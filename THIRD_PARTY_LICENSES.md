# 第三方组件与许可

本仓为「clone 下来即可构建」，因此**随源码分发**了一批第三方二进制（Java jar，部分内含原生库）。
这些组件**不适用**本项目的 GPL-3.0，各自保留上游许可；本文件是它们的署名清单。

- 生成方式：本地脚本读取每个 jar 的 `META-INF/maven/**/pom.properties`、`META-INF/MANIFEST.MF`
  与内嵌 `LICENSE*`，逐条列出「依据」；**无法从仓内证实的条目明确标为「待核实」**，不做推测。
- Java 组件沿用 2026-11-18 核对的 **43 个 JAR**；v1.2.0 候选使用已提交的 `companion/deps.manifest.json`，不纳入工作区未提交的 SQLite／转换器试验。v1.2.0 的 MDK／FFmpeg 分发边界见 §2.1。
- 上游许可原文以各项目仓库为准；本文件只做转载与指向。

## 1. 构建与分发使用的 Java 二进制（`companion/`，43 个 JAR）

### 1.1 `companion/lib-unidbg/`（15 个 · unidbg 运行时）

| 文件 | 上游坐标 | 许可 | 依据 |
| --- | --- | --- | --- |
| `apk-parser-2.6.10.jar` | `net.dongliu:apk-parser:2.6.10` | Apache-2.0 | 上游声明；jar 内无许可文件（待核实） |
| `capstone-3.1.8.jar` | `com.github.zhkl0228:capstone:3.1.8`（内含原生 `capstone.dll/.so/.dylib`） | Java 绑定 Apache-2.0；Capstone 原生 BSD-3-Clause | 原生库随 jar 分发，许可见上游（待核实） |
| `commons-codec-1.21.0.jar` | `commons-codec:commons-codec:1.21.0` | Apache-2.0 | jar 内 `META-INF/LICENSE.txt`（首行 "Apache License, Version 2.0"） |
| `commons-collections4-4.5.0.jar` | `org.apache.commons:commons-collections4:4.5.0` | Apache-2.0 | 同上 |
| `commons-io-2.21.0.jar` | `commons-io:commons-io:2.21.0` | Apache-2.0 | 同上 |
| `demumble-1.0.4.jar` | `com.github.zhkl0228:demumble:1.0.4` | Apache-2.0 | 上游声明（待核实） |
| `fastjson-1.2.83.jar` | `com.alibaba:fastjson:1.2.83` | Apache-2.0 | jar 内 `META-INF/LICENSE.txt` |
| `jna-5.14.0.jar` | `net.java.dev.jna:jna:5.14.0` | **Apache-2.0 或 LGPL-2.1（双许可，任选其一）** | jar 内 `META-INF/LICENSE` 原文：`SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1` |
| `jna-platform-5.14.0.jar` | `net.java.dev.jna:jna-platform:5.14.0` | 同上 | 同上 |
| `keystone-0.9.7.jar` | `com.github.zhkl0228:keystone:0.9.7`（内含原生 `keystone.dll/.so/.dylib`） | Java 绑定 Apache-2.0；**Keystone 原生引擎为 GPL-2.0 系** | 见 §4.1（待核实） |
| `slf4j-api-2.0.16.jar` | `org.slf4j:slf4j-api:2.0.16` | MIT | jar 内 `META-INF/LICENSE.txt`（QOS.ch 的 MIT 式条文） |
| `slf4j-simple-2.0.16.jar` | `org.slf4j:slf4j-simple:2.0.16` | MIT | 同上 |
| `unicorn-1.0.15.jar` | `com.github.zhkl0228:unicorn:1.0.15`（内含原生 `unicorn_java.dll/.so/.dylib`） | Java 绑定 Apache-2.0；**Unicorn 引擎为 GPL-2.0 系** | 见 §4.1（待核实） |
| `unidbg-android-0.9.9.jar` | `com.github.zhkl0228:unidbg-android:0.9.9` | Apache-2.0 | 上游声明（待核实） |
| `unidbg-api-0.9.9.jar` | `com.github.zhkl0228:unidbg-api:0.9.9` | Apache-2.0 | 上游声明（待核实） |

