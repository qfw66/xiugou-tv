"""Run the unmodified author CCTV script against local HTTP fixtures; missing source skips."""

import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet  # noqa: E402
from base.spider import Spider as BaseSpider  # noqa: E402


DEFAULT_AUTHOR = Path(r"E:\code\tvbox_1102\live-python-20261107\live\cctv.py")
CHANNEL_IDS = ["cctv" + str(number) for number in range(1, 18)] + ["cctv5plus"]


class _CctvHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        self.server.requests.append({
            "path": parsed.path,
            "query": parse_qs(parsed.query, keep_blank_values=True),
            "headers": {key.lower(): value for key, value in self.headers.items()},
        })
        status, mime, content = self.server.responses.get(
            parsed.path, (404, "text/plain", b"fixture route not found"))
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


class AuthorCctvTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ.get("XIUGOU_AUTHOR_CCTV") or DEFAULT_AUTHOR)
        if not source.is_file():
            raise unittest.SkipTest("author CCTV source missing; set XIUGOU_AUTHOR_CCTV")
        spec = importlib.util.spec_from_file_location("xiugou_author_cctv_fixture", source)
        cls.author = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.author)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _CctvHandler)
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
        self.server.requests = []
        self.server.responses = {}
        endpoints = patch.multiple(self.author, HOST=self.origin,
                                   CATALOG_URL=self.origin + "/catalog",
                                   EPG_URL=self.origin + "/epg", PLAY_URL=self.origin + "/play")
        endpoints.start()
        self.addCleanup(endpoints.stop)
        environment = patch.dict(os.environ, {
            "XIUGOU_SCRIPT_PROXY_BASE": self.origin + "/script-proxy?token=fixture%2Btoken",
            "XIUGOU_SCRIPT_SITE_KEY": "author-cctv",
            "XIUGOU_PROXY_BASE": "legacy-prefix",
            "XIUGOU_CACHE_DIR": "",
            "NO_PROXY": "127.0.0.1,localhost",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.spider = self.author.Spider()
        self.spider.init(self.origin + "/snapshot")
        self.addCleanup(self._close_spider)
        self.assertIsInstance(self.spider, BaseSpider)
        self.assertIsInstance(self.spider.net, RuntimeNet)

    def _close_spider(self):
        try:
            self.spider.destroy()
        finally:
            net = self.spider.__dict__.get("_net")
            if net is not None:
                net.close()

    def _reply_json(self, path, payload, status=200):
        self.server.responses[path] = (
            status, "application/json; charset=utf-8",
            json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        )

    def _reply_catalog(self, channel_ids=CHANNEL_IDS):
        links = [
            '<a href="https://tv.cctv.com/live/{}/">频道 {}</a>'.format(channel_id, index)
            for index, channel_id in enumerate(channel_ids, 1)
        ]
        links += ['<a href="https://tv.cctv.com/live/cctv1/">重复</a>',
                  '<a href="https://example.invalid/ignored/">非频道</a>']
        content = ('<html><head><meta charset="utf-8"></head><body>'
                   + "".join(links) + "</body></html>").encode("utf-8")
        self.server.responses["/catalog"] = (200, "text/html; charset=utf-8", content)

    def test_original_catalog_produces_18_channels_and_real_proxy_urls(self):
        self._reply_catalog()
        groups = self.spider.liveContent("")
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["name"], "央視頻道")
        channels = groups[0]["channel"]
        self.assertEqual(len(channels), 18)
        self.assertEqual([channel["tvgId"] for channel in channels], CHANNEL_IDS)
        self.assertEqual([channel["number"] for channel in channels],
                         ["{:02d}".format(number) for number in range(1, 19)])
        for index, channel in enumerate(channels, 1):
            self.assertEqual(channel["name"], "频道 " + str(index))
            self.assertEqual(channel["format"], "application/x-mpegURL")
            self.assertEqual(channel["ua"], self.author.USER_AGENT)
            self.assertEqual(len(channel["urls"]), 1)
            parsed = urlsplit(channel["urls"][0])
            self.assertEqual(parsed.scheme + "://" + parsed.netloc, self.origin)
            self.assertEqual(parsed.path, "/script-proxy")
            self.assertEqual(parse_qs(parsed.query), {
                "token": ["fixture+token"], "do": ["py"],
                "siteKey": ["author-cctv"], "id": [channel["tvgId"]],
            })
            self.assertEqual(parse_qs(urlsplit(channel["epg"]).query), {
                "token": ["fixture+token"], "do": ["py"],
                "siteKey": ["author-cctv"], "id": [channel["tvgId"]],
                "type": ["epg"], "date": ["{date}"],
            })
        self.assertEqual(len(self.server.requests), 1)
        request = self.server.requests[0]
        self.assertEqual(request["path"], "/catalog")
        self.assertEqual(request["headers"]["referer"], self.origin + "/")
        self.assertEqual(request["headers"]["user-agent"], self.author.USER_AGENT)

    def test_original_proxy_returns_302_location_from_primary_or_backup_manifest(self):
        self._reply_catalog()
        play_url = self.spider.liveContent("")[0]["channel"][0]["urls"][0]
        params = {key: values[0] for key, values in parse_qs(urlsplit(play_url).query).items()}
        location = self.origin + "/media/live.m3u8?token=a%2Bb&channel=cctv1"
        for source in ("manifest", "backup"):
            with self.subTest(source=source):
                self.server.requests.clear()
                self._reply_json("/play", {"ack": "yes", source: {"hls_cdrm": location}})
                self.assertEqual(self.spider.proxy(params),
                                 [302, "text/plain", "", {"Location": location}])
                self.assertEqual(len(self.server.requests), 1)
                request = self.server.requests[0]
                self.assertEqual(request["path"], "/play")
                self.assertEqual(request["query"]["channel"], ["cctv1"])
                self.assertEqual(request["query"]["vn"], ["1"])
                self.assertEqual(request["query"]["pdrm"], ["1"])
                self.assertTrue(request["query"]["uid"][0])
                auth_key = request["headers"]["auth-key"]
                self.assertRegex(auth_key, r"^\d+-\d{3}-[0-9a-f]{32}$")
                self.assertEqual(auth_key.split("-")[0], request["query"]["hbss"][0])
                self.assertEqual(request["headers"]["origin"], self.origin)
                self.assertEqual(request["headers"]["referer"], self.origin + "/")
                self.assertEqual(request["headers"]["user-agent"], self.author.USER_AGENT)
                self.assertEqual(request["headers"]["x-requested-with"], "XMLHttpRequest")

    def test_original_epg_uses_selected_date_and_one_network_request_within_ttl(self):
        self._reply_catalog()
        channel = self.spider.liveContent("")[0]["channel"][0]
        self.server.requests.clear()
        self._reply_json("/epg", {"data": {"cctv1": {"list": [
            {"title": "  早间新闻  ", "startTime": 1704153600, "endTime": 1704155400},
            {"title": "", "startTime": 1704153600, "endTime": 1704155400},
            {"title": "无效时间", "startTime": "invalid", "endTime": 1704155400},
            None,
        ]}}})
        epg_url = channel["epg"].replace("{date}", "2024-01-02")
        params = {key: values[0] for key, values in parse_qs(urlsplit(epg_url).query).items()}
        first = self.spider.proxy(params)
        second = self.spider.proxy(params)
        self.assertEqual(first, second)
        self.assertEqual(first[:2], [200, "application/json"])
        self.assertEqual(json.loads(first[2]), {
            "date": "2024-01-02", "epg_data": [
                {"title": "早间新闻", "start": "08:00:00", "end": "08:30:00"},
            ],
        })
        self.assertEqual(len(self.server.requests), 1)
        request = self.server.requests[0]
        self.assertEqual(request["path"], "/epg")
        self.assertEqual(request["query"], {
            "c": ["cctv1"], "serviceId": ["tvcctv"], "d": ["20240102"],
        })
        self.assertEqual(request["headers"]["referer"], self.origin + "/")
        self.assertEqual(request["headers"]["user-agent"], self.author.USER_AGENT)
        params["date"] = "2024-01-03"
        third = self.spider.proxy(params)
        self.assertEqual(third[:2], [200, "application/json"])
        self.assertEqual(json.loads(third[2])["date"], "2024-01-03")
        self.assertEqual(len(self.server.requests), 2)
        self.assertEqual(self.server.requests[1]["query"]["d"], ["20240103"])

    def test_original_catalog_falls_back_to_http_snapshot_on_failure_or_incomplete_html(self):
        snapshot = [{"id": "cctv1", "name": "快照一"}, {"id": "cctv5plus", "name": "快照体育"}]
        self._reply_json("/snapshot", {"channels": snapshot})
        for failure in ("http", "incomplete"):
            with self.subTest(failure=failure):
                self.server.requests.clear()
                if failure == "http":
                    self.server.responses["/catalog"] = (503, "text/plain", b"unavailable")
                else:
                    self._reply_catalog(CHANNEL_IDS[:2])
                channels = self.spider.liveContent("")[0]["channel"]
                self.assertEqual([channel["tvgId"] for channel in channels], ["cctv1", "cctv5plus"])
                self.assertEqual([channel["name"] for channel in channels], ["快照一", "快照体育"])
                self.assertEqual([request["path"] for request in self.server.requests],
                                 ["/catalog", "/snapshot"])
                self.assertEqual(parse_qs(urlsplit(channels[0]["urls"][0]).query)["id"], ["cctv1"])

    def test_original_play_proxy_converts_network_and_payload_failures_to_502(self):
        failures = [
            (503, {"message": "unavailable"}, "HTTP 503"),
            (200, {"ack": "no"}, "play api rejected channel"),
            (200, {"ack": "yes", "manifest": {}}, "missing hls manifest"),
        ]
        for status, payload, message in failures:
            with self.subTest(status=status, message=message):
                self.server.requests.clear()
                self._reply_json("/play", payload, status=status)
                response = self.spider.proxy({"id": "cctv1"})
                self.assertEqual(response, [502, "text/plain", "央視網: " + message])
                self.assertEqual([request["path"] for request in self.server.requests], ["/play"])
        self.server.requests.clear()
        self.assertEqual(self.spider.proxy({"id": "../invalid"}),
                         [502, "text/plain", "央視網: invalid channel id"])
        self.assertEqual(self.server.requests, [])

    def test_original_epg_proxy_returns_502_without_caching_a_failed_load(self):
        params = {"type": "epg", "id": "cctv1", "date": "2024-01-02"}
        self.server.responses["/epg"] = (200, "text/html", b"<html>invalid JSON</html>")
        first = self.spider.proxy(params)
        self.assertEqual(first[:2], [502, "text/plain"])
        self.assertIn("JSON", first[2])
        self._reply_json("/epg", {"data": {"cctv1": {"list": []}}})
        second = self.spider.proxy(params)
        self.assertEqual(second[:2], [200, "application/json"])
        self.assertEqual(json.loads(second[2]), {"date": "2024-01-02", "epg_data": []})
        self.assertEqual(len(self.server.requests), 2)
        self.assertEqual(self.spider.proxy(params), second)
        self.assertEqual(len(self.server.requests), 2)
        params["date"] = "20240102"
        self.assertEqual(self.spider.proxy(params), [502, "text/plain", "央視網: invalid date"])
        self.assertEqual(len(self.server.requests), 2)


if __name__ == "__main__":
    unittest.main()
