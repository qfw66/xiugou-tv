# 参与贡献

感谢你愿意改进 修狗TV（xiugou-tv）。本文件只讲一件事：**怎么提改动、怎么让对方能收**。

## 提交前

1. 先在本机确认能构建、能跑：

   ```powershell
   flutter pub get
   flutter analyze --no-pub lib
   flutter build windows --release --no-pub
   ```

2. 改动集中在 `lib/`（Flutter 界面与业务）与 `android-bridge/`（Android→JVM 兼容层）；
   两者各自的约束见对应目录的说明。
   弹幕、共享片段依赖维护者自部署的在线服务，源码直接构建时这两项不出现；
   需要的话按 [`DEVELOPER_GUIDE.md`](DEVELOPER_GUIDE.md) 自行部署并配置 `config/app.env`（**不要提交**）。
3. 不要提交下列内容（已在 `.gitignore` 中排除，请勿用 `-f` 绕过）：
   第三方配置文件样本、反编译产物、解密后的载荷、`*.jar` 新增二进制、
   个人运行数据（`appdata/`、`history.json`、`favorites.json` 等）、日志与崩溃转储。
4. 新增随仓分发的第三方二进制时，必须同时更新根目录的
   [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)（名称 / 版本 / 来源 / 许可 / 依据）。

## 提交信息

- 用一行说明「做了什么」，必要时第二段写「为什么」；
- 一个提交只做一件事（视觉改动与逻辑改动分开，便于回退）；
- 中文或英文都可以，保持一致即可。

## DCO（开发者原创声明）

从 v1.1.0 起，新的贡献采用 DCO（Developer Certificate of Origin）：贡献者确认自己有权提交代码，并按项目许可证提供该贡献。请在新提交中添加签名行；已合并的历史贡献（包括 PR #21）不要求追补签名或改写历史。

请使用：

```
git commit -s -m "fix(player): 修复倍速切换后音画不同步"
```

`-s` 会自动追加：

```
Signed-off-by: 你的名字 <你的邮箱>
```

签名用于记录贡献来源和提交权限。DCO 不转移著作权，也不自动授予维护者变更许可证的权限；未来若变更许可证，仍需按实际权利和许可条件处理。

## 许可

提交进本项目的代码，按根目录 [`LICENSE`](LICENSE)（GPL-3.0）发布。
第三方组件各自的许可见 [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)。

## 不要做什么

- 不要提交任何爬虫载荷、密钥、登录态或第三方内容样本；
- 不要在仓库里引入"按站名写死"的解析分支（兼容层的历史原因见 `android-bridge/`）；
- 不要为了通过检查而放宽忽略规则或删掉许可署名。
