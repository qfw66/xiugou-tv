"""Run with: python -B -m unittest discover -s companion/pyshell/tests -v."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


SHELL = Path(__file__).resolve().parents[1]
RUNNER = SHELL / "runner.py"
SCRIPT = """
from base.spider import Spider as BaseSpider

class Spider(BaseSpider):
    def read(self, key):
        return self.getCache(key)

    def write(self, key, value):
        self.setCache(key, value)
        return self.getCache(key)
"""


class CachePersistenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xiugou-py-cache-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.cache = self.home / ".xiugou_tv_companion" / "py-cache"
        self.script = self.root / "scripts" / "source.py"
        self.script.parent.mkdir()
        self.script.write_text(textwrap.dedent(SCRIPT), encoding="utf-8")
        self.env = dict(os.environ)
        self.env.update({
            "HOME": str(self.home),
            "USERPROFILE": str(self.home),
            "PYTHONIOENCODING": "utf-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "XIUGOU_CACHE_DIR": str(self.cache),
        })
        self.env.pop("XIUGOU_SCRIPT_ID", None)

    def run_script(self, calls, script=None, identity=None, hash_seed="random"):
        script = script or self.script
        load = {"id": 1, "action": "load", "api": str(script)}
        if identity is not None:
            load["cacheId"] = identity
        requests = [load]
        for method, args in calls:
            requests.append({"id": len(requests) + 1, "action": "call",
                             "method": method, "args": args})
        requests.append({"id": len(requests) + 1, "action": "exit"})
        env = dict(self.env, PYTHONHASHSEED=hash_seed)
        result = subprocess.run(
            [sys.executable, "-B", "-X", "utf8", str(RUNNER)],
            input="".join(json.dumps(item) + "\n" for item in requests),
            encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=str(self.root), env=env, timeout=20, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(replies[0]["type"], "ready")
        responses = [reply for reply in replies if "id" in reply]
        self.assertEqual(len(responses), len(requests), result.stdout)
        for request, response in zip(requests, responses):
            self.assertEqual(response["id"], request["id"])
            self.assertEqual(response["type"], "result", response)
        return [response.get("value") for response in responses[1:-1]], result.stderr

    def test_cache_survives_fresh_process_with_different_hash_seed(self):
        value = {"token": "synthetic-only", "items": [0, False, None, "中文"]}
        values, _ = self.run_script([("write", ["account", value])], hash_seed="1")
        self.assertEqual(values, [value])
        values, _ = self.run_script([("read", ["account"])], hash_seed="2")
        self.assertEqual(values, [value])
        files = list(self.cache.glob("*.json"))
        self.assertEqual(len(files), 1)
        self.assertEqual(list(self.script.parent.glob("*.json")), [])

    def cache_file(self):
        files = list(self.cache.glob("*.json"))
        self.assertEqual(len(files), 1)
        return files[0]

    def test_same_filename_and_contents_do_not_share_cache(self):
        other = self.root / "other" / "source.py"
        other.parent.mkdir()
        other.write_text(textwrap.dedent(SCRIPT), encoding="utf-8")
        self.run_script([("write", ["account", "source-a"])])
        values, _ = self.run_script([("read", ["account"]),
                                     ("write", ["account", "source-b"])], script=other)
        self.assertEqual(values, [None, "source-b"])
        values, _ = self.run_script([("read", ["account"])])
        self.assertEqual(values, ["source-a"])
        self.assertEqual(len(list(self.cache.glob("*.json"))), 2)

    def test_canonical_path_alias_and_content_updates_keep_identity(self):
        self.run_script([("write", ["revision", 1])])
        self.script.write_text(textwrap.dedent(SCRIPT) + "\nREVISION = 2\n", encoding="utf-8")
        alias = self.script.parent / ".." / "scripts" / self.script.name
        values, _ = self.run_script([("read", ["revision"])], script=alias)
        self.assertEqual(values, [1])
        self.assertEqual(len(list(self.cache.glob("*.json"))), 1)

    def test_host_identity_is_stable_and_isolated(self):
        self.run_script([("write", ["account", "one"])], identity="synthetic:source-1")
        values, _ = self.run_script([("read", ["account"])], identity="synthetic:source-2")
        self.assertEqual(values, [None])
        copy = self.root / "relocated.py"
        copy.write_text(textwrap.dedent(SCRIPT), encoding="utf-8")
        values, _ = self.run_script([("read", ["account"])], script=copy,
                                    identity="synthetic:source-1")
        self.assertEqual(values, ["one"])

    def test_constructor_without_super_and_init_can_read_cache(self):
        self.run_script([("write", ["account", "stored-before-start"])])
        self.script.write_text(textwrap.dedent('''
            from base.spider import Spider as BaseSpider
            class Spider(BaseSpider):
                def __init__(self):
                    self.in_constructor = self.getCache("account")
                def init(self, extend=""):
                    self.in_init = self.getCache("account")
                    self.setCache("during-init", "saved")
                def observed(self):
                    return [self.in_constructor, self.in_init]
        '''), encoding="utf-8")
        values, _ = self.run_script([("observed", [])])
        self.assertEqual(values, [["stored-before-start", "stored-before-start"]])
        self.script.write_text(textwrap.dedent(SCRIPT), encoding="utf-8")
        values, _ = self.run_script([("read", ["during-init"])])
        self.assertEqual(values, ["saved"])

    def test_bad_json_wrong_shape_and_invalid_utf8_recover(self):
        self.run_script([("write", ["account", "old"])])
        cache_file = self.cache_file()
        for data in (b'{"account":', b'["wrong-shape"]', b'null', b'\xff\xfe'):
            with self.subTest(data=data):
                cache_file.write_bytes(data)
                values, stderr = self.run_script([("read", ["account"]),
                                                   ("write", ["fresh", "usable"])])
                self.assertEqual(values, [None, "usable"])
                self.assertIn("[spider-cache] read failed", stderr)
                values, _ = self.run_script([("read", ["fresh"])])
                self.assertEqual(values, ["usable"])

    def test_unserializable_values_stay_in_memory_without_poisoning_other_keys(self):
        self.script.write_text(textwrap.dedent('''
            from base.spider import Spider as BaseSpider
            class Spider(BaseSpider):
                def unsupported(self):
                    marker = object()
                    self.setCache("account", "stale-synthetic-value")
                    self.setCache("account", marker)
                    circular = []
                    circular.append(circular)
                    self.setCache("circular", circular)
                    self.setCache("good", {"unicode": "中文", "enabled": False})
                    return [self.getCache("account") is marker,
                            self.getCache("circular") is circular]
                def read(self, key):
                    return self.getCache(key)
        '''), encoding="utf-8")
        values, stderr = self.run_script([("unsupported", [])])
        self.assertEqual(values, [[True, True]])
        self.assertIn("entry is not JSON serializable", stderr)
        values, _ = self.run_script([("read", ["account"]), ("read", ["circular"]),
                                     ("read", ["good"])])
        self.assertEqual(values, [None, None, {"unicode": "中文", "enabled": False}])

    def test_non_string_keys_keep_memory_semantics_without_json_collisions(self):
        values, _ = self.run_script([("write", [1, "number"]),
                                     ("write", ["1", "string"]), ("read", [1])])
        self.assertEqual(values, ["number", "string", "number"])
        values, _ = self.run_script([("read", [1]), ("read", ["1"])])
        self.assertEqual(values, [None, "string"])

    def test_blocked_cache_directory_preserves_memory(self):
        self.cache.parent.mkdir(parents=True)
        self.cache.write_text("synthetic directory blocker", encoding="utf-8")
        values, stderr = self.run_script([("write", ["account", "memory-only"]),
                                          ("read", ["account"])])
        self.assertEqual(values, ["memory-only", "memory-only"])
        self.assertIn("[spider-cache] write failed", stderr)
        self.assertEqual(self.cache.read_text(encoding="utf-8"), "synthetic directory blocker")

    def test_write_failures_preserve_last_complete_file(self):
        self.run_script([("write", ["account", "last-complete"])])
        cache_file = self.cache_file()
        before = cache_file.read_bytes()
        self.script.write_text(textwrap.dedent('''
            import os
            from base.spider import Spider as BaseSpider
            class Spider(BaseSpider):
                def fail_write(self, operation):
                    original = getattr(os, operation)
                    def denied(*args):
                        raise PermissionError("secret-error-canary")
                    setattr(os, operation, denied)
                    try:
                        self.setCache("account", "secret-value-canary")
                        return self.getCache("account")
                    finally:
                        setattr(os, operation, original)
        '''), encoding="utf-8")
        for operation in ("replace", "fsync"):
            with self.subTest(operation=operation):
                values, stderr = self.run_script([("fail_write", [operation])])
                self.assertEqual(values, ["secret-value-canary"])
                self.assertEqual(cache_file.read_bytes(), before)
                self.assertEqual(list(self.cache.glob("*.tmp")), [])
                self.assertIn("[spider-cache] write failed", stderr)
                self.assertNotIn("secret-", stderr)
                self.assertNotIn(str(self.cache), stderr)
        self.script.write_text(textwrap.dedent(SCRIPT), encoding="utf-8")
        values, _ = self.run_script([("read", ["account"])])
        self.assertEqual(values, ["last-complete"])

    def test_successful_write_replaces_a_complete_same_directory_temporary(self):
        self.run_script([("write", ["account", "old"])])
        self.script.write_text(textwrap.dedent('''
            import json
            import os
            from base.spider import Spider as BaseSpider
            class Spider(BaseSpider):
                def observe_replace(self):
                    original = os.replace
                    observed = []
                    def inspect(source, target):
                        with open(source, encoding="utf-8") as stream:
                            fresh = json.load(stream)
                        with open(target, encoding="utf-8") as stream:
                            old = json.load(stream)
                        observed.append([os.path.dirname(source) == os.path.dirname(target),
                                         old["account"], fresh["account"]])
                        return original(source, target)
                    os.replace = inspect
                    try:
                        self.setCache("account", "new")
                    finally:
                        os.replace = original
                    return observed
        '''), encoding="utf-8")
        values, _ = self.run_script([("observe_replace", [])])
        self.assertEqual(values, [[[True, "old", "new"]]])
        self.assertEqual(list(self.cache.glob("*.tmp")), [])
        self.assertEqual(json.loads(self.cache_file().read_text(encoding="utf-8")), {"account": "new"})

    def test_size_limit_preserves_memory_and_last_complete_snapshot(self):
        self.script.write_text(textwrap.dedent('''
            from base.spider import Spider as BaseSpider
            class Spider(BaseSpider):
                def write_sized(self, length):
                    self.setCache("account", "x" * length)
                    return len(self.getCache("account"))
                def read_length(self):
                    value = self.getCache("account")
                    return len(value) if value is not None else None
        '''), encoding="utf-8")
        limit = 1024 * 1024
        overhead = len(b'{"account":""}')
        values, _ = self.run_script([("write_sized", [limit - overhead])])
        self.assertEqual(values, [limit - overhead])
        cache_file = self.cache_file()
        before = cache_file.read_bytes()
        self.assertEqual(len(before), limit)
        values, stderr = self.run_script([
            ("write_sized", [limit - overhead + 1]), ("read_length", [])])
        self.assertEqual(values, [limit - overhead + 1] * 2)
        self.assertIn("size limit exceeded", stderr)
        self.assertEqual(cache_file.read_bytes(), before)
        self.assertEqual(list(self.cache.glob("*.tmp")), [])
        values, _ = self.run_script([("read_length", [])])
        self.assertEqual(values, [limit - overhead])
        self.run_script([("write_sized", [10])])
        self.assertEqual(len(cache_file.read_bytes()), overhead + 10)

    def test_oversized_existing_cache_is_ignored_and_can_recover(self):
        self.run_script([("write", ["account", "old"])])
        cache_file = self.cache_file()
        cache_file.write_text(
            '{"account":"' + 'x' * (1024 * 1024) + '"}', encoding="utf-8")
        values, stderr = self.run_script([
            ("read", ["account"]), ("write", ["fresh", "usable"])])
        self.assertIsNone(values[0])
        self.assertEqual(values[1], "usable")
        self.assertIn("size limit exceeded", stderr)
        self.assertEqual(json.loads(cache_file.read_text(encoding="utf-8")),
                         {"fresh": "usable"})

    def test_missing_or_relative_host_directory_uses_only_memory(self):
        for directory in (None, "relative-cache"):
            with self.subTest(directory=directory):
                if directory is None:
                    self.env.pop("XIUGOU_CACHE_DIR", None)
                else:
                    self.env["XIUGOU_CACHE_DIR"] = directory
                values, _ = self.run_script([("write", ["account", "memory"]),
                                             ("read", ["account"])])
                self.assertEqual(values, ["memory", "memory"])
                values, _ = self.run_script([("read", ["account"])])
                self.assertEqual(values, [None])
                self.assertFalse(self.cache.exists())
                self.assertFalse((self.root / "relative-cache").exists())


if __name__ == "__main__":
    unittest.main()
