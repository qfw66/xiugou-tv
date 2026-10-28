// 修狗TV 共享跳过片段（§44）——提交校验与多数一致合并的纯函数。
// 与客户端 lib/core/segments/segment_rules.dart 同口径；两端共用 test/vectors.json 做契约测试，改规则须两边一起改。

export const CATEGORIES = ['intro', 'outro', 'recap', 'preview', 'ad', 'other'];
export const ACTIONS = ['skip', 'mute', 'highlight'];

const S = 1000;
const MIN = 60 * S;

/** 各分类：片段时长上限 + 位置约束（相对本集总时长 D）。 */
export const RULES = {
  intro:   { maxLen: 5 * MIN,  where: (st, en, d) => st <= Math.min(10 * MIN, d * 0.3) },
  outro:   { maxLen: 10 * MIN, where: (st, en, d) => st >= d * 0.6 && en >= d * 0.8 },
  recap:   { maxLen: 5 * MIN,  where: (st, en, d) => st <= Math.min(15 * MIN, d * 0.4) },
  preview: { maxLen: 5 * MIN,  where: (st, en, d) => st >= d * 0.7 },
  ad:      { maxLen: 3 * MIN,  where: () => true },
  other:   { maxLen: 10 * MIN, where: () => true },
};

export const MIN_LEN = 3 * S;          // 片段至少 3 秒
export const MIN_DURATION = 1 * MIN;   // 本集至少 1 分钟
export const MAX_DURATION = 6 * 60 * MIN;
export const END_SLACK = 2 * S;        // 结束点允许超出总时长 2 秒（片尾吸附误差）

/** 同一剪辑版本：总时长相差不超过 15 秒。 */
export const SAME_CUT_MS = 15 * S;
/** 两条提交算「一致」：起点、终点各相差不超过 3 秒。 */
export const AGREE_MS = 3 * S;

/**
 * 校验一条提交。合法返回 null；否则返回 { code, message }（message 直接给用户看）。
 * @param {{key:string, clientId:string, category:string, action:string, startMs:number, endMs:number, durationMs:number}} s
 */
export function validate(s) {
  const bad = (code, message) => ({ code, message });
  if (!s || typeof s !== 'object') return bad('bad_body', '请求格式错误');
  if (typeof s.key !== 'string' || !/^[0-9a-f]{40}$/.test(s.key)) return bad('bad_key', '影片标识无效');
  if (typeof s.clientId !== 'string' || !/^[A-Za-z0-9-]{16,64}$/.test(s.clientId)) return bad('bad_client', '客户端标识无效');
  if (!CATEGORIES.includes(s.category)) return bad('bad_category', '未知的片段分类');
  if (!ACTIONS.includes(s.action)) return bad('bad_action', '未知的片段动作');
  for (const k of ['startMs', 'endMs', 'durationMs']) {
    if (!Number.isInteger(s[k])) return bad('bad_time', '时间必须是整数毫秒');
  }
  const { startMs: st, endMs: en, durationMs: d } = s;
  if (d < MIN_DURATION || d > MAX_DURATION) return bad('bad_duration', '本集时长异常，无法共享');
  if (st < 0 || en <= st || en > d + END_SLACK) return bad('bad_range', '开始 / 结束时间不正确');
  const len = en - st;
  if (len < MIN_LEN) return bad('too_short', '片段太短（至少 3 秒）');
  const rule = RULES[s.category];
  if (len > rule.maxLen) return bad('too_long', `片段太长，不像${label(s.category)}`);
  if (!rule.where(st, en, d)) return bad('bad_position', `时间位置不像${label(s.category)}，未上传`);
  return null;
}

export function label(category) {
  return { intro: '片头', outro: '片尾', recap: '前情回顾', preview: '下集预告', ad: '广告', other: '其他片段' }[category] ?? '片段';
}

function median(nums) {
  const a = [...nums].sort((x, y) => x - y);
  return a[Math.floor((a.length - 1) / 2)];
}

/** 同一剪辑版本、起止点一致：提交与提交、反馈与片段都用这个口径判断「说的是同一段」。 */
export function sameSegment(a, b) {
  return (
    Math.abs(a.duration_ms - b.duration_ms) <= SAME_CUT_MS &&
    Math.abs(a.start_ms - b.start_ms) <= AGREE_MS &&
    Math.abs(a.end_ms - b.end_ms) <= AGREE_MS
  );
}

/** 反馈结论：up = 自动执行后没有撤销（认可），down = 点了「撤销」（异议）。 */
export const VERDICTS = ['up', 'down'];

/**
 * 是否撤下（§44 拍板 2026-10-27）：异议 ≥ 2 且异议 ≥ 认可（认可含提交者本身）。
 * 新片段两人撤销就下架；被很多人认可过的片段，要更多异议才会被撤下，防两个人恶意反馈。
 */
export function shouldHide(supporters, downs) {
  return downs >= 2 && downs >= supporters;
}

/**
 * 多数一致合并（§44 拍板 Q2）：同集同分类的提交里，
 * 按「同剪辑版本（时长 ±15 s）且起止点各 ±3 s」找支持者最多的一簇，取中位数作结果；
 * 簇内动作取多数。不同剪辑版本可能各有一簇，所以每个分类可返回多条，客户端按自己的时长挑。
 *
 * 只合并未隐藏（hidden = 0）的提交；票数 = 提交者 + 认可反馈（[feedback] 里 verdict = up 且与该段一致）。
 * 返回项带 `members`（组成该段的提交 id），供反馈判定时定位。
 * @param {Array<{id:number, category:string, action:string, start_ms:number, end_ms:number, duration_ms:number, created_at:number}>} rows
 * @param {Array<{category:string, verdict:string, start_ms:number, end_ms:number, duration_ms:number}>} [feedback]
 */
export function merge(rows, feedback = []) {
  const out = [];
  for (const category of CATEGORIES) {
    let pool = rows.filter((r) => r.category === category).sort((a, b) => a.created_at - b.created_at);
    while (pool.length > 0 && out.filter((o) => o.category === category).length < 5) {
      let best = null;
      let bestMembers = [];
      for (const r of pool) {
        const members = pool.filter((x) => sameSegment(r, x));
        if (members.length > bestMembers.length) {
          best = r;
          bestMembers = members;
        }
      }
      const sameCut = pool.filter((x) => Math.abs(x.duration_ms - best.duration_ms) <= SAME_CUT_MS).length;
      const counts = {};
      for (const m of bestMembers) counts[m.action] = (counts[m.action] ?? 0) + 1;
      const action = ACTIONS.filter((a) => counts[a]).sort((a, b) => counts[b] - counts[a])[0];
      const seg = {
        category,
        action,
        start_ms: median(bestMembers.map((m) => m.start_ms)),
        end_ms: median(bestMembers.map((m) => m.end_ms)),
        duration_ms: median(bestMembers.map((m) => m.duration_ms)),
      };
      const ups = feedback.filter((f) => f.category === category && f.verdict === 'up' && sameSegment(f, seg)).length;
      out.push({
        category,
        action,
        startMs: seg.start_ms,
        endMs: seg.end_ms,
        durationMs: seg.duration_ms,
        votes: bestMembers.length + ups,
        total: sameCut,
        members: bestMembers.map((m) => m.id),
      });
      const used = new Set(bestMembers);
      // 同一剪辑版本只取得票最多的一簇；剩下的去找其他剪辑版本
      pool = pool.filter((x) => !used.has(x) && Math.abs(x.duration_ms - best.duration_ms) > SAME_CUT_MS);
    }
  }
  return out;
}
