# 修狗TV 共享跳过片段服务（Cloudflare Worker + D1）

修狗TV 播放页的「片段」功能会把用户标记的时间片段（片头 / 片尾 / 广告……）提交到这里，
其他用户播放同一集时拉取结果，按动作「跳过 / 静音 / 精彩时刻」处理。

- 客户端代码：`lib/core/segments/`、`lib/ui/desktop/player/segment_panel.dart`
- 本服务**可选**：客户端没配置服务地址时，播放页不出现「片段」按钮，其余功能不受影响。

## 一、D1 表结构

两张表：`submission` 存每一条原始提交（只追加，被反馈撤下时软删除）；`feedback` 存播放时的认可 / 异议。
对外结果在查询时现算（见下文「多数一致」「反馈与撤下」）。完整 SQL 在 [`schema.sql`](schema.sql)。

> `wrangler d1 execute --file` 不接受建表语句**同一行**里的行内注释，所以 `schema.sql` 不带注释，说明都在本文。

### `submission`

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER 主键自增 | |
| `ep_key` | TEXT | 集身份：`sha1(规范化片名 \| 集序号)`，40 位十六进制。由客户端计算，跨站点通用（不含年份：很多站点不给年份；同名不同片靠 `duration_ms` 区分） |
| `client_id` | TEXT | 客户端首次使用时随机生成的 ID，不含任何个人信息 |
| `ip_hash` | TEXT | `sha256(IP_SALT + IP)` 的前 32 位，只用于限频；**不保存原始 IP** |
| `category` | TEXT | 分类：`intro` 片头、`outro` 片尾、`recap` 前情回顾、`preview` 下集预告、`ad` 广告、`other` 其他 |
| `action` | TEXT | 动作：`skip` 跳过、`mute` 静音、`highlight` 精彩时刻 |
| `start_ms` / `end_ms` | INTEGER | 片段起止（毫秒） |
| `duration_ms` | INTEGER | 提交者这一集的总时长，用来区分不同剪辑版本 |
| `title` / `episode` | TEXT / INTEGER | 片名、集序号，只为方便人工排查，可空 |
| `created_at` | INTEGER | 提交时间（毫秒时间戳） |
| `hidden` | INTEGER | 0 正常；1 = 被反馈撤下（软删除，不再下发，数据保留便于排查） |

### `feedback`

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER 主键自增 | |
| `ep_key` / `category` | TEXT | 反馈的是哪一集的哪个分类 |
| `client_id` / `ip_hash` | TEXT | 同上表；`ip_hash` 用于反馈限频 |
| `verdict` | TEXT | `up` 认可（自动执行后 3 秒内没撤销）/ `down` 异议（点了「撤销」） |
| `start_ms` / `end_ms` / `duration_ms` | INTEGER | 反馈时这一段的起止与时长（判断反馈的是不是同一段） |
| `created_at` | INTEGER | 反馈时间 |

索引：

| 索引 | 列 | 作用 |
| --- | --- | --- |
| `one_shot`（唯一，**只约束 `hidden = 0`**） | `submission(ep_key, client_id, category)` | **每人每集每种分类只能提交一次**；被撤下后可重新提交（含原提交者） |
| `by_episode` | `submission(ep_key)` | 按集查询 |
| `by_ip_time` | `submission(ip_hash, created_at)` | 按 IP 限频 |
| `feedback_once`（唯一） | `feedback(ep_key, category, client_id)` | 每人每集每分类一条反馈，再次反馈覆盖（可以改主意） |
| `feedback_by_ip` | `feedback(ip_hash, created_at)` | 反馈限频 |

## 二、规则

### 提交校验（不合理的直接拒绝，不入库）

| 分类 | 片段长度 | 位置（D = 本集总时长） |
| --- | --- | --- |
| 片头 | 3 秒 – 5 分钟 | 开始 ≤ min(10 分钟, D × 30%) |
| 片尾 | 3 秒 – 10 分钟 | 开始 ≥ D × 60%，结束 ≥ D × 80% |
| 前情回顾 | 3 秒 – 5 分钟 | 开始 ≤ min(15 分钟, D × 40%) |
| 下集预告 | 3 秒 – 5 分钟 | 开始 ≥ D × 70% |
| 广告 | 3 秒 – 3 分钟 | 任意 |
| 其他 | 3 秒 – 10 分钟 | 任意 |

通用：本集时长 1 分钟 – 6 小时；`0 ≤ 开始 < 结束 ≤ D + 2 秒`；时间为整数毫秒。
规则代码在 [`src/rules.js`](src/rules.js)，客户端 `lib/core/segments/segment_rules.dart` 与它同口径，
两端共用 [`test/vectors.json`](test/vectors.json) 做契约测试——**改规则要两边一起改**。

### 多数一致

同一集同一分类的提交里，找「同剪辑版本（总时长相差 ≤ 15 秒）且起止点各相差 ≤ 3 秒」支持者最多的一组，
取中位数作为结果，动作取组内多数；返回 `votes` 和 `total`（同版本的全部提交数）。
`votes` = 这一组的提交人数 + 与这一段一致的**认可**反馈数。

### 反馈与撤下（2026-10-27 拍板）

