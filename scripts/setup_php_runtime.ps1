# Installs a verified portable PHP CLI, never modifies PATH or an existing runtime.
param([string]$ArchivePath, [string]$CertificatePath)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$target = Join-Path $project 'companion/phpruntime'
if (Test-Path -LiteralPath $target) { throw "Runtime already exists: $target" }
$archiveName = 'php-8.3.36-1-nts-Win32-vs16-x64.zip'
$archiveHash = '1a097d52b7a68622cdc723073b61cc70caf79c941218ff65b2d8441dbc6b10d4'
$tempBase = if ($env:PI_SCRATCH_DIR) { $env:PI_SCRATCH_DIR } else { [IO.Path]::GetTempPath() }
$stage = Join-Path $tempBase ('xiugou-php-setup-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    if (-not $ArchivePath) {
        $ArchivePath = Join-Path $stage $archiveName
        Invoke-WebRequest -UseBasicParsing -Uri ("https://windows.php.net/downloads/releases/" + $archiveName) -OutFile $ArchivePath -TimeoutSec 180
    }
    if ((Get-FileHash -LiteralPath $ArchivePath).Hash.ToLowerInvariant() -ne $archiveHash) { throw 'PHP archive SHA256 mismatch' }
    if (-not $CertificatePath) {
        $CertificatePath = Join-Path $stage 'cacert.pem'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://curl.se/ca/cacert.pem' -OutFile $CertificatePath -TimeoutSec 60
        $published = (Invoke-WebRequest -UseBasicParsing -Uri 'https://curl.se/ca/cacert.pem.sha256' -TimeoutSec 30).Content
        $certificateHash = ([string]$published).Split(' ')[0].Trim()
        if ((Get-FileHash -LiteralPath $CertificatePath).Hash.ToLowerInvariant() -ne $certificateHash) { throw 'CA bundle SHA256 mismatch' }
    }
    $pem = [IO.File]::ReadAllText($CertificatePath)
    if ($pem -notmatch 'BEGIN CERTIFICATE' -or $pem -notmatch 'END CERTIFICATE') { throw 'CA bundle invalid' }
    $unpacked = Join-Path $stage 'runtime'
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $unpacked
    # Runtime and dependency notices are kept beside the executable. Development tools are unnecessary.
    $selected = Join-Path $stage 'selected'
    [IO.Directory]::CreateDirectory($selected) | Out-Null
    Get-ChildItem -LiteralPath $unpacked -File | Where-Object {
        $_.Extension -eq '.dll' -or $_.Name -in @('php.exe', 'license.txt', 'readme-redist-bins.txt', 'README.md', 'news.txt', 'snapshot.txt')
    } | Copy-Item -Destination $selected
    Copy-Item -LiteralPath (Join-Path $unpacked 'ext') -Destination $selected -Recurse
    Copy-Item -LiteralPath $CertificatePath -Destination (Join-Path $selected 'cacert.pem')
    # Child executables search their own directory for the Microsoft VC runtime.
    foreach ($crt in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')) {
        $source = Join-Path $project "build/windows/x64/runner/Release/$crt"
        if (-not (Test-Path -LiteralPath $source)) { $source = Join-Path ([Environment]::GetFolderPath('System')) $crt }
        if (-not (Test-Path -LiteralPath $source)) { throw "VC runtime missing: $crt" }
        Copy-Item -LiteralPath $source -Destination $selected
    }
    $modules = @(& (Join-Path $selected 'php.exe') -n -d ("extension_dir=" + (Join-Path $selected 'ext')) -d extension=curl -d extension=openssl -d extension=mbstring -d extension=sqlite3 -m)
    if ($LASTEXITCODE -ne 0) { throw 'PHP CLI module validation failed' }
    foreach ($module in @('curl', 'openssl', 'mbstring', 'sqlite3', 'dom')) { if ($modules -notcontains $module) { throw "PHP module missing: $module" } }
    $metadata = @{archive=$archiveName;archiveSha256=$archiveHash;caSha256=(Get-FileHash $CertificatePath).Hash.ToLowerInvariant();source='https://windows.php.net/downloads/releases/'}
    [IO.File]::WriteAllText((Join-Path $selected 'runtime-origin.json'),($metadata|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $selected -Destination $target
    Write-Output "PHP runtime installed: $target"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
