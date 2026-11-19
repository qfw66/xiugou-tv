import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import worker from '../src/index.js';
import { contractFixtures } from './contract-fixtures.js';

test('Dart contract fixture equals real Worker and SQLite responses', async () => {
  const fixture = JSON.parse(readFileSync(new URL('./fixtures/manifest-contract.json', import.meta.url), 'utf8'));
  assert.deepEqual(await contractFixtures(), fixture);
});

const schema = readFileSync(new URL('../migrations/0001_schema.sql', import.meta.url), 'utf8');
const seed = readFileSync(new URL('../migrations/0002_seed.sql', import.meta.url), 'utf8');
const endpoint = 'https://mirrors.example.com/v1/mirrors';
const seedDomains = [
  'down.mxw.xx.kg',
  'gh-proxy.com',
  'tvv.tw',
  'fastgit.cc',
  'ghproxy.imciel.com',
  'ghproxy.felicity.land',
  'gg.z321.cc.cd',
  'xsadwsd.kdns.fr',
];

function database(t, { seeded = true, schemaSql = schema } = {}) {
  const sqlite = new DatabaseSync(':memory:');
  t.after(() => sqlite.close());
  sqlite.exec(schemaSql);
  if (seeded) sqlite.exec(seed);
  const statements = [];
  const env = {
    DB: {
      prepare(sql) {
        statements.push(sql);
        return {
          async all() {
            return { success: true, results: sqlite.prepare(sql).all() };
          },
        };
      },
    },
  };
  return { sqlite, env, statements };
}

function request(env, options = {}) {
  return worker.fetch(new Request(endpoint, options), env);
}

test('seed returns the ordered version-1 manifest through one real SQLite query', async (t) => {
  const { env, statements } = database(t);
  const response = await request(env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    version: 1,
    revision: 9,
    ttlSeconds: 3600,
    mirrors: seedDomains.map((domain) => ({
      id: domain.replaceAll('.', '-'),
      label: domain,
      prefix: `https://${domain}/`,
      proxiesApi: domain === 'gh-proxy.com',
    })),
  });
  assert.equal(statements.length, 1);
  assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8');
  assert.equal(response.headers.get('cache-control'), 'public, max-age=3600');
  assert.match(response.headers.get('etag'), /^"[a-f0-9]{64}"$/);
});

function insertMirror(sqlite, changes = {}) {
  const row = {
    id: 'example', label: 'Example', prefix: 'https://example.com/',
    proxies_api: 0, enabled: 1, priority: 10, ...changes,
  };
  sqlite.prepare(`INSERT INTO mirrors (id, label, prefix, proxies_api, enabled, priority)
    VALUES (?, ?, ?, ?, ?, ?)`).run(
    row.id, row.label, row.prefix, row.proxies_api, row.enabled, row.priority,
  );
}

async function assertUnavailable(env, options) {
  const response = await request(env, options);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('retry-after'), '60');
  assert.equal(response.headers.get('etag'), null);
  assert.deepEqual(await response.json(), { error: 'Mirror manifest unavailable' });
}

test('ETag is stable; conditional GET supports weak, list, wildcard and nonmatching tags', async (t) => {
  const { env } = database(t);
  const first = await request(env);
  const etag = first.headers.get('etag');
  assert.equal((await request(env)).headers.get('etag'), etag);
  for (const value of [etag, `W/${etag}`, `"unrelated", W/${etag}`, '*']) {
    const response = await request(env, { headers: { 'If-None-Match': value } });
    assert.equal(response.status, 304);
    assert.equal(await response.text(), '');
    assert.equal(response.headers.get('etag'), etag);
    assert.equal(response.headers.get('cache-control'), 'public, max-age=3600');
  }
  const changed = await request(env, { headers: { 'If-None-Match': '"unrelated"' } });
  assert.equal(changed.status, 200);
  assert.equal((await changed.json()).mirrors.length, 8);
});

