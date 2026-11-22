# 修狗TV（xiugou-tv）

一款面向 Windows 的桌面影视聚合播放客户端。

<p align="center">
  <img src="assets/icons/app_icon.png" width="128" alt="修狗TV 图标">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/平台-Windows%2010%2F11%20x64-0078D4" alt="平台">
  <img src="https://img.shields.io/badge/版本-1.2.0-2ea44f" alt="版本">
  <img src="https://img.shields.io/badge/许可证-GPL--3.0-blue" alt="许可证">
  <a href="https://linux.do" target="_blank">
    <img src="https://img.shields.io/badge/社区-LINUXDO-blue" alt="社区">
  </a>
  <a href="https://t.me/+Z-8NGECyhdkzMDVl" target="_blank">
    <img src="https://img.shields.io/badge/TG群组-点击加入-blue" alt="TG">
  </a>
</p>


## 简介

修狗TV 是一款运行在 Windows 10/11 x64 上的桌面影视客户端。导入你自己的影视配置后，就可以在同一套界面里浏览分类、搜索剧集、选集播放，并随时切换到电视直播。

播放内核基于 libmpv（media_kit），提供硬件解码、多轨切换、倍速与断点续播。解析层内置 JVM 运行时，可直接运行既有生态的 spider 插件，因此你现有的站点配置基本可以原样复用。

软件本身不提供任何内容源，播放内容来自你自行添加的配置。

## 核心亮点

- 点播与直播共用一套界面：分类浏览、全局搜索、选集播放、频道切换与 EPG 节目单。
- libmpv 播放内核：D3D11VA / DXVA2 硬件解码，0.5–3.0 倍速，音轨 / 视轨 / 字幕轨切换。
- 直接复用既有影视配置与 spider 插件，无需迁移内容源。
- 播放失败自动换线，也可手动切线路；片头片尾可按时长跳过。
- 历史、收藏与各项偏好支持一键备份与恢复。

## 功能特性

### 内容源与配置

- 支持Tvbox影视配置 JSON、多仓清单与 CMS 资源站清单导入，多仓可指定具体仓库。
- 站点中的相对地址（api / ext / jar）自动还原，支持远程与本地文件。
- 站点自检：逐个体检站点，给出分类数量与可用性结论。
- 「添加配置源 → 导入本地文件…」可选择配置文件或猫源 ZIP。包内至少各有一个 JSON 和 JAR 即满足文件要求，支持自定义文件名和子目录。
- 支持猫源 Node、Python、道长 T3 PHP 脚本与 T4 HTTP 接口，以及 XPTV、NowShowTime、drpy2 等订阅格式。Windows 包自带对应运行时。
- 影视源和直播源分别支持分类、备注与批量移动。支持网页验证的站点可用独立浏览器资料完成验证后重试。

### 点播

- 首页分类浏览、海报瀑布流，站点与分类可快速切换。
- 分类页滚动到底自动加载下一页并增量追加，直到该分类取完；页码按站点声明推进，遇到不响应翻页的站点会自行收住而不是空转。
- 全局搜索逐站显示结果，结果可按站点筛选。在「设置 → 通用 → 聚合搜索站点」可为每份配置单独勾选参与搜索的站点。默认全选，取消所有勾选会暂停该配置的聚合搜索。
- 首页可从热门海报点缩略图选片，也可点「评分盲开」挑片。详情显示更新状态、线路和选集，以及同站同片上次看到的集数和进度。
- 播放历史与断点续播，保留条数可配置（30–500，默认 150）。
- 可选 TMDB 新版影片详情，在「设置 → 外观 → 影片详情」开启，经典布局仍默认。新版保留原站选集、收藏与续播，异步补充背景、简介、演员、豆瓣短评和相似推荐。
- 资料／图片失败时只补经过同片核验的豆瓣缺项：横版海报优先、横剧照回退，演员头像按同片同名回退；不放大竖封面，不用不确定的同名片拼接资料。

### 直播

- 在「设置 → 直播源」导入 TXT、M3U、M3U8 或 JSON 频道表，同一路径再次导入可刷新频道。
- 频道按来源分组，支持分组浏览与频道搜索。
- EPG 节目单：查看频道当前与后续节目。
- 播放画面中部偏左（含中线）滚轮上滚上一台、下滚下一台，右侧仍调节音量。

### 播放器

- libmpv 内核，支持 D3D11VA、D3D11VA（拷回模式）、DXVA2 硬件解码，并显示硬解状态。
- 倍速菜单提供 0.5–3.0 倍速，同片切集、换线和刷新可保留手选倍率。可调音量与画面缩放，还可在画面左上角显示实际分辨率。
- 点播弹幕可按片名、集数手动搜索匹配。
- 视频轨、音轨、字幕轨切换，支持关闭字幕；音轨/字幕菜单按真实引擎选择更新。
- mpv 文本字幕可按 75%、100%、125%、150%、200% 调整字号并恢复默认；位图字幕及 MDK / Media Foundation 不提供此字号能力。
- mpv 可从系统文件选择器挂载 SRT、ASS、SSA、VTT，取消、坏文件及换片不会串用上一片字幕。
- 片头 / 片尾跳过，按毫秒精确配置。
- 自动换线与手动换线，失败提示统一呈现。
- 键盘快捷键与鼠标操作并行。
- 播放/暂停/缓冲期间维持伴随服务租约，代理异常时有界恢复，保留播放位置。
- 点播自然结束后自动切下一集，可在「设置 → 播放器与解码」关闭；点播失败后可直接重选线路与剧集。
- Windows 播放页可在 mpv、MDK 与 Media Foundation 之间切换，默认仍为 mpv。格式、字幕与硬解能力以内核和系统支持为准，不承诺新内核普遍更省电。

