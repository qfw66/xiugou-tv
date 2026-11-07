"""Best-effort JSON persistence for the host's per-script memory cache."""

import hashlib
import json
import os
import sys
import tempfile
import threading


class ScriptCache(dict):
    MAX_FILE_BYTES = 1024 * 1024

    def __init__(self):
        super().__init__()
        self._lock = threading.RLock()
        self._reported = set()
        self._path = None
        directory = os.environ.get("XIUGOU_CACHE_DIR", "")
        identity = os.environ.get("XIUGOU_SCRIPT_ID", "")
        if not directory or not identity:
            return
        try:
            if not os.path.isabs(directory):
                raise ValueError("cache directory must be absolute")
            digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
            self._path = os.path.join(directory, digest + ".json")
            with open(self._path, "rb") as source:
                payload = source.read(self.MAX_FILE_BYTES + 1)
            if len(payload) > self.MAX_FILE_BYTES:
                self._report("size limit exceeded")
                return
            values = json.loads(payload.decode("utf-8"))
            if not isinstance(values, dict):
                raise ValueError("cache must be a JSON object")
            dict.update(self, values)
        except FileNotFoundError:
            pass
        except Exception:
            self._report("read failed")

    def __setitem__(self, key, value):
        with self._lock:
            dict.__setitem__(self, key, value)
            if self._path is not None:
                self._persist()

    def _persist(self):
        temporary = None
        try:
            entries = []
            for key, value in dict.items(self):
                try:
                    if not isinstance(key, str):
                        raise TypeError("persistent keys must be strings")
                    encoded = json.dumps(value, ensure_ascii=True, allow_nan=False)
                    entries.append(json.dumps(key, ensure_ascii=True) + ":" + encoded)
                except Exception:
                    self._report("entry is not JSON serializable")
            payload = "{" + ",".join(entries) + "}"
            if len(payload) > self.MAX_FILE_BYTES:
                self._report("size limit exceeded")
                return
            directory = os.path.dirname(self._path)
            os.makedirs(directory, mode=0o700, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=directory,
                prefix=os.path.basename(self._path) + ".", suffix=".tmp", delete=False,
            ) as target:
                temporary = target.name
                target.write(payload)
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary, self._path)
            temporary = None
        except Exception:
            self._report("write failed")
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except OSError:
                    self._report("temporary file cleanup failed")

    def _report(self, reason):
        if reason in self._reported:
            return
        self._reported.add(reason)
        try:
            sys.stderr.write("[spider-cache] %s; memory cache remains available\n" % reason)
            sys.stderr.flush()
        except Exception:
            pass
