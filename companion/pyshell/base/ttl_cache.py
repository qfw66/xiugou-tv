"""Bounded public TTL snapshots; disk identity is the site and original script URL."""

from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import threading
import time


MAX_KEYS = 256
MAX_NAMESPACE_BYTES = 16 * 1024 * 1024
MAX_ROOT_BYTES = 64 * 1024 * 1024
MAX_NAMESPACES = 256
_CACHE_FILE = re.compile(r"[0-9a-f]{64}\.json\Z")


def _encode(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")


class TtlCache:
    def __init__(self):
        self._memory = {}
        self._lock = threading.RLock()
        root = os.environ.get("XIUGOU_NET_CACHE_DIR", "")
        site = os.environ.get("XIUGOU_SCRIPT_SITE_KEY", "")
        api = os.environ.get("XIUGOU_SCRIPT_API", "")
        self._root = Path(root) if root and Path(root).is_absolute() and site.strip() and api.strip() else None
        self._name = hashlib.sha256(_encode([site, api])).hexdigest() + ".json"

    def _remember(self, key, persist, entry):
        with self._lock:
            identity = (key, persist)
            self._memory.pop(identity, None)
            self._memory[identity] = entry
            while (len(self._memory) > MAX_KEYS
                   or sum(len(value[1].encode("utf-8")) for value in self._memory.values()) > MAX_NAMESPACE_BYTES):
                self._memory.pop(next(iter(self._memory)))

    def lookup(self, key, persist, check):
        with self._lock:
            entry = self._memory.get((key, persist))
            if entry is not None and time.monotonic() < entry[0]:
                return entry[1]
            self._memory.pop((key, persist), None)
        if not persist:
            return None
        with self._disk_lock(check):
            entry = self._read().get(key)
        if entry is None:
            return None
        remaining = entry["expires"] - time.time()
        if remaining <= 0:
            return None
        encoded = json.dumps(entry["value"], ensure_ascii=False, allow_nan=False)
        self._remember(key, True, (time.monotonic() + remaining, encoded))
        return encoded

    def put(self, key, ttl, persist, encoded, check):
        check()
        expires = time.monotonic() + ttl
        if persist:
            completed = time.time()
            with self._disk_lock(check):
                entries = self._read()
                entries.pop(key, None)
                entries[key] = {"expires": completed + ttl, "value": json.loads(encoded)}
                self._write(entries, check)
        check()
        self._remember(key, persist, (expires, encoded))

    def clear(self, key, check, *, disk=True):
        with self._lock:
            if key is None:
                self._memory.clear()
            else:
                self._memory.pop((key, False), None)
                self._memory.pop((key, True), None)
        if disk and self._root is not None:
            with self._disk_lock(check):
                entries = self._read()
                if key is None:
                    entries.clear()
                else:
                    entries.pop(key, None)
                self._write(entries, check)

    def close(self):
        with self._lock:
            self._memory.clear()

    @contextmanager
    def _disk_lock(self, check):
        if self._root is None:
            raise RuntimeError("persistent network cache is not configured")
        try:
            self._root.mkdir(parents=True, exist_ok=True)
            with (self._root / ".lock").open("a+b") as lock:
                lock.seek(0, os.SEEK_END)
                if lock.tell() == 0:
                    lock.write(b"\0")
                    lock.flush()
                until = time.monotonic() + 2
                while True:
                    check()
                    try:
                        lock.seek(0)
                        if os.name == "nt":
                            import msvcrt
                            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                        else:
                            import fcntl
                            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except OSError:
                        if time.monotonic() >= until:
                            raise TimeoutError("persistent network cache lock timeout") from None
                        time.sleep(0.01)
                try:
                    check()
                    yield
                finally:
                    lock.seek(0)
                    if os.name == "nt":
                        msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
                    else:
                        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except InterruptedError:
            raise
        except OSError:
            raise OSError("persistent network cache storage failed") from None

    def _read(self):
        try:
            with (self._root / self._name).open("rb") as stream:
                raw = stream.read(MAX_NAMESPACE_BYTES + 1)
            if len(raw) > MAX_NAMESPACE_BYTES:
                return {}
            data = json.loads(raw)
            if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("entries"), dict):
                return {}
            now = time.time()
            entries = {}
            for key, entry in data["entries"].items():
                if not isinstance(key, str) or not isinstance(entry, dict):
                    continue
                expires = entry.get("expires")
                if (type(expires) not in (int, float) or not math.isfinite(expires)
                        or expires <= now or "value" not in entry):
                    continue
                _encode(entry["value"])
                entries[key] = entry
            return entries
        except FileNotFoundError:
            return {}
        except (ValueError, UnicodeError, RecursionError):
            return {}

    def _write(self, entries, check):
        while len(entries) > MAX_KEYS:
            entries.pop(next(iter(entries)))
        payload = _encode({"version": 1, "entries": entries})
        while len(payload) > MAX_NAMESPACE_BYTES and entries:
            entries.pop(next(iter(entries)))
            payload = _encode({"version": 1, "entries": entries})
        files = []
        for path in self._root.iterdir():
            if _CACHE_FILE.fullmatch(path.name) and path.name != self._name and path.is_file():
                stat = path.stat()
                files.append((stat.st_mtime_ns, path, stat.st_size))
        total = sum(size for _, _, size in files) + len(payload)
        files.sort(key=lambda item: item[0])
        while files and (total > MAX_ROOT_BYTES or len(files) + 1 > MAX_NAMESPACES):
            _, path, size = files.pop(0)
            path.unlink()
            total -= size
        check()
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=self._root, prefix=".ttl-", suffix=".tmp", delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            check()
            os.replace(temporary, self._root / self._name)
            temporary = None
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
