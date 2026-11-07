"""Bounded, synchronous network access owned by one script instance."""

import base64
from email.message import Message
import gzip
import http.client
import io
import json
import math
import re
import threading
import time
import urllib.parse
import zlib

from .cancel_scope import CancelScope, bind, close_all, current_scope
from .generator_stream import GeneratorExchange
from .http_transport import HttpExchange, RuntimeReader, SessionCookies
from .ttl_cache import TtlCache
from .ws import WebSocketExchange
from .ws_connection import WebSocketConnection


MAX_RESPONSE_BYTES = 8 * 1024 * 1024
DEFAULT_TIMEOUT_MS = 10000


def _options(value):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise TypeError("options must be a dict or None")
    return dict(value)


def _milliseconds(value, name, allow_zero=False):
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or value < 0 or (value == 0 and not allow_zero)):
        raise ValueError(name + " must be a finite positive millisecond value")
    return value / 1000.0


def _request_url(url, params):
    if not isinstance(url, str) or any(ord(char) < 32 or ord(char) == 127 for char in url):
        raise ValueError("url must be an HTTP(S) URL without control characters")
    try:
        parsed = urllib.parse.urlsplit(url)
        valid = (parsed.scheme in ("http", "https") and parsed.hostname
                 and parsed.username is None and parsed.password is None
                 and parsed.port != 0)
    except ValueError:
        valid = False
    if not valid:
        raise ValueError("url must be an HTTP(S) URL")
    if params is not None:
        if not isinstance(params, dict):
            raise TypeError("params must be a dict or None")
        pairs = []
        for key, values in params.items():
            if not isinstance(key, str):
                raise TypeError("params keys must be strings")
            for value in values if isinstance(values, (list, tuple)) else (values,):
                if value is not None:
                    pairs.append((key, value))
        query = urllib.parse.urlencode(pairs)
        url = urllib.parse.urlunsplit(parsed._replace(
            query=parsed.query + ("&" if parsed.query and query else "") + query))
    return urllib.parse.quote(url, safe=":/?#[]@!$&'()*+,;=%~")


def _content(raw, buffer, charset="utf-8"):
    if buffer == 3:
        return raw
    if buffer == 2:
        return base64.b64encode(raw).decode("ascii")
    if buffer == 1:
        return [byte if byte < 128 else byte - 256 for byte in raw]
    try:
        return raw.decode(charset or "utf-8", "replace")
    except LookupError:
        return raw.decode("utf-8", "replace")


class _ResponseLimit(ValueError):
    pass


def _bounded(raw):
    if len(raw) > MAX_RESPONSE_BYTES:
        raise _ResponseLimit("response exceeds 8 MiB limit")
    return raw


def _decode_response(raw, encoding):
    encoding = (encoding or "identity").strip().lower()
    if not raw or encoding == "identity":
        return raw
    if encoding in ("gzip", "x-gzip"):
        with gzip.GzipFile(fileobj=io.BytesIO(raw)) as stream:
            return _bounded(stream.read(MAX_RESPONSE_BYTES + 1))
    if encoding == "deflate":
        try:
            inflater = zlib.decompressobj()
            result = inflater.decompress(raw, MAX_RESPONSE_BYTES + 1)
        except zlib.error:
            inflater = zlib.decompressobj(-zlib.MAX_WBITS)
            result = inflater.decompress(raw, MAX_RESPONSE_BYTES + 1)
        _bounded(result)
        if not inflater.eof:
            raise ValueError("invalid deflate response")
        return result
    raise ValueError("unsupported response encoding")


def _headers(value):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise TypeError("headers must be a dict or None")
    result = {}
    for key, item in value.items():
        if not isinstance(key, str) or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", key):
            raise ValueError("invalid header name")
        if not isinstance(item, str) or any(ord(c) < 32 or ord(c) == 127 for c in item):
            raise ValueError("header values must be strings without control characters")
        item.encode("latin-1")
        result[key] = item
    return result