test('a label edit advances revision and invalidates the old ETag', async (t) => {
  const { env, sqlite } = database(t);
  const first = await request(env);
  const etag = first.headers.get('etag');
  sqlite.exec("UPDATE mirrors SET label = 'GitHub proxy' WHERE id = 'gh-proxy-com'");
  const next = await request(env, { headers: { 'If-None-Match': etag } });
  assert.equal(next.status, 200);
  assert.notEqual(next.headers.get('etag'), etag);
  const body = await next.json();
  assert.equal(body.revision, 10);
  assert.equal(body.mirrors[1].label, 'GitHub proxy');
});

test('empty database and disabling every row intentionally return an empty list', async (t) => {
  const empty = database(t, { seeded: false });
  const emptyResponse = await request(empty.env);
  assert.equal(emptyResponse.status, 200);
  assert.deepEqual(await emptyResponse.json(), { version: 1, revision: 1, ttlSeconds: 3600, mirrors: [] });
  const { env, sqlite } = database(t);
  sqlite.exec('UPDATE mirrors SET enabled = 0');
  const response = await request(env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { version: 1, revision: 17, ttlSeconds: 3600, mirrors: [] });
});

test('priority reorders enabled rows; id breaks priority ties deterministically', async (t) => {
  const { env, sqlite } = database(t);
  sqlite.exec("UPDATE mirrors SET priority = 0 WHERE id = 'tvv-tw'");
  let body = await (await request(env)).json();
  assert.equal(body.mirrors[0].id, 'tvv-tw');
  assert.equal(body.revision, 10);
  sqlite.exec('UPDATE mirrors SET priority = 0');
  sqlite.exec("UPDATE mirrors SET enabled = 0 WHERE id = 'fastgit-cc'");
  body = await (await request(env)).json();
  const ids = body.mirrors.map((mirror) => mirror.id);
  assert.deepEqual(ids, [...ids].sort());
  assert.equal(ids.includes('fastgit-cc'), false);
});

test('16 enabled mirrors are valid; 17 are rejected; additional valid disabled rows are allowed', async (t) => {
  const { env, sqlite } = database(t, { seeded: false });
  for (let index = 0; index < 17; index++) {
    insertMirror(sqlite, { id: `m${index}`, prefix: `https://m${index}.example.com/`, priority: index,
      enabled: index < 16 ? 1 : 0 });
  }
  assert.equal((await (await request(env)).json()).mirrors.length, 16);
  sqlite.exec("UPDATE mirrors SET enabled = 1 WHERE id = 'm16'");
  await assertUnavailable(env);
});

test('valid boundary values include explicit port 443, ASCII subpaths and Unicode labels', async (t) => {
  const { env, sqlite } = database(t, { seeded: false });
  const longestPrefix = `https://length.example.com/${'a'.repeat(484)}/`;
  assert.equal(longestPrefix.length, 512);
  insertMirror(sqlite, { id: 'a'.repeat(48), label: '镜'.repeat(80), prefix: longestPrefix });
  insertMirror(sqlite, { id: 'b', label: 'B', prefix: 'HTTPS://OTHER.Example.com:443/a-b_c.v1/~user/' });
  const response = await request(env);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.mirrors[1].prefix, 'HTTPS://OTHER.Example.com:443/a-b_c.v1/~user/');
});

