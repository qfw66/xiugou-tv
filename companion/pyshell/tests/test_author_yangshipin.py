"""Run the unchanged YSP author against real runtime APIs and local HTTP peers.

Run: python -B -m unittest discover -s companion/pyshell/tests -p test_author_yangshipin.py -v
Only a missing author reference skips this suite (override with XIUGOU_AUTHOR_YSP).
The web fixture reuses synthetic WASM; it does not validate the official signing binary.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
import base.ttl_cache as runtime_cache  # noqa: E402
from base.http_transport import RuntimeReader  # noqa: E402
from base.local import RuntimeLocal  # noqa: E402
from base.net import RuntimeNet  # noqa: E402
from base.spider import Spider as BaseSpider  # noqa: E402
from author_ysp_fixture import (  # noqa: E402
    AUTHOR_SHA256, CNLID, DEFAULT_AUTHOR, MEDIA, SNAPSHOT, TV_PID,
    Reply, TvPeer, YspFixture, catalog_replies, decode_app_ckey, load_author, ts_payload, web_wasm,
)


class AuthorYangshipinTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ.get("XIUGOU_AUTHOR_YSP") or DEFAULT_AUTHOR)
        if not cls.source.is_file():
            raise unittest.SkipTest("author YSP source missing; set XIUGOU_AUTHOR_YSP")
        cls.source_hash = hashlib.sha256(cls.source.read_bytes()).hexdigest()
        if cls.source_hash != AUTHOR_SHA256:
            raise AssertionError("author YSP reference hash differs from the task28 original")
        cls.author = load_author(cls.source)

    @classmethod
    def tearDownClass(cls):
        if hashlib.sha256(cls.source.read_bytes()).hexdigest() != cls.source_hash:
            raise AssertionError("author YSP reference changed during the tests")

    def setUp(self):
        fixture = YspFixture()
        self.fixture = fixture.__enter__()
        self.addCleanup(fixture.__exit__, None, None, None)
        self.enterContext(patch.object(self.author, "tempfile", SimpleNamespace(
            gettempdir=lambda: self.fixture.local_dir)))
        self.spider = self.new_spider()
        self.assertIsInstance(self.spider, BaseSpider)
        self.assertIsInstance(self.spider.net, RuntimeNet)

    def tearDown(self):
        self.assertEqual(self.fixture.errors, [])

    def new_spider(self):
        spider = self.author.Spider()
        spider.init(SNAPSHOT)
        self.addCleanup(self.close_spider, spider)
        return spider

    @staticmethod
    def close_spider(spider):
        try:
            spider.destroy()
        finally:
            spider.net.close()

    def catalog(self, channels):
        navigation, page = catalog_replies(channels)
        self.fixture.reply(self.author.NAVIGATION_URL, navigation)
        self.fixture.reply(self.author.PAGE_URL.format("fixture-tv"), page)

    @staticmethod
    def proxy_params(url):
        return {key: values[-1] for key, values in parse_qs(urlsplit(url).query).items()}

    def app_media(self, encrypted=True):
        self.media_bytes = ts_payload()
        self.fixture.json(self.author.APP_LIVE_URL, {
            "iretcode": 0, "playurl": MEDIA + "/entry.m3u8?origin=a%2Bb",
            "extended_param": "&fixture=one%2Btwo", "http_header": {"X-Fixture-Media": "app-token"},
        })
        self.fixture.reply(MEDIA + "/entry.m3u8", Reply(status=302, headers={
            "Location": "/hls/master.m3u8?master=a%2Bb",
        }))
        self.fixture.reply(MEDIA + "/hls/master.m3u8", Reply(
            b'#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI="audio/index.m3u8"\n'
            b'#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,URI="iframes.m3u8"\n'
            b'#EXT-X-STREAM-INF:BANDWIDTH=4000000\nvideo/index.m3u8?token=a%2Bb\n',
            mime=self.author.HLS_MIME))
        resource_tags = (
            '#EXT-X-KEY:METHOD=AES-128,URI="https://keys.cntv.com/key.bin?token=a%2Bb"\n'
            '#EXT-X-MAP:URI="https://init.cctvpic.com/init.mp4"\n'
            '#EXT-X-SESSION-DATA:DATA-ID="fixture",URI="https://metadata.citvc.com/session.json"\n'
            '#EXT-X-RENDITION-REPORT:URI="alternate.m3u8"\n'
        ) if encrypted else ""
        self.fixture.reply(MEDIA + "/hls/video/index.m3u8", Reply((
            "#EXTM3U\n" + resource_tags + "#EXTINF:6,\nsegment.ts?token=part%2Btoken\n"
        ).encode(), mime=self.author.HLS_MIME))
        self.fixture.reply("https://keys.cntv.com/key.bin", Reply(bytes(range(16))))
        self.fixture.reply("https://init.cctvpic.com/init.mp4", Reply(b"\0\0\0\x18ftypisom" + bytes(16)))
        self.fixture.json("https://metadata.citvc.com/session.json", {"source": "fixture"})

        def segment(request):
            byte_range = request["headers"].get("range")
            if byte_range is None:
                return Reply(self.media_bytes, mime="video/mp2t")
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", byte_range)
            assert match is not None, byte_range
            start = int(match[1])
            stop = min(int(match[2]) + 1, len(self.media_bytes)) if match[2] else len(self.media_bytes)
            return Reply(self.media_bytes[start:stop], 206, "video/mp2t", {
                "Content-Range": f"bytes {start}-{stop - 1}/{len(self.media_bytes)}",
                "Accept-Ranges": "bytes",
            })

        self.fixture.reply(MEDIA + "/hls/video/segment.ts", segment)

    def test_original_incomplete_protobuf_catalog_falls_back_and_orders_playback_labels(self):
        self.catalog([{"name": f"incomplete{index}", "pid": str(index + 1), "cnlid": "2"}
                      for index in range(49)])
        self.fixture.json(SNAPSHOT, {"channels": [
            {"name": " CCTV1 ", "pid": int(TV_PID), "cnlid": int(CNLID), "type": "yangshi"},
            {"name": "卫视测试", "pid": "700000001", "cnlid": "800000001", "type": "weishi", "vip": True},
        ]})
        groups = self.spider.liveContent("")
        self.assertEqual([group["name"] for group in groups], ["央視頻道", "衛視頻道"])
        tv, satellite = [group["channel"][0] for group in groups]
        self.assertEqual([tv["name"], tv["tvgId"], tv["number"]], ["CCTV1", TV_PID, "01"])
        self.assertEqual(satellite["number"], "02")
        for row, labels, sources, definitions in (
            (tv, ["自動", "超清", "電視", "手機"], ["auto", "auto", "tv", "app"], ["fhd", "sfhd", None, "fhd"]),
            (satellite, ["自動", "超清", "手機"], ["auto", "auto", "app"], ["shd", "sfhd", "shd"]),
        ):
            self.assertEqual([url.rsplit("$", 1)[1] for url in row["urls"]], labels)
            for url, source, definition in zip(row["urls"], sources, definitions):
                route = url.rsplit("$", 1)[0]
                self.assertTrue(route.startswith("proxy://"))
                self.assertFalse(route.startswith("proxy://?"))
                params = parse_qs(route[len("proxy://"):])
                self.assertEqual(params["type"], [source])
                self.assertEqual(params.get("defn"), [definition] if definition else None)
                self.assertEqual(params["pid"], [row["tvgId"]])
                self.assertEqual(params["cmg"], ["1"])
                self.assertEqual(params["siteKey"], ["author-yangshipin"])
                self.assertEqual(params["token"], ["ysp+fixture"])
                self.assertEqual(params["do"], ["py"])
            self.assertEqual(row["format"], self.author.HLS_MIME)
            self.assertEqual(row["referer"], self.author.HOST + "/")
        epg = parse_qs(urlsplit(tv["epg"]).query)
        self.assertEqual(epg["id"], ["cctv1"])
        self.assertEqual(epg["date"], ["{date}"])
        self.assertNotIn("epg", satellite)
        self.assertEqual([request["path"] for request in self.fixture.requests], [
            "/api/oms/pc/navigation/home_top_nav", "/api/oms/pc/page/fixture-tv", "/snapshot",
        ])
        for request in self.fixture.requests[:2]:
            self.assertEqual(request["headers"]["accept"], "application/octet-stream")
            self.assertEqual(request["headers"]["referer"], self.author.HOST + "/")

    def test_original_complete_catalog_uses_protobuf_without_snapshot(self):
        channels = [{"name": f"频道{index}", "pid": str(900000000 + index),
                     "cnlid": str(800000000 + index), "type": "yangshi"} for index in range(50)]
        self.catalog(channels + [channels[0], {"name": "invalid", "pid": "bad", "cnlid": "1"}])
        groups = self.spider.liveContent("")
        self.assertEqual(len(groups[0]["channel"]), 50)
        self.assertEqual(len(self.fixture.requests), 2)
        self.assertEqual(self.fixture.matching(SNAPSHOT), [])

    def test_original_epg_cache_separates_dates_expires_and_does_not_serve_stale(self):
        now = [100.0]
        self.fixture.json(self.author.EPG_URL, {"data": {"cctv1": {"channelName": "CCTV1",
            "list": [{"startTime": 1704153600, "endTime": 1704155400, "title": "fixture morning"}]}}})
        params = {"type": "epg", "id": "cctv1", "date": "2024-01-02"}
        with patch.object(runtime_cache, "time", SimpleNamespace(monotonic=lambda: now[0])):
            first = self.spider.proxy(params)
            self.assertEqual(first[0], 200, first)
            data = json.loads(first[2])
            self.assertEqual(data["date"], "2024-01-02")
            self.assertEqual(data["epg_data"], [{"start": "08:00:00", "end": "08:30:00", "title": "fixture morning"}])
            now[0] += self.author.EPG_CACHE_SECONDS - 0.001
            self.assertEqual(self.spider.proxy(params), first)
            self.assertEqual(len(self.fixture.matching(self.author.EPG_URL)), 1)
            self.assertEqual(json.loads(self.spider.proxy(dict(params, date="2024-01-03"))[2])["date"], "2024-01-03")
            self.assertEqual(len(self.fixture.matching(self.author.EPG_URL)), 2)
            now[0] += 0.002
            self.fixture.json(self.author.EPG_URL, {"error": "offline"}, 503)
            failed = self.spider.proxy(params)
            self.assertEqual(failed[0], 502, failed)
            self.assertEqual(len(self.fixture.matching(self.author.EPG_URL)), 3)
            self.fixture.json(self.author.EPG_URL, {"data": {"cctv1": {"list": []}}})
            recovered = self.spider.proxy(params)
            self.assertEqual(recovered[0], 200, recovered)
            self.assertEqual(json.loads(recovered[2])["epg_data"], [])
            self.assertEqual(len(self.fixture.matching(self.author.EPG_URL)), 4)
        self.assertEqual(self.fixture.matching(self.author.EPG_URL)[0]["query"], {
            "c": ["cctv1"], "d": ["20240102"], "serviceId": ["tvcctv"],
        })
        for invalid in (dict(params, date="2024-13-01"), dict(params, id="../cctv1")):
            self.assertEqual(self.spider.proxy(invalid)[0], 400)
        self.assertEqual(len(self.fixture.matching(self.author.EPG_URL)), 4)

    def test_original_app_tea_hls_resources_and_large_binary_range_stream(self):
        self.app_media()
        params = {"type": "app", "pid": TV_PID, "cnlid": CNLID, "defn": "fhd"}
        master = self.spider.proxy(params)
        self.assertEqual(master[0], 200, master)
        self.assertEqual(master[1], self.author.HLS_MIME)
        app_request = self.fixture.matching(self.author.APP_LIVE_URL)[0]
        query = app_request["query"]
        packet = decode_app_ckey(query["cKey"][0])
        self.assertEqual(packet["platform"], self.author.APP_LIVE_PLATFORM)
        self.assertEqual(packet["version"], self.author.APP_LIVE_VERSION)
        self.assertEqual(packet["cnlid"], CNLID)
        self.assertEqual(packet["guid"], query["guid"][0])
        self.assertEqual(packet["timestamp"], int(query["fntick"][0]))
        self.assertEqual(packet["guard_timestamp"], packet["timestamp"])
        self.assertEqual(packet["source"], "dcgh")
        self.assertEqual(packet["flags"], (1, 1))
        self.assertEqual(packet["package"], "com.cctv.yangshipin.app.iphone")
        self.assertEqual(packet["guard_fields"], [packet["guid"][-5:], "", "", "-1"])
        self.assertEqual(query["defn"], ["fhd"])
        self.assertEqual(app_request["headers"]["user-agent"], "qqlive")
        entry = self.fixture.matching(MEDIA + "/entry.m3u8")[0]
        self.assertEqual(entry["query"], {"origin": ["a+b"], "fixture": ["one+two"]})
        self.assertEqual(entry["headers"]["x-fixture-media"], "app-token")
        self.assertEqual(entry["headers"]["referer"], "https://live.cctv.cn/")
        for child in re.findall(r'URI="([^"]+)"', master[2]):
            self.assertEqual(self.proxy_params(child)["kind"], "playlist")
        child = next(line for line in master[2].splitlines() if line and not line.startswith("#"))
        child_params = self.proxy_params(child)
        self.assertEqual(child_params["url"], MEDIA + "/hls/video/index.m3u8?token=a%2Bb")
        self.assertEqual(child_params["type"], "app")
        self.assertEqual(child_params["pid"], TV_PID)
        self.assertRegex(child_params["generation"], r"^[0-9a-f]{32}$")
        media = self.spider.proxy(child_params)
        self.assertEqual(media[0], 200, media)
        resources = re.findall(r'URI="([^"]+)"', media[2])
        self.assertEqual([self.proxy_params(url).get("kind") for url in resources],
                         ["segment", "segment", "segment", "playlist"])
        self.assertEqual(self.proxy_params(resources[2])["url"], "https://metadata.citvc.com/session.json")
        for resource in resources[:3]:
            resource_params = self.proxy_params(resource)
            self.assertEqual(resource_params["generation"], child_params["generation"])
            result = self.spider.proxy(resource_params)
            self.assertEqual(result[0], 200, result)
            self.assertIsInstance(result[2], RuntimeReader)
            self.assertIsInstance(result[2].read(1024), bytes)
            result[2].close()
        segment = next(line for line in media[2].splitlines() if line and not line.startswith("#"))
        self.assertTrue(urlsplit(segment).path.endswith("/hls/video/segment.ts"))
        segment_params = self.proxy_params(segment)
        streamed = self.spider.proxy(dict(segment_params, range="bytes=188-"))
        self.assertEqual(streamed[0:2], [206, "video/mp2t"], streamed[:2])
        self.assertIsInstance(streamed[2], RuntimeReader)
        self.addCleanup(streamed[2].close)
        response_headers = {key.lower(): value for key, value in streamed[3].items()}
        self.assertEqual(response_headers["content-range"], f"bytes 188-{len(self.media_bytes) - 1}/{len(self.media_bytes)}")
        digest, total, reads = hashlib.sha256(), 0, 0
        while True:
            chunk = streamed[2].read(65536)
            if chunk is None:
                break
            self.assertIsInstance(chunk, bytes)
            self.assertGreater(len(chunk), 0)
            digest.update(chunk)
            total += len(chunk)
            reads += 1
        self.assertGreater(total, 4 * 1024 * 1024)
        self.assertGreater(reads, 64)
        self.assertEqual(total, len(self.media_bytes) - 188)
        self.assertEqual(digest.digest(), hashlib.sha256(self.media_bytes[188:]).digest())
        self.assertEqual(len(self.fixture.matching(self.author.APP_LIVE_URL)), 1)
        self.assertEqual(self.spider.proxy(params)[0], 200)
        renewed = self.fixture.matching(self.author.APP_LIVE_URL)[1]["query"]["cKey"][0]
        self.assertNotEqual(renewed, query["cKey"][0])
        decode_app_ckey(renewed)

    def test_original_default_auto_rejects_tv_nonmedia_then_validates_app(self):
        self.app_media(encrypted=False)
        TvPeer(self.fixture, self.author)
        self.fixture.reply(MEDIA + "/tv/segment.ts", Reply(b"X" * 376, mime="video/mp2t"))
        params = {"type": "auto", "pid": TV_PID, "cnlid": CNLID}
        result = self.spider.proxy(params)
        self.assertEqual(result[0], 302, result)
        target = self.proxy_params(result[3]["Location"])
        self.assertEqual(target["type"], "app")
        self.assertEqual(target["defn"], "fhd")
        self.assertEqual(self.fixture.requests[0]["host"], "ytpaddr.cctv.cn")
        rejected = self.fixture.matching(MEDIA + "/tv/segment.ts")
        self.assertEqual(len(rejected), 1)
        app_request = self.fixture.matching(self.author.APP_LIVE_URL)[0]
        self.assertLess(self.fixture.requests.index(rejected[0]), self.fixture.requests.index(app_request))
        probe = self.fixture.matching(MEDIA + "/hls/video/segment.ts")
        self.assertEqual(len(probe), 1)
        self.assertEqual(probe[0]["headers"]["x-fixture-media"], "app-token")
        self.assertEqual(self.spider.proxy(params)[0], 302)
        self.assertEqual(len(self.fixture.matching(self.author.TV_BASE + "api/app/start/v1/01")), 1)
        self.assertEqual(len(self.fixture.matching(self.author.APP_LIVE_URL)), 2)

    def test_original_non_tv_auto_tries_app_web_cdrm_in_order(self):
        self.fixture.json(self.author.APP_LIVE_URL, {"iretcode": 1})
        self.fixture.reply(self.author.KEYGEN_URL, Reply(b"fixture unavailable", 503, "text/plain"))
        cdrm = "https://liveinfo.ysp.cctv.cn/"
        self.fixture.json(cdrm, {"iretcode": 0, "playurl": MEDIA + "/cdrm/index.m3u8"})
        self.fixture.reply(MEDIA + "/cdrm/index.m3u8", Reply(
            b"#EXTM3U\n#EXTINF:6,\nsegment.ts\n", mime=self.author.HLS_MIME))
        self.fixture.reply(MEDIA + "/cdrm/segment.ts", Reply(ts_payload(3), mime="video/mp2t"))
        pid = "700000001"
        self.assertNotIn(pid, self.author.TV_CHANNELS)
        result = self.spider.proxy({"type": "auto", "pid": pid, "cnlid": "800000001"})
        self.assertEqual(result[0], 302, result)
        self.assertEqual(self.proxy_params(result[3]["Location"])["type"], "cdrm")
        self.assertEqual([request["host"] for request in self.fixture.requests], [
            "bkliveinfo.ysp.cctv.cn", "s.yangshipin.cn", "liveinfo.ysp.cctv.cn",
            "fixture.cctv.cn", "fixture.cctv.cn",
        ])
        self.assertEqual(self.fixture.matching(cdrm)[0]["query"]["livepid"], [pid])

    def test_original_tv_device_persists_and_crypto_flow_reuses_registration(self):
        peer = TvPeer(self.fixture, self.author)
        params = {"type": "tv", "pid": TV_PID, "cnlid": CNLID, "rate": "high"}
        first = self.spider.proxy(params)
        self.assertEqual(first[0], 200, first)
        self.assertIsInstance(self.spider.local, RuntimeLocal)
        device = self.spider.local.get("tv-device:v1")
        self.assertRegex(device["android_id"], r"^[0-9a-f]{16}$")
        second = self.new_spider()
        self.assertEqual(second.local.get("tv-device:v1"), device)
        repeated = second.proxy(params)
        self.assertEqual(repeated[0], 200, repeated)
        self.assertEqual(peer.identities, [device, device])
        self.assertEqual(len(self.fixture.matching(self.author.TV_CLOUD + "register")), 1)
        self.assertEqual(len(self.fixture.matching(self.author.TV_CLOUD + "get")), 2)
        child_code = '''
import json, sys
sys.path[:0] = sys.argv[1:3]
from author_ysp_fixture import CNLID, TV_PID, load_author, route_to_local
with route_to_local(sys.argv[4]):
    author = load_author(sys.argv[3])
    spider = author.Spider()
    spider.init("")
    try:
        result = spider.proxy({"type": "tv", "pid": TV_PID, "cnlid": CNLID, "rate": "high"})
        assert result[0] == 200, result
        print("YSP_DEVICE_RESULT=" + json.dumps(spider.local.get("tv-device:v1")))
    finally:
        spider.destroy()
        spider.net.close()
'''
        child = subprocess.run([sys.executable, "-B", "-c", child_code, str(SHELL), str(Path(__file__).parent),
                                str(self.source), self.fixture.origin], capture_output=True, text=True,
                               encoding="utf-8", env={**os.environ, "PYTHONIOENCODING": "utf-8"}, timeout=20)
        self.assertEqual(child.returncode, 0, child.stdout + child.stderr)
        record = next(line for line in child.stdout.splitlines() if line.startswith("YSP_DEVICE_RESULT="))
        self.assertEqual(json.loads(record.partition("=")[2]), device)
        self.assertEqual(peer.identities, [device, device, device])
        self.assertEqual(len(self.fixture.matching(self.author.TV_CLOUD + "register")), 1)
        self.assertEqual(len(self.fixture.matching(self.author.TV_CLOUD + "get")), 3)
        for result in (first, repeated):
            segment = next(line for line in result[2].splitlines() if line and not line.startswith("#"))
            self.assertEqual(self.proxy_params(segment)["url"], MEDIA + "/tv/segment.ts")

    def test_original_resource_allowlist_rejects_bad_urls_before_transport(self):
        self.app_media()
        master = self.spider.proxy({"type": "app", "pid": TV_PID, "cnlid": CNLID})
        self.assertEqual(master[0], 200, master)
        variant = next(line for line in master[2].splitlines() if line and not line.startswith("#"))
        params = dict(self.proxy_params(variant), kind="segment")
        for domain in ("cctv.cn", "cctv.com", "cntv.cn", "cntv.com", "cctvpic.com", "citvc.com", "yangshipin.cn"):
            with self.subTest(allowed_domain=domain):
                url = "https://fixture-media." + domain + "/sample.ts"
                self.fixture.reply(url, Reply(b"\x47\0\xff", mime="video/mp2t"))
                result = self.spider.proxy(dict(params, url=url))
                self.assertEqual(result[0], 200, result)
                self.assertEqual(result[2].read(3), b"\x47\0\xff")
                result[2].close()
        requests_before = len(self.fixture.requests)
        for url in ("https://cctv.cn.evil.invalid/a.ts", "https://evilcctv.cn/a.ts",
                    "http://127.0.0.1/a.ts", "https://user@fixture.cctv.cn/a.ts",
                    "https://fixture.cctv.cn:0/a.ts", "https://fixture.cctv.cn/\\bad.ts",
                    "https://fixture.cctv.cn/a.ts\r\nX-Test: bad", "file:///segment.ts"):
            with self.subTest(rejected_url=repr(url)):
                result = self.spider.proxy(dict(params, url=url))
                self.assertEqual(result[0], 400, result)
        self.assertEqual(len(self.fixture.requests), requests_before)

    def test_original_web_keygen_and_cross_subdomain_session_cookies(self):
        from Crypto.Cipher import AES
        from Crypto.Util.Padding import unpad

        wasm = web_wasm()
        self.fixture.reply(self.author.KEYGEN_URL, Reply(wasm, mime="application/wasm", headers={"ETag": '"fixture-wasm"'}))
        self.fixture.json(self.author.PLAYER_URL + "auth", {
            "code": 0, "data": {"token": "fixture-player-token", "ts": 1704153600},
        }, headers={"Set-Cookie": "fixture_auth=local; Domain=yangshipin.cn; Path=/; Secure; HttpOnly"})
        self.fixture.json(self.author.OPEN_TOKEN_URL, {"data": {"token": "fixture-sdk-token"}},
                          headers={"Set-Cookie": "fixture_open=host-only; Path=/; Secure"})
        self.fixture.json(self.author.PLAYER_URL + "get_live_info", {"code": 0, "data": {
            "iretcode": 0, "playurl": MEDIA + "/web/index.m3u8", "extended_param": "&fixture=web",
        }})
        self.fixture.reply(MEDIA + "/web/index.m3u8", Reply(b"#EXTM3U\n#EXTINF:6,\nsegment.ts\n", mime=self.author.HLS_MIME))
        for spider in (self.spider, self.new_spider()):
            result = spider.proxy({"type": "web", "pid": TV_PID, "cnlid": CNLID})
            self.assertEqual(result[0], 200, result)
            self.assertIn(MEDIA + "/web/segment.ts", result[2])
            self.assertIsInstance(spider.player.keygen, self.author._Keygen)
            self.assertEqual(spider.player.keygen.heap, {})
        self.assertEqual(len(self.fixture.matching(self.author.KEYGEN_URL)), 1)
        self.assertEqual((Path(self.fixture.local_dir) / "ysp-keygen-v1.wasm").read_bytes(), wasm)
        auth_calls = self.fixture.matching(self.author.PLAYER_URL + "auth")
        token_calls = self.fixture.matching(self.author.OPEN_TOKEN_URL)
        play_calls = self.fixture.matching(self.author.PLAYER_URL + "get_live_info")
        self.assertEqual([len(auth_calls), len(token_calls), len(play_calls)], [2, 2, 2])
        guids = []
        for auth_request, token_request, play_request in zip(auth_calls, token_calls, play_calls):
            auth = {key: values[-1] for key, values in parse_qs(auth_request["body"].decode()).items()}
            auth_signature = auth.pop("signature")
            canonical = "&".join(f"{key}={auth[key]}" for key in sorted(auth))
            self.assertEqual(auth_signature, hashlib.md5((canonical + self.author.AUTH_SALT).encode()).hexdigest())
            guid = auth["guid"]
            guids.append(guid)
            for request in (auth_request, token_request, play_request):
                self.assertIn("guid=" + guid, request["headers"]["cookie"])
                self.assertIn("versionName=99.99.99", request["headers"]["cookie"])
                self.assertEqual(request["headers"]["origin"], self.author.HOST)
            self.assertNotIn("fixture_auth=", auth_request["headers"]["cookie"])
            self.assertIn("fixture_auth=local", token_request["headers"]["cookie"])
            self.assertIn("fixture_auth=local", play_request["headers"]["cookie"])
            self.assertNotIn("fixture_open=", play_request["headers"]["cookie"])
            self.assertEqual(token_request["query"]["rnd"], [""])
            self.assertEqual(token_request["query"]["guid"], [guid])
            play = json.loads(play_request["body"])
            self.assertEqual(play["guid"], guid)
            self.assertEqual(play["cnlid"], CNLID)
            self.assertEqual(play_request["headers"]["yspplayertoken"], "fixture-player-token")
            sdk_input = {key: value for key, value in play.items() if key not in ("signature", "rand_str")}
            canonical = "&".join(f"{key}={sdk_input[key]}" for key in sorted(sdk_input))
            digest = hashlib.md5(canonical.encode()).hexdigest()
            self.assertEqual(play_request["headers"]["yspsdkinput"], digest)
            self.assertEqual(play_request["headers"]["yspsdksign"],
                             "fixture-sdk-token-" + digest + "-" + guid + "-1-" + play_request["headers"]["request-id"])
            clear = unpad(AES.new(bytes.fromhex("48e5918a74ae21c972b90cce8af6c8be"), AES.MODE_CBC,
                                  bytes.fromhex("9a7e7d23610266b1d9fbf98581384d92")).decrypt(
                                      bytes.fromhex(play["cKey"][4:])), 16).decode()
            self.assertIn("|" + CNLID + "|", clear)
            self.assertIn("|" + guid + "|", clear)
        self.assertNotEqual(guids[0], guids[1])
        self.fixture.json(self.author.PLAYER_URL + "cookie-check", {"ok": True})
        self.spider.net.json(self.author.PLAYER_URL + "cookie-check")
        self.assertNotIn("cookie", self.fixture.matching(self.author.PLAYER_URL + "cookie-check")[0]["headers"])
        for request in self.fixture.matching(MEDIA + "/web/index.m3u8"):
            self.assertNotIn("cookie", request["headers"])


if __name__ == "__main__":
    unittest.main()
