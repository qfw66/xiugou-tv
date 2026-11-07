"""Unmodified author danmaku protocols over loopback RuntimeNet connections."""

from contextlib import contextmanager
import importlib.util
import os
from pathlib import Path
import struct
import sys
import threading
import unittest
from urllib.parse import parse_qs, urlsplit


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet  # noqa: E402
from test_runtime_connect import EventLog, connection_fixture  # noqa: E402
from test_runtime_ws import frame, read_frame  # noqa: E402


DEFAULT_AUTHOR = Path(r"E:\code\tvbox_1102\live-python\vod\game_live_protocol.py")


def douyu_packet(text):
    body = text.encode() + b"\0"
    return struct.pack("<III", len(body) + 8, len(body) + 8, 689) + body


def tars_int(tag, value):
    if value == 0:
        return bytes((tag << 4 | 12,))
    for size, kind in ((1, 0), (2, 1), (4, 2), (8, 3)):
        if -(1 << (8 * size - 1)) <= value < 1 << (8 * size - 1):
            return bytes((tag << 4 | kind,)) + value.to_bytes(size, "big", signed=True)
    raise ValueError("fixture integer exceeds signed 64-bit range")


def tars_blob(tag, content):
    return bytes((tag << 4 | 13, 0)) + tars_int(0, len(content)) + content


def tars_text(tag, text):
    content = text.encode()
    return bytes((tag << 4 | 6, len(content))) + content


def huya_chat(text, colors, color=0xffffff):
    palette = b"\x69" + tars_int(0, len(colors)) + b"".join(tars_int(0, item) for item in colors)
    message = tars_text(3, text) + b"\x6a" + tars_int(0, color) + palette + b"\x0b"
    push = tars_int(1, 1400) + tars_blob(2, message)
    return tars_int(0, 7) + tars_blob(1, push)


def yy_blob(data=b"", wide=False):
    if isinstance(data, str):
        data = data.encode()
    return struct.pack("<I" if wide else "<H", len(data)) + data


def yy_packet(uri, body=b""):
    return struct.pack("<IIH", len(body) + 10, uri, 200) + body


def yy_guest(uid):
    # Synthetic guest values exercise the wire contract without upstream credentials.
    payload = (yy_blob() + struct.pack("<III", 200, uid, 0) + yy_blob("fixture-account")
               + yy_blob("fixture-password") + yy_blob("fixture-cookie") + yy_blob() * 3 + struct.pack("<Q", uid))
    return yy_packet(778500, yy_blob() + struct.pack("<II", 200, 20078) + yy_blob(payload, True))


def yy_joined(top, sub):
    payload = struct.pack("<IIIII", top, 0, sub, 0, 0) + b"\x04" + yy_blob()
    return yy_packet(512011, yy_blob() + struct.pack("<IH", 2048514, 200) + yy_blob(payload, True))


def yy_chat(top, sub, text, color, alternate=False):
    content = (struct.pack("<I", 0) + yy_blob(b"", True) + struct.pack("<II", color, 0)
               + yy_blob(text.encode("utf-16le"), True) + struct.pack("<I", 0))
    inner = yy_packet(3104600, struct.pack("<III", 0, top, sub) + yy_blob(content))
    if alternate:
        return yy_packet(28760, struct.pack("<HI", 31, 0) + yy_blob(inner))
    return yy_packet(533080, struct.pack("<QQI", 12345, 0, 31) + yy_blob(inner, True))


class _EndpointNet:
    """Route only the endpoint; leave options, callbacks and RuntimeNet behavior intact."""

    def __init__(self, runtime, url):
        self.runtime, self.url = runtime, url
        self.calls, self.sockets = [], []

    def connect(self, url, options, callback):
        self.calls.append((url, options))
        connection = self.runtime.connect(self.url, options, callback)
        self.sockets.append(connection)
        return connection


class AuthorGameDanmakuTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ.get("XIUGOU_AUTHOR_GAME_PROTOCOL") or DEFAULT_AUTHOR)
        if not source.is_file():
            raise unittest.SkipTest("author game protocol missing; set XIUGOU_AUTHOR_GAME_PROTOCOL")
        spec = importlib.util.spec_from_file_location("xiugou_author_game_protocol_fixture", source)
        cls.author = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.author)

    @contextmanager
    def connected(self, peer):
        with connection_fixture(peer) as server:
            runtime = RuntimeNet()
            endpoint = _EndpointNet(runtime, server.url)
            try:
                yield server, endpoint
            finally:
                runtime.close()

    def assert_binary(self, packet):
        self.assertEqual((packet["fin"], packet["opcode"], packet["masked"]), (True, 2, True))
        return packet["payload"]

    def assert_yy(self, packet, uri):
        content = self.assert_binary(packet)
        self.assertEqual(struct.unpack_from("<IIH", content), (len(content), uri, 200))
        return content[10:]

    def assert_options(self, endpoint, platform):
        self.assertEqual(len(endpoint.calls), 1)
        url, options = endpoint.calls[0]
        self.assertEqual(options, {"timeout": 10000, "idle": 90000, "reconnect": True,
                                  **({"headers": {"Origin": "https://www.yy.com"}} if platform == "yy" else {})})
        self.assertEqual(urlsplit(url).hostname, {
            "douyu": "danmuproxy.douyu.com", "huya": "cdnws.api.huya.com", "yy": "h5-sinchl.yy.com"}[platform])

    def test_douyu_original_login_join_heartbeat_fragmented_chat_and_ready(self):
        sent_login, ack_login, send_chat = threading.Event(), threading.Event(), threading.Event()
        events = EventLog()

        def peer(stream, observation):
            observation["frames"].extend(read_frame(stream) for _ in range(3))
            sent_login.set()
            self.assertTrue(ack_login.wait(1))
            stream.sendall(frame(douyu_packet("type@=loginres/"), opcode=2))
            self.assertTrue(send_chat.wait(1))
            payload = (douyu_packet("type@=mrkl/") + douyu_packet("type@=chatmsg/txt@=你好@S@Alive/col@=1/")
                       + douyu_packet("type@=chatmsg/txt@=白色/col@=0/"))
            stream.sendall(frame(payload[:5], opcode=2) + frame(payload[5:19], opcode=2, fin=False)
                           + frame(b"pulse", opcode=9) + frame(payload[19:], opcode=0))
            observation["frames"].append(read_frame(stream))
            stream.recv(1)

        with self.connected(peer) as (server, endpoint):
            stop = self.author.subscribe(endpoint, {"platform": "douyu", "id": "12345"}, events.append)
            try:
                self.assertTrue(sent_login.wait(1))
                self.assertEqual(events.items, [])
                ack_login.set()
                self.assertFalse(events.wait(bool, 0.1))
                send_chat.set()
                self.assertTrue(events.wait(lambda items: len(items) >= 3))
                self.assertEqual(events.items, [{"state": "ready"}, {"text": "你好/@live", "color": 0xff2e2e},
                                               {"text": "白色", "color": 0xffffff}])
            finally:
                ack_login.set()
                send_chat.set()
                stop()
            self.assertTrue(server.requests[0]["finished"].wait(1))
            packets = server.requests[0]["frames"]
            self.assertEqual([self.assert_binary(item) for item in packets[:3]], [
                douyu_packet("type@=loginreq/roomid@=12345/"),
                douyu_packet("type@=joingroup/rid@=12345/gid@=-9999/"), douyu_packet("type@=mrkl/")])
            self.assertEqual(packets[3]["opcode"], 10)
            self.assertEqual(packets[3]["payload"], b"pulse")
            self.assertFalse(endpoint.sockets[0].send(b"late"))
            self.assert_options(endpoint, "douyu")

    def test_huya_original_tars_login_ack_multicolor_and_color_fallback(self):
        logged, acknowledge = threading.Event(), threading.Event()
        events = EventLog()
        room = {"platform": "huya", "uid": 123456789, "top": 1024, "sub": 2048}

        def peer(stream, observation):
            observation["frames"].extend(read_frame(stream) for _ in range(2))
            logged.set()
            self.assertTrue(acknowledge.wait(1))
            stream.sendall(frame(tars_int(0, 2) + tars_blob(1, tars_int(0, 0)), opcode=2)
                           + frame(huya_chat("虎牙彩色中文", [-1, 0x112233, 0x1000000, 0x445566, 0xabcdef]), opcode=2)
                           + frame(huya_chat("黑色", [], 0), opcode=2)
                           + frame(huya_chat("默认白色", [], -1), opcode=2))
            stream.recv(1)

        with self.connected(peer) as (server, endpoint):
            stop = self.author.subscribe(endpoint, room, events.append)
            try:
                self.assertTrue(logged.wait(1))
                self.assertEqual(events.items, [])
                acknowledge.set()
                self.assertTrue(events.wait(lambda items: len(items) >= 4))
                self.assertEqual(events.items, [{"state": "ready"},
                    {"text": "虎牙彩色中文", "color": 0x112233, "colors": [0x112233, 0x445566, 0xabcdef]},
                    {"text": "黑色", "color": 0}, {"text": "默认白色", "color": 0xffffff}])
            finally:
                acknowledge.set()
                stop()
            self.assertTrue(server.requests[0]["finished"].wait(1))
            login = (tars_int(0, room["uid"]) + tars_int(1, 1) + tars_text(2, "") + tars_text(3, "")
                     + tars_int(4, room["top"]) + tars_int(5, room["sub"]) + tars_int(6, 0) + tars_int(7, 0))
            self.assertEqual([self.assert_binary(item) for item in server.requests[0]["frames"]],
                             [tars_int(0, 1) + tars_blob(1, login), b"\x00\x14\x1d\x00\x0c"])
            self.assert_options(endpoint, "huya")

    def test_yy_original_guest_ap_login_join_groups_and_utf16_chat(self):
        guest, allow_guest, joining, allow_join = (threading.Event() for _ in range(4))
        events = EventLog()
        top, sub, uid = 123, 456, 12345

        def peer(stream, observation):
            observation["frames"].append(read_frame(stream))
            guest.set()
            self.assertTrue(allow_guest.wait(1))
            response = yy_guest(uid)
            stream.sendall(frame(response[:13], opcode=2) + frame(response[13:], opcode=2))
            observation["frames"].append(read_frame(stream))
            stream.sendall(frame(yy_packet(775940, struct.pack("<II", 0, 200) + yy_blob("259:0")), opcode=2))
            observation["frames"].extend(read_frame(stream) for _ in range(2))
            joining.set()
            self.assertTrue(allow_join.wait(1))
            stream.sendall(frame(yy_joined(top, sub), opcode=2))
            observation["frames"].extend(read_frame(stream) for _ in range(2))
            xml = '<msg><txt data="YY 中文&amp;♫"/><txt data="直播"/></msg>'
            payload = (yy_chat(top, sub + 1, "忽略其他频道", 1) + yy_chat(top, sub, xml, 0x13579b)
                       + yy_chat(top, sub, "另一种推送", 0, alternate=True))
            stream.sendall(frame(payload[:27], opcode=2, fin=False) + frame(b"yy-ping", opcode=9)
                           + frame(payload[27:], opcode=0))
            observation["frames"].append(read_frame(stream))
            stream.recv(1)

        with self.connected(peer) as (server, endpoint):
            stop = self.author.subscribe(endpoint, {"platform": "yy", "top": top, "sub": sub}, events.append)
            try:
                self.assertTrue(guest.wait(1))
                self.assertEqual(events.items, [])
                allow_guest.set()
                self.assertTrue(joining.wait(1))
                self.assertEqual(events.items, [])
                allow_join.set()
                self.assertTrue(events.wait(lambda items: len(items) >= 3))
                self.assertEqual(events.items, [{"state": "ready"},
                                               {"text": "YY 中文&♫直播", "color": 0x13579b},
                                               {"text": "另一种推送", "color": 0xffffff}])
            finally:
                allow_guest.set()
                allow_join.set()
                stop()
            self.assertTrue(server.requests[0]["finished"].wait(1))
            packets = server.requests[0]["frames"]
            self.assertIn(b"yymwebh5", self.assert_yy(packets[0], 778244))
            self.assertIn(b"fixture-account", self.assert_yy(packets[1], 775684))
            self.assertEqual(self.assert_yy(packets[2], 538456), struct.pack("<QII", uid, 1, 31))
            join_body = self.assert_yy(packets[3], 513035)
            self.assertEqual(join_body[:8], struct.pack("<HIH", 0, 2048258, 0))
            self.assertIn(struct.pack("<IIIIQ", uid, top, sub, 0, uid), join_body)
            for packet, count in zip(packets[4:6], (6, 2)):
                groups = self.assert_yy(packet, 537944)
                self.assertEqual(struct.unpack_from("<QI", groups), (uid, count))
                self.assertIn(struct.pack("<IIII", 1, 0, top, 0), groups)
                self.assertIn(struct.pack("<IIII", 2, 0, sub, 0), groups)
            self.assertEqual((packets[6]["opcode"], packets[6]["payload"]), (10, b"yy-ping"))
            self.assertEqual(server.requests[0]["headers"]["origin"], "https://www.yy.com")
            self.assert_options(endpoint, "yy")
            query = parse_qs(urlsplit(endpoint.calls[0][0]).query)
            self.assertEqual(query["appid"], ["yymwebh5"])
            self.assertEqual(query["version"], ["3.2.14"])
            self.assertTrue(query["uuid"][0])

    def test_douyu_retry_resets_partial_decoder_relogs_and_marks_ready_again(self):
        events = EventLog()

        def peer(stream, observation):
            observation["frames"].extend(read_frame(stream) for _ in range(3))
            if observation["number"] == 0:
                stream.sendall(frame(douyu_packet("type@=mrkl/"), opcode=2)
                               + frame(douyu_packet("type@=chatmsg/txt@=discard/")[:15], opcode=2))
            else:
                stream.sendall(frame(douyu_packet("type@=chatmsg/txt@=恢复/col@=2/"), opcode=2))
                stream.recv(1)

        with self.connected(peer) as (server, endpoint):
            stop = self.author.subscribe(endpoint, {"platform": "douyu", "id": "54321"}, events.append)
            try:
                self.assertTrue(events.wait(lambda items: len(items) >= 4, 3))
                self.assertEqual(events.items, [{"state": "ready"},
                    {"state": "retrying", "msg": "彈幕連線中斷，等待恢復"}, {"state": "ready"},
                    {"text": "恢复", "color": 0x00ccff}])
            finally:
                stop()
            self.assertEqual(len(server.requests), 2)
            for observation in server.requests:
                self.assertTrue(observation["finished"].wait(1))
                self.assertEqual([self.assert_binary(packet) for packet in observation["frames"]], [
                    douyu_packet("type@=loginreq/roomid@=54321/"),
                    douyu_packet("type@=joingroup/rid@=54321/gid@=-9999/"), douyu_packet("type@=mrkl/")])
            self.assertEqual(len(endpoint.sockets), 1)
            self.assertFalse(events.wait(lambda items: len(items) > 4, 0.3))

    def test_original_emit_can_stop_from_socket_callback_under_helper_rlock(self):
        events, stopped = EventLog(), threading.Event()

        def peer(stream, observation):
            observation["frames"].extend(read_frame(stream) for _ in range(3))
            stream.sendall(frame(douyu_packet("type@=chatmsg/txt@=stop-now/"), opcode=2))
            stream.recv(1)

        with self.connected(peer) as (server, endpoint):
            def emit(event):
                events.append(event)
                if "text" in event:
                    subscription.stop()
                    stopped.set()

            subscription = self.author._Subscription(endpoint, {"platform": "douyu", "id": "9"}, emit)
            subscription.start()
            try:
                self.assertTrue(stopped.wait(1))
                self.assertTrue(subscription.stopped)
                self.assertIsNone(subscription.heartbeat)
                self.assertIsNone(subscription.decode)
                self.assertFalse(endpoint.sockets[0].send(b"late"))
                self.assertTrue(server.requests[0]["finished"].wait(1))
                self.assertEqual(events.items, [{"state": "ready"}, {"text": "stop-now", "color": 0xffffff}])
            finally:
                subscription.stop()

    def test_original_malformed_protocol_stops_in_callback_without_reconnect(self):
        cases = [({"platform": "douyu", "id": "9"}, 3, struct.pack("<III", 1, 2, 689)),
                 ({"platform": "huya", "uid": 1, "top": 2, "sub": 3}, 2, b"\xff"),
                 ({"platform": "yy", "top": 2, "sub": 3}, 1, struct.pack("<IIH", 1, 778500, 200))]
        for room, count, invalid in cases:
            events = EventLog()

            def peer(stream, observation):
                observation["frames"].extend(read_frame(stream) for _ in range(count))
                stream.sendall(frame(invalid, opcode=2))
                stream.recv(1)

            with self.subTest(platform=room["platform"]), self.connected(peer) as (server, endpoint):
                stop = self.author.subscribe(endpoint, room, events.append)
                try:
                    self.assertTrue(events.wait(bool))
                    self.assertEqual([item.get("state") for item in events.items], ["error"])
                    self.assertTrue(server.requests[0]["finished"].wait(1))
                    self.assertFalse(events.wait(lambda items: len(items) > 1, 0.3))
                    self.assertFalse(endpoint.sockets[0].send(b"late"))
                    self.assertEqual(len(server.requests), 1)
                finally:
                    stop()


if __name__ == "__main__":
    unittest.main()
