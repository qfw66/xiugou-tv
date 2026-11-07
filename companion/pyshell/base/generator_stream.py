"""Adapt a byte iterator to the same owned reader used by HTTP proxy streams."""

import threading

from .cancel_scope import CancelScope, bind, close_all
from .http_transport import RuntimeReader


class GeneratorExchange:
    def __init__(self, source, owner):
        if not hasattr(source, "__next__") or iter(source) is not source:
            raise TypeError("stream source must be a byte iterator")
        self._source = source
        self._scope = CancelScope()
        self._read_lock = threading.Lock()
        self._pending = memoryview(b"")
        self._finished = False
        self._eof = False
        self._release = lambda: None
        self._release = bind(self, owner)
        if self._finished:
            self._release()

    def reader(self):
        return RuntimeReader(self, code=200, headers={}, content_type="application/octet-stream")

    def _finish(self):
        if self._finished:
            return
        self._finished = True
        self._pending = memoryview(b"")
        try:
            with self._scope.activate():
                close = getattr(self._source, "close", None)
                if close is not None:
                    close()
        finally:
            try:
                self._scope.close()
            finally:
                self._release()

    def read(self, size):
        if not self._read_lock.acquire(blocking=False):
            raise RuntimeError("concurrent reads are not allowed")
        try:
            if self._eof:
                return None
            self._scope.check()
            while not self._pending:
                with self._scope.activate():
                    self._scope.check()
                    try:
                        chunk = next(self._source)
                    except StopIteration:
                        self._scope.check()
                        self._eof = True
                        self._finish()
                        return None
                    self._scope.check()
                if not isinstance(chunk, (bytes, bytearray, memoryview)):
                    raise TypeError("stream chunks must be bytes, bytearray or contiguous memoryview")
                view = memoryview(chunk)
                if not view.c_contiguous:
                    raise ValueError("stream memoryview must be contiguous")
                self._pending = view.cast("B")
            result = bytes(self._pending[:size])
            self._pending = self._pending[size:]
            return result
        except BaseException:
            self._finish()
            raise
        finally:
            self._read_lock.release()

    def _finish_if_idle(self):
        if self._read_lock.acquire(blocking=False):
            try:
                self._finish()
            finally:
                self._read_lock.release()

    def close(self):
        close_all((self._scope.close, self._finish_if_idle))
