// §44 Worker 自测：在本目录运行 `npm test`（= node --test test/worker.test.mjs，需 Node ≥ 22.5）
// 不需要 Cloudflare 账号——用 Node 内置 node:sqlite 模拟 D1，直接调用 Worker 的 fetch。
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

import worker from '../src/index.js';
import { merge, shouldHide, validate } from '../src/rules.js';

const here = new URL('.', import.meta.url);
const vectors = JSON.parse(readFileSync(new URL('vectors.json', here), 'utf8'));
const schema = readFileSync(new URL('../schema.sql', here), 'utf8');

const KEY = 'a'.repeat(40);
const base = { key: KEY, clientId: 'client-0000000000000001' };

test('校验：共享向量全部符合预期', () => {
  for (const v of vectors.validate) {
    const r = validate({ ...base, ...v.in });
    if (v.ok) assert.equal(r, null, v.name);
    else assert.equal(r?.code, v.code, v.name);
  }
});

test('合并：多数一致取中位数；分歧时多数胜；不同剪辑版本各自成簇', () => {
  let id = 0;
  const row = (s, e, d = 2700000, action = 'skip', t = 0) =>
    ({ id: ++id, category: 'intro', action, start_ms: s, end_ms: e, duration_ms: d, created_at: t });
  const out = merge([
    row(0, 90000), row(1000, 91000), row(0, 92000, 2700000, 'mute'), // 一致的三票
    row(0, 300000),                                                   // 离群一票
    row(0, 60000, 2400000),                                           // 另一个剪辑版本（短 5 分钟）
  ]);
  const main = out.find((o) => o.durationMs === 2700000);
  assert.deepEqual(
    { s: main.startMs, e: main.endMs, v: main.votes, t: main.total, a: main.action },
    { s: 0, e: 91000, v: 3, t: 4, a: 'skip' },
  );
  const other = out.find((o) => o.durationMs === 2400000);
  assert.equal(other.votes, 1);
  assert.equal(out.length, 2);
  assert.deepEqual(main.members, [1, 2, 3]);
});

test('合并：认可反馈计入票数；与该段不一致的反馈不算', () => {
  const rows = [{ id: 1, category: 'intro', action: 'skip', start_ms: 0, end_ms: 90000, duration_ms: 2700000, created_at: 0 }];
  const fb = (verdict, e = 90000) => ({ category: 'intro', verdict, start_ms: 0, end_ms: e, duration_ms: 2700000 });
  const [seg] = merge(rows, [fb('up'), fb('up'), fb('down'), fb('up', 200000)]);
  assert.equal(seg.votes, 3, '提交者 1 + 一致的认可 2');
});

test('撤下规则：异议 ≥ 2 且 ≥ 认可', () => {
  assert.equal(shouldHide(1, 1), false, '只有 1 个异议不撤');
  assert.equal(shouldHide(1, 2), true, '新片段 2 人撤销即撤下');
  assert.equal(shouldHide(3, 2), false, '认可多于异议不撤（防两人恶意反馈）');
  assert.equal(shouldHide(3, 3), true);
});

// ---- 用 node:sqlite 模拟 D1 绑定 ----
function fakeD1() {
  const db = new DatabaseSync(':memory:');
  db.exec(schema);
  const stmt = (sql) => {
    let args = [];
    const s = {
      bind: (...a) => { args = a; return s; },
      all: async () => ({ results: db.prepare(sql.replace(/\?(\d+)/g, '?')).all(...order(sql, args)) }),
      first: async () => db.prepare(sql.replace(/\?(\d+)/g, '?')).get(...order(sql, args)),
      run: async () => db.prepare(sql.replace(/\?(\d+)/g, '?')).run(...order(sql, args)),
    };
    return s;
  };
  // D1 的 ?N 是按编号绑定；node:sqlite 用位置绑定，这里按出现顺序展开
  const order = (sql, args) => [...sql.matchAll(/\?(\d+)/g)].map((m) => args[Number(m[1]) - 1]);
  return { prepare: stmt };
}

const env = () => ({ DB: fakeD1(), CLIENT_TOKEN: 'tk-test', IP_SALT: 'salt' });
const call = (e, method, path, body, headers = {}) =>
  worker.fetch(new Request(`https://w.test${path}`, {
    method,
    headers: { 'x-xiugou-token': 'tk-test', 'content-type': 'application/json', 'cf-connecting-ip': '1.2.3.4', ...headers },
    body: body ? JSON.stringify(body) : undefined,
  }), e);

const intro = (clientId, startMs = 0, endMs = 92000) => ({
  key: KEY, clientId, category: 'intro', action: 'skip', startMs, endMs, durationMs: 2700000, title: '测试', episode: 1,
});