def _request_body(options, headers):
    has_data, has_body = "data" in options, "body" in options
    if has_data and has_body:
        raise ValueError("data and body are mutually exclusive")
    method = options.get("method", "POST" if has_data or has_body else "GET")
    if not isinstance(method, str) or not re.fullmatch(r"[A-Za-z]+", method):
        raise ValueError("invalid HTTP method")
    method = method.upper()
    if method in ("GET", "HEAD") and (has_data or has_body):
        raise ValueError("GET and HEAD do not accept a body")
    body, content_type = None, None
    if has_body:
        value = options["body"]
        if isinstance(value, str):
            body = value.encode("utf-8")
        elif isinstance(value, (bytes, bytearray)):
            body = bytes(value)
        elif isinstance(value, list) and all(type(v) is int and 0 <= v <= 255 for v in value):
            body = bytes(value)
        else:
            raise ValueError("body must be text, bytes, or a list of unsigned bytes")
    elif has_data:
        value = options["data"]
        post_type = options.get("postType", "json")
        if post_type == "json":
            body = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
            content_type = "application/json; charset=utf-8"
        elif post_type == "form":
            if not isinstance(value, dict):
                raise TypeError("form data must be a dict")
            body = urllib.parse.urlencode({str(k).strip(): str(v).strip()
                                           for k, v in value.items()}).encode("utf-8")
            content_type = "application/x-www-form-urlencoded"
        else:
            raise NotImplementedError("only json and form postType are supported")
    if body is not None and len(body) > MAX_RESPONSE_BYTES:
        raise ValueError("request body exceeds 8 MiB limit")
    if content_type and not any(k.lower() == "content-type" for k in headers):
        headers["Content-Type"] = content_type
    return method, body


def _reject_json_constant(value):
    raise ValueError("non-finite JSON number")


class _HttpClient:
    def __init__(self, cookies=None):
        self._closed = False
        self._cookies = cookies
        self._http_lock = threading.Lock()
        self._active_http = set()
        self._scope = CancelScope()

    def _release_http(self, connection):
        with self._http_lock:
            self._active_http.discard(connection)

    def _prepare_http(self, url, options):
        if self._closed:
            raise RuntimeError("network runtime is closed")
        options = _options(options)
        supported = {"params", "headers", "timeout", "buffer", "method", "data",
                     "body", "postType", "redirect", "callTimeout", "cookie"}
        if options.keys() - supported:
            raise NotImplementedError("unsupported network option")
        if options.get("cookie", False) is not False:
            raise NotImplementedError("shared WebView cookies are not available")
        redirect = options.get("redirect", True)
        if type(redirect) not in (bool, int) or redirect not in (False, True):
            raise ValueError("redirect must be a bool or integer 0 or 1")
        timeout = _milliseconds(options.get("timeout", DEFAULT_TIMEOUT_MS), "timeout")
        call_timeout = _milliseconds(options.get("callTimeout", 0), "callTimeout", allow_zero=True)
        url = _request_url(url, options.get("params"))
        headers = _headers(options.get("headers"))
        method, body = _request_body(options, headers)
        return url, method, body, headers, bool(redirect), timeout, call_timeout

    def _open_http(self, url, method, body, headers, redirect, timeout, call_timeout):
        scope = current_scope()

        def release(connection):
            self._release_http(connection)
            if scope is not None:
                scope.discard(connection)

        connection = HttpExchange(timeout, call_timeout, release, self._cookies)
        try:
            if scope is not None:
                scope.add(connection)
            with self._http_lock:
                if self._closed:
                    raise RuntimeError("network runtime is closed")
                self._active_http.add(connection)
            if scope is not None:
                scope.check()
            return connection.open(url, method, body, headers, redirect)
        except BaseException:
            connection.close()
            raise

    def openStream(self, url, options=None):
        """Open one owned HTTP response without buffering its body."""
        return self._open_http(*self._prepare_http(url, options))

    def stream(self, url, options=None):
        """Transfer an HTTP or byte-iterator reader to the caller without prefetching."""
        if self._closed:
            raise RuntimeError("network runtime is closed")
        if isinstance(url, str):
            reader = self.openStream(url, options)
        else:
            if options is not None:
                raise ValueError("generator streams do not accept HTTP options")
            reader = GeneratorExchange(url, self._scope).reader()
        return {"code": reader.code, "headers": reader.headers,
                "contentType": reader.contentType, "stream": reader}

    def req(self, url, options=None):
        """Buffer a bounded response; transport failures have code 0 and error."""
        options = _options(options)
        buffer = options.get("buffer", 0)
        if type(buffer) is not int or buffer not in (0, 1, 2, 3):
            raise ValueError("buffer must be an integer from 0 to 3")
        prepared = self._prepare_http(url, options)
        try:
            with self._open_http(*prepared) as reader:
                raw = bytearray()
                while True:
                    chunk = reader.read(min(65536, MAX_RESPONSE_BYTES + 1 - len(raw)))
                    if chunk is None:
                        break
                    raw.extend(chunk)
                    _bounded(raw)
                headers = {name.lower(): value for name, value in reader.headers.items()}
                encoding = headers.get("content-encoding")
                if isinstance(encoding, list):
                    encoding = encoding[0]
                raw = _decode_response(bytes(raw), encoding)
                message = Message()
                message["Content-Type"] = reader.contentType
                return {"code": reader.code, "headers": reader.headers,
                        "content": _content(raw, buffer, message.get_content_charset())}
        except InterruptedError:
            raise
        except (OSError, ValueError, EOFError, zlib.error, http.client.HTTPException) as error:
            message = ("response exceeds 8 MiB limit" if isinstance(error, _ResponseLimit)
                       else "request timeout" if isinstance(error, TimeoutError)
                       else "request failed (" + type(error).__name__ + ")")
            return {"code": 0, "headers": {}, "content": _content(b"", buffer), "error": message}

    def json(self, url, options=None):
        """Parse text JSON; HTTP, transport and decoding errors remain failures."""
        options = _options(options)
        options["buffer"] = 0
        response = self.req(url, options)
        if response.get("error"):
            raise OSError(response["error"])
        if not 200 <= response["code"] < 300:
            raise ValueError("HTTP " + str(response["code"]))
        try:
            return json.loads(response["content"], parse_constant=_reject_json_constant)
        except (ValueError, RecursionError):
            raise ValueError("response is not valid JSON") from None

    def close(self):
        with self._http_lock:
            self._closed = True
            connections = tuple(self._active_http)
            self._active_http.clear()
        actions = [connection.close for connection in connections]
        if self._cookies is not None:
            actions.append(self._cookies.close)
        actions.append(self._scope.close)
        close_all(actions)


