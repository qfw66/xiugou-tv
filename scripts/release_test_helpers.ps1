# Helpers used by the release gate and its fixtures. No install/uninstall side effects.

function Get-ReleaseRegistryFingerprint([Microsoft.Win32.RegistryKey]$Key) {
    $values = @($Key.GetValueNames() | Sort-Object | ForEach-Object {
        [pscustomobject]@{ Name=$_; Kind=[string]$Key.GetValueKind($_)
            Value=$Key.GetValue($_, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    })
    $serialized = ConvertTo-Json -InputObject $values -Depth 8 -Compress
    $digest = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($serialized))).Replace('-', '') }
    finally { $digest.Dispose() }
}

function Get-ReleaseInstallRegistrations {
    # Preserve the shipped AppId, including its extra closing brace. Scan by GUID
    # so both historical spellings and both registry views are protected.
    $guid = 'E88D6F21-6A2F-4E8C-B8FB-5A86FA8F0C42'
    $parentPath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $parent = $base.OpenSubKey($parentPath)
                try {
                    if (-not $parent) { continue }
                    foreach ($name in $parent.GetSubKeyNames()) {
                        if ($name -notlike "*$guid*_is1") { continue }
                        $key = $parent.OpenSubKey($name)
                        try {
                            if (-not $key) { throw "Installation registration changed during inspection: $name" }
                            $fingerprint = Get-ReleaseRegistryFingerprint $key
                            [pscustomobject]@{
                                Hive = [string]$hive; View = [string]$view; Key = $name
                                InstallLocation = [string]$key.GetValue('InstallLocation')
                                UninstallString = [string]$key.GetValue('UninstallString')
                                Fingerprint = $fingerprint
                            }
                        } finally { if ($key) { $key.Dispose() } }
                    }
                } finally { if ($parent) { $parent.Dispose() } }
            } finally { $base.Dispose() }
        }
    }
}

function Assert-NoReleaseInstallConflict([object[]]$Registrations, [switch]$AllowMachineInstall) {
    $conflicts = @($Registrations | Where-Object {
        -not $AllowMachineInstall -or $_.Hive -ne 'LocalMachine' -or
        -not $_.Fingerprint -or -not $_.InstallLocation
    })
    if ($conflicts.Count -gt 0) {
        $locations = ($conflicts | ForEach-Object { "$($_.Hive)/$($_.View)/$($_.Key): $($_.InstallLocation)" }) -join '; '
        throw "Existing XiugouTV installation registration; refusing installer smoke and uninstall: $locations"
    }
}

