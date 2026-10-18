# 修狗TV（xiugou-tv）

面向 Windows 10/11 x64 的影视桌面客户端：导入用户提供的影视配置，浏览、搜索、选集播放，并提供直播、媒体直链、本地文件与 NAS 媒体入口。采用 Flutter / Dart、Riverpod、media_kit / libmpv，以及本地 Java Companion。

## 项目结构

```text
lib/                Flutter 界面、配置、播放、直播与 Companion 通信
windows/            Windows 原生宿主、CMake 配置与应用图标
android-bridge/     Android 爬虫 → JVM 桥接内核（运行时 shim / CatVod 契约 / 载荷加载 / RPC）
companion/          Java 侧启动壳、打包脚本与构建期依赖（lib / libs / lib-unidbg）
scripts/            Windows 打包、JRE 生成与图标闸门
```

> 本仓库只收录「clone 后即可构建」的最小集合：Dart 测试、抓取产物、探针脚本与内部记录
> 均不随仓库发布。

`android-bridge/` 的分层契约、必守陷阱（Android 语义 `org.json`、ext 解密映射、
jlink 模块、PKCS7 Provider 等）与验收基线见 [`android-bridge/README.md`](android-bridge/README.md)。

### 1. 准备工具

- Windows 10/11 x64。
- Flutter SDK：当前 `pubspec.lock` 要求 **Flutter ≥ 3.44.0、Dart ≥ 3.12.0**，不能只按 `pubspec.yaml` 中较低的声明选择 SDK。
- Visual Studio 的“使用 C++ 的桌面开发”工作负载与 Windows SDK。
- 建议使用 x64 JDK 21，并将同一 JDK 的 `java`、`javac`、`jar`、`jlink` 加入 `PATH`。
- 生成安装器时另需 Inno Setup 6；只生成便携 ZIP 不需要。

### 2. 依赖

**当前仓库已内置全部构建期依赖**（40 个固定版本 JAR，共约 95 MB）：

| 目录 | 用途 | 数量 |
|---|---|---|
| `companion/lib/` | `javac` 的 classpath，并被打进自包含 `companion-service.jar`（ASM、dex2jar、OkHttp、Gson/JSON、jsoup、NanoHTTPD、GraalVM JS 等） | 24 |
| `companion/libs/` | 运行时并列依赖（BouncyCastle，PKCS7 需保留独立 jar 的签名） | 1 |
| `companion/lib-unidbg/` | 加固壳解密的子进程依赖（unidbg / unicorn / capstone / keystone / JNA 等） | 15 |

完整性清单见 [`companion/deps.manifest.json`](companion/deps.manifest.json)（路径 / 字节数 / SHA256）。
**不需要再手动下载**；升级依赖时替换同名文件并同步更新清单即可。各依赖保留其上游许可。

> 下面的下载脚本仅保留为「校验或补回单个 JAR」的参考，正常构建不需要执行。

