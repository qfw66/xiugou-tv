# 开发者指北：可选的在线服务（弹幕 / 共享片段）

修狗TV 有两项功能依赖维护者自己部署的在线服务：

| 功能 | 依赖的服务 | 没配置时 |
| --- | --- | --- |
| 点播弹幕 | 自部署的 [LogVar Danmu API](https://github.com/qfw66/danmu_api) | 播放页没有弹幕按钮 / 弹幕设置 / `D` 键，设置页没有「弹幕」分组，不发任何请求 |
| 共享跳过片段 | 本仓库的 Cloudflare Worker：[`server/segments-worker/`](server/segments-worker/README.md) | 播放页没有「片段」按钮，时间轴上不显示片段色块 |

这两项服务的地址与令牌**不在仓库里**。
所以你 clone 下来直接构建，得到的是「没有这两项功能」的版本——其余功能（站点、点播、直播、播放器、历史收藏……）完全不受影响。

**如果你需要这些功能，就要自己部署服务并按下面配置。**

## 1. 建配置文件

```bash
cp config/app.env.example config/app.env
```

`config/app.env` 已被 `.gitignore` 排除，**不要提交**（也不要用 `git add -f`）。模板里每一项都有注释：

```env
# 弹幕：自部署 LogVar Danmu API 的根地址（不带令牌、末尾不带 /）与令牌（路径第一段）
XIUGOU_DANMAKU_URL="https://danmu.example.com"
XIUGOU_DANMAKU_TOKEN="your-token"

# 共享片段：Cloudflare Worker 地址与令牌（= Worker 的 secret CLIENT_TOKEN）
XIUGOU_SEGMENTS_URL="https://xiugou-segments.example.workers.dev"
XIUGOU_SEGMENTS_TOKEN="your-client-token"
```

只想要其中一项，另一项留空即可；留空的那项功能不出现。

## 2. 部署服务

- **弹幕**：按 [LogVar Danmu API](https://github.com/qfw66/danmu_api) 的说明部署（Vercel / Cloudflare / Docker 均可），
  得到「根地址 + 令牌」。国内直连 `*.vercel.app` 常被干扰，建议绑定自己的域名。
- **共享片段**：照 [`server/segments-worker/README.md`](server/segments-worker/README.md) 第四节，6 条命令完成
  D1 建库建表、设置密钥、部署 Worker；该文档也写了表结构、接口与校验规则。

## 3. 运行与打包

| 场景 | 怎么带上配置 |
| --- | --- |
| 本机调试 `flutter run -d windows` | **自动**：开发态（debug / profile）启动时读项目根的 `config/app.env`，不用加参数 |
| 打包 `scripts/build_windows.ps1` | **自动**：发现 `config/app.env` 就加 `--dart-define-from-file`，值编进 exe |
| 手动 `flutter build windows --release` | 必须自己加 `--dart-define-from-file=config/app.env`——release 包**只认编译期注入的值**，不读磁盘上的文件 |
| `flutter test` | 不读配置，测试环境一律视为「未配置」，保证结果稳定 |

启动日志里会打印 `[xiugou-tv] 弹幕服务：已配置 / 未配置`（不打印地址和令牌），可以据此确认配置是否生效。
读取逻辑在 `lib/core/config/app_env.dart`。
