<#
.SYNOPSIS
    修狗TV 发布产物冒烟门禁：任何一项 FAIL 即以退出码 1 结束，调用方据此中止发布。

.DESCRIPTION
    针对 v1.0.1 / v1.0.2 「安装包与便携包运行后打不开」两类事故设计：
      1) 用户机缺 VC++ 运行库（issue #2，VCRUNTIME140_1.dll）——exe 与插件 DLL 依赖
         MSVCP140 / VCRUNTIME140 / VCRUNTIME140_1，旧包只在 runtime\jre\bin 下有一份，
         主程序目录没有；本门禁做 PE 导入闭包检查，并在启动后核对运行库从包内目录加载；
      2) 窗口开在屏幕外（§47，desktop_window.json 被写成 -32000 / 158×26）——启动冒烟
         用临时 APPDATA 预置事故配置，要求窗口可见、落在显示器工作区内且尺寸正常。

    检查项：产物与 SHA256SUMS 自检、版本资源、zip 条目分隔符、必需文件清单、与构建目录
    逐文件一致、PE 依赖闭包、内置 JRE 可运行、zip 解压 / 安装包静默安装到临时目录后
    分别启动（存活、可见、有内容、运行库来源、正常关闭退出码 0、无 hs_err / 崩溃转储）。

.PARAMETER Version
    期望版本号 x.y.z。

.PARAMETER ArtifactDir
    存放 portable.zip / setup.exe / SHA256SUMS 的目录。

.PARAMETER BuildOutputDir
    Flutter Release 输出目录（用于逐文件对照）；缺省为 build\windows\x64\runner\Release。

.PARAMETER LaunchSeconds
    窗口出现后要求进程持续存活的秒数（默认 8）。

.PARAMETER SkipZip
    不检查便携包（打包时用了 -SkipZip）。

.PARAMETER SkipInstaller
    不检查安装包（打包时用了 -SkipInstaller）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$ArtifactDir,
    [string]$BuildOutputDir = "",
    [int]$LaunchSeconds = 8,
    [switch]$SkipZip,
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir/..").Path
if (-not $BuildOutputDir) { $BuildOutputDir = Join-Path $ProjectRoot "build/windows/x64/runner/Release" }
$ArtifactDir = (Resolve-Path -LiteralPath $ArtifactDir).Path
$BuildOutputDir = [System.IO.Path]::GetFullPath($BuildOutputDir)

$ZipName = "xiugou-tv-windows-x64-v$Version-portable.zip"
$SetupName = "xiugou-tv-windows-x64-v$Version-setup.exe"
$ZipPath = Join-Path $ArtifactDir $ZipName
$SetupPath = Join-Path $ArtifactDir $SetupName
$SumsPath = Join-Path $ArtifactDir "SHA256SUMS"
# 与 scripts/installer.iss 的 AppId 一致；Inno 在注册表里的键名是 "{AppId}_is1"。
$InnoUninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E88D6F21-6A2F-4E8C-B8FB-5A86FA8F0C42}_is1"

