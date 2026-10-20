# Build script for Companion Service Jar
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir = Join-Path $scriptDir "src"
$libDir = Join-Path $scriptDir "lib"
# 加固壳自动解密用的 unidbg 依赖：只进编译期 classpath，不进主 jar（27 MB + 原生库），
# 运行时由 GuardPayloadProvisioner 以子进程方式使用 dist/lib-unidbg。
$unidbgDir = Join-Path $scriptDir "lib-unidbg"
$outDir = Join-Path $scriptDir "build"
$distDir = Join-Path $scriptDir "dist"
$jarPath = Join-Path $distDir "companion-service.jar"

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
if (!(Test-Path $distDir)) {
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# invariant: dist 里只允许存在一份正式产物 companion-service.jar。
# jar 先写成 companion-service-<guid>.jar 再改名，构建被中断就会留下 ~36 MB 的孤儿文件；
# 这些残渣随后会被打包步骤整目录带进发布包（曾把便携包撑到 684 MB），所以每次构建先清场。
Get-ChildItem -LiteralPath $distDir -Filter 'companion-service-*.jar' -File -ErrorAction SilentlyContinue |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Host "Removed stale pending jar: $($_.Name)"
    }

$compileJars = @()
$compileJars += Get-ChildItem -Path $libDir -Filter "*.jar" -ErrorAction SilentlyContinue
if (Test-Path $unidbgDir) {
    $compileJars += Get-ChildItem -Path $unidbgDir -Filter "*.jar" -ErrorAction SilentlyContinue
}
$classpath = ($compileJars | ForEach-Object { $_.FullName }) -join [System.IO.Path]::PathSeparator
$sep = [System.IO.Path]::PathSeparator

# 两个模块，两个源码目录，同一个输出目录（产物仍是自包含单 jar）：
#   android-bridge/  = 可复用的桥接内核（android.* shim / CatVod 契约 / 载荷加载 / RPC）
#   companion/       = 修狗TV 桌面端的启动壳（Main + 打包 + 运行时依赖）
$bridgeDir = Join-Path (Split-Path -Parent $scriptDir) "android-bridge"
$bridgeSrcDir = Join-Path $bridgeDir "src"
if (!(Test-Path $bridgeSrcDir)) {
    throw "android-bridge module not found: $bridgeSrcDir"
}

Write-Host "Compiling android-bridge (runtime / crawler / host)..."
$bridgeFiles = Get-ChildItem -Path $bridgeSrcDir -Filter "*.java" -Recurse | ForEach-Object { $_.FullName }
if ($classpath) {
    & javac -encoding UTF-8 -cp $classpath -d $outDir $bridgeFiles
} else {
    & javac -encoding UTF-8 -d $outDir $bridgeFiles
}
if ($LASTEXITCODE -ne 0) {
    throw "javac (android-bridge) failed with exit code $LASTEXITCODE"
}

Write-Host "Compiling Companion Service Java sources..."
$javaFiles = Get-ChildItem -Path $srcDir -Filter "*.java" -Recurse | ForEach-Object { $_.FullName }
$serviceClasspath = "$outDir$sep$classpath"
& javac -encoding UTF-8 -cp $serviceClasspath -d $outDir $javaFiles
if ($LASTEXITCODE -ne 0) {
    throw "javac (companion) failed with exit code $LASTEXITCODE"
}

