"""Owned HTTP exchanges with bounded reads, cancellation and one call deadline."""

from email.message import Message
import http.client
import http.cookiejar
from http.cookies import CookieError, SimpleCookie
import io
import socket
import ssl
import threading
import time
import urllib.parse
import urllib.request

from .cancel_scope import current_scope


MAX_READ_BYTES = 1024 * 1024
MAX_HEADER_BYTES = 64 * 1024


class _SocketInput(io.RawIOBase):
    def __init__(self, exchange):
        super().__init__()
        self._exchange = exchange

    def readable(self):
        return True

    def readinto(self, buffer):
        return self._exchange.receive_into(buffer)


class _HttpInput(io.BufferedReader):
    def __init__(self, exchange):
        super().__init__(_SocketInput(exchange))
        self.reading_headers = True
        self.header_bytes = 0

    def readline(self, size=-1):
        line = super().readline(size)
        if self.reading_headers:
            self.header_bytes += len(line)
            if self.header_bytes > MAX_HEADER_BYTES:
                raise http.client.HTTPException("HTTP headers exceed limit")
        return line


class _ResponseSocket:
    def __init__(self, exchange):
        self.file = _HttpInput(exchange)

    def makefile(self, mode):
        return self.file


def _safe_error(error):
    if isinstance(error, InterruptedError):
        return InterruptedError("Network owner closed")
    if isinstance(error, TimeoutError):
        return TimeoutError("HTTP request timeout")
    return OSError("HTTP request failed (" + type(error).__name__ + ")")


def _response_headers(message):
    result = {}
    for name in message.keys():
        values = message.get_all(name)
        result[name] = values if len(values) > 1 else values[0]
    return result


class _CookieResponse:
    def __init__(self, headers):
        self._headers = headers

    def info(self):
        return self._headers


class SessionCookies:
    def __init__(self):
        self._policy = http.cookiejar.DefaultCookiePolicy(
            strict_ns_domain=http.cookiejar.DefaultCookiePolicy.DomainStrictNonDomain)
        self._jar = http.cookiejar.CookieJar(self._policy)
        self._lock = threading.Lock()
        self._closed = False

    def _validated(self, url, value):
        if (not isinstance(value, str) or not value or len(value) > 8192
                or any(ord(c) < 32 or ord(c) == 127 for c in value)):
            return None
        parsed = SimpleCookie()
        try:
            parsed.load(value)
        except CookieError:
            return None
        if len(parsed) != 1:
            return None
        cookie = next(iter(parsed.values()))
        host = urllib.parse.urlsplit(url).hostname.lower()
        domain = cookie["domain"].lower().lstrip(".")
        if domain and (domain.endswith(".") or not (host == domain or host.endswith("." + domain))
                       or ("." not in domain and host != domain)):
            return None
        message = Message()
        message["Set-Cookie"] = value
        return _CookieResponse(message)

    def set(self, url, value):
        response = self._validated(url, value)
        if response is None:
            return False
        request = urllib.request.Request(url)
        with self._lock:
            if self._closed:
                raise InterruptedError("Network owner closed")
            cookies = self._jar.make_cookies(response, request)
            accepted = not cookies
            for cookie in cookies:
                if self._policy.set_ok(cookie, request):
                    self._jar.set_cookie(cookie)
                    accepted = True
            return accepted

    def request(self, url, headers):
        request = urllib.request.Request(url, headers=headers)
        with self._lock:
            if self._closed:
                raise InterruptedError("Network owner closed")
            self._jar.add_cookie_header(request)
        return request

    def receive(self, url, headers):
        for value in headers.get_all("Set-Cookie", []):
            self.set(url, value)

    def close(self):
        with self._lock:
            self._closed = True
            self._jar.clear()


