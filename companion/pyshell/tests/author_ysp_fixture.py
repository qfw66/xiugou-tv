"""Local HTTP peers for the unchanged Yangshipin author script."""

import base64
from contextlib import contextmanager, ExitStack
from dataclasses import dataclass, field
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import threading
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from base.http_transport import HttpExchange


DEFAULT_AUTHOR = Path(r"E:\code\tvbox_1102\live-python-20261107\live\yangshipin.py")
AUTHOR_SHA256 = "67c66cf3f36723f41eb1e10ca0f48a11f24a69eb81c6ccf46e64aea45e75c850"
TV_PID = "600001859"
CNLID = "2000210103"
MEDIA = "https://fixture.cctv.cn"
SNAPSHOT = "https://fixture.yangshipin.cn/snapshot"


def load_author(source):
    spec = importlib.util.spec_from_file_location("xiugou_author_yangshipin_fixture", source)
    author = importlib.util.module_from_spec(spec)
    with patch.object(sys, "dont_write_bytecode", True):
        spec.loader.exec_module(author)
    return author


@contextmanager
def route_to_local(origin):
    """Change only socket destination; preserve URL, Host, cookies and HTTP handling."""
    connect = HttpExchange._connect
    local = urlsplit(origin)
    if local.scheme != "http" or local.hostname != "127.0.0.1" or not local.port:
        raise ValueError("fixture transport requires an explicit loopback origin")

    def connect_locally(exchange, parsed):
        return connect(exchange, local)

    with patch.object(HttpExchange, "_connect", connect_locally):
        yield


@dataclass
class Reply:
    content: bytes = b""
    status: int = 200
    mime: str = "application/octet-stream"
    headers: dict = field(default_factory=dict)


def json_reply(value, status=200, headers=None):
    return Reply(json.dumps(value, ensure_ascii=False).encode("utf-8"), status,
                 "application/json; charset=utf-8", headers or {})


class _YspHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self._respond()

    def do_POST(self):
        self._respond()

    def _respond(self):
        fixture = self.server.fixture
        parsed = urlsplit(self.path)
        request = {
            "method": self.command,
            "host": self.headers["Host"],
            "target": self.path,
            "path": parsed.path,
            "query": parse_qs(parsed.query, keep_blank_values=True),
            "headers": {key.lower(): value for key, value in self.headers.items()},
            "body": self.rfile.read(int(self.headers.get("Content-Length", "0"))),
        }
        fixture.requests.append(request)
        route = fixture.routes.get((request["host"], request["path"]))
        if route is None:
            fixture.errors.append("unregistered fixture route: " + request["host"] + request["path"])
            reply = Reply(b"fixture route not found", 404, "text/plain")
        else:
            try:
                reply = route(request) if callable(route) else route
            except Exception as error:
                fixture.errors.append(repr(error))
                reply = Reply(b"fixture peer assertion failed", 500, "text/plain")
        self.send_response(reply.status)
        self.send_header("Content-Type", reply.mime)
        self.send_header("Content-Length", str(len(reply.content)))
        for key, value in reply.headers.items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(reply.content)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


class YspFixture:
    def __init__(self):
        self.requests = []
        self.routes = {}
        self.errors = []

    def __enter__(self):
        self.stack = ExitStack()
        self.local_dir = self.stack.enter_context(tempfile.TemporaryDirectory(prefix="author-ysp-"))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _YspHandler)
        self.server.fixture = self
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        self.stack.callback(self._close_server)
        self.origin = "http://127.0.0.1:" + str(self.server.server_port)
        self.stack.enter_context(route_to_local(self.origin))
        self.stack.enter_context(patch.dict(os.environ, {
            "XIUGOU_SCRIPT_PROXY_BASE": self.origin + "/script-proxy?token=ysp%2Bfixture",
            "XIUGOU_SCRIPT_SITE_KEY": "author-yangshipin",
            "XIUGOU_LOCAL_DIR": self.local_dir,
            "XIUGOU_CACHE_DIR": "",
        }))
        return self

    def _close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def __exit__(self, *args):
        return self.stack.__exit__(*args)

    def reply(self, url, response):
        parsed = urlsplit(url)
        self.routes[(parsed.netloc, parsed.path or "/")] = response

    def json(self, url, value, status=200, headers=None):
        self.reply(url, json_reply(value, status, headers))

    def matching(self, url):
        parsed = urlsplit(url)
        return [request for request in self.requests
                if (request["host"], request["path"]) == (parsed.netloc, parsed.path or "/")]


def _varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def _field(number, value):
    if isinstance(value, int):
        return _varint(number << 3) + _varint(value)
    if isinstance(value, str):
        value = value.encode("utf-8")
    return _varint((number << 3) | 2) + _varint(len(value)) + value


