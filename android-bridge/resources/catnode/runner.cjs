'use strict';
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const readline = require('node:readline');
const os = require('node:os');
const {createHash} = require('node:crypto');
const {gunzipSync} = require('node:zlib');
const {isDeepStrictEqual} = require('node:util');
const {AsyncLocalStorage} = require('node:async_hooks');
const requestContext = new AsyncLocalStorage();
// invariant: source-advertised addresses describe this loopback-only child, not host LAN interfaces.
os.networkInterfaces = () => ({loopback: [
  {address: '127.0.0.1', netmask: '255.0.0.0', family: 'IPv4',
    mac: '00:00:00:00:00:00', internal: true, cidr: '127.0.0.1/8'},
]});
require('node:module').syncBuiltinESMExports();
const output = process.stdout.write.bind(process.stdout);
const stringify = JSON.stringify.bind(JSON);
const parse = JSON.parse.bind(JSON);
const exit = process.exit.bind(process);
const frame = value => output('XIUGOU_CAT ' + stringify(value) + '\n');
const limit = 8 * 1024 * 1024;
let plugin, control, stopping = false, booted = false;
let servicePort = 0;
const timers = {setTimeout, clearTimeout};
let profileAdapter = false, profileRestored = false, snapshotConfirmed = false, configurationRevision = 0;
let configurationGeneration = 0;
let flushProfile = async () => {};
const siteRevisions = new Map();
const pendingRequests = new Set();
// Bundles also reach the host callback through a loopback HTTP bridge. Carry
// correlation only to that bridge; never send host request IDs to upstreams.
const nativeRequest = http.request;
http.request = function (...args) {
  const request = nativeRequest.apply(this, args);
  const requestId = requestContext.getStore();
  const address = control?.address();
  if (requestId && address && request.path === '/msg' &&
      request.getHeader('host') === '127.0.0.1:' + address.port) {
    request.setHeader('X-Xiugou-Request', requestId);
  }
  return request;
};
require('node:module').syncBuiltinESMExports();

async function currentProfile() {
  const compressed = await new Promise((resolve, reject) => {
    const request = http.get({host: '127.0.0.1', port: servicePort,
      path: '/website/backup/', headers: {Connection: 'close'}}, response => {
      if (response.statusCode !== 200) {
        response.resume(); reject(new Error('Cat backup unavailable')); return;
      }
      const chunks = []; let size = 0;
      response.on('data', chunk => {
        size += chunk.length;
        if (size > limit) request.destroy(new Error('Cat backup exceeds limit'));
        else chunks.push(chunk);
      });
      response.on('error', reject);
      response.on('end', () => resolve(Buffer.concat(chunks)));
    });
    const deadline = timers.setTimeout(() => request.destroy(new Error('Cat backup timeout')), 500);
    request.on('close', () => timers.clearTimeout(deadline));
    request.on('error', reject);
  });
  const snapshot = parse(gunzipSync(compressed, {maxOutputLength: limit}).toString('utf8'));
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
    throw new Error('Invalid Cat backup');
  }
  // invariant: this pinned bundle sends these fields as arrays in saveProfile.
  for (const value of Object.values(snapshot)) {
    if (!value || typeof value !== 'object') continue;
    for (const field of ['order', 'channels', 'plugins']) {
      if (typeof value[field] === 'string') value[field] = value[field].split(',').filter(Boolean);
    }
    if (value.filter && typeof value.filter === 'object') {
      for (const field of ['include', 'exclude']) {
        if (typeof value.filter[field] === 'string') value.filter[field] = [value.filter[field]];
      }
    }
  }
  return snapshot;
}
const listeners = new Set();
const nativeListen = net.Server.prototype.listen;
net.Server.prototype.listen = function (...args) {
  if (args[0] && typeof args[0] === 'object') {
    args[0] = {...args[0], host: '127.0.0.1'};
  } else if (typeof args[0] === 'number') {
    if (typeof args[1] === 'string') args[1] = '127.0.0.1';
    else args.splice(1, 0, '127.0.0.1');
  }
  listeners.add(this);
  return nativeListen.apply(this, args);
};
// Source packages may write credentials to console; reserve stdout for the host protocol.
console.log = console.info = console.debug = console.warn = console.error = () => {};
process.stdout.write = process.stderr.write = (_chunk, encoding, callback) => {
  if (typeof encoding === 'function') encoding();
  if (typeof callback === 'function') callback();
  return true;
};

