"""Owned callback WebSockets with cancellable reconnect and independent idle time."""

import math
import re
import select
import socket
import ssl
import threading
import time

from .ws import WebSocketExchange, _ProtocolError


_MAX_MESSAGE = 8 * 1024 * 1024
_POLL = 0.02


def _milliseconds(value, name):
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or value <= 0):
        raise ValueError(name + " must be a finite positive millisecond value")
    return value / 1000.0


def _headers(value):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise TypeError("headers must be a dict or None")
    result = {}
    for name, item in value.items():
        if not isinstance(name, str) or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name):
            raise ValueError("invalid header name")
        if not isinstance(item, str) or any(ord(char) < 32 or ord(char) == 127 for char in item):
            raise ValueError("header values must be strings without control characters")
        item.encode("latin-1")
        result[name] = item
    return result


class _ConnectionExchange(WebSocketExchange):
    def __init__(self, url, headers, timeout, idle):
        super().__init__(url, headers, None, timeout, _MAX_MESSAGE)
        self._idle = idle
        self._live = False
        self._received_at = None
        self._write_lock = threading.Lock()
        self._io_lock = threading.Lock()
        self.peer_closed = False

    def open(self):
        self._deadline = time.monotonic() + self._timeout
        self._connect()
        code, headers = self._handshake()
        if code != 101:
            raise OSError("WebSocket handshake rejected")
        with self._lock:
            if self._closed:
                raise OSError("WebSocket connection cancelled")
            self._socket.setblocking(False)
            self._received_at = time.monotonic()
            self._live = True
        return headers

    def close(self):
        with self._io_lock:
            super().close()

    def _check(self, deadline):
        if self._closed:
            raise OSError("WebSocket connection cancelled")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("WebSocket operation timed out")
        return remaining

    def _wait(self, stream, writing, deadline):
        remaining = self._check(deadline)
        try:
            select.select([] if writing else [stream], [stream] if writing else [], [], min(_POLL, remaining))
        except ValueError:
            raise OSError("WebSocket connection cancelled") from None

    def _send(self, content):
        if not self._live:
            return super()._send(content)
        deadline = time.monotonic() + self._timeout
        while not self._write_lock.acquire(timeout=min(_POLL, self._check(deadline))):
            pass
        try:
            pending = memoryview(content)
            while pending:
                self._check(deadline)
                stream = self._socket
                if stream is None:
                    raise OSError("WebSocket connection cancelled")
                writing = True
                try:
                    # invariant: SSL calls are serialized, but never block while holding the I/O lock.
                    with self._io_lock:
                        self._check(deadline)
                        sent = stream.send(pending[:65536])
                    if not sent:
                        raise OSError("WebSocket send failed")
                    pending = pending[sent:]
                    continue
                except ssl.SSLWantReadError:
                    writing = False
                except (ssl.SSLWantWriteError, BlockingIOError):
                    pass
                self._wait(stream, writing, deadline)
        finally:
            self._write_lock.release()

    def _read(self, count):
        if not self._live:
            return super()._read(count)
        while len(self._buffer) < count:
            deadline = self._received_at + self._idle
            self._check(deadline)
            stream = self._socket
            if stream is None:
                raise OSError("WebSocket connection cancelled")
            writing = False
            try:
                with self._io_lock:
                    self._check(deadline)
                    piece = stream.recv(min(65536, count - len(self._buffer)))
                if not piece:
                    raise EOFError("WebSocket peer disconnected")
                self._buffer.extend(piece)
                self._received_at = time.monotonic()
                continue
            except ssl.SSLWantWriteError:
                writing = True
            except (ssl.SSLWantReadError, BlockingIOError):
                pass
            self._wait(stream, writing, deadline)
        result = bytes(self._buffer[:count])
        del self._buffer[:count]
        return result

    def _finish_close(self, payload, peer=True):
        self.peer_closed = peer
        try:
            self._send_frame(8, payload)
            stream = self._socket
            if stream is None:
                return
            with self._io_lock:
                stream.shutdown(socket.SHUT_WR)
            deadline, remaining = time.monotonic() + 0.05, self._limit
            # invariant: draining unread peer data avoids a reset discarding the close frame.
            while remaining > 0 and not self._closed and time.monotonic() < deadline:
                writing = False
                try:
                    with self._io_lock:
                        piece = stream.recv(min(65536, remaining))
                    if not piece:
                        break
                    remaining -= len(piece)
                    continue
                except ssl.SSLWantWriteError:
                    writing = True
                except (ssl.SSLWantReadError, BlockingIOError):
                    pass
                self._wait(stream, writing, deadline)
        except OSError:
            pass