- 客户端：**第一个人提交后，其他人播放时就自动执行**（跳过 / 静音），并显示 3 秒提醒「已为你跳过片头 · 撤销」；
- 3 秒内点「撤销」：回到片段开头 / 恢复音量，上报 `down`（异议）；没点：上报 `up`（认可，相当于投一票）；
- 提交者本人的反馈不计；每人每集每分类一条，再次反馈覆盖旧结论；
- **撤下条件：异议 ≥ 2 且 异议 ≥ 认可**（认可 = 提交者 + `up` 反馈）。新片段两人撤销就撤下；被很多人认可的片段要更多异议才撤下，防两个人恶意反馈；
- 撤下 = 该段提交 `hidden = 1`（软删除）+ 清掉该段的反馈；这一集该分类**重新开放提交**，包括原提交者。

### 限频

提交：同一 IP 每小时 30 条、每天 200 条；同一客户端每天 200 条。反馈：同一 IP 每小时 120 条。超出返回 429。

## 三、接口

所有请求带请求头 `X-Xiugou-Token: <CLIENT_TOKEN>`（`/v1/health` 除外）。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/v1/segments?key=<ep_key>` | 该集结果。可带 `X-Xiugou-Client: <client_id>`，返回里的 `submitted` 会列出这个客户端已提交过的分类 |
| POST | `/v1/segments` | 提交一条，JSON：`{key, clientId, category, action, startMs, endMs, durationMs, title?, episode?}` |
| POST | `/v1/feedback` | 反馈，JSON：`{key, clientId, category, verdict: "up" \| "down", startMs, endMs, durationMs}`；返回 `{ok, hidden}`，`hidden: true` 表示这一段已被撤下 |
| GET | `/v1/health` | 健康检查 |

返回：

```json
{ "ok": true, "key": "…", "submitted": ["intro"],
  "segments": [ { "category": "intro", "action": "skip", "startMs": 0, "endMs": 91000,
                  "durationMs": 2700000, "votes": 3, "total": 4 } ] }
```

失败：`{ "ok": false, "code": "bad_position", "message": "时间位置不像片头，未上传" }`。
`code` 取值：`bad_body` `bad_key` `bad_client` `bad_category` `bad_action` `bad_time` `bad_duration`
`bad_range` `too_short` `too_long` `bad_position` `bad_verdict`（400）、`unauthorized`（401）、
`segment_gone`（404，反馈的片段已不存在）、`already_submitted`（409）、`rate_limited`（429）、`internal`（500）。

## 四、部署步骤

需要 Node.js 18+ 和一个 Cloudflare 账号。以下命令都在本目录（`server/segments-worker/`）执行。

```bash
# 1. 安装 wrangler 并登录（会打开浏览器授权）
npm install
npx wrangler login

# 2. 创建 D1 数据库，把输出里的 database_id 填进 wrangler.toml
npx wrangler d1 create xiugou-segments

# 3. 建表
npx wrangler d1 execute xiugou-segments --remote --file=schema.sql

# 4. 设置两个密钥（命令执行后按提示粘贴值；不会写进任何文件）
npx wrangler secret put CLIENT_TOKEN   # 客户端令牌：自己生成一串随机字符，例如 openssl rand -hex 24
npx wrangler secret put IP_SALT        # IP 哈希的盐：另一串随机字符

# 5. 部署，记下输出的地址（https://xiugou-segments.<你的子域>.workers.dev）
npx wrangler deploy

# 6. 验证
curl https://xiugou-segments.<你的子域>.workers.dev/v1/health
```

部署完成后，在修狗TV 项目根目录的 `config/app.env`（不入库）里填上：

```env
XIUGOU_SEGMENTS_URL="https://xiugou-segments.<你的子域>.workers.dev"
XIUGOU_SEGMENTS_TOKEN="<第 4 步设置的 CLIENT_TOKEN>"
```

重新 `flutter run` 或打包即可在播放页看到「片段」按钮。也可以在 Cloudflare 后台给 Worker 绑定自定义域名。

> 注意：`database_id` 填好后不要提交（它不是密钥，但没必要公开）；令牌与盐只存在 Cloudflare 的 secret 里。

## 四之一、已部署过旧版本的升级（2026-10-27 投票改版）

旧库没有 `hidden` 列和 `feedback` 表，执行一次迁移脚本再部署新代码（脚本只加不删，已有提交保留）：

```bash
npx wrangler d1 execute xiugou-segments --remote --file=migrations/0002_feedback.sql
npx wrangler deploy
```

迁移脚本只能执行**一次**（第二次会因 `hidden` 列已存在而报错，无害）。全新部署直接用 `schema.sql`，不需要迁移。

## 五、本地自测

```bash
npm test     # 用 Node 内置 sqlite 模拟 D1，跑校验向量、合并逻辑和完整接口流程（需 Node ≥ 22.5）
```

## 六、维护

```bash
# 看某一集的全部提交
npx wrangler d1 execute xiugou-segments --remote --command "SELECT * FROM submission WHERE ep_key='…'"
# 看某一集的反馈
npx wrangler d1 execute xiugou-segments --remote --command "SELECT * FROM feedback WHERE ep_key='…'"
# 撤下某个客户端的全部提交（恶意刷数据时）
npx wrangler d1 execute xiugou-segments --remote --command "UPDATE submission SET hidden=1 WHERE client_id='…'"
# 恢复被误撤下的片段
npx wrangler d1 execute xiugou-segments --remote --command "UPDATE submission SET hidden=0 WHERE id=…"
```
