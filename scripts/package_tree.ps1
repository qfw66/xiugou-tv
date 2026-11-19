# Shared, path-only selection for Windows release packaging. Dot-source this file.
# Only the selected files are ever opened/copied; excluded directories are not traversed.

function Assert-PackagePathIsNotLinked([string]$Path) {
    $current = [System.IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Package path is a symlink/junction/reparse point: $current"
            }
        }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
}

function Get-PackageRequiredEntries {
    @(
        'xiugou_tv.exe', 'flutter_windows.dll', 'libmpv-2.dll',
        'libEGL.dll', 'libGLESv2.dll', 'd3dcompiler_47.dll',
        'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
        'data/app.so', 'data/icudtl.dat',
        'data/flutter_assets/AssetManifest.bin', 'data/flutter_assets/FontManifest.json',
        'data/flutter_assets/fonts/MaterialIcons-Regular.otf', 'data/flutter_assets/NOTICES.Z',
        'runtime/jre/bin/java.exe', 'runtime/jre/bin/server/jvm.dll', 'runtime/jre/lib/modules',
        'runtime/jre/legal/java.base/LICENSE', 'runtime/jre/legal/java.base/COPYRIGHT',
        'companion/dist/companion-service.jar', 'companion/dist/pyshell/runner.py',
        'companion/dist/pyruntime/python.exe', 'companion/dist/pyruntime/LICENSE.txt',
        'companion/dist/noderuntime/node.exe', 'companion/dist/noderuntime/LICENSE',
        'companion/dist/phpruntime/php.exe', 'companion/dist/phpruntime/php8.dll',
        'companion/dist/phpruntime/license.txt', 'companion/dist/phpruntime/readme-redist-bins.txt',
        'companion/dist/phpruntime/cacert.pem', 'companion/dist/phpruntime/ext/php_curl.dll',
        'companion/dist/phpruntime/ext/php_mbstring.dll', 'companion/dist/phpruntime/ext/php_openssl.dll',
        'companion/dist/phpruntime/ext/php_sqlite3.dll', 'companion/dist/phpruntime/ext/php_sockets.dll',
        'companion/dist/phpruntime/ext/php_pdo_sqlite.dll', 'companion/dist/phpruntime/ext/php_pdo_mysql.dll',
        'companion/dist/phpruntime/ext/php_mysqli.dll'
    )
}

function Get-PackagePathDisposition([string]$RelativePath, [bool]$IsDirectory) {
    # These are application-generated roots, not generic names filtered at every depth.
    if ($IsDirectory -and $RelativePath -match '^(user_data|logs|cache|\.xiugou_tv_companion)$') { return 'Exclude' }
    if ($IsDirectory -and $RelativePath -match '^companion/dist/(pyshell|pyruntime)/(.*/)?(__pycache__|\.pytest_cache)$') { return 'Exclude' }
    if (-not $IsDirectory -and $RelativePath -match '^(companion/dist/)?[^/]+\.(log|dmp)$') { return 'Exclude' }
    if (-not $IsDirectory -and $RelativePath -match '(^|/)(hs_err_pid[0-9]+|replay_pid[0-9]+)\.log$') { return 'Exclude' }
    if (-not $IsDirectory -and $RelativePath -match '^companion/dist/phpruntime/(php_errors\.log|error_log)$') { return 'Exclude' }
    # The pinned ANGLE archive also ships an unused debug zlib.dll (VCRUNTIME140D).
    # No ANGLE/media module imports it. The package PE gate must fail if a future
    # dependency begins importing zlib, instead of publishing a debug runtime.
    if (-not $IsDirectory -and $RelativePath -ieq 'zlib.dll') { return 'Exclude' }

    # Unexpected credentials/source-control material must be reviewed, never silently omitted.
    # Do not ban *.pem, config, cache.py, tests, or all bytecode: runtimes need these.
    if ($RelativePath -match '(^|/)(\.env(\.[^/]*)?|\.git|\.ssh|\.aws|id_rsa|id_ed25519)(/|$)') { return 'Unknown' }
    $license = '(LICENSES?|LICENCE|COPYING|COPYRIGHT|NOTICE|THIRD[_-]PARTY[_-]NOTICES)([._-][^/]+)?'
    if ($IsDirectory) {
        if ($RelativePath -match '^(data|data/flutter_assets(/.*)?|companion|companion/dist|runtime|runtime/jre)$') { return 'Include' }
        if ($RelativePath -match '^companion/dist/(lib-unidbg|noderuntime|phpruntime|pyshell|pyruntime)(/.*)?$') { return 'Include' }
        if ($RelativePath -match '^runtime/jre/(bin|conf|legal|lib)(/.*)?$') { return 'Include' }
        if ($RelativePath -match '^(licenses|legal)(/.*)?$') { return 'Include' }
    } else {
        if ($RelativePath -match '^(xiugou_tv\.exe|[^/]+\.dll|native_assets\.json)$' -or $RelativePath -match "^$license$") { return 'Include' }
        if ($RelativePath -match '^data/(app\.so|icudtl\.dat|flutter_assets/.+)$') { return 'Include' }
        if ($RelativePath -match '^companion/dist/[^/]+\.jar$' -or $RelativePath -match "^companion/dist/$license$") { return 'Include' }
        if ($RelativePath -match '^companion/dist/(lib-unidbg|noderuntime|phpruntime|pyshell|pyruntime)/.+$') { return 'Include' }
        if ($RelativePath -match '^runtime/jre/(release|(bin|conf|legal|lib)/.+)$' -or $RelativePath -match "^runtime/jre/$license$") { return 'Include' }
        if ($RelativePath -match '^(licenses|legal)/.+$') { return 'Include' }
    }
    return 'Unknown'
}

