"""Danmaku URLs preserve host routing and never accept a source to load."""

import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.spider import Spider  # noqa: E402


class SpiderDanmakuUrlTest(unittest.TestCase):
    def setUp(self):
        self.spider = Spider.__new__(Spider)
        environment = patch.dict(os.environ, {
            "XIUGOU_SCRIPT_DANMAKU_BASE": "http://127.0.0.1:12345/opaque/endpoint?token=opaque%2B%25&route=a%2Bb&empty=",
            "XIUGOU_SCRIPT_SITE_KEY": "游戏 +&=",
            "XIUGOU_SCRIPT_PROXY_BASE": "http://127.0.0.1:54321/proxy?token=other",
        })
        environment.start()
        self.addCleanup(environment.stop)

    def test_original_game_player_includes_host_danmaku_url_for_room(self):
        path = Path(os.environ.get("XIUGOU_AUTHOR_GAME") or
                    r"E:\code\tvbox_1102\live-python\vod\game_live.py")
        if not path.is_file():
            self.skipTest("original game source missing; set XIUGOU_AUTHOR_GAME")
        spec = importlib.util.spec_from_file_location("author_game_danmaku_url_fixture", path)
        author = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(author)
        spider = author.Spider.__new__(author.Spider)
        with patch.object(spider, "_huya_live", return_value={"url": "fixture-stream"}) as live:
            result = spider.playerContent("", "huya:abc123", [])
        live.assert_called_once_with("abc123")
        self.assertEqual(result["url"], "fixture-stream")
        self.assertEqual(result["position"], 0)
        self.assertEqual(len(result["danmaku"]), 1)
        query = parse_qs(urlsplit(result["danmaku"][0]["url"]).query)
        self.assertEqual(query["id"], ["huya:abc123"])
        self.assertEqual(query["siteKey"], ["游戏 +&="])
        self.assertEqual(query["token"], ["opaque+%"])

    def test_room_string_is_encoded_once_and_host_token_and_path_are_preserved(self):
        room = "douyu:房间 +&=%2F?api=ignored&load=ignored"
        result = urlsplit(self.spider.danmakuUrl(room))
        self.assertEqual((result.scheme, result.netloc, result.path),
                         ("http", "127.0.0.1:12345", "/opaque/endpoint"))
        self.assertEqual(parse_qs(result.query, keep_blank_values=True), {
            "token": ["opaque+%"], "route": ["a+b"], "empty": [""],
            "do": ["py"], "siteKey": ["游戏 +&="], "id": [room],
        })

    def test_host_routing_and_id_are_forced_without_duplicate_parameters(self):
        base = "http://127.0.0.1/danmaku?token=kept&do=other&siteKey=other&id=old&id=again"
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_DANMAKU_BASE": base}):
            query = parse_qs(urlsplit(self.spider.danmakuUrl("yy:123_456")).query)
        self.assertEqual(query, {"token": ["kept"], "do": ["py"],
                                 "siteKey": ["游戏 +&="], "id": ["yy:123_456"]})

    def test_only_literal_loopback_or_localhost_http_endpoints_are_accepted(self):
        for authority in ("127.0.0.1:80", "127.10.20.30:81", "localhost:82", "[::1]:83"):
            with self.subTest(authority=authority), patch.dict(os.environ, {
                "XIUGOU_SCRIPT_DANMAKU_BASE": "https://" + authority + "/endpoint?token=fixture",
            }):
                self.assertEqual(urlsplit(self.spider.danmakuUrl("huya:abc")).netloc, authority)
        for base in ("http://example.invalid/", "http://127.0.0.1.evil.invalid/", "http://0.0.0.0/",
                     "http://192.168.1.1/", "http://[::]/", "http://127.1/", "http://2130706433/",
                     "file:///local", "ws://127.0.0.1/", "//127.0.0.1/path"):
            with self.subTest(base=base), patch.dict(os.environ, {
                "XIUGOU_SCRIPT_DANMAKU_BASE": base + "?token=secret",
            }), self.assertRaises(RuntimeError) as caught:
                self.spider.danmakuUrl("douyu:123")
            self.assertNotIn("secret", str(caught.exception))

    def test_missing_invalid_or_ambiguous_host_configuration_is_rejected(self):
        for base in ("", "http://127.0.0.1/", "http://127.0.0.1/?token=",
                     "http://127.0.0.1/?token=one&token=two", "http://user:secret@127.0.0.1/?token=x",
                     "http://127.0.0.1:0/?token=x", "http://127.0.0.1:99999/?token=x",
                     "http://[invalid/?token=x", "http://127.0.0.1/\n?token=secret",
                     "http://127.0.0.1/?token=secret#fragment"):
            with self.subTest(base=base), patch.dict(os.environ, {
                "XIUGOU_SCRIPT_DANMAKU_BASE": base,
            }), self.assertRaises(RuntimeError) as caught:
                self.spider.danmakuUrl("douyu:123")
            self.assertNotIn("secret", str(caught.exception))
        with patch.dict(os.environ, {"XIUGOU_SCRIPT_SITE_KEY": " "}), self.assertRaises(RuntimeError):
            self.spider.danmakuUrl("douyu:123")

    def test_only_a_nonempty_room_string_can_be_passed(self):
        for value in (None, 123, {}, {"api": "anything"}, ["id"]):
            with self.subTest(value=value), self.assertRaises(TypeError):
                self.spider.danmakuUrl(value)
        for value in ("", " ", "room\x00", "room\r\n", "x" * 4097):
            with self.subTest(value=value[:20]), self.assertRaises(ValueError):
                self.spider.danmakuUrl(value)
        with self.assertRaises(TypeError):
            self.spider.danmakuUrl("room", api="anything")
        with self.assertRaises(TypeError):
            self.spider.danmakuUrl("room", load="anything")


if __name__ == "__main__":
    unittest.main()
