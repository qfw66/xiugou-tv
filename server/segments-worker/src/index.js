// 修狗TV 共享跳过片段 Worker（§44）。部署说明见 ../README.md。
//
// 接口（均需请求头 X-Xiugou-Token = CLIENT_TOKEN）：
//   GET  /v1/segments?key=<ep_key>          —— 该集的采纳结果；带 X-Xiugou-Client 时附带「我已提交的分类」
//   POST /v1/segments                       —— 提交一条片段（JSON，见 rules.js 的 validate）
//   POST /v1/feedback                       —— 自动执行后的反馈：up = 没撤销（认可）/ down = 撤销（异议）
//   GET  /v1/health                         —— 健康检查（不需要令牌）
//
// 绑定：
//   DB           —— D1 数据库（schema.sql）
//   CLIENT_TOKEN —— secret，客户端令牌（与 config/app.env 的 XIUGOU_SEGMENTS_TOKEN 一致）
//   IP_SALT      —— secret，IP 哈希用的盐（随便一串随机字符）

import { CATEGORIES, VERDICTS, merge, sameSegment, shouldHide, validate } from './rules.js';

const HOUR = 3600 * 1000;
const LIMIT_IP_HOUR = 30;
const LIMIT_IP_DAY = 200;
const LIMIT_CLIENT_DAY = 200;
const LIMIT_FEEDBACK_IP_HOUR = 120;

const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });

const fail = (status, code, message) => json(status, { ok: false, code, message });

async function sha256Hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** 常量时间比较，避免按字节提前返回泄露令牌长度 / 前缀。 */
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function mergedEpisode(env, key) {
  const rows = await env.DB.prepare(
    'SELECT id, category, action, start_ms, end_ms, duration_ms, created_at FROM submission WHERE ep_key = ?1 AND hidden = 0',
  ).bind(key).all();
  const fb = await env.DB.prepare(
    'SELECT category, verdict, start_ms, end_ms, duration_ms FROM feedback WHERE ep_key = ?1',
  ).bind(key).all();
  return { segments: merge(rows.results, fb.results), feedback: fb.results };
}

async function loadEpisode(env, key, clientId) {
  const { segments } = await mergedEpisode(env, key);
  let submitted = [];
  if (clientId) {
    const mine = await env.DB.prepare(
      'SELECT category FROM submission WHERE ep_key = ?1 AND client_id = ?2 AND hidden = 0',
    ).bind(key, clientId).all();
    submitted = mine.results.map((r) => r.category);
  }
  // members 只供服务端判定，不下发
  return { key, segments: segments.map(({ members, ...rest }) => rest), submitted };
}

/** `IN (?2, ?3, …)`：D1 用编号占位，从 [start] 开始编号。 */
const inList = (n, start) => Array.from({ length: n }, (_, i) => `?${start + i}`).join(', ');

async function ipHashOf(request, env) {
  const ip = request.headers.get('cf-connecting-ip') ?? '0.0.0.0';
  return (await sha256Hex(`${env.IP_SALT ?? ''}|${ip}`)).slice(0, 32);
}

/**
 * 反馈：自动执行片段后，客户端 3 秒内被「撤销」记 down，否则记 up。
 * 每人每集每分类一条（再次反馈覆盖旧结论）。异议 ≥ 2 且 ≥ 认可（含提交者）时，
 * 该段的全部提交软删除（hidden = 1），这一集该分类重新开放提交（含原提交者）。
 */
