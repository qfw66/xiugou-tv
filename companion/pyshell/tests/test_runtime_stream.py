"""Offline streaming contracts for the author probe and runner reader seam."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import patch


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet  # noqa: E402


@contextmanager
def http_fixture(respond, tls_context=None):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def handle_request(self):
            self.server.requests.append({"method": self.command, "path": self.path,
                                         "headers": dict(self.headers)})
            try:
                respond(self)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

        do_GET = do_POST = do_HEAD = handle_request

    class Server(ThreadingHTTPServer):
        daemon_threads = True

        def get_request(self):
            stream, address = super().get_request()
            if tls_context is not None:
                stream = tls_context.wrap_socket(stream, server_side=True)
            return stream, address

    server = Server(("127.0.0.1", 0), Handler)
    server.requests = []
    thread = threading.Thread(target=server.serve_forever,
                              kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    scheme = "https" if tls_context is not None else "http"
    server.origin = scheme + "://127.0.0.1:" + str(server.server_port)
    try:
        with patch.dict(os.environ, {"NO_PROXY": "*", "no_proxy": "*"}):
            yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def reply(handler, content=b"fixture", status=200, headers=()):
    handler.send_response(status)
    handler.send_header("Content-Length", str(len(content)))
    for key, value in headers:
        handler.send_header(key, value)
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(content)


class RuntimeStreamTest(unittest.TestCase):
    def setUp(self):
        self.net = RuntimeNet()
        self.addCleanup(self.net.close)

    def test_open_stream_has_owned_type_metadata_and_reads_bounded_bytes(self):
        def respond(handler):
            reply(handler, b"\x00\x80\xff", 206, (
                ("Content-Type", "video/mp2t"), ("Content-Range", "bytes 5-7/8"),
                ("Accept-Ranges", "bytes"),
            ))

        with http_fixture(respond) as server:
            reader = self.net.openStream(server.origin + "/segment.ts", {
                "headers": {"Range": "bytes=5-7"},
            })
            from base.net import RuntimeReader
            self.assertIsInstance(reader, RuntimeReader)
            with reader:
                self.assertEqual(reader.code, 206)
                self.assertEqual(reader.contentType, "video/mp2t")
                self.assertEqual(reader.headers["Content-Range"], "bytes 5-7/8")
                self.assertEqual(reader.read(2), b"\x00\x80")
                self.assertEqual(reader.read(), b"\xff")
                self.assertIsNone(reader.read())
                self.assertIsNone(reader.read())
            reader.close()
            self.assertEqual(server.requests[0]["headers"]["Range"], "bytes=5-7")

    def test_stream_returns_before_body_finishes_and_reads_first_available_chunk(self):
        release = threading.Event()

        def respond(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", "6")
            handler.end_headers()
            handler.wfile.write(b"one")
            handler.wfile.flush()
            release.wait(2)
            handler.wfile.write(b"two")

        with http_fixture(respond) as server:
            try:
                start = time.monotonic()
                result = self.net.stream(server.origin)
                with result["stream"] as reader:
                    self.assertLess(time.monotonic() - start, 0.5)
                    self.assertEqual(result["code"], 200)
                    self.assertEqual(result["contentType"], "application/octet-stream")
                    self.assertEqual(reader.read(), b"one")
                    self.assertLess(time.monotonic() - start, 0.5)
                    release.set()
                    self.assertEqual(reader.read(), b"two")
                    self.assertIsNone(reader.read())
            finally:
                release.set()

    def test_stream_is_not_limited_to_the_buffered_response_cap(self):
        block = b"\x00\x80\xff" * 16384
        count = 180

        def respond(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", str(len(block) * count))
            handler.end_headers()
            for _ in range(count):
                handler.wfile.write(block)

        with http_fixture(respond) as server, self.net.openStream(server.origin) as reader:
            received, offset = 0, 0
            while True:
                chunk = reader.read(65536)
                if chunk is None:
                    break
                self.assertTrue(0 < len(chunk) <= 65536)
                expected = (b"\x00\x80\xff" * ((len(chunk) + 5) // 3))[offset:offset + len(chunk)]
                self.assertEqual(chunk, expected)
                received += len(chunk)
                offset = received % 3
            self.assertEqual(received, len(block) * count)
            self.assertGreater(received, 8 * 1024 * 1024)

    def test_non_success_and_head_preserve_metadata_without_losing_body(self):
        def respond(handler):
            reply(handler, b"denied", 403, (("Content-Type", "text/plain"),))

        with http_fixture(respond) as server:
            for method in ("GET", "HEAD"):
                with self.subTest(method=method), self.net.openStream(server.origin, {
                    "method": method,
                }) as reader:
                    self.assertEqual(reader.code, 403)
                    self.assertEqual(reader.contentType, "text/plain")
                    self.assertEqual(reader.read(), b"denied" if method == "GET" else None)
                    self.assertIsNone(reader.read())

    def test_chunked_frames_are_decoded_and_truncated_body_is_not_eof(self):
        def respond(handler):
            handler.send_response(200)
            if handler.path == "/chunked":
                handler.send_header("Transfer-Encoding", "chunked")
                content = b"2\r\n\x00\x80\r\n1\r\n\xff\r\n0\r\nX-Trailer: ok\r\n\r\n"
            else:
                handler.send_header("Content-Length", "10")
                content = b"short"
            handler.end_headers()
            handler.wfile.write(content)
            handler.close_connection = True

        with http_fixture(respond) as server:
            with self.net.openStream(server.origin + "/chunked") as reader:
                chunks = []
                while True:
                    chunk = reader.read(1)
                    if chunk is None:
                        break
                    chunks.append(chunk)
                self.assertEqual(b"".join(chunks), b"\x00\x80\xff")
            with self.net.openStream(server.origin + "/truncated") as reader:
                self.assertEqual(reader.read(), b"short")
                with self.assertRaisesRegex(OSError, "IncompleteRead"):
                    reader.read()

    def test_invalid_sizes_are_rejected_before_consuming_bytes(self):
        with http_fixture(lambda handler: reply(handler, b"abc")) as server:
            with self.net.openStream(server.origin) as reader:
                for size in (0, -1, True, 1.5, 1048577, None):
                    with self.subTest(size=size), self.assertRaises(ValueError):
                        reader.read(size)
                self.assertEqual(reader.read(1048576), b"abc")
                self.assertIsNone(reader.read())
        for url in (object(), [], None):
            with self.subTest(url=type(url).__name__), self.assertRaises((TypeError, ValueError)):
                self.net.stream(url)

    def test_concurrent_read_rejected_and_owner_or_reader_close_interrupts_wait(self):
        for close_owner in (False, True):
            release, entered, ended = threading.Event(), threading.Event(), threading.Event()
            failures = []
            net = RuntimeNet()
            self.addCleanup(net.close)

            def respond(handler):
                handler.send_response(200)
                handler.send_header("Content-Length", "1")
                handler.end_headers()
                release.wait(2)

            with self.subTest(close_owner=close_owner), http_fixture(respond) as server:
                reader = net.openStream(server.origin, {"timeout": 2000})

                def consume():
                    entered.set()
                    try:
                        reader.read()
                    except Exception as error:
                        failures.append(error)
                    finally:
                        ended.set()

                thread = threading.Thread(target=consume, daemon=True)
                thread.start()
                try:
                    self.assertTrue(entered.wait(1))
                    with self.assertRaisesRegex(RuntimeError, "concurrent"):
                        reader.read()
                    start = time.monotonic()
                    (net.close if close_owner else reader.close)()
                    self.assertTrue(ended.wait(0.5))
                    self.assertLess(time.monotonic() - start, 0.5)
                    self.assertEqual(len(failures), 1)
                    self.assertIsInstance(failures[0], InterruptedError)
                    self.assertEqual(str(failures[0]), "Network owner closed")
                    reader.close()
                finally:
                    release.set()
                    net.close()
                    thread.join(timeout=2)

    def test_reader_rejects_incomplete_chunk_framing_and_unsolicited_upgrade(self):
        def respond(handler):
            messages = {
                "/chunk": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab",
                "/upgrade": b"HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n",
            }
            handler.connection.sendall(messages[handler.path])
            handler.close_connection = True

        with http_fixture(respond) as server:
            with self.net.openStream(server.origin + "/chunk") as reader:
                self.assertEqual(reader.read(), b"ab")
                with self.assertRaises(OSError):
                    reader.read()
            result = self.net.req(server.origin + "/upgrade")
            self.assertEqual(result["code"], 0)
            self.assertIn("error", result)

    def test_buffered_compressed_response_preserves_duplicate_headers(self):
        import gzip

        def respond(handler):
            reply(handler, gzip.compress(b"decoded"), headers=(
                ("Content-Encoding", "gzip"), ("Content-Encoding", "gzip"),
                ("Content-Type", "text/plain; charset=utf-8"), ("Content-Type", "text/plain"),
            ))

        with http_fixture(respond) as server:
            result = self.net.req(server.origin)
            self.assertEqual(result["code"], 200)
            self.assertEqual(result["content"], "decoded")
            self.assertEqual(result["headers"]["Content-Encoding"], ["gzip", "gzip"])


if __name__ == "__main__":
    unittest.main()
