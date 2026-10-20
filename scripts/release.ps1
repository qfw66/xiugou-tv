<#
.SYNOPSIS
    修狗TV 一键发布到 GitHub Releases。

.DESCRIPTION
    流程：完整打包 -> 校验 SHA256SUMS -> push 当前分支 -> 建 Release（先草稿）
          -> 上传 setup.exe / portable.zip / SHA256SUMS -> 发布。

    凭据二选一：
      1) GitHub CLI（推荐）：winget install --id GitHub.cli -e   然后 gh auth login
      2) 环境变量 GH_TOKEN（个人访问令牌，需 repo 权限）：setx GH_TOKEN ghp_xxx

.PARAMETER Version
    版本号，缺省取 pubspec.yaml 的 version 主版本（如 1.0.0）。

.PARAMETER Notes
    Release 说明正文；缺省自动生成下载/校验说明。

.PARAMETER NotesFile
    从文件读取 Release 说明，优先级高于 -Notes。

.PARAMETER Draft
    只建草稿，不自动发布（可在网页上检查后再点 Publish）。

.PARAMETER Prerelease
    标记为预发布。

.PARAMETER SkipBuild
    跳过打包，直接用 dist 里现有产物（会提示产物是否早于最后一次提交）。

.PARAMETER Force
    同名 Release 已存在时删除重建。

.PARAMETER DryRun
    只做本地检查并打印计划，不 push、不调 GitHub。

.EXAMPLE
    .\release.bat
    .\release.bat -Draft
    .\release.bat -SkipBuild
    .\release.bat -Version 1.0.1
#>
[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$Notes = "",
    [string]$NotesFile = "",
    [switch]$Draft,
    [switch]$Prerelease,
    [switch]$SkipBuild,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Net.ServicePointManager]::Expect100Continue = $false } catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir/..").Path
$DistDir = Join-Path $ProjectRoot "dist"

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "  [+] $Message" -ForegroundColor Green }
function Write-Note([string]$Message) { Write-Host "  [*] $Message" -ForegroundColor DarkGray }
function Fail([string]$Message) { throw $Message }

# 1. 版本号
if (-not $Version) {
    foreach ($line in (Get-Content -LiteralPath (Join-Path $ProjectRoot "pubspec.yaml") -TotalCount 12)) {
        if ($line -match '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { $Version = $Matches[1]; break }
    }
}
if (-not $Version) { Fail "无法确定版本号：请用 -Version 指定，或在 pubspec.yaml 写 version: x.y.z" }
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Fail "版本号格式应为 x.y.z：$Version" }

$Tag = "v$Version"
$ZipName = "xiugou-tv-windows-x64-v$Version-portable.zip"
$SetupName = "xiugou-tv-windows-x64-v$Version-setup.exe"
$ZipPath = Join-Path $DistDir $ZipName
$SetupPath = Join-Path $DistDir $SetupName
$SumsPath = Join-Path $DistDir "SHA256SUMS"

Write-Step "发布 修狗TV $Tag"

# 2. 打包
if ($SkipBuild) {
    Write-Note "跳过打包（-SkipBuild），使用 dist 现有产物"
} else {
    Write-Step "完整打包（Flutter + companion + 便携包 + 安装器）"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "build_windows.ps1") -Version $Version
    if ($LASTEXITCODE -ne 0) { Fail "打包失败（exit $LASTEXITCODE）" }
}

# 3. 产物与校验和
foreach ($file in @($ZipPath, $SetupPath, $SumsPath)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Fail "缺少产物：$file（先跑一次完整打包）" }
    if ((Get-Item -LiteralPath $file).Length -eq 0) { Fail "产物为空：$file" }
}

$expected = @{}
foreach ($line in (Get-Content -LiteralPath $SumsPath)) {
    $trimmed = $line.Trim()
    if (-not $trimmed) { continue }
    $m = [regex]::Match($trimmed, '^([0-9a-fA-F]{64})\s+\*?(.+)$')
    if ($m.Success) { $expected[$m.Groups[2].Value.Trim()] = $m.Groups[1].Value.ToLowerInvariant() }
}
foreach ($name in @($ZipName, $SetupName)) {
    if (-not $expected.ContainsKey($name)) { Fail "SHA256SUMS 里没有 $name" }
    $actual = (Get-FileHash -LiteralPath (Join-Path $DistDir $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected[$name]) { Fail "校验和不匹配：$name`n  清单=$($expected[$name])`n  实际=$actual" }
    $sizeMb = [math]::Round((Get-Item -LiteralPath (Join-Path $DistDir $name)).Length / 1MB, 1)
    Write-Ok "$name  sha256=$actual  ${sizeMb}MB"
}

# 4. Git 状态
$dirty = & git -C $ProjectRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0) { Fail "当前目录不是 git 仓库：$ProjectRoot" }
if ($dirty) { Fail "有未提交的已跟踪改动，先提交再发布：`n$dirty" }
$untracked = @(& git -C $ProjectRoot status --porcelain | Where-Object { $_ -like '??*' })
if ($untracked.Count -gt 0) {
    Write-Host "  [!] 存在未跟踪文件（不会随发布上传，但请确认不是遗漏的源码）：" -ForegroundColor Yellow
    $untracked | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
}

