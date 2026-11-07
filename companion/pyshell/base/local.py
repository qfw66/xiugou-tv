"""Strict JSON settings persistence isolated by the host's Site.key."""

import hashlib
import json
import math
import os
import stat
import tempfile
import threading


_LOCKS = {}
_LOCKS_GUARD = threading.Lock()


class RuntimeLocal:
    MAX_FILE_BYTES = 1024 * 1024

    def __init__(self):
        directory = os.environ.get("XIUGOU_LOCAL_DIR", "")
        site_key = os.environ.get("XIUGOU_SCRIPT_SITE_KEY", "")
        if not directory or not os.path.isabs(directory) or not site_key.strip():
            raise RuntimeError("Local requires an absolute directory and a site key")
        self._directory = os.path.normcase(os.path.realpath(directory))
        digest = hashlib.sha256(site_key.encode("utf-8")).hexdigest()
        self._path = os.path.join(self._directory, digest + ".json")
        with _LOCKS_GUARD:
            self._lock = _LOCKS.setdefault(self._path, threading.RLock())

    def get(self, key, default=None):
        self._check_key(key)
        with self._lock:
            return self._read().get(key, default)

    def set(self, key, value):
        self._check_key(key)
        with self._lock:
            values = self._read()
            values[key] = value
            self._write(values)

    def delete(self, key):
        self._check_key(key)
        with self._lock:
            values = self._read()
            if key in values:
                del values[key]
                self._write(values)

    @staticmethod
    def _check_key(key):
        if not isinstance(key, str):
            raise TypeError("Local keys must be strings")

    @staticmethod
    def _validate_json(value, ancestors=None):
        if value is None or isinstance(value, (str, bool, int)):
            return
        if isinstance(value, float):
            if not math.isfinite(value):
                raise ValueError("Local numbers must be finite")
            return
        if not isinstance(value, (dict, list)):
            raise TypeError("Local values must be JSON values")
        if ancestors is None:
            ancestors = set()
        identity = id(value)
        if identity in ancestors:
            raise ValueError("Local values must not contain cycles")
        ancestors.add(identity)
        try:
            if isinstance(value, dict):
                for key, item in value.items():
                    RuntimeLocal._check_key(key)
                    RuntimeLocal._validate_json(item, ancestors)
            else:
                for item in value:
                    RuntimeLocal._validate_json(item, ancestors)
        finally:
            ancestors.remove(identity)

    def _read(self):
        try:
            with open(self._path, "rb") as source:
                payload = source.read(self.MAX_FILE_BYTES + 1)
        except FileNotFoundError:
            self._check_directory()
            return {}
        if len(payload) > self.MAX_FILE_BYTES:
            raise ValueError("Local snapshot exceeds 1 MiB limit")
        values = json.loads(payload.decode("utf-8"))
        if not isinstance(values, dict):
            raise ValueError("Local snapshot must be a JSON object")
        self._validate_json(values)
        return values

    def _check_directory(self):
        directory = self._directory
        while True:
            try:
                mode = os.stat(directory).st_mode
            except FileNotFoundError:
                parent = os.path.dirname(directory)
                if parent == directory:
                    raise
                directory = parent
            else:
                if not stat.S_ISDIR(mode):
                    raise NotADirectoryError("Local storage parent must be a directory")
                return

    def _write(self, values):
        self._validate_json(values)
        payload = json.dumps(values, ensure_ascii=True, allow_nan=False,
                             separators=(",", ":")).encode("utf-8")
        if len(payload) > self.MAX_FILE_BYTES:
            raise ValueError("Local snapshot exceeds 1 MiB limit")
        os.makedirs(self._directory, mode=0o700, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="wb", dir=self._directory,
                prefix=os.path.basename(self._path) + ".", suffix=".tmp", delete=False,
            ) as target:
                temporary = target.name
                target.write(payload)
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary, self._path)
            temporary = None
        finally:
            if temporary is not None:
                os.unlink(temporary)
