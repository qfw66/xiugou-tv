"""宿主基类：py 源脚本通过 `from base.spider import Spider` 拿到它。

契约来自对 156 个真实脚本的调用统计（`.do-it/verification/pysource-analysis-20261029/REPORT.md`），
按出现文件数排序：fetch 67 / log 59 / getProxyUrl 49 / post 6 /
setCache 4 / getCache 3 / proxyM3u8|proxyMedia|proxyTs 各 3，
以及启动探测用的 getDependence、download。

三个必须由宿主兜住的差异（脚本按 okhttp 行为编写，urllib 不会自动做）：
  1. URL 里的裸中文需要 %XX 编码
  2. 脚本显式带 `Accept-Encoding: gzip`，响应体要自己解压
  3. fetch(verify=False) 要真的跳过证书校验
"""

import gzip
import io
import ipaddress
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import zlib

from .cache import ScriptCache
from .local import RuntimeLocal
from .net import RuntimeNet


def _normalize_url(url):
    """把裸中文等非 ASCII 转成 %XX，且不二次编码已编码的 %XX。

    真实客户端（okhttp）自动做这一步；脚本里直接写 `wd=斗罗` 是常态。
    """
    try:
        url.encode("ascii")
        return url
    except UnicodeEncodeError:
        return urllib.parse.quote(url, safe=":/?#[]@!$&'()*+,;=%~")


def _decompress(raw, encoding):
    """脚本普遍显式带 `Accept-Encoding: gzip`，宿主必须自己解压。"""
    enc = (encoding or "").lower()
    if not raw or not enc or enc == "identity":
        return raw
    try:
        if "gzip" in enc:
            with gzip.GzipFile(fileobj=io.BytesIO(raw)) as f:
                return f.read()
        if "deflate" in enc:
            try:
                return zlib.decompress(raw)
            except zlib.error:
                return zlib.decompress(raw, -zlib.MAX_WBITS)
    except Exception:
        pass
    return raw


class Response(object):
    """最小 requests.Response 兼容层：脚本常用 .ok / .text / .content / .json()。"""

    def __init__(self, url, status, content, headers):
        self.url = url
        self.status_code = status
        self.content = content
        self.headers = headers or {}
        self._text = None

    @property
    def ok(self):
        return 200 <= self.status_code < 400

    @property
    def text(self):
        if self._text is None:
            ctype = ""
            for k, v in self.headers.items():
                if k.lower() == "content-type":
                    ctype = (v or "").lower()
                    break
            enc = "utf-8"
            if "charset=" in ctype:
                enc = ctype.split("charset=")[-1].split(";")[0].strip() or "utf-8"
            try:
                self._text = self.content.decode(enc, "replace")
            except Exception:
                self._text = self.content.decode("utf-8", "replace")
        return self._text

    def json(self):
        return json.loads(self.text)


class _ProxyUrl(str):
    """代理前缀：同时支持当字符串读 `self._proxy_base` 与当方法调 `self._proxy_base()`。

    实测两类脚本都有（属性 2 处 / 方法 7 处），少支持一种就有站点直接崩。
    """

    def __call__(self, local=False):
        return str(self)