$branch = (& git -C $ProjectRoot rev-parse --abbrev-ref HEAD).Trim()
$sha = (& git -C $ProjectRoot rev-parse HEAD).Trim()
if ($branch -ne "main") { Write-Host "  [!] 当前分支是 $branch（不是 main）" -ForegroundColor Yellow }
Write-Note "commit $sha on $branch"

if ($SkipBuild) {
    # 产物是否比源码还旧：只比较真正的构建输入，避免 commit 时间（amend/rebase）造成误报。
    $sourceDirs = @("lib", "companion/src", "android-bridge/src", "scripts") |
        ForEach-Object { Join-Path $ProjectRoot $_ } |
        Where-Object { Test-Path -LiteralPath $_ }
    $newestSource = Get-ChildItem -LiteralPath $sourceDirs -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\build\*' -and $_.FullName -notlike '*\dist\*' -and $_.Name -ne 'release.ps1' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($newestSource) {
        foreach ($file in @($ZipPath, $SetupPath)) {
            if ((Get-Item -LiteralPath $file).LastWriteTime -lt $newestSource.LastWriteTime) {
                Write-Host "  [!] $([System.IO.Path]::GetFileName($file)) 早于源码 $($newestSource.Name) 的修改时间，可能不是最新代码构建的" -ForegroundColor Yellow
            }
        }
    }
}

# 5. 仓库与说明
$remote = (& git -C $ProjectRoot remote get-url origin).Trim()
if ($remote -notmatch 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') { Fail "无法从 origin 解析 owner/repo：$remote" }
$Owner = $Matches['owner']
$Repo = $Matches['repo']

if (-not $NotesFile) {
    if (-not $Notes) {
        $Notes = @"
## 修狗TV v$Version

### 下载
- ``$SetupName`` —— 安装版（需要管理员权限，装到 Program Files）
- ``$ZipName`` —— 便携版，解压即用（自带 JRE，无需另装 Java）

### 校验
下载 ``SHA256SUMS`` 后在同目录执行 ``sha256sum -c SHA256SUMS``；
Windows 可用 ``certutil -hashfile <文件名> SHA256`` 对照。
"@
    }
    $NotesFile = Join-Path $env:TEMP "xiugou-tv-release-notes-$Version.md"
    [System.IO.File]::WriteAllText($NotesFile, $Notes, (New-Object System.Text.UTF8Encoding($false)))
}
if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) { Fail "说明文件不存在：$NotesFile" }

# 6. 凭据探测（dry-run 不强制）
$GhCommand = Get-Command gh -ErrorAction SilentlyContinue
$Token = $env:GH_TOKEN
if (-not $Token) { $Token = $env:GITHUB_TOKEN }

if ($GhCommand) {
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if ($Token) { $GhCommand = $null } else { $GhCommand = $null; $GhAuthPending = $true }
    }
}
$UseGh = [bool]$GhCommand
$Assets = @($SetupPath, $ZipPath, $SumsPath)
$ReleaseUrl = "https://github.com/$Owner/$Repo/releases/tag/$Tag"

# 7. dry-run：只打印计划
if ($DryRun) {
    Write-Step "计划（dry-run，不执行）"
    Write-Note "git push origin HEAD:$branch"
    if ($UseGh) {
        Write-Note "通道：GitHub CLI"
        $plan = @("release", "create", $Tag, "--repo", "$Owner/$Repo", "--title", "修狗TV v$Version", "--notes-file", $NotesFile)
        if ($Draft) { $plan += "--draft" }
        if ($Prerelease) { $plan += "--prerelease" }
        $plan += $Assets
        Write-Note ("gh " + ($plan -join " "))
    } else {
        Write-Note "通道：REST API（GH_TOKEN）"
        Write-Note "POST https://api.github.com/repos/$Owner/$Repo/releases  tag=$Tag commit=$sha draft=$([bool]$Draft)"
        foreach ($asset in $Assets) { Write-Note ("upload " + [System.IO.Path]::GetFileName($asset)) }
    }
    Write-Note "说明文件：$NotesFile"
    return
}