async function handleFeedback(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return fail(400, 'bad_body', '请求格式错误');
  }
  const b = body ?? {};
  if (typeof b.key !== 'string' || !/^[0-9a-f]{40}$/.test(b.key)) return fail(400, 'bad_key', '影片标识无效');
  if (typeof b.clientId !== 'string' || !/^[A-Za-z0-9-]{16,64}$/.test(b.clientId)) return fail(400, 'bad_client', '客户端标识无效');
  if (!CATEGORIES.includes(b.category)) return fail(400, 'bad_category', '未知的片段分类');
  if (!VERDICTS.includes(b.verdict)) return fail(400, 'bad_verdict', '未知的反馈');
  for (const k of ['startMs', 'endMs', 'durationMs']) {
    if (!Number.isInteger(b[k])) return fail(400, 'bad_time', '时间必须是整数毫秒');
  }

  const now = Date.now();
  const ipHash = await ipHashOf(request, env);
  const counts = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM feedback WHERE ip_hash = ?1 AND created_at > ?2',
  ).bind(ipHash, now - HOUR).first();
  if (counts.n >= LIMIT_FEEDBACK_IP_HOUR) return fail(429, 'rate_limited', '操作太频繁，请稍后再试');

  const target = { category: b.category, start_ms: b.startMs, end_ms: b.endMs, duration_ms: b.durationMs };
  const { segments } = await mergedEpisode(env, b.key);
  const seg = segments.find((s) => s.category === b.category &&
    sameSegment({ start_ms: s.startMs, end_ms: s.endMs, duration_ms: s.durationMs }, target));
  if (!seg) return fail(404, 'segment_gone', '该片段已不存在');

  // 提交者本人反馈不计（自己提交的当然认可；撤销自己的也只影响自己这次播放）
  const own = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM submission WHERE client_id = ?1 AND id IN (${inList(seg.members.length, 2)})`,
  ).bind(b.clientId, ...seg.members).first();
  if (own.n > 0) return json(200, { ok: true, hidden: false, ignored: true });

  await env.DB.prepare(
    `INSERT INTO feedback (ep_key, category, client_id, ip_hash, verdict, start_ms, end_ms, duration_ms, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
     ON CONFLICT(ep_key, category, client_id) DO UPDATE SET
       verdict = excluded.verdict, start_ms = excluded.start_ms, end_ms = excluded.end_ms,
       duration_ms = excluded.duration_ms, ip_hash = excluded.ip_hash, created_at = excluded.created_at`,
  ).bind(b.key, b.category, b.clientId, ipHash, b.verdict, seg.startMs, seg.endMs, seg.durationMs, now).run();

  // 重新统计（只算与这一段一致的反馈）
  const fb = await env.DB.prepare(
    'SELECT id, verdict, start_ms, end_ms, duration_ms FROM feedback WHERE ep_key = ?1 AND category = ?2',
  ).bind(b.key, b.category).all();
  const segShape = { start_ms: seg.startMs, end_ms: seg.endMs, duration_ms: seg.durationMs };
  const mine = fb.results.filter((f) => sameSegment(f, segShape));
  const ups = mine.filter((f) => f.verdict === 'up').length;
  const downs = mine.filter((f) => f.verdict === 'down').length;
  const supporters = seg.members.length + ups;
  if (!shouldHide(supporters, downs)) return json(200, { ok: true, hidden: false, supporters, downs });

  await env.DB.prepare(
    `UPDATE submission SET hidden = 1 WHERE id IN (${inList(seg.members.length, 1)})`,
  ).bind(...seg.members).run();
  // 这段的反馈一并清掉：同一位置日后有人重新标，重新计票
  const fbIds = mine.map((f) => f.id);
  await env.DB.prepare(`DELETE FROM feedback WHERE id IN (${inList(fbIds.length, 1)})`).bind(...fbIds).run();
  return json(200, { ok: true, hidden: true, supporters, downs });
}

async function handleGet(request, env, url) {
  const key = url.searchParams.get('key') ?? '';
  if (!/^[0-9a-f]{40}$/.test(key)) return fail(400, 'bad_key', '影片标识无效');
  const clientId = request.headers.get('x-xiugou-client') ?? '';
  return json(200, { ok: true, ...(await loadEpisode(env, key, clientId)) });
}

async function handlePost(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return fail(400, 'bad_body', '请求格式错误');
  }
  const invalid = validate(body);
  if (invalid) return fail(400, invalid.code, invalid.message);

  const now = Date.now();
  const ipHash = await ipHashOf(request, env);

  // 限频：同 IP 每小时 / 每天、同客户端每天
  const counts = await env.DB.prepare(
    `SELECT
       (SELECT COUNT(*) FROM submission WHERE ip_hash = ?1 AND created_at > ?2) AS ip_hour,
       (SELECT COUNT(*) FROM submission WHERE ip_hash = ?1 AND created_at > ?3) AS ip_day,
       (SELECT COUNT(*) FROM submission WHERE client_id = ?4 AND created_at > ?3) AS client_day`,
  ).bind(ipHash, now - HOUR, now - 24 * HOUR, body.clientId).first();
  if (counts.ip_hour >= LIMIT_IP_HOUR || counts.ip_day >= LIMIT_IP_DAY || counts.client_day >= LIMIT_CLIENT_DAY) {
    return fail(429, 'rate_limited', '提交太频繁，请稍后再试');
  }

  const title = typeof body.title === 'string' ? body.title.slice(0, 100) : null;
  const episode = Number.isInteger(body.episode) ? body.episode : null;
  try {
    await env.DB.prepare(
      `INSERT INTO submission
         (ep_key, client_id, ip_hash, category, action, start_ms, end_ms, duration_ms, title, episode, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`,
    ).bind(body.key, body.clientId, ipHash, body.category, body.action,
      body.startMs, body.endMs, body.durationMs, title, episode, now).run();
  } catch (e) {
    // 唯一索引 one_shot：每人每集每种分类只能提交一次（§44 拍板 Q1）
    if (String(e?.message ?? e).includes('UNIQUE')) {
      return fail(409, 'already_submitted', '这一集的这种分类你已经提交过了');
    }
    throw e;
  }
  return json(201, { ok: true, ...(await loadEpisode(env, body.key, body.clientId)) });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname === '/v1/health') return json(200, { ok: true });
      if (!env.CLIENT_TOKEN) return fail(503, 'not_configured', '服务未配置令牌');
      if (!safeEqual(request.headers.get('x-xiugou-token') ?? '', env.CLIENT_TOKEN)) {
        return fail(401, 'unauthorized', '令牌无效');
      }
      if (url.pathname === '/v1/segments') {
        if (request.method === 'GET') return await handleGet(request, env, url);
        if (request.method === 'POST') return await handlePost(request, env);
        return fail(405, 'method', '不支持的请求方法');
      }
      if (url.pathname === '/v1/feedback' && request.method === 'POST') return await handleFeedback(request, env);
      return fail(404, 'not_found', '接口不存在');
    } catch (e) {
      console.error(e);
      return fail(500, 'internal', '服务内部错误');
    }
  },
};
