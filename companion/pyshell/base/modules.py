"""Declared, entry-relative Python helpers owned by one spider generation."""

import builtins
import hashlib
import http.client
import keyword
import os
from pathlib import Path
import re
import socket
import sys
import threading
import time
from types import ModuleType
import urllib.error
import urllib.parse
import urllib.request
import uuid


MAX_SOURCE_BYTES = 1024 * 1024
MAX_MODULES = 32
LOAD_TIMEOUT_SECONDS = 10.0
HTTP_TIMEOUT_SECONDS = 5.0


def _name(value):
    if not isinstance(value, str):
        raise TypeError("module name must be a string")
    value = value.removesuffix(".py")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]{0,127}", value) or keyword.iskeyword(value):
        raise ValueError("invalid declared module name")
    return value


def _source(value):
    if not isinstance(value, str) or not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("invalid module source")
    if os.path.isabs(value) and not value.startswith(("//", "\\\\")):
        return Path(value).resolve().as_uri()
    try:
        parsed = urllib.parse.urlsplit(value)
        if (parsed.scheme not in ("http", "https", "file") or parsed.fragment
                or parsed.username is not None or parsed.password is not None):
            raise ValueError()
        if parsed.scheme == "file":
            if parsed.netloc not in ("", "localhost") or parsed.query:
                raise ValueError()
            path = urllib.request.url2pathname(parsed.path)
            if (not os.path.isabs(path) or path.startswith(("//", "\\\\"))
                    or any(ord(c) < 32 or ord(c) == 127 for c in path)):
                raise ValueError()
            return Path(path).resolve().as_uri()
        if not parsed.hostname or parsed.port == 0 or "\\" in value:
            raise ValueError()
        return urllib.parse.quote(value, safe=":/?#[]@!$&'()*+,;=%~")
    except (ValueError, OSError):
        raise ValueError("invalid module source") from None


def _resolve(location, parent):
    if (not isinstance(location, str) or not location
            or any(ord(c) < 32 or ord(c) == 127 for c in location)
            or location.startswith(("//", "\\\\"))):
        raise ValueError("invalid module source")
    # A URL-rooted path keeps its HTTP origin, including on Windows where /x is absolute.
    if location.startswith("/") and urllib.parse.urlsplit(parent).scheme in ("http", "https"):
        return _source(urllib.parse.urljoin(parent, location))
    if os.path.isabs(location) or urllib.parse.urlsplit(location).scheme:
        return _source(location)
    origin = urllib.parse.urlsplit(parent)
    relative = urllib.parse.urlsplit(location.replace("\\", "/"))
    path = origin.path.rsplit("/", 1)[0] + "/" + relative.path
    segments = []
    # Proxy URL paths can contain https://; empty segments must survive resolution.
    for segment in path.split("/"):
        if segment == "..":
            if len(segments) > 1:
                segments.pop()
        elif segment != ".":
            segments.append(segment)
    if path.endswith(("/.", "/..")):
        segments.append("")
    return _source(urllib.parse.urlunsplit((origin.scheme, origin.netloc,
                    "/".join(segments), relative.query, relative.fragment)))


def _entry(api, base):
    if not api:
        raise RuntimeError("module source is not configured")
    if base and api.startswith("/") and urllib.parse.urlsplit(base).scheme in ("http", "https"):
        return _resolve(api, _source(base))
    if os.path.isabs(api) or urllib.parse.urlsplit(api).scheme:
        return _source(api)
    if not base:
        raise RuntimeError("relative module entry requires a source base")
    base = _source(base)
    return _resolve(api, base.rstrip("/") + "/")


def _declarations(value, entry):
    if not isinstance(value, (list, tuple, dict)) or len(value) > MAX_MODULES:
        raise ValueError("getDependence must declare at most 32 modules")
    pairs = value.items() if isinstance(value, dict) else ((None, item) for item in value)
    result = {}
    for alias, location in pairs:
        if not isinstance(location, str) or not location:
            raise ValueError("invalid declared module source")
        decoded = urllib.parse.unquote(location).replace("\\", "/")
        parsed = urllib.parse.urlsplit(decoded)
        if ".." in parsed.path.split("/") or decoded.startswith(("//", "\\\\")):
            raise ValueError("unsafe declared module source")
        alias = _name(alias if alias is not None else parsed.path.rsplit("/", 1)[-1])
        if alias in result:
            raise ValueError("duplicate declared module name")
        if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", location):
            location += ".py"
        resolved = _resolve(location, entry)
        if not urllib.parse.urlsplit(resolved).path.endswith(".py"):
            raise ValueError("declared module source must be Python")
        result[alias] = resolved
    return result


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        response.close()
        raise ImportError("module source redirects are not supported")


