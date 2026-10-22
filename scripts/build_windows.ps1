<#
.SYNOPSIS
    修狗TV Windows x64 Automated Build and Packaging Script.
.DESCRIPTION
    Compiles the Flutter Windows application in Release mode, collects all required
    runtime dependencies (including MPV and Flutter plugins), and packages the output
    into a portable ZIP archive and an Inno Setup installer executable.
.PARAMETER Version
    Product release version string (Default: read from pubspec.yaml).
.PARAMETER FlutterPath
    Custom path to Flutter SDK bin directory (e.g. 'D:\flutter\bin').
.PARAMETER SkipZip
    Skip generating the portable ZIP archive.
.PARAMETER SkipInstaller
    Skip compiling the Inno Setup installer.
#>

param (
    [string]$Version = "",
    [string]$FlutterPath = "",
    [switch]$SkipZip = $false,
    [switch]$SkipInstaller = $false
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir/..").Path
$BuildOutputDir = "$ProjectRoot/build/windows/x64/runner/Release"
$DistDir = "$ProjectRoot/dist"

# 版本号默认跟随 pubspec.yaml（开发版本真源）；显式传 -Version 时以参数为准。
if ([string]::IsNullOrWhiteSpace($Version)) {
    $pubspecPath = Join-Path $ProjectRoot "pubspec.yaml"
    $versionLine = Get-Content -LiteralPath $pubspecPath |
        Where-Object { $_ -match '^\s*version:\s*\S+' } |
        Select-Object -First 1
    if ($versionLine -match '^\s*version:\s*(\d+\.\d+\.\d+)') {
        $Version = $Matches[1]
    } else {
        throw "无法从 pubspec.yaml 解析版本号，请显式传 -Version x.y.z"
    }
}
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw "版本号格式不合法：$Version（期望 x.y.z）"
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  修狗TV Build & Packaging System" -ForegroundColor Cyan
Write-Host "  Target: Windows x64 | Version: $Version" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# 1. Environment Check & Auto-discovery
Write-Host "[1/5] Checking build environment..." -ForegroundColor Yellow

$FlutterCmd = $null

# Check custom path parameter
if ($FlutterPath -ne "") {
    $CustomFlutter = Join-Path $FlutterPath "flutter.bat"
    if (Test-Path -LiteralPath $CustomFlutter -PathType Leaf) {
        $FlutterCmd = (Resolve-Path -LiteralPath $CustomFlutter).ProviderPath
        $env:Path = (Split-Path -Parent $FlutterCmd) + ";" + $env:Path
        Write-Host "  [+] Using specified Flutter SDK: $FlutterPath" -ForegroundColor Green
    } else {
        throw "Flutter SDK not found at explicit path: $CustomFlutter"
    }
}

# Check system PATH
if (-not $FlutterCmd) {
    $SysFlutter = Get-Command "flutter" -ErrorAction SilentlyContinue
    if ($SysFlutter) {
        $FlutterCmd = $SysFlutter.Source
        Write-Host "  [+] Found Flutter SDK in PATH: $FlutterCmd" -ForegroundColor Green
    }
}

# Auto scan candidate directories
if (-not $FlutterCmd) {
    $CandidateDirs = @(
        "E:\resource\path\flutter\bin",
        "C:\flutter\bin",
        "D:\flutter\bin",
        "E:\flutter\bin",
        "F:\flutter\bin",
        "C:\src\flutter\bin",
        "D:\src\flutter\bin",
        "E:\src\flutter\bin",
        "$env:USERPROFILE\flutter\bin",
        "$env:USERPROFILE\scoop\apps\flutter\current\bin",
        "$env:LOCALAPPDATA\flutter\bin",
        "$env:LOCALAPPDATA\Programs\flutter\bin",
        "$env:ProgramFiles\flutter\bin",
        "C:\tools\flutter\bin"
    )

    foreach ($dir in $CandidateDirs) {
        $bat = Join-Path $dir "flutter.bat"
        if (Test-Path $bat) {
            $FlutterCmd = $bat
            $env:Path = "$dir;" + $env:Path
            Write-Host "  [+] Auto-discovered Flutter SDK at: $dir" -ForegroundColor Green
            break
        }
    }
}

if (-not $FlutterCmd) {
    Write-Host ""
    Write-Host "[!] Flutter SDK not found in PATH or standard directories!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Solutions:" -ForegroundColor Yellow
    Write-Host "1. Specify Flutter SDK path directly:" -ForegroundColor White
    Write-Host "   powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1 -FlutterPath 'D:\path\to\flutter\bin'" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Or set PATH temporarily in current session:" -ForegroundColor White
    Write-Host "   `$env:Path = 'D:\path\to\flutter\bin;' + `$env:Path" -ForegroundColor Cyan
    Write-Host "   powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "3. Or download Flutter SDK from official site:" -ForegroundColor White
    Write-Host "   https://docs.flutter.dev/get-started/install/windows/desktop" -ForegroundColor Cyan
    Write-Host ""
    Exit 1
}

# 2. Dependency resolution
Write-Host "[2/5] Resolving Flutter dependencies..." -ForegroundColor Yellow
Set-Location $ProjectRoot
& $FlutterCmd pub get
if ($LASTEXITCODE -ne 0) {
    Write-Error "flutter pub get failed."
}

# 3. Release compilation
Write-Host "[3/5] Building Windows x64 Release binary..." -ForegroundColor Yellow
& $FlutterCmd build windows --release
if ($LASTEXITCODE -ne 0) {
    Write-Error "flutter build windows --release failed."
}

if (-not (Test-Path -LiteralPath "$BuildOutputDir/xiugou_tv.exe" -PathType Leaf)) {
    Write-Error "Build output executable not found at: $BuildOutputDir/xiugou_tv.exe"
}

# 3.2 Icon font subset gate
# release 构建默认 --tree-shake-icons，增量构建可能复用过期子集，导致新增图标运行时空白
# （2026-10-18 实机事故：7 个图标缺失）。此处强制校验，缺失即失败。
Write-Host "[3.2/5] Verifying icon font subset..." -ForegroundColor Yellow
$IconFont = Join-Path $BuildOutputDir "data/flutter_assets/fonts/MaterialIcons-Regular.otf"
$SourceRoot = Join-Path $ProjectRoot "lib"
$IconChecker = Join-Path $ProjectRoot "scripts/check_icon_subset.py"
if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    Write-Host "  [i] No lib/ source directory; skipping icon subset gate." -ForegroundColor DarkGray
} elseif (-not (Test-Path -LiteralPath $IconFont -PathType Leaf)) {
    throw "Icon font asset is missing: $IconFont"
} else {
    $IconChecked = $false
    $PythonCmd = Get-Command "python" -ErrorAction SilentlyContinue
    if ($PythonCmd -and (Test-Path -LiteralPath $IconChecker -PathType Leaf)) {
        & $PythonCmd.Source $IconChecker "--project-root" $ProjectRoot
        if ($LASTEXITCODE -eq 0) {
            $IconChecked = $true
            Write-Host "  [+] Icon font subset covers every referenced icon." -ForegroundColor Green
        } elseif ($LASTEXITCODE -eq 1) {
            throw "Icon font subset is stale: referenced icons are missing from $IconFont. Delete that file and rebuild."
        } else {
            Write-Host "  [!] Icon checker could not run (Flutter SDK icons.dart not found); using timestamp fallback." -ForegroundColor Yellow
        }
    }
    if (-not $IconChecked) {
        $FontTime = (Get-Item -LiteralPath $IconFont).LastWriteTimeUtc
        $NewestSource = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter "*.dart" -File |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($NewestSource -and ($NewestSource.LastWriteTimeUtc -gt $FontTime)) {
            throw "Icon font subset is stale: $($NewestSource.Name) is newer than $IconFont. Delete that file and rebuild."
        }
        Write-Host "  [+] Icon font timestamp is newer than every lib/*.dart (fallback check)." -ForegroundColor Green
    }
}