async function stop() {
  if (stopping) return;
  stopping = true;
  const deadline = timers.setTimeout(() => {
    frame({type: 'error', error: 'Cat shutdown timed out'}); exit(1);
  }, 800);
  let failed = false;
  try { await flushProfile(); }
  catch (_) { failed = true; frame({type: 'error', error: 'Cat final profile could not be saved'}); }
  try { if (plugin?.stop) await plugin.stop(); }
  catch (_) { failed = true; frame({type: 'error', error: 'Cat source could not stop'}); }
  for (const server of listeners) {
    try { server.closeAllConnections?.(); server.close(); } catch (_) {}
  }
  timers.clearTimeout(deadline);
  frame({type: 'stopped', profileSaved: snapshotConfirmed});
  exit(failed ? 1 : 0);
}

async function boot(input) {
  const state = path.resolve(input.state);
  const bundle = path.resolve(input.bundle);
  const configFile = path.resolve(input.config);
  profileAdapter = createHash('md5').update(fs.readFileSync(bundle)).digest('hex') ===
      'f0c67ae0db9c1310589065c6b473ded9';
  fs.mkdirSync(state, {recursive: true});
  process.chdir(state);
  Object.assign(process.env, {NODE_PATH: state, NODE_ENV: 'production',
    HOST: '127.0.0.1', PORT: '0', DEV_HTTP_PORT: '0', CATVOD_DISABLE_AUTOSTART: '1'});
  const profilePath = path.join(state, 'host-profile.json');
  let profile = {};
  try { profile = parse(fs.readFileSync(profilePath, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw new Error('Stored cat profile is unreadable'); }
  const initialProfile = parse(stringify(profile));
  const events = [];
  let finalSnapshotSaved = false;
  const callback = async message => {
    if (message.action === 'queryProfile') return profile;
    if (message.action === 'saveProfile') {
      if (finalSnapshotSaved) return {success: true, code: 0};
      if (profileAdapter && !profileRestored) return {success: false, code: -1};
      if (!message.opt || typeof message.opt !== 'object' || Array.isArray(message.opt)) {
        return {success: false, code: -1, message: 'Invalid profile'};
      }
      const candidate = {...message.opt};
      const data = stringify(candidate);
      if (Buffer.byteLength(data) > limit) throw new Error('Profile exceeds 8 MiB');
      fs.writeFileSync(profilePath + '.tmp', data, {encoding: 'utf8', mode: 0o600});
      fs.renameSync(profilePath + '.tmp', profilePath);
      profile = candidate;
      return {success: true, code: 0};
    }
    if (message.action === 'openInternalWebview' || message.action === 'openWebview') {
      let target;
      try { target = new URL(String(message.opt?.url || '')); } catch (_) {}
      if (!target || !['http:', 'https:'].includes(target.protocol) || target.username || target.password) {
        return {success: false, code: -1, message: 'Invalid web address'};
      }
      if (events.length >= 32) return {success: false, code: -1, message: 'Too many pending actions'};
      events.push({type: 'openWeb', url: target.href, requestId: requestContext.getStore() || ''});
      return {success: true, code: 0};
    }
    if (['toast', 'showToast'].includes(message.action)) {
      const text = String(message.opt?.text ?? message.opt?.message ?? message.opt ?? '').slice(0,1000);
      if (events.length < 32) events.push({type: 'toast', text, requestId: requestContext.getStore() || ''});
      return {success: true, code: 0};
    }
    return {success: false, code: -1, message: '此操作请使用猫源的本机网页配置'};
  };
  globalThis.messageToDart = callback;
  flushProfile = async () => {
    await Promise.all(pendingRequests);
    if (!profileAdapter || !servicePort || !profileRestored) return;
    await callback({action: 'saveProfile', opt: await currentProfile()});
    finalSnapshotSaved = true;
    snapshotConfirmed = true;
  };
  control = http.createServer(async (request, response) => {
    try {
      if (request.headers.origin) { response.writeHead(403); response.end(); return; }
      if (request.method === 'GET' && request.url === '/configuration-state') {
        response.setHeader('Content-Type', 'application/json');
        response.end(stringify({generation: configurationGeneration, reload: profileAdapter ? 'init' : 'restart'}));
        return;
      }
      if (request.method === 'GET' && request.url.startsWith('/site-revision?')) {
        const route = new URL(request.url, 'http://127.0.0.1').searchParams.get('route');
        const site = /^\/spider\/([^/]+)(?:\/[0-9]+)?$/.exec(route || '')?.[1];
        if (!site) { response.writeHead(400); response.end(); return; }
        response.setHeader('Content-Type', 'application/json');
        response.end(stringify({revision: configurationRevision + ':' + (siteRevisions.get(site) || 0)}));
        return;
      }
      if (request.method === 'GET' && request.url === '/config' && servicePort) {
        response.writeHead(302, {Location: 'http://127.0.0.1:' + servicePort + '/website'});
        response.end(); return;
      }
      if (request.method === 'GET' && (request.url === '/events' || request.url.startsWith('/events?'))) {
        const requestId = new URL(request.url, 'http://127.0.0.1').searchParams.get('requestId');
        const selected = events.filter(event => !requestId || event.requestId === requestId);
        for (let index = events.length - 1; index >= 0; index--) {
          if (selected.includes(events[index])) events.splice(index, 1);
        }
        response.setHeader('Content-Type', 'application/json');
        response.end(stringify(selected)); return;
      }
      if (request.method !== 'POST' || request.url !== '/msg') { response.writeHead(404); response.end(); return; }
      let length = 0; const chunks = [];
      for await (const chunk of request) {
        length += chunk.length;
        if (length > limit) throw new Error('Message exceeds limit');
        chunks.push(chunk);
      }
      const requestId = request.headers['x-xiugou-request'];
      const result = await requestContext.run(
        typeof requestId === 'string' && /^[a-f0-9-]{36}$/.test(requestId) ? requestId : '',
        () => callback(parse(Buffer.concat(chunks).toString('utf8'))));
      response.setHeader('Content-Type', 'application/json'); response.end(stringify(result));
    } catch (_) { response.writeHead(400); response.end('{"success":false,"code":-1}'); }
  });
  await new Promise(resolve => control.listen(0, '127.0.0.1', resolve));
  globalThis.catDartServerPort = () => control.address().port;
  let resolveReady;
  const listening = new Promise(resolve => { resolveReady = resolve; });
  globalThis.catServerFactory = handler => {
    const server = http.createServer((request, response) => {
      const backup = request.method === 'GET' && request.url === '/website/backup/';
      if (!backup) {
        if (stopping || (profileAdapter && !profileRestored)) { response.writeHead(503); response.end(); return; }
        const mutation = ['POST', 'PUT', 'DELETE', 'PATCH'].includes(request.method) &&
            request.url.startsWith('/website/');
        let finished;
        const pending = new Promise(resolve => { finished = resolve; });
        pendingRequests.add(pending);
        response.once('finish', () => {
          if (mutation && response.statusCode >= 200 && response.statusCode < 300) {
            configurationGeneration++;
            const site = /^\/website\/([^/?]+)\/urls?\/?(?:\?|$)/.exec(request.url)?.[1];
            if (site) siteRevisions.set(site, (siteRevisions.get(site) || 0) + 1);
            else configurationRevision++;
          }
          pendingRequests.delete(pending); finished();
        });
        response.once('close', () => { pendingRequests.delete(pending); finished(); });
      }
      const requestId = request.headers['x-xiugou-request'];
      requestContext.run(typeof requestId === 'string' && /^[a-f0-9-]{36}$/.test(requestId) ? requestId : '',
        () => handler(request, response));
    });
    server.listen = (_options, ...args) => net.Server.prototype.listen.call(server,
      {port: 0, host: '127.0.0.1'}, ...args.filter(value => typeof value === 'function'));
    server.once('listening', () => resolveReady(server.address()));
    return server;
  };
  const config = require(configFile);
  plugin = require(bundle);
  if (typeof plugin.start !== 'function' || typeof plugin.stop !== 'function') {
    throw new Error('Cat bundle must export start and stop');
  }
  await plugin.start({...config.default ?? config, debug: false});
  const address = await listening;
  if (address.address !== '127.0.0.1') throw new Error('Cat server must use loopback');
  servicePort = address.port;
  if (profileAdapter && Object.keys(initialProfile).length) {
    const until = Date.now() + 2000;
    while (!stopping && Date.now() < until) {
      try { if (isDeepStrictEqual(await currentProfile(), initialProfile)) { profileRestored = true; break; } }
      catch (_) {}
      await new Promise(resolve => timers.setTimeout(resolve, 20));
    }
    if (stopping) return;
    if (!profileRestored) throw new Error('Cat profile recovery was not confirmed');
  } else profileRestored = true;
  if (stopping) return;
  frame({type: 'ready', port: address.port, controlPort: control.address().port});
}

const lines = readline.createInterface({input: process.stdin, crlfDelay: Infinity});
lines.on('line', line => {
  if (Buffer.byteLength(line) > limit) { frame({type: 'error', error: 'Request too large'}); exit(1); }
  if (line === 'stop') { void stop(); return; }
  if (booted) return;
  booted = true;
  let request;
  try { request = parse(line); } catch (_) { frame({type: 'error', error: 'Invalid boot request'}); exit(1); }
  boot(request).catch(error => {
    frame({type: 'error', error: String(error.message || error).slice(0, 300)});
    exit(1);
  });
});
lines.on('close', () => { void stop(); });
process.on('SIGTERM', () => { void stop(); });
process.on('uncaughtException', () => { frame({type: 'error', error: 'Cat source crashed'}); exit(1); });
