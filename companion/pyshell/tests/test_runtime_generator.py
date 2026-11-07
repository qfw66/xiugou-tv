"""Generator streams keep the HTTP reader boundary and own their cancellation."""

import gc
from pathlib import Path
import sys
import weakref
import threading
import time
import unittest
from unittest.mock import patch

from test_runtime_stream import http_fixture, reply
from test_runtime_ws import websocket_fixture

SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet, RuntimeReader


class RuntimeGeneratorTest(unittest.TestCase):
    def setUp(self):
        self.net = RuntimeNet()
        self.addCleanup(self.net.close)

    def test_lazy_generator_returns_owned_reader_and_splits_without_prefetch(self):
        events = []

        def chunks():
            try:
                events.append("start")
                yield b"\x00\x80\xff" * 30000
                events.append("next")
                yield bytearray(b"tail")
                yield memoryview(b"end")
            finally:
                events.append("closed")

        result = self.net.stream(chunks())
        self.assertEqual(events, [])
        self.assertEqual((result["code"], result["headers"], result["contentType"]),
                         (200, {}, "application/octet-stream"))
        with result["stream"] as reader:
            self.assertIsInstance(reader, RuntimeReader)
            self.assertEqual(reader.read(65536), (b"\x00\x80\xff" * 30000)[:65536])
            self.assertEqual(events, ["start"])
            self.assertEqual(reader.read(65536), (b"\x00\x80\xff" * 30000)[65536:])
            self.assertEqual(events, ["start"])
            self.assertEqual(reader.read(), b"tail")
            self.assertEqual(reader.read(), b"end")
            self.assertIsNone(reader.read())
            self.assertIsNone(reader.read())
        self.assertEqual(events, ["start", "next", "closed"])

    def test_close_suspended_generator_runs_finally_once_and_keeps_sibling_alive(self):
        finished = []

        def chunks():
            try:
                yield b"first"
                yield b"second"
            finally:
                finished.append(True)

        first = self.net.stream(chunks())["stream"]
        other = self.net.stream(iter([b"other"]))["stream"]
        self.assertEqual(first.read(2), b"fi")
        first.close()
        first.close()
        self.assertEqual(finished, [True])
        with self.assertRaises(InterruptedError):
            first.read()
        self.assertEqual(other.read(), b"other")

    def test_invalid_chunks_and_options_close_iterator(self):
        for invalid in ("text", 7, None, memoryview(b"abcd")[::2]):
            finished = []

            def chunks():
                try:
                    yield invalid
                finally:
                    finished.append(True)

            with self.subTest(invalid=invalid):
                reader = self.net.stream(chunks())["stream"]
                with self.assertRaises((TypeError, ValueError)):
                    reader.read()
                self.assertEqual(finished, [True])
        for source in ([], {}, b"bytes", object()):
            with self.assertRaises(TypeError):
                self.net.stream(source)
        with self.assertRaises(ValueError):
            self.net.stream(iter([b"one"]), {})
        with self.net.stream(iter([b"", bytearray(), b"ok"]))["stream"] as reader:
            self.assertEqual(reader.read(), b"ok")
            self.assertIsNone(reader.read())

    def test_close_interrupts_owned_http_without_closing_unrelated_reader(self):
        waiting, release, finished = threading.Event(), threading.Event(), threading.Event()

        def respond(handler):
            if handler.path == "/slow":
                handler.send_response(200)
                handler.send_header("Content-Length", "8")
                handler.end_headers()
                handler.wfile.flush()
                waiting.set()
                release.wait(2)
            else:
                reply(handler, b"unrelated")

        with http_fixture(respond) as server:
            def chunks():
                try:
                    with self.net.openStream(server.origin + "/slow") as inner:
                        yield inner.read()
                finally:
                    finished.set()

            reader = self.net.stream(chunks())["stream"]
            sibling = self.net.openStream(server.origin + "/ok")
            errors = []

            def read():
                try:
                    reader.read()
                except BaseException as error:
                    errors.append(error)

            worker = threading.Thread(target=read, daemon=True)
            worker.start()
            try:
                self.assertTrue(waiting.wait(1))
                with self.assertRaisesRegex(RuntimeError, "concurrent"):
                    reader.read()
                before = time.monotonic()
                reader.close()
                self.assertTrue(finished.wait(0.5))
                worker.join(0.5)
                self.assertLess(time.monotonic() - before, 0.5)
                self.assertEqual(len(errors), 1)
                self.assertIsInstance(errors[0], InterruptedError)
                self.assertEqual(sibling.read(), b"unrelated")
            finally:
                release.set()
                sibling.close()
                reader.close()
                worker.join(2)

    def test_sleep_and_owner_close_cancel_empty_generator_loops(self):
        for owner_close in (False, True):
            with self.subTest(owner_close=owner_close):
                net = RuntimeNet()
                entered, finished = threading.Event(), threading.Event()
                errors = []

                def chunks():
                    try:
                        entered.set()
                        net.sleep(10000)
                        yield b"late"
                    finally:
                        finished.set()

                reader = net.stream(chunks())["stream"]

                def read():
                    try:
                        reader.read()
                    except BaseException as error:
                        errors.append(error)

                worker = threading.Thread(target=read, daemon=True)
                worker.start()
                try:
                    self.assertTrue(entered.wait(1))
                    (net if owner_close else reader).close()
                    self.assertTrue(finished.wait(0.5))
                    worker.join(0.5)
                    self.assertEqual(len(errors), 1)
                    self.assertIsInstance(errors[0], InterruptedError)
                finally:
                    net.close()
                    worker.join(1)

    def test_reader_validation_and_error_finally_release_resources(self):
        closed = []

        def chunks():
            try:
                yield b"ok"
                raise LookupError("producer failed")
            finally:
                closed.append(True)

        reader = self.net.stream(chunks())["stream"]
        for size in (0, -1, True, 1048577, 1.5):
            with self.assertRaises(ValueError):
                reader.read(size)
        self.assertEqual(reader.read(), b"ok")
        with self.assertRaisesRegex(LookupError, "producer failed"):
            reader.read()
        self.assertEqual(closed, [True])
        reader.close()
        self.assertEqual(closed, [True])

    def test_failed_generator_finalizer_still_closes_parent_websocket_and_sessions(self):
        received = threading.Event()
        session = self.net.session()

        def chunks():
            try:
                yield b"one"
            finally:
                raise LookupError("producer cleanup failed")

        def callback(connection, event):
            if event["type"] == "open":
                connection.send(b"join")
            elif event["type"] == "message":
                received.set()

        reader = self.net.stream(chunks())["stream"]
        self.assertEqual(reader.read(), b"one")
        with websocket_fixture() as server:
            connection = self.net.connect(server.url, {"reconnect": False}, callback)
            try:
                self.assertTrue(received.wait(1))
                with self.assertRaisesRegex(LookupError, "producer cleanup failed"):
                    self.net.close()
                self.assertFalse(connection.send(b"late"))
                with self.assertRaisesRegex(RuntimeError, "closed"):
                    session.req("http://127.0.0.1:1")
            finally:
                connection.cancel()
                session.close()

    def test_nested_cleanup_failure_still_runs_outer_generator_finally(self):
        completed = []

        def inner():
            try:
                yield b"inner"
            finally:
                raise LookupError("inner cleanup failed")

        def outer():
            try:
                yield self.net.stream(inner())["stream"].read()
            finally:
                completed.append("outer")

        reader = self.net.stream(outer())["stream"]
        self.assertEqual(reader.read(), b"inner")
        with self.assertRaisesRegex(LookupError, "inner cleanup failed"):
            reader.close()
        self.assertEqual(completed, ["outer"])
        reader.close()
        self.assertEqual(completed, ["outer"])

    def test_owner_close_during_registration_does_not_retain_closed_generator(self):
        from base.cancel_scope import CancelScope
        active = CancelScope()
        self.addCleanup(active.close)
        original_add = CancelScope.add

        def add(scope, resource):
            original_add(scope, resource)
            if scope is not active:
                self.net.close()

        source = (chunk for chunk in (b"one", b"two"))
        retained = weakref.ref(source)
        with active.activate(), patch.object(CancelScope, "add", add):
            reader = self.net.stream(source)["stream"]
        with self.assertRaises(InterruptedError):
            reader.read()
        del reader, source
        gc.collect()
        self.assertIsNone(retained())


if __name__ == "__main__":
    unittest.main()