def catalog_replies(channels, feed="fixture-tv"):
    """Encode wire responses so the author performs its real protobuf decoding."""
    navigation = _field(1, 200) + _field(2, _field(2,
        _field(1, "电视") + _field(4, feed) + _field(10, 2)))
    rows = []
    for channel in channels:
        rows.append(_field(15, b"".join([
            _field(2, channel["name"]), _field(4, str(channel["pid"])),
            _field(6, str(channel["cnlid"])), _field(5, channel.get("logo", "")),
            _field(7, int(channel.get("vip", False))), _field(11, channel.get("type", "yangshi")),
        ])))
    page = _field(1, 200) + _field(2, _field(2, _field(2, "tvChannel") + b"".join(rows)))
    return Reply(navigation), Reply(page)


def _checksum(data):
    result = 0
    for byte in data:
        result = (result * 131 + byte) & 0x7fffffff
    return result


def _tea_decode(ciphertext, key):
    words = struct.unpack(">4I", key)
    previous_mixed = previous_cipher = bytes(8)
    plaintext = bytearray()
    for offset in range(0, len(ciphertext), 8):
        block = ciphertext[offset:offset + 8]
        left, right = struct.unpack(">2I", bytes(a ^ b for a, b in zip(block, previous_mixed)))
        for round_number in range(16, 0, -1):
            total = (round_number * 0x9e3779b9) & 0xffffffff
            right = (right - (((left * 16) + words[2]) ^ (left + total) ^ ((left >> 5) + words[3]))) & 0xffffffff
            left = (left - (((right * 16) + words[0]) ^ (right + total) ^ ((right >> 5) + words[1]))) & 0xffffffff
        mixed = struct.pack(">2I", left, right)
        plaintext.extend(a ^ b for a, b in zip(mixed, previous_cipher))
        previous_mixed, previous_cipher = mixed, block
    if plaintext[-7:] != bytes(7):
        raise ValueError("App cKey TEA padding is invalid")
    return bytes(plaintext[(plaintext[0] & 7) + 3:-7])


def _unmask_packet(encoded, mask, key):
    decoded = bytes(byte ^ mask[index % len(mask)] for index, byte in enumerate(encoded))
    packet = _tea_decode(decoded[:-4], key)
    if _checksum(packet) != int.from_bytes(decoded[-4:], "big"):
        raise ValueError("App cKey checksum is invalid")
    if int.from_bytes(packet[:2], "big") != len(packet) - 2:
        raise ValueError("App cKey packet length is invalid")
    return packet


def decode_app_ckey(value):
    """Decrypt the outbound TEA packet independently and expose its semantic fields."""
    if not value.startswith("--01"):
        raise ValueError("App cKey prefix is invalid")
    encoded = value[4:].replace("_", "+").replace("-", "/")
    packet = _unmask_packet(base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True),
                           bytes.fromhex("842eed08f066e6ea48b4caa991ed6ff3"),
                           bytes.fromhex("59b2f7cf725ef43c34fdd7c123411ed3"))
    if packet[2:14] != bytes.fromhex("0000004200000004000004d2"):
        raise ValueError("App cKey version header is invalid")
    expected = bytearray(packet)
    expected[18:22] = bytes(4)
    if _checksum(expected) != int.from_bytes(packet[18:22], "big"):
        raise ValueError("App cKey embedded checksum is invalid")

    def fields(data, start, count):
        values = []
        for _ in range(count):
            length = int.from_bytes(data[start:start + 2], "big")
            start += 2
            values.append(data[start:start + length].decode("utf-8"))
            start += length
        return values, start

    initial, position = fields(packet, 26, 5)
    flags = struct.unpack_from(">2I", packet, position)
    extra, position = fields(packet, position + 8, 10)
    if position != len(packet):
        raise ValueError("App cKey trailing fields are invalid")
    guard = _unmask_packet(bytes.fromhex(extra[-1]), bytes.fromhex("b3c953a06913ad4d"),
                           bytes.fromhex("110dbec10c23e7d2e56a1cad6914ef1b"))
    guard_fields, guard_end = fields(guard, 6, 4)
    if guard_end != len(guard):
        raise ValueError("App cKey guard length is invalid")
    return {
        "platform": int.from_bytes(packet[14:18], "big"),
        "timestamp": int.from_bytes(packet[22:26], "big"),
        "source": initial[0], "version": initial[2], "cnlid": initial[3], "guid": initial[4],
        "flags": flags, "package": extra[5],
        "guard_timestamp": int.from_bytes(guard[2:6], "big"), "guard_fields": guard_fields,
    }


def web_wasm():
    """Reuse the ABI worker's module, echoing state.token with a legal custom pad."""
    from test_wasm_compatibility import WASM
    source = b"cctvh5openapi.state.probe"
    assert WASM.count(source) == 1
    payload = _varint(7) + b"fixture" + bytes(20000)
    return (WASM.replace(source, b"cctvh5openapi.state.token")
            + b"\0" + _varint(len(payload)) + payload)


