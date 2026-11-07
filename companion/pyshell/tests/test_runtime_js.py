"""Restricted JavaScript contracts; set the host Java env to run the real helper."""

import ast
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import parse_qsl


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.js import RuntimeJS  # noqa: E402


class RuntimeJSValidationTest(unittest.TestCase):
    def test_invalid_requests_do_not_spawn(self):
        cycle = []
        cycle.append(cycle)
        cases = [
            (None, None), ("1", []), ("1", {"extra": 1}),
            *[("1", {"timeout": value}) for value in [True, 0, -1, 1.5, "1", None, 2147483648]],
            ("1", {"globals": []}), ("1", {"globals": {"md5X": "replacement"}}),
            ("1", {"globals": {"__proto__": {}}}), ("1", {"globals": {"constructor": {}}}),
            ("1", {"globals": {1: "value"}}), ("1", {"globals": {"x": object()}}),
            ("1", {"globals": {"x": float("nan")}}), ("1", {"globals": {"x": float("inf")}}),
            ("1", {"globals": {"x": 9007199254740992}}), ("1", {"globals": {"x": cycle}}),
            ("x" * (1024 * 1024 + 1), None),
            ("1", {"globals": {"x": "中文" * 100000}}),
        ]
        with patch("base.js.subprocess.Popen") as popen:
            for source, options in cases:
                with self.subTest(source=str(source)[:20], options_type=type(options).__name__):
                    with self.assertRaises((ValueError, TypeError)):
                        RuntimeJS().eval(source, options)
            popen.assert_not_called()

    def test_missing_or_relative_host_configuration_fails_safely(self):
        for values in [{}, {"XIUGOU_JAVA_BIN": "java", "XIUGOU_JAVA_CLASSPATH": "."}]:
            with patch.dict(os.environ, values, clear=True), patch("base.js.subprocess.Popen") as popen:
                with self.assertRaisesRegex(RuntimeError, "absolute Java"):
                    RuntimeJS().eval("1")
                popen.assert_not_called()


class RuntimeJSTransportTest(unittest.TestCase):
    def probe(self, mode, source="1", timeout=1000):
        original = subprocess.Popen
        processes = []
        commands = []

        def start(command, **kwargs):
            commands.append((command, kwargs))
            child = original([sys.executable, str(Path(__file__).resolve()), "--probe", mode], **kwargs)
            processes.append(child)
            return child

        env = {"XIUGOU_JAVA_BIN": sys.executable,
               "XIUGOU_JAVA_CLASSPATH": str(Path(__file__).resolve().parent),
               "JAVA_TOOL_OPTIONS": "TEST_SECRET", "JDK_JAVA_OPTIONS": "TEST_SECRET", "_JAVA_OPTIONS": "TEST_SECRET"}
        self.addCleanup(self.assert_processes_closed, processes)
        with patch.dict(os.environ, env), patch("base.js.subprocess.Popen", side_effect=start):
            result = RuntimeJS().eval(source, {"timeout": timeout})
        self.assertFalse(commands[0][1]["shell"])
        self.assertNotIn(source, commands[0][0])
        self.assertTrue(all(key not in commands[0][1]["env"] for key in
                            ["JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"]))
        return result

    def assert_processes_closed(self, processes):
        self.assertTrue(processes)
        self.assertTrue(all(child.poll() is not None for child in processes))
        self.assertTrue(all(child.stdin.closed and child.stdout.closed and child.stderr.closed for child in processes))
        self.assertFalse(any(thread.is_alive() and thread.name.startswith("runtime-js-")
                             for thread in threading.enumerate()))

    def test_large_stderr_is_discarded_and_never_logged(self):
        capture = io.StringIO()
        with contextlib.redirect_stderr(capture), contextlib.redirect_stdout(capture):
            self.assertEqual(self.probe("stderr", timeout=3000), 7)
        self.assertNotIn("TEST_SECRET", capture.getvalue())

    def test_stdout_limit_kills_and_reaps_helper(self):
        with self.assertRaisesRegex(RuntimeError, "output exceeds"):
            self.probe("stdout", timeout=3000)

    def test_deadline_includes_blocked_stdin_and_startup(self):
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.probe("blocked", source=" " * 200000, timeout=200)
        self.assertLess(time.monotonic() - started, 3)

    def test_invalid_response_and_failure_never_echo_raw_output(self):
        for mode in ["invalid", "failure"]:
            with self.subTest(mode=mode), self.assertRaises(RuntimeError) as raised:
                self.probe(mode)
            self.assertNotIn("TEST_SECRET", str(raised.exception))


class RuntimeJSTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.environ.get("XIUGOU_JAVA_BIN") or not os.environ.get("XIUGOU_JAVA_CLASSPATH"):
            raise unittest.SkipTest("set XIUGOU_JAVA_BIN and XIUGOU_JAVA_CLASSPATH to the real helper")

    def test_md5_vectors_and_js_string_coercion(self):
        values = ["", "abc", "message digest", "中文😀", "a\x00b"]
        result = RuntimeJS().eval("values.map(value => md5X(value))", {"globals": {"values": values}})
        self.assertEqual(result, [hashlib.md5(value.encode("utf-8")).hexdigest() for value in values])
        self.assertEqual(RuntimeJS().eval("[md5X(123), md5X(null), md5X(), md5X([1,2])]"),
                         [hashlib.md5(value.encode()).hexdigest() for value in ["123", "null", "undefined", "1,2"]])

    def test_json_globals_remain_data_and_unicode_round_trips(self):
        payload = "'\"; throw new Error('injection'); // ${secret} `x` \n中文😀"
        values = {"payload": payload, "nested": {"__proto__": {"polluted": True}, "constructor": {"prototype": 7}}}
        self.assertEqual(RuntimeJS().eval("({payload,nested,items:[true,null,4.5],clean:typeof ({}).polluted})",
                                         {"globals": values}),
                         {**values, "items": [True, None, 4.5], "clean": "undefined"})

    def test_context_and_builtin_isolation(self):
        js = RuntimeJS()
        self.assertEqual(js.eval("var saved=rid; Object.prototype.polluted=1; md5X=()=> 'bad'; md5X('abc')",
                                 {"globals": {"rid": "room"}}), "900150983cd24fb0d6963f7d28e17f72")
        self.assertEqual(js.eval("[typeof rid,typeof saved,typeof ({}).polluted]"), ["undefined"] * 3)

    def test_safe_script_errors_and_unsupported_results(self):
        for source in ["throw new Error('TEST_SECRET')", "Promise.resolve('TEST_SECRET')", "undefined"]:
            with self.subTest(source=source), self.assertRaises(RuntimeError) as raised:
                RuntimeJS().eval(source)
            self.assertNotIn("TEST_SECRET", str(raised.exception))

    def test_real_loop_and_startup_timeout_kill_and_reap(self):
        original = subprocess.Popen
        processes = []

        def start(*args, **kwargs):
            child = original(*args, **kwargs)
            processes.append(child)
            return child

        with patch("base.js.subprocess.Popen", side_effect=start):
            for timeout in [1, 2000]:
                started = time.monotonic()
                with self.subTest(timeout=timeout), self.assertRaises(TimeoutError):
                    RuntimeJS().eval("while(true){}", {"timeout": timeout})
                self.assertLess(time.monotonic() - started, timeout / 1000 + 2)
        self.assertTrue(processes)
        self.assertTrue(all(child.poll() is not None for child in processes))
        self.assertFalse(any(thread.is_alive() and thread.name.startswith("runtime-js-")
                             for thread in threading.enumerate()))
        self.assertEqual(RuntimeJS().eval("6*7"), 42)

    def test_single_request_main_uses_only_json_stdout(self):
        command = [os.environ["XIUGOU_JAVA_BIN"], "-cp", os.environ["XIUGOU_JAVA_CLASSPATH"],
                   "com.fongmi.companion.ScriptJsEvaluator"]
        result = subprocess.run(command, input=json.dumps({"source": "print('TEST_SECRET'); console.log('TEST_SECRET'); '中文😀'"}).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=True)
        self.assertEqual(json.loads(result.stdout.decode("utf-8")), {"ok": True, "result": "中文😀"})
        self.assertNotIn(b"TEST_SECRET", result.stderr)
        self.assertLess(len(result.stderr), 4096)

    def test_original_douyu_function_with_local_signing_fixture(self):
        original = Path(os.environ.get("XIUGOU_GAME_LIVE_SOURCE", "E:/code/tvbox_1102/live-python/vod/game_live.py"))
        if not original.is_file():
            self.skipTest("original game_live.py not available; set XIUGOU_GAME_LIVE_SOURCE")
        tree = ast.parse(original.read_text(encoding="utf-8"))
        owner = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Spider")
        method = next(node for node in owner.body if isinstance(node, ast.FunctionDef) and node.name == "_douyu_stream")
        namespace = {"DOUYU": "https://www.douyu.com", "time": SimpleNamespace(time=lambda: 1700000000), "parse_qsl": parse_qsl}
        exec(compile(ast.Module(body=[method], type_ignores=[]), str(original), "exec"), namespace)
        # This is deterministic fixture input to the original function's exact
        # expression, not a captured public signature or upstream verification.
        fixture = """
            function ub98484234(rid, did, tt) {
                var v = 'fixture-v1';
                var sign = CryptoJS.MD5(rid + did + tt + v).toString();
                return 'v=' + v + '&did=' + encodeURIComponent(did) + '&tt=' + tt + '&sign=' + sign;
            }
        """
        calls, caches, expressions = [], [], []
        runtime = RuntimeJS()

        def cached(key, options, producer):
            caches.append((key, options))
            return producer()

        def douyu(url, options):
            calls.append((url, options))
            if url.endswith("homeH5Enc"):
                return {"room123": fixture}
            return {"rtmp_url": "https://fixture.invalid", "rtmp_live": "stream.m3u8"}

        def evaluate(source, options):
            expressions.append((source, options))
            return runtime.eval(source, options)

        spider = SimpleNamespace(net=SimpleNamespace(cached=cached), js=SimpleNamespace(eval=evaluate),
                                 device_id="fixture-device", _douyu=douyu)
        result = namespace["_douyu_stream"](spider, "123")
        self.assertEqual(result["rtmp_live"], "stream.m3u8")
        self.assertEqual(expressions, [("var CryptoJS = {MD5: md5X};\n" + fixture + "\nub98484234(rid, did, tt);",
                                        {"globals": {"rid": "123", "did": "fixture-device", "tt": "1700000000"}})])
        expected = hashlib.md5(b"123fixture-device1700000000fixture-v1").hexdigest()
        self.assertEqual(calls[1][1], {"method": "POST", "postType": "form", "data": {
            "v": "fixture-v1", "did": "fixture-device", "tt": "1700000000", "sign": expected, "cdn": "", "rate": 0}})
        self.assertEqual([entry[0] for entry in caches], ["stream:douyu:123", "sign:douyu:123"])


def _transport_probe(mode):
    if mode == "blocked":
        time.sleep(60)
        return
    sys.stdin.buffer.read()
    if mode == "stderr":
        sys.stderr.buffer.write(b"TEST_SECRET" * 200000)
        sys.stderr.buffer.flush()
        sys.stdout.write('{"ok":true,"result":7}')
    elif mode == "stdout":
        sys.stdout.buffer.write(b"x" * (2 * 1024 * 1024))
        sys.stdout.buffer.flush()
        time.sleep(60)
    elif mode == "invalid":
        sys.stdout.write("TEST_SECRET")
    elif mode == "failure":
        sys.stderr.write("TEST_SECRET")
        raise SystemExit(1)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--probe":
        _transport_probe(sys.argv[2])
    else:
        unittest.main()
