# Update mirror manifest Worker

A zero-dependency JavaScript ES module Cloudflare Worker backed by D1. It serves the app's ordered update-mirror configuration at `GET /v1/mirrors`. Operators edit D1 directly; the Worker has no HTTP administration or write endpoint.

## Why D1

D1 is recommended here because the requested operating model is **database updates**: edit rows, toggle a mirror, or change its priority. [Cloudflare's D1 documentation](https://developers.cloudflare.com/d1/) describes managed SQL with SQLite semantics. This implementation uses SQL constraints and triggers to keep mirror edits and revision changes in the same statement.

[Workers KV](https://developers.cloudflare.com/kv/concepts/how-kv-works/) is a reasonable alternative for a rarely updated, whole-document configuration with heavy read traffic. It is a key-value store with eventual consistency: Cloudflare documents that changes can take 60 seconds or more to appear in other locations. A KV implementation would publish a complete validated JSON document and manage its revision in the publishing process. D1 fits the requested row-editing workflow without adding that publisher.

The HTTP response is cacheable for one hour regardless of the storage choice. A database update does not purge responses that clients or intermediary caches already hold.

## Files and local tests

- [src/index.js](./src/index.js): Worker, validation, deterministic JSON and SHA-256 ETags.
- [migrations/0001_schema.sql](./migrations/0001_schema.sql): tables, constraints, automatic revision triggers.
- [migrations/0002_seed.sql](./migrations/0002_seed.sql): the eight supplied starting candidates.
- [wrangler.toml.example](./wrangler.toml.example): Worker and D1 binding configuration.
- [test/worker.test.js](./test/worker.test.js): Node built-in tests running the actual SQL against built-in SQLite, including the Worker query.

Tests require Node 24 or newer for `node:sqlite`. The deployed Worker uses only Workers/Web APIs and D1, with no Node compatibility flag or package dependencies. From this directory:

```sh
node --test
```

The supplied Windows runtime can run the same suite without installing anything:

```powershell
& '..\..\companion\noderuntime\node.exe' --test
```

Tests cover the seed and order, SQL revision enforcement, enable/disable/reorder behavior, the 16-entry limit, identifier/label/URL validation, duplicates, corrupt database state, conditional requests, and read-only routing. Local SQLite plus a small D1 result adapter verifies the SQL/Worker boundary; it does not replace a deployment smoke test in Cloudflare.

## Response contract

```json
{
  "version": 1,
  "revision": 9,
  "ttlSeconds": 3600,
  "mirrors": [
    {
      "id": "gh-proxy-com",
      "label": "gh-proxy.com",
      "prefix": "https://gh-proxy.com/",
      "proxiesApi": true
    }
  ]
}
```

This shortened example shows one entry; the seed produces eight. Revision starts at 1 for an empty schema and becomes 9 after the eight seed inserts. Treat revisions as increasing positive safe integers, not consecutive document numbers.

| Field or behavior | Rule |
| --- | --- |
| `version` | Always `1`. |
| `revision` | Integer from `1` to `9007199254740991`, read from the single metadata row. |
| `ttlSeconds` | Always `3600`. |
| `mirrors` | Zero to 16 enabled entries, ordered by `priority ASC, id ASC`. |
| `id` | Matches `^[a-z0-9][a-z0-9-]{0,47}$`; unique. |
| `label` | 1–80 Unicode code points; no Unicode control or format characters. |
| `prefix` | At most 512 ASCII characters; absolute HTTPS URL ending in `/`. |
| `proxiesApi` | JSON boolean, derived from D1's integer `0` or `1`. |

Prefix validation requires a DNS hostname with at least two nonempty labels, each 1–63 ASCII letters/digits/hyphens with no leading or trailing hyphen; total hostname length is at most 253. ASCII punycode names are permitted. IPv4, IPv6, alternative numeric-IP spellings, single-label hosts, `localhost` and its subdomains, `.local`, and `.internal` are rejected. Only the default HTTPS port or explicit `:443` is allowed. User information, query strings (including empty `?`), fragments (including empty `#`), whitespace, backslashes and percent encoding are rejected. Paths use ASCII URL path characters, with no `.` or `..` segments. Validation happens before URL parsing can silently normalize unsafe syntax.

The supplied prefix spelling is preserved in JSON. Duplicate detection canonicalizes the scheme, hostname and default port, so `https://EXAMPLE.com:443/` duplicates `https://example.com/`. IDs and canonical prefixes must be unique across enabled and disabled rows. Labels may repeat. Every stored row is validated, including disabled rows; disabling a malformed row does not hide invalid database state. DNS syntax checks do not verify resolution, ownership, reachability, or proxy capability.

An empty `mirrors` array is a successful, intentional instruction to **disable all mirrors**. There is no server-side substitution of the seed when the array is empty.

Successful responses include `Content-Type: application/json; charset=utf-8`, `Cache-Control: public, max-age=3600`, and a quoted SHA-256 `ETag` derived from the exact JSON bytes. `If-None-Match` accepts matching strong or weak tags, comma-separated alternatives, and `*`; a match returns a bodyless `304` with the same cache headers. Revision and rows come from one SQL statement. Validation happens before conditional request handling, so an invalid database cannot produce `304`.

Missing bindings, D1 errors, invalid metadata, unsafe rows, duplicates, or more than 16 enabled rows produce `503` with `Cache-Control: no-store`, `Retry-After: 60`, and a generic JSON error. No partial list is served. Worker logs use the `update-mirrors: manifest unavailable` marker. Other paths return `404`; methods other than GET on this path return `405` and `Allow: GET`. Responses allow public browser reads with `Access-Control-Allow-Origin: *`; the endpoint is intended for public mirror URLs, never secrets.

## Create, migrate, and deploy

These are operator instructions; running tests does not install tooling, create a database, deploy a Worker, or contact a mirror. Use an already available Wrangler CLI authenticated to the intended Cloudflare account. See the official [D1 getting-started guide](https://developers.cloudflare.com/d1/get-started/) and [D1 migration documentation](https://developers.cloudflare.com/d1/reference/migrations/).

Run from this directory:

```sh
wrangler d1 create xiugou-update-mirrors
cp wrangler.toml.example wrangler.toml
```

In the copied configuration, replace `REPLACE_WITH_D1_DATABASE_ID` with the returned database ID. Keep the binding name `DB`. Choose a different Worker/database name if those names are already in use, keeping CLI commands and configuration consistent. The local configuration and Wrangler state are ignored by the included [.gitignore](./.gitignore).

Apply both ordered migrations to a local database, then optionally start a local Worker:

```sh
wrangler d1 migrations apply xiugou-update-mirrors --local
wrangler dev
```

For the selected Cloudflare account/database, apply the migrations remotely and deploy:

```sh
wrangler d1 migrations apply xiugou-update-mirrors --remote
wrangler deploy
```

Use the HTTPS Worker URL returned by Wrangler, or your configured custom domain, with `/v1/mirrors` appended. Perform a live smoke check, then repeat with the returned ETag in `If-None-Match` to check the `304` response:

```sh
curl -i https://xiugou-update-mirrors.YOUR-SUBDOMAIN.workers.dev/v1/mirrors
curl -i -H 'If-None-Match: "PASTE-THE-RETURNED-HASH"' https://xiugou-update-mirrors.YOUR-SUBDOMAIN.workers.dev/v1/mirrors
```

On Windows PowerShell use `curl.exe` if `curl` resolves to another command. For production errors, inspect Worker logs (for example `wrangler tail`) and validate D1 rows before retrying.

## Configure the app

Set the app updater's `mirrorsUrl` configuration value to the complete HTTPS endpoint, for example:

```json
{
  "mirrorsUrl": "https://xiugou-update-mirrors.YOUR-SUBDOMAIN.workers.dev/v1/mirrors"
}
```

A build can instead supply the compile-time default using `XIUGOU_UPDATE_MIRRORS_URL`:

```sh
flutter build apk --dart-define=XIUGOU_UPDATE_MIRRORS_URL=https://xiugou-update-mirrors.YOUR-SUBDOMAIN.workers.dev/v1/mirrors
```

These are configuration examples for the consuming app; this directory contains only the Worker. The endpoint must be the manifest URL, not an individual proxy prefix. A valid empty manifest disables mirror use on the client.

## SQL operations and revision discipline

`mirror_manifest` has exactly one row, `singleton = 1`. `mirrors` stores `id`, `label`, `prefix`, `proxies_api`, `enabled`, and `priority`. Boolean columns use `0` or `1`. Priority is a safe integer; lower numbers come first, with ID as a stable tie-breaker.

**Every SQL insert, update, toggle, reorder, or delete MUST increase the revision.** The migration's `AFTER INSERT/UPDATE/DELETE` triggers enforce this automatically and atomically for each affected mirror row. Do not drop these triggers, reset the revision, or replace the metadata row. Multi-row updates increase revision once per row, which is intentional. A failed update rolls back its revision increment. At the maximum safe revision, further mirror edits fail rather than producing an imprecise JSON number.

Inspect current data:

```sh
wrangler d1 execute xiugou-update-mirrors --remote --command "SELECT * FROM mirror_manifest; SELECT * FROM mirrors ORDER BY priority, id;"
```

Edit a label or prefix (the trigger increases revision):

```sql
UPDATE mirrors SET label = 'GitHub proxy' WHERE id = 'gh-proxy-com';
UPDATE mirrors SET prefix = 'https://new-proxy.example.com/' WHERE id = 'tvv-tw';
```

Disable or enable a mirror:

```sql
UPDATE mirrors SET enabled = 0 WHERE id = 'tvv-tw';
UPDATE mirrors SET enabled = 1 WHERE id = 'tvv-tw';
```

Reorder two mirrors in one statement, so the swap and its revision increments are atomic:

```sql
UPDATE mirrors
SET priority = CASE id WHEN 'gh-proxy-com' THEN 10 WHEN 'down-mxw-xx-kg' THEN 20 END
WHERE id IN ('gh-proxy-com', 'down-mxw-xx-kg');
```

Intentionally disable all mirrors:

```sql
UPDATE mirrors SET enabled = 0;
```

Insert and delete examples (use an actual operator-verified hostname in production):

```sql
INSERT INTO mirrors (id, label, prefix, proxies_api, enabled, priority)
VALUES ('operator-mirror', 'Operator mirror', 'https://mirror.example.com/', 0, 0, 90);
DELETE FROM mirrors WHERE id = 'operator-mirror';
```

Execute a statement through Wrangler, or use the D1 dashboard SQL console:

```sh
wrangler d1 execute xiugou-update-mirrors --remote --command "UPDATE mirrors SET enabled = 0 WHERE id = 'tvv-tw';"
```

D1 constraints catch basic types and exact duplicates, while the Worker also checks the complete hostname/path/manifest contract. Test uncertain SQL changes against `--local` and inspect the manifest before applying them remotely. To correct an operator mistake, restore the prior row values using normal UPDATE statements; keep the new, higher revision. The one-hour HTTP cache can delay client-visible corrections.

## Seed candidates

The seed preserves this supplied order:

| Priority | Prefix | `proxiesApi` |
| --- | --- | --- |
| 10 | `https://down.mxw.xx.kg/` | false |
| 20 | `https://gh-proxy.com/` | true |
| 30 | `https://tvv.tw/` | false |
| 40 | `https://fastgit.cc/` | false |
| 50 | `https://ghproxy.imciel.com/` | false |
| 60 | `https://ghproxy.felicity.land/` | false |
| 70 | `https://gg.z321.cc.cd/` | false |
| 80 | `https://xsadwsd.kdns.fr/` | false |

These are supplied starting candidates, not a claim that all are functional or trustworthy. No live mirror availability or API capability check is performed by this Worker or its tests. Only `gh-proxy.com` is marked `proxiesApi: true` as requested. Operators should verify candidates for their actual release assets and API use before relying on them.
