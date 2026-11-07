"""Loopback upstream and endpoint-only adapter for the original game vertical test."""

import argparse
import base64
from contextlib import ExitStack
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import struct
import sys
import threading
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
HELPERS = ("game_live_protocol.py", "game_live_stream.py", "game_live_yy.py")
HEADER = b"FLV\x01\x05\x00\x00\x00\x09\x00\x00\x00\x00"
PAYLOAD_SIZE = 90 * 1024


def flv_tag(stamp=0):
    payload = b"\x17\x01" + b"v" * (PAYLOAD_SIZE - 2)
    return (b"\x09" + len(payload).to_bytes(3, "big")
            + (stamp & 0xffffff).to_bytes(3, "big") + bytes((stamp >> 24,))
            + b"\x00\x00\x00" + payload + (len(payload) + 11).to_bytes(4, "big"))


def install(author_path, origin, ws_url, observations):
    """Change destinations only; original business functions and SDK execution stay intact."""
    from base.http_transport import HttpExchange
    from base.ws import WebSocketExchange

    path = Path(observations)
    lock = threading.Lock()

    def record(value):
        with lock, path.open("a", encoding="utf-8") as output:
            output.write(json.dumps({"pid": os.getpid(), **value}, ensure_ascii=False) + "\n")

    request = HttpExchange._request

    def route_http(exchange, url, method, body, headers):
        parsed = urlsplit(url)
        if parsed.hostname in ("mp.huya.com", "search.cdn.huya.com"):
            target = urlsplit(origin)
            routed = urlunsplit((target.scheme, target.netloc, parsed.path or "/", parsed.query, ""))
        elif parsed.hostname == "127.0.0.1" and parsed.port == urlsplit(origin).port:
            routed = url
        else:
            raise AssertionError("unmapped upstream is forbidden in the offline fixture")
        record({"kind": "http", "source": url, "destination": routed})
        return request(exchange, routed, method, body, headers)

    initialize_ws = WebSocketExchange.__init__

    def route_ws(exchange, url, headers, payload, timeout, limit):
        if urlsplit(url).hostname != "cdnws.api.huya.com":
            raise AssertionError("unmapped WebSocket is forbidden in the offline fixture")
        record({"kind": "ws", "source": url, "destination": ws_url})
        initialize_ws(exchange, ws_url, headers, payload, timeout, limit)

    HttpExchange._request = route_http
    WebSocketExchange.__init__ = route_ws
    spec = importlib.util.spec_from_file_location("unchanged_author_game_vertical", author_path)
    author = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(author)
    author.HUYA = origin
    record({"kind": "loaded", "author": str(author_path), "environment": {
        key: os.environ.get(key) for key in ("XIUGOU_SCRIPT_API", "XIUGOU_SCRIPT_ENTRY",
            "XIUGOU_SCRIPT_BASE", "XIUGOU_SCRIPT_SITE_KEY", "XIUGOU_SCRIPT_DANMAKU_BASE")}})
    return author.Spider


