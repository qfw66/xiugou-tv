"""Exercise the unchanged author GD script through real local HTTP and WebSocket."""

import base64
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import sys
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet  # noqa: E402
from base.spider import Spider as BaseSpider  # noqa: E402
from test_runtime_ws import frame, read_frame, websocket_fixture  # noqa: E402


DEFAULT_AUTHOR = Path(r"E:\code\tvbox_1102\live-python-20261107\live\gdtv.py")


class _GdHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        self.server.requests.append({
            "target": self.path,
            "path": parsed.path,
            "query": parse_qs(parsed.query, keep_blank_values=True),
            "headers": {key.lower(): value for key, value in self.headers.items()},
        })
        status, content = self.server.responses.get(parsed.path, (404, b"fixture route not found"))
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


class AuthorGdtvTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ.get("XIUGOU_AUTHOR_GDTV") or DEFAULT_AUTHOR)
        if not source.is_file():
            raise unittest.SkipTest("author GD source missing; set XIUGOU_AUTHOR_GDTV")
        spec = importlib.util.spec_from_file_location("xiugou_author_gdtv_fixture", source)
        cls.author = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.author)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _GdHandler)
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
        websocket = websocket_fixture()
        self.ws = websocket.__enter__()
        self.addCleanup(websocket.__exit__, None, None, None)
        endpoints = patch.multiple(
            self.author, HOST=self.origin, API_URL=self.origin,
            CATALOG_URL=self.origin + "/catalog", PLAY_URL=self.origin + "/play",
            NODE_HOST=self.origin + "/signed-node-origin", NODE_URL=self.origin + "/node",
            WS_URL=self.ws.url,
            PLAYER_HEADERS={"User-Agent": self.author.USER_AGENT, "Referer": self.origin + "/"},
        )
        endpoints.start()
        self.addCleanup(endpoints.stop)
        environment = patch.dict(os.environ, {
            "XIUGOU_SCRIPT_PROXY_BASE": self.origin + "/script-proxy?token=gd%2Bfixture",
            "XIUGOU_SCRIPT_SITE_KEY": "author-gdtv",
            "XIUGOU_CACHE_DIR": "",
            "NO_PROXY": "127.0.0.1,localhost",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.spider = self.author.Spider()
        self.spider.init("")
        self.addCleanup(self._close_spider)
        self.assertIsInstance(self.spider, BaseSpider)
        self.assertIsInstance(self.spider.net, RuntimeNet)
        self.location = self.origin + "/media/广东.m3u8?token=a%2Bb&quality=hd"
        self._reply_json("/node", {"node": "direct-node"})
        self._reply_json("/play", {"videoUrl": self.location})

    def _close_spider(self):
        try:
            self.spider.destroy()
        finally:
            net = self.spider.__dict__.get("_net")
            if net is not None:
                net.close()

    def _reply_json(self, path, payload, status=200):
        self.server.responses[path] = (status, json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    def _assert_signature(self, headers, signed_url):
        timestamp = headers["x-itouchtv-ca-timestamp"]
        message = "GET\n" + signed_url + "\n" + timestamp + "\n"
        expected = base64.b64encode(hmac.new(
            self.author.API_SECRET, message.encode("utf-8"), hashlib.sha256).digest()).decode("ascii")
        self.assertEqual(headers["x-itouchtv-ca-signature"], expected)
        self.assertEqual(headers["x-itouchtv-ca-key"], self.author.API_KEY)
        self.assertEqual(headers["x-itouchtv-client"], "NEWS_APP")
        self.assertEqual(headers["user-agent"], self.author.USER_AGENT)
        self.assertEqual(headers["referer"], self.origin + "/")

    def test_original_direct_node_returns_location_without_websocket_and_preserves_signed_query(self):
        node = "direct+node/& %中文"
        self._reply_json("/node", {"node": node})
        result = self.spider.proxy({"id": "00101"})
        self.assertEqual(result, [302, "text/plain", "", {"Location": self.location}])
        self.assertEqual([item["path"] for item in self.server.requests], ["/node", "/play"])
        self.assertEqual(self.server.requests[1]["query"], {"channelId": ["101"], "node": [node]})
        self.assertEqual(self.ws.requests, [])
        for request in self.server.requests:
            self._assert_signature(request["headers"], self.origin + request["target"])

    def test_original_websocket_node_uses_node_host_signature_and_real_fragmented_exchange(self):
        node, resolved = "challenge+中文-1", "resolved+node/% 中文"
        self._reply_json("/node", {"node": node})
        message = json.dumps({"status": 201, "wsnode": resolved}, ensure_ascii=False).encode("utf-8")

        def fragmented(stream, observation):
            stream.sendall(frame(message[:9], fin=False) + frame(b"gd-heartbeat", opcode=9)
                           + frame(message[9:], opcode=0))
            observation["frames"].extend([read_frame(stream), read_frame(stream)])

        self.ws.on_message = fragmented
        self.assertEqual(self.spider.proxy({"id": "101"}),
                         [302, "text/plain", "", {"Location": self.location}])
        self.assertTrue(self.ws.finished.wait(1))
        request = self.ws.requests[0]
        self._assert_signature(request["headers"], self.author.NODE_HOST)
        wrong_message = "GET\n" + self.author.WS_URL + "\n" + request["headers"]["x-itouchtv-ca-timestamp"] + "\n"
        wrong_signature = base64.b64encode(hmac.new(
            self.author.API_SECRET, wrong_message.encode("utf-8"), hashlib.sha256).digest()).decode("ascii")
        self.assertNotEqual(request["headers"]["x-itouchtv-ca-signature"], wrong_signature)
        outgoing, pong, close = request["frames"]
        self.assertTrue(outgoing["masked"])
        self.assertEqual(json.loads(outgoing["payload"]), {"route": "getwsparam", "message": node})
        self.assertEqual(pong["opcode"], 10)
        self.assertEqual(pong["payload"], b"gd-heartbeat")
        self.assertEqual(close["opcode"], 8)
        self.assertEqual(self.server.requests[-1]["query"], {"channelId": ["101"], "node": [resolved]})
        for request in self.server.requests:
            self._assert_signature(request["headers"], self.origin + request["target"])

    def test_original_30_second_cache_expires_and_failed_refresh_does_not_reuse_stale_url(self):
        self._reply_json("/node", {"node": "challenge-1"})
        clock = [100.0]
        with patch("base.ttl_cache.time", SimpleNamespace(monotonic=lambda: clock[0])):
            first = self.spider.proxy({"id": "101"})
            self.assertEqual(first[0], 302)
            clock[0] = 129.999
            self.assertEqual(self.spider.proxy({"id": "101"}), first)
            self.assertEqual(len(self.server.requests), 2)
            self.assertEqual(len(self.ws.requests), 1)
            clock[0] = 130.0
            self._reply_json("/play", {"error": "temporary failure"}, status=503)
            failed = self.spider.proxy({"id": "101"})
            self.assertEqual(failed[0], 502)
            self.assertIn("HTTP 503", failed[2])
            self.assertEqual(len(self.ws.requests), 2)
            fresh_location = self.origin + "/media/fresh.m3u8?token=new"
            self._reply_json("/play", {"videoUrl": fresh_location})
            fresh = self.spider.proxy({"id": "101"})
            self.assertEqual(fresh, [302, "text/plain", "", {"Location": fresh_location}])
            self.assertEqual(len(self.ws.requests), 3)
            self.assertEqual(len(self.server.requests), 6)
            self.assertEqual(self.spider.proxy({"id": "101"}), fresh)
            self.assertEqual(len(self.server.requests), 6)
            self.assertEqual(self.spider.proxy({"id": "102"})[0], 302)
            self.assertEqual(len(self.server.requests), 8)

    def _catalog(self):
        def channel(number, name, kind=1):
            return {"tvChannelPk": number, "channelName": name, "tvType": kind,
                    "coverUrl": self.origin + "/logo/" + str(number)}

        return {"categoryTvChannelResps": [
            {"categoryPk": 3041, "categoryName": "省台", "tvChannelEntityList": [
                channel("00101", "广东卫视"), channel(201, "登录频道"), channel(1198, "电视专用"),
                channel(999, "广播", 2)]},
            {"categoryPk": 3043, "categoryName": "地市", "tvChannelEntityList": [
                channel(102, "深圳频道"), channel(101, "广东卫视")]},
            {"categoryPk": 3044, "categoryName": "县区", "tvChannelEntityList": [channel(103, "县区频道")]},
        ]}

    def test_original_catalog_deduplicates_tv_channels_and_uses_host_proxy_urls(self):
        self._reply_json("/catalog", self._catalog())
        groups = self.spider.liveContent("")
        self.assertEqual([group["name"] for group in groups], ["全部頻道", "省台", "地市", "县区"])
        channels = groups[0]["channel"]
        self.assertEqual([channel["tvgId"] for channel in channels], ["101", "201", "102", "103"])
        self.assertEqual([channel["number"] for channel in channels], ["01", "02", "03", "04"])
        for channel in channels:
            self.assertEqual(channel["format"], "application/x-mpegURL")
            self.assertEqual(channel["ua"], self.author.USER_AGENT)
            self.assertEqual(channel["referer"], self.origin + "/")
            parsed = urlsplit(channel["urls"][0])
            self.assertEqual(parsed.scheme + "://" + parsed.netloc, self.origin)
            self.assertEqual(parsed.path, "/script-proxy")
            self.assertEqual(parse_qs(parsed.query), {
                "do": ["py"], "siteKey": ["author-gdtv"], "token": ["gd+fixture"], "id": [channel["tvgId"]],
            })
        self._assert_signature(self.server.requests[0]["headers"], self.author.CATALOG_URL)

    def test_original_login_error_returns_403_and_removes_channel_from_future_catalog(self):
        self._reply_json("/catalog", self._catalog())
        self.assertIn("201", [row["tvgId"] for row in self.spider.liveContent("")[0]["channel"]])
        self._reply_json("/play", {"errorCode": 403001}, status=403)
        result = self.spider.proxy({"id": "201"})
        self.assertEqual(result[0], 403)
        self.assertIn("登入", result[2])
        before = len(self.server.requests)
        self.assertEqual(self.spider.proxy({"id": "201"}), result)
        self.assertEqual(len(self.server.requests), before)
        groups = self.spider.liveContent("")
        self.assertEqual([row["tvgId"] for row in groups[0]["channel"]], ["101", "102", "103"])
        self.assertEqual([row["number"] for row in groups[0]["channel"]], ["01", "02", "03"])
        self._reply_json("/node", {"errorCode": "403001"}, status=200)
        self.assertEqual(self.spider.proxy({"id": "202"})[0], 403)
        before = len(self.server.requests)
        self.assertEqual(self.spider.proxy({"id": "202"})[0], 403)
        self.assertEqual(len(self.server.requests), before)

    def test_original_invalid_or_tv_only_id_is_rejected_without_network(self):
        for channel_id in ("", "0", "000", "-1", "1&node=x", "１２３", 101, None):
            with self.subTest(channel_id=channel_id):
                self.assertEqual(self.spider.proxy({"id": channel_id})[0], 400)
        self.assertEqual(self.spider.proxy({"id": "001198"})[0], 403)
        self.assertEqual(self.server.requests, [])
        self.assertEqual(self.ws.requests, [])

    def test_original_websocket_failures_return_502_without_poisoning_cache(self):
        self._reply_json("/node", {"node": "challenge-1"})
        invalid_messages = [b"not-json", b"[]", b'{"status":200,"wsnode":"wrong"}',
                            b'{"status":201,"wsnode":""}', b'{"status":201,"wsnode":12}']
        for message in invalid_messages:
            with self.subTest(message=message):
                self.ws.message = message
                result = self.spider.proxy({"id": "101"})
                self.assertEqual(result[0], 502)
        self.assertEqual([item["path"] for item in self.server.requests], ["/node"] * len(invalid_messages))
        self.assertEqual(len(self.ws.requests), len(invalid_messages))

        def reject_handshake(stream, observation):
            stream.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")

        self.ws.on_handshake = reject_handshake
        result = self.spider.proxy({"id": "101"})
        self.assertEqual(result[0], 502)
        self.assertIn("HTTP 403", result[2])
        self.ws.on_handshake = None
        self.ws.message = b'{"status":201,"wsnode":"recovered"}'
        self.assertEqual(self.spider.proxy({"id": "101"})[0], 302)
        self.assertEqual(self.server.requests[-1]["query"]["node"], ["recovered"])
        before = len(self.ws.requests)
        self.assertEqual(self.spider.proxy({"id": "101"})[0], 302)
        self.assertEqual(len(self.ws.requests), before)

    def test_original_invalid_http_payloads_remain_failures_and_can_retry(self):
        for payload, status in (({}, 200), ({"node": 12}, 200), ({"node": ""}, 200), ({}, 503)):
            with self.subTest(payload=payload, status=status):
                self._reply_json("/node", payload, status)
                self.assertEqual(self.spider.proxy({"id": "101"})[0], 502)
        self._reply_json("/node", {"node": "direct-node"})
        for value in (None, "", "file:///tmp/stream", "http:///missing-host"):
            with self.subTest(video=value):
                self._reply_json("/play", {"videoUrl": value})
                self.assertEqual(self.spider.proxy({"id": "101"})[0], 502)
        self.server.responses["/play"] = (200, b"not-json")
        self.assertEqual(self.spider.proxy({"id": "101"})[0], 502)
        self._reply_json("/play", {"videoUrl": self.location})
        self.assertEqual(self.spider.proxy({"id": "101"}),
                         [302, "text/plain", "", {"Location": self.location}])
        self.assertEqual(self.ws.requests, [])


if __name__ == "__main__":
    unittest.main()
