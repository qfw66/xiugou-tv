"""Declared helper loading using unchanged author files and localhost fixtures."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import os
from pathlib import Path
import struct
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.spider import Spider  # noqa: E402


AUTHOR = Path(os.environ.get("XIUGOU_AUTHOR_GAME") or
              r"E:\code\tvbox_1102\live-python\vod\game_live.py")
HELPERS = ("game_live_protocol", "game_live_stream", "game_live_yy")


class _DeclaredSpider(Spider):
    def __init__(self, declarations):
        self.declarations = declarations

    def getDependence(self):
        return self.declarations

    def _request(self, *args, **kwargs):
        raise AssertionError("module downloads must not dispatch to source _request")


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        status, headers, payload = self.server.responses.get(urlsplit(self.path).path, (404, {}, b"missing"))
        if self.path == "/stall.py":
            self.server.started.set()
            self.server.release.wait(2)
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        if "Content-Length" not in headers and self.path != "/drip.py":
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            if self.path == "/drip.py":
                self.server.started.set()
                for _ in range(100):
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    if self.server.release.wait(0.03):
                        break
            else:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


class ModuleFixtureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever,
                                      kwargs={"poll_interval": 0.02}, daemon=True)
        cls.thread.start()
        cls.origin = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="xiugou-modules-")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.server.responses = {}
        self.server.requests = []
        self.server.started = threading.Event()
        self.server.release = threading.Event()
        self.addCleanup(self.server.release.set)
        environment = patch.dict(os.environ, {
            "XIUGOU_SCRIPT_API": str(self.directory / "entry.py"),
            "XIUGOU_SCRIPT_BASE": "", "XIUGOU_SCRIPT_SITE_KEY": "site-one",
            "XIUGOU_CACHE_DIR": "", "NO_PROXY": "127.0.0.1,localhost",
        })
        environment.start()
        os.environ.pop("XIUGOU_SCRIPT_ENTRY", None)
        self.addCleanup(environment.stop)

    def _write(self, name, text):
        path = self.directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def _original(self):
        if not AUTHOR.is_file():
            self.skipTest("original game source missing; set XIUGOU_AUTHOR_GAME")
        spec = importlib.util.spec_from_file_location("author_game_modules_fixture", AUTHOR)
        author = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(author)
        return author

    def _assert_original_helpers(self, spider):
        spider.init("")
        self.assertEqual(tuple(spider.getDependence()), HELPERS)
        packet = spider.protocol.douyu_packet("type@=mrkl/")
        self.assertEqual(struct.unpack("<I", packet[:4])[0], len(packet) - 4)
        self.assertTrue(callable(spider.stream.flv_stream))
        normalizer = spider.yy_stream.Normalizer()
        self.assertEqual(normalizer.last, {})
        self.assertIs(spider.loadModule("game_live_protocol"), spider.protocol)
        self.assertIsInstance(spider.protocol, types.ModuleType)

    def test_unchanged_original_helpers_load_from_windows_path_and_file_uri(self):
        author = self._original()
        for api in (str(AUTHOR), AUTHOR.as_uri()):
            with self.subTest(api=api), patch.dict(os.environ, {"XIUGOU_SCRIPT_API": api}):
                self._assert_original_helpers(author.Spider())

    def test_original_http_helpers_keep_parent_origin_instead_of_cached_entry(self):
        author = self._original()
        for name in HELPERS:
            self.server.responses["/scripts/vod/" + name + ".py"] = (
                200, {}, AUTHOR.with_name(name + ".py").read_bytes())
        with patch.dict(os.environ, {
            "XIUGOU_SCRIPT_API": "./vod/game_live.py",
            "XIUGOU_SCRIPT_BASE": self.origin + "/scripts/",
        }):
            spider = author.Spider()
            self._assert_original_helpers(spider)
        self.assertEqual(self.server.requests, ["/scripts/vod/" + name + ".py" for name in HELPERS])
        self.assertEqual(spider.protocol.__file__, self.origin + "/scripts/vod/game_live_protocol.py")

    def test_relative_entry_resolves_from_local_and_file_base(self):
        self._write("vod/helper.py", "answer = 42\n")
        for base in (str(self.directory), self.directory.as_uri() + "/"):
            with self.subTest(base=base), patch.dict(os.environ, {
                "XIUGOU_SCRIPT_API": "./vod/entry.py", "XIUGOU_SCRIPT_BASE": base,
            }):
                self.assertEqual(_DeclaredSpider(["helper"]).loadModule("helper").answer, 42)

    def test_effective_absolute_entry_avoids_repeating_relative_local_parent(self):
        self._write("vod/helper.py", "answer = 42\n")
        original_api = "vod/entry.py"
        original_base = (self.directory / "vod").as_uri() + "/"
        with patch.dict(os.environ, {
            "XIUGOU_SCRIPT_API": original_api,
            "XIUGOU_SCRIPT_BASE": original_base,
            "XIUGOU_SCRIPT_ENTRY": (self.directory / "vod/entry.py").as_uri(),
        }):
            helper = _DeclaredSpider(["helper"]).loadModule("helper")
            self.assertEqual(helper.answer, 42)
            self.assertEqual(helper.__file__, (self.directory / "vod/helper.py").as_uri())
            self.assertEqual(os.environ["XIUGOU_SCRIPT_API"], original_api)
            self.assertEqual(os.environ["XIUGOU_SCRIPT_BASE"], original_base)

    def test_effective_http_entry_loads_original_helpers_from_normalized_origin(self):
        author = self._original()
        for original, effective in (
            (self.origin + "/ordinary/game_live.py", self.origin + "/ordinary/game_live.py"),
            (self.origin + "/https://github.com/owner/repo/blob/main/vod/game_live.py",
             self.origin + "/https://raw.githubusercontent.com/owner/repo/main/vod/game_live.py"),
        ):
            self.server.requests.clear()
            parent = effective.rsplit("/", 1)[0]
            expected = []
            for name in HELPERS:
                path = urlsplit(parent + "/" + name + ".py").path
                self.server.responses[path] = (200, {}, AUTHOR.with_name(name + ".py").read_bytes())
                expected.append(path)
            with self.subTest(api=original), patch.dict(os.environ, {
                "XIUGOU_SCRIPT_API": original,
                "XIUGOU_SCRIPT_BASE": original.rsplit("/", 1)[0] + "/",
                "XIUGOU_SCRIPT_ENTRY": effective,
            }):
                spider = author.Spider()
                self._assert_original_helpers(spider)
                self.assertEqual(spider.protocol.__file__, parent + "/game_live_protocol.py")
                self.assertEqual(os.environ["XIUGOU_SCRIPT_API"], original)
            self.assertEqual(self.server.requests, expected)

    def test_invalid_explicit_entry_never_falls_back_to_original_source(self):
        self._write("helper.py", "answer = 42\n")
        for entry in ("", "vod/entry.py", "//remote/entry.py", "file://remote/entry.py",
                      "https://user:secret@example.test/entry.py", "http://localhost/a.py#bad"):
            with self.subTest(entry=entry), patch.dict(os.environ, {"XIUGOU_SCRIPT_ENTRY": entry}), \
                    self.assertRaises(ValueError):
                _DeclaredSpider(["helper"]).loadModule("helper")
        self.assertEqual(self.server.requests, [])

    def test_declared_alias_paths_and_sibling_imports_stay_isolated(self):
        self._write("helpers/first.py", "from . import second\nanswer = second.answer + 1\n")
        self._write("second.py", "answer = 41\n")
        spider = _DeclaredSpider({"first": "./helpers/first.py", "second": "second.py"})
        loaded = spider.loadModule("first")
        self.assertEqual(loaded.answer, 42)
        self.assertIs(loaded.second, spider.loadModule("second"))
        self.assertNotIn("first", sys.modules)
        self.assertNotIn("second", sys.modules)
        alternate = _DeclaredSpider(["./helpers/first.py", "second.py"])
        self.assertEqual(alternate.loadModule("first.py").answer, 42)

    def test_site_entry_and_new_instance_do_not_share_module_state(self):
        self._write("helper.py", "values = []\n")
        first = _DeclaredSpider(["helper"])
        one = first.loadModule("helper")
        one.values.append("only-first")
        generations = [one]
        for site, entry in (("site-one", "entry.py"), ("site-two", "entry.py"), ("site-one", "other.py")):
            with patch.dict(os.environ, {
                "XIUGOU_SCRIPT_SITE_KEY": site,
                "XIUGOU_SCRIPT_API": str(self.directory / entry),
            }):
                helper = _DeclaredSpider(["helper"]).loadModule("helper")
                self.assertEqual(helper.values, [])
                generations.append(helper)
        self.assertEqual(len({helper.__name__ for helper in generations}), 4)
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_API": "", "XIUGOU_SCRIPT_SITE_KEY": "changed"}):
            self.assertIs(first.loadModule("helper"), one)
        self.assertEqual(one.values, ["only-first"])

    def test_declared_system_name_loads_source_and_never_falls_back_to_stdlib(self):
        self._write("json.py", "source_marker = 'declared'\n")
        spider = _DeclaredSpider(["json", "os"])
        self.assertEqual(spider.loadModule("json").source_marker, "declared")
        with self.assertRaisesRegex(ImportError, "source"):
            spider.loadModule("os")
        self.assertNotEqual(sys.modules["json"].__name__, spider.loadModule("json").__name__)

    def test_missing_unsafe_and_undeclared_names_fail_before_io(self):
        from base.modules import RuntimeModules
        spider = _DeclaredSpider(["helper"])
        for name in ("os", "pathlib", "../helper", "/helper", "helper/other", "http://127.0.0.1/x", "", None):
            with self.subTest(name=name), self.assertRaises((ValueError, TypeError, ImportError)):
                spider.loadModule(name)
        self.assertEqual(self.server.requests, [])
        for declarations in ("helper", ["../escape.py"], {"helper": "../escape.py"},
                             {"helper": "ftp://host/x.py"}, ["a", "a"],
                             {"helper": "he\nlper.py"}, {"helper": "./%2e%2e/escape.py"},
                             {"helper": "file://localhost//remote/share/helper.py"}):
            with self.subTest(declarations=declarations), patch.object(
                    RuntimeModules, "_read", side_effect=AssertionError("invalid declaration reached I/O")) as read:
                with self.assertRaises((ValueError, TypeError, ImportError)):
                    _DeclaredSpider(declarations).loadModule("helper")
                read.assert_not_called()

    def test_invalid_origin_has_no_cwd_or_system_import_fallback(self):
        for api, base, site in (("", "", "site"), ("entry.py", "", "site"),
                                ("ftp://host/entry.py", "", "site"),
                                ("http://user:secret@127.0.0.1/entry.py", "", "site"),
                                (str(self.directory / "entry.py"), "", "")):
            with self.subTest(api=api, base=base, site=site), patch.dict(os.environ, {
                "XIUGOU_SCRIPT_API": api, "XIUGOU_SCRIPT_BASE": base, "XIUGOU_SCRIPT_SITE_KEY": site,
            }), self.assertRaises((ValueError, RuntimeError)) as caught:
                _DeclaredSpider(["os"]).loadModule("os")
            self.assertNotIn("secret", str(caught.exception))

    def test_http_missing_source_and_syntax_fail_cleanly_without_caching_partial_module(self):
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_API": self.origin + "/entry.py"}):
            spider = _DeclaredSpider(["helper"])
            with self.assertRaisesRegex(ImportError, "source"):
                spider.loadModule("helper")
            self.server.responses["/helper.py"] = (200, {}, b"this is not Python !!!")
            with self.assertRaisesRegex(ImportError, "initialize"):
                spider.loadModule("helper")
            self.server.responses["/helper.py"] = (200, {}, b"answer = 42\n")
            self.assertEqual(spider.loadModule("helper").answer, 42)

    def test_truncated_http_source_is_rejected_even_when_prefix_compiles(self):
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_API": self.origin + "/entry.py"}):
            spider = _DeclaredSpider(["helper"])
            self.server.responses["/helper.py"] = (200, {"Content-Length": "100"}, b"answer = 42\n")
            with self.assertRaises(ImportError):
                spider.loadModule("helper")
            self.server.responses["/helper.py"] = (200, {}, b"answer = 43\n")
            self.assertEqual(spider.loadModule("helper").answer, 43)

    def test_http_root_relative_declared_helper_keeps_http_origin(self):
        self.server.responses["/shared/helper.py"] = (200, {}, b"answer = 42\n")
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_API": self.origin + "/vod/entry.py"}):
            loaded = _DeclaredSpider({"helper": "/shared/helper.py"}).loadModule("helper")
        self.assertEqual(loaded.answer, 42)
        self.assertEqual(self.server.requests, ["/shared/helper.py"])

    def test_size_and_declaration_count_limits_apply_before_execution(self):
        from base import modules
        self._write("helper.py", "answer = 42\n" + " " * 65)
        with patch.object(modules, "MAX_SOURCE_BYTES", 64), self.assertRaisesRegex(ImportError, "size"):
            _DeclaredSpider(["helper"]).loadModule("helper")
        self.assertNotIn("helper", sys.modules)
        with self.assertRaises(ValueError):
            _DeclaredSpider(["helper" + str(index) for index in range(33)]).loadModule("helper0")
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_API": self.origin + "/entry.py"}), patch.object(
                modules, "MAX_SOURCE_BYTES", 64):
            for headers in ({}, {"Content-Length": "invalid"}, {"Content-Length": "-1"}):
                self.server.responses["/helper.py"] = (200, headers, b"answer = 42\n" + b" " * 65)
                with self.subTest(headers=headers), self.assertRaises(ImportError):
                    _DeclaredSpider(["helper"]).loadModule("helper")

    def test_redirects_and_compressed_http_sources_are_rejected(self):
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_API": self.origin + "/entry.py"}):
            self.server.responses["/helper.py"] = (302, {"Location": self.origin + "/redirect.py"}, b"")
            with self.assertRaises(ImportError):
                _DeclaredSpider(["helper"]).loadModule("helper")
            self.assertEqual(self.server.requests, ["/helper.py"])
            self.server.responses["/helper.py"] = (200, {"Content-Encoding": "gzip"}, b"not-gzip")
            with self.assertRaises(ImportError):
                _DeclaredSpider(["helper"]).loadModule("helper")

    def test_circular_and_undeclared_imports_fail_without_partial_cache(self):
        self._write("first.py", "import second\n")
        self._write("second.py", "import first\n")
        spider = _DeclaredSpider(["first", "second"])
        with self.assertRaises(ImportError):
            spider.loadModule("first")
        self._write("first.py", "from .missing import value\n")
        with self.assertRaises(ImportError):
            spider.loadModule("first")
        self._write("first.py", "import requests\n")
        with self.assertRaises(ImportError):
            spider.loadModule("first")
        self._write("first.py", "from xml.etree import ElementTree\nanswer = ElementTree.fromstring('<r/>').tag\n")
        self.assertEqual(spider.loadModule("first").answer, "r")

    def test_endless_module_initialization_times_out_and_does_not_cache(self):
        from base import modules
        self._write("helper.py", "while True:\n    pass\n")
        spider = _DeclaredSpider(["helper"])
        started = time.monotonic()
        with patch.object(modules, "LOAD_TIMEOUT_SECONDS", 0.15), self.assertRaises(TimeoutError):
            spider.loadModule("helper")
        self.assertLess(time.monotonic() - started, 0.9)
        self._write("helper.py", "answer = 42\n")
        with self.assertRaises(TimeoutError):
            spider.loadModule("helper")
        self.assertEqual(_DeclaredSpider(["helper"]).loadModule("helper").answer, 42)
        for thread in threading.enumerate():
            if thread.name == "script-module":
                thread.join(timeout=0.5)
                self.assertFalse(thread.is_alive())

    def test_endless_dependency_initialization_also_has_deadline(self):
        from base import modules

        class LoopSpider(_DeclaredSpider):
            def getDependence(self):
                while True:
                    pass

        started = time.monotonic()
        with patch.object(modules, "LOAD_TIMEOUT_SECONDS", 0.15), self.assertRaises(TimeoutError):
            LoopSpider([]).loadModule("helper")
        self.assertLess(time.monotonic() - started, 0.9)

    def test_http_stall_and_slow_drip_have_total_deadline_and_release_sockets(self):
        from base import modules
        for name in ("stall", "drip"):
            self.server.responses["/" + name + ".py"] = (200, {}, b"answer = 42\n")
            self.server.release.clear()
            self.server.started.clear()
            spider = _DeclaredSpider([name])
            started = time.monotonic()
            try:
                with self.subTest(name=name), patch.dict(os.environ, {
                    "XIUGOU_SCRIPT_API": self.origin + "/entry.py",
                }), patch.object(modules, "LOAD_TIMEOUT_SECONDS", 0.2), self.assertRaises(TimeoutError):
                    spider.loadModule(name)
                self.assertLess(time.monotonic() - started, 0.9)
                self.assertTrue(self.server.started.is_set())
            finally:
                self.server.release.set()
            for thread in threading.enumerate():
                if thread.name == "script-module":
                    thread.join(timeout=0.5)
                    self.assertFalse(thread.is_alive())

    def test_lazy_js_accessor_uses_base_runtime_once_per_spider(self):
        fake = types.ModuleType("base.js")
        constructed = []

        class RuntimeJS:
            def __init__(self):
                constructed.append(self)

        fake.RuntimeJS = RuntimeJS
        with patch.dict(sys.modules, {"base.js": fake}):
            first, second = _DeclaredSpider([]), _DeclaredSpider([])
            self.assertEqual(constructed, [])
            self.assertIs(first.js, first.js)
            self.assertIsNot(first.js, second.js)
            self.assertEqual(len(constructed), 2)
            first.js = "injected"
            self.assertEqual(first.js, "injected")


if __name__ == "__main__":
    unittest.main()