### 界面与交互

- 左侧导航 + 顶部搜索 + 站点分类横滚 + 海报网格的桌面布局。
- 详情、选集、收藏、历史、直播频道与 EPG 以浮层呈现，不打断当前播放。
- 支持深色 / 浅色 / 跟随系统三档主题，可自定义壁纸。
- 记忆窗口大小与位置，并限制最小窗口尺寸。
- 主侧栏可收起并在重启后保持状态。系统开启减少动画时，首页停止自动轮播。

### 媒体与数据

- 媒体直链、本地文件与 WebDAV 目录均可直接浏览播放（不支持磁力链）。
- WebDAV 支持保存最多 20 个连接；凭据由当前 Windows 用户加密保护，不进入普通备份。
- 数据目录可自行指定并迁移，启动前校验写入权限。
- 备份与恢复覆盖历史、收藏与偏好设置，恢复后自动重启生效。

## 下载与升级

适用于 Windows 10 / 11 x64，随包提供 Java、Node、Python、PHP 和媒体运行时。安装版与便携版从 [GitHub Releases](https://github.com/qfw66/xiugou-tv/releases/latest) 获取，摘要以该次发行附带的 SHA256SUMS 为准。

安装版请先完全退出旧程序再运行安装向导；便携版解压到新的可写目录后运行 `xiugou_tv.exe`。升级前在旧版设置中导出备份，记下实际资料目录并退出；确认配置、历史、收藏和偏好正常前，保留旧目录与备份。

第三方组件及 MDK／FFmpeg 的分发材料见 [第三方许可](THIRD_PARTY_LICENSES.md)。

## 界面截图

### 首页

<p align="center">
  <img src="assets/snapshot/home.png?v=1.0.1" alt="修狗TV 首页：左侧导航、顶部搜索与海报网格" width="900">
</p>

<p align="center">左侧导航 + 顶部搜索 + 站点分类横栏 + 海报网格；站点与分类都能一键切换。</p>

### 播放历史

<p align="center">
  <img src="assets/snapshot/history.png?v=1.0.1" alt="修狗TV 播放历史" width="900">
</p>

<p align="center">按时间倒序记录剧集与观看进度，点击即从上次位置续播；保留条数可配置（30–500，默认 150）。</p>

### 设置

<p align="center">
  <img src="assets/snapshot/settings.png?v=1.0.1" alt="修狗TV 设置" width="900">
</p>

<p align="center">主题与壁纸、播放器、数据目录、站点自检与备份恢复集中在这里。</p>


## 从源码构建

弹幕与共享跳过片段依赖维护者自部署的在线服务，直接用源码构建时这两项功能不会出现（其余功能不受影响）。
需要的话请看 [开发者指北](DEVELOPER_GUIDE.md)，按说明部署服务并配置 `config/app.env`。普通用户直接下载 Releases 安装包即可，无需任何配置。

从源码制作 Windows 完整包时，`companion/noderuntime/node.exe` 使用 Node.js 24.19.0 的 Windows x64 官方二进制，SHA-256 见 `companion/noderuntime/provenance.json`。PHP 可用 `scripts/setup_php_runtime.ps1` 准备。已有同版本便携包的开发者也可在校验 ZIP 后，将包内 `companion/dist/` 的 `noderuntime`、`phpruntime`、`pyruntime` 分别复制到源码的 `companion/`，将 `runtime/jre` 复制到源码的同名位置。

## 上游来源

本项目的产品形态与交互参考了 FongMi 系列（[FongMi/TV](https://github.com/FongMi/TV)）以及 TVBox / CatVod 生态的既有实现，解析层遵循 CatVod spider 契约，以便直接运行既有插件。感谢这些项目及其贡献者长期的开源工作。

播放基于 [media_kit](https://github.com/media-kit/media-kit)（libmpv）；部分兼容能力借助 [unidbg](https://github.com/zhkl0228/unidbg) 与 [dex2jar](https://github.com/pxb1988/dex2jar) 实现。

安装目录的 `licenses/THIRD_PARTY_LICENSES.md` 列出第三方组件的来源与许可。项目从 v1.1.0 起对新贡献采用 DCO 签名。感谢 @digiprospector 修复音轨和字幕的选中状态，并贡献聚合搜索站点选择。[PR #21](https://github.com/qfw66/xiugou-tv/pull/21) · [PR #25](https://github.com/qfw66/xiugou-tv/pull/25)

## 许可证

本项目以 GPL-3.0 协议发布，详见 [LICENSE](LICENSE)。