class RuntimeSession(_HttpClient):
    """HTTP client with an isolated cookie jar and parent-owned lifetime."""

    def __init__(self, release):
        super().__init__(SessionCookies())
        self._release = release

    def setCookie(self, url, cookie):
        if self._closed:
            raise RuntimeError("network runtime is closed")
        return self._cookies.set(_request_url(url, None), cookie)

    def close(self):
        try:
            super().close()
        finally:
            self._release(self)

    def __enter__(self):
        if self._closed:
            raise RuntimeError("network runtime is closed")
        return self

    def __exit__(self, *args):
        self.close()


class RuntimeNet(_HttpClient):
    def __init__(self):
        super().__init__()
        self._cache = TtlCache()
        self._ws_lock = threading.Lock()
        self._active_ws = set()
        self._session_lock = threading.Lock()
        self._sessions = set()

    def _release_session(self, session):
        with self._session_lock:
            self._sessions.discard(session)

    def session(self):
        """Create an isolated cookie session that closes with this runtime."""
        with self._session_lock:
            if self._closed:
                raise RuntimeError("network runtime is closed")
            session = RuntimeSession(self._release_session)
            self._sessions.add(session)
            return session

    def map(self, items, mapper, concurrency=4):
        """Run at most concurrency mappers, retaining input order and cancelling siblings on error."""
        if self._closed:
            raise RuntimeError("network runtime is closed")
        if type(concurrency) is not int or not 1 <= concurrency <= 32:
            raise ValueError("concurrency must be an integer from 1 to 32")
        if not callable(mapper):
            raise TypeError("mapper must be callable")
        if isinstance(items, (str, bytes, bytearray, dict)):
            raise TypeError("items must be an iterable of values")
        values = []
        for value in items:
            if len(values) == 10000:
                raise ValueError("map input exceeds 10000 items")
            values.append(value)
        scope = CancelScope()
        release = bind(scope, self._scope)
        condition = threading.Condition()
        results = [None] * len(values)
        errors = []
        next_index = completed = 0

        def work():
            nonlocal next_index, completed
            with scope.activate():
                while True:
                    with condition:
                        if scope.event.is_set() or errors or next_index == len(values):
                            return
                        index = next_index
                        next_index += 1
                    try:
                        scope.check()
                        result = mapper(values[index], index)
                        scope.check()
                    except BaseException as error:
                        with condition:
                            if not errors:
                                errors.append(error)
                            condition.notify_all()
                        scope.close()
                        return
                    with condition:
                        results[index] = result
                        completed += 1
                        condition.notify_all()

        try:
            for _ in range(min(concurrency, len(values))):
                threading.Thread(target=work, name="runtime-map", daemon=True).start()
            with condition:
                while completed != len(values):
                    if errors:
                        raise errors[0]
                    scope.check()
                    condition.wait(0.02)
                scope.check()
            return results
        finally:
            try:
                scope.close()
            finally:
                release()

    def sleep(self, milliseconds):
        """Wait cooperatively; closing this runtime or the current stream interrupts it."""
        if self._closed:
            raise RuntimeError("network runtime is closed")
        seconds = _milliseconds(milliseconds, "sleep", allow_zero=True)
        scope = CancelScope()
        release = bind(scope, self._scope)
        try:
            scope.event.wait(seconds)
            scope.check()
        finally:
            release()

    def connect(self, url, options, callback):
        """Start a parent-owned WebSocket; callbacks receive (connection, event)."""
        if self._closed:
            raise RuntimeError("network runtime is closed")
        scope = current_scope()

        def release(connection):
            with self._ws_lock:
                self._active_ws.discard(connection)
            if scope is not None:
                scope.discard(connection)

        connection = WebSocketConnection(url, options, callback, release)
        try:
            with self._ws_lock:
                if self._closed:
                    raise RuntimeError("network runtime is closed")
                self._active_ws.add(connection)
                if scope is not None:
                    scope.add(connection)
            return connection.start()
        except BaseException:
            connection.cancel()
            raise

    def ws(self, url, options=None):
        """Send optional JSON data and return the first complete WebSocket message."""
        if self._closed:
            raise RuntimeError("network runtime is closed")
        options = _options(options)
        if options.keys() - {"headers", "data", "timeout"}:
            raise NotImplementedError("unsupported WebSocket option")
        headers = _headers(options.get("headers"))
        timeout = _milliseconds(options.get("timeout", DEFAULT_TIMEOUT_MS), "timeout")
        payload = None
        if "data" in options:
            if not isinstance(options["data"], dict):
                raise TypeError("WebSocket data must be a JSON object")
            payload = json.dumps(options["data"], ensure_ascii=False, allow_nan=False).encode("utf-8")
            if len(payload) > MAX_RESPONSE_BYTES:
                raise ValueError("WebSocket data exceeds 8 MiB limit")
        connection = WebSocketExchange(url, headers, payload, timeout, MAX_RESPONSE_BYTES)
        with self._ws_lock:
            if self._closed:
                raise RuntimeError("network runtime is closed")
            self._active_ws.add(connection)
        try:
            return connection.exchange()
        finally:
            with self._ws_lock:
                self._active_ws.discard(connection)

    def cached(self, key, options, loader):
        """Return a JSON snapshot, synchronously refreshing after its millisecond TTL."""
        if self._closed:
            raise RuntimeError("network runtime is closed")
        if not isinstance(key, str) or not key.strip():
            raise ValueError("cache key must be a non-empty string")
        options = _options(options)
        if options.keys() - {"ttl", "stale", "persist"}:
            raise NotImplementedError("unsupported cache option")
        if "ttl" not in options:
            raise ValueError("ttl is required")
        ttl = _milliseconds(options["ttl"], "ttl", allow_zero=True)
        for name in ("stale", "persist"):
            value = options.get(name, False)
            if type(value) is not bool:
                raise ValueError(name + " must be a bool")
            if name == "stale" and value:
                raise NotImplementedError(name + " cache mode is not supported")
        if not callable(loader):
            raise TypeError("loader must be callable")
        scope = current_scope()

        def check():
            if scope is not None:
                scope.check()
            if self._closed:
                raise RuntimeError("network runtime is closed")

        persist = options.get("persist", False)
        check()
        if ttl > 0:
            encoded = self._cache.lookup(key, persist, check)
            if encoded is not None:
                check()
                return json.loads(encoded)
        else:
            self._cache.clear(key, check, disk=persist)
        value = loader()
        check()
        try:
            encoded = json.dumps(value, ensure_ascii=False, allow_nan=False)
        except (TypeError, ValueError, RecursionError):
            raise ValueError("cached loader must return a JSON value") from None
        if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
            raise ValueError("cached value exceeds 8 MiB limit")
        if ttl > 0:
            self._cache.put(key, ttl, persist, encoded, check)
        return json.loads(encoded)

    def clearCache(self, key=None):
        """Drop one cached JSON value, or all values owned by this runtime."""
        if self._closed:
            raise RuntimeError("network runtime is closed")
        if key is not None and (not isinstance(key, str) or not key.strip()):
            raise ValueError("cache key must be a non-empty string")
        self._cache.clear(key, self._scope.check)

    def close(self):
        """Cancel owned HTTP, WebSockets and sessions; safe to repeat."""
        with self._ws_lock:
            self._closed = True
            connections = tuple(self._active_ws)
            self._active_ws.clear()
        with self._session_lock:
            sessions = tuple(self._sessions)
            self._sessions.clear()
        close_all([super().close, self._cache.close,
                   *(connection.close for connection in connections),
                   *(session.close for session in sessions)])