# 主程序目录里必须自带的 VC++ 运行库（应用本地部署；用户机未装 vc_redist 时也能启动）。
$VcCrtFiles = @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Scope, [string]$Name, [bool]$Ok, [string]$Detail) {
    $Results.Add([pscustomobject]@{ Scope = $Scope; Name = $Name; Ok = $Ok; Detail = $Detail })
    $tag = if ($Ok) { "PASS" } else { "FAIL" }
    $color = if ($Ok) { "Green" } else { "Red" }
    Write-Host ("  [{0}] {1} / {2}：{3}" -f $tag, $Scope, $Name, $Detail) -ForegroundColor $color
}
function Invoke-Check([string]$Scope, [string]$Name, [scriptblock]$Body) {
    try {
        $detail = & $Body
        Add-Result $Scope $Name $true ([string]$detail)
    } catch {
        Add-Result $Scope $Name $false $_.Exception.Message
    }
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class XgPe {
    // 读取 PE 导入表里的 DLL 名（不含延迟加载）。只解析需要的字段，避免引入第三方依赖。
    public static string[] Imports(string path) {
        byte[] b = File.ReadAllBytes(path);
        int pe = BitConverter.ToInt32(b, 0x3C);
        if (BitConverter.ToUInt32(b, pe) != 0x4550) throw new Exception("不是 PE 文件: " + path);
        int coff = pe + 4;
        int nsec = BitConverter.ToUInt16(b, coff + 2);
        int optSize = BitConverter.ToUInt16(b, coff + 16);
        int opt = coff + 20;
        ushort magic = BitConverter.ToUInt16(b, opt);
        int dd = opt + (magic == 0x20b ? 112 : 96);
        uint impRva = BitConverter.ToUInt32(b, dd + 8);
        int secTable = opt + optSize;
        List<string> list = new List<string>();
        if (impRva == 0) return list.ToArray();
        int d = RvaToOffset(b, secTable, nsec, impRva);
        while (d >= 0 && d + 20 <= b.Length) {
            uint nameRva = BitConverter.ToUInt32(b, d + 12);
            if (nameRva == 0) break;
            int n = RvaToOffset(b, secTable, nsec, nameRva);
            if (n < 0) break;
            int e = n;
            while (e < b.Length && b[e] != 0) e++;
            list.Add(Encoding.ASCII.GetString(b, n, e - n));
            d += 20;
        }
        return list.ToArray();
    }

    static int RvaToOffset(byte[] b, int secTable, int nsec, uint rva) {
        for (int i = 0; i < nsec; i++) {
            int s = secTable + i * 40;
            uint va = BitConverter.ToUInt32(b, s + 12);
            uint size = Math.Max(BitConverter.ToUInt32(b, s + 8), BitConverter.ToUInt32(b, s + 16));
            uint raw = BitConverter.ToUInt32(b, s + 20);
            if (rva >= va && rva < va + size) return (int)(rva - va + raw);
        }
        return -1;
    }
}

public static class XgWin {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder sb, int max);

    // 找指定进程的 Flutter 顶层窗口（类名见 windows/runner/win32_window.cpp）。
    public static IntPtr FindTopLevel(int pid, string className) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner != (uint)pid) return true;
            StringBuilder sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            if (sb.ToString() == className) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@
[void][XgWin]::SetProcessDPIAware()

$SmokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("xiugou-tv-smoke-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SmokeRoot -Force | Out-Null

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  发布产物冒烟门禁  v$Version" -ForegroundColor Cyan
Write-Host "  产物目录：$ArtifactDir" -ForegroundColor Cyan
Write-Host "  临时目录：$SmokeRoot" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

function Get-NormalizedVersion([string]$Raw) {
    if (-not $Raw) { return "" }
    $v = $Raw.Trim() -replace '[, ]+', '.'
    while (($v.Split('.').Count -gt 3) -and $v.EndsWith('.0')) { $v = $v.Substring(0, $v.Length - 2) }
    return $v
}

# 包内必需文件清单（相对路径）。插件 DLL 另按构建目录全量对照，这里列的是「缺了必然打不开 / 必然降级」的项。
function Get-RequiredEntries {
    $list = @(
        "xiugou_tv.exe", "flutter_windows.dll",
        "libmpv-2.dll", "libEGL.dll", "libGLESv2.dll", "d3dcompiler_47.dll",
        "data/app.so", "data/icudtl.dat",
        "data/flutter_assets/AssetManifest.bin", "data/flutter_assets/FontManifest.json",
        "data/flutter_assets/fonts/MaterialIcons-Regular.otf",
        "runtime/jre/bin/java.exe", "runtime/jre/bin/server/jvm.dll", "runtime/jre/lib/modules",
        "companion/dist/companion-service.jar",
        "companion/dist/pyshell/runner.py"
    ) + $VcCrtFiles
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot "companion/pyruntime/python.exe")) {
        $list += "companion/dist/pyruntime/python.exe"
    }
    foreach ($plugin in (Get-ChildItem -LiteralPath $BuildOutputDir -Filter "*_plugin.dll" -File)) { $list += $plugin.Name }
    return $list
}