const invalidPrefixes = [
  '', 'http://example.com/', 'https://example.com', 'ftp://example.com/',
  'https://user@example.com/', 'https://user:password@example.com/',
  'https://example.com/?x=1', 'https://example.com/?', 'https://example.com/#fragment', 'https://example.com/#',
  'https://example.com:80/', 'https://example.com:444/', 'https://example.com:0443/',
  'https://127.0.0.1/', 'https://8.8.8.8/', 'https://127.1/', 'https://0x7f.1/',
  'https://2130706433/', 'https://[::1]/', 'https://[2001:db8::1]/',
  'https://localhost/', 'https://a.localhost/', 'https://a.local/', 'https://a.internal/',
  'https://singlelabel/', 'https://example.com./', 'https://-bad.example/', 'https://bad-.example/',
  'https://bad_name.example/', 'https://a..example/', `https://${'a'.repeat(64)}.example/`,
  `https://${Array(4).fill('a'.repeat(63)).join('.')}/`,
  'https://example.com/../', 'https://example.com/a/../../', 'https://example.com/./',
  'https://example.com/%2e%2e/', 'https://example.com/%2F/', 'https://example.com/%61/',
  'https://example.com/a\\b/', 'https://example.com/ /', 'https://example.com/\n/',
  'https://example.com/\u0000/', 'https://example.com/中文/', 'https://éxample.com/',
  `https://example.com/${'a'.repeat(493)}/`,
];

for (const prefix of invalidPrefixes) {
  test(`rejects unsafe prefix ${JSON.stringify(prefix)}`, async (t) => {
    const { env, sqlite } = database(t, { seeded: false });
    sqlite.exec('PRAGMA ignore_check_constraints = ON');
    insertMirror(sqlite, { prefix });
    await assertUnavailable(env);
  });
}

const invalidFields = [
  ['empty id', { id: '' }], ['uppercase id', { id: 'Bad' }], ['leading dash', { id: '-bad' }],
  ['long id', { id: 'a'.repeat(49) }], ['punctuation in id', { id: 'bad_id' }],
  ['trailing newline in id', { id: 'bad\n' }],
  ['empty label', { label: '' }], ['long label', { label: 'a'.repeat(81) }],
  ['C0 control label', { label: 'bad\nlabel' }], ['C1 control label', { label: 'bad\u0085label' }],
  ['format control label', { label: 'bad\u202elabel' }],
  ['invalid API flag', { proxies_api: 2 }], ['invalid enabled flag', { enabled: 2 }],
  ['invalid disabled row', { enabled: 0, prefix: 'http://example.com/' }],
];

for (const [name, changes] of invalidFields) {
  test(`invalid database row returns 503: ${name}`, async (t) => {
    const { env, sqlite } = database(t, { seeded: false });
    sqlite.exec('PRAGMA ignore_check_constraints = ON');
    insertMirror(sqlite, changes);
    await assertUnavailable(env);
  });
}

test('canonical-equivalent prefixes are rejected, including disabled duplicates', async (t) => {
  const { env, sqlite } = database(t, { seeded: false });
  insertMirror(sqlite);
  insertMirror(sqlite, { id: 'other', prefix: 'HTTPS://EXAMPLE.COM:443/', enabled: 0 });
  await assertUnavailable(env);
});

const unconstrainedSchema = `
  CREATE TABLE mirror_manifest (singleton, revision);
  INSERT INTO mirror_manifest VALUES (1, 1);
  CREATE TABLE mirrors (id, label, prefix, proxies_api, enabled, priority);
`;

for (const [name, sql] of [
  ['missing singleton', 'DELETE FROM mirror_manifest'],
  ['duplicate singleton', 'INSERT INTO mirror_manifest VALUES (1, 1)'],
  ['wrong singleton', 'UPDATE mirror_manifest SET singleton = 2'],
  ['zero revision', 'UPDATE mirror_manifest SET revision = 0'],
  ['negative revision', 'UPDATE mirror_manifest SET revision = -1'],
  ['fractional revision', 'UPDATE mirror_manifest SET revision = 1.5'],
  ['text revision', "UPDATE mirror_manifest SET revision = '1'"],
  ['unsafe revision', 'UPDATE mirror_manifest SET revision = 9007199254740992.0'],
  ['null mirror row', "INSERT INTO mirrors VALUES (NULL, 'bad', NULL, NULL, NULL, NULL)"],
  ['all-null mirror row', 'INSERT INTO mirrors VALUES (NULL, NULL, NULL, NULL, NULL, NULL)'],
]) {
  test(`invalid metadata returns 503: ${name}`, async (t) => {
    const { env, sqlite } = database(t, { seeded: false, schemaSql: unconstrainedSchema });
    sqlite.exec(sql);
    await assertUnavailable(env, { headers: { 'If-None-Match': '*' } });
  });
}

