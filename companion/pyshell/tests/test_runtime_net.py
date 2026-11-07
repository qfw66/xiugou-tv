"""Offline runtime contracts: python -B -m unittest discover -s companion/pyshell/tests -p test_runtime_net.py -v."""

import base64
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.spider import Spider  # noqa: E402


class _LocalHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self._respond()

    def do_POST(self):
        self._respond()

    def do_HEAD(self):
        self._respond()

    def _respond(self):
        payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        path = urlsplit(self.path)
        observation = {"method": self.command, "path": path.path,
                       "query": parse_qs(path.query, keep_blank_values=True),
                       "headers": dict(self.headers),
                       "body": base64.b64encode(payload).decode("ascii")}
        self.server.requests.append(observation)
        status, content_type = 200, "application/json; charset=utf-8"
        headers = []
        content = json.dumps(observation, ensure_ascii=False).encode("utf-8")
        if path.path == "/binary":
            content_type, content = "application/octet-stream", b"\x00\x80\xff"
        elif path.path == "/latin":
            content_type, content = 'text/plain; charset="iso-8859-1"', b"caf\xe9"
        elif path.path == "/gzip":
            content = gzip.compress(content)
            headers.append(("Content-Encoding", "gzip"))
        elif path.path == "/forbidden":
            status, content = 403, b'{"message":"denied"}'
        elif path.path == "/invalid-json":
            content_type, content = "text/html", b"<html>login</html>"
        elif path.path == "/redirect":
            status, content = 302, b"redirect body"
            headers.append(("Location", "/echo?redirected=yes"))
        elif path.path == "/duplicate":
            headers.extend([("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")])
        elif path.path == "/slow":
            threading.Event().wait(0.2)
        elif path.path in ("/large", "/large-gzip"):
            content = b"x" * (8 * 1024 * 1024 + 1)
            if path.path == "/large-gzip":
                content = gzip.compress(content)
                headers.append(("Content-Encoding", "gzip"))
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(content)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass


class _CctvShapeSpider(Spider):
    def __init__(self):
        self.own_constructor_ran = True

    def _request(self, url, params=None, headers=None, buffer=0):
        options = {"headers": headers or {}, "timeout": 8000, "buffer": buffer}
        if params:
            options["params"] = params
        result = self.net.req(url, options)
        if result.get("error"):
            raise OSError(result["error"])
        if result["code"] >= 400:
            raise ValueError("HTTP " + str(result["code"]))
        return result["content"]


class RuntimeNetHttpTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _LocalHandler)
        cls.server.requests = []
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
        self.spider = _CctvShapeSpider()
        self.addCleanup(self._close_net)

    def _close_net(self):
        net = self.spider.__dict__.get("_net")
        if net is not None:
            net.close()

    def test_cctv_request_uses_independent_net_with_query_headers_and_bytes(self):
        payload = self.spider._request(
            self.origin + "/echo?existing=a%2Bb",
            params={"channel": "中文 +&=", "repeat": ["first", "second"],
                    "omit": None, "empty": ""},
            headers={"Referer": "https://example.invalid/", "User-Agent": "cctv-test"},
            buffer=3,
        )
        self.assertIsInstance(payload, bytes)
        response = json.loads(payload)
        self.assertEqual(response["query"], {
            "existing": ["a+b"], "channel": ["中文 +&="],
            "repeat": ["first", "second"], "empty": [""],
        })
        self.assertEqual(response["headers"]["Referer"], "https://example.invalid/")
        self.assertEqual(response["headers"]["User-Agent"], "cctv-test")
        self.assertTrue(self.spider.own_constructor_ran)

    def test_all_binary_modes_and_response_charset(self):
        for buffer, expected in ((1, [0, -128, -1]), (2, "AID/"),
                                 (3, b"\x00\x80\xff")):
            with self.subTest(buffer=buffer):
                self.assertEqual(self.spider.net.req(self.origin + "/binary", {
                    "buffer": buffer,
                })["content"], expected)
        self.assertEqual(self.spider.net.req(self.origin + "/latin")["content"], "café")

    def test_json_rejects_http_failure_invalid_json_and_overrides_buffer(self):
        with self.assertRaisesRegex(ValueError, "HTTP 403"):
            self.spider.net.json(self.origin + "/forbidden")
        with self.assertRaisesRegex(ValueError, "JSON"):
            self.spider.net.json(self.origin + "/invalid-json")
        options = {"buffer": 3}
        self.assertEqual(self.spider.net.json(self.origin + "/echo", options)["path"], "/echo")
        self.assertEqual(options, {"buffer": 3})

    def test_http_failure_preserves_status_headers_and_body(self):
        result = self.spider.net.req(self.origin + "/forbidden")
        self.assertEqual(result["code"], 403)
        self.assertEqual(json.loads(result["content"]), {"message": "denied"})
        self.assertIn("Content-Type", result["headers"])
        self.assertNotIn("error", result)

    def test_post_json_form_and_explicit_body(self):
        result = self.spider.net.json(self.origin + "/echo", {
            "data": {"name": "中文", "number": 3},
        })
        self.assertEqual(result["method"], "POST")
        self.assertEqual(json.loads(base64.b64decode(result["body"])), {"name": "中文", "number": 3})
        self.assertEqual(result["headers"]["Content-Type"], "application/json; charset=utf-8")
        result = self.spider.net.json(self.origin + "/echo", {
            "method": "POST", "postType": "form", "data": {"name": " a+b ", "page": 3},
        })
        self.assertEqual(parse_qs(base64.b64decode(result["body"]).decode("utf-8")), {
            "name": ["a+b"], "page": ["3"],
        })
        result = self.spider.net.json(self.origin + "/echo", {
            "body": [0, 128, 255], "headers": {"content-type": "application/octet-stream"},
        })
        self.assertEqual(base64.b64decode(result["body"]), b"\x00\x80\xff")
        self.assertEqual(result["headers"]["Content-Type"], "application/octet-stream")

    def test_redirect_can_be_disabled_without_losing_location(self):
        redirected = self.spider.net.json(self.origin + "/redirect")
        self.assertEqual(redirected["query"], {"redirected": ["yes"]})
        response = self.spider.net.req(self.origin + "/redirect", {"redirect": False})
        self.assertEqual(response["code"], 302)
        self.assertEqual(response["headers"]["Location"], "/echo?redirected=yes")
        self.assertEqual(response["content"], "redirect body")

    def test_gzip_and_duplicate_response_headers(self):
        self.assertEqual(self.spider.net.json(self.origin + "/gzip")["path"], "/gzip")
        response = self.spider.net.req(self.origin + "/duplicate")
        self.assertEqual(response["headers"]["Set-Cookie"], ["a=1", "b=2"])

    def test_timeout_is_milliseconds_and_error_does_not_expose_url(self):
        start = time.monotonic()
        response = self.spider.net.req(self.origin + "/slow?token=private-value", {
            "timeout": 30,
        })
        self.assertLess(time.monotonic() - start, 1)
        self.assertEqual(response["code"], 0)
        self.assertTrue(response["error"])
        self.assertNotIn("private-value", response["error"])
        with self.assertRaises(OSError):
            self.spider.net.json(self.origin + "/slow", {"timeout": 30})

    def test_wire_and_decompressed_responses_have_a_finite_limit(self):
        for path in ("/large", "/large-gzip"):
            with self.subTest(path=path):
                response = self.spider.net.req(self.origin + path, {"buffer": 3})
                self.assertEqual(response["code"], 0)
                self.assertEqual(response["content"], b"")
                self.assertIn("8 MiB", response["error"])

    def test_invalid_options_fail_before_network_io(self):
        for options in ({"buffer": True}, {"buffer": 4}, {"timeout": 0},
                        {"timeout": float("nan")}, {"timeout": -1},
                        {"method": "GET", "body": "body"},
                        {"method": "HEAD", "data": {}}, {"body": [], "data": {}},
                        {"body": [-1]}, {"headers": {"X-Test": "a\r\nb"}},
                        {"postType": "form-data", "data": {}},
                        {"cookie": True}, {"callTimeout": -1}, {"callTimeout": True},
                        {"redirect": 2}, {"redirect": "0"}):
            with self.subTest(options=options):
                before = len(self.server.requests)
                with self.assertRaises((ValueError, TypeError, NotImplementedError)):
                    self.spider.net.req(self.origin + "/echo", options)
                self.assertEqual(len(self.server.requests), before)
        for url in ("file:///private", "http://127.0.0.1/\n", "not-a-url"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.spider.net.req(url)

    def test_close_is_idempotent_and_does_not_recreate_runtime(self):
        net = self.spider.net
        net.close()
        net.close()
        self.assertIs(self.spider.net, net)
        with self.assertRaisesRegex(RuntimeError, "closed"):
            net.req(self.origin + "/echo")

    def test_legacy_fetch_post_and_cache_remain_available(self):
        with patch.dict(os.environ, {"XIUGOU_CACHE_DIR": "", "XIUGOU_PROXY_BASE": "legacy-prefix"}):
            spider = Spider()
        response = spider.fetch(self.origin + "/echo", timeout=1)
        self.assertTrue(response.ok)
        self.assertEqual(response.json()["method"], "GET")
        response = spider.post(self.origin + "/echo", {"name": "old form"})
        self.assertEqual(parse_qs(base64.b64decode(response.json()["body"]).decode()),
                         {"name": ["old form"]})
        spider.setCache("legacy", {"kept": True})
        self.assertEqual(spider.getCache("legacy"), {"kept": True})
        self.assertEqual(spider.getProxyUrl(), "legacy-prefix")


class RuntimeNetCacheTest(unittest.TestCase):
    def setUp(self):
        self.net = _CctvShapeSpider().net
        self.addCleanup(self.net.close)

    def test_cache_waits_for_fresh_value_and_starts_ttl_after_loader_finishes(self):
        now, calls = [10.0], []

        def load():
            calls.append(len(calls) + 1)
            now[0] += 2
            return {"revision": calls[-1], "programs": ["新闻"]}

        with patch("time.monotonic", lambda: now[0]):
            first = self.net.cached("epg:1:20261107", {"ttl": 1000, "stale": False}, load)
            self.assertEqual(first, {"revision": 1, "programs": ["新闻"]})
            now[0] = 12.999
            self.assertEqual(self.net.cached("epg:1:20261107", {"ttl": 1000}, load), first)
            self.assertEqual(calls, [1])
            now[0] = 13.0
            self.assertEqual(self.net.cached("epg:1:20261107", {"ttl": 1000}, load)["revision"], 2)
            self.assertEqual(calls, [1, 2])

    def test_failed_refresh_propagates_and_is_retried_without_stale_fallback(self):
        now, calls = [1.0], []

        def fail():
            calls.append("failed")
            raise OSError("fixture failure")

        with patch("time.monotonic", lambda: now[0]):
            self.net.cached("epg", {"ttl": 1000}, lambda: {"old": True})
            now[0] = 2.0
            for _ in range(2):
                with self.assertRaisesRegex(OSError, "fixture failure"):
                    self.net.cached("epg", {"ttl": 1000, "stale": False}, fail)
            self.assertEqual(calls, ["failed", "failed"])
            self.assertEqual(self.net.cached("epg", {"ttl": 1000}, lambda: None), None)
            self.assertIsNone(self.net.cached("epg", {"ttl": 1000}, self.fail))

    def test_zero_ttl_bypasses_existing_value_and_cache_returns_json_snapshots(self):
        source = {"programs": ["original"]}
        result = self.net.cached("epg", {"ttl": 10000}, lambda: source)
        source["programs"].append("source mutation")
        result["programs"].append("caller mutation")
        self.assertEqual(self.net.cached("epg", {"ttl": 10000}, self.fail),
                         {"programs": ["original"]})
        self.assertEqual(self.net.cached("epg", {"ttl": 0}, lambda: "uncached"), "uncached")
        self.assertEqual(self.net.cached("epg", {"ttl": 0}, lambda: "next"), "next")
        self.assertEqual(self.net.cached("epg", {"ttl": 10000}, lambda: "fresh"), "fresh")

    def test_clear_one_or_all_and_script_instance_isolation(self):
        other = _CctvShapeSpider().net
        self.addCleanup(other.close)
        for net, value in ((self.net, "first"), (other, "second")):
            for key in ("a", "b"):
                self.assertEqual(net.cached(key, {"ttl": 10000}, lambda: value), value)
        self.net.clearCache("a")
        self.assertEqual(self.net.cached("a", {"ttl": 10000}, lambda: "reloaded"), "reloaded")
        self.assertEqual(self.net.cached("b", {"ttl": 10000}, self.fail), "first")
        self.assertEqual(other.cached("a", {"ttl": 10000}, self.fail), "second")
        self.net.clearCache()
        self.net.clearCache("missing")
        for key in ("a", "b"):
            self.assertEqual(self.net.cached(key, {"ttl": 10000}, lambda: "cleared"), "cleared")

    def test_invalid_or_unsupported_cache_options_do_not_call_loader(self):
        options_list = ({}, {"ttl": -1}, {"ttl": True}, {"ttl": float("inf")},
                        {"ttl": 1, "stale": True},
                        {"ttl": 1, "stale": None}, {"ttl": 1, "persist": 0},
                        {"ttl": 1, "refresh": 1})
        for options in options_list:
            with self.subTest(options=options), self.assertRaises((ValueError, NotImplementedError)):
                self.net.cached("epg", options, self.fail)
        for key in (None, "", " ", 1):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.net.cached(key, {"ttl": 1}, self.fail)
            if key is not None:
                with self.assertRaises(ValueError):
                    self.net.clearCache(key)
        with self.assertRaises(TypeError):
            self.net.cached("epg", {"ttl": 1}, None)

    def test_invalid_or_oversized_loader_values_are_not_cached(self):
        circular = []
        circular.append(circular)
        for value in (b"bytes", {"value": float("nan")}, circular):
            with self.subTest(kind=type(value).__name__), self.assertRaisesRegex(ValueError, "JSON"):
                self.net.cached("epg", {"ttl": 10000}, lambda: value)
        with self.assertRaisesRegex(ValueError, "8 MiB"):
            self.net.cached("epg", {"ttl": 10000}, lambda: "x" * (8 * 1024 * 1024))
        self.assertEqual(self.net.cached("epg", {"ttl": 10000}, lambda: "valid"), "valid")

    def test_closed_runtime_does_not_serve_cached_values_or_accept_new_loads(self):
        self.net.cached("epg", {"ttl": 10000}, lambda: "cached")
        self.net.close()
        self.net.close()
        with self.assertRaisesRegex(RuntimeError, "closed"):
            self.net.cached("epg", {"ttl": 10000}, self.fail)
        with self.assertRaisesRegex(RuntimeError, "closed"):
            self.net.clearCache()


class RuntimeNetConnectionTest(unittest.TestCase):
    def test_parent_close_from_callback_cancels_registered_connection(self):
        from test_runtime_ws import websocket_fixture
        net = _CctvShapeSpider().net
        self.addCleanup(net.close)
        finished = threading.Event()
        messages, sent = [], []

        def receive(connection, event):
            if event["type"] == "open":
                sent.append(connection.send(b"join"))
            elif event["type"] == "message":
                messages.append(event["content"])
                net.close()
                finished.set()

        with websocket_fixture(message=b"hello") as server:
            connection = net.connect(server.url, {"timeout": 1000}, receive)
            self.assertTrue(finished.wait(1))
            self.assertEqual(messages, ["hello"])
            self.assertEqual(sent, [True])
            self.assertFalse(connection.send(b"late"))
            connection.cancel()
            with self.assertRaises(RuntimeError):
                net.connect(server.url, None, receive)

    def test_scope_cancel_during_registration_does_not_retain_closed_connection(self):
        from base.cancel_scope import CancelScope
        import gc
        import weakref
        net = _CctvShapeSpider().net
        self.addCleanup(net.close)
        scope = CancelScope()
        original_add = scope.add
        workers = []

        def add_then_cancel(resource):
            original_add(resource)
            worker = threading.Thread(target=scope.close, daemon=True)
            workers.append(worker)
            worker.start()
            self.assertTrue(scope.event.wait(1))

        with scope.activate(), patch.object(scope, "add", add_then_cancel):
            connection = net.connect("ws://127.0.0.1:1/", None, lambda connection, event: None)
        for worker in workers:
            worker.join(1)
            self.assertFalse(worker.is_alive())
        self.assertFalse(connection.send(b"late"))
        retained = weakref.ref(connection)
        del connection
        gc.collect()
        self.assertIsNone(retained())

    def test_cancelling_connection_keeps_parent_available(self):
        from test_runtime_ws import websocket_fixture
        net = _CctvShapeSpider().net
        self.addCleanup(net.close)
        opened = threading.Event()
        events = []

        def receive(connection, event):
            events.append(event["type"])
            if event["type"] == "open":
                opened.set()

        with websocket_fixture() as server:
            connection = net.connect(server.url, {"timeout": 1000}, receive)
            self.assertTrue(opened.wait(1))
            connection.cancel()
            self.assertFalse(connection.send(b"late"))
            self.assertTrue(server.finished.wait(1))
            self.assertEqual(events, ["open"])
            self.assertEqual(net.cached("alive", {"ttl": 1000}, lambda: 7), 7)


class ScriptProxyUrlTest(unittest.TestCase):
    def setUp(self):
        self.spider = _CctvShapeSpider()
        env = patch.dict(os.environ, {
            "XIUGOU_SCRIPT_PROXY_BASE": "http://127.0.0.1:12345/script-proxy?token=opaque%2B%25&route=a%2Bb&empty=",
            "XIUGOU_SCRIPT_SITE_KEY": "央视 +&=",
            "XIUGOU_PROXY_BASE": "legacy-prefix",
        })
        env.start()
        self.addCleanup(env.stop)

    def test_proxy_url_preserves_host_token_and_encodes_each_parameter_once(self):
        params = {"id": "a+b &=中文%2F", "type": "epg", "date": "{date}"}
        result = urlsplit(self.spider.proxyUrl(params))
        self.assertEqual((result.scheme, result.netloc, result.path),
                         ("http", "127.0.0.1:12345", "/script-proxy"))
        self.assertEqual(parse_qs(result.query, keep_blank_values=True), {
            "token": ["opaque+%"], "route": ["a+b"], "empty": [""],
            "do": ["py"], "siteKey": ["央视 +&="],
            "id": ["a+b &=中文%2F"], "type": ["epg"], "date": ["{date}"],
        })
        self.assertEqual(params, {"id": "a+b &=中文%2F", "type": "epg", "date": "{date}"})
        query = parse_qs(urlsplit(self.spider.proxyUrl({"id": "1"}) + "&date=20261107").query)
        self.assertEqual(query["date"], ["20261107"])

    def test_host_routing_and_token_cannot_be_overridden(self):
        for key in ("do", "siteKey", "token", "route", "empty"):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "host routing"):
                self.spider.proxyUrl({key: "replacement"})
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_PROXY_BASE":
                                     "http://127.0.0.1:12345/script-proxy?do=wrong&siteKey=wrong&token=kept"}):
            query = parse_qs(urlsplit(self.spider.proxyUrl()).query)
        self.assertEqual(query, {"do": ["py"], "siteKey": ["央视 +&="], "token": ["kept"]})

    def test_none_and_empty_params_are_equal_and_old_proxy_api_stays_independent(self):
        self.assertEqual(self.spider.proxyUrl(), self.spider.proxyUrl({}))
        self.assertEqual(self.spider.proxyUrl(None, local=True), self.spider.proxyUrl())
        with patch.dict(os.environ, {"XIUGOU_CACHE_DIR": ""}):
            legacy = Spider()
        self.assertEqual(legacy.getProxyUrl(), "legacy-prefix")
        self.assertEqual(legacy.getProxyUrl(False), "legacy-prefix")
        self.assertEqual(legacy.getProxyUrl(True), "legacy-prefix")
        self.assertEqual(legacy.proxyUrl(), self.spider.proxyUrl())

    def test_proxy_params_and_local_mode_are_strict(self):
        for params in (False, [], "", {1: "value"}, {"key": 1}, {"key": None}):
            with self.subTest(params=params), self.assertRaises(TypeError):
                self.spider.proxyUrl(params)
        for local in (None, 0, 1, "true"):
            with self.subTest(local=local), self.assertRaises(TypeError):
                self.spider.proxyUrl(local=local)
        with self.assertRaisesRegex(NotImplementedError, "LAN"):
            self.spider.proxyUrl(local=False)

    def test_missing_or_invalid_host_configuration_fails_without_exposing_secrets(self):
        for base in ("", "relative/script-proxy", "file:///private", "http://user:secret@127.0.0.1/",
                     "http://127.0.0.1:0/", "http://127.0.0.1:99999/", "http://[invalid/",
                     "http://127.0.0.1/\n?token=secret", "http://127.0.0.1/#token=secret"):
            with self.subTest(base=base), patch.dict(os.environ, {"XIUGOU_SCRIPT_PROXY_BASE": base}):
                with self.assertRaises(RuntimeError) as caught:
                    self.spider.proxyUrl()
                self.assertNotIn("secret", str(caught.exception))
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_SITE_KEY": " "}):
            with self.assertRaisesRegex(RuntimeError, "not configured"):
                self.spider.proxyUrl()


if __name__ == "__main__":
    unittest.main()
