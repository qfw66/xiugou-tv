<#
.SYNOPSIS
    Fixture-only packaging regression. Never builds, launches, installs, or uninstalls the app.
.PARAMETER ScratchRoot
    Existing scratch directory; all fixtures are created in a fresh child directory.
#>
param([Parameter(Mandatory = $true)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'package_tree.ps1')
. (Join-Path $PSScriptRoot 'client_build_config.ps1')
. (Join-Path $PSScriptRoot 'release_test_helpers.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetFullPath($ScratchRoot)) ('packaging-fixtures-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $testRoot 'source'
$stage = Join-Path $testRoot 'stage'
[void][System.IO.Directory]::CreateDirectory($source)
$checks = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Wrong failure, expected '$Pattern': $($_.Exception.Message)" }
        $script:checks++
        return
    }
    throw "Expected failure matching '$Pattern'"
}
function Write-Fixture([string]$Root, [string]$RelativePath, [string]$Content = 'fixture-runtime') {
    $path = Join-Path $Root $RelativePath
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
    [System.IO.File]::WriteAllText($path, $Content)
}

# Explicit fixture inventory: retain native assets, arbitrary plugin DLLs, runtime
# configuration, CA certificates, bytecode-only modules, and third-party legal files.
$runtimeFiles = @(
    'xiugou_tv.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'libEGL.dll', 'libGLESv2.dll', 'd3dcompiler_47.dll',
    'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'new_feature_plugin.dll', 'dartjni.dll', 'native_assets.json',
    'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin', 'data/flutter_assets/FontManifest.json',
    'data/flutter_assets/NOTICES.Z', 'data/flutter_assets/fonts/MaterialIcons-Regular.otf',
    'data/flutter_assets/assets/config.json', 'data/flutter_assets/assets/example.log',
    'companion/dist/companion-service.jar', 'companion/dist/bcprov-jdk18on-1.78.1.jar', 'companion/dist/another-runtime.jar',
    'companion/dist/lib-unidbg/unidbg-android.jar', 'companion/dist/lib-unidbg/jna.jar',
    'companion/dist/noderuntime/node.exe', 'companion/dist/noderuntime/LICENSE', 'companion/dist/noderuntime/provenance.json',
    'companion/dist/phpruntime/php.exe', 'companion/dist/phpruntime/php8.dll', 'companion/dist/phpruntime/license.txt',
    'companion/dist/phpruntime/readme-redist-bins.txt', 'companion/dist/phpruntime/cacert.pem',
    'companion/dist/phpruntime/ext/php_curl.dll', 'companion/dist/phpruntime/ext/php_mbstring.dll',
    'companion/dist/phpruntime/ext/php_openssl.dll', 'companion/dist/phpruntime/ext/php_sqlite3.dll',
    'companion/dist/phpruntime/ext/php_sockets.dll', 'companion/dist/phpruntime/ext/php_pdo_sqlite.dll',
    'companion/dist/phpruntime/ext/php_pdo_mysql.dll', 'companion/dist/phpruntime/ext/php_mysqli.dll',
    'companion/dist/phpruntime/libcrypto-3-x64.dll', 'companion/dist/phpruntime/php.ini-production',
    'companion/dist/pyshell/runner.py', 'companion/dist/pyshell/base/spider.py',
    'companion/dist/pyruntime/python.exe', 'companion/dist/pyruntime/python314.dll',
    'companion/dist/pyruntime/python314.zip', 'companion/dist/pyruntime/python314._pth', 'companion/dist/pyruntime/LICENSE.txt',
    'companion/dist/pyruntime/Lib/site-packages/pkg/cache.py', 'companion/dist/pyruntime/Lib/site-packages/pkg/only_bytecode.pyc',
    'companion/dist/pyruntime/Lib/site-packages/pkg/cacert.pem', 'companion/dist/pyruntime/Lib/site-packages/pkg-1.dist-info/licenses/LICENSE',
    'runtime/jre/bin/java.exe', 'runtime/jre/bin/server/jvm.dll', 'runtime/jre/lib/modules', 'runtime/jre/lib/security/cacerts',
    'runtime/jre/conf/security/java.security', 'runtime/jre/legal/java.base/LICENSE', 'runtime/jre/legal/java.base/COPYRIGHT',
    'runtime/jre/legal/java.base/third-party.md', 'runtime/jre/release', 'LICENSE.txt', 'licenses/mpv/COPYING'
)
foreach ($rel in $runtimeFiles) { Write-Fixture $source $rel }
$generatedFiles = @(
    'user_data/desktop_window.json', 'user_data/webdav_connections.bin', 'user_data/private/never-copy.env',
    'logs/companion.log', 'cache/download.jar', '.xiugou_tv_companion/jars/private.jar',
    'hs_err_pid123.log', 'replay_pid123.log', 'xiugou_tv.exe.dmp', 'companion/dist/companion.log',
    'companion/dist/phpruntime/php_errors.log', 'companion/dist/pyshell/base/__pycache__/spider.cpython-314.pyc',
    'companion/dist/pyruntime/Lib/site-packages/pkg/__pycache__/cache.cpython-314.pyc',
    'companion/dist/pyshell/.pytest_cache/private-token', 'zlib.dll'
)
foreach ($rel in $generatedFiles) { Write-Fixture $source $rel 'fixture-private-state' }
# An exclusive file handle makes accidental copying/hashing of user_data fail.
$privatePath = Join-Path $source 'user_data/webdav_connections.bin'
$privateLock = [System.IO.File]::Open($privatePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    $first = Get-PackageSelection $source
    $second = Get-PackageSelection $source
    Assert-True (($first.Files -join "`n") -ceq ($second.Files -join "`n")) 'Selection order is unstable.'
    Assert-True ($first.Files.Count -eq $runtimeFiles.Count) 'Selection lost runtime files or included private state.'
    $expectedOrder = [string[]]$runtimeFiles.Clone()
    [Array]::Sort($expectedOrder, [StringComparer]::Ordinal)
    Assert-True (($first.Files -join "`n") -ceq ($expectedOrder -join "`n")) 'Selection is not sorted by ordinal relative path.'
    $result = New-StagedApplicationTree -SourceDir $source -StageDir $stage
    foreach ($rel in $runtimeFiles) { Assert-True (Test-Path -LiteralPath (Join-Path $stage $rel) -PathType Leaf) "Runtime file lost: $rel" }
    foreach ($rel in $generatedFiles) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage $rel))) "Generated state leaked: $rel" }
    Assert-True ($result.Excluded -contains 'user_data') 'user_data exclusion was not reported.'
} finally { $privateLock.Dispose() }
Assert-True (([System.IO.File]::ReadAllText($privatePath)) -eq 'fixture-private-state') 'Source profile changed.'
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $source 'user_data') -File -Recurse).Count -eq 3) 'Source profile file set changed.'

