"""One bounded RFC6455 exchange, owned and cancelled by its script runtime."""

import base64
import hashlib
import re
import secrets
import socket
import ssl
import struct
import threading
import time
from urllib.parse import quote, urlsplit


_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
_MAX_HEADERS = 32 * 1024
_RESERVED_HEADERS = {"host", "upgrade", "connection", "sec-websocket-key",
                     "sec-websocket-version", "sec-websocket-extensions", "sec-websocket-protocol"}


class _ProtocolError(ValueError):
    def __init__(self, message, close_code=1002):
        super().__init__(message)
        self.close_code = close_code


class WebSocketExchange:
    def __init__(self, url, headers, payload, timeout, limit):
        if not isinstance(url, str) or any(ord(char) < 32 or ord(char) == 127 for char in url):
            raise ValueError("url must be a WS(S) URL without control characters")
        parsed = urlsplit(url)
        if (parsed.scheme not in ("ws", "wss") or not parsed.hostname or parsed.fragment
                or parsed.username is not None or parsed.password is not None or parsed.port == 0):
            raise ValueError("url must be an absolute WS(S) URL")
        if _RESERVED_HEADERS.intersection(key.lower() for key in headers):
            raise ValueError("headers cannot override the WebSocket handshake")
        self._host = parsed.hostname
        self._secure = parsed.scheme == "wss"
        self._port = parsed.port or (443 if self._secure else 80)
        self._authority = ("[" + self._host + "]" if ":" in self._host else self._host)
        if parsed.port is not None:
            self._authority += ":" + str(parsed.port)
        self._path = quote((parsed.path or "/") + ("?" + parsed.query if parsed.query else ""),
                           safe="/:?[]@!$&'()*+,;=%~")
        self._headers = headers
        self._payload = payload
        self._timeout = timeout
        self._limit = limit
        self._lock = threading.Lock()
        self._socket = None
        self._closed = False
        self._buffer = bytearray()
        self._deadline = None

    def close(self):
        with self._lock:
            self._closed = True
            stream, self._socket = self._socket, None
        if stream is not None:
            try:
                stream.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            stream.close()

    def _remaining(self):
        if self._closed:
            raise OSError("WebSocket exchange cancelled")
        remaining = self._deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("WebSocket deadline elapsed")
        return remaining

    def _addresses(self):
        ready, result, failure = threading.Event(), [], []
        host, port = self._host, self._port

        def resolve():
            try:
                result.extend(socket.getaddrinfo(host, port, type=socket.SOCK_STREAM))
            except (OSError, ValueError) as error:
                failure.append(error)
            finally:
                ready.set()

        # The system resolver cannot be cancelled; it owns no socket or runtime state.
        threading.Thread(target=resolve, name="script-ws-resolver", daemon=True).start()
        while not ready.wait(min(self._remaining(), 0.02)):
            pass
        self._remaining()
        if failure:
            raise failure[0]
        return result

    def _connect(self):
        last_error = OSError("WebSocket host has no address")
        for family, kind, protocol, _, address in self._addresses():
            stream = socket.socket(family, kind, protocol)
            try:
                with self._lock:
                    if self._closed:
                        raise OSError("WebSocket exchange cancelled")
                    self._socket = stream
                stream.settimeout(self._remaining())
                stream.connect(address)
                break
            except OSError as error:
                last_error = error
                with self._lock:
                    if self._socket is stream:
                        self._socket = None
                stream.close()
                self._remaining()
        else:
            raise last_error
        if self._secure:
            context = ssl.create_default_context()
            with self._lock:
                if self._closed:
                    raise OSError("WebSocket exchange cancelled")
                stream = context.wrap_socket(stream, server_hostname=self._host,
                                             do_handshake_on_connect=False)
                self._socket = stream
            stream.settimeout(self._remaining())
            stream.do_handshake()

    def _send(self, content):
        stream = self._socket
        if stream is None:
            raise OSError("WebSocket exchange cancelled")
        stream.settimeout(self._remaining())
        stream.sendall(content)

    def _read(self, count):
        while len(self._buffer) < count:
            stream = self._socket
            if stream is None:
                raise OSError("WebSocket exchange cancelled")
            stream.settimeout(self._remaining())
            piece = stream.recv(min(65536, count - len(self._buffer)))
            if not piece:
                raise EOFError("WebSocket closed before a complete message")
            self._buffer.extend(piece)
        result = bytes(self._buffer[:count])
        del self._buffer[:count]
        return result

    def _handshake(self):
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        lines = ["GET " + self._path + " HTTP/1.1", "Host: " + self._authority,
                 "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: " + key,
                 "Sec-WebSocket-Version: 13"]
        lines.extend(name + ": " + value for name, value in self._headers.items())
        request = ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")
        if len(request) > _MAX_HEADERS:
            raise ValueError("WebSocket request headers exceed limit")
        self._send(request)
        raw = bytearray()
        while not raw.endswith(b"\r\n\r\n"):
            raw.extend(self._read(1))
            if len(raw) > _MAX_HEADERS:
                raise _ProtocolError("WebSocket response headers exceed limit")
        lines = raw.decode("latin-1").split("\r\n")
        status = re.fullmatch(r"HTTP/1\.1 ([1-5][0-9]{2})(?: [^\r\n]*)?", lines[0])
        if status is None:
            raise _ProtocolError("invalid WebSocket HTTP status")
        headers, lowered = {}, {}
        for line in lines[1:-2]:
            name, separator, value = line.partition(":")
            if not separator or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name):
                raise _ProtocolError("invalid WebSocket HTTP header")
            value = value.strip(" \t")
            if any(ord(char) < 32 and char != "\t" or ord(char) == 127 for char in value):
                raise _ProtocolError("invalid WebSocket HTTP header")
            lowered.setdefault(name.lower(), []).append(value)
            if name in headers:
                previous = headers[name]
                headers[name] = previous + [value] if isinstance(previous, list) else [previous, value]
            else:
                headers[name] = value
        code = int(status[1])
        if code != 101:
            return code, headers
        expected = base64.b64encode(hashlib.sha1((key + _GUID).encode("ascii")).digest()).decode("ascii")
        if lowered.get("sec-websocket-accept") != [expected]:
            raise _ProtocolError("invalid WebSocket accept key")
        for name, expected in (("upgrade", "websocket"), ("connection", "upgrade")):
            tokens = {part.strip().lower() for value in lowered.get(name, []) for part in value.split(",")}
            if expected not in tokens:
                raise _ProtocolError("invalid WebSocket upgrade headers")
        if "sec-websocket-extensions" in lowered or "sec-websocket-protocol" in lowered:
            raise _ProtocolError("unsolicited WebSocket negotiation")
        return code, headers

    def _send_frame(self, opcode, payload):
        length = len(payload)
        if length < 126:
            header = bytes((128 | opcode, 128 | length))
        elif length <= 65535:
            header = bytes((128 | opcode, 128 | 126)) + struct.pack("!H", length)
        else:
            header = bytes((128 | opcode, 128 | 127)) + struct.pack("!Q", length)
        mask = secrets.token_bytes(4)
        encoded = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self._send(header + mask + encoded)

    def _read_frame(self, available):
        first, second = self._read(2)
        fin, opcode = bool(first & 128), first & 15
        if first & 112 or second & 128 or opcode not in (0, 1, 2, 8, 9, 10):
            raise _ProtocolError("invalid WebSocket frame")
        length = second & 127
        if opcode >= 8 and (not fin or length > 125):
            raise _ProtocolError("invalid WebSocket control frame")
        if length == 126:
            length = struct.unpack("!H", self._read(2))[0]
            if length < 126:
                raise _ProtocolError("non-canonical WebSocket frame length")
        elif length == 127:
            length = struct.unpack("!Q", self._read(8))[0]
            if length < 65536 or length & (1 << 63):
                raise _ProtocolError("invalid WebSocket frame length")
        if opcode < 8 and length > available:
            raise _ProtocolError("WebSocket message exceeds limit", 1009)
        return fin, opcode, self._read(length)

    def _message(self):
        content, message_opcode = bytearray(), None
        while True:
            fin, opcode, payload = self._read_frame(self._limit - len(content))
            if opcode == 9:
                self._send_frame(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode == 8:
                if len(payload) == 1:
                    raise _ProtocolError("invalid WebSocket close payload")
                if payload:
                    code = struct.unpack("!H", payload[:2])[0]
                    valid = {1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014}
                    if code not in valid and not 3000 <= code <= 4999:
                        raise _ProtocolError("invalid WebSocket close code")
                    try:
                        payload[2:].decode("utf-8")
                    except UnicodeDecodeError:
                        raise _ProtocolError("invalid WebSocket close reason", 1007) from None
                self._finish_close(payload)
                raise EOFError("WebSocket closed before a complete message")
            if opcode == 0:
                if message_opcode is None:
                    raise _ProtocolError("unexpected WebSocket continuation")
            elif message_opcode is not None:
                raise _ProtocolError("interleaved WebSocket data messages")
            else:
                message_opcode = opcode
            content.extend(payload)
            if fin:
                if message_opcode == 2:
                    return bytes(content)
                try:
                    return content.decode("utf-8")
                except UnicodeDecodeError:
                    raise _ProtocolError("invalid WebSocket text", 1007) from None

    def _finish_close(self, payload):
        try:
            self._send_frame(8, payload)
            stream = self._socket
            if stream is None:
                return
            stream.shutdown(socket.SHUT_WR)
            deadline = min(self._deadline, time.monotonic() + 0.05)
            remaining_bytes = self._limit
            while remaining_bytes > 0 and not self._closed:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                stream.settimeout(remaining)
                chunk = stream.recv(min(65536, remaining_bytes))
                if not chunk:
                    break
                remaining_bytes -= len(chunk)
        except OSError:
            pass

    def exchange(self):
        self._deadline = time.monotonic() + self._timeout
        upgraded = False
        try:
            self._connect()
            code, headers = self._handshake()
            if code != 101:
                return {"code": code, "headers": headers, "content": ""}
            upgraded = True
            if self._payload is not None:
                self._send_frame(1, self._payload)
            content = self._message()
            self._finish_close(struct.pack("!H", 1000))
            if self._closed:
                raise OSError("WebSocket exchange cancelled")
            return {"code": 101, "headers": headers, "content": content}
        except (OSError, ValueError, EOFError) as error:
            if upgraded and isinstance(error, _ProtocolError):
                self._finish_close(struct.pack("!H", error.close_code))
            return {"code": 0, "headers": {}, "content": "",
                    "error": "WebSocket exchange failed (" + type(error).__name__ + ")"}
        finally:
            self.close()