function Test-PackageLayout([string]$Scope, [string]$Root) {
    Invoke-Check $Scope "必需文件清单" {
        $missing = @()
        foreach ($rel in (Get-RequiredEntries)) {
            $full = Join-Path $Root $rel
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-Item -LiteralPath $full).Length -eq 0) { $missing += $rel }
        }
        foreach ($glob in @(@("companion/dist", "bcprov-*.jar"), @("companion/dist/lib-unidbg", "*.jar"))) {
            $dir = Join-Path $Root $glob[0]
            if (@(Get-ChildItem -LiteralPath $dir -Filter $glob[1] -File -ErrorAction SilentlyContinue).Count -eq 0) { $missing += "$($glob[0])/$($glob[1])" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Root "data/flutter_assets") -PathType Container)) { $missing += "data/flutter_assets/" }
        if ($missing.Count -gt 0) { throw "缺少 $($missing.Count) 项：$($missing -join ', ')" }
        "$(@(Get-RequiredEntries).Count + 2) 项齐全"
    }

    Invoke-Check $Scope "与构建目录逐文件一致" {
        $buildFiles = @(Get-ChildItem -LiteralPath $BuildOutputDir -Recurse -File)
        $bad = @()
        foreach ($f in $buildFiles) {
            $rel = $f.FullName.Substring($BuildOutputDir.Length).TrimStart('\', '/')
            $peer = Join-Path $Root $rel
            if (-not (Test-Path -LiteralPath $peer -PathType Leaf)) { $bad += "缺 $rel"; continue }
            if ((Get-Item -LiteralPath $peer).Length -ne $f.Length) { $bad += "大小不同 $rel" }
        }
        foreach ($rel in @("data/app.so", "xiugou_tv.exe")) {
            $a = (Get-FileHash -LiteralPath (Join-Path $BuildOutputDir $rel) -Algorithm SHA256).Hash
            $b = (Get-FileHash -LiteralPath (Join-Path $Root $rel) -Algorithm SHA256).Hash
            if ($a -ne $b) { $bad += "哈希不同 $rel" }
        }
        if ($bad.Count -gt 0) { throw ("{0} 处不一致：{1}" -f $bad.Count, (($bad | Select-Object -First 8) -join '; ')) }
        "$($buildFiles.Count) 个文件一致，app.so / exe 哈希相同"
    }

    Invoke-Check $Scope "残留检查（hs_err / 崩溃转储）" {
        $junk = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "hs_err_pid*.log" -or $_.Name -like "replay_pid*.log" -or $_.Name -like "*.dmp" })
        if ($junk.Count -gt 0) { throw "包内有 $($junk.Count) 个残留：$(($junk | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')" }
        "无残留"
    }

    Invoke-Check $Scope "PE 依赖闭包（从 xiugou_tv.exe 出发）" {
        $system32 = [Environment]::GetFolderPath('System')
        $queue = New-Object System.Collections.Generic.Queue[string]
        $seen = @{}
        $queue.Enqueue("xiugou_tv.exe")
        $problems = @()
        while ($queue.Count -gt 0) {
            $name = $queue.Dequeue()
            if ($seen.ContainsKey($name.ToLowerInvariant())) { continue }
            $seen[$name.ToLowerInvariant()] = $true
            foreach ($dep in [XgPe]::Imports((Join-Path $Root $name))) {
                $lower = $dep.ToLowerInvariant()
                if ($lower -like "api-ms-win-*" -or $lower -like "ext-ms-*") { continue }
                if (Test-Path -LiteralPath (Join-Path $Root $dep) -PathType Leaf) { $queue.Enqueue($dep); continue }
                # VC++ 运行库与调试版 CRT 不是系统自带文件：本机有不代表用户机有（issue #2）。
                if ($lower -match '^(vcruntime|msvcp|concrt|vccorlib|ucrtbase)') {
                    $problems += "$name -> $dep（未随包）"
                    continue
                }
                if (-not (Test-Path -LiteralPath (Join-Path $system32 $dep) -PathType Leaf)) { $problems += "$name -> $dep（包内与系统目录都没有）" }
            }
        }
        if ($problems.Count -gt 0) { throw ($problems -join '; ') }
        "$($seen.Count) 个模块的静态依赖均可解析，VC++ 运行库随包"
    }
}