$innoList = Join-Path $testRoot 'application-files.iss'
Write-PackageInnoFileList -StageDir $stage -DestinationPath $innoList
$innoText = [System.IO.File]::ReadAllText($innoList)
Assert-True (($innoText -split "`r?`n" | Where-Object { $_ }).Count -eq $runtimeFiles.Count) 'Inno file set does not match stage.'
Assert-True ($innoText -notmatch 'user_data|__pycache__|recursesubdirs|\\\*') 'Inno includes state or a recursive wildcard.'
foreach ($rel in $runtimeFiles) { Assert-True ($innoText.Contains('{#SourceDir}\' + $rel.Replace('/', '\') + '"')) "Inno omitted $rel" }
Assert-Throws { New-StagedApplicationTree $source $stage } 'must be new'
Assert-Throws { New-StagedApplicationTree $source (Join-Path $source 'nested') } 'non-overlapping'
Assert-Throws { New-StagedApplicationTree $source $source } 'non-overlapping'

foreach ($unexpected in @('secrets/token.txt', 'future-runtime.bin', 'companion/dist/private-config.json', 'data/flutter_assets/.env', 'companion/dist/phpruntime/.env.local')) {
    Write-Fixture $source $unexpected 'secret-fixture'
    $rejectedStage = Join-Path $testRoot 'must-not-be-created'
    Assert-Throws { New-StagedApplicationTree $source $rejectedStage } 'Unknown package path'
    Assert-True (-not (Test-Path -LiteralPath $rejectedStage)) 'Failed selection partially staged files.'
    Remove-Item -LiteralPath (Join-Path $source $unexpected) -Force
    if ($unexpected -like 'secrets/*') { Remove-Item -LiteralPath (Join-Path $source 'secrets') -Force }
}
$bcprov = Join-Path $source 'companion/dist/bcprov-jdk18on-1.78.1.jar'
Remove-Item -LiteralPath $bcprov
Assert-Throws { New-StagedApplicationTree $source (Join-Path $testRoot 'missing-runtime') } 'Required package runtime missing'
Write-Fixture $source 'companion/dist/bcprov-jdk18on-1.78.1.jar'

# Junctions require no symlink privilege and exercise the same rejection before traversal.
$linkPath = Join-Path $source 'data/flutter_assets/linked'
New-Item -ItemType Junction -Path $linkPath -Value (Join-Path $source 'user_data') | Out-Null
try { Assert-Throws { Get-PackageSelection $source } 'symlink/junction/reparse point' }
finally { [System.IO.Directory]::Delete($linkPath) }
# PowerShell 5.1's New-Item requires elevation even when Windows Developer Mode
# permits symlinks. Use the native unprivileged flag for this fixture only.
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class PackagingFixtureLinks {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool CreateSymbolicLink(string link, string target, uint flags);
}
'@
$symlinkCreated = [PackagingFixtureLinks]::CreateSymbolicLink($linkPath, (Join-Path $source 'user_data'), 3)
if (-not $symlinkCreated) { Write-Host "SYMLINK FIXTURE UNAVAILABLE: Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()); junction regression passed." }
if ($symlinkCreated) {
    try { Assert-Throws { Get-PackageSelection $source } 'symlink/junction/reparse point' }
    finally { [System.IO.Directory]::Delete($linkPath) }
}
# A linked path inside the excluded profile must not be visited at all.
$linkPath = Join-Path $source 'user_data/ignored-link'
New-Item -ItemType Junction -Path $linkPath -Value $stage | Out-Null
try { Assert-True ((Get-PackageSelection $source).Files.Count -eq $runtimeFiles.Count) 'Profile was traversed.' }
finally { [System.IO.Directory]::Delete($linkPath) }

$copy = New-StagedApplicationTree $stage (Join-Path $testRoot 'package-copy')
Assert-True ((Assert-PackageMatchesStage $stage $copy.Root) -eq $runtimeFiles.Count) 'Clean stage comparison failed.'
Write-Fixture $copy.Root 'companion/dist/phpruntime/ext/php_curl.dll' 'fixture-runtimX'
Assert-Throws { Assert-PackageMatchesStage $stage $copy.Root } 'hash differs'
Write-Fixture $copy.Root 'companion/dist/phpruntime/ext/php_curl.dll'
Write-Fixture $copy.Root 'unexpected.dll'
Assert-Throws { Assert-PackageMatchesStage $stage $copy.Root } 'file set differs'
Remove-Item -LiteralPath (Join-Path $copy.Root 'unexpected.dll')
Write-Fixture $copy.Root 'unins000.exe'
Write-Fixture $copy.Root 'unins000.dat'
Assert-Throws { Assert-PackageMatchesStage $stage $copy.Root } 'Unknown package path'
Assert-True ((Assert-PackageMatchesStage $stage $copy.Root -Installed) -eq $runtimeFiles.Count) 'Installer metadata should be the only allowed extra files.'
Write-Fixture $copy.Root 'user_data/leaked.json'
Assert-Throws { Assert-PackageMatchesStage $stage $copy.Root -Installed } 'Generated state/cache/log'

$smoke = Join-Path $testRoot 'smoke'
$smokeApp = Join-Path $smoke 'portable'
[void][System.IO.Directory]::CreateDirectory($smokeApp)
$windowConfig = New-ReleaseWindowFixture -Root $smokeApp -SmokeRoot $smoke
Assert-True ($windowConfig -eq (Join-Path $smokeApp 'user_data/desktop_window.json')) 'Wrong active window profile path.'
Assert-Throws { Assert-ReleaseWindowRecovered $windowConfig } 'was not healed'
Assert-Throws { New-ReleaseWindowFixture $smokeApp $smoke } 'already contains user_data'
Assert-Throws { New-ReleaseWindowFixture $stage $smoke } 'disposable smoke'
[System.IO.File]::WriteAllText($windowConfig, '{"width":1280,"height":720,"posX":100,"posY":100}')
Assert-ReleaseWindowRecovered $windowConfig | Out-Null
Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage 'user_data'))) 'Window fixture polluted the stage.'

