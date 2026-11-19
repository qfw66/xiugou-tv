// XPTV / NowShowTime 脚本的宿主环境（companion 桌面端实现）。
// 只能用 IIFE 往 globalThis 上挂：站点脚本会在同一全局作用域里声明自己的
// const jsonify / argsify / cheerio…，这里若用顶层 let/const 会与之冲突。
(function (g) {
  'use strict';
  var H = g.__xptv;

  g.jsonify = function (value) { return JSON.stringify(value); };
  g.argsify = function (value) {
    if (value == null) return {};
    if (typeof value === 'string') {
      if (!value.trim()) return {};
      try { return JSON.parse(value); } catch (e) { return value; }
    }
    return value;
  };
  var describe = function (value) {
    if (typeof value === 'string') return value;
    if (value instanceof Error) return String(value.stack || value.message || value);
    try { return JSON.stringify(value); } catch (e) { return String(value); }
  };
  g.$print = function () { H.log(Array.prototype.map.call(arguments, describe).join(' ')); };
  g.console = {
    log: g.$print, info: g.$print, debug: g.$print, warn: g.$print, error: g.$print,
  };
  if (typeof g.$config_str === 'undefined') g.$config_str = '{}';
  g.$utils = {
    toastInfo: function (msg) { H.log('[toast] ' + msg); },
    toastError: function (msg) { H.log('[toast] ' + msg); },
    openSafari: function (url) { H.log('[openSafari] ' + url); },
  };

  // ---- 定时器：桌面端无事件循环，回调排进微任务队列（忽略延时）----
  var timerSeq = 0;
  var cancelled = {};
  g.setTimeout = function (fn) {
    var id = ++timerSeq;
    var args = Array.prototype.slice.call(arguments, 2);
    Promise.resolve().then(function () { if (!cancelled[id] && typeof fn === 'function') fn.apply(null, args); });
    return id;
  };
  g.clearTimeout = function (id) { cancelled[id] = true; };
  g.setInterval = function () { return ++timerSeq; };
  g.clearInterval = function () {};

  // ---- 存储 ----
  var cache = {};
  g.$cache = {
    get: function (k) { return Object.prototype.hasOwnProperty.call(cache, k) ? cache[k] : undefined; },
    set: function (k, v) { cache[k] = v; },
    remove: function (k) { delete cache[k]; },
    delete: function (k) { delete cache[k]; },
  };
  g.localStorage = {
    getItem: function (k) { return Object.prototype.hasOwnProperty.call(cache, k) ? String(cache[k]) : null; },
    setItem: function (k, v) { cache[k] = String(v); },
    removeItem: function (k) { delete cache[k]; },
  };

  // ---- Base64 ----
  g.btoa = function (s) { return String(H.btoa(String(s))); };
  g.atob = function (s) { return String(H.atob(String(s))); };

  // ---- URL / URLSearchParams（够用的子集）----
  function URLSearchParams(init) {
    this._p = [];
    if (init == null) return;
    if (typeof init === 'string') {
      var text = init.charAt(0) === '?' ? init.slice(1) : init;
      var self = this;
      text.split('&').forEach(function (part) {
        if (!part) return;
        var i = part.indexOf('=');
        var k = i < 0 ? part : part.slice(0, i);
        var v = i < 0 ? '' : part.slice(i + 1);
        self._p.push([decode(k), decode(v)]);
      });
    } else if (typeof init === 'object') {
      for (var key in init) if (Object.prototype.hasOwnProperty.call(init, key)) this._p.push([key, String(init[key])]);
    }
  }
  function decode(s) { try { return decodeURIComponent(s.replace(/\+/g, ' ')); } catch (e) { return s; } }
  URLSearchParams.prototype = {
    get: function (k) { for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === k) return this._p[i][1]; return null; },
    getAll: function (k) { return this._p.filter(function (p) { return p[0] === k; }).map(function (p) { return p[1]; }); },
    has: function (k) { return this.get(k) !== null; },
    set: function (k, v) { this.delete(k); this._p.push([k, String(v)]); },
    append: function (k, v) { this._p.push([k, String(v)]); },
    delete: function (k) { this._p = this._p.filter(function (p) { return p[0] !== k; }); },
    forEach: function (fn) { var self = this; this._p.forEach(function (p) { fn(p[1], p[0], self); }); },
    toString: function () {
      return this._p.map(function (p) { return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]); }).join('&');
    },
  };
  g.URLSearchParams = URLSearchParams;
  function URL(input, base) {
    var parts = JSON.parse(H.parseUrl(String(input), base == null ? null : String(base)));
    if (parts.error) throw new TypeError('Invalid URL: ' + input);
    this.protocol = parts.protocol;
    this.username = parts.username;
    this.password = parts.password;
    this.hostname = parts.hostname;
    this.port = parts.port;
    this.host = parts.port ? parts.hostname + ':' + parts.port : parts.hostname;
    this.origin = parts.protocol + '//' + this.host;
    this.pathname = parts.pathname || '/';
    this.search = parts.search ? '?' + parts.search : '';
    this.hash = parts.hash ? '#' + parts.hash : '';
    this.searchParams = new URLSearchParams(this.search);
  }
  URL.prototype.toString = function () { return this.origin + this.pathname + this.search + this.hash; };
  Object.defineProperty(URL.prototype, 'href', { get: function () { return this.toString(); } });
  URL.prototype.toJSON = URL.prototype.toString;
  g.URL = URL;

  // ---- $fetch ----
  var headerBag = function (raw) {
    var out = {};
    for (var name in raw) {
      if (!Object.prototype.hasOwnProperty.call(raw, name)) continue;
      var values = raw[name];
      var lower = name.toLowerCase();
      // 小写键与 Node 一致（多值保留数组），首字母大写键与 iOS 一致（多值逗号拼接）
      out[lower] = values.length === 1 ? values[0] : values;
      var canonical = lower.replace(/(^|-)([a-z])/g, function (m, d, c) { return d + c.toUpperCase(); });
      if (canonical !== lower) out[canonical] = values.join(', ');
    }
    return out;
  };
  var request = function (method, url, body, options) {
    var opts = options || {};
    var headers = {};
    var src = opts.headers || {};
    for (var k in src) if (Object.prototype.hasOwnProperty.call(src, k) && src[k] != null) headers[k] = String(src[k]);
    var payload = body;
    if (payload != null && typeof payload === 'object') {
      var typeKey = Object.keys(headers).filter(function (h) { return h.toLowerCase() === 'content-type'; })[0];
      if (typeKey && /x-www-form-urlencoded/i.test(headers[typeKey])) {
        // 与 axios 一致：声明了表单类型的对象 body 按表单编码
        payload = Object.keys(payload).filter(function (k) { return payload[k] != null; }).map(function (k) {
          var v = payload[k];
          return encodeURIComponent(k) + '=' + encodeURIComponent(typeof v === 'object' ? JSON.stringify(v) : String(v));
        }).join('&');
      } else {
        payload = JSON.stringify(payload);
        if (!typeKey) headers['Content-Type'] = 'application/json';
      }
    }
    var raw = H.fetch(method, String(url), payload == null ? null : String(payload), JSON.stringify({
      headers: headers, timeout: opts.timeout, redirect: opts.redirect,
    }));
    var res = JSON.parse(raw);
    var bag = headerBag(res.headers || {});
    return Promise.resolve({ data: res.data, status: res.status, headers: bag, respHeaders: bag, url: res.url, error: res.error });
  };
  g.$fetch = {
    get: function (url, opts) { return request('GET', url, null, opts); },
    post: function (url, body, opts) { return request('POST', url, body, opts); },
    put: function (url, body, opts) { return request('PUT', url, body, opts); },
    patch: function (url, body, opts) { return request('PATCH', url, body, opts); },
    delete: function (url, opts) { return request('DELETE', url, null, opts); },
    head: function (url, opts) { return request('HEAD', url, null, opts); },
  };

  // ---- CryptoJS（crypto-js 4.2.0 已在本文件之前加载）----
  g.crypto = g.crypto || {
    getRandomValues: function (arr) { for (var i = 0; i < arr.length; i++) arr[i] = H.randomInt() >>> 0; return arr; },
  };
  g.createCryptoJS = function () { return g.CryptoJS; };
  // NowShowTime v1/7sefun.js 直接调用全局 _aesDecryptCBC 却未自行定义；语义取自同站 XPTV 版
  // 的 decrypt()：Base64 密文、UTF-8 key/iv、AES-CBC + PKCS7，返回 UTF-8 明文。脚本自带同名函数时不覆盖。
  if (typeof g._aesDecryptCBC !== 'function') {
    g._aesDecryptCBC = function (data, key, iv) {
      var C = g.CryptoJS;
      return C.AES.decrypt(String(data), C.enc.Utf8.parse(String(key)), {
        iv: C.enc.Utf8.parse(String(iv)), mode: C.mode.CBC, padding: C.pad.Pkcs7,
      }).toString(C.enc.Utf8);
    };
  }

  // ---- JSEncrypt（RSA PKCS#1 v1.5，Java 实现）----
  g.loadJSEncrypt = function () {
    function JSEncrypt() { this._pub = null; this._pri = null; }
    JSEncrypt.prototype.setPublicKey = function (pem) { this._pub = String(pem); };
    JSEncrypt.prototype.setPrivateKey = function (pem) { this._pri = String(pem); };
    JSEncrypt.prototype.setKey = function (pem) {
      if (String(pem).indexOf('PRIVATE') >= 0) this._pri = String(pem); else this._pub = String(pem);
    };
    JSEncrypt.prototype.encrypt = function (text) {
      var r = H.rsaEncrypt(this._pub || this._pri || '', String(text));
      return r == null ? false : String(r);
    };
    JSEncrypt.prototype.decrypt = function (text) {
      var r = H.rsaDecrypt(this._pri || '', String(text));
      return r == null ? false : String(r);
    };
    return JSEncrypt;
  };

  // ---- cheerio 子集（jsoup 节点）----
  var toArray = function (list) {
    var out = [];
    if (list == null) return out;
    var n = list.size();
    for (var i = 0; i < n; i++) out.push(list.get(i));
    return out;
  };
  var isNode = function (x) { return x != null && typeof x === 'object' && !(x instanceof Q) && H.isNode(x); };
  var unique = function (nodes) {
    var out = [];
    nodes.forEach(function (n) { if (out.indexOf(n) < 0) out.push(n); });
    return out;
  };
  function Q(nodes, prev, root) {
    this._n = nodes;
    this._prev = prev || null;
    this._root = root;
    this.length = nodes.length;
    for (var i = 0; i < nodes.length; i++) this[i] = nodes[i];
  }
  var wrap = function (nodes, prev, root) { return new Q(nodes, prev, root); };
  var elementsOf = function (q) { return q._n.filter(function (n) { return isNode(n) && H.isElement(n); }); };
  var matches = function (node, sel) {
    if (sel == null) return true;
    if (typeof sel === 'function') return false;
    return H.isElement(node) && H.is(node, String(sel));
  };
  Q.prototype = {
    constructor: Q,
    find: function (sel) {
      var out = [];
      if (sel instanceof Q) sel = null;
      if (sel != null) elementsOf(this).forEach(function (n) { out = out.concat(toArray(H.find(n, String(sel)))); });
      return wrap(unique(out), this, this._root);
    },
    each: function (fn) {
      for (var i = 0; i < this._n.length; i++) if (fn.call(this._n[i], i, this._n[i]) === false) break;
      return this;
    },
    map: function (fn) {
      var out = [];
      for (var i = 0; i < this._n.length; i++) {
        var r = fn.call(this._n[i], i, this._n[i]);
        if (r == null) continue;
        if (Array.isArray(r)) out = out.concat(r); else out.push(r);
      }
      return wrap(out, this, this._root);
    },
    filter: function (sel) {
      var out = [];
      for (var i = 0; i < this._n.length; i++) {
        var n = this._n[i];
        var keep = typeof sel === 'function' ? sel.call(n, i, n) : matches(n, sel);
        if (keep) out.push(n);
      }
      return wrap(out, this, this._root);
    },
    not: function (sel) {
      var out = [];
      for (var i = 0; i < this._n.length; i++) {
        var n = this._n[i];
        var hit = typeof sel === 'function' ? sel.call(n, i, n) : matches(n, sel);
        if (!hit) out.push(n);
      }
      return wrap(out, this, this._root);
    },
    is: function (sel) { var self = this; return this._n.some(function (n, i) { return typeof sel === 'function' ? sel.call(n, i, n) : matches(n, sel); }); },
    has: function (sel) { return this.filter(function () { return toArray(H.find(this, String(sel))).length > 0; }); },
    get: function (i) {
      if (i == null) return this._n.slice();
      return this._n[i < 0 ? this._n.length + i : i];
    },
    toArray: function () { return this._n.slice(); },
    eq: function (i) { var n = this.get(i); return wrap(n == null ? [] : [n], this, this._root); },
    first: function () { return this.eq(0); },
    last: function () { return this.eq(-1); },
    slice: function (a, b) { return wrap(this._n.slice(a, b), this, this._root); },
    end: function () { return this._prev || wrap([], null, this._root); },
    index: function () { var n = elementsOf(this)[0]; return n ? H.elementIndex(n) : -1; },
    attr: function (name, value) {
      if (typeof name === 'object' && name !== null) {
        for (var k in name) if (Object.prototype.hasOwnProperty.call(name, k)) this.attr(k, name[k]);
        return this;
      }
      if (value === undefined) {
        var n = elementsOf(this)[0];
        if (n == null || !H.hasAttr(n, String(name))) return undefined;
        return String(H.attr(n, String(name)));
      }
      elementsOf(this).forEach(function (el) { H.setAttr(el, String(name), String(value)); });
      return this;
    },
    removeAttr: function (name) { elementsOf(this).forEach(function (el) { H.removeAttr(el, String(name)); }); return this; },
    prop: function (name) { return this.attr(name); },
    data: function (name) {
      if (name == null) return {};
      return this.attr('data-' + String(name).replace(/[A-Z]/g, function (c) { return '-' + c.toLowerCase(); }));
    },
    val: function (value) { return value === undefined ? this.attr('value') : this.attr('value', value); },
    hasClass: function (c) { return elementsOf(this).some(function (el) { return H.hasClass(el, String(c)); }); },
    addClass: function (c) { elementsOf(this).forEach(function (el) { H.addClass(el, String(c)); }); return this; },
    removeClass: function (c) { elementsOf(this).forEach(function (el) { H.removeClass(el, String(c)); }); return this; },
    text: function (value) {
      if (value !== undefined) { elementsOf(this).forEach(function (el) { H.setText(el, String(value)); }); return this; }
      return this._n.map(function (n) { return isNode(n) ? String(H.text(n)) : ''; }).join('');
    },
    html: function (value) {
      if (value !== undefined) { elementsOf(this).forEach(function (el) { H.setHtml(el, String(value)); }); return this; }
      var n = this._n.filter(isNode)[0];
      return n == null ? null : String(H.html(n));
    },
    toString: function () { return this._n.filter(isNode).map(function (n) { return String(H.outerHtml(n)); }).join(''); },
    children: function (sel) { return this._rel(function (el) { return toArray(H.children(el)); }, sel); },
    contents: function () { return this._rel(function (el) { return toArray(H.childNodes(el)); }, null); },
    parent: function (sel) { return this._rel(function (el) { var p = H.parent(el); return p ? [p] : []; }, sel); },
    parents: function (sel) { return this._rel(function (el) { return toArray(H.parents(el)); }, sel); },
    closest: function (sel) {
      return this._rel(function (el) {
        var cur = el;
        while (cur != null) { if (H.isElement(cur) && H.is(cur, String(sel))) return [cur]; cur = H.parent(cur); }
        return [];
      }, null);
    },
    next: function (sel) { return this._rel(function (el) { var s = H.next(el); return s ? [s] : []; }, sel); },
    prev: function (sel) { return this._rel(function (el) { var s = H.prev(el); return s ? [s] : []; }, sel); },
    nextAll: function (sel) { return this._rel(function (el) { return toArray(H.nextAll(el)); }, sel); },
    prevAll: function (sel) { return this._rel(function (el) { return toArray(H.prevAll(el)); }, sel); },
    siblings: function (sel) { return this._rel(function (el) { return toArray(H.siblings(el)); }, sel); },
    _rel: function (fn, sel) {
      var out = [];
      elementsOf(this).forEach(function (el) { out = out.concat(fn(el)); });
      out = unique(out);
      if (sel != null) out = out.filter(function (n) { return matches(n, sel); });
      return wrap(out, this, this._root);
    },
    clone: function () { return wrap(this._n.map(function (n) { return isNode(n) ? H.clone(n) : n; }), this, this._root); },
    remove: function (sel) {
      this._n.forEach(function (n) { if (isNode(n) && matches(n, sel == null ? null : sel)) H.remove(n); });
      return this;
    },
    empty: function () { elementsOf(this).forEach(function (el) { H.empty(el); }); return this; },
    append: function (html) { elementsOf(this).forEach(function (el) { H.append(el, String(html)); }); return this; },
    add: function (other) { return wrap(unique(this._n.concat(other instanceof Q ? other._n : [])), this, this._root); },
  };
  if (typeof Symbol === 'function' && Symbol.iterator) {
    Q.prototype[Symbol.iterator] = function () { return this._n[Symbol.iterator](); };
  }

  var load = function (html) {
    var doc = H.parseHtml(html == null ? '' : String(html));
    var $ = function (sel, context) {
      if (sel == null) return wrap([], null, doc);
      if (sel instanceof Q) return sel;
      if (typeof sel === 'string') {
        var s = sel.trim();
        if (s.charAt(0) === '<') return wrap(toArray(H.parseFragment(s)), null, doc);
        var roots = context == null ? [doc] : $(context)._n.filter(isNode);
        var out = [];
        roots.forEach(function (root) { out = out.concat(toArray(H.find(root, s))); });
        return wrap(unique(out), null, doc);
      }
      if (Array.isArray(sel)) return wrap(sel.filter(isNode), null, doc);
      if (isNode(sel)) return wrap([sel], null, doc);
      return wrap([], null, doc);
    };
    $.root = function () { return wrap([doc], null, doc); };
    $.html = function (sel) { return sel == null ? String(H.outerHtml(doc)) : $(sel).toString(); };
    $.text = function (sel) { return sel == null ? String(H.text(doc)) : $(sel).text(); };
    $.load = load;
    $.fn = Q.prototype;
    return $;
  };
  g.createCheerio = function () { return { load: load, html: function (x) { return x instanceof Q ? x.toString() : ''; } }; };

  // XPTV 内置的 $html：以 HTML 字符串为单位的选择器助手（4kav / hjkk 等脚本使用）
  var pick = function (html, sel) {
    var $ = load(html);
    return sel == null || sel === '' ? $.root().children() : $(String(sel));
  };
  g.$html = {
    elements: function (html, sel) { return pick(html, sel).get().filter(isNode).map(function (n) { return String(H.outerHtml(n)); }); },
    text: function (html, sel) { return pick(html, sel).first().text().trim(); },
    attr: function (html, sel, name) { var v = pick(html, sel).first().attr(String(name)); return v == null ? '' : v; },
    html: function (html, sel) { var v = pick(html, sel).first().html(); return v == null ? '' : v; },
  };

  // NowShowTime 脚本以 CommonJS 导出
  if (typeof g.module === 'undefined') { g.module = { exports: {} }; g.exports = g.module.exports; }
})(globalThis);