function Test-BundledJre([string]$Scope, [string]$Root) {
    Invoke-Check $Scope "内置 JRE 可运行" {
        $java = Join-Path $Root "runtime/jre/bin/java.exe"
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $out = & $java -version 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
        if ($code -ne 0) { throw "java -version 退出码 $code：$out" }
        ($out -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1).Trim()
    }
}

function Test-VersionResource([string]$Scope, [string]$Path, [string[]]$Fields) {
    Invoke-Check $Scope "版本资源 = $Version" {
        $info = (Get-Item -LiteralPath $Path).VersionInfo
        $pairs = @()
        foreach ($field in $Fields) {
            $value = Get-NormalizedVersion ([string]$info.$field)
            if ($value -ne $Version) { throw "$([System.IO.Path]::GetFileName($Path)) 的 $field = '$($info.$field)'，期望 $Version" }
            $pairs += "$field=$value"
        }
        $pairs -join ', '
    }
}

# 启动冒烟：临时 APPDATA + 事故窗口配置 → 窗口可见且在屏内 → 运行库来源 → 正常关闭。
function Test-Launch([string]$Scope, [string]$Root) {
    $exe = Join-Path $Root "xiugou_tv.exe"
    $appData = Join-Path $SmokeRoot ("appdata-" + $Scope)
    $workDir = Join-Path $SmokeRoot ("cwd-" + $Scope)
    New-Item -ItemType Directory -Path (Join-Path $appData "XiugouTV"), $workDir -Force | Out-Null
    # §47 事故现场：最小化关闭后写下的占位几何。
    $poison = '{"width":158.0,"height":26.0,"posX":-32000.0,"posY":-32000.0,"isMaximized":false,"isFullScreen":false,"alwaysOnTop":false}'
    [System.IO.File]::WriteAllText((Join-Path $appData "XiugouTV/desktop_window.json"), $poison, (New-Object System.Text.UTF8Encoding($false)))
    $dumpDir = Join-Path $env:LOCALAPPDATA "CrashDumps"
    $startedAt = Get-Date

    $savedAppData = $env:APPDATA
    $proc = $null
    try {
        $env:APPDATA = $appData
        $proc = Start-Process -FilePath $exe -WorkingDirectory $workDir -PassThru
        $null = $proc.Handle  # 保持句柄，进程退出后仍可读 ExitCode
    } finally {
        $env:APPDATA = $savedAppData
    }

    try {
        $hwnd = [IntPtr]::Zero
        Invoke-Check $Scope "进程启动且窗口可见" {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                if ($proc.HasExited) { throw ("进程已退出，退出码 0x{0:X8}" -f $proc.ExitCode) }
                $h = [XgWin]::FindTopLevel($proc.Id, "FLUTTER_RUNNER_WIN32_WINDOW")
                if ($h -ne [IntPtr]::Zero -and [XgWin]::IsWindowVisible($h)) { $script:hwndFound = $h; break }
                Start-Sleep -Milliseconds 300
            }
            if (-not $script:hwndFound) { throw "30 秒内没有出现可见的主窗口（进程仍在：$(-not $proc.HasExited)）" }
            "pid $($proc.Id)，$([int]((Get-Date) - $startedAt).TotalSeconds)s 内出现窗口"
        }
        $hwnd = $script:hwndFound
        $script:hwndFound = $null

        Invoke-Check $Scope "存活 $LaunchSeconds 秒未崩溃" {
            Start-Sleep -Seconds $LaunchSeconds
            if ($proc.HasExited) { throw ("进程提前退出，退出码 0x{0:X8}" -f $proc.ExitCode) }
            "仍在运行"
        }

        Invoke-Check $Scope "窗口在屏幕内（预置 -32000 / 158×26 事故配置）" {
            if (-not $hwnd) { throw "没有主窗口" }
            if ([XgWin]::IsIconic($hwnd)) { throw "窗口处于最小化" }
            $r = New-Object XgWin+RECT
            [void][XgWin]::GetWindowRect($hwnd, [ref]$r)
            $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
            if ($w -lt 320 -or $h -lt 180) { throw "窗口尺寸异常 ${w}×${h}" }
            $visible = $false
            foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
                $a = $screen.WorkingArea
                $ix = [Math]::Min($r.Right, $a.Right) - [Math]::Max($r.Left, $a.Left)
                $iy = [Math]::Min($r.Bottom, $a.Bottom) - [Math]::Max($r.Top, $a.Top)
                if ($ix -ge 120 -and $iy -ge 40) { $visible = $true }
            }
            if (-not $visible) { throw "窗口不在任何显示器工作区内：($($r.Left),$($r.Top)) ${w}×${h}" }
            "($($r.Left),$($r.Top)) ${w}×${h}"
        }

        Invoke-Check $Scope "窗口有渲染内容" {
            if (-not $hwnd) { throw "没有主窗口" }
            # 最多截 5 次、间隔 2 秒：任一次有内容即通过；持续纯色才判白屏 / 黑屏。
            # 每次先用 PrintWindow（不受遮挡影响）；实测它对 ANGLE / D3D 合成的窗口会间歇性只返回
            # 窗口底色（同一进程相邻两秒 391 色 / 1 色交替），所以纯色时再把窗口切到前台、直接截屏复核。
            $best = 0
            $shot = Join-Path $SmokeRoot "window-$Scope.png"
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                $r = New-Object XgWin+RECT
                [void][XgWin]::GetWindowRect($hwnd, [ref]$r)
                $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
                $bmp = New-Object System.Drawing.Bitmap $w, $h
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $hdc = $g.GetHdc()
                # PW_RENDERFULLCONTENT = 2：能截到 DirectX / ANGLE 合成的内容，且不受遮挡影响。
                [void][XgWin]::PrintWindow($hwnd, $hdc, 2)
                $g.ReleaseHdc($hdc); $g.Dispose()
                $colors = @{}
                for ($x = 0; $x -lt 24; $x++) {
                    for ($y = 0; $y -lt 24; $y++) {
                        $c = $bmp.GetPixel([int](($x + 0.5) * $w / 24), [int](($y + 0.5) * $h / 24))
                        $colors[$c.ToArgb()] = $true
                    }
                }
                if ($colors.Count -lt 4) {
                    [void][XgWin]::SetForegroundWindow($hwnd)
                    Start-Sleep -Milliseconds 300
                    $g = [System.Drawing.Graphics]::FromImage($bmp)
                    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
                    $g.Dispose()
                    $colors = @{}
                }
                for ($x = 0; $x -lt 24; $x++) {
                    for ($y = 0; $y -lt 24; $y++) {
                        $c = $bmp.GetPixel([int](($x + 0.5) * $w / 24), [int](($y + 0.5) * $h / 24))
                        $colors[$c.ToArgb()] = $true
                    }
                }
                $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
                $best = [Math]::Max($best, $colors.Count)
                if ($colors.Count -ge 4) { break }
                Start-Sleep -Seconds 2
            }
            if ($best -lt 4) { throw "连续 5 次截图采样最多 $best 种颜色，疑似白屏 / 黑屏（截图 $shot）" }
            "采样 $best 种颜色（第 $attempt 次截图）"
        }

        Invoke-Check $Scope "VC++ 运行库从包内目录加载" {
            $proc.Refresh()
            $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
            $wrong = @()
            foreach ($name in $VcCrtFiles) {
                $mod = $proc.Modules | Where-Object { $_.ModuleName -ieq $name } | Select-Object -First 1
                if (-not $mod) { $wrong += "$name 未加载"; continue }
                if (-not $mod.FileName.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { $wrong += "$name 来自 $($mod.FileName)" }
            }
            if ($wrong.Count -gt 0) { throw ($wrong -join '; ') }
            "$($VcCrtFiles -join ' / ') 均来自安装目录"
        }

        Invoke-Check $Scope "正常关闭（退出码 0）" {
            if ($proc.HasExited) { throw ("进程已退出，退出码 0x{0:X8}" -f $proc.ExitCode) }
            # WM_CLOSE，走与点关闭按钮相同的退出路径（§48 关闭崩溃即发生在这里）。
            [void][XgWin]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            if (-not $proc.WaitForExit(20000)) { throw "20 秒内未退出" }
            if ($proc.ExitCode -ne 0) { throw ("退出码 0x{0:X8}" -f $proc.ExitCode) }
            "退出码 0"
        }

        Invoke-Check $Scope "无 hs_err / 新崩溃转储" {
            $junk = @(Get-ChildItem -LiteralPath $workDir, $Root -Filter "hs_err_pid*.log" -File -ErrorAction SilentlyContinue)
            $dumps = @(Get-ChildItem -LiteralPath $dumpDir -Filter "xiugou_tv.exe*.dmp" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $startedAt })
            if ($junk.Count -gt 0 -or $dumps.Count -gt 0) { throw "hs_err $($junk.Count) 个、崩溃转储 $($dumps.Count) 个" }
            "无"
        }

        Invoke-Check $Scope "窗口几何已自愈" {
            $saved = Get-Content -LiteralPath (Join-Path $appData "XiugouTV/desktop_window.json") -Raw | ConvertFrom-Json
            if (($saved.posX -ne $null -and $saved.posX -le -10000) -or $saved.width -lt 320) { throw "关闭后仍为事故值：$($saved | ConvertTo-Json -Compress)" }
            "width=$($saved.width) height=$($saved.height) posX=$($saved.posX) posY=$($saved.posY)"
        }
    } finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
        # 兜底：清掉从该目录启动的残留进程（主程序或伴随 JVM）。
        $rootFull = [System.IO.Path]::GetFullPath($Root)
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and $_.Path.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) } catch { $false }
        } | ForEach-Object { try { $_.Kill() } catch { } }
    }
}

