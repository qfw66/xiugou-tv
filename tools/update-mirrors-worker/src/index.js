const TTL_SECONDS = 3600;
const MAX_MIRRORS = 16;
const CONTROL_CHARACTERS = /[\p{Cc}\p{Cf}]/u;

// invariant: one statement reads revision and rows from the same D1 snapshot.
const MANIFEST_QUERY = `
  SELECT manifest.singleton, manifest.revision,
         (SELECT COUNT(*) FROM mirror_manifest) AS manifest_count,
         (SELECT COUNT(*) FROM mirrors) AS mirror_count,
         mirrors.id, mirrors.label, mirrors.prefix,
         mirrors.proxies_api, mirrors.enabled, mirrors.priority
  FROM mirror_manifest AS manifest
  LEFT JOIN mirrors ON 1 = 1
  ORDER BY mirrors.priority ASC, mirrors.id ASC
`;

function requireValid(condition, message) {
  if (!condition) throw new Error(message);
}

function canonicalPrefix(prefix) {
  requireValid(
    typeof prefix === 'string' && prefix.length >= 1 && prefix.length <= 512 &&
      prefix.endsWith('/') && !/[\s\\%?#]/u.test(prefix),
    'Invalid mirror prefix',
  );
  const parts = /^https:\/\/([^/]+)(\/.*)$/i.exec(prefix);
  requireValid(parts !== null, 'Mirror prefix must use HTTPS');
  const authority = /^([a-z0-9.-]+)(?::443)?$/i.exec(parts[1]);
  requireValid(authority !== null, 'Invalid mirror authority');
  const hostname = authority[1].toLowerCase();
  const labels = hostname.split('.');
  requireValid(
    hostname.length <= 253 && labels.length >= 2 &&
      labels.every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label)) &&
      !/(?:^|\.)(?:localhost|local|internal|localdomain)$/i.test(hostname) &&
      !hostname.endsWith('.home.arpa') && /^[a-z]{2,63}$/i.test(labels.at(-1)),
    'Mirror prefix must use a public DNS hostname',
  );
  const path = parts[2];
  requireValid(
    /^\/[a-z0-9._~!$&'()*+,;=:@/\-]*$/i.test(path) &&
      !path.split('/').some((segment) => segment === '.' || segment === '..'),
    'Invalid mirror path',
  );
  const url = new URL(prefix);
  requireValid(
    url.protocol === 'https:' && url.hostname === hostname && url.port === '' &&
      url.username === '' && url.password === '' && url.search === '' && url.hash === '' &&
      url.pathname === path,
    'Mirror prefix must not require URL normalization',
  );
  return url.href;
}

async function readManifest(db) {
  const result = await db.prepare(MANIFEST_QUERY).all();
  requireValid(result?.success === true && Array.isArray(result.results), 'D1 query failed');
  const rows = result.results;
  requireValid(rows.length > 0, 'Missing manifest metadata');
  const revision = rows[0]?.revision;
  const mirrorCount = rows[0]?.mirror_count;
  requireValid(Number.isSafeInteger(revision) && revision > 0, 'Invalid manifest revision');
  requireValid(
    Number.isSafeInteger(mirrorCount) && mirrorCount >= 0 && rows.length === Math.max(1, mirrorCount),
    'Invalid mirror row count',
  );
  const ids = new Set();
  const prefixes = new Set();
  const mirrors = [];
  for (const row of rows) {
    requireValid(
      row?.singleton === 1 && row.manifest_count === 1 && row.revision === revision &&
        row.mirror_count === mirrorCount,
      'Invalid manifest metadata',
    );
    if (row.id === null) {
      requireValid(
        mirrorCount === 0 && rows.length === 1 &&
          ['label', 'prefix', 'proxies_api', 'enabled', 'priority'].every((key) => row[key] === null),
        'Invalid empty manifest',
      );
      continue;
    }
    requireValid(
      typeof row.id === 'string' && /^[a-z0-9][a-z0-9-]{0,47}$/.test(row.id),
      'Invalid mirror id',
    );
    requireValid(
      typeof row.label === 'string' && row.label.trim().length >= 1 && [...row.label].length <= 80 &&
        !CONTROL_CHARACTERS.test(row.label),
      'Invalid mirror label',
    );
    requireValid(row.proxies_api === 0 || row.proxies_api === 1, 'Invalid proxies_api flag');
    requireValid(row.enabled === 0 || row.enabled === 1, 'Invalid enabled flag');
    requireValid(Number.isSafeInteger(row.priority), 'Invalid mirror priority');
    const prefix = canonicalPrefix(row.prefix);
    requireValid(!ids.has(row.id) && !prefixes.has(prefix), 'Duplicate mirror id or prefix');
    ids.add(row.id);
    prefixes.add(prefix);
    if (row.enabled === 1) {
      mirrors.push({
        id: row.id,
        label: row.label,
        prefix: row.prefix,
        proxiesApi: row.proxies_api === 1,
      });
    }
  }
  requireValid(mirrors.length <= MAX_MIRRORS, 'Too many enabled mirrors');
  return { version: 1, revision, ttlSeconds: TTL_SECONDS, mirrors };
}

async function entityTag(body) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body));
  return `"${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')}"`;
}

function matchesEntityTag(header, etag) {
  return header !== null && header.split(',').some((value) => {
    const candidate = value.trim();
    return candidate === '*' || candidate.replace(/^W\//, '') === etag;
  });
}

function errorResponse(status, error, extraHeaders = {}) {
  return Response.json({ error }, {
    status,
    headers: {
      'Cache-Control': 'no-store',
      'Access-Control-Allow-Origin': '*',
      ...extraHeaders,
    },
  });
}

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== '/v1/mirrors') {
      return errorResponse(404, 'Not found');
    }
    if (request.method !== 'GET') {
      return errorResponse(405, 'Method not allowed', { Allow: 'GET' });
    }
    try {
      const manifest = await readManifest(env?.DB);
      const body = JSON.stringify(manifest);
      const etag = await entityTag(body);
      const headers = {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': `public, max-age=${TTL_SECONDS}`,
        ETag: etag,
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Expose-Headers': 'ETag',
        'X-Content-Type-Options': 'nosniff',
      };
      if (matchesEntityTag(request.headers.get('If-None-Match'), etag)) {
        return new Response(null, { status: 304, headers });
      }
      return new Response(body, { status: 200, headers });
    } catch (error) {
      console.error('update-mirrors: manifest unavailable', error instanceof Error ? error.message : 'D1 read failed');
      return errorResponse(503, 'Mirror manifest unavailable', { 'Retry-After': '60' });
    }
  },
};