# Pure registry fixtures: exercise both AppId spellings, hives and views without writes.
$ownedRoot = Join-Path $smoke 'installed'
Assert-NoReleaseInstallConflict @()
foreach ($hive in @('CurrentUser', 'LocalMachine')) {
    foreach ($view in @('Registry32', 'Registry64')) {
        foreach ($key in @('{E88D6F21-6A2F-4E8C-B8FB-5A86FA8F0C42}_is1', '{E88D6F21-6A2F-4E8C-B8FB-5A86FA8F0C42}}_is1')) {
            $registration = [pscustomobject]@{ Hive=$hive; View=$view; Key=$key; InstallLocation='C:\real-install'; UninstallString='"C:\real-install\unins000.exe"' }
            Assert-Throws { Assert-NoReleaseInstallConflict @($registration) } 'Existing XiugouTV installation'
            Assert-Throws { Assert-ReleaseTestInstallOwner @($registration) $ownedRoot } 'refusing uninstall'
        }
    }
}
$owned = [pscustomobject]@{Hive='CurrentUser';View='Registry64';Key='fixture';InstallLocation=$ownedRoot;UninstallString=('"' + (Join-Path $ownedRoot 'unins000.exe') + '"')}
Assert-ReleaseTestInstallOwner @($owned) $ownedRoot
Assert-Throws { Assert-ReleaseTestInstallOwner @() $ownedRoot } 'no registration'
$owned.UninstallString = '"C:\real-install\unins000.exe"'
Assert-Throws { Assert-ReleaseTestInstallOwner @($owned) $ownedRoot } 'refusing uninstall'