# 3.1 Bundle Companion Service and Embedded Minimal JRE
Write-Host "[3.1/5] Bundling Companion Service & Runtime..." -ForegroundColor Yellow

$CompanionScript = Join-Path $ProjectRoot "companion/build.ps1"
if (-not (Test-Path -LiteralPath $CompanionScript -PathType Leaf)) {
    throw "Required Companion build script not found: $CompanionScript"
}
$EmbeddedJre = Join-Path $ProjectRoot "runtime/jre"
foreach ($requiredRuntimeFile in @("bin/java.exe", "bin/server/jvm.dll")) {
    if (-not (Test-Path -LiteralPath (Join-Path $EmbeddedJre $requiredRuntimeFile) -PathType Leaf)) {
        throw "Required embedded JRE file not found: $EmbeddedJre/$requiredRuntimeFile"
    }
}

Write-Host "  [*] Building companion-service.jar..." -ForegroundColor Cyan
& powershell -NoProfile -NonInteractive -File $CompanionScript
if ($LASTEXITCODE -ne 0) {
    throw "Companion build failed with exit code $LASTEXITCODE."
}

$CompanionDist = Join-Path $ProjectRoot "companion/dist/companion-service.jar"
if (-not (Test-Path -LiteralPath $CompanionDist -PathType Leaf)) {
    throw "Companion build produced no JAR: $CompanionDist"
}
if ((Get-Item -LiteralPath $CompanionDist).Length -eq 0) {
    throw "Companion JAR is empty: $CompanionDist"
}
$TargetCompanionRoot = Join-Path $BuildOutputDir "companion"
$TargetCompanionDir = Join-Path $TargetCompanionRoot "dist"
# invariant: 每次构建都从源目录重建 companion/dist，发布包里不允许出现上一轮的残留文件。
# 只覆盖单个 jar 会把旧的 companion-service-<guid>.jar（每个 ~36 MB）、旧依赖一并留在原地，
# 随后被 Compress-Archive 整包带走——684 MB 的便携包就是这么来的。
$BuildOutputFull = [System.IO.Path]::GetFullPath($BuildOutputDir) + [System.IO.Path]::DirectorySeparatorChar
$TargetCompanionRootFull = [System.IO.Path]::GetFullPath($TargetCompanionRoot)
if (-not $TargetCompanionRootFull.StartsWith($BuildOutputFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Companion cleanup target is outside the release directory: $TargetCompanionRootFull"
}
if (Test-Path -LiteralPath $TargetCompanionRoot) {
    Remove-Item -LiteralPath $TargetCompanionRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $TargetCompanionDir -Force | Out-Null
Copy-Item -LiteralPath $CompanionDist -Destination $TargetCompanionDir -Force

# 运行时依赖必须与 companion-service.jar 同级：AndroidBridge 按 jar 同目录找 BouncyCastle，
# GuardPayloadProvisioner 按 dist/lib-unidbg 找解密依赖。缺任何一个都会让发布包在下游静默降级。
$CompanionLibsDir = Join-Path $ProjectRoot "companion/libs"
$CompanionLibJars = @(Get-ChildItem -LiteralPath $CompanionLibsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue)
if ($CompanionLibJars.Count -eq 0) {
    throw "No runtime library JARs found: $CompanionLibsDir (AndroidBridge requires BouncyCastle beside the service JAR)."
}
$CompanionUnidbgDir = Join-Path $ProjectRoot "companion/lib-unidbg"
$CompanionUnidbgJars = @(Get-ChildItem -LiteralPath $CompanionUnidbgDir -Filter "*.jar" -File -ErrorAction SilentlyContinue)
if ($CompanionUnidbgJars.Count -eq 0) {
    throw "No guard-decrypt JARs found: $CompanionUnidbgDir (guard sites would silently fall back to SpiderNull)."
}
foreach ($lib in $CompanionLibJars) {
    Copy-Item -LiteralPath $lib.FullName -Destination $TargetCompanionDir -Force
}
$TargetUnidbgDir = Join-Path $TargetCompanionDir "lib-unidbg"
New-Item -ItemType Directory -Path $TargetUnidbgDir -Force | Out-Null
foreach ($lib in $CompanionUnidbgJars) {
    Copy-Item -LiteralPath $lib.FullName -Destination $TargetUnidbgDir -Force
}
$BundledCompanionFiles = @(Get-ChildItem -LiteralPath $TargetCompanionDir -Recurse -File)
Write-Host "  [+] Bundled companion-service.jar + $($CompanionLibJars.Count) runtime lib(s) + $($CompanionUnidbgJars.Count) guard-decrypt lib(s) ($($BundledCompanionFiles.Count) files total)." -ForegroundColor Green

Write-Host "  [*] Bundling embedded minimal JRE..." -ForegroundColor Cyan
$TargetRuntimeDir = [System.IO.Path]::GetFullPath((Join-Path $BuildOutputDir "runtime"))
$TargetJreDir = Join-Path $TargetRuntimeDir "jre"
if (-not $TargetJreDir.StartsWith([System.IO.Path]::GetFullPath($BuildOutputDir) + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Runtime cleanup target is outside the release directory: $TargetJreDir"
}
if (Test-Path -LiteralPath $TargetJreDir) {
    Remove-Item -LiteralPath $TargetJreDir -Recurse -Force
}
# invariant: 父目录必须已存在，避免 Copy-Item 将 jre 重命名为 runtime。
New-Item -ItemType Directory -Path $TargetRuntimeDir -Force | Out-Null
Copy-Item -LiteralPath $EmbeddedJre -Destination $TargetRuntimeDir -Recurse -Force
Write-Host "  [+] Bundled embedded JRE to release directory." -ForegroundColor Green

# Ensure dist directory exists
if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
}

# 4. Generate Portable ZIP
$PackageStage = Join-Path $ProjectRoot ("build/packaging/" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $PackageStage -Force | Out-Null
$Artifacts = @()
if (-not $SkipZip) {
    Write-Host "[4/5] Packaging Portable ZIP archive..." -ForegroundColor Yellow
    $ZipPath = Join-Path $PackageStage "xiugou-tv-windows-x64-v$Version-portable.zip"

    Compress-Archive -Path "$BuildOutputDir/*" -DestinationPath $ZipPath -CompressionLevel Optimal
    $Artifacts += $ZipPath
    Write-Host "  [+] Portable ZIP staged: $ZipPath" -ForegroundColor Green
} else {
    Write-Host "[4/5] Skipped Portable ZIP generation." -ForegroundColor DarkGray
}

# 5. Generate Inno Setup Installer
if (-not $SkipInstaller) {
    Write-Host "[5/5] Checking Inno Setup compiler (ISCC.exe)..." -ForegroundColor Yellow
    $IsccCandidates = @(
        "ISCC.exe",
        "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe",
        "${env:ProgramFiles}/Inno Setup 6/ISCC.exe",
        "${env:LOCALAPPDATA}/Programs/Inno Setup 6/ISCC.exe"
    )

    $IsccPath = $null
    foreach ($candidate in $IsccCandidates) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            $IsccPath = $candidate
            break
        }
        if (Test-Path $candidate) {
            $IsccPath = $candidate
            break
        }
    }

    if ($IsccPath) {
        Write-Host "  [+] Running Inno Setup: $IsccPath" -ForegroundColor Cyan
        & $IsccPath "/DAppVersion=$Version" "/DSourceDir=$BuildOutputDir" "/DOutputDir=$PackageStage" "$ScriptDir/installer.iss"
        if ($LASTEXITCODE -ne 0) {
            throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
        }
        $Artifacts += Join-Path $PackageStage "xiugou-tv-windows-x64-v$Version-setup.exe"
    } else {
        throw "ISCC.exe not found. Install Inno Setup or explicitly use -SkipInstaller."
    }
}

# invariant: 所有本轮请求的产物就绪前，不覆盖 dist 中的旧版本。
foreach ($artifact in $Artifacts) {
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
        throw "Build produced no artifact: $artifact"
    }
    if ((Get-Item -LiteralPath $artifact).Length -eq 0) {
        throw "Build produced an empty artifact: $artifact"
    }
}
foreach ($artifact in $Artifacts) {
    $destination = Join-Path $DistDir ([System.IO.Path]::GetFileName($artifact))
    Move-Item -LiteralPath $artifact -Destination $destination -Force
    Write-Host "  [+] Published artifact: $destination" -ForegroundColor Green
}
# 客户端强制校验：Release 必须带 SHA256SUMS（或资产自带 digest），
# 否则「检测更新」会拒绝安装。格式与 sha256sum 一致：<hex>  <filename>。
if ($Artifacts.Count -gt 0) {
    $SumsPath = Join-Path $DistDir "SHA256SUMS"
    $Sums = foreach ($artifact in $Artifacts) {
        $name = [System.IO.Path]::GetFileName($artifact)
        $published = Join-Path $DistDir $name
        $hash = (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    # invariant: 清单必须是 LF 换行，标准 `sha256sum -c` 才能直接消费；
    # Set-Content 在 Windows PowerShell 下写 CRLF，会把 \r 混进文件名。
    $SumsText = (($Sums -join "`n") + "`n")
    [System.IO.File]::WriteAllText($SumsPath, $SumsText, [System.Text.Encoding]::ASCII)
    Write-Host "  [+] Published checksums: $SumsPath" -ForegroundColor Green
}
if ($Artifacts.Count -eq 0) {
    Write-Host "  [*] Release bundled only; no distribution artifacts requested." -ForegroundColor Yellow
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Build completed successfully!" -ForegroundColor Green
Write-Host "  Artifacts directory: $DistDir" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Cyan