class Spider(object):

    def __init__(self):
        self._cache = ScriptCache()
        self._proxy_base = _ProxyUrl(os.environ.get("XIUGOU_PROXY_BASE", ""))

    def init(self, extend=""):
        """脚本常写 `super().init(extend)` 或在自己的 __init__ 里调它，基类必须有。"""
        pass

    # ---------------------------------------------------------------- 日志

    def log(self, msg):
        try:
            sys.stderr.write("[spider] %s\n" % (msg,))
            sys.stderr.flush()
        except Exception:
            pass

    # ---------------------------------------------------------------- 网络

    @property
    def net(self):
        """Each script owns a runtime, including subclasses without super().__init__."""
        if "_net" not in self.__dict__:
            self._net = RuntimeNet()
        return self._net

    @net.setter
    def net(self, value):
        self._net = value

    def _request(self, url, data=None, headers=None, timeout=10, method=None, verify=True):
        url = _normalize_url(url)
        hdrs = dict(headers or {})
        body = None
        if data is not None:
            if isinstance(data, (bytes, bytearray)):
                body = bytes(data)
            elif isinstance(data, dict):
                body = urllib.parse.urlencode(data).encode("utf-8")
                hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
            else:
                body = str(data).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
        ctx = None
        if not verify:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
                raw = _decompress(r.read(), r.headers.get("Content-Encoding"))
                return Response(url, r.status, raw, dict(r.headers))
        except urllib.error.HTTPError as e:
            raw = _decompress(e.read(), (getattr(e, "headers", None) or {}).get("Content-Encoding"))
            return Response(url, e.code, raw or b"", dict(e.headers or {}))
        except Exception as e:
            self.log("fetch failed %s : %s" % (url, e))
            return None

    def fetch(self, url, headers=None, timeout=10, verify=True, **kw):
        return self._request(url, None, headers, timeout, verify=verify)

    def post(self, url, data=None, headers=None, timeout=10, verify=True, **kw):
        return self._request(url, data, headers, timeout, method="POST", verify=verify)

    # ---------------------------------------------------------------- 代理

    def proxyUrl(self, params=None, local=True):
        """Build a script proxy URL using host-owned routing and string parameters."""
        if type(local) is not bool:
            raise TypeError("local must be a bool")
        if not local:
            raise NotImplementedError("LAN script proxy URLs are not supported")
        if params is None:
            params = {}
        if not isinstance(params, dict) or any(
                not isinstance(key, str) or not isinstance(value, str)
                for key, value in params.items()):
            raise TypeError("proxy params must be a dict of strings")
        base = os.environ.get("XIUGOU_SCRIPT_PROXY_BASE", "")
        site_key = os.environ.get("XIUGOU_SCRIPT_SITE_KEY", "")
        if not base or not site_key.strip():
            raise RuntimeError("script proxy is not configured")
        try:
            parsed = urllib.parse.urlsplit(base)
            if (parsed.scheme not in ("http", "https") or not parsed.hostname
                    or parsed.username is not None or parsed.password is not None
                    or parsed.fragment or parsed.port == 0
                    or any(ord(char) < 32 or ord(char) == 127 for char in base)):
                raise ValueError()
            pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True,
                                           encoding="utf-8", errors="strict")
        except ValueError:
            raise RuntimeError("script proxy configuration is invalid") from None
        reserved = {"do", "siteKey", "token"} | {key for key, _ in pairs}
        if reserved.intersection(params):
            raise ValueError("proxy params cannot override host routing")
        pairs = [(key, value) for key, value in pairs if key not in ("do", "siteKey")]
        pairs.extend((("do", "py"), ("siteKey", site_key)))
        pairs.extend(params.items())
        return urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(pairs)))

    def danmakuUrl(self, id):
        """Attach a room id to the host-owned, token-bearing loopback endpoint."""
        if not isinstance(id, str):
            raise TypeError("danmaku id must be a room string")
        if not id.strip() or len(id) > 4096 or any(ord(char) < 32 or ord(char) == 127 for char in id):
            raise ValueError("danmaku id is invalid")
        base = os.environ.get("XIUGOU_SCRIPT_DANMAKU_BASE", "")
        site_key = os.environ.get("XIUGOU_SCRIPT_SITE_KEY", "")
        if not base or not site_key.strip():
            raise RuntimeError("script danmaku is not configured")
        try:
            parsed = urllib.parse.urlsplit(base)
            if (parsed.scheme not in ("http", "https") or not parsed.hostname
                    or parsed.username is not None or parsed.password is not None
                    or parsed.fragment or parsed.port == 0 or "\\" in base
                    or any(ord(char) < 32 or ord(char) == 127 for char in base)):
                raise ValueError()
            if parsed.hostname != "localhost" and not ipaddress.ip_address(parsed.hostname).is_loopback:
                raise ValueError()
            pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True,
                                           encoding="utf-8", errors="strict")
            tokens = [value for key, value in pairs if key == "token"]
            if len(tokens) != 1 or not tokens[0].strip():
                raise ValueError()
        except ValueError:
            raise RuntimeError("script danmaku configuration is invalid") from None
        pairs = [(key, value) for key, value in pairs if key not in ("do", "siteKey", "id")]
        pairs.extend((("do", "py"), ("siteKey", site_key), ("id", id)))
        return urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(pairs)))

    def getProxyUrl(self, local=False):
        """宿主把本地代理前缀注入环境变量；脚本据此拼接播放地址。"""
        return self._proxy_base

    def proxyM3u8(self, *a, **kw):
        return self._proxy_base

    def proxyMedia(self, *a, **kw):
        return self._proxy_base

    def proxyTs(self, *a, **kw):
        return self._proxy_base

    # ---------------------------------------------------------------- 缓存

    @property
    def local(self):
        """Site settings are available even without super().__init__."""
        if "_local" not in self.__dict__:
            self._local = RuntimeLocal()
        return self._local

    @local.setter
    def local(self, value):
        self._local = value

    def _host_cache(self):
        if not hasattr(self, "_cache"):
            self._cache = ScriptCache()
        return self._cache

    def getCache(self, key):
        return self._host_cache().get(key)

    def setCache(self, key, value):
        self._host_cache()[key] = value

    @property
    def js(self):
        """Create the optional JS runtime only when the source uses it."""
        if "_js" not in self.__dict__:
            from .js import RuntimeJS
            self._js = RuntimeJS()
        return self._js

    @js.setter
    def js(self, value):
        self._js = value

    def loadModule(self, name):
        """Load only helpers declared by this source, relative to its original entry."""
        if "_modules" not in self.__dict__:
            from .modules import RuntimeModules
            self._modules = RuntimeModules()
        return self._modules.load(name, self.getDependence)

    def page(self, items, current, limit, total=None):
        """Slice a complete list, or preserve an upstream page with an explicit total."""
        if not isinstance(items, (list, tuple)):
            raise TypeError("page items must be a list or tuple")
        if type(current) is not int or current < 1 or type(limit) is not int or limit < 1:
            raise ValueError("page and limit must be positive integers")
        if total is None:
            total = len(items)
            items = items[(current - 1) * limit:current * limit]
        elif type(total) is not int or total < 0:
            raise ValueError("total must be a nonnegative integer")
        return {"list": list(items), "page": current, "pagecount": max(1, (total + limit - 1) // limit),
                "limit": limit, "total": total}

    # ---------------------------------------------------------------- 生命周期

    def getDependence(self):
        """壳启动时探测依赖清单；脚本常覆盖它。缺失会 AttributeError → 首页空白。"""
        return []

    def download(self, *a, **kw):
        return None

    def getName(self):
        return ""

    def destroy(self):
        pass


class TokenExpired(Exception):
    pass