if (-not $UseGh -and -not $Token) {
    Fail @"
没有可用的 GitHub 凭据，二选一：
  1) 安装并登录 GitHub CLI（推荐，只需一次）：
       winget install --id GitHub.cli -e
       gh auth login
  2) 设置个人访问令牌（需 repo 权限）后重开终端：
       setx GH_TOKEN ghp_xxxxxxxx
"@
}

# 8. 推送
Write-Step "推送到 origin/$branch"
& git -C $ProjectRoot push origin "HEAD:$branch"
if ($LASTEXITCODE -ne 0) { Fail "push 失败" }

# 9A. gh 通道
if ($UseGh) {
    if (-not $Force) {
        & gh release view $Tag --repo "$Owner/$Repo" *> $null
        if ($LASTEXITCODE -eq 0) { Fail "Release $Tag 已存在；加 -Force 覆盖，或先 gh release delete $Tag --cleanup-tag" }
    } else {
        & gh release delete $Tag --repo "$Owner/$Repo" --yes --cleanup-tag *> $null
    }

    $ghArgs = @("release", "create", $Tag, "--repo", "$Owner/$Repo", "--title", "修狗TV v$Version", "--notes-file", $NotesFile)
    if ($Draft) { $ghArgs += "--draft" }
    if ($Prerelease) { $ghArgs += "--prerelease" }
    $ghArgs += $Assets

    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) { Fail "gh release create 失败（exit $LASTEXITCODE）" }
    Write-Ok "Release 已创建：$ReleaseUrl"
    & git -C $ProjectRoot fetch origin --tags --quiet 2>&1 | Out-Null
    return
}

# 9B. REST 通道（GH_TOKEN）
$Headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "xiugou-tv-release"
}
$Api = "https://api.github.com/repos/$Owner/$Repo"

$existingId = $null
try {
    $existing = Invoke-RestMethod -Uri "$Api/releases/tags/$Tag" -Headers $Headers -Method Get -TimeoutSec 60
    $existingId = $existing.id
} catch { }

if ($existingId -and -not $Force) {
    Fail "Release $Tag 已存在（id=$existingId）；加 -Force 覆盖，或先删除"
}
if ($existingId -and $Force) {
    Invoke-RestMethod -Uri "$Api/releases/$existingId" -Headers $Headers -Method Delete -TimeoutSec 60 | Out-Null
    Write-Note "已删除旧 Release $Tag"
}

$body = [System.IO.File]::ReadAllText($NotesFile, [System.Text.Encoding]::UTF8)
$payload = @{
    tag_name         = $Tag
    target_commitish = $sha
    name             = "修狗TV v$Version"
    body             = $body
    draft            = $true
    prerelease       = [bool]$Prerelease
} | ConvertTo-Json -Depth 4

Write-Step "创建 Release（草稿）"
$release = Invoke-RestMethod -Uri "$Api/releases" -Headers $Headers -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 120

$uploadUrl = $release.upload_url -replace '\{.*\}$', ''
foreach ($asset in $Assets) {
    $assetName = [System.IO.Path]::GetFileName($asset)
    $sizeMb = [math]::Round((Get-Item -LiteralPath $asset).Length / 1MB, 1)
    Write-Step "上传 $assetName（${sizeMb}MB）"
    $uploaded = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $url = "$uploadUrl?name=$assetName"
            Invoke-WebRequest -Uri $url -Method Post -Headers $Headers -InFile $asset -ContentType "application/octet-stream" -UseBasicParsing -TimeoutSec 3600 | Out-Null
            $uploaded = $true
            Write-Ok "已上传 $assetName"
            break
        } catch {
            if ($attempt -eq 3) { Fail "上传 $assetName 失败：$($_.Exception.Message)" }
            Write-Host "  [!] 第 $attempt 次失败，3 秒后重试：$($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }
    }
    if (-not $uploaded) { Fail "上传 $assetName 失败" }
}

if ($Draft) {
    Write-Ok "草稿已保存（未发布）：https://github.com/$Owner/$Repo/releases"
} else {
    Write-Step "发布 Release"
    Invoke-RestMethod -Uri "$Api/releases/$($release.id)" -Headers $Headers -Method Patch -Body (@{ draft = $false } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 120 | Out-Null
    Write-Ok "Release 已发布：$ReleaseUrl"
}

& git -C $ProjectRoot fetch origin --tags --quiet 2>&1 | Out-Null