class Fixture:
    def __init__(self, root, author):
        self.root, self.author = root, author
        self.lock = threading.RLock()
        self.stopped = threading.Event()
        self.requests, self.streams, self.websockets, self.errors = [], [], [], []
        self.origin, self.ws_url = "", ""

    def wrapper(self):
        return ("import importlib.util\n"
                "spec = importlib.util.spec_from_file_location('author_game_endpoint_fixture', "
                + repr(str(Path(__file__).resolve())) + ")\n"
                "fixture = importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(fixture)\n"
                "Spider = fixture.install(" + ", ".join(map(repr, (
                    str(self.author), self.origin, self.ws_url,
                    str(self.root / "child-observations.jsonl")))) + ")\n").encode()

    def profile(self):
        anti = urlencode({"fm": base64.b64encode(b"$0_$1_$2_$3").decode(),
                          "ctype": "tars_mobile", "t": "100", "wsTime": "ffffffff"})
        return {"status": 200, "data": {"profileInfo": {"nick": "原作者虎牙", "profileRoom": "12345"},
            "realLiveStatus": "ON", "stream": {"baseSteamInfoList": [{
                "sCdnType": cdn, "iWebPriorityRate": priority, "sFlvUrl": self.origin + "/flv/" + cdn,
                "sStreamName": "live", "sFlvUrlSuffix": "flv", "sFlvAntiCode": anti,
                "lPresenterUid": 123456789, "lChannelId": 1024, "lSubChannelId": 2048,
            } for cdn, priority in (("A", 100), ("B", 50))]}}}

    def snapshot(self):
        with self.lock:
            return {"requests": list(self.requests), "errors": list(self.errors),
                    "streams": [{k: v for k, v in item.items() if k not in ("handler", "lock")}
                                for item in self.streams],
                    "websockets": [{k: v for k, v in item.items() if k not in ("socket", "lock")}
                                   for item in self.websockets]}

    def chunk(self, item, data):
        with item["lock"]:
            output = item["handler"].wfile
            output.write(("%x\r\n" % len(data)).encode() + data + b"\r\n")
            output.flush()

    def peer(self, stream, observation):
        from test_author_game_danmaku import huya_chat, tars_blob, tars_int, tars_text
        from test_runtime_ws import frame, read_frame
        login, pulse = read_frame(stream), read_frame(stream)
        room = (tars_int(0, 123456789) + tars_int(1, 1) + tars_text(2, "") + tars_text(3, "")
                + tars_int(4, 1024) + tars_int(5, 2048) + tars_int(6, 0) + tars_int(7, 0))
        if (not login["masked"] or login["opcode"] != 2 or login["payload"] != tars_int(0, 1) + tars_blob(1, room)
                or not pulse["masked"] or pulse["payload"] != b"\x00\x14\x1d\x00\x0c"):
            raise AssertionError("original Huya login/join/heartbeat did not reach the peer")
        item = {"socket": stream, "lock": threading.Lock(), "closed": False, "loginVerified": True}
        with self.lock:
            self.websockets.append(item)
        try:
            with item["lock"]:
                stream.sendall(frame(tars_int(0, 2) + tars_blob(1, tars_int(0, 0)), opcode=2)
                               + frame(huya_chat("原作者彩色弹幕", [0x112233, 0x445566]), opcode=2))
            while not self.stopped.is_set():
                if select.select([stream], [], [], 0.1)[0]:
                    packet = read_frame(stream)
                    if packet["opcode"] == 8:
                        break
        except (OSError, EOFError):
            pass
        finally:
            item["closed"] = True

    def chat(self, text):
        from test_author_game_danmaku import huya_chat
        from test_runtime_ws import frame
        with self.lock:
            peers = [item for item in self.websockets if not item["closed"]]
        for item in peers:
            with item["lock"]:
                item["socket"].sendall(frame(huya_chat(text, [], 0xabcdef), opcode=2))
        return len(peers)

    def close(self):
        self.stopped.set()
        with self.lock:
            sockets = ([item["handler"].connection for item in self.streams if not item["closed"]]
                       + [item["socket"] for item in self.websockets if not item["closed"]])
        for stream in sockets:
            try:
                stream.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, value, status=200, mime="application/json; charset=utf-8"):
        content = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        fixture = self.server.fixture
        parsed = urlsplit(self.path)
        params = parse_qs(parsed.query)
        path = parsed.path
        with fixture.lock:
            fixture.requests.append({"path": path, "query": params, "headers": dict(self.headers)})
        try:
            if path == "/status":
                self.reply(fixture.snapshot())
            elif path == "/chat":
                self.reply({"sent": fixture.chat(params["text"][0])})
            elif path == "/advance":
                cdn = params["cdn"][0]
                with fixture.lock:
                    items = [item for item in fixture.streams if item["cdn"] == cdn and not item["closed"]]
                for item in items:
                    fixture.chunk(item, flv_tag(1000))
                self.reply({"advanced": len(items)})
            elif path.startswith("/flv/"):
                self.live(path.split("/")[2])
            elif path == "/cache.php":
                if params != {"m": ["Live"], "do": ["profileRoom"], "roomid": ["12345"]}:
                    raise AssertionError("original room query changed")
                self.reply(fixture.profile())
            elif path == "/":
                if params.get("q") != ["主播 中文"] or params.get("start") != ["0"]:
                    raise AssertionError("original search query changed")
                self.reply({"responseHeader": {"status": 0}, "response": {"1": {"numFound": 1, "docs": [{
                    "room_id": "12345", "game_nick": "原作者虎牙", "live_intro": "离线直播",
                    "game_avatarUrl180": fixture.origin + "/unused.png", "gameLiveOn": True,
                }]}}})
            elif path.startswith(("/ordinary/", "/https://raw.githubusercontent.com/fixture/game/main/vod/")):
                name = path.rsplit("/", 1)[-1]
                if name in HELPERS:
                    self.reply(fixture.author.with_name(name).read_bytes(), mime="text/plain")
                elif name == "game_live.py":
                    self.reply(fixture.author.read_bytes() if path.startswith("/ordinary/") else fixture.wrapper(), mime="text/plain")
                else:
                    self.reply({"error": "unknown source"}, 404)
            else:
                self.reply({"error": "unexpected upstream path"}, 404)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass
        except Exception as error:
            with fixture.lock:
                fixture.errors.append(type(error).__name__ + ": " + str(error))
            self.close_connection = True

    def live(self, cdn):
        fixture = self.server.fixture
        item = {"cdn": cdn, "closed": False, "handler": self, "lock": threading.Lock(), "initialSent": False}
        self.send_response(200)
        self.send_header("Content-Type", "video/x-flv")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        with fixture.lock:
            fixture.streams.append(item)
        try:
            fixture.chunk(item, HEADER + flv_tag())
            item["initialSent"] = True
            self.connection.settimeout(0.2)
            while not fixture.stopped.is_set():
                try:
                    if not self.connection.recv(1):
                        break
                except socket.timeout:
                    continue
        finally:
            item["closed"] = True
            self.close_connection = True


def serve(root, author):
    from test_runtime_connect import connection_fixture
    fixture = Fixture(root, author)
    with ExitStack() as stack:
        ws = stack.enter_context(connection_fixture(fixture.peer))
        fixture.ws_url = ws.url
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        server.fixture = fixture
        fixture.origin = "http://127.0.0.1:" + str(server.server_port)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        thread.start()
        hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in (author, *(author.with_name(name) for name in HELPERS))}
        (root / "ready.json").write_text(json.dumps({"origin": fixture.origin, "wsUrl": fixture.ws_url,
            "author": str(author), "hashes": hashes, "fixturePid": os.getpid()}, ensure_ascii=False), encoding="utf-8")
        try:
            while not (root / "stop").exists():
                if fixture.stopped.wait(0.05):
                    break
        finally:
            fixture.close()
            server.shutdown()
            server.server_close()
            thread.join(2)
            if ws.errors:
                raise AssertionError(ws.errors)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--author", required=True, type=Path)
    args = parser.parse_args()
    serve(args.root.resolve(strict=True), args.author.resolve(strict=True))
