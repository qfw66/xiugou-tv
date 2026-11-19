import { mkdirSync, writeFileSync } from 'node:fs';
import { contractFixtures } from '../test/contract-fixtures.js';

const target = new URL('../test/fixtures/manifest-contract.json', import.meta.url);
mkdirSync(new URL('.', target), { recursive: true });
const fixtures = await contractFixtures();
writeFileSync(target, JSON.stringify(fixtures, null, 2) + '\n', 'utf8');
console.log(`Exported ${fixtures.length} Worker/SQLite cases to ${target.pathname}`);