function Get-PackageSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [switch]$RejectExcluded,
        [switch]$Installed
    )
    $root = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\', '/')
    Assert-PackagePathIsNotLinked $root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Package source directory missing: $root" }
    $files = New-Object 'System.Collections.Generic.List[string]'
    $excluded = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($root)
    while ($pending.Count -gt 0) {
        foreach ($item in (Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop)) {
            $rel = $item.FullName.Substring($root.Length + 1).Replace('\', '/')
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Package path is a symlink/junction/reparse point: $rel"
            }
            # Inno creates these itself; they are never accepted as application inputs.
            if ($Installed -and -not $item.PSIsContainer -and $rel -match '^unins000\.(exe|dat|msg)$') { continue }
            $disposition = Get-PackagePathDisposition $rel $item.PSIsContainer
            if ($disposition -eq 'Unknown') { throw "Unknown package path (review the application roots): $rel" }
            if ($disposition -eq 'Exclude') {
                if ($RejectExcluded) { throw "Generated state/cache/log in clean package: $rel" }
                $excluded.Add($rel)
                continue
            }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) } else { $files.Add($rel) }
        }
    }
    $files.Sort([System.StringComparer]::Ordinal)
    $excluded.Sort([System.StringComparer]::Ordinal)
    [pscustomobject]@{ Root = $root; Files = $files.ToArray(); Excluded = $excluded.ToArray() }
}

function Assert-PackageRuntimeFiles($Selection) {
    $present = @{}
    foreach ($rel in $Selection.Files) { $present[$rel] = $true }
    foreach ($rel in (Get-PackageRequiredEntries)) {
        if (-not $present.ContainsKey($rel)) { throw "Required package runtime missing: $rel" }
        if ((Get-Item -LiteralPath (Join-Path $Selection.Root $rel)).Length -eq 0) { throw "Required package runtime empty: $rel" }
    }
    foreach ($pattern in @('companion/dist/bcprov-*.jar', 'companion/dist/lib-unidbg/*.jar', '*_plugin.dll')) {
        if (@($Selection.Files | Where-Object { $_ -like $pattern }).Count -eq 0) { throw "Required package runtime missing: $pattern" }
    }
}

function New-StagedApplicationTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$StageDir
    )
    $source = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\', '/')
    $stage = [System.IO.Path]::GetFullPath($StageDir).TrimEnd('\', '/')
    if ($source -eq $stage -or $stage.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $source.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Application stage and source must be separate, non-overlapping trees.'
    }
    Assert-PackagePathIsNotLinked $stage
    if (Test-Path -LiteralPath $stage) { throw "Application stage must be new (no cleanup/overwrite): $stage" }
    $selection = Get-PackageSelection -SourceDir $source
    Assert-PackageRuntimeFiles $selection
    [void][System.IO.Directory]::CreateDirectory($stage)
    foreach ($rel in $selection.Files) {
        $destination = Join-Path $stage $rel
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
        Copy-Item -LiteralPath (Join-Path $source $rel) -Destination $destination -ErrorAction Stop
    }
    [pscustomobject]@{ Root = $stage; Files = $selection.Files; Excluded = $selection.Excluded }
}

function Write-PackageInnoFileList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )
    $selection = Get-PackageSelection -SourceDir $StageDir -RejectExcluded
    Assert-PackageRuntimeFiles $selection
    $destination = [System.IO.Path]::GetFullPath($DestinationPath)
    if ($destination.StartsWith($selection.Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Inno file list must be outside the application tree.' }
    if (Test-Path -LiteralPath $destination) { throw "Inno file list already exists: $destination" }
    $lines = foreach ($rel in $selection.Files) {
        $windowsRel = $rel.Replace('/', '\').Replace('{', '{{')
        $parent = [System.IO.Path]::GetDirectoryName($windowsRel)
        $destDir = if ($parent) { '{app}\' + $parent } else { '{app}' }
        'Source: "{#SourceDir}\' + $windowsRel + '"; DestDir: "' + $destDir + '"; Flags: ignoreversion'
    }
    [System.IO.File]::WriteAllLines($destination, [string[]]$lines, (New-Object System.Text.UTF8Encoding($true)))
}

function Assert-PackageMatchesStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$PackageDir,
        [switch]$Installed
    )
    $expected = Get-PackageSelection -SourceDir $StageDir -RejectExcluded
    $actual = Get-PackageSelection -SourceDir $PackageDir -RejectExcluded -Installed:$Installed
    Assert-PackageRuntimeFiles $expected
    $difference = @(Compare-Object -ReferenceObject $expected.Files -DifferenceObject $actual.Files)
    if ($difference.Count -gt 0) { throw "Package file set differs from stage: $(($difference | Select-Object -First 8 | ForEach-Object { $_.InputObject }) -join ', ')" }
    foreach ($rel in $expected.Files) {
        $a = Get-FileHash -LiteralPath (Join-Path $expected.Root $rel) -Algorithm SHA256
        $b = Get-FileHash -LiteralPath (Join-Path $actual.Root $rel) -Algorithm SHA256
        if ($a.Hash -ne $b.Hash) { throw "Package hash differs from stage: $rel" }
    }
    return $expected.Files.Count
}