### 1.2 `companion/lib/`（27 个）

| 文件 | 上游坐标 / 名称 | 许可 | 依据 |
| --- | --- | --- | --- |
| `android-json-0.0.20131108.vaadin1.jar` | `com.vaadin.external.google:android-json:0.0.20131108.vaadin1` | Apache-2.0 | 对应版本 Maven Central POM 的许可证声明，见 §4.2 |
| `asm-9.8.jar` / `asm-analysis` / `asm-commons` / `asm-tree` / `asm-util` | `org.ow2.asm:asm*:9.8` | BSD-3-Clause | jar 内 MANIFEST：`Bundle-License: BSD-3-Clause;link=https://asm.ow2.io/LICENSE.txt` |
| `collections-24.1.2.jar` / `js-language` / `nativeimage` / `polyglot` / `regex` / `truffle-api` | GraalVM JS（MANIFEST: `Implementation-Vendor: Oracle Corporation`） | UPL 1.0（上游声明） | 待核实 |
| `core-3.5.3.jar` | `com.google.zxing:core:3.5.3`（ZXing，载荷生成登录二维码用；FongMi 宿主同样内置） | Apache-2.0 | jar 内 MANIFEST：`Bundle-License: "The Apache Software License, Version 2.0"` |
| `dex-ir-2.4.31.jar` / `dex-reader` / `dex-reader-api` / `dex-translator` / `dex-writer` | dex2jar（`com.github.pxb1988`） | Apache-2.0（上游声明） | 待核实 |
| `gson-2.11.0.jar` | `com.google.code.gson:gson:2.11.0` | Apache-2.0 | 对应版本 JAR/Maven 元数据；构建期清单已从旧 2.10.1 更新为 2.11.0 |
| `icu4j-24.1.2.jar` | `com.ibm.icu:icu4j:24.1.2` | Unicode License v3 | jar 内 `LICENSE`（首行 "UNICODE LICENSE V3"） |
| `json-20231013.jar` | `org.json:json:20231013` | Public Domain | 对应版本 Maven Central POM 的许可证声明，见 §4.2 |
| `jsoup-1.18.3.jar` | `org.jsoup:jsoup:1.18.3` | MIT | jar 内 `META-INF/LICENSE`（"The MIT License"） |
| `nanohttpd-2.3.1.jar` | `org.nanohttpd:nanohttpd:2.3.1` | BSD-3-Clause | jar 内 `LICENSE.txt`（三条款 BSD 正文） |
| `okhttp-3.12.1.jar` | `com.squareup.okhttp3:okhttp:3.12.1` | Apache-2.0 | 上游声明（待核实） |
| `okio-1.17.5.jar` | `com.squareup.okio:okio:1.17.5` | Apache-2.0 | 上游声明（待核实） |
| `smbj-0.13.0.jar` | `com.hierynomus:smbj:0.13.0` | Apache-2.0 | 对应版本 Maven Central POM；许可原文随伴随 JAR 的 `licenses/smbj-0.13.0/LICENSE.txt` 分发 |
| `commons-lang3-3.18.0.jar` | `org.apache.commons:commons-lang3:3.18.0` | Apache-2.0 | 原 JAR 的 `META-INF/LICENSE.txt` / `NOTICE.txt`；伴随 JAR 保留在 `licenses/commons-lang3-3.18.0/` |

### 1.3 `companion/libs/`（1 个）

| 文件 | 上游坐标 | 许可 | 依据 |
| --- | --- | --- | --- |
| `bcprov-jdk18on-1.78.1.jar` | `org.bouncycastle:bcprov-jdk18on:1.78.1` | Bouncy Castle License（MIT 式） | jar 内含 `org/bouncycastle/LICENSE.class`，字符串含 "Copyright (c) 2000-2023 The Legion of the Bouncy Castle Inc." |

## 2. 不随仓分发、由构建或运行时获取

