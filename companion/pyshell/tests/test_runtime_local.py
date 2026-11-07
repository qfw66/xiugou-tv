"""Offline Local contracts: python -B -m unittest discover -s companion/pyshell/tests -p test_runtime_local.py -v."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
from unittest.mock import patch


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.spider import Spider  # noqa: E402


class RuntimeLocalTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xiugou-local-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / "local"
        self.env = dict(os.environ)
        self.env.update({
            "PYTHONIOENCODING": "utf-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "XIUGOU_LOCAL_DIR": str(self.directory),
            "XIUGOU_SCRIPT_SITE_KEY": "synthetic-ysp",
            "XIUGOU_CACHE_DIR": str(self.root / "legacy-cache"),
            "XIUGOU_SCRIPT_ID": "synthetic-legacy-script",
        })
        self.environment = patch.dict(os.environ, self.env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def run_local(self, calls, **environment):
        source = textwrap.dedent('''
            import json
            import sys
            sys.path.insert(0, sys.argv[1])
            from base.spider import Spider

            class AuthorSpider(Spider):
                def __init__(self):
                    self.previous = self.local.get("tv-device:v1")

            owner = AuthorSpider()
            results = [getattr(owner.local, method)(*args)
                       for method, args in json.load(sys.stdin)]
            print(json.dumps(results, ensure_ascii=True))
        ''')
        result = subprocess.run(
            [sys.executable, "-B", "-X", "utf8", "-c", source, str(SHELL)],
            input=json.dumps(calls), encoding="utf-8", capture_output=True,
            cwd=str(self.root), env=dict(self.env, **environment),
            timeout=15, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def test_identity_survives_fresh_process_without_super_init(self):
        identity = {"android_id": "0123456789abcdef", "mac": "02:12:34:56:78:90"}
        results = self.run_local([
            ("get", ["tv-device:v1"]),
            ("set", ["tv-device:v1", identity]),
            ("get", ["tv-device:v1"]),
        ], PYTHONHASHSEED="1", XIUGOU_SCRIPT_ID="original-script")
        self.assertEqual(results, [None, None, identity])
        self.assertEqual(self.run_local([
            ("get", ["tv-device:v1"]),
        ], PYTHONHASHSEED="2", XIUGOU_SCRIPT_ID="relocated-script"), [identity])

    def test_site_key_isolates_persistence_in_same_directory(self):
        self.run_local([("set", ["tv-device:v1", "site-a"])])
        results = self.run_local([
            ("get", ["tv-device:v1", "missing"]),
            ("set", ["tv-device:v1", "site-b"]),
        ], XIUGOU_SCRIPT_SITE_KEY="../other/site")
        self.assertEqual(results, ["missing", None])
        self.assertEqual(self.run_local([("get", ["tv-device:v1"])]), ["site-a"])
        self.assertEqual(len(list(self.directory.glob("*.json"))), 2)
        self.assertFalse((self.root / "other").exists())

    def local_file(self):
        files = list(self.directory.glob("*.json"))
        self.assertEqual(len(files), 1)
        return files[0]

    def test_json_values_are_detached_snapshots_without_expiration(self):
        owner = Spider()
        local = owner.local
        self.assertIs(owner.local, local)
        value = {"items": [0, False, None, "中文"], "expiresAt": 1}
        self.assertIsNone(local.set("preferences", value))
        value["items"].append("mutated input")
        snapshot = local.get("preferences")
        self.assertEqual(snapshot, {"items": [0, False, None, "中文"], "expiresAt": 1})
        snapshot["items"].append("mutated output")
        self.assertEqual(local.get("preferences"), {
            "items": [0, False, None, "中文"], "expiresAt": 1,
        })
        self.assertIsNone(local.set("null", None))
        self.assertIsNone(local.get("null", "fallback"))
        fallback = {"default": []}
        self.assertEqual(local.get("missing", fallback), fallback)
        self.assertIsNone(local.delete("preferences"))
        self.assertIsNone(local.delete("preferences"))
        self.assertIsNone(local.get("preferences"))
        self.assertEqual(self.run_local([("get", ["preferences", "deleted"])]), ["deleted"])

    def test_non_json_inputs_raise_without_replacing_complete_snapshot(self):
        local = Spider().local
        local.set("stable", "unchanged")
        stored = self.local_file()
        before = stored.read_bytes()
        circular = []
        circular.append(circular)
        for value in (object(), b"bytes", {"nested": (1, 2)}, {1: "non-string key"},
                      float("nan"), float("inf"), circular):
            with self.subTest(kind=type(value).__name__):
                stored.write_bytes(before)
                with self.assertRaises((TypeError, ValueError)):
                    local.set("stable", value)
                self.assertEqual(stored.read_bytes(), before)
                self.assertEqual(local.get("stable"), "unchanged")
        for method, args in (("get", [1]), ("set", [1, "value"]), ("delete", [1])):
            with self.subTest(method=method):
                with self.assertRaises(TypeError):
                    getattr(local, method)(*args)
        self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def test_invalid_snapshots_raise_on_reads_writes_and_deletes(self):
        local = Spider().local
        local.set("stable", "unchanged")
        stored = self.local_file()
        for payload in (b'{"stable":', b'[]', b'null', b'\xff\xfe',
                        b'{"value":NaN}', b'{"value":Infinity}', b'{"value":1e400}'):
            for method, args in (("get", ["stable"]), ("set", ["fresh", True]),
                                 ("delete", ["stable"])):
                with self.subTest(payload=payload, method=method):
                    stored.write_bytes(payload)
                    with self.assertRaises(ValueError):
                        getattr(local, method)(*args)
                    self.assertEqual(stored.read_bytes(), payload)
        self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def test_configuration_is_required_only_when_local_is_accessed(self):
        for directory, site_key in ((None, "site"), ("relative", "site"),
                                    (str(self.directory), None),
                                    (str(self.directory), "  ")):
            with self.subTest(directory=directory, site_key=site_key):
                with patch.dict(os.environ, {}, clear=True):
                    if directory is not None:
                        os.environ["XIUGOU_LOCAL_DIR"] = directory
                    if site_key is not None:
                        os.environ["XIUGOU_SCRIPT_SITE_KEY"] = site_key
                    owner = Spider()
                    with self.assertRaises(RuntimeError):
                        owner.local.get("missing")
        self.assertFalse(self.directory.exists())

    def test_storage_ignores_old_cache_and_retains_exact_site_identity(self):
        cache = self.root / "cache"
        with patch.dict(os.environ, {"XIUGOU_CACHE_DIR": str(cache),
                                     "XIUGOU_SCRIPT_ID": "old-script"}):
            owner = Spider()
            owner.setCache("preferences", "legacy-value")
            self.assertIsNone(owner.local.get("preferences"))
            owner.local.set("preferences", "local-value")
            owner.setCache("preferences", "legacy-update")
            self.assertEqual(owner.getCache("preferences"), "legacy-update")
            self.assertEqual(owner.local.get("preferences"), "local-value")
        self.assertTrue(cache.is_dir())
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_SITE_KEY": "synthetic-ysp "}):
            other = Spider().local
            self.assertIsNone(other.get("preferences"))
            other.set("preferences", "other-site")
        self.assertEqual(owner.local.get("preferences"), "local-value")
        self.assertEqual(other.get("preferences"), "other-site")

    def test_same_site_instances_observe_updates_and_delete_without_lost_keys(self):
        first = Spider().local
        alias = self.directory / ".." / self.directory.name
        with patch.dict(os.environ, {"XIUGOU_LOCAL_DIR": str(alias)}):
            second = Spider().local
        self.assertIsNone(first.get("a"))
        self.assertIsNone(second.get("b"))
        first.set("a", {"revision": 1})
        second.set("b", 2)
        self.assertEqual(second.get("a"), {"revision": 1})
        self.assertEqual(first.get("b"), 2)
        self.assertIsNone(second.delete("a"))
        first.set("c", 3)
        self.assertIsNone(first.get("a"))
        self.assertEqual(second.get("c"), 3)
        self.assertEqual(json.loads(self.local_file().read_text(encoding="utf-8")),
                         {"b": 2, "c": 3})

    def test_parallel_same_site_instances_preserve_all_completed_writes(self):
        workers = 6
        barrier = threading.Barrier(workers)
        locals_ = [Spider().local for _ in range(workers)]

        def write(worker):
            local = locals_[worker]
            barrier.wait(timeout=5)
            for index in range(12):
                key = str(worker) + ":" + str(index)
                local.set(key, [worker, index])
                self.assertEqual(local.get(key), [worker, index])
                if index % 2 == 0:
                    local.delete(key)

        with ThreadPoolExecutor(max_workers=workers) as executor:
            list(executor.map(write, range(workers)))
        expected = {str(worker) + ":" + str(index): [worker, index]
                    for worker in range(workers) for index in range(12) if index % 2}
        self.assertEqual(json.loads(self.local_file().read_text(encoding="utf-8")), expected)
        self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def test_write_faults_propagate_and_preserve_disk_and_visible_state(self):
        local = Spider().local
        local.set("synthetic-key-canary", "last-complete")
        stored = self.local_file()
        before = stored.read_bytes()
        for operation in ("create", "fsync", "replace"):
            for method, args in (("set", ["synthetic-key-canary", "synthetic-value-canary"]),
                                 ("delete", ["synthetic-key-canary"])):
                with self.subTest(operation=operation, method=method):
                    fault = PermissionError("synthetic-storage-failure")
                    target = ("base.local.tempfile.NamedTemporaryFile" if operation == "create"
                              else "base.local.os." + operation)
                    output = io.StringIO()
                    with redirect_stdout(output), redirect_stderr(output):
                        with patch(target, side_effect=fault):
                            with self.assertRaises(PermissionError) as raised:
                                getattr(local, method)(*args)
                    self.assertIs(raised.exception, fault)
                    self.assertEqual(output.getvalue(), "")
                    self.assertEqual(stored.read_bytes(), before)
                    self.assertEqual(local.get("synthetic-key-canary"), "last-complete")
                    self.assertEqual(Spider().local.get("synthetic-key-canary"), "last-complete")
                    self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def test_successful_replace_uses_synced_complete_same_directory_snapshot(self):
        local = Spider().local
        local.set("stable", "old")
        stored = self.local_file()
        original_fsync, original_replace = os.fsync, os.replace
        observations = []

        def synced(fd):
            original_fsync(fd)
            observations.append("synced")

        def replaced(source, target):
            self.assertEqual(observations, ["synced"])
            self.assertEqual(Path(source).parent.resolve(), stored.parent.resolve())
            self.assertEqual(json.loads(Path(source).read_text(encoding="utf-8")),
                             {"stable": "new"})
            self.assertEqual(json.loads(Path(target).read_text(encoding="utf-8")),
                             {"stable": "old"})
            original_replace(source, target)
            observations.append("replaced")

        with patch("base.local.os.fsync", side_effect=synced):
            with patch("base.local.os.replace", side_effect=replaced):
                self.assertIsNone(local.set("stable", "new"))
        self.assertEqual(observations, ["synced", "replaced"])
        self.assertEqual(local.get("stable"), "new")
        self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def test_size_limit_covers_entire_encoded_snapshot_and_rejected_reads(self):
        local = Spider().local
        limit = 1024 * 1024
        overhead = len(b'{"k":""}')
        local.set("k", "x" * (limit - overhead))
        stored = self.local_file()
        before = stored.read_bytes()
        self.assertEqual(len(before), limit)
        for key, value in (("k", "x" * (limit - overhead + 1)), ("extra", True),
                           ("k", "中文" * (limit // 4))):
            with self.subTest(key=key, length=len(value) if isinstance(value, str) else 0):
                with self.assertRaises(ValueError):
                    local.set(key, value)
                self.assertEqual(stored.read_bytes(), before)
                self.assertEqual(len(local.get("k")), limit - overhead)
        oversized = before + b" "
        stored.write_bytes(oversized)
        for method, args in (("get", ["k"]), ("set", ["k", "short"]), ("delete", ["k"])):
            with self.subTest(method=method):
                with self.assertRaises(ValueError):
                    getattr(local, method)(*args)
                self.assertEqual(stored.read_bytes(), oversized)
        self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def test_unreadable_snapshot_errors_do_not_become_missing_entries(self):
        local = Spider().local
        local.set("stable", "unchanged")
        stored = self.local_file()
        before = stored.read_bytes()
        fault = PermissionError("synthetic-read-failure")
        for method, args in (("get", ["stable"]), ("set", ["fresh", True]),
                             ("delete", ["stable"])):
            with self.subTest(method=method):
                with patch("base.local.open", side_effect=fault):
                    with self.assertRaises(PermissionError) as raised:
                        getattr(local, method)(*args)
                self.assertIs(raised.exception, fault)
                self.assertEqual(stored.read_bytes(), before)

    def test_missing_snapshot_reads_and_deletes_have_no_filesystem_side_effects(self):
        local = Spider().local
        self.assertIsNone(local.get("missing"))
        self.assertEqual(local.get("missing", "default"), "default")
        self.assertIsNone(local.delete("missing"))
        self.assertFalse(self.directory.exists())

    def test_cleanup_failure_remains_visible_with_original_write_failure(self):
        local = Spider().local
        local.set("stable", "old")
        stored = self.local_file()
        before = stored.read_bytes()
        write_fault = PermissionError("synthetic-write-failure")
        cleanup_fault = PermissionError("synthetic-cleanup-failure")
        with patch("base.local.os.replace", side_effect=write_fault):
            with patch("base.local.os.unlink", side_effect=cleanup_fault):
                with self.assertRaises(PermissionError) as raised:
                    local.set("stable", "new")
        self.assertIs(raised.exception, cleanup_fault)
        self.assertIs(raised.exception.__context__, write_fault)
        self.assertEqual(stored.read_bytes(), before)
        self.assertEqual(local.get("stable"), "old")

    def test_blocked_directory_raises_instead_of_accepting_memory_write(self):
        self.directory.write_text("directory blocker", encoding="utf-8")
        for method, args in (("get", ["tv-device:v1"]),
                             ("set", ["tv-device:v1", {"synthetic": True}]),
                             ("delete", ["tv-device:v1"])):
            with self.subTest(method=method):
                with self.assertRaises(OSError):
                    getattr(Spider().local, method)(*args)
        self.assertEqual(self.directory.read_text(encoding="utf-8"), "directory blocker")


if __name__ == "__main__":
    unittest.main()