test('duplicate ids are rejected if database constraints are missing', async (t) => {
  const { env, sqlite } = database(t, { seeded: false, schemaSql: unconstrainedSchema });
  insertMirror(sqlite);
  insertMirror(sqlite, { prefix: 'https://other.example.com/' });
  await assertUnavailable(env);
});

for (const priority of [1.5, 'one', null, 9007199254740992]) {
  test(`invalid priority ${JSON.stringify(priority)} returns 503`, async (t) => {
    const { env, sqlite } = database(t, { seeded: false, schemaSql: unconstrainedSchema });
    insertMirror(sqlite, { priority });
    await assertUnavailable(env);
  });
}

test('missing binding, query errors and malformed D1 results are not cached', async () => {
  await assertUnavailable({});
  const secret = 'private database failure';
  await assertUnavailable({ DB: { prepare() { throw new Error(secret); } } });
  for (const result of [undefined, null, {}, { success: false, results: [] }, { success: true, results: {} },
    { success: true, results: [] }, { success: true, results: [null] }]) {
    await assertUnavailable({ DB: { prepare() { return { async all() { return result; } }; } } });
  }
});

test('invalid DB state is never hidden by conditional GET', async (t) => {
  const { env, sqlite } = database(t);
  const first = await request(env);
  sqlite.exec("UPDATE mirrors SET prefix = 'http://example.com/' WHERE id = 'tvv-tw'");
  await assertUnavailable(env, { headers: { 'If-None-Match': first.headers.get('etag') } });
});

test('unsupported paths and write methods never query D1', async () => {
  const env = { DB: { prepare() { assert.fail('D1 must not be queried'); } } };
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']) {
    const response = await request(env, { method });
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('allow'), 'GET');
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
  for (const path of ['/', '/admin', '/v1/mirrors/', '/v2/mirrors']) {
    const response = await worker.fetch(new Request(`https://mirrors.example.com${path}`), env);
    assert.equal(response.status, 404);
  }
});

test('schema enforces uniqueness, boolean types, and monotonic automatic revision', (t) => {
  const { sqlite } = database(t, { seeded: false });
  const revision = () => sqlite.prepare('SELECT revision FROM mirror_manifest').get().revision;
  assert.equal(revision(), 1);
  insertMirror(sqlite);
  assert.equal(revision(), 2);
  sqlite.exec("UPDATE mirrors SET enabled = 0, priority = -1 WHERE id = 'example'");
  assert.equal(revision(), 3);
  assert.throws(() => insertMirror(sqlite), /UNIQUE constraint/);
  assert.throws(() => insertMirror(sqlite, { id: 'another' }), /UNIQUE constraint/);
  assert.throws(() => sqlite.exec("UPDATE mirrors SET enabled = 2"), /CHECK constraint/);
  assert.throws(() => sqlite.exec("UPDATE mirrors SET proxies_api = 2"), /CHECK constraint/);
  assert.throws(() => sqlite.exec("UPDATE mirrors SET priority = 0.5"), /cannot store REAL/);
  assert.equal(revision(), 3);
  sqlite.exec("DELETE FROM mirrors WHERE id = 'example'");
  assert.equal(revision(), 4);
  assert.throws(() => sqlite.exec('UPDATE mirror_manifest SET revision = 4'), /revision must increase/);
  assert.throws(() => sqlite.exec('UPDATE mirror_manifest SET revision = 0'), /revision must increase/);
  assert.throws(() => sqlite.exec('DELETE FROM mirror_manifest'), /singleton cannot be deleted/);
  sqlite.exec('UPDATE mirror_manifest SET revision = 9007199254740991');
  assert.throws(() => insertMirror(sqlite), /CHECK constraint/);
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM mirrors').get().count, 0);
});