```powershell
$ErrorActionPreference = 'Stop'
$dependencies = [ordered]@{ 
    'org/graalvm/sdk/collections/24.1.2/collections-24.1.2.jar' = 'cb4046c0ca469961b93d6159f87ae17ff449847a3677ffdde59ba09091bf1d84'
    'org/graalvm/shadowed/icu4j/24.1.2/icu4j-24.1.2.jar' = '94edfff5952b411837699810afa1efb3b5254ffecb752df8e12646d24e557970'
    'org/graalvm/js/js-language/24.1.2/js-language-24.1.2.jar' = 'c5c8bc278119f818587ab07416717f10f855c43a6885ecf1e9c7cab70eb76b3c'
    'org/jsoup/jsoup/1.18.3/jsoup-1.18.3.jar' = '5be1ccd3228ae5fd6eed1bd6d827bac2bc65b91c20e9957d16ea65f739f15302'
    'org/graalvm/sdk/nativeimage/24.1.2/nativeimage-24.1.2.jar' = '3ceb688a0f75009d14c2f4b2f624420347acd3df824550144ba8f02dd247fcdd'
    'org/graalvm/polyglot/polyglot/24.1.2/polyglot-24.1.2.jar' = '6da3fe42a16a6d670c3458462df9a8b1f2198783e22819ffcb6f575ba19d5f6e'
    'org/graalvm/regex/regex/24.1.2/regex-24.1.2.jar' = 'f54d2e8c04e457e14ea7ecabacef355af14f9dfd25259326b64aa5cbc53afcbb'
    'org/graalvm/truffle/truffle-api/24.1.2/truffle-api-24.1.2.jar' = 'fd884a7c6b2f8a09bc1bace45d8af42dab02dca38e11c92f43e408b490bd60a3'
}
$libDir = Join-Path (Get-Location) 'companion/lib'
New-Item -ItemType Directory -Force -Path $libDir | Out-Null
foreach ($entry in $dependencies.GetEnumerator()) {
    $file = Join-Path $libDir ($entry.Key.Split('/')[-1])
    if (-not (Test-Path -LiteralPath $file)) {
        Invoke-WebRequest -UseBasicParsing `
            -Uri ("https://repo.maven.apache.org/maven2/" + $entry.Key) `
            -OutFile $file
    }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Value) {
        throw "JAR checksum mismatch: $file"
    }
}
```

已有文件会跳过下载但仍校验。若下载中断或校验失败，核对并移走对应损坏文件后再重试；不要跳过校验。离线环境可复制同版本的这 8 个 JAR 到 `companion/lib/`，再执行同一段命令校验。

### 3. 启动开发版本

> 首次构建需联网一次：`media_kit` 的 Windows 插件会下载 `mpv-dev-*.7z` 与 `ANGLE.7z`
> 到 `build/windows/x64/`（之后走本地缓存）。Flutter 依赖同理需要 `flutter pub get`。

```powershell
flutter doctor -v
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
powershell -NoProfile -File .\companion\build.ps1
if ($LASTEXITCODE -ne 0) { throw 'Companion build failed' }
flutter run -d windows
```

开发时可使用系统 Java，无需提交或预先生成 `runtime/jre/`。使用 `flutter analyze` 进行静态检查。部分测试会访问真实端点、连接 Java 服务或读写应用数据，执行前应准备对应依赖并隔离 `%APPDATA%/XiugouTV`；不要把直接执行全部测试视为纯离线验证。

### 4. 生成 Windows 便携包

先完成 Java 依赖恢复，再执行：

```powershell
if (-not (Test-Path -LiteralPath .\runtime\jre)) {
    powershell -NoProfile -File .\scripts\create_minimal_jre.ps1
    if ($LASTEXITCODE -ne 0) { throw 'JRE generation failed' }
}
powershell -NoProfile -File .\scripts\build_windows.ps1 -Version 1.0.0 -SkipInstaller
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
```

`create_minimal_jre.ps1` 会删除已有目标后重建，因此示例只在目录不存在时执行；已有 JRE 的重建应先确认路径。打包会检查 JRE、构建 Flutter 和 Companion，并将本次发布包输出到 `dist/`。需要安装器时安装 Inno Setup 6 后去掉 `-SkipInstaller`。仅执行 `flutter build windows --release` 不会补齐 Companion / JRE。

## 许可证与上游来源

本项目依据 **GNU General Public License v3.0（GPL v3）** 发布，完整条款见 [LICENSE](LICENSE)。许可证全文与上游 [FongMi/TV 的 LICENSE.md](https://github.com/FongMi/TV/blob/fongmi/LICENSE.md) 保持一致。

上游项目：[FongMi/TV](https://github.com/FongMi/TV)。本仓库包含面向 Windows 的 Flutter 桌面界面与 Java Companion 适配，并非上游的未修改副本；上游代码的版权及许可声明应予保留，版权归各自权利人所有。

本项目不提供适销性、特定用途适用性等保证，具体以许可证中的免责声明为准。
