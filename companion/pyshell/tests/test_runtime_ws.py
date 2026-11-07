"""Local RFC6455 behavior tests for the single-message script API."""

import base64
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import socket
import socketserver
import ssl
import struct
import sys
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet  # noqa: E402


GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        piece = stream.recv(count - len(result))
        if not piece:
            raise EOFError("peer closed")
        result.extend(piece)
    return bytes(result)


def read_frame(stream):
    first, second = read_exact(stream, 2)
    length = second & 127
    if length == 126:
        length = struct.unpack("!H", read_exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(stream, 8))[0]
    if length > 8 * 1024 * 1024:
        raise ValueError("fixture refuses oversized client frame")
    mask = read_exact(stream, 4) if second & 128 else None
    payload = read_exact(stream, length)
    if mask is not None:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return {"fin": bool(first & 128), "opcode": first & 15,
            "masked": mask is not None, "payload": payload}


def frame(payload, opcode=1, fin=True):
    length = len(payload)
    first = (128 if fin else 0) | opcode
    if length < 126:
        header = bytes((first, length))
    elif length <= 65535:
        header = bytes((first, 126)) + struct.pack("!H", length)
    else:
        header = bytes((first, 127)) + struct.pack("!Q", length)
    return header + payload


class _WsHandler(socketserver.BaseRequestHandler):
    def handle(self):
        stream = self.request
        stream.settimeout(2)
        observation = {"frames": []}
        self.server.requests.append(observation)
        try:
            if self.server.tls_context is not None:
                stream = self.server.tls_context.wrap_socket(stream, server_side=True)
            raw = bytearray()
            while not raw.endswith(b"\r\n\r\n"):
                raw.extend(read_exact(stream, 1))
                if len(raw) > 32768:
                    raise ValueError("fixture handshake too large")
            lines = raw.decode("latin-1").split("\r\n")
            observation["request"] = lines[0]
            observation["headers"] = dict(
                (key.lower(), value.strip())
                for key, value in (line.split(":", 1) for line in lines[1:] if line)
            )
            self.server.connected.set()
            if self.server.on_handshake is not None:
                self.server.on_handshake(stream, observation)
                return
            accept = base64.b64encode(hashlib.sha1(
                (observation["headers"]["sec-websocket-key"] + GUID).encode("ascii")
            ).digest()).decode("ascii")
            stream.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                            "Sec-WebSocket-Accept: " + accept + "\r\n"
                            "X-Fixture: local\r\n\r\n").encode("ascii"))
            outgoing = read_frame(stream)
            observation["frames"].append(outgoing)
            self.server.received.set()
            if self.server.on_message is not None:
                self.server.on_message(stream, observation)
            else:
                stream.sendall(frame(self.server.message))
                observation["frames"].append(read_frame(stream))
        except (OSError, EOFError, ValueError, KeyError) as error:
            observation["error"] = type(error).__name__
        finally:
            stream.close()
            self.server.finished.set()


class _WsServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    block_on_close = False


@contextmanager
def websocket_fixture(message=b'{"status":201,"wsnode":"resolved-node"}',
                      on_handshake=None, on_message=None, tls_context=None):
    server = _WsServer(("127.0.0.1", 0), _WsHandler)
    server.tls_context = tls_context
    server.requests = []
    server.message = message
    server.on_handshake = on_handshake
    server.on_message = on_message
    server.connected = threading.Event()
    server.received = threading.Event()
    server.finished = threading.Event()
    server.url = "ws://127.0.0.1:" + str(server.server_address[1]) + "/connect?route=local%2Bvalue"
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


