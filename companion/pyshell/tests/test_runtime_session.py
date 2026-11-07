"""Isolated HTTP cookies exercised over virtual domains and loopback sockets."""

from contextlib import contextmanager
import json
import socket
import threading
import time
import unittest
from urllib.parse import urlsplit

from test_runtime_deadline import tls_contexts
from unittest.mock import patch

from test_runtime_stream import RuntimeNet, http_fixture, reply


@contextmanager
def virtual_dns():
    original = socket.getaddrinfo

    def resolve(host, port, *args, **kwargs):
        if host.endswith(".test"):
            host = "127.0.0.1"
        return original(host, port, *args, **kwargs)

    with patch("socket.getaddrinfo", resolve):
        yield


def cookie_echo(handler):
    payload = json.dumps({"cookie": handler.headers.get("Cookie", ""),
                          "host": handler.headers.get("Host")}).encode("utf-8")
    reply(handler, payload, headers=(("Content-Type", "application/json"),))


class RuntimeSessionTest(unittest.TestCase):
    def setUp(self):
        self.net = RuntimeNet()
        self.addCleanup(self.net.close)

    def test_session_domain_cookie_crosses_subdomains_without_leaking_to_siblings_or_parent(self):
        with http_fixture(cookie_echo) as server, virtual_dns():
            origin = "http://auth.media.test:" + str(server.server_port)
            player = "http://player.media.test:" + str(server.server_port)
            unrelated = "http://other.test:" + str(server.server_port)
            with self.net.session() as session:
                self.assertTrue(session.setCookie(origin, "login=opaque; Domain=media.test; Path=/"))
                self.assertTrue(session.setCookie(origin, "host=only; Path=/"))
                self.assertEqual(session.json(origin)["cookie"], "login=opaque; host=only")
                self.assertEqual(session.json(player)["cookie"], "login=opaque")
                self.assertEqual(session.json(unrelated)["cookie"], "")
                self.assertEqual(self.net.json(player)["cookie"], "")
                with self.net.session() as other:
                    self.assertEqual(other.json(player)["cookie"], "")
            self.assertEqual(self.net.json(origin)["cookie"], "")
            with self.assertRaisesRegex(RuntimeError, "closed"):
                session.req(origin)

    def test_response_cookie_redirect_path_expiry_and_invalid_domains(self):
        def respond(handler):
            if handler.path == "/login":
                reply(handler, b"", 302, (
                    ("Location", "/private/result"),
                    ("Set-Cookie", "login=1; Domain=media.test; Path=/"),
                    ("Set-Cookie", "scoped=2; Path=/private"),
                    ("Set-Cookie", "blocked=3; Domain=unrelated.test; Path=/"),
                ))
            else:
                cookie_echo(handler)

        with http_fixture(respond) as server, virtual_dns(), self.net.session() as session:
            origin = "http://auth.media.test:" + str(server.server_port)
            self.assertEqual(session.json(origin + "/login")["cookie"], "scoped=2; login=1")
            self.assertEqual(session.json(origin + "/public")["cookie"], "login=1")
            self.assertEqual(session.json(origin + "/privately")["cookie"], "login=1")
            self.assertTrue(session.setCookie(origin, "login=; Domain=media.test; Path=/; Max-Age=0"))
            self.assertEqual(session.json(origin + "/public")["cookie"], "")
            now = time.time()
            with patch("time.time", lambda: now):
                self.assertTrue(session.setCookie(origin, "short=1; Path=/; Max-Age=1"))
                self.assertEqual(session.json(origin + "/")["cookie"], "short=1")
            with patch("time.time", lambda: now + 2):
                self.assertEqual(session.json(origin + "/")["cookie"], "")
            self.assertTrue(session.setCookie(origin, "old=1; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"))
            self.assertEqual(session.json(origin)["cookie"], "")
            self.assertFalse(session.setCookie(origin, "bad=1; Domain=media.test.attacker.test; Path=/"))
            self.assertFalse(session.setCookie(origin, "bad=1; Domain=test; Path=/"))

    def test_set_cookie_validates_one_record_and_explicit_cookie_does_not_modify_jar(self):
        with http_fixture(cookie_echo) as server, virtual_dns(), self.net.session() as session:
            origin = "http://auth.media.test:" + str(server.server_port)
            for invalid in (None, 1, "", "no-equals", "a=1; b=2", "a=1\r\nX-Secret: leaked", "a=" + "x" * 8192):
                with self.subTest(invalid=type(invalid).__name__):
                    self.assertFalse(session.setCookie(origin, invalid))
            self.assertTrue(session.setCookie(origin, "valid=1; Path=/"))
            self.assertEqual(session.json(origin, {"headers": {"Cookie": "explicit=1"}})["cookie"], "explicit=1")
            self.assertEqual(session.json(origin)["cookie"], "valid=1")
            with self.assertRaises(ValueError):
                session.setCookie("file:///private", "a=1")

    def test_secure_cookie_is_sent_only_over_verified_https(self):
        original_dns = socket.getaddrinfo

        def resolve(host, port, *args, **kwargs):
            return original_dns("127.0.0.1" if host == "localhost" else host, port, *args, **kwargs)

        with tls_contexts() as (tls, client), http_fixture(cookie_echo, tls_context=tls) as secure, http_fixture(
                cookie_echo) as plain, patch("socket.getaddrinfo", resolve), patch(
                    "ssl.create_default_context", client), self.net.session() as session:
            https = secure.origin.replace("127.0.0.1", "localhost")
            http = plain.origin.replace("127.0.0.1", "localhost")
            self.assertTrue(session.setCookie(https, "safe=1; Path=/; Secure"))
            self.assertEqual(session.json(https)["cookie"], "safe=1")
            self.assertEqual(session.json(http)["cookie"], "")

    def test_parent_and_session_close_cancel_active_child_only_and_are_idempotent(self):
        for close_parent in (False, True):
            entered, release, ended = threading.Event(), threading.Event(), threading.Event()
            failures = []
            net = RuntimeNet()
            self.addCleanup(net.close)
            session = net.session()

            def respond(handler):
                if handler.path == "/blocked":
                    entered.set()
                    release.wait(2)
                cookie_echo(handler)

            with self.subTest(close_parent=close_parent), http_fixture(respond) as server:
                def request():
                    try:
                        session.req(server.origin + "/blocked")
                    except Exception as error:
                        failures.append(error)
                    finally:
                        ended.set()

                thread = threading.Thread(target=request, daemon=True)
                thread.start()
                try:
                    self.assertTrue(entered.wait(1))
                    (net.close if close_parent else session.close)()
                    self.assertTrue(ended.wait(0.4))
                    self.assertEqual(len(failures), 1)
                    self.assertIsInstance(failures[0], InterruptedError)
                    session.close()
                    with self.assertRaisesRegex(RuntimeError, "closed"):
                        session.setCookie(server.origin, "a=1")
                    if close_parent:
                        with self.assertRaisesRegex(RuntimeError, "closed"):
                            net.session()
                    else:
                        self.assertEqual(net.json(server.origin)["cookie"], "")
                        with net.session() as other:
                            self.assertEqual(other.json(server.origin)["cookie"], "")
                finally:
                    release.set()
                    net.close()
                    thread.join(timeout=2)

    def test_child_reader_closes_with_parent_and_context_releases_on_exception(self):
        release = threading.Event()

        def respond(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", "1")
            handler.end_headers()
            release.wait(1)

        with http_fixture(respond) as server:
            try:
                with self.assertRaisesRegex(ValueError, "caller"):
                    with self.net.session() as session:
                        reader = session.openStream(server.origin)
                        raise ValueError("caller")
                with self.assertRaises(InterruptedError):
                    reader.read()
                session = self.net.session()
                reader = session.openStream(server.origin)
                self.net.close()
                with self.assertRaises(InterruptedError):
                    reader.read()
            finally:
                release.set()


if __name__ == "__main__":
    unittest.main()