# An explicitly selected /CURRENTUSER run can coexist with a fingerprinted HKLM
# installation, but never with an existing HKCU install or an overlapping path.
$machine = [pscustomobject]@{Hive='LocalMachine';View='Registry64';Key='machine';InstallLocation='C:\real-install';UninstallString='"C:\real-install\unins000.exe"';Fingerprint='BEFORE'}
Assert-NoReleaseInstallConflict @($machine) -AllowMachineInstall
$owned.UninstallString = '"' + (Join-Path $ownedRoot 'unins000.exe') + '"'
Assert-ReleaseTestInstallOwner @($machine, $owned) $ownedRoot @($machine)
Assert-True $true 'Current-user test install has separate ownership.'
Assert-Throws { Assert-NoReleaseInstallConflict @($machine, $owned) -AllowMachineInstall } 'Existing XiugouTV installation'
Assert-Throws { Assert-ReleaseMachineInstallPreserved @($machine) @($machine) 'C:\real-install\child' } 'overlap'
Assert-Throws { Assert-ReleaseMachineInstallPreserved @($machine) @($machine) 'C:\' } 'overlap'
Assert-Throws { Assert-ReleaseMachineInstallPreserved @() @($machine) } 'registration changed'
$changedMachine = [pscustomobject]@{Hive='LocalMachine';View='Registry64';Key='machine';InstallLocation='C:\real-install';UninstallString='"C:\real-install\unins000.exe"';Fingerprint='AFTER'}
Assert-Throws { Assert-ReleaseTestInstallOwner @($changedMachine, $owned) $ownedRoot @($machine) } 'registration changed'
Assert-Throws { Assert-ReleaseTestInstallOwner @($machine) $ownedRoot @($machine) } 'no registration'
$unfingerprinted = [pscustomobject]@{Hive='LocalMachine';View='Registry64';Key='machine';InstallLocation='C:\real-install';UninstallString='"C:\real-install\unins000.exe"';Fingerprint=''}
Assert-Throws { Assert-NoReleaseInstallConflict @($unfingerprinted) -AllowMachineInstall } 'Existing XiugouTV installation'

# Reject physical aliases before installer launch, not only during package reads.
$installAlias = Join-Path $testRoot 'install-alias'
$aliasTarget = Join-Path $testRoot 'protected-install'
New-Item -ItemType Directory -Path $aliasTarget | Out-Null
New-Item -ItemType Junction -Path $installAlias -Target $aliasTarget | Out-Null
try {
    Assert-Throws { Assert-ReleaseMachineInstallPreserved @() @() (Join-Path $installAlias 'child') } 'reparse point'
    $linkedMachine = [pscustomobject]@{Hive='LocalMachine';View='Registry64';Key='linked';InstallLocation=$installAlias;UninstallString='fixture';Fingerprint='fixture'}
    Assert-Throws { Assert-ReleaseMachineInstallPreserved @($linkedMachine) @($linkedMachine) $ownedRoot } 'reparse point'
} finally { (Get-Item -LiteralPath $installAlias -Force).Delete() }

# Exercise a real disposable key; fingerprints must use stored REG_EXPAND_SZ
# bytes, independent of the isolated environment. Never touch uninstall keys.
$fixtureKeyName = 'Software\XiugouTV-Packaging-Test-' + [Guid]::NewGuid().ToString('N')
$fixtureKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fixtureKeyName)
$savedFixtureEnv = $env:XIUGOU_PACKAGING_FIXTURE
try {
    $env:XIUGOU_PACKAGING_FIXTURE = 'before'
    $fixtureKey.SetValue('expanded', '%XIUGOU_PACKAGING_FIXTURE%\path', [Microsoft.Win32.RegistryValueKind]::ExpandString)
    $fingerprintBefore = Get-ReleaseRegistryFingerprint $fixtureKey
    $env:XIUGOU_PACKAGING_FIXTURE = 'after'
    Assert-True ((Get-ReleaseRegistryFingerprint $fixtureKey) -eq $fingerprintBefore) 'Expanded environment changed raw registry fingerprint.'
    $fixtureKey.SetValue('expanded', 'after\path', [Microsoft.Win32.RegistryValueKind]::ExpandString)
    Assert-True ((Get-ReleaseRegistryFingerprint $fixtureKey) -ne $fingerprintBefore) 'Different raw values with equal expansion compare equal.'
} finally {
    $fixtureKey.Dispose()
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($fixtureKeyName)
    $env:XIUGOU_PACKAGING_FIXTURE = $savedFixtureEnv
}