class WebSocketConnection:
    """Start once; callbacks receive (self, event), final owner cleanup receives self.

    cancel/close never join the worker or wait for a user callback. A callback
    already in progress can finish after cancellation; no further event is queued.
    timeout bounds each handshake and write; idle bounds receive inactivity.
    """

    def __init__(self, url, options, callback, on_close):
        if options is None:
            options = {}
        if not isinstance(options, dict):
            raise TypeError("options must be a dict or None")
        if options.keys() - {"headers", "timeout", "idle", "reconnect"}:
            raise NotImplementedError("unsupported WebSocket connection option")
        if not callable(callback) or not callable(on_close):
            raise TypeError("callback and on_close must be callable")
        self._timeout = _milliseconds(options.get("timeout", 10000), "timeout")
        self._idle = _milliseconds(options.get("idle", 90000), "idle")
        self._reconnect = options.get("reconnect", False)
        if type(self._reconnect) is not bool:
            raise ValueError("reconnect must be a bool")
        self._url, self._headers = url, _headers(options.get("headers"))
        self._callback, self._on_close = callback, on_close
        self._exchange = self._new_exchange()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._started = self._finished = self._open = False

    def _new_exchange(self):
        return _ConnectionExchange(self._url, self._headers, self._timeout, self._idle)

    def start(self):
        with self._lock:
            if self._started or self._finished:
                return self
            self._started = True
        try:
            threading.Thread(target=self._run, name="script-ws-connection", daemon=True).start()
        except Exception:
            self.cancel()
            raise
        return self

    def send(self, content):
        if not isinstance(content, bytes):
            raise TypeError("WebSocket send content must be bytes")
        if len(content) > _MAX_MESSAGE:
            raise ValueError("WebSocket message exceeds 8 MiB limit")
        with self._lock:
            exchange = self._exchange if self._open and not self._finished else None
        if exchange is None:
            return False
        try:
            exchange._send_frame(2, content)
            return not self._stop.is_set()
        except OSError:
            exchange.close()
            return False

    def cancel(self):
        with self._lock:
            if self._finished:
                return
            self._finished = True
            self._open = False
            self._stop.set()
            exchange, self._exchange = self._exchange, None
        if exchange is not None:
            exchange.close()
        self._on_close(self)

    close = cancel

    def _deliver(self, event):
        with self._lock:
            if self._finished:
                return False
        try:
            self._callback(self, event)
        except Exception:
            self.cancel()
            return False
        return not self._stop.is_set()

    def _run(self):
        failures = 0
        try:
            while not self._stop.is_set():
                with self._lock:
                    exchange = self._exchange
                if exchange is None:
                    break
                opened_at = None
                error = None
                try:
                    headers = exchange.open()
                    with self._lock:
                        if self._finished:
                            break
                        self._open = True
                    opened_at = time.monotonic()
                    if not self._deliver({"type": "open", "headers": headers}):
                        break
                    while not self._stop.is_set():
                        content = exchange._message()
                        if not self._deliver({"type": "message", "binary": isinstance(content, bytes),
                                              "content": content}):
                            break
                except (OSError, EOFError, ValueError) as failure:
                    error = failure
                    if opened_at is not None and isinstance(failure, _ProtocolError):
                        exchange._finish_close(failure.close_code.to_bytes(2, "big"), peer=False)
                finally:
                    with self._lock:
                        self._open = False
                    exchange.close()
                if self._stop.is_set():
                    break
                message = "WebSocket connection failed (" + type(error).__name__ + ")"
                if not self._reconnect:
                    self._deliver({"type": "close"} if exchange.peer_closed else {"type": "error", "error": message})
                    break
                if opened_at is not None and time.monotonic() - opened_at >= 30:
                    failures = 0
                delay = min(0.25 * 2 ** failures, 5.0)
                failures = min(failures + 1, 5)
                if not self._deliver({"type": "retry", "error": message}) or self._stop.wait(delay):
                    break
                with self._lock:
                    if not self._finished:
                        self._exchange = self._new_exchange()
        finally:
            self.cancel()