| 组件 | 获取方式 | 许可 |
| --- | --- | --- |
| JRE（`runtime/jre`，构建期由 `jlink` 生成） | 本机 JDK，构建脚本产物，**不入仓** | 随所选 JDK 发行版（通常 GPL-2.0 + Classpath Exception） |
| mpv / FFmpeg / ANGLE（媒体运行时） | `media_kit_libs_windows_video` 首次构建时下载 `mpv-dev`、`ANGLE` 归档，**不入仓** | 取决于其构建配置（LGPL-2.1+ 或 GPL-2.0+）；以该归档自带许可为准 |
| Dart / Flutter 包（`pubspec.yaml` 声明的依赖） | 经 `pub` 获取，**不入仓**；每个包在 pub 缓存内自带 `LICENSE` | 逐包不同；已核实 `media_kit` = MIT |
| Node.js（猫源运行时） | 构建时随包放置在 `companion/dist/noderuntime` | MIT 及所含第三方条款，随包 `LICENSE` |
| CPython（Python 站源运行时） | 随包放置在 `companion/dist/pyruntime` | PSF 及所含第三方条款，随发行版许可文件 |
| PHP 8.3.36 NTS x64（PHP 站源运行时） | `scripts/setup_php_runtime.ps1` 校验下载后随包放置在 `companion/dist/phpruntime` | PHP License 3.01；扩展与 redist 见随包 `license.txt`、`readme-redist-bins.txt` |
| Mozilla CA 证书集 | PHP HTTPS 使用随包 `cacert.pem`，由 curl 官方 CA 提取服务获取 | Mozilla CA 数据条款，来源 `https://curl.se/docs/caextract.html` |
| MDK 0.40.1（可选 Windows 播放内核） | 入选时随包放在 `mdk/`，含 `mdk.dll` 与 SDK 通知 | MDK SDK 条款（见 §2.1）；本项目为 GPL-3.0 开源软件，按上游"opensource 免费"条款使用 |
| MDK 的 `ffmpeg-9.dll` | 随 MDK 以独立 DLL 动态加载 | LGPL-2.1-or-later；对应源码按书面提供方式给出，见 §2.1 |
| Windows Media Foundation | 使用 Windows 系统组件，包内只有本项目接口实现 | 系统组件由 Windows 提供，不将系统 DLL 随包再分发 |

> §1 的 43 个 JAR 是构建/分发输入；§2 的运行时由构建工具获取并随 Windows 二进制包分发，是否进入源码仓库是另一回事。安装包与便携包均应保留对应许可文件。

### 2.1 v1.2.0 可选原生播放器的分发边界

- MDK SDK 0.40.1 的授权依据：上游通知原文「Free for opensource softwares, non-commercial softwares, flutter, QtAV donors and contributors.」，原文随包保留在 `mdk/Xiugou-MDK-SDK-notice.txt`。本项目以 GPL-3.0 开源发布，按该条款使用；本清单不把 SDK 重新声明为 GPL-3.0。
- `ffmpeg-9.dll` 报告 LGPL version 2.1 or later，构建标识 `git-2026-10-25-464fc8c-avbuild`。**书面提供**：对应源码为 FFmpeg 提交 `464fc8c2ed53`（<https://github.com/FFmpeg/FFmpeg/tree/464fc8c2ed53>），Windows 构建脚本见 <https://github.com/wang-bin/avbuild>；自本版发布起三年内，向持有本发行版者提供上述源码副本（含所用构建配置），索取方式见仓库 Issue。许可全文随包在 `licenses/FFmpeg-COPYING.LGPLv2.1`。
- MDK 以独立 DLL 动态加载 `ffmpeg-9.dll`，用户可用兼容构建直接替换该 DLL，无需重新链接本程序，满足 LGPL 的可替换要求。
- MDK 的 FFmpeg 与默认 mpv 的 FFmpeg 是不同构建，不互相推断许可；各自保留上游通知与许可文件。PGS 独立预览内核未替换本版标准 mpv。

## 3. 已核实的许可文件位置（便于复查）

