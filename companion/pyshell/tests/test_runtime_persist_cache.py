"""Public TTL persistence remains separate from legacy cache and Local."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet


class PersistentCacheTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        env = patch.dict(os.environ, {
            "XIUGOU_NET_CACHE_DIR": str(self.root / "public-cache"),
            "XIUGOU_SCRIPT_SITE_KEY": "直播 +&=",
            "XIUGOU_SCRIPT_API": "https://scripts.example/game_live.py?revision=1",
            "XIUGOU_CACHE_DIR": str(self.root / "legacy"),
            "XIUGOU_LOCAL_DIR": str(self.root / "local"),
        })
        env.start()
        self.addCleanup(env.stop)
        self.options = {"ttl": 86400000, "persist": True}

    def net(self):
        net = RuntimeNet()
        self.addCleanup(net.close)
        return net

    def test_public_catalog_survives_runtime_and_process_restart(self):
        source = {"groups": ["体育", "游戏"]}
        net = self.net()
        snapshot = net.cached("groups:yy", self.options, lambda: source)
        source["groups"].append("producer mutation")
        snapshot["groups"].append("caller mutation")
        net.close()
        self.assertEqual(self.net().cached("groups:yy", self.options, self.fail),
                         {"groups": ["体育", "游戏"]})
        program = "\n".join([
            "import json,sys", "sys.path.insert(0, sys.argv[1])", "from base.net import RuntimeNet",
            "def fail(): raise AssertionError('loader should not run')",
            "net=RuntimeNet()", "value=net.cached('groups:yy', {'ttl':86400000,'persist':True}, fail)",
            "print(json.dumps(value,ensure_ascii=True))", "net.close()",
        ])
        result = subprocess.run([sys.executable, "-B", "-c", program, str(SHELL)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"groups": ["体育", "游戏"]})
        self.assertFalse((self.root / "legacy").exists())
        self.assertFalse((self.root / "local").exists())

    def test_site_and_original_script_identity_are_isolated_and_captured(self):
        first = self.net()
        self.assertEqual(first.cached("catalog", self.options, lambda: "first"), "first")
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_SITE_KEY": "other"}):
            self.assertEqual(self.net().cached("catalog", self.options, lambda: "site"), "site")
            self.assertEqual(first.cached("catalog", self.options, self.fail), "first")
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_API": "https://scripts.example/other.py"}):
            self.assertEqual(self.net().cached("catalog", self.options, lambda: "script"), "script")
        self.assertEqual(self.net().cached("catalog", self.options, self.fail), "first")
        paths = list((self.root / "public-cache").glob("*.json"))
        self.assertEqual(len(paths), 3)
        self.assertTrue(all(len(path.stem) == 64 for path in paths))

    def test_ttl_starts_after_loader_and_failed_expired_refresh_is_not_cached(self):
        wall, monotonic = [1000.0], [10.0]
        options = {"ttl": 1000, "persist": True}

        def load():
            wall[0] += 2
            monotonic[0] += 2
            return {"revision": 1}

        with patch("time.time", lambda: wall[0]), patch("time.monotonic", lambda: monotonic[0]):
            net = self.net()
            self.assertEqual(net.cached("catalog", options, load), {"revision": 1})
            net.close()
            wall[0], monotonic[0] = 1002.999, 12.999
            self.assertEqual(self.net().cached("catalog", options, self.fail), {"revision": 1})
            wall[0], monotonic[0] = 1003.0, 13.0
            with self.assertRaisesRegex(LookupError, "offline"):
                self.net().cached("catalog", options, lambda: (_ for _ in ()).throw(LookupError("offline")))
            self.assertEqual(self.net().cached("catalog", options, lambda: {"revision": 2}), {"revision": 2})

    def test_clear_and_zero_ttl_remove_only_owned_namespace_without_touching_local(self):
        local = self.root / "local"
        local.mkdir()
        sentinel = local / "identity.json"
        sentinel.write_text('{"device":"preserved"}', encoding="utf-8")
        net = self.net()
        for key in ("a", "b"):
            net.cached(key, self.options, lambda key=key: key)
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_SITE_KEY": "other"}):
            self.net().cached("a", self.options, lambda: "other")
        net.clearCache("a")
        fresh = self.net()
        self.assertEqual(fresh.cached("a", self.options, lambda: "reload"), "reload")
        self.assertEqual(fresh.cached("b", self.options, self.fail), "b")
        fresh.cached("b", {"ttl": 0, "persist": True}, lambda: "temporary")
        self.assertEqual(self.net().cached("b", self.options, lambda: "new"), "new")
        fresh.clearCache()
        self.assertEqual(self.net().cached("a", self.options, lambda: "cleared"), "cleared")
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_SITE_KEY": "other"}):
            self.assertEqual(self.net().cached("a", self.options, self.fail), "other")
        self.assertEqual(sentinel.read_text(encoding="utf-8"), '{"device":"preserved"}')

    def test_memory_only_values_do_not_leak_into_persistent_catalog(self):
        net = self.net()
        net.cached("same", {"ttl": 10000}, lambda: "private signed URL")
        self.assertFalse((self.root / "public-cache").exists())
        self.assertEqual(net.cached("same", self.options, lambda: "public catalog"), "public catalog")
        self.assertEqual(self.net().cached("same", self.options, self.fail), "public catalog")
        for path in (self.root / "public-cache").glob("*.json"):
            self.assertNotIn("private signed URL", path.read_text(encoding="utf-8"))

    def test_corrupt_file_is_replaced_and_storage_failure_is_sanitized_and_retryable(self):
        self.net().cached("a", self.options, lambda: "old")
        path = next((self.root / "public-cache").glob("*.json"))
        for content in ("broken JSON", '{"version":9}', '{"version":1,"entries":{"x":{"expires":NaN}}}'):
            path.write_text(content, encoding="utf-8")
            self.assertEqual(self.net().cached("a", self.options, lambda: "recovered"), "recovered")
        before = path.read_bytes()
        net = self.net()
        with patch("base.ttl_cache.os.replace", side_effect=PermissionError("secret path token")):
            with self.assertRaises(OSError) as failure:
                net.cached("b", self.options, lambda: "new")
        self.assertNotIn("secret", str(failure.exception))
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(path.parent.glob(".ttl-*.tmp")), [])
        self.assertEqual(net.cached("b", self.options, lambda: "retried"), "retried")

    def test_unconfigured_persistence_fails_before_loader_and_close_never_persists_late_work(self):
        for env in ({"XIUGOU_NET_CACHE_DIR": ""}, {"XIUGOU_NET_CACHE_DIR": "relative"},
                    {"XIUGOU_SCRIPT_SITE_KEY": " "}, {"XIUGOU_SCRIPT_API": ""}):
            with self.subTest(env=env), patch.dict(os.environ, env):
                with self.assertRaisesRegex(RuntimeError, "not configured"):
                    self.net().cached("a", self.options, self.fail)
        net = self.net()
        with self.assertRaisesRegex(RuntimeError, "closed"):
            net.cached("late", self.options, lambda: net.close() or "late")
        self.assertEqual(self.net().cached("late", self.options, lambda: "fresh"), "fresh")

    def test_key_byte_and_namespace_limits_evict_only_public_cache_records(self):
        from base import ttl_cache
        root = self.root / "public-cache"
        root.mkdir()
        sentinel = root / "unrelated.txt"
        sentinel.write_text("keep", encoding="utf-8")
        with patch.object(ttl_cache, "MAX_KEYS", 2), patch.object(ttl_cache, "MAX_NAMESPACE_BYTES", 500), \
                patch.object(ttl_cache, "MAX_ROOT_BYTES", 900), patch.object(ttl_cache, "MAX_NAMESPACES", 2):
            net = self.net()
            for index in range(4):
                net.cached(str(index), self.options, lambda: "x" * 100)
            document = json.loads(next(root.glob("*.json")).read_bytes())
            self.assertEqual(list(document["entries"]), ["2", "3"])
            for index in range(4):
                with patch.dict(os.environ, {"XIUGOU_SCRIPT_SITE_KEY": str(index)}):
                    self.net().cached("catalog", self.options, lambda: "x" * 250)
            paths = list(root.glob("*.json"))
            self.assertLessEqual(len(paths), 2)
            self.assertLessEqual(sum(path.stat().st_size for path in paths), 900)
            self.assertTrue(all(path.stat().st_size <= 500 for path in paths))
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_disk_write_time_does_not_extend_the_in_memory_ttl(self):
        wall, monotonic = [1000.0], [10.0]
        replace = os.replace

        def delayed_replace(source, target):
            wall[0] += 0.75
            monotonic[0] += 0.75
            return replace(source, target)

        options = {"ttl": 1000, "persist": True}
        with patch("time.time", lambda: wall[0]), patch("time.monotonic", lambda: monotonic[0]):
            net = self.net()
            with patch("base.ttl_cache.os.replace", delayed_replace):
                self.assertEqual(net.cached("a", options, lambda: "old"), "old")
            wall[0], monotonic[0] = 1001.0, 11.0
            self.assertEqual(net.cached("a", options, lambda: "fresh"), "fresh")

    def test_two_process_writers_merge_without_losing_other_keys(self):
        program = "\n".join([
            "import sys", "sys.path.insert(0,sys.argv[1])", "from base.net import RuntimeNet",
            "net=RuntimeNet()",
            "for i in range(12): net.cached(sys.argv[2]+str(i), {'ttl':60000,'persist':True}, lambda i=i:i)",
            "net.close()",
        ])
        processes = [subprocess.Popen([sys.executable, "-B", "-c", program, str(SHELL), prefix],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for prefix in ("first", "second")]
        try:
            for process in processes:
                _, error = process.communicate(timeout=8)
                self.assertEqual(process.returncode, 0, error)
            net = self.net()
            for prefix in ("first", "second"):
                for index in range(12):
                    self.assertEqual(net.cached(prefix + str(index), self.options, self.fail), index)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=2)


if __name__ == "__main__":
    unittest.main()