# Produce a self-contained jar because the desktop launcher invokes java -jar.
$oldLocation = Get-Location
$dependencyRoot = Join-Path $outDir "_deps"
$serviceContents = @{}
try {
    if (Test-Path $dependencyRoot) { Remove-Item -Recurse -Force $dependencyRoot }
    New-Item -ItemType Directory -Force -Path $dependencyRoot | Out-Null
    foreach ($lib in (Get-ChildItem -Path $libDir -Filter "*.jar" -ErrorAction SilentlyContinue)) {
        $depDir = Join-Path $dependencyRoot ([System.IO.Path]::GetFileNameWithoutExtension($lib.Name))
        New-Item -ItemType Directory -Force -Path $depDir | Out-Null
        Set-Location $depDir
        & jar xf $lib.FullName
        if ($LASTEXITCODE -ne 0) { throw "Failed to unpack dependency $($lib.Name)" }
        Set-Location $oldLocation
        # Android 语义的 org.json（companion/lib/android-json-*.jar）必须胜出。
        # 载荷爬虫按 Android 的 JSONObject.getString() 语义取字段：Integer 会自动转成
        # 字符串（"0" / "447407"）。标准 JSON-java（json-20231013.jar）遇到非 String
        # 直接抛 JSONException("... is not a string")，会让整站返回 0 分类 / 空数据。
        if ($lib.Name -like 'json-2*') {
            $jsonPkg = Join-Path $depDir 'org'
            if (Test-Path $jsonPkg) { Remove-Item -Recurse -Force $jsonPkg }
        }
        Copy-Item -Path (Join-Path $depDir "*") -Destination $outDir -Recurse -Force
        $serviceDir = Join-Path $depDir "META-INF/services"
        if (Test-Path $serviceDir) {
            foreach ($serviceFile in (Get-ChildItem -Path $serviceDir -File)) {
                if (-not $serviceContents.ContainsKey($serviceFile.Name)) { $serviceContents[$serviceFile.Name] = [System.Collections.Generic.List[string]]::new() }
                foreach ($line in (Get-Content $serviceFile.FullName)) {
                    if ($line.Trim() -and -not $serviceContents[$serviceFile.Name].Contains($line.Trim())) { [void]$serviceContents[$serviceFile.Name].Add($line.Trim()) }
                }
            }
        }
    }
    $mergedServiceDir = Join-Path $outDir "META-INF/services"
    New-Item -ItemType Directory -Force -Path $mergedServiceDir | Out-Null
    foreach ($name in $serviceContents.Keys) {
        [System.IO.File]::WriteAllLines((Join-Path $mergedServiceDir $name), $serviceContents[$name])
    }
} finally {
    Set-Location $oldLocation
    if (Test-Path $dependencyRoot) { Remove-Item -Recurse -Force $dependencyRoot }
}

Write-Host "Packaging companion-service.jar..."
$manifestContent = @"
Manifest-Version: 1.0
Main-Class: com.fongmi.companion.Main

"@
$manifestFile = Join-Path $outDir "MANIFEST.MF"
[System.IO.File]::WriteAllText($manifestFile, $manifestContent, [System.Text.Encoding]::ASCII)

# invariant: 只发布本次 jar 命令的新文件，失败时保留上一份可用 JAR。
# pending jar 放在同一磁盘的 dist 下，Move-Item 才是原子改名；try/finally 保证异常路径也不留残渣。
$pendingJarPath = Join-Path $distDir ("companion-service-" + [Guid]::NewGuid().ToString('N') + ".jar")
try {
    & jar cfm $pendingJarPath $manifestFile -C $outDir .
    if ($LASTEXITCODE -ne 0) {
        throw "jar failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path -LiteralPath $pendingJarPath -PathType Leaf)) {
        throw "Failed to produce $pendingJarPath"
    }
    if ((Get-Item -LiteralPath $pendingJarPath).Length -eq 0) {
        throw "Produced an empty JAR: $pendingJarPath"
    }
    Move-Item -LiteralPath $pendingJarPath -Destination $jarPath -Force
} finally {
    if (Test-Path -LiteralPath $pendingJarPath) {
        Remove-Item -LiteralPath $pendingJarPath -Force -ErrorAction SilentlyContinue
    }
}

# 复制运行时依赖（如 BouncyCastle）：需保持独立 jar（签名保留），与主 jar 并列
$libsDir = Join-Path $scriptDir "libs"
if (Test-Path $libsDir) {
    Get-ChildItem -Path $libsDir -Filter "*.jar" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName -Destination $distDir -Force
        Write-Host "Copied runtime lib: $($_.Name)"
    }
}
Write-Host "Successfully built: $jarPath"

# 加固壳自动解密依赖（unidbg + unicorn）：放到 dist/lib-unidbg，由解密子进程按 classpath 引用。
# 刻意不并进主 jar：原生库 + 27 MB 会拖慢常驻服务启动，且只有首次解密才用得上。
if (Test-Path $unidbgDir) {
    $unidbgDist = Join-Path $distDir "lib-unidbg"
    New-Item -ItemType Directory -Force -Path $unidbgDist | Out-Null
    $unidbgJars = Get-ChildItem -Path $unidbgDir -Filter "*.jar" -ErrorAction SilentlyContinue
    foreach ($lib in $unidbgJars) {
        Copy-Item $lib.FullName -Destination $unidbgDist -Force
    }
    Write-Host "Copied guard-decrypt libs: $($unidbgJars.Count) jar(s) -> $unidbgDist"
} else {
    Write-Host "WARN: 缺少 $unidbgDir，加固站点将无法自动解密（退回 SpiderNull）"
}