try {
    # 1. 产物与 SHA256SUMS
    $expectFiles = @()
    if (-not $SkipZip) { $expectFiles += $ZipName }
    if (-not $SkipInstaller) { $expectFiles += $SetupName }
    Invoke-Check "产物" "文件存在且非空" {
        foreach ($f in ($expectFiles + "SHA256SUMS")) {
            $p = Join-Path $ArtifactDir $f
            if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -eq 0) { throw "缺少或为空：$f" }
        }
        ($expectFiles | ForEach-Object { "{0}（{1:N0} B）" -f $_, (Get-Item -LiteralPath (Join-Path $ArtifactDir $_)).Length }) -join '；'
    }
    Invoke-Check "产物" "SHA256SUMS 自检" {
        $bytes = [System.IO.File]::ReadAllBytes($SumsPath)
        if ($bytes -contains 13) { throw "SHA256SUMS 含 CR，标准 sha256sum -c 会把 \r 当成文件名" }
        $map = @{}
        foreach ($line in ([System.Text.Encoding]::ASCII.GetString($bytes) -split "`n")) {
            if (-not $line.Trim()) { continue }
            $m = [regex]::Match($line, '^([0-9a-f]{64}) [ *](\S.*)$')
            if (-not $m.Success) { throw "格式不符：$line" }
            $map[$m.Groups[2].Value] = $m.Groups[1].Value
        }
        foreach ($f in $expectFiles) {
            if (-not $map.ContainsKey($f)) { throw "清单缺少 $f" }
            $actual = (Get-FileHash -LiteralPath (Join-Path $ArtifactDir $f) -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $map[$f]) { throw "$f 哈希不符：清单 $($map[$f]) / 实际 $actual" }
        }
        ($expectFiles | ForEach-Object { "$_ $($map[$_].Substring(0, 12))…" }) -join '；'
    }

    # 2. 便携包
    if (-not $SkipZip) {
        $zipRoot = Join-Path $SmokeRoot "portable"
        Invoke-Check "便携包" "zip 条目使用 / 分隔且可解压" {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
            try {
                $count = $archive.Entries.Count
                $backslash = @($archive.Entries | Where-Object { $_.FullName.Contains('\') }).Count
            } finally { $archive.Dispose() }
            # 先照常解压（.NET 在 Windows 上会把 \ 当分隔符），后续检查仍可进行；分隔符问题单独判 FAIL。
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $zipRoot)
            if ($backslash -gt 0) { throw "$backslash / $count 个条目用了反斜杠分隔（不符合 zip 规范，部分解压工具会把整条路径当文件名）" }
            "$count 个条目，已解压到 $zipRoot"
        }
        if (Test-Path -LiteralPath (Join-Path $zipRoot "xiugou_tv.exe")) {
            Test-VersionResource "便携包" (Join-Path $zipRoot "xiugou_tv.exe") @("FileVersion", "ProductVersion")
            Test-PackageLayout "便携包" $zipRoot
            Test-BundledJre "便携包" $zipRoot
            Test-Launch "便携包" $zipRoot
        } else {
            Add-Result "便携包" "启动冒烟" $false "解压目录里没有 xiugou_tv.exe"
        }
    }

    # 3. 安装包：/CURRENTUSER 免提权静默装到临时目录（installer.iss 允许命令行覆盖权限）。
    if (-not $SkipInstaller) {
        Test-VersionResource "安装包" $SetupPath @("FileVersion", "ProductVersion")
        $installRoot = Join-Path $SmokeRoot "installed"
        $installed = $false
        Invoke-Check "安装包" "静默安装到临时目录" {
            if (Test-Path -LiteralPath $InnoUninstallKey) {
                $loc = (Get-ItemProperty -LiteralPath $InnoUninstallKey).InstallLocation
                throw "当前用户已有一份按用户安装的修狗TV（$loc），为避免覆盖 / 卸载它，门禁不执行安装；请先卸载或在其他账户运行"
            }
            $log = Join-Path $SmokeRoot "install.log"
            $p = Start-Process -FilePath $SetupPath -PassThru -Wait -ArgumentList @(
                "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/NOICONS", "/TASKS=`"`"",
                "/DIR=`"$installRoot`"", "/LOG=`"$log`"")
            if ($p.ExitCode -ne 0) { throw "安装程序退出码 $($p.ExitCode)（日志 $log）" }
            if (-not (Test-Path -LiteralPath (Join-Path $installRoot "xiugou_tv.exe"))) { throw "安装后没有 xiugou_tv.exe（日志 $log）" }
            $script:installedFlag = $true
            "已安装到 $installRoot"
        }
        $installed = [bool]$script:installedFlag
        if ($installed) {
            try {
                Test-VersionResource "安装包" (Join-Path $installRoot "xiugou_tv.exe") @("FileVersion", "ProductVersion")
                Test-PackageLayout "安装包" $installRoot
                Test-BundledJre "安装包" $installRoot
                Test-Launch "安装包" $installRoot
            } finally {
                Invoke-Check "安装包" "静默卸载与清理" {
                    $uninstaller = Join-Path $installRoot "unins000.exe"
                    if (Test-Path -LiteralPath $uninstaller) {
                        $u = Start-Process -FilePath $uninstaller -PassThru -Wait -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
                        if ($u.ExitCode -ne 0) { throw "卸载程序退出码 $($u.ExitCode)" }
                    }
                    # 卸载器会把自身复制到临时目录再执行，注册表键与文件稍后才消失。
                    $deadline = (Get-Date).AddSeconds(30)
                    while ((Test-Path -LiteralPath $InnoUninstallKey) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
                    if (Test-Path -LiteralPath $InnoUninstallKey) { throw "卸载后注册表仍有 $InnoUninstallKey" }
                    "已卸载，注册表项已清除"
                }
            }
        }
    }
} finally {
    Start-Sleep -Seconds 1
    # 全部通过才清理；有失败时保留临时目录（截图、安装日志、解压内容）供排查。
    if (@($Results | Where-Object { -not $_.Ok }).Count -eq 0) {
        Remove-Item -LiteralPath $SmokeRoot -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "  [*] 有失败项，保留临时目录供排查：$SmokeRoot" -ForegroundColor Yellow
    }
}

$failed = @($Results | Where-Object { -not $_.Ok })
Write-Host "------------------------------------------------------" -ForegroundColor Cyan
Write-Host ("  门禁汇总：{0} 项，PASS {1}，FAIL {2}" -f $Results.Count, ($Results.Count - $failed.Count), $failed.Count) -ForegroundColor $(if ($failed.Count -eq 0) { "Green" } else { "Red" })
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host "    FAIL  $($_.Scope) / $($_.Name)：$($_.Detail)" -ForegroundColor Red }
    exit 1
}
exit 0
