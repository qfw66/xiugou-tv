"""Real HTTP deadline and cancellation boundaries; no upstream network."""

from contextlib import contextmanager
from pathlib import Path
import shutil
import socket
import ssl
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from test_runtime_stream import RuntimeNet, http_fixture, reply


@contextmanager
def tls_contexts():
    candidates = (Path(sys.base_prefix) / "Lib/test/certdata/keycert.pem",
                  Path("C:/Python314/Lib/test/certdata/keycert.pem"))
    source = next((path for path in candidates if path.is_file()), None)
    if source is None:
        raise unittest.SkipTest("CPython localhost TLS fixture certificate is unavailable")
    original_factory = ssl.create_default_context
    with tempfile.TemporaryDirectory(prefix="xiugou-http-tls-") as folder:
        certificate = Path(folder) / "localhost.pem"
        shutil.copyfile(source, certificate)
        server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server.load_cert_chain(str(certificate))

        def client():
            context = original_factory(cafile=str(certificate))
            if context.verify_mode != ssl.CERT_REQUIRED or not context.check_hostname:
                raise AssertionError("TLS verification must remain enabled")
            return context

        yield server, client


class RuntimeDeadlineTest(unittest.TestCase):
    def setUp(self):
        self.net = RuntimeNet()
        self.addCleanup(self.net.close)

    def test_redirect_integer_options_and_shared_deadline_span_slow_body(self):
        def respond(handler):
            if handler.path == "/redirect":
                threading.Event().wait(0.08)
                reply(handler, b"redirect", 302, (("Location", "/slow?private=secret"),))
            else:
                handler.send_response(200)
                handler.send_header("Content-Length", "20")
                handler.end_headers()
                for _ in range(20):
                    handler.wfile.write(b"x")
                    handler.wfile.flush()
                    threading.Event().wait(0.02)

        with http_fixture(respond) as server:
            disabled = self.net.req(server.origin + "/redirect", {"redirect": 0})
            self.assertEqual(disabled["code"], 302)
            self.assertEqual(disabled["content"], "redirect")
            started = time.monotonic()
            result = self.net.req(server.origin + "/redirect", {
                "redirect": 1, "timeout": 1000, "callTimeout": 180,
            })
            self.assertLess(time.monotonic() - started, 0.6)
            self.assertEqual(result["code"], 0)
            self.assertIn("timeout", result["error"].lower())
            self.assertNotIn("secret", result["error"])
            self.assertEqual([item["path"] for item in server.requests], [
                "/redirect", "/redirect", "/slow?private=secret",
            ])

    def test_call_timeout_zero_allows_progress_beyond_io_timeout(self):
        def respond(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", "6")
            handler.end_headers()
            for _ in range(6):
                handler.wfile.write(b"x")
                handler.wfile.flush()
                threading.Event().wait(0.03)

        with http_fixture(respond) as server:
            started = time.monotonic()
            result = self.net.req(server.origin, {"timeout": 100, "callTimeout": 0})
            self.assertEqual(result["content"], "xxxxxx")
            self.assertEqual(result["code"], 200)
            self.assertGreater(time.monotonic() - started, 0.12)

    def test_reader_idle_time_counts_and_deadline_failure_closes_connection(self):
        peer_closed = threading.Event()

        def respond(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", "10")
            handler.end_headers()
            handler.connection.settimeout(1)
            if not handler.connection.recv(1):
                peer_closed.set()

        with http_fixture(respond) as server:
            reader = self.net.openStream(server.origin, {"callTimeout": 50})
            threading.Event().wait(0.07)
            with self.assertRaisesRegex(TimeoutError, "timeout"):
                reader.read()
            self.assertTrue(peer_closed.wait(0.5))
            reader.close()

    def test_deadline_covers_slow_headers_and_chunk_framing(self):
        def respond(handler):
            if handler.path == "/headers":
                content = b"HTTP/1.1 200 OK\r\nX-Slow: " + b"a" * 60 + b"\r\n\r\n"
            else:
                handler.connection.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
                content = b"0000000000000000000000000001\r\nx\r\n0\r\n\r\n"
            for byte in content:
                handler.connection.sendall(bytes([byte]))
                threading.Event().wait(0.01)
            handler.close_connection = True

        with http_fixture(respond) as server:
            for path in ("/headers", "/chunked"):
                with self.subTest(path=path):
                    start = time.monotonic()
                    result = self.net.req(server.origin + path, {"timeout": 500, "callTimeout": 80})
                    self.assertLess(time.monotonic() - start, 0.4)
                    self.assertEqual(result["code"], 0)
                    self.assertIn("timeout", result["error"].lower())

    def test_blocked_dns_is_bounded_and_owner_close_interrupts_it(self):
        for cancel in (False, True):
            entered, release, ended = threading.Event(), threading.Event(), threading.Event()
            results, failures = [], []
            net = RuntimeNet()
            self.addCleanup(net.close)

            def resolve(*args, **kwargs):
                entered.set()
                release.wait(2)
                raise socket.gaierror("private DNS detail")

            def request():
                try:
                    results.append(net.req("http://secret.invalid/?token=hidden", {
                        "timeout": 1000, "callTimeout": 1000 if cancel else 60,
                    }))
                except Exception as error:
                    failures.append(error)
                finally:
                    ended.set()

            with self.subTest(cancel=cancel), patch("socket.getaddrinfo", resolve):
                thread = threading.Thread(target=request, daemon=True)
                thread.start()
                try:
                    self.assertTrue(entered.wait(1))
                    started = time.monotonic()
                    if cancel:
                        net.close()
                    self.assertTrue(ended.wait(0.4))
                    self.assertLess(time.monotonic() - started, 0.4)
                    if cancel:
                        self.assertEqual(len(failures), 1)
                        self.assertIsInstance(failures[0], InterruptedError)
                        self.assertEqual(str(failures[0]), "Network owner closed")
                    else:
                        self.assertEqual(results[0]["code"], 0)
                        self.assertIn("timeout", results[0]["error"].lower())
                        self.assertNotIn("secret", results[0]["error"])
                finally:
                    release.set()
                    net.close()
                    thread.join(timeout=2)

    def test_owner_close_interrupts_buffered_request_waiting_for_headers(self):
        entered, release, ended = threading.Event(), threading.Event(), threading.Event()
        failures = []

        def respond(handler):
            entered.set()
            release.wait(2)
            reply(handler)

        with http_fixture(respond) as server:
            def request():
                try:
                    self.net.req(server.origin, {"timeout": 2000})
                except Exception as error:
                    failures.append(error)
                finally:
                    ended.set()

            thread = threading.Thread(target=request, daemon=True)
            thread.start()
            try:
                self.assertTrue(entered.wait(1))
                started = time.monotonic()
                self.net.close()
                self.assertTrue(ended.wait(0.4))
                self.assertLess(time.monotonic() - started, 0.4)
                self.assertIsInstance(failures[0], InterruptedError)
            finally:
                release.set()
                thread.join(timeout=2)

    def test_redirect_status_method_and_sensitive_header_boundaries(self):
        def destination(handler):
            length = int(handler.headers.get("Content-Length", "0"))
            self.observed.append((handler.command, handler.rfile.read(length), dict(handler.headers)))
            reply(handler, b"final")

        self.observed = []
        with http_fixture(destination) as final:
            def respond(handler):
                handler.rfile.read(int(handler.headers.get("Content-Length", "0")))
                reply(handler, b"", int(handler.path[1:]), (("Location", final.origin + "/new"),))

            with http_fixture(respond) as origin:
                for status, expected_method in ((301, "GET"), (302, "GET"), (303, "GET"), (307, "POST"), (308, "POST")):
                    with self.subTest(status=status):
                        result = self.net.req(origin.origin + "/" + str(status), {
                            "body": "posted", "headers": {"Authorization": "private", "Cookie": "secret=1"},
                        })
                        self.assertEqual(result["content"], "final")
                        method, body, headers = self.observed[-1]
                        self.assertEqual(method, expected_method)
                        self.assertEqual(body, b"posted" if method == "POST" else b"")
                        self.assertNotIn("Authorization", headers)
                        self.assertNotIn("Cookie", headers)
                        self.assertEqual(headers["Host"], final.origin.removeprefix("http://"))

    def test_invalid_redirects_and_header_limit_fail_safely(self):
        def respond(handler):
            if handler.path == "/huge":
                handler.connection.sendall(b"HTTP/1.1 200 OK\r\n" + b"X-Fill: " + b"a" * 65000 + b"\r\nY-Fill: " + b"b" * 2000 + b"\r\n\r\n")
                handler.close_connection = True
            else:
                location = "/loop" if handler.path == "/loop" else "file:///private-secret"
                reply(handler, b"", 302, (("Location", location),))

        with http_fixture(respond) as server:
            for path in ("/loop", "/file", "/huge"):
                with self.subTest(path=path):
                    result = self.net.req(server.origin + path, {"callTimeout": 1000})
                    self.assertEqual(result["code"], 0)
                    self.assertNotIn("private-secret", result["error"])

    def test_tls_verifies_certificate_and_hostname_on_real_connections(self):
        original_dns = socket.getaddrinfo

        def resolve(host, port, *args, **kwargs):
            return original_dns("127.0.0.1" if host == "localhost" else host, port, *args, **kwargs)

        with tls_contexts() as (context, client), http_fixture(
                lambda handler: reply(handler, b"secure"), tls_context=context) as server, patch(
                    "socket.getaddrinfo", resolve):
            trusted_url = server.origin.replace("127.0.0.1", "localhost")
            self.assertEqual(self.net.req(trusted_url)["code"], 0)
            with patch("ssl.create_default_context", client):
                self.assertEqual(self.net.req(trusted_url)["content"], "secure")
                self.assertEqual(self.net.req(server.origin)["code"], 0)

    def test_deadline_and_owner_close_interrupt_tls_handshake(self):
        for cancel in (False, True):
            accepted, release, finished = threading.Event(), threading.Event(), threading.Event()
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            net = RuntimeNet()
            self.addCleanup(net.close)
            results, failures = [], []

            def server():
                stream, _ = listener.accept()
                with stream:
                    accepted.set()
                    release.wait(2)

            def request():
                try:
                    results.append(net.req("https://127.0.0.1:" + str(listener.getsockname()[1]), {
                        "timeout": 1000, "callTimeout": 1000 if cancel else 100,
                    }))
                except Exception as error:
                    failures.append(error)
                finally:
                    finished.set()

            server_thread = threading.Thread(target=server, daemon=True)
            client_thread = threading.Thread(target=request, daemon=True)
            server_thread.start()
            client_thread.start()
            try:
                with self.subTest(cancel=cancel):
                    self.assertTrue(accepted.wait(1))
                    start = time.monotonic()
                    if cancel:
                        net.close()
                    self.assertTrue(finished.wait(0.4))
                    self.assertLess(time.monotonic() - start, 0.4)
                    if cancel:
                        self.assertIsInstance(failures[0], InterruptedError)
                    else:
                        self.assertIn("timeout", results[0]["error"].lower())
            finally:
                net.close()
                release.set()
                listener.close()
                server_thread.join(timeout=2)
                client_thread.join(timeout=2)

    def test_deadline_bounds_request_body_when_server_does_not_read(self):
        release = threading.Event()

        def respond(handler):
            release.wait(2)
            handler.close_connection = True

        with http_fixture(respond) as server:
            try:
                start = time.monotonic()
                result = self.net.req(server.origin, {
                    "body": b"x" * (8 * 1024 * 1024), "timeout": 1000, "callTimeout": 100,
                })
                self.assertLess(time.monotonic() - start, 0.5)
                self.assertEqual(result["code"], 0)
                self.assertIn("timeout", result["error"].lower())
            finally:
                release.set()


if __name__ == "__main__":
    unittest.main()