class RuntimeWebSocketTest(unittest.TestCase):
    def setUp(self):
        self.net = RuntimeNet()
        self.addCleanup(self.net.close)

    def test_json_exchange_preserves_signed_headers_masks_client_and_closes(self):
        with websocket_fixture() as server:
            response = self.net.ws(server.url, {
                "headers": {"X-ITOUCHTV-Ca-Signature": "signed+/=", "Origin": "https://node.invalid"},
                "data": {"route": "getwsparam", "message": "中文-node-1"},
                "timeout": 1000,
            })
            self.assertEqual(response["code"], 101)
            self.assertEqual(json.loads(response["content"]), {"status": 201, "wsnode": "resolved-node"})
            self.assertNotIn("error", response)
            self.assertEqual(response["headers"]["X-Fixture"], "local")
            self.assertTrue(server.finished.wait(1))
            request = server.requests[0]
            self.assertEqual(request["request"], "GET " + urlsplit(server.url).path
                             + "?route=local%2Bvalue HTTP/1.1")
            self.assertEqual(request["headers"]["x-itouchtv-ca-signature"], "signed+/=")
            self.assertEqual(request["headers"]["origin"], "https://node.invalid")
            self.assertNotIn("error", request)
            first, close = request["frames"]
            self.assertTrue(first["masked"])
            self.assertEqual(first["opcode"], 1)
            self.assertEqual(json.loads(first["payload"]), {"route": "getwsparam", "message": "中文-node-1"})
            self.assertTrue(close["masked"])
            self.assertEqual(close["opcode"], 8)
            self.assertEqual(close["payload"], struct.pack("!H", 1000))

    def test_fragmented_utf8_message_handles_interleaved_ping_and_pong(self):
        payload = '{"wsnode":"中文节点"}'.encode("utf-8")
        split = payload.index("中".encode("utf-8")) + 1

        def fragments(stream, observation):
            stream.sendall(frame(payload[:split], fin=False) + frame(b"keep-alive", opcode=9)
                           + frame(b"ignored", opcode=10)
                           + frame(payload[split:], opcode=0))
            observation["frames"].extend([read_frame(stream), read_frame(stream)])

        with websocket_fixture(on_message=fragments) as server:
            result = self.net.ws(server.url, {"data": {"route": "getwsparam"}})
            self.assertEqual(result["code"], 101)
            self.assertEqual(result["content"], payload.decode("utf-8"))
            self.assertTrue(server.finished.wait(1))
            sent, pong, close = server.requests[0]["frames"]
            self.assertEqual(pong, {"fin": True, "opcode": 10, "masked": True, "payload": b"keep-alive"})
            self.assertEqual(close["opcode"], 8)

    def test_first_complete_binary_message_is_returned_without_waiting_for_another(self):
        def binary(stream, observation):
            stream.sendall(frame(b"\x00\x80\xff", opcode=2) + frame(b"second message"))
            observation["frames"].append(read_frame(stream))

        with websocket_fixture(on_message=binary) as server:
            result = self.net.ws(server.url, {"data": {}})
            self.assertEqual(result["code"], 101)
            self.assertEqual(result["content"], b"\x00\x80\xff")
            self.assertTrue(server.finished.wait(1))
            self.assertEqual(server.requests[0]["frames"][-1]["opcode"], 8)

    def test_runtime_close_interrupts_handshake_or_receiving_and_is_idempotent(self):
        def wait_for_disconnect(stream, observation):
            observation["disconnected"] = stream.recv(1) == b""

        for stage in ("handshake", "message"):
            with self.subTest(stage=stage), websocket_fixture(
                    on_handshake=wait_for_disconnect if stage == "handshake" else None,
                    on_message=wait_for_disconnect if stage == "message" else None) as server:
                net = RuntimeNet()
                self.addCleanup(net.close)
                results = []
                worker = threading.Thread(target=lambda: results.append(
                    net.ws(server.url, {"data": {}, "timeout": 5000})), daemon=True)
                worker.start()
                ready = server.connected if stage == "handshake" else server.received
                self.assertTrue(ready.wait(1))
                start = time.monotonic()
                net.close()
                net.close()
                self.assertLess(time.monotonic() - start, 0.15)
                worker.join(timeout=0.5)
                self.assertFalse(worker.is_alive())
                self.assertEqual(results[0]["code"], 0)
                self.assertIn("error", results[0])
                self.assertTrue(server.finished.wait(1))
                self.assertTrue(server.requests[0]["disconnected"])
                with self.assertRaisesRegex(RuntimeError, "closed"):
                    net.ws(server.url)

    def test_timeout_uses_one_millisecond_deadline_across_handshake_and_receive(self):
        def delayed_handshake(stream, observation):
            threading.Event().wait(0.12)
            key = observation["headers"]["sec-websocket-key"]
            accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
            stream.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                            "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode("ascii"))
            read_frame(stream)
            threading.Event().wait(0.24)
            stream.sendall(frame(b"too late"))

        with websocket_fixture(on_handshake=delayed_handshake) as server:
            start = time.monotonic()
            result = self.net.ws(server.url + "&secret=do-not-log", {"data": {}, "timeout": 250})
            elapsed = time.monotonic() - start
            self.assertEqual(result["code"], 0)
            self.assertIn("TimeoutError", result["error"])
            self.assertNotIn("do-not-log", result["error"])
            self.assertLess(elapsed, 0.5)
            self.assertTrue(server.finished.wait(1))

    def test_handshake_refusal_preserves_http_status_and_headers(self):
        def refused(stream, observation):
            stream.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nX-Reason: denied\r\n\r\n")
            observation["after_refusal"] = stream.recv(1)

        with websocket_fixture(on_handshake=refused) as server:
            result = self.net.ws(server.url, {"data": {"secret": "not-sent"}})
            self.assertEqual(result, {"code": 403, "headers": {"Content-Length": "0", "X-Reason": "denied"},
                                      "content": ""})
            self.assertTrue(server.finished.wait(1))
            self.assertEqual(server.requests[0]["after_refusal"], b"")

    def test_handshake_rejects_bad_accept_headers_and_unsolicited_negotiation(self):
        for invalid in ("accept", "upgrade", "connection", "protocol", "extension", "duplicate", "oversize"):
            with self.subTest(invalid=invalid):
                def bad_handshake(stream, observation):
                    key = observation["headers"]["sec-websocket-key"]
                    accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
                    lines = ["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
                             "Sec-WebSocket-Accept: " + accept]
                    if invalid == "accept":
                        lines[-1] = "Sec-WebSocket-Accept: wrong"
                    elif invalid == "upgrade":
                        lines[1] = "Upgrade: http"
                    elif invalid == "connection":
                        lines[2] = "Connection: close"
                    elif invalid == "protocol":
                        lines.append("Sec-WebSocket-Protocol: unexpected")
                    elif invalid == "extension":
                        lines.append("Sec-WebSocket-Extensions: permessage-deflate")
                    elif invalid == "duplicate":
                        lines.append("sec-websocket-accept: " + accept)
                    else:
                        lines.append("X-Large: " + "x" * 32768)
                    stream.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("ascii"))

                with websocket_fixture(on_handshake=bad_handshake) as server:
                    result = self.net.ws(server.url, {"data": {}, "timeout": 1000})
                    self.assertEqual(result["code"], 0)
                    self.assertIn("error", result)

    def test_protocol_failures_send_correct_close_code_without_echoing_peer_data(self):
        bad_frames = [
            (b"\xc1\x00", 1002),
            (b"\x81\x80" + b"mask", 1002),
            (frame(b"", opcode=3), 1002),
            (frame(b"", opcode=0), 1002),
            (frame(b"a", fin=False) + frame(b"b"), 1002),
            (frame(b"ping", opcode=9, fin=False), 1002),
            (b"\x89\x7e" + struct.pack("!H", 126), 1002),
            (b"\x81\x7e\x00\x01", 1002),
            (b"\x82\x7f" + struct.pack("!Q", 126), 1002),
            (b"\x82\x7f" + struct.pack("!Q", 1 << 63), 1002),
            (frame(b"x", opcode=8), 1002),
            (frame(struct.pack("!H", 1005), opcode=8), 1002),
            (frame(struct.pack("!H", 5000), opcode=8), 1002),
            (frame(struct.pack("!H", 1000) + b"\xff", opcode=8), 1007),
            (frame(b"\xffsecret-token"), 1007),
            (b"\x82\x7f" + struct.pack("!Q", 8 * 1024 * 1024 + 1), 1009),
        ]
        for index, (wire, close_code) in enumerate(bad_frames):
            with self.subTest(index=index):
                def invalid_message(stream, observation):
                    stream.sendall(wire)
                    observation["frames"].append(read_frame(stream))

                with websocket_fixture(on_message=invalid_message) as server:
                    result = self.net.ws(server.url, {"data": {}, "timeout": 1000})
                    self.assertEqual(result["code"], 0)
                    self.assertIn("error", result)
                    self.assertNotIn("secret-token", result["error"])
                    self.assertTrue(server.finished.wait(1))
                    self.assertNotIn("error", server.requests[0])
                    close = server.requests[0]["frames"][-1]
                    self.assertEqual(close["opcode"], 8)
                    self.assertTrue(close["masked"])
                    self.assertEqual(close["payload"], struct.pack("!H", close_code))

    def test_close_before_message_is_acknowledged_and_eof_is_a_failure(self):
        close_payload = struct.pack("!H", 1001) + b"private-peer-reason"

        def closed(stream, observation):
            stream.sendall(frame(close_payload, opcode=8))
            observation["frames"].append(read_frame(stream))

        with websocket_fixture(on_message=closed) as server:
            result = self.net.ws(server.url, {"data": {}})
            self.assertEqual(result["code"], 0)
            self.assertNotIn("private-peer-reason", result["error"])
            self.assertTrue(server.finished.wait(1))
            self.assertEqual(server.requests[0]["frames"][-1]["payload"], close_payload)
        with websocket_fixture(on_message=lambda stream, observation: None) as server:
            result = self.net.ws(server.url, {"data": {}})
            self.assertEqual(result["code"], 0)
            self.assertIn("EOFError", result["error"])

    def test_extended_lengths_and_aggregate_fragment_limit(self):
        for size in (126, 65536):
            with self.subTest(size=size), websocket_fixture(message=b"x" * size) as server:
                result = self.net.ws(server.url, {"data": {"message": "x" * size}})
                self.assertEqual(result["code"], 101)
                self.assertEqual(result["content"], "x" * size)
                self.assertTrue(server.finished.wait(1))
                self.assertEqual(json.loads(server.requests[0]["frames"][0]["payload"])["message"], "x" * size)

        def too_many_fragments(stream, observation):
            stream.sendall(frame(b"x" * (8 * 1024 * 1024), opcode=2, fin=False)
                           + frame(b"x", opcode=0))
            observation["frames"].append(read_frame(stream))

        with websocket_fixture(on_message=too_many_fragments) as server:
            result = self.net.ws(server.url, {"data": {}, "timeout": 1500})
            self.assertEqual(result["code"], 0)
            self.assertTrue(server.finished.wait(1))
            self.assertEqual(server.requests[0]["frames"][-1]["payload"], struct.pack("!H", 1009))

    def test_invalid_options_fail_before_any_connection(self):
        invalid = [
            {"data": []}, {"data": None}, {"data": {"n": float("nan")}},
            {"data": {"large": "x" * (8 * 1024 * 1024)}},
            {"timeout": 0}, {"timeout": True}, {"timeout": float("inf")},
            {"headers": {"X-Test": "bad\r\nvalue"}},
            {"headers": {"Sec-WebSocket-Key": "override"}},
            {"headers": {"Host": "other-host"}}, {"buffer": 3}, {"reconnect": True},
        ]
        with websocket_fixture() as server:
            for options in invalid:
                with self.subTest(keys=list(options)), self.assertRaises((ValueError, TypeError, NotImplementedError)):
                    self.net.ws(server.url, options)
            for url in ("http://127.0.0.1/", "ws://user:secret@127.0.0.1/", "ws://127.0.0.1/#fragment",
                        "ws://127.0.0.1:0/", "ws://127.0.0.1:99999/", "ws://127.0.0.1/\n"):
                with self.subTest(url=url), self.assertRaises(ValueError):
                    self.net.ws(url, {"data": {}})
            self.assertEqual(server.requests, [])

    def test_deadline_and_close_bound_blocked_name_resolution(self):
        real_resolver = socket.getaddrinfo
        for cancel in (False, True):
            started, release = threading.Event(), threading.Event()

            def blocked_resolver(*args, **kwargs):
                started.set()
                release.wait(2)
                return real_resolver("127.0.0.1", 1, type=socket.SOCK_STREAM)

            net = RuntimeNet()
            results = []
            with self.subTest(cancel=cancel), patch("base.ws.socket.getaddrinfo", side_effect=blocked_resolver):
                worker = threading.Thread(target=lambda: results.append(
                    net.ws("ws://resolver.invalid/", {"data": {}, "timeout": 100 if not cancel else 5000})), daemon=True)
                try:
                    worker.start()
                    self.assertTrue(started.wait(1))
                    if cancel:
                        net.close()
                    worker.join(timeout=0.4)
                    self.assertFalse(worker.is_alive(), "caller must not wait for the system resolver")
                    self.assertEqual(results[0]["code"], 0)
                    self.assertIn("error", results[0])
                finally:
                    release.set()
                    net.close()
                    worker.join(timeout=1)

    def test_wss_checks_trust_and_hostname_and_exchanges_with_a_trusted_peer(self):
        certificate = Path(sys.base_prefix) / "Lib" / "test" / "certdata" / "keycert.pem"
        if not certificate.is_file():
            self.skipTest("CPython localhost TLS test certificate is not installed")
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(certificate)
        original_context = ssl.create_default_context
        trusted_contexts = []

        def trust_fixture_only():
            context = original_context(cafile=certificate)
            trusted_contexts.append(context)
            return context

        with websocket_fixture(tls_context=server_context) as server:
            url = server.url.replace("ws://", "wss://")
            result = self.net.ws(url, {"data": {}, "timeout": 2000})
            self.assertEqual(result["code"], 0)
            self.assertIn("SSLCertVerificationError", result["error"], server.requests)
            self.assertTrue(server.finished.wait(1))
        real_resolver = socket.getaddrinfo

        def resolve_localhost_on_fixture_interface(host, port, **kwargs):
            return real_resolver("127.0.0.1" if host == "localhost" else host, port, **kwargs)

        with patch("base.ws.ssl.create_default_context", side_effect=trust_fixture_only), \
                patch("base.ws.socket.getaddrinfo", side_effect=resolve_localhost_on_fixture_interface):
            with websocket_fixture(tls_context=server_context) as server:
                url = server.url.replace("ws://127.0.0.1:", "wss://localhost:")
                result = self.net.ws(url, {"data": {}, "timeout": 2000})
                self.assertEqual(result["code"], 101, result)
                self.assertEqual(json.loads(result["content"])["status"], 201)
            with websocket_fixture(tls_context=server_context) as server:
                result = self.net.ws(server.url.replace("ws://", "wss://"), {"data": {}, "timeout": 2000})
                self.assertEqual(result["code"], 0)
                self.assertIn("SSLCertVerificationError", result["error"])
                self.assertTrue(server.finished.wait(1))
        for context in trusted_contexts:
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(context.check_hostname)

    def test_omitted_data_waits_for_server_message_without_sending_a_data_frame(self):
        def unsolicited(stream, observation):
            key = observation["headers"]["sec-websocket-key"]
            accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
            stream.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                            "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode("ascii")
                            + frame(b"server-first"))
            observation["frames"].append(read_frame(stream))

        with websocket_fixture(on_handshake=unsolicited) as server:
            result = self.net.ws(server.url)
            self.assertEqual(result["code"], 101)
            self.assertEqual(result["content"], "server-first")
            self.assertTrue(server.finished.wait(1))
            self.assertEqual([item["opcode"] for item in server.requests[0]["frames"]], [8])


if __name__ == "__main__":
    unittest.main()
