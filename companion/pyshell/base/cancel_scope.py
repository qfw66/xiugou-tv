"""Cooperative ownership for synchronous SDK work running inside a stream or map."""

from contextlib import contextmanager
from contextvars import ContextVar
import threading


_CURRENT = ContextVar("runtime_cancel_scope", default=None)


def current_scope():
    return _CURRENT.get()


def close_all(actions):
    """Attempt every owned cleanup before propagating the first failure."""
    failure = None
    for action in actions:
        try:
            action()
        except BaseException as error:
            if failure is None:
                failure = error
    if failure is not None:
        raise failure


class CancelScope:
    def __init__(self):
        self.event = threading.Event()
        self._lock = threading.Lock()
        self._resources = {}

    def check(self):
        if self.event.is_set():
            raise InterruptedError("Network owner closed")

    def add(self, resource):
        with self._lock:
            self.check()
            self._resources[resource] = self._resources.get(resource, 0) + 1

    def discard(self, resource):
        with self._lock:
            count = self._resources.get(resource, 0)
            if count > 1:
                self._resources[resource] = count - 1
            else:
                self._resources.pop(resource, None)

    @contextmanager
    def activate(self):
        token = _CURRENT.set(self)
        try:
            yield
        finally:
            _CURRENT.reset(token)

    def close(self):
        with self._lock:
            self.event.set()
            resources = tuple(self._resources)
            self._resources.clear()
        close_all(resource.close for resource in resources)


def bind(resource, owner):
    scopes = [owner]
    active = current_scope()
    if active is not None and active is not owner:
        scopes.append(active)
    attached = []
    try:
        for scope in scopes:
            scope.add(resource)
            attached.append(scope)
    except BaseException:
        for scope in attached:
            scope.discard(resource)
        resource.close()
        raise

    def release():
        for scope in attached:
            scope.discard(resource)

    return release
