"""Loopback checks for the owned, persistent WebSocket callback contract."""

import base64
from contextlib import contextmanager
import hashlib
from pathlib import Path
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.ws_connection import WebSocketConnection  # noqa: E402
from test_runtime_ws import GUID, frame, read_exact, read_frame  # noqa: E402


class EventLog:
    def __init__(self):
        self.items = []
        self.condition = threading.Condition()

    def append(self, item):
        with self.condition:
            self.items.append(item)
            self.condition.notify_all()

    def wait(self, predicate, timeout=2):
        with self.condition:
            return self.condition.wait_for(lambda: predicate(self.items), timeout)


def upgrade(stream, observation):
    accept = base64.b64encode(hashlib.sha1(
        (observation["headers"]["sec-websocket-key"] + GUID).encode("ascii")
    ).digest()).decode("ascii")
    stream.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                    "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode("ascii"))


class _ConnectionHandler(socketserver.BaseRequestHandler):
    def handle(self):
        stream = self.request
        stream.settimeout(2)
        with self.server.lock:
            observation = {"number": len(self.server.requests), "frames": [], "finished": threading.Event()}
            self.server.requests.append(observation)
        try:
            if self.server.before_handshake is not None:
                self.server.before_handshake(stream, observation)
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
            if self.server.handshake is None:
                upgrade(stream, observation)
            else:
                self.server.handshake(stream, observation)
            self.server.script(stream, observation)
        except (OSError, EOFError) as error:
            observation["error"] = type(error).__name__
        except Exception as error:
            self.server.errors.append(error)
        finally:
            stream.close()
            observation["finished"].set()


class _ConnectionServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    block_on_close = False


@contextmanager
def connection_fixture(script, handshake=None, before_handshake=None, tls_context=None):
    server = _ConnectionServer(("127.0.0.1", 0), _ConnectionHandler)
    server.lock = threading.Lock()
    server.requests, server.errors = [], []
    server.script, server.handshake = script, handshake
    server.before_handshake, server.tls_context = before_handshake, tls_context
    server.url = "ws://127.0.0.1:" + str(server.server_address[1]) + "/danmaku?route=a%2Bb"
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)
    if server.errors:
        raise AssertionError(server.errors)