```
companion/lib-unidbg/commons-codec-1.21.0.jar    → META-INF/LICENSE.txt   (Apache-2.0)
companion/lib-unidbg/commons-collections4-4.5.0.jar → META-INF/LICENSE.txt (Apache-2.0)
companion/lib-unidbg/commons-io-2.21.0.jar       → META-INF/LICENSE.txt   (Apache-2.0)
companion/lib-unidbg/fastjson-1.2.83.jar         → META-INF/LICENSE.txt   (Apache-2.0)
companion/lib-unidbg/jna-5.14.0.jar              → META-INF/LICENSE       (Apache-2.0 OR LGPL-2.1)
companion/lib-unidbg/jna-platform-5.14.0.jar     → META-INF/LICENSE       (同上)
companion/lib-unidbg/slf4j-api-2.0.16.jar        → META-INF/LICENSE.txt   (MIT)
companion/lib-unidbg/slf4j-simple-2.0.16.jar     → META-INF/LICENSE.txt   (MIT)
companion/lib/asm-9.8.jar                        → META-INF/MANIFEST.MF   (BSD-3-Clause)
companion/lib/core-3.5.3.jar                     → META-INF/MANIFEST.MF   (Apache-2.0)
companion/lib/icu4j-24.1.2.jar                   → LICENSE                (UNICODE LICENSE V3)
companion/lib/jsoup-1.18.3.jar                   → META-INF/LICENSE       (MIT)
companion/lib/nanohttpd-2.3.1.jar                → LICENSE.txt            (BSD-3-Clause)
companion/libs/bcprov-jdk18on-1.78.1.jar         → org/bouncycastle/LICENSE.class（字符串）
```

## 4. 两处待确认（仅提示，本文件不下结论）

### 4.1 Unicorn / Keystone 的原生引擎与本项目 GPL-3.0 的兼容性

`unicorn-1.0.15.jar`、`keystone-0.9.7.jar` 内**直接包含原生库**（`unicorn_java.dll`、`keystone.dll` 等），
随仓分发。这两个引擎的上游主体是 **GPL-2.0 系**：

- 若上游表述为 **GPL-2.0-only**，与 GPL-3.0 项目**不兼容**，需要处理（换上游 / 换成外部依赖 / 不在仓内分发）；
- 若为 **GPL-2.0-or-later**，则与 GPL-3.0 兼容，无需处理。

这两项是历史待核实项：应按实际分发版本和所含原生引擎的许可原文确认，不能仅用 Java 绑定的许可推断原生引擎许可。当前清单保留该边界，不将它们标为本次已核实。

### 4.2 JSON 组件的版本级核对

2026-11-18 重新读取 Maven Central 对应版本的 POM 后，纠正旧清单把两者笼统写成 JSON License 的表述：

- `com.vaadin.external.google:android-json:0.0.20131108.vaadin1` 声明 **Apache License 2.0**。
- `org.json:json:20231013` 声明 **Public Domain**。

依据分别为 `https://repo.maven.apache.org/maven2/com/vaadin/external/google/android-json/0.0.20131108.vaadin1/android-json-0.0.20131108.vaadin1.pom` 与 `https://repo.maven.apache.org/maven2/org/json/json/20231013/json-20231013.pom`。这是这两个指定版本的声明，不能外推到其它版本或所有同名实现。

## 5. 用途与反规避声明

本项目的兼容层（`android-bridge/`、`companion/`）仅用于运行**用户自行提供**的解析插件（spider），
以便在桌面端复用既有生态；本项目**不提供、不托管任何插件、载荷或密钥**，也不对第三方插件的内容负责。
本仓不含任何反编译产物、解密后的载荷或第三方内容样本。

## 6. 复查方式

在任意机器上（无需联网）执行以下检查即可复现本文件的数据：

1. 核对已提交候选时先读取其清单：`$m = git show HEAD:companion/deps.manifest.json | ConvertFrom-Json; $m.count`（本版候选为 43）。工作区未提交的依赖试验不是入包证据。
2. 对 `$m.files` 中每个路径核对 `Get-Item` 的 `Length` 和 `Get-FileHash -Algorithm SHA256`；不能只核对文件名。
3. 读取各 JAR 的 Maven 元数据与许可文件，并确认胖 JAR 合并后保留独立 `licenses/` 路径，外部 Node/Python/PHP/JRE 运行时也保留自己的许可。