class RuntimeReader:
    """A single owned response; reads are bounded bytes and EOF is None."""

    def __init__(self, exchange, *, code=None, headers=None, content_type=None):
        self._exchange = exchange
        if code is None:
            response = exchange.response
            self.code = response.status
            self.headers = _response_headers(response.headers)
            self.contentType = response.headers.get("Content-Type", "application/octet-stream")
        else:
            self.code = code
            self.headers = headers
            self.contentType = content_type

    def read(self, size=65536):
        if type(size) is not int or not 1 <= size <= MAX_READ_BYTES:
            raise ValueError("read size must be an integer from 1 to 1048576")
        scope = current_scope()
        if scope is not None:
            scope.add(self._exchange)
        try:
            result = self._exchange.read(size)
            if scope is not None:
                scope.check()
            return result
        finally:
            if scope is not None:
                scope.discard(self._exchange)

    def close(self):
        self._exchange.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class HttpExchange:
    def __init__(self, timeout, call_timeout, release, cookies=None):
        self._cookies = cookies
        self._timeout = timeout
        self._deadline = time.monotonic() + call_timeout if call_timeout else None
        self._release = release
        self._state_lock = threading.Lock()
        self._read_lock = threading.Lock()
        self._socket = None
        self.response = None
        self._closed = False
        self._eof = False

    def _remaining(self):
        if self._closed:
            raise InterruptedError("Network owner closed")
        if self._deadline is None:
            return self._timeout
        remaining = self._deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("HTTP request timeout")
        return min(self._timeout, remaining)

    def _addresses(self, host, port):
        done, values = threading.Event(), []

        def resolve():
            try:
                values.append(socket.getaddrinfo(host, port, type=socket.SOCK_STREAM))
            except OSError as error:
                values.append(error)
            finally:
                done.set()

        threading.Thread(target=resolve, daemon=True).start()
        dns_deadline = time.monotonic() + self._remaining()
        while not done.is_set():
            remaining = min(self._remaining(), dns_deadline - time.monotonic())
            if remaining <= 0:
                raise TimeoutError("HTTP request timeout")
            done.wait(min(remaining, 0.02))
        self._remaining()
        if isinstance(values[0], OSError):
            raise values[0]
        return values[0]

    def _connect(self, parsed):
        host = parsed.hostname.encode("idna").decode("ascii")
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        last_error = OSError("HTTP connection unavailable")
        for family, kind, protocol, _, address in self._addresses(host, port):
            stream = socket.socket(family, kind, protocol)
            with self._state_lock:
                if self._closed:
                    stream.close()
                    raise InterruptedError("Network owner closed")
                self._socket = stream
            try:
                stream.settimeout(self._remaining())
                stream.connect(address)
                self._remaining()
                if parsed.scheme == "https":
                    context = ssl.create_default_context()
                    self._remaining()
                    with self._state_lock:
                        if self._closed:
                            raise InterruptedError("Network owner closed")
                        stream = context.wrap_socket(stream, server_hostname=host,
                                                     do_handshake_on_connect=False)
                        self._socket = stream
                    stream.settimeout(self._remaining())
                    stream.do_handshake()
                    self._remaining()
                return
            except OSError as error:
                last_error = error
                self._drop_socket()
                self._remaining()
        raise last_error

    def _drop_socket(self):
        with self._state_lock:
            stream, self._socket = self._socket, None
        if stream is not None:
            try:
                stream.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            stream.close()

    def receive_into(self, buffer):
        timeout = self._remaining()
        stream = self._socket
        if stream is None:
            raise InterruptedError("Network owner closed")
        try:
            stream.settimeout(timeout)
            count = stream.recv_into(buffer)
        except OSError:
            self._remaining()
            raise
        self._remaining()
        return count

    def _send(self, data):
        timeout = self._remaining()
        stream = self._socket
        if stream is None:
            raise InterruptedError("Network owner closed")
        stream.settimeout(timeout)
        stream.sendall(data)
        self._remaining()

    def _dispose_response(self):
        response, self.response = self.response, None
        if response is not None:
            response.close()
        self._drop_socket()

    def _finish(self):
        self._eof = True
        self._dispose_response()
        self._release(self)

    def close(self):
        with self._state_lock:
            self._closed = True
        self._drop_socket()
        if self._read_lock.acquire(blocking=False):
            try:
                self._dispose_response()
            finally:
                self._read_lock.release()
        self._release(self)

    def _request(self, url, method, body, headers):
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme not in ("http", "https") or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or any(ord(c) < 32 or ord(c) == 127 for c in url)):
            raise ValueError("invalid HTTP redirect URL")
        self._connect(parsed)
        if self._cookies is not None:
            headers = dict(self._cookies.request(url, headers).header_items())
        request_headers = {"-".join(part.capitalize() for part in name.split("-")): value
                           for name, value in headers.items()}
        default_host = parsed.netloc.encode("idna").decode("ascii")
        request_headers.setdefault("Host", default_host)
        request_headers.setdefault("Accept-Encoding", "identity")
        request_headers["Connection"] = "close"
        request_headers.pop("Transfer-Encoding", None)
        if body is not None:
            request_headers["Content-Length"] = str(len(body))
        else:
            request_headers.pop("Content-Length", None)
        target = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
        target = urllib.parse.quote(target, safe="/?!$&'()*+,;=:%@-._~")
        head = method + " " + target + " HTTP/1.1\r\n"
        head += "".join(name + ": " + value + "\r\n"
                        for name, value in request_headers.items()) + "\r\n"
        self._send(head.encode("latin-1"))
        if body is not None:
            self._send(body)
        source = _ResponseSocket(self)
        self.response = http.client.HTTPResponse(source, method=method)
        self.response.begin()
        if not 200 <= self.response.status <= 599:
            raise http.client.HTTPException("unsupported HTTP response status")
        source.file.reading_headers = False
        self._remaining()
        if self._cookies is not None:
            self._cookies.receive(url, self.response.headers)

    def open(self, url, method, body, headers, redirect):
        with self._read_lock:
            try:
                for hop in range(11):
                    self._request(url, method, body, headers)
                    location = self.response.headers.get("Location")
                    status = self.response.status
                    if not redirect or status not in (301, 302, 303, 307, 308) or not location:
                        return RuntimeReader(self)
                    if hop == 10:
                        raise ValueError("too many HTTP redirects")
                    target = urllib.parse.urljoin(url, location)
                    previous, following = urllib.parse.urlsplit(url), urllib.parse.urlsplit(target)
                    if (previous.scheme, previous.hostname, previous.port) != (
                            following.scheme, following.hostname, following.port):
                        headers = {name: value for name, value in headers.items()
                                   if name.lower() not in ("authorization", "proxy-authorization", "cookie", "host")}
                    if (status in (301, 302) and method == "POST") or (status == 303 and method != "HEAD"):
                        method, body = "GET", None
                        headers = {name: value for name, value in headers.items()
                                   if name.lower() not in ("content-type", "content-length")}
                    self._dispose_response()
                    url = target
            except (OSError, ValueError, http.client.HTTPException) as error:
                self._dispose_response()
                self._release(self)
                if self._closed:
                    raise InterruptedError("Network owner closed") from None
                raise _safe_error(error) from None

    def read(self, size):
        if not self._read_lock.acquire(blocking=False):
            raise RuntimeError("concurrent reads are not allowed")
        try:
            if self._eof:
                return None
            self._remaining()
            response = self.response
            chunk = response.read1(size)
            self._remaining()
            if not chunk:
                if response.length not in (None, 0):
                    raise http.client.IncompleteRead(b"")
                self._finish()
                return None
            if response.isclosed():
                self._finish()
            return chunk
        except (OSError, ValueError, http.client.HTTPException) as error:
            self.close()
            raise _safe_error(error) from None
        finally:
            if self._closed:
                self._dispose_response()
            self._read_lock.release()
