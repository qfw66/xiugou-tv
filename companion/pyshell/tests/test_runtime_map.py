"""Ordered bounded map and cooperative waits used by the game catalog."""

from pathlib import Path
import sys
import threading
import time
import unittest

SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet
from test_runtime_stream import http_fixture, reply


class RuntimeMapTest(unittest.TestCase):
    def setUp(self):
        self.net = RuntimeNet()
        self.addCleanup(self.net.close)

    def test_parallel_mapper_gets_original_index_and_preserves_order(self):
        barrier = threading.Barrier(2)
        finished = []
        second = threading.Event()

        def mapper(item, index):
            barrier.wait(timeout=1)
            if index == 0:
                self.assertTrue(second.wait(1))
            else:
                second.set()
            finished.append(index)
            return (item, index)

        self.assertEqual(self.net.map(["one", "two"], mapper, 2), [("one", 0), ("two", 1)])
        self.assertEqual(finished, [1, 0])
        self.assertEqual(self.net.map([], mapper), [])

    def test_default_concurrency_is_four_and_explicit_one_is_serial(self):
        barrier = threading.Barrier(4)
        guard = threading.Lock()
        active = peak = 0

        def mapper(item, index):
            nonlocal active, peak
            with guard:
                active += 1
                peak = max(peak, active)
            if index < 4:
                barrier.wait(1)
            self.net.sleep(1)
            with guard:
                active -= 1
            return index

        self.assertEqual(self.net.map(range(12), mapper), list(range(12)))
        self.assertEqual(peak, 4)
        order = []
        self.assertEqual(self.net.map([3, 2, 1], lambda item, index: order.append(item) or item, 1), [3, 2, 1])
        self.assertEqual(order, [3, 2, 1])

    def test_failure_interrupts_sibling_sleep_without_starting_more_items(self):
        entered = threading.Event()
        finished = threading.Event()
        visited = []

        def mapper(item, index):
            visited.append(index)
            if index == 0:
                entered.set()
                try:
                    self.net.sleep(10000)
                finally:
                    finished.set()
            if index == 1:
                self.assertTrue(entered.wait(1))
                raise LookupError("loader failed")
            return item

        before = time.monotonic()
        with self.assertRaisesRegex(LookupError, "loader failed"):
            self.net.map(range(100), mapper, 2)
        self.assertTrue(finished.wait(0.5))
        self.assertLess(time.monotonic() - before, 0.5)
        self.assertEqual(sorted(visited), [0, 1])
        self.assertEqual(self.net.map([7], lambda item, index: item), [7])

    def test_generator_close_propagates_into_map_workers_and_http_reads(self):
        entered, release = threading.Event(), threading.Event()
        errors = []

        def respond(handler):
            if handler.path == "/wait":
                entered.set()
                release.wait(2)
            reply(handler, b"ok")

        with http_fixture(respond) as server:
            def chunks():
                self.net.map([server.origin + "/wait"], lambda url, index: self.net.req(url))
                yield b"late"

            reader = self.net.stream(chunks())["stream"]

            def read():
                try:
                    reader.read()
                except BaseException as error:
                    errors.append(error)

            worker = threading.Thread(target=read, daemon=True)
            worker.start()
            try:
                self.assertTrue(entered.wait(1))
                reader.close()
                worker.join(0.5)
                self.assertFalse(worker.is_alive())
                self.assertIsInstance(errors[0], InterruptedError)
                self.assertEqual(self.net.req(server.origin + "/ok")["content"], "ok")
            finally:
                release.set()
                reader.close()
                worker.join(2)

    def test_validation_precedes_mapper_and_sleep_is_cancelled_by_owner(self):
        calls = []
        for concurrency in (0, -1, True, 1.5, 33):
            with self.assertRaises(ValueError):
                self.net.map([1], lambda item, index: calls.append(item), concurrency)
        for items in (None, "abc", b"abc", {}):
            with self.assertRaises(TypeError):
                self.net.map(items, lambda item, index: calls.append(item))
        with self.assertRaises(TypeError):
            self.net.map([], None)
        with self.assertRaises(ValueError):
            self.net.map(range(10001), lambda item, index: calls.append(item))
        self.assertEqual(calls, [])
        for milliseconds in (-1, True, None, float("inf")):
            with self.assertRaises(ValueError):
                self.net.sleep(milliseconds)
        self.net.sleep(0)
        before = time.monotonic()
        self.net.sleep(20)
        self.assertGreaterEqual(time.monotonic() - before, 0.015)
        entered, finished = threading.Event(), threading.Event()
        errors = []

        def wait():
            try:
                entered.set()
                self.net.sleep(10000)
            except BaseException as error:
                errors.append(error)
            finally:
                finished.set()

        worker = threading.Thread(target=wait, daemon=True)
        worker.start()
        self.assertTrue(entered.wait(1))
        self.net.close()
        self.assertTrue(finished.wait(0.5))
        worker.join(0.5)
        self.assertIsInstance(errors[0], (InterruptedError, RuntimeError))
        with self.assertRaises(RuntimeError):
            self.net.map([1], lambda item, index: item)


if __name__ == "__main__":
    unittest.main()
