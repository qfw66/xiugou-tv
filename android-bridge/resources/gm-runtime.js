// Browser interfaces required by GM user scripts. Site rules remain in userScript/@require.
(() => {
    const nodes = new Map(), ready = [], timers = new Map();
    let timerId = 0;
    const decode = raw => JSON.parse(raw);
    globalThis.window = globalThis;
    globalThis.unsafeWindow = globalThis;
    globalThis.self = globalThis;
    // Metadata object every userscript manager defines; scripts read it at top level.
    globalThis.GM_info = {script: {name: 'GmSpider', namespace: 'gmspider', version: '0', grant: ['unsafeWindow']}, scriptHandler: 'GmSpider', version: '1.0'};
    globalThis.console = {log() {}, debug() {}, info() {}, warn() {}, error() {}};
    globalThis.URL = class URL {
        constructor(value, base) { Object.assign(this, decode(__gmUrl(String(value), base === undefined ? '' : String(base)))); }
        toString() { return this.href; }
        toJSON() { return this.href; }
    };
    globalThis.location = new URL(__gmPageUrl);
    globalThis.navigator = {userAgent: __gmUa, language: 'zh-CN', languages: ['zh-CN', 'en']};
    globalThis.performance = {now: () => Date.now(), getEntriesByType: () => []};
    globalThis.setTimeout = (fn, delay = 0, ...args) => {
        const id = ++timerId;
        timers.set(id, {fn: () => typeof fn === 'function' ? fn(...args) : (0, eval)(String(fn)), at: Date.now() + Math.max(0, Number(delay) || 0)});
        return id;
    };
    globalThis.clearTimeout = id => timers.delete(id);
    globalThis.setInterval = (fn, delay = 0) => {
        const id = ++timerId;
        const ms = Math.max(10, Number(delay) || 0);
        timers.set(id, {fn, at: Date.now() + ms, interval: ms});
        return id;
    };
    globalThis.clearInterval = clearTimeout;
    globalThis.requestAnimationFrame = fn => setTimeout(() => fn(Date.now()), 16);
    globalThis.cancelAnimationFrame = clearTimeout;
    globalThis.__gmTick = () => {
        for (const [id, task] of Array.from(timers)) {
            if (task.at > Date.now()) continue;
            if (task.interval) task.at = Date.now() + task.interval;
            else timers.delete(id);
            task.fn();
        }
    };
    globalThis.MutationObserver = class { constructor(fn) { this.fn = fn; } observe() {} disconnect() {} };
    globalThis.Event = class { constructor(type) { this.type = type; } preventDefault() {} stopPropagation() {} };
    globalThis.AbortController = class { constructor() { this.signal = {aborted: false}; } abort() { this.signal.aborted = true; } };
    globalThis.atob = value => __gmBase64(String(value), false);
    globalThis.btoa = value => __gmBase64(String(value), true);
    globalThis.localStorage = globalThis.sessionStorage = {
        getItem: key => __gmStorage(String(key), '', 'get'),
        setItem: (key, value) => __gmStorage(String(key), String(value), 'set'),
        removeItem: key => __gmStorage(String(key), '', 'remove'),
        clear: () => __gmStorage('', '', 'clear')
    };
    function wrap(raw) {
        if (nodes.has(raw.id)) return nodes.get(raw.id);
        const n = {
            __gm: raw, nodeType: 1, tagName: raw.tagName.toUpperCase(),
            getAttribute(name) { return Object.hasOwn(raw.attrs, name) ? raw.attrs[name] : null; },
            hasAttribute(name) { return Object.hasOwn(raw.attrs, name); },
            setAttribute(name, value) { raw.attrs[name] = String(value); },
            querySelectorAll(selector) { return decode(__gmDom('find', raw.id, String(selector))).map(wrap); },
            querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
            closest(selector) { return decode(__gmDom('closest', raw.id, String(selector))).map(wrap)[0] || null; },
            matches(selector) { return __gmDom('matches', raw.id, String(selector)) === 'true'; },
            addEventListener() {}, removeEventListener() {},
            dispatchEvent(event) { return this.click(event); },
            click() { throw new Error('GM desktop: page click handler requires a browser'); },
            remove() { __gmDom('remove', raw.id, ''); },
            get textContent() { return decode(__gmDom('snapshot', raw.id, '')).text; },
            get innerText() { return this.textContent; },
            get innerHTML() { return decode(__gmDom('snapshot', raw.id, '')).html; },
            get outerHTML() { return raw.outerHtml; },
            get id() { return raw.attrs.id || ''; },
            get className() { return raw.attrs.class || ''; },
            get href() { return raw.attrs.href ? new URL(raw.attrs.href, location.href).href : ''; },
            get src() { return raw.attrs.src ? new URL(raw.attrs.src, location.href).href : ''; },
            get dataset() {
                const values = {};
                for (const key of Object.keys(raw.attrs)) if (key.startsWith('data-')) values[key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = raw.attrs[key];
                return values;
            },
            style: {}
        };
        n.classList = {contains: name => n.className.split(/\s+/).includes(name), add() {}, remove() {}};
        nodes.set(raw.id, n);
        return n;
    }
    function query(selector, root) {
        selector = String(selector);
        // jQuery positional filters apply to the matched set, including intermediate sets.
        const positional = /:(first|last|eq\((-?\d+)\)|gt\((-?\d+)\)|lt\((-?\d+)\))(?![\w-])/;
        const match = positional.exec(selector);
        if (match) {
            let values = query(selector.slice(0, match.index) || '*', root);
            const n = Number(match[2] || match[3] || match[4] || 0);
            if (match[1] === 'first') values = values.slice(0, 1);
            else if (match[1] === 'last') values = values.slice(-1);
            else if (match[1].startsWith('eq')) values = [values[n < 0 ? values.length + n : n]].filter(Boolean);
            else if (match[1].startsWith('gt')) values = values.filter((_, i) => i > n);
            else values = values.filter((_, i) => i < n);
            const tail = selector.slice(match.index + match[0].length);
            return tail.trim() ? values.flatMap(node => query(tail.trim(), node)) : values;
        }
        return decode(__gmDom(root ? 'find' : 'select', root ? root.__gm.id : 0, selector)).map(wrap);
    }
    const document = globalThis.document = {
        readyState: 'loading', URL: location.href, baseURI: location.href,
        querySelectorAll: selector => query(selector),
        querySelector: selector => query(selector)[0] || null,
        getElementById: id => query('[id="' + String(id).replace(/"/g, '\\"') + '"]')[0] || null,
        addEventListener(type, fn) { if (type === 'DOMContentLoaded' || type === 'load') ready.push(fn); },
        removeEventListener() {},
        createElement(type) { throw new Error('GM desktop: dynamic ' + type + ' requires a browser'); }
    };
    document.body = wrap(decode(__gmDom('body', 0, '')));
    document.documentElement = query('html')[0];
    document.head = query('head')[0];
    globalThis.addEventListener = document.addEventListener.bind(document);
    globalThis.removeEventListener = () => {};
    globalThis.__gmReady = () => {
        document.readyState = 'complete';
        for (const fn of ready.splice(0)) {
            const result = fn();
            if (result && result.then) result.catch(error => { globalThis.__gmAsyncError = String(error); });
        }
    };
    function collection(values, previous) {
        const c = {length: values.length, __values: values, prevObject: previous};
        values.forEach((node, i) => { c[i] = node; });
        c[Symbol.iterator] = () => values[Symbol.iterator]();
        c.get = index => index === undefined ? values.slice() : values[index < 0 ? values.length + index : index];
        c.toArray = () => values.slice();
        c.each = fn => { for (let i = 0; i < values.length; i++) if (fn.call(values[i], i, values[i]) === false) break; return c; };
        c.map = fn => collection(values.flatMap((node, i) => { const v = fn.call(node, i, node); return v == null ? [] : v; }), c);
        c.eq = i => collection([c.get(Number(i))].filter(Boolean), c);
        c.first = () => c.eq(0);
        c.last = () => c.eq(-1);
        c.slice = (start, end) => collection(values.slice(start, end), c);
        c.find = selector => collection(values.flatMap(node => query(selector, node)), c);
        c.text = () => values.map(node => node.textContent).join('');
        c.html = () => values.length ? values[0].innerHTML : undefined;
        c.attr = name => values.length ? (values[0].getAttribute(name) ?? undefined) : undefined;
        c.data = name => {
            const raw = c.attr('data-' + String(name).replace(/[A-Z]/g, ch => '-' + ch.toLowerCase()));
            if (raw === undefined) return undefined;
            if (raw === 'true') return true;
            if (raw === 'false') return false;
            if (raw === 'null') return null;
            if (String(Number(raw)) === raw) return Number(raw);
            try { if (/^[\[{]/.test(raw)) return JSON.parse(raw); } catch (_) {}
            return raw;
        };
        c.has = selector => collection(values.filter(node => query(selector, node).length), c);
        c.filter = selector => collection(values.filter((node, i) => typeof selector === 'function' ? selector.call(node, i, node) : node.matches(selector)), c);
        c.not = selector => collection(values.filter(node => !node.matches(selector)), c);
        c.children = selector => collection(values.flatMap(node => decode(__gmDom('children', node.__gm.id, selector || '')).map(wrap)), c);
        c.next = selector => collection(values.flatMap(node => decode(__gmDom('next', node.__gm.id, selector || '')).map(wrap)), c);
        c.prev = selector => collection(values.flatMap(node => decode(__gmDom('prev', node.__gm.id, selector || '')).map(wrap)), c);
        c.parent = selector => collection(values.flatMap(node => decode(__gmDom('parent', node.__gm.id, selector || '')).map(wrap)), c);
        c.closest = selector => collection(values.flatMap(node => decode(__gmDom('closest', node.__gm.id, selector)).map(wrap)), c);
        c.parents = selector => { let result = [], current = c.parent(); while (current.length) { result.push(...current.__values); current = current.parent(); } return collection(result, c).filter(selector || '*'); };
        c.remove = () => { values.forEach(node => node.remove()); return c; };
        c.end = () => previous || collection([]);
        c.is = selector => values.some(node => node.matches(selector));
        c.ready = fn => { ready.push(fn); return c; };
        c.click = () => { values.forEach(node => node.click()); return c; };
        c.trigger = c.click;
        return c;
    }
    globalThis.jQuery = globalThis.$ = function (value) {
        if (typeof value === 'function') { ready.push(value); return collection([]); }
        if (value === document) return {ready: fn => ready.push(fn)};
        if (typeof value === 'string') return collection(query(value));
        if (value && value.__values) return value;
        return collection(value && value.__gm ? [value] : []);
    };
    // Static helpers user scripts call on the jQuery function itself.
    jQuery.isNumeric = value => (typeof value === 'number' || typeof value === 'string') && !isNaN(value - parseFloat(value));
    jQuery.trim = value => value == null ? '' : String(value).trim();
    jQuery.isArray = Array.isArray;
    jQuery.each = (items, fn) => {
        if (Array.isArray(items)) { for (let i = 0; i < items.length; i++) if (fn.call(items[i], i, items[i]) === false) break; }
        else for (const key of Object.keys(items || {})) if (fn.call(items[key], key, items[key]) === false) break;
        return items;
    };
    function response(raw) {
        return {
            ok: raw.code >= 200 && raw.code < 300, status: raw.code, url: raw.url,
            headers: {get: name => raw.headers[String(name).toLowerCase()] || null},
            text: () => Promise.resolve(raw.content), json: () => Promise.resolve(JSON.parse(raw.content)),
            clone: () => response(raw),
            blob: () => Promise.reject(new Error('GM desktop: image decoding requires a browser'))
        };
    }
    globalThis.fetch = (url, options = {}) => {
        try { return Promise.resolve(response(decode(__gmFetch(new URL(String(url), location.href).href, JSON.stringify(options))))); }
        catch (error) { return Promise.reject(error); }
    };
    globalThis.GmSpiderInject = {
        GetSpiderArgs: () => __gmArgs,
        SetSpiderResult: value => __gmResult(String(value)),
        ShowWebview() { throw new Error('GM desktop: interactive challenge requires a browser'); },
        HideWebview() {}
    };
})();