function Assert-ReleaseMachineInstallPreserved([object[]]$Registrations, [object[]]$Expected, [string]$InstallRoot = '') {
    $current = @($Registrations | Where-Object { $_.Hive -eq 'LocalMachine' } | Sort-Object View, Key)
    $baseline = @($Expected | Sort-Object View, Key)
    if ((ConvertTo-Json -InputObject $current -Depth 8 -Compress) -cne
        (ConvertTo-Json -InputObject $baseline -Depth 8 -Compress)) {
        throw 'Machine installation registration changed; refusing uninstall.'
    }
    if ($InstallRoot) {
        Assert-PackagePathIsNotLinked $InstallRoot
        $testRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
        foreach ($registration in $baseline) {
            $existing = [IO.Path]::GetFullPath($registration.InstallLocation).TrimEnd('\', '/')
            Assert-PackagePathIsNotLinked $registration.InstallLocation
            if ($testRoot -ieq $existing -or $testRoot.StartsWith($existing + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $existing.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Temporary and existing installation directories overlap.'
            }
        }
    }
}

function Assert-ReleaseTestInstallOwner([object[]]$Registrations, [string]$InstallRoot, [object[]]$ProtectedMachine = @()) {
    Assert-ReleaseMachineInstallPreserved $Registrations $ProtectedMachine $InstallRoot
    $Registrations = @($Registrations | Where-Object { $_.Hive -ne 'LocalMachine' })
    if ($Registrations.Count -eq 0) { throw 'Temporary installation has no registration; refusing uninstall.' }
    $expectedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $expectedUninstaller = Join-Path $expectedRoot 'unins000.exe'
    foreach ($registration in $Registrations) {
        if ($registration.Hive -ne 'CurrentUser' -or -not $registration.InstallLocation -or
            [System.IO.Path]::GetFullPath($registration.InstallLocation).TrimEnd('\', '/') -ine $expectedRoot -or
            $registration.UninstallString.Trim('"') -ine $expectedUninstaller) {
            throw "Registration does not belong to this smoke installation; refusing uninstall: $($registration.Key)"
        }
    }
}

function New-ReleaseTestEnvironment([string]$TestRoot) {
    $testHome = Join-Path $TestRoot 'home'
    $appData = Join-Path $testHome 'AppData/Roaming'
    $localData = Join-Path $testHome 'AppData/Local'
    $tempDir = Join-Path $TestRoot 'temp'
    foreach ($dir in @($testHome, $appData, $localData, $tempDir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $systemDir = [Environment]::GetFolderPath('System')
    $drive = [System.IO.Path]::GetPathRoot($testHome).TrimEnd('\')
    @{
        PATH = "$systemDir;$env:SystemRoot;$systemDir\Wbem"
        APPDATA = $appData; LOCALAPPDATA = $localData; USERPROFILE = $testHome
        HOME = $testHome; HOMEDRIVE = $drive; HOMEPATH = $testHome.Substring($drive.Length)
        TEMP = $tempDir; TMP = $tempDir
        JAVA_HOME = $null; JRE_HOME = $null; JDK_HOME = $null; CLASSPATH = $null
        _JAVA_OPTIONS = $null; JDK_JAVA_OPTIONS = $null
        JAVA_TOOL_OPTIONS = "-Duser.home=`"$testHome`" -Djava.io.tmpdir=`"$tempDir`""
        PYTHONHOME = $null; PYTHONPATH = $null; PYTHONUSERBASE = $null
        PYTHONNOUSERSITE = '1'; PYTHONDONTWRITEBYTECODE = '1'
        VIRTUAL_ENV = $null; CONDA_PREFIX = $null
        NODE_PATH = $null; NODE_OPTIONS = $null; PHPRC = $null; PHP_INI_SCAN_DIR = $null
    }
}

function New-ReleaseWindowFixture([string]$Root, [string]$SmokeRoot) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $smokeFull = [System.IO.Path]::GetFullPath($SmokeRoot).TrimEnd('\', '/')
    if (-not $rootFull.StartsWith($smokeFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Window fixture must be inside a disposable smoke application tree.'
    }
    Assert-PackagePathIsNotLinked $rootFull
    $profile = Join-Path $rootFull 'user_data'
    if (Test-Path -LiteralPath $profile) { throw "Package already contains user_data; refusing to overwrite it: $profile" }
    [void][System.IO.Directory]::CreateDirectory($profile)
    $config = Join-Path $profile 'desktop_window.json'
    $poison = '{"width":158.0,"height":26.0,"posX":-32000.0,"posY":-32000.0,"isMaximized":false,"isFullScreen":false,"alwaysOnTop":false}'
    [System.IO.File]::WriteAllText($config, $poison, (New-Object System.Text.UTF8Encoding($false)))
    return $config
}

function Assert-ReleaseWindowRecovered([string]$ConfigPath) {
    $saved = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($null -eq $saved.width -or $null -eq $saved.height -or $saved.width -lt 320 -or $saved.height -lt 180 -or
        ($null -ne $saved.posX -and $saved.posX -le -10000) -or ($null -ne $saved.posY -and $saved.posY -le -10000)) {
        throw 'The actual user_data/desktop_window.json was not healed by the application.'
    }
    return "width=$($saved.width) height=$($saved.height) posX=$($saved.posX) posY=$($saved.posY); profile=$ConfigPath"
}