def ts_payload(packets=28000):
    return (b"\x47" + bytes((index * 17) % 256 for index in range(187))) * packets


def _seal(value, key):
    from Crypto.Cipher import AES
    cipher = AES.new(key.encode().ljust(32, b"\0")[:32], AES.MODE_GCM, nonce=os.urandom(12))
    ciphertext, tag = cipher.encrypt_and_digest(value.encode("utf-8"))
    return base64.b64encode(cipher.nonce + ciphertext + tag).decode("ascii")


def _unseal(value, key):
    from Crypto.Cipher import AES
    raw = base64.b64decode(value, validate=True)
    cipher = AES.new(key.encode().ljust(32, b"\0")[:32], AES.MODE_GCM, nonce=raw[:12])
    return cipher.decrypt_and_verify(raw[12:-16], raw[-16:]).decode("utf-8")


class TvPeer:
    """Stateful local TV service requiring the author's real RSA/AES/signature flow."""
    def __init__(self, fixture, author):
        self.fixture, self.author = fixture, author
        self.devices = {}
        self.identities = []
        self.session_key = "fixture-tv-session-key"
        self.secret = "fixture-play-secret"
        self.playlist = MEDIA + "/tv/high.m3u8"
        fixture.reply(author.TV_BASE + "api/app/start/v1/01", self.start)
        fixture.reply(author.TV_CLOUD + "get", self.get)
        fixture.reply(author.TV_CLOUD + "register", self.register)
        fixture.reply(author.TV_REPORT, self.heartbeat)
        fixture.reply(author.TV_BASE + "api/live/v1/01", self.videos)
        fixture.reply(author.TV_BASE + "api/live/v1/02", self.authorize)
        fixture.reply(author.TV_VDN, self.vdn)
        fixture.reply(self.playlist, Reply(b"#EXTM3U\n#EXTINF:6,\nsegment.ts\n", mime=author.HLS_MIME))
        fixture.reply(MEDIA + "/tv/segment.ts", Reply(ts_payload(3), mime="video/mp2t"))

    def start(self, request):
        body = json.loads(request["body"])
        assert body["key"] == "app_start_d1"
        identity = {key: body["value"][key] for key in ("android_id", "mac")}
        self.identities.append(identity)
        timestamp = int(request["headers"]["x-timestamp"])
        day0 = ((timestamp // 1000 + 28800) // 86400) * 86400000 - 28800000
        digest = hashlib.sha256((self.author.TV_APP_ID + request["headers"]["x-uid"]
                                 + str(timestamp) + str(day0)).encode()).hexdigest()
        fingerprint = hashlib.sha256(digest.encode()).hexdigest()
        assert request["headers"]["x-fingerprint"] == fingerprint
        return json_reply({"result": 0, "data": {"key": _seal(self.session_key, fingerprint[:32])}})

    def get(self, request):
        body = json.loads(request["body"])
        assert len(base64.b64decode(body["device_id"], validate=True)) == 256
        uid = request["headers"]["x-uid"]
        if uid not in self.devices:
            return json_reply({"result": "601"}, 400)
        return json_reply({"result": "0", "data": {"guid": self.devices[uid]}})

    def register(self, request):
        body = json.loads(request["body"])
        assert body["device_name"] == "央视频电视投屏助手"
        assert len(base64.b64decode(body["device_id"], validate=True)) == 256
        uid = request["headers"]["x-uid"]
        assert uid not in self.devices
        self.devices[uid] = "fixture-device-" + str(len(self.devices) + 1)
        return json_reply({"result": "0", "data": {"guid": self.devices[uid]}})

    def heartbeat(self, request):
        body = json.loads(request["body"])
        assert body["key"] == "app_heartbeat"
        assert body["value"]["guid"] == self.devices[request["headers"]["x-uid"]]
        return json_reply({"result": 0})

    def videos(self, request):
        assert json.loads(request["body"])["id"] == self.author.TV_CHANNELS[TV_PID]
        return json_reply({"result": 0, "data": {"videoList": [
            {"rate": "10p", "url": MEDIA + "/tv/low.m3u8"},
            {"rate": "36p", "url": _seal(self.playlist, self.session_key)},
        ]}})

    def authorize(self, request):
        assert _unseal(json.loads(request["body"])["guid"], self.session_key) == ""
        return json_reply({"result": 0, "data": {"appSecret": _seal(self.secret, self.session_key)}})

    def vdn(self, request):
        body = parse_qs(request["body"].decode("utf-8"))
        assert body["url"] == [self.playlist]
        assert json.loads(body["appcommon"][0])["an"] == "央视频电视投屏助手"
        random = request["headers"]["apprandomstr"]
        signature = hashlib.md5((self.author.TV_APP_ID + self.secret + random).encode()).hexdigest()
        assert request["headers"]["appid"] == self.author.TV_APP_ID
        assert request["headers"]["appsign"] == signature
        return json_reply({"succeed": 1, "url": self.playlist})