@contextmanager
def local_tls_certificate():
    certificate = Path(sys.base_prefix) / "Lib" / "test" / "certdata" / "keycert.pem"
    if certificate.is_file():
        yield certificate, None
        return
    openssl = shutil.which("openssl")
    if openssl is None:
        raise unittest.SkipTest("local TLS fixture needs the CPython test certificate or OpenSSL")
    with tempfile.TemporaryDirectory(prefix="runtime-connect-tls-") as directory:
        certificate, key = Path(directory) / "localhost.pem", Path(directory) / "localhost.key"
        config = Path(directory) / "openssl.cnf"
        config.write_text("[req]\ndistinguished_name=dn\n[dn]\nCN=localhost\n", encoding="ascii")
        subprocess.run([openssl, "req", "-config", str(config), "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
                        "-keyout", str(key), "-out", str(certificate)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        yield certificate, key


class RuntimeConnectionTest(unittest.TestCase):
    def connection(self, url, options=None, callback=None):
        events, released = EventLog(), EventLog()

        def receive(connection, event):
            events.append(event)
            if callback is not None:
                callback(connection, event)

        connection = WebSocketConnection(url, options, receive, released.append)
        self.addCleanup(connection.cancel)
        return connection, events, released

    def test_start_returns_self_binary_send_and_multiple_messages_then_close(self):
        def peer(stream, observation):
            observation["frames"].append(read_frame(stream))
            stream.sendall(frame(b"\x00\x80\xff", opcode=2) + frame("中文".encode())
                           + frame(struct.pack("!H", 1000), opcode=8))
            observation["frames"].append(read_frame(stream))

        def opened(connection, event):
            if event["type"] == "open":
                self.assertTrue(connection.send(b"login"))

        with connection_fixture(peer) as server:
            connection, events, released = self.connection(server.url, callback=opened)
            self.assertIs(connection.start(), connection)
            self.assertTrue(released.wait(bool))
            self.assertEqual(released.items, [connection])
            self.assertEqual([event["type"] for event in events.items], ["open", "message", "message", "close"])
            self.assertEqual(events.items[1], {"type": "message", "binary": True, "content": b"\x00\x80\xff"})
            self.assertEqual(events.items[2], {"type": "message", "binary": False, "content": "中文"})
            self.assertTrue(server.requests[0]["finished"].wait(1))
            login, close = server.requests[0]["frames"]
            self.assertEqual(login, {"fin": True, "masked": True, "opcode": 2, "payload": b"login"})
            self.assertEqual(close["opcode"], 8)
            self.assertTrue(close["masked"])
            self.assertFalse(connection.send(b"late"))
            connection.cancel()
            connection.close()
            self.assertEqual(released.items, [connection])

    def test_fragmented_binary_and_utf8_control_frames_and_headers(self):
        binary = b"\x00\xff" * 32768
        text = "fragment中文".encode()

        def peer(stream, observation):
            stream.sendall(frame(binary[:40000], opcode=2, fin=False) + frame(b"pulse", opcode=9)
                           + frame(b"ignore", opcode=10) + frame(binary[40000:], opcode=0)
                           + frame(text[:-2], fin=False) + frame(text[-2:], opcode=0)
                           + frame(struct.pack("!H", 1000), opcode=8))
            observation["frames"].extend([read_frame(stream), read_frame(stream)])

        with connection_fixture(peer) as server:
            connection, events, released = self.connection(server.url, {
                "headers": {"Origin": "https://www.yy.com", "X-Signature": "a+/="}})
            connection.start()
            self.assertTrue(released.wait(bool))
            self.assertEqual([item["content"] for item in events.items if item["type"] == "message"],
                             [binary, text.decode()])
            request = server.requests[0]
            self.assertTrue(request["finished"].wait(1))
            self.assertEqual(request["request"], "GET /danmaku?route=a%2Bb HTTP/1.1")
            self.assertEqual(request["headers"]["origin"], "https://www.yy.com")
            self.assertEqual(request["headers"]["x-signature"], "a+/=")
            self.assertEqual(request["frames"][0], {"fin": True, "opcode": 10, "masked": True, "payload": b"pulse"})
            self.assertEqual(request["frames"][1]["opcode"], 8)

    def test_concurrent_heartbeat_callback_and_pong_writes_are_whole_masked_frames(self):
        count = 20
        sent = EventLog()
        workers = []
        heartbeat = [bytes((index,)) * 65536 for index in range(count)]
        replies = [b"callback-" + str(index).encode() for index in range(count)]

        def peer(stream, observation):
            stream.sendall(b"".join(frame(item, opcode=2) for item in replies) + frame(b"ping", opcode=9))
            observation["frames"].extend(read_frame(stream) for _ in range(count * 2 + 1))
            stream.sendall(frame(struct.pack("!H", 1000), opcode=8))
            observation["frames"].append(read_frame(stream))

        def receive(connection, event):
            if event["type"] == "open":
                worker = threading.Thread(target=lambda: [sent.append(connection.send(item)) for item in heartbeat],
                                          daemon=True)
                workers.append(worker)
                worker.start()
            elif event["type"] == "message":
                sent.append(connection.send(event["content"]))

        with connection_fixture(peer) as server:
            connection, events, released = self.connection(server.url, callback=receive)
            connection.start()
            self.assertTrue(released.wait(bool, 4))
            for worker in workers:
                worker.join(timeout=1)
                self.assertFalse(worker.is_alive())
            self.assertEqual(sent.items, [True] * (count * 2))
            self.assertTrue(server.requests[0]["finished"].wait(1))
            frames = server.requests[0]["frames"]
            self.assertTrue(all(item["masked"] for item in frames))
            self.assertCountEqual([item["payload"] for item in frames if item["opcode"] == 2], heartbeat + replies)
            self.assertEqual([item["payload"] for item in frames if item["opcode"] == 10], [b"ping"])
            self.assertEqual(frames[-1]["opcode"], 8)

    def test_reader_errors_send_protocol_close_and_never_deliver_partial_messages(self):
        invalid = [
            (b"\xc2\x00", 1002), (b"\x82\x80mask", 1002),
            (frame(b"", opcode=0), 1002), (frame(b"", opcode=3), 1002),
            (frame(b"a", opcode=2, fin=False) + frame(b"b", opcode=2), 1002),
            (frame(b"ping", opcode=9, fin=False), 1002),
            (b"\x89\x7e\x00\x7e", 1002), (b"\x82\x7e\x00\x01", 1002),
            (b"\x82\x7f" + struct.pack("!Q", 1 << 63), 1002),
            (b"\x82\x7f" + struct.pack("!Q", 8 * 1024 * 1024 + 1), 1009),
            (frame(b"secret\xff"), 1007), (frame(b"x", opcode=8), 1002),
            (frame(struct.pack("!H", 1005), opcode=8), 1002),
            (frame(struct.pack("!H", 1000) + b"\xff", opcode=8), 1007),
        ]
        for wire, code in invalid:
            def peer(stream, observation):
                stream.sendall(wire)
                observation["frames"].append(read_frame(stream))

            with self.subTest(wire=wire), connection_fixture(peer) as server:
                connection, events, released = self.connection(server.url)
                connection.start()
                self.assertTrue(released.wait(bool))
                self.assertEqual([item["type"] for item in events.items], ["open", "error"])
                self.assertNotIn("secret", events.items[-1]["error"])
                self.assertTrue(server.requests[0]["finished"].wait(1))
                self.assertEqual(server.requests[0]["frames"][0]["payload"], struct.pack("!H", code))

    def test_handshake_timeout_is_not_total_lifetime_and_activity_refreshes_idle(self):
        def peer(stream, observation):
            for item in (b"one", b"two", b"three"):
                threading.Event().wait(0.12)
                stream.sendall(frame(item, opcode=2))
            stream.sendall(frame(struct.pack("!H", 1000), opcode=8))
            observation["frames"].append(read_frame(stream))

        with connection_fixture(peer) as server:
            connection, events, released = self.connection(server.url, {"timeout": 100, "idle": 250})
            connection.start()
            self.assertTrue(released.wait(bool))
            self.assertEqual([item["content"] for item in events.items if item["type"] == "message"],
                             [b"one", b"two", b"three"])
            self.assertEqual(events.items[-1]["type"], "close")

    def test_outbound_heartbeats_do_not_postpone_receive_idle_timeout(self):
        stop = threading.Event()
        workers = []

        def peer(stream, observation):
            while True:
                observation["frames"].append(read_frame(stream))

        def receive(connection, event):
            if event["type"] == "open":
                def beat():
                    while not stop.wait(0.02):
                        if not connection.send(b"heartbeat"):
                            break
                worker = threading.Thread(target=beat, daemon=True)
                workers.append(worker)
                worker.start()

        with connection_fixture(peer) as server:
            connection, events, released = self.connection(server.url, {"timeout": 1000, "idle": 140}, receive)
            started = time.monotonic()
            connection.start()
            self.assertTrue(released.wait(bool, 1))
            stop.set()
            for worker in workers:
                worker.join(timeout=1)
            self.assertLess(time.monotonic() - started, 0.8)
            self.assertIn("TimeoutError", events.items[-1]["error"])
            self.assertGreater(len(server.requests[0]["frames"]), 1)

    def test_cancel_interrupts_receiving_and_stalled_http_handshake(self):
        for stage in ("handshake", "receive"):
            entered = threading.Event()

            def peer(stream, observation):
                entered.set()
                observation["disconnected"] = stream.recv(1) == b""

            with self.subTest(stage=stage), connection_fixture(
                    peer, handshake=(lambda stream, observation: None) if stage == "handshake" else None) as server:
                connection, events, released = self.connection(server.url, {"timeout": 5000, "reconnect": True})
                connection.start()
                self.assertTrue(entered.wait(1))
                if stage == "receive":
                    self.assertTrue(events.wait(lambda items: any(item["type"] == "open" for item in items)))
                started = time.monotonic()
                connection.cancel()
                self.assertLess(time.monotonic() - started, 0.15)
                self.assertTrue(released.wait(bool))
                self.assertTrue(server.requests[0]["finished"].wait(0.5))
                self.assertTrue(server.requests[0]["disconnected"])
                self.assertFalse(events.wait(lambda items: any(item["type"] == "retry" for item in items), 0.3))
                self.assertEqual(len(server.requests), 1)

    def test_stalled_handshake_obeys_timeout(self):
        with connection_fixture(lambda stream, observation: stream.recv(1),
                                handshake=lambda stream, observation: None) as server:
            connection, events, released = self.connection(server.url, {"timeout": 100})
            connection.start()
            self.assertTrue(released.wait(bool, 0.8))
            self.assertEqual([item["type"] for item in events.items], ["error"])
            self.assertIn("TimeoutError", events.items[0]["error"])

    def test_reconnect_drops_partial_frame_and_cancel_in_message_stops_retries(self):
        attempts = []

        def peer(stream, observation):
            attempts.append(time.monotonic())
            if observation["number"] == 0:
                stream.sendall(frame(b"discard-me", opcode=2, fin=False))
            else:
                stream.sendall(frame(b"fresh", opcode=2))
                stream.recv(1)

        send_while_retrying = []

        def receive(connection, event):
            if event["type"] == "retry":
                send_while_retrying.append(connection.send(b"not-connected"))
            if event["type"] == "message":
                connection.cancel()

        with connection_fixture(peer) as server:
            connection, events, released = self.connection(server.url, {"reconnect": True}, receive)
            connection.start()
            self.assertTrue(released.wait(bool))
            self.assertEqual([item["type"] for item in events.items], ["open", "retry", "open", "message"])
            self.assertEqual(events.items[-1]["content"], b"fresh")
            self.assertEqual(send_while_retrying, [False])
            self.assertGreaterEqual(attempts[1] - attempts[0], 0.2)
            self.assertFalse(events.wait(lambda items: len(items) > 4, 0.35))
            self.assertEqual(len(server.requests), 2)
            self.assertEqual(released.items, [connection])

    def test_repeated_immediate_disconnects_back_off_and_cancel_inside_retry(self):
        attempts, retries = [], []

        def peer(stream, observation):
            attempts.append(time.monotonic())

        def receive(connection, event):
            if event["type"] == "retry":
                retries.append(event)
                if len(retries) == 3:
                    connection.cancel()

        with connection_fixture(peer) as server:
            connection, events, released = self.connection(server.url, {"reconnect": True}, receive)
            connection.start()
            self.assertTrue(released.wait(bool, 3))
            self.assertEqual(len(attempts), 3)
            self.assertGreaterEqual(attempts[1] - attempts[0], 0.2)
            self.assertGreaterEqual(attempts[2] - attempts[1], 0.45)
            self.assertFalse(events.wait(lambda items: len(items) > 6, 0.3))
            self.assertEqual([item["type"] for item in events.items], ["open", "retry"] * 3)

    def test_cancel_during_retry_delay_prevents_the_next_connection(self):
        with connection_fixture(lambda stream, observation: None) as server:
            connection, events, released = self.connection(server.url, {"reconnect": True})
            connection.start()
            self.assertTrue(events.wait(lambda items: any(item["type"] == "retry" for item in items)))
            started = time.monotonic()
            connection.cancel()
            self.assertLess(time.monotonic() - started, 0.15)
            self.assertEqual(released.items, [connection])
            self.assertFalse(events.wait(lambda items: len(items) > 2, 0.4))
            self.assertEqual(len(server.requests), 1)

    def test_cancel_interrupts_a_backpressured_sender_without_waiting_for_it(self):
        written, resume, sending, returned = (threading.Event() for _ in range(4))
        results = []

        def peer(stream, observation):
            stream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            written.set()
            resume.wait(2)

        with connection_fixture(peer) as server:
            server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            connection, events, released = self.connection(server.url, {"timeout": 5000, "reconnect": True})
            connection.start()
            self.assertTrue(events.wait(lambda items: any(item["type"] == "open" for item in items)))
            self.assertTrue(written.wait(1))
            # A small socket buffer makes the real peer's stopped reads create deterministic backpressure.
            connection._exchange._socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)

            def send():
                sending.set()
                results.append(connection.send(b"x" * (1024 * 1024)))
                returned.set()

            sender = threading.Thread(target=send, daemon=True)
            sender.start()
            try:
                self.assertTrue(sending.wait(1))
                self.assertFalse(returned.wait(0.15))
                started = time.monotonic()
                connection.cancel()
                self.assertLess(time.monotonic() - started, 0.15)
                self.assertTrue(returned.wait(0.5))
                self.assertEqual(results, [False])
                self.assertEqual(released.items, [connection])
                self.assertFalse(events.wait(lambda items: len(items) > 1, 0.3))
            finally:
                connection.cancel()
                resume.set()
                sender.join(timeout=1)

    def test_cancel_never_waits_for_callback_holding_or_waiting_for_helper_rlock(self):
        helper_lock = threading.RLock()
        entered, left = threading.Event(), threading.Event()

        def receive(connection, event):
            entered.set()
            with helper_lock:
                connection.cancel()
                left.set()

        with connection_fixture(lambda stream, observation: stream.recv(1)) as server:
            connection, events, released = self.connection(server.url, callback=receive)
            with helper_lock:
                connection.start()
                self.assertTrue(entered.wait(1))
                started = time.monotonic()
                connection.cancel()
                self.assertLess(time.monotonic() - started, 0.15)
                self.assertEqual(released.items, [connection])
                self.assertFalse(left.is_set())
            self.assertTrue(left.wait(0.5))
            self.assertEqual(released.items, [connection])

    def test_callback_exception_is_terminal_even_when_reconnect_is_enabled(self):
        def receive(connection, event):
            raise ValueError("private callback failure")

        with connection_fixture(lambda stream, observation: stream.recv(1)) as server:
            connection, events, released = self.connection(server.url, {"reconnect": True}, receive)
            connection.start()
            self.assertTrue(released.wait(bool))
            self.assertFalse(events.wait(lambda items: len(items) > 1, 0.3))
            self.assertEqual([item["type"] for item in events.items], ["open"])
            self.assertEqual(len(server.requests), 1)

    def test_cancel_before_start_is_terminal_and_start_is_idempotent(self):
        with connection_fixture(lambda stream, observation: stream.recv(1)) as server:
            connection, events, released = self.connection(server.url)
            self.assertFalse(connection.send(b"early"))
            connection.cancel()
            self.assertIs(connection.start(), connection)
            self.assertIs(connection.start(), connection)
            connection.close()
            self.assertEqual(released.items, [connection])
            self.assertEqual(events.items, [])
            self.assertEqual(server.requests, [])
            active, opened, finished = self.connection(server.url)
            active.start()
            active.start()
            self.assertTrue(opened.wait(bool))
            active.cancel()
            self.assertEqual(finished.items, [active])
            self.assertEqual(len(server.requests), 1)

    def test_dns_resolution_is_bounded_by_timeout_and_cancel_without_late_retry(self):
        resolver = socket.getaddrinfo
        for cancel in (False, True):
            entered, release, resolved = threading.Event(), threading.Event(), threading.Event()

            def blocked(*args, **kwargs):
                entered.set()
                release.wait(2)
                try:
                    return resolver("127.0.0.1", 1, type=socket.SOCK_STREAM)
                finally:
                    resolved.set()

            with self.subTest(cancel=cancel), patch("base.ws.socket.getaddrinfo", side_effect=blocked):
                connection, events, released = self.connection("ws://resolver.invalid/", {
                    "timeout": 5000 if cancel else 100, "reconnect": cancel})
                try:
                    connection.start()
                    self.assertTrue(entered.wait(1))
                    if cancel:
                        started = time.monotonic()
                        connection.cancel()
                        self.assertLess(time.monotonic() - started, 0.15)
                    self.assertTrue(released.wait(bool, 0.5))
                    if cancel:
                        self.assertEqual(events.items, [])
                    else:
                        self.assertIn("TimeoutError", events.items[0]["error"])
                finally:
                    release.set()
                    self.assertTrue(resolved.wait(1))
                    connection.cancel()
                self.assertFalse(events.wait(lambda items: any(item["type"] == "retry" for item in items), 0.1))

    def test_tls_handshake_can_timeout_or_cancel_without_waiting_for_peer(self):
        for cancel in (False, True):
            entered = threading.Event()

            def stalled_tls(stream, observation):
                read_exact(stream, 1)
                entered.set()
                while stream.recv(65536):
                    pass

            with self.subTest(cancel=cancel), connection_fixture(
                    lambda stream, observation: None, before_handshake=stalled_tls) as server:
                connection, events, released = self.connection(server.url.replace("ws://", "wss://"), {
                    "timeout": 5000 if cancel else 300, "reconnect": cancel})
                connection.start()
                self.assertTrue(entered.wait(1))
                if cancel:
                    started = time.monotonic()
                    connection.cancel()
                    self.assertLess(time.monotonic() - started, 0.15)
                self.assertTrue(released.wait(bool, 0.8))
                self.assertTrue(server.requests[0]["finished"].wait(0.5))
                if cancel:
                    self.assertEqual(events.items, [])
                else:
                    self.assertIn("TimeoutError", events.items[0]["error"])

    def test_tls_retains_certificate_and_hostname_validation_and_receives_messages(self):
        certificate, key = self.enterContext(local_tls_certificate())
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(certificate, key)
        create_context, resolver = ssl.create_default_context, socket.getaddrinfo
        contexts = []

        def trust_fixture():
            context = create_context(cafile=certificate)
            contexts.append(context)
            return context

        def resolve_fixture(host, port, **kwargs):
            return resolver("127.0.0.1" if host == "localhost" else host, port, **kwargs)

        workers, sent = [], EventLog()
        heartbeat = [bytes((index,)) * 65536 for index in range(12)]

        def receive(connection, event):
            if event["type"] == "open":
                worker = threading.Thread(target=lambda: [sent.append(connection.send(item)) for item in heartbeat],
                                          daemon=True)
                workers.append(worker)
                worker.start()
            elif event["type"] == "message":
                sent.append(connection.send(event["content"]))

        def peer(stream, observation):
            stream.sendall(frame(b"tls", opcode=2, fin=False) + frame(b"ping", opcode=9)
                           + frame(b"-message", opcode=0))
            observation["frames"].extend(read_frame(stream) for _ in range(len(heartbeat) + 2))
            stream.sendall(frame(struct.pack("!H", 1000), opcode=8))
            observation["frames"].append(read_frame(stream))

        with connection_fixture(peer, tls_context=server_context) as server:
            connection, events, released = self.connection(server.url.replace("ws://", "wss://"))
            connection.start()
            self.assertTrue(released.wait(bool))
            self.assertIn("SSLCertVerificationError", events.items[0]["error"])
        with patch("base.ws.ssl.create_default_context", side_effect=trust_fixture), \
                patch("base.ws.socket.getaddrinfo", side_effect=resolve_fixture):
            for host, valid in (("localhost", True), ("127.0.0.1", False)):
                with self.subTest(host=host), connection_fixture(peer, tls_context=server_context) as server:
                    url = server.url.replace("ws://127.0.0.1", "wss://" + host)
                    connection, events, released = self.connection(url, callback=receive)
                    connection.start()
                    self.assertTrue(released.wait(bool, 3))
                    if valid:
                        self.assertEqual(events.items[1]["content"], b"tls-message")
                        self.assertEqual(events.items[-1]["type"], "close")
                        self.assertTrue(server.requests[0]["finished"].wait(1))
                        for worker in workers:
                            worker.join(timeout=1)
                            self.assertFalse(worker.is_alive())
                        self.assertEqual(sent.items, [True] * (len(heartbeat) + 1))
                        frames = server.requests[0]["frames"]
                        self.assertTrue(all(item["masked"] for item in frames))
                        self.assertCountEqual([item["payload"] for item in frames if item["opcode"] == 2],
                                              heartbeat + [b"tls-message"])
                        self.assertEqual([item["payload"] for item in frames if item["opcode"] == 10], [b"ping"])
                        self.assertEqual(frames[-1]["opcode"], 8)
                    else:
                        self.assertIn("SSLCertVerificationError", events.items[0]["error"])
        self.assertTrue(all(context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED for context in contexts))

    def test_invalid_options_urls_and_send_types_fail_before_network(self):
        options = [[], {"timeout": 0}, {"timeout": True}, {"timeout": float("inf")}, {"idle": -1},
                   {"idle": float("nan")}, {"idle": False}, {"reconnect": 1}, {"reconnect": None},
                   {"buffer": 3}, {"headers": []}, {"headers": {"Bad Name": "x"}},
                   {"headers": {"Origin": "a\r\nb"}}, {"headers": {"Host": "other"}},
                   {"headers": {"Sec-WebSocket-Key": "override"}}, {"headers": {"Origin": 1}}]
        with connection_fixture(lambda stream, observation: None) as server:
            for value in options:
                with self.subTest(options=value), self.assertRaises((TypeError, ValueError, NotImplementedError)):
                    WebSocketConnection(server.url, value, lambda *args: None, lambda *args: None)
            for url in ("http://127.0.0.1", "ws://user:secret@127.0.0.1", "ws://127.0.0.1/#fragment",
                        "ws://127.0.0.1:0", "ws://127.0.0.1:99999", "ws://127.0.0.1/\n"):
                with self.subTest(url=url), self.assertRaises(ValueError):
                    WebSocketConnection(url, {}, lambda *args: None, lambda *args: None)
            connection, events, released = self.connection(server.url)
            for value in ("text", bytearray(b"binary"), None, [1, 2]):
                with self.subTest(value=value), self.assertRaises(TypeError):
                    connection.send(value)
            with self.assertRaises(ValueError):
                connection.send(b"x" * (8 * 1024 * 1024 + 1))
            self.assertEqual(server.requests, [])


if __name__ == "__main__":
    unittest.main()