class RuntimeModules:
    """No global module aliases or shared source-file cache are created."""

    def __init__(self):
        site = os.environ.get("XIUGOU_SCRIPT_SITE_KEY", "")
        if not site.strip():
            raise RuntimeError("module site is not configured")
        effective_entry = os.environ.get("XIUGOU_SCRIPT_ENTRY")
        self._entry = (_source(effective_entry) if effective_entry is not None else
                       _entry(os.environ.get("XIUGOU_SCRIPT_API", ""),
                              os.environ.get("XIUGOU_SCRIPT_BASE", "")))
        identity = hashlib.sha256((site + "\0" + self._entry).encode("utf-8")).hexdigest()[:24]
        self._namespace = "_xiugou_modules_" + identity + "_" + uuid.uuid4().hex
        self._package = ModuleType(self._namespace)
        self._declared = None
        self._modules = {}
        self._loading = set()
        self._lock = threading.Lock()
        self._cancelled = threading.Event()
        self._sockets = set()
        self._socket_lock = threading.Lock()

    def load(self, name, declarations):
        name = _name(name)
        if not self._lock.acquire(timeout=LOAD_TIMEOUT_SECONDS):
            raise TimeoutError("module initialization timeout")
        try:
            if self._cancelled.is_set():
                raise TimeoutError("module initialization timeout")
            if name in self._modules:
                return self._modules[name]
            done, result = threading.Event(), []
            deadline = time.monotonic() + LOAD_TIMEOUT_SECONDS

            def trace(frame, event, arg):
                if self._cancelled.is_set() or time.monotonic() >= deadline:
                    raise TimeoutError("module initialization timeout")
                return trace

            def initialize():
                try:
                    sys.settrace(trace)
                    if self._declared is None:
                        self._declared = _declarations(declarations(), self._entry)
                    result.append((True, self._load(name)))
                except BaseException as error:
                    result.append((False, error))
                finally:
                    sys.settrace(None)
                    done.set()

            worker = threading.Thread(target=initialize, name="script-module", daemon=True)
            worker.start()
            if not done.wait(max(0, deadline - time.monotonic())):
                self._cancelled.set()
                self._close_sockets()
                raise TimeoutError("module initialization timeout")
            succeeded, value = result[0]
            if succeeded:
                return value
            if isinstance(value, TimeoutError):
                self._cancelled.set()
                self._close_sockets()
            raise value
        finally:
            self._lock.release()

    def _close_sockets(self):
        with self._socket_lock:
            sockets = tuple(self._sockets)
        for stream in sockets:
            try:
                stream.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            stream.close()

    def _download(self, source):
        owner = self

        class Connection(http.client.HTTPConnection):
            def connect(self):
                super().connect()
                with owner._socket_lock:
                    owner._sockets.add(self.sock)
                    if owner._cancelled.is_set():
                        self.sock.close()
                        raise TimeoutError("module initialization timeout")

        class SecureConnection(http.client.HTTPSConnection):
            def connect(self):
                super().connect()
                with owner._socket_lock:
                    owner._sockets.add(self.sock)
                    if owner._cancelled.is_set():
                        self.sock.close()
                        raise TimeoutError("module initialization timeout")

        class HTTPHandler(urllib.request.HTTPHandler):
            def http_open(self, request):
                return self.do_open(Connection, request)

        class HTTPSHandler(urllib.request.HTTPSHandler):
            def https_open(self, request):
                return self.do_open(SecureConnection, request, context=self._context)

        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), HTTPHandler(),
                                             HTTPSHandler(), _NoRedirect())
        request = urllib.request.Request(source, headers={"Accept-Encoding": "identity"})
        try:
            with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
                if response.status != 200 or response.headers.get("Content-Encoding", "identity") != "identity":
                    raise ImportError("module source response is invalid")
                length = response.headers.get("Content-Length")
                if length is not None and (not length.isdigit() or int(length) > MAX_SOURCE_BYTES):
                    raise ImportError("module source exceeds size limit")
                data = response.read(MAX_SOURCE_BYTES + 1)
                if length is not None and len(data) != int(length):
                    raise ImportError("module source response is incomplete")
        except TimeoutError:
            raise
        except urllib.error.HTTPError as error:
            error.close()
            raise ImportError("module source download failed") from None
        except Exception:
            raise ImportError("module source download failed") from None
        finally:
            self._close_sockets()
            with self._socket_lock:
                self._sockets.clear()
        if len(data) > MAX_SOURCE_BYTES:
            raise ImportError("module source exceeds size limit")
        return data

    def _read(self, source):
        parsed = urllib.parse.urlsplit(source)
        if parsed.scheme != "file":
            return self._download(source)
        try:
            with open(urllib.request.url2pathname(parsed.path), "rb") as stream:
                data = stream.read(MAX_SOURCE_BYTES + 1)
        except OSError:
            raise ImportError("module source is unavailable") from None
        if len(data) > MAX_SOURCE_BYTES:
            raise ImportError("module source exceeds size limit")
        return data

    def _import(self, name, globals=None, locals=None, fromlist=(), level=0):
        if level == 1 and not name:
            for item in fromlist:
                if item == "*":
                    raise ImportError("wildcard relative module import is not supported")
                setattr(self._package, item, self._load(_name(item)))
            return self._package
        if level > 1 or "." in name and name.split(".")[0] in self._declared:
            raise ImportError("invalid declared module import")
        if level or name in self._declared:
            return self._load(_name(name))
        if name.split(".")[0] not in sys.stdlib_module_names:
            raise ImportError("module import is not declared")
        return builtins.__import__(name, globals, locals, fromlist, level)

    def _load(self, name):
        if name not in self._declared:
            raise ImportError("module is not declared")
        if name in self._modules:
            return self._modules[name]
        if name in self._loading:
            raise ImportError("circular declared module import")
        source = self._declared[name]
        self._loading.add(name)
        try:
            data = self._read(source)
            module = ModuleType(self._namespace + "." + name)
            module.__file__ = source
            module.__package__ = self._namespace
            module.__builtins__ = {**vars(builtins), "__import__": self._import}
            try:
                exec(compile(data, source, "exec"), module.__dict__)
            except TimeoutError:
                raise
            except BaseException:
                raise ImportError("cannot initialize declared module") from None
            if self._cancelled.is_set():
                raise TimeoutError("module initialization timeout")
            self._modules[name] = module
            return module
        finally:
            self._loading.discard(name)
