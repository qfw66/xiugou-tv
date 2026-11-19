import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';

const schema = readFileSync(new URL('../migrations/0001_schema.sql', import.meta.url), 'utf8');
const seed = readFileSync(new URL('../migrations/0002_seed.sql', import.meta.url), 'utf8');

// Shared boundary cases: generated from real Worker responses, consumed by Dart.
export async function contractFixtures() {
  const cases = [
    { name: 'seed', seed: true },
    { name: 'empty' },
    { name: 'unicode-label-uppercase-prefix', row: { label: '🎬'.repeat(80), prefix: 'HTTPS://Mirror.Example.COM:443/path/' } },
    ...['https://127.0.0.1/', 'https://x.local/', 'https://x.localdomain/', 'https://x.home.arpa/',
      'https://x.123/', 'https://user@mirror.example.com/', 'https://mirror.example.com/%2e%2e/',
      'https://mirror.example.com/../', 'https://mirror.example.com/中文/', 'https://mirror.example.com/?q=1']
      .map((prefix, i) => ({ name: `unsafe-prefix-${i}`, row: { prefix }, invalid: true })),
    ...[' ', 'a\u0000b', 'a\u0085b', 'a\u200bb', 'a\u202eb']
      .map((label, i) => ({ name: `unsafe-label-${i}`, row: { label }, invalid: true })),
  ];
  const fixtures = [];
  for (const item of cases) {
    const sqlite = new DatabaseSync(':memory:');
    try {
      sqlite.exec(schema);
      if (item.seed) sqlite.exec(seed);
      let row;
      if (item.row) {
        row = { id: 'example', label: 'Example', prefix: 'https://mirror.example.com/', proxies_api: 0, ...item.row };
        sqlite.prepare('INSERT INTO mirrors (id,label,prefix,proxies_api,enabled,priority) VALUES (?,?,?,?,1,1)')
          .run(row.id, row.label, row.prefix, row.proxies_api);
      }
      const response = await worker.fetch(new Request('https://config.example.com/v1/mirrors'), {
        DB: { prepare: (sql) => ({ all: async () => ({ success: true, results: sqlite.prepare(sql).all() }) }) },
      });
      assert.equal(response.status, item.invalid ? 503 : 200, item.name);
      const payload = await response.json();
      fixtures.push({ name: item.name, workerStatus: response.status,
        // A malformed wire payload mirrors the same invalid D1 fields the Worker rejected.
        document: item.invalid ? { version: 1, revision: 2, ttlSeconds: 3600,
          mirrors: [{ id: row.id, label: row.label, prefix: row.prefix, proxiesApi: row.proxies_api === 1 }] } : payload });
    } finally { sqlite.close(); }
  }
  return fixtures;
}