test('Worker：令牌、提交、一次机会、多数一致、我已提交', async () => {
  const e = env();
  assert.equal((await call(e, 'GET', '/v1/health', null, { 'x-xiugou-token': '' })).status, 200);
  assert.equal((await call(e, 'GET', `/v1/segments?key=${KEY}`, null, { 'x-xiugou-token': 'wrong' })).status, 401);

  let r = await call(e, 'POST', '/v1/segments', intro('client-aaaaaaaaaaaaaaaa'));
  assert.equal(r.status, 201);
  let body = await r.json();
  assert.equal(body.segments[0].votes, 1);
  assert.deepEqual(body.submitted, ['intro']);

  // 同一人同一集同一分类：第二次拒绝
  r = await call(e, 'POST', '/v1/segments', intro('client-aaaaaaaaaaaaaaaa', 0, 95000));
  assert.equal(r.status, 409);
  assert.equal((await r.json()).code, 'already_submitted');

  // 同一人换分类可以
  r = await call(e, 'POST', '/v1/segments',
    { ...intro('client-aaaaaaaaaaaaaaaa'), category: 'outro', startMs: 2580000, endMs: 2700000 });
  assert.equal(r.status, 201);

  // 第二个人提交接近的时间 → 2 票
  await call(e, 'POST', '/v1/segments', intro('client-bbbbbbbbbbbbbbbb', 1000, 91000));
  r = await call(e, 'GET', `/v1/segments?key=${KEY}`, null, { 'x-xiugou-client': 'client-cccccccccccccccc' });
  body = await r.json();
  const seg = body.segments.find((s) => s.category === 'intro');
  assert.equal(seg.votes, 2);
  assert.deepEqual(body.submitted, [], '第三个人还没提交过');

  // 不合理的时间：拒绝且不入库
  r = await call(e, 'POST', '/v1/segments', intro('client-dddddddddddddddd', 1200000, 1290000));
  assert.equal(r.status, 400);
  assert.equal((await r.json()).code, 'bad_position');
});

test('Worker：同 IP 限频', async () => {
  const e = env();
  let last;
  for (let i = 0; i < 31; i++) {
    const id = `client-${String(i).padStart(16, '0')}`;
    last = await call(e, 'POST', '/v1/segments', intro(id));
  }
  assert.equal(last.status, 429);
});

const feedback = (clientId, verdict, startMs = 0, endMs = 92000) => ({
  key: KEY, clientId, category: 'intro', verdict, startMs, endMs, durationMs: 2700000,
});

test('Worker 反馈：认可计票；提交者本人不计；两人撤销 → 隐藏，原提交者可重新提交', async () => {
  const e = env();
  await call(e, 'POST', '/v1/segments', intro('client-aaaaaaaaaaaaaaaa'));

  // 提交者本人反馈：忽略
  let r = await call(e, 'POST', '/v1/feedback', feedback('client-aaaaaaaaaaaaaaaa', 'down'));
  assert.deepEqual(await r.json(), { ok: true, hidden: false, ignored: true });

  // 第二个人没撤销 → 认可，票数 2
  r = await call(e, 'POST', '/v1/feedback', feedback('client-bbbbbbbbbbbbbbbb', 'up'));
  assert.equal((await r.json()).hidden, false);
  let body = await (await call(e, 'GET', `/v1/segments?key=${KEY}`)).json();
  assert.equal(body.segments[0].votes, 2);

  // 两人撤销：异议 2 ≥ 认可 2（提交者 + 1）→ 撤下
  r = await call(e, 'POST', '/v1/feedback', feedback('client-cccccccccccccccc', 'down', 1000, 91000));
  assert.equal((await r.json()).hidden, false, '1 个异议不撤');
  r = await call(e, 'POST', '/v1/feedback', feedback('client-dddddddddddddddd', 'down'));
  const res = await r.json();
  assert.equal(res.hidden, true);
  assert.deepEqual({ s: res.supporters, d: res.downs }, { s: 2, d: 2 });

  body = await (await call(e, 'GET', `/v1/segments?key=${KEY}`, null, { 'x-xiugou-client': 'client-aaaaaaaaaaaaaaaa' })).json();
  assert.equal(body.segments.length, 0, '撤下后不再下发');
  assert.deepEqual(body.submitted, [], '原提交者的「已提交」也解除');

  // 原提交者可重新提交（部分唯一索引只约束未隐藏的行）
  r = await call(e, 'POST', '/v1/segments', intro('client-aaaaaaaaaaaaaaaa', 0, 60000));
  assert.equal(r.status, 201);
  body = await r.json();
  assert.equal(body.segments[0].votes, 1, '旧反馈已清，新片段从 1 票开始');
});

test('Worker 反馈：认可多时两人撤销不撤下；改主意覆盖旧反馈；片段不存在 404', async () => {
  const e = env();
  await call(e, 'POST', '/v1/segments', intro('client-aaaaaaaaaaaaaaaa'));
  for (const c of ['b', 'c', 'd']) await call(e, 'POST', '/v1/feedback', feedback(`client-${c.repeat(16)}`, 'up'));
  await call(e, 'POST', '/v1/feedback', feedback('client-eeeeeeeeeeeeeeee', 'down'));
  let r = await (await call(e, 'POST', '/v1/feedback', feedback('client-ffffffffffffffff', 'down'))).json();
  assert.equal(r.hidden, false, '认可 4 > 异议 2');

  // b 改主意：up → down（同一人只算一条）
  r = await (await call(e, 'POST', '/v1/feedback', feedback('client-bbbbbbbbbbbbbbbb', 'down'))).json();
  assert.deepEqual({ s: r.supporters, d: r.downs }, { s: 3, d: 3 });
  assert.equal(r.hidden, true, '3 ≥ 3 撤下');

  r = await call(e, 'POST', '/v1/feedback', feedback('client-gggggggggggggggg', 'down'));
  assert.equal(r.status, 404);
});