$environment = New-ReleaseTestEnvironment (Join-Path $smoke 'environment')
Assert-True ($environment.PATH -eq ([Environment]::GetFolderPath('System') + ';' + $env:SystemRoot + ';' + [Environment]::GetFolderPath('System') + '\Wbem')) 'Developer PATH leaked.'
foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'TEMP', 'TMP')) { Assert-True ($environment[$name].StartsWith($smoke + '\')) "$name is not isolated." }
foreach ($name in @('JAVA_HOME', 'PYTHONPATH', 'PYTHONHOME', 'NODE_PATH', 'NODE_OPTIONS', 'PHPRC', '_JAVA_OPTIONS')) { Assert-True ($null -eq $environment[$name]) "$name can load developer dependencies." }
$powerShellExe = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$savedPath = $env:PATH
try {
    $env:PATH = $environment.PATH
    & $powerShellExe -NoProfile -NonInteractive -Command 'exit 0'
    Assert-True ($LASTEXITCODE -eq 0) 'Absolute PowerShell invocation failed under isolated PATH.'
} finally { $env:PATH = $savedPath }

$mdkFiles = @('mdk/mdk.dll','mdk/ffmpeg-9.dll','mdk/Xiugou-MDK-SDK-notice.txt')
Assert-Throws { New-StagedApplicationTree $source (Join-Path $testRoot 'no-sdk') -IncludeMdk } 'Required package runtime missing: mdk/'
foreach ($rel in $mdkFiles) { Write-Fixture $source $rel }
$mdkStage = New-StagedApplicationTree $source (Join-Path $testRoot 'mdk-default')
$mdkCopy = New-StagedApplicationTree $mdkStage.Root (Join-Path $testRoot 'mdk-explicit') -IncludeMdk
Assert-True ((Assert-PackageMatchesStage $mdkStage.Root $mdkCopy.Root -IncludeMdk) -eq ($runtimeFiles.Count + 3)) 'MDK assets missing.'
Assert-True ((Assert-PackageMatchesStage $mdkStage.Root $mdkCopy.Root) -eq ($runtimeFiles.Count + 3)) 'Automatic MDK validation failed.'
$legacyMdkCopy = New-StagedApplicationTree $mdkStage.Root (Join-Path $testRoot 'mdk-legacy-copy') -LocalMdkPreview
Assert-True ((Assert-PackageMatchesStage $mdkStage.Root $legacyMdkCopy.Root) -eq ($runtimeFiles.Count + 3)) 'Legacy MDK switch alias failed.'
$mdkList = Join-Path $testRoot 'mdk-files.iss'
Write-PackageInnoFileList $mdkStage.Root $mdkList -IncludeMdk
foreach ($rel in $mdkFiles) { Assert-True ([IO.File]::ReadAllText($mdkList).Contains($rel.Replace('/','\'))) "Inno missing: $rel" }
Write-Fixture $source 'mdk/other.dll'
Assert-Throws { New-StagedApplicationTree $source (Join-Path $testRoot 'unlisted-sdk') -IncludeMdk } 'Unknown package path'

$configFile = Join-Path $testRoot 'app.env'
$aotFixture = Join-Path $testRoot 'app.so'
$configRows = @('XIUGOU_TMDB_API_KEY=0123456789abcdef0123456789abcdef','XIUGOU_DANMAKU_URL="https://fixture.invalid/d"','XIUGOU_DANMAKU_TOKEN="dm#test"','XIUGOU_SEGMENTS_URL=https://fixture.invalid/s','XIUGOU_SEGMENTS_TOKEN=sg_test')
foreach ($row in $configRows) {
    [IO.File]::WriteAllLines($configFile, @($configRows -ne $row) + ($row.Split('=')[0] + '=""'))
    Assert-Throws { Get-PackageClientConfig $configFile } $row.Split('=')[0]
}
[IO.File]::WriteAllLines($configFile, $configRows)
$config = Get-PackageClientConfig $configFile
Assert-True ($config.Count -eq 5 -and $config.XIUGOU_DANMAKU_TOKEN -ceq 'dm#test') 'Wrong client config.'
[IO.File]::WriteAllText($aotFixture, ($config.Values -ne 'sg_test' -join ';'))
Assert-Throws { Assert-PackageClientConfig $config $aotFixture } 'XIUGOU_SEGMENTS_TOKEN'
[IO.File]::AppendAllText($aotFixture, 'sg_test')
Assert-PackageClientConfig $config $aotFixture

Write-Host "PASS: $checks packaging fixture assertions. Actual symbolic link tested: $symlinkCreated. Fixtures: $testRoot"
