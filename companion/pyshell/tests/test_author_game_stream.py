"""Original FLV/YY helpers over loopback HTTP and the public managed reader."""

import importlib.util
import os
from pathlib import Path
import sys
import threading
import time
import unittest

from test_runtime_stream import http_fixture, reply

SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.net import RuntimeNet, RuntimeReader

DEFAULT_AUTHOR = Path(r"E:\code\tvbox_1102\live-python\vod")
FLV_HEADER = b"FLV\x01\x05\x00\x00\x00\x09\x00\x00\x00\x00"


def author_module(filename, variable):
    source = Path(os.environ.get(variable) or DEFAULT_AUTHOR / filename)
    if not source.is_file():
        raise unittest.SkipTest("author helper missing; set " + variable)
    spec = importlib.util.spec_from_file_location("author_" + source.stem, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def flv_tag(kind, stamp, body):
    head = bytes((kind,)) + len(body).to_bytes(3, "big")
    head += (stamp & 0xffffff).to_bytes(3, "big") + bytes((stamp >> 24,)) + b"\0\0\0"
    return head + body + (len(body) + 11).to_bytes(4, "big")


def decode_tags(data):
    tags = []
    position = len(FLV_HEADER)
    if data[:position] != FLV_HEADER:
        raise AssertionError("invalid output FLV header")
    while position < len(data):
        length = int.from_bytes(data[position + 1:position + 4], "big")
        end = position + 11 + length
        if len(data) < end + 4 or int.from_bytes(data[end:end + 4], "big") != length + 11:
            raise AssertionError("invalid output FLV tag framing")
        stamp = int.from_bytes(data[position + 4:position + 7], "big") + data[position + 7] * 16777216
        tags.append((data[position], stamp, data[position + 11:end]))
        position = end + 4
    return tags


class AuthorGameStreamTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stream_module = author_module("game_live_stream.py", "XIUGOU_AUTHOR_GAME_STREAM")
        cls.yy_module = author_module("game_live_yy.py", "XIUGOU_AUTHOR_GAME_YY")

    def setUp(self):
        self.net = RuntimeNet()
        self.addCleanup(self.net.close)

    def stream(self, url, *, sleep=None, min_duration=0, normalize=False):
        def open_source():
            return self.net.openStream(url, {
                "timeout": 15000, "callTimeout": 0,
                "headers": {"X-Fixture": "original-helper"},
            })

        source = self.stream_module.flv_stream(
            open_source, sleep or self.net.sleep, min_duration,
            self.yy_module.Normalizer if normalize else None)
        reader = self.net.stream(source)["stream"]
        self.addCleanup(reader.close)
        return reader

    def test_original_helper_is_lazy_and_large_whole_tag_is_split_without_reconnect(self):
        payload = b"\x17\x01" + b"\x00\x80\xff" * 30000
        body = FLV_HEADER + flv_tag(9, 500, payload)
        with http_fixture(lambda handler: reply(handler, body)) as server:
            reader = self.stream(server.origin + "/large.flv")
            self.assertIsInstance(reader, RuntimeReader)
            self.assertEqual(server.requests, [])
            self.assertEqual(reader.read(), FLV_HEADER)
            chunks = [reader.read(), reader.read()]
            self.assertEqual([len(chunk) for chunk in chunks], [65536, len(body) - 13 - 65536])
            self.assertEqual(decode_tags(FLV_HEADER + b"".join(chunks)), [(9, 0, payload)])
            reader.close()
            self.assertEqual(len(server.requests), 1)
            self.assertEqual(server.requests[0]["headers"]["X-Fixture"], "original-helper")

    def test_reconnect_keeps_one_header_skips_new_metadata_and_unwraps_timestamps(self):
        bodies = [
            FLV_HEADER + flv_tag(18, 0, b"first metadata")
            + flv_tag(9, 0xfffffff0, b"\x17\x01first") + flv_tag(9, 16, b"\x17\x01second"),
            FLV_HEADER + flv_tag(18, 0, b"discard metadata")
            + flv_tag(9, 500, b"\x17\x01third") + flv_tag(9, 700, b"\x17\x01fourth"),
        ]
        received = []

        def respond(handler):
            received.append(handler.path)
            reply(handler, bodies[min(len(received) - 1, 1)])

        with http_fixture(respond) as server:
            reader = self.stream(server.origin + "/reconnect.flv")
            output = reader.read() + reader.read() + reader.read()
            reader.close()
            self.assertEqual(len(received), 2)
            tags = decode_tags(output)
            self.assertEqual([tag[1] for tag in tags], [0, 0, 32, 33, 233])
            self.assertEqual([tag[2] for tag in tags if tag[0] == 18], [b"first metadata"])
            self.assertEqual(output.count(FLV_HEADER), 1)

    def test_premature_eof_uses_real_bounded_backoff_then_propagates_failure(self):
        delays = []

        def sleep(milliseconds):
            delays.append(milliseconds)
            self.net.sleep(milliseconds)

        body = FLV_HEADER + flv_tag(9, 7, b"\x17\x01short")
        with http_fixture(lambda handler: reply(handler, body)) as server:
            reader = self.stream(server.origin, sleep=sleep, min_duration=10000)
            chunks = []
            with self.assertRaises(EOFError):
                for _ in range(10):
                    chunks.append(reader.read())
            self.assertEqual(delays, [500, 1000, 2000])
            self.assertEqual(len(server.requests), 4)
            self.assertEqual([stamp for kind, stamp, _ in decode_tags(b"".join(chunks)) if kind == 9],
                             [0, 1, 2, 3])
            reader.close()

    def test_close_during_flv_read_interrupts_only_owned_upstream(self):
        waiting, release, peer_closed = threading.Event(), threading.Event(), threading.Event()

        def respond(handler):
            if handler.path == "/other":
                reply(handler, b"independent")
                return
            handler.send_response(200)
            handler.send_header("Content-Length", "100000")
            handler.end_headers()
            handler.wfile.write(FLV_HEADER)
            handler.wfile.flush()
            waiting.set()
            handler.connection.settimeout(2)
            try:
                if not handler.connection.recv(1):
                    peer_closed.set()
            except ConnectionResetError:
                peer_closed.set()
            finally:
                release.wait(2)

        with http_fixture(respond) as server:
            reader = self.stream(server.origin + "/blocked")
            self.assertEqual(reader.read(), FLV_HEADER)
            errors, finished = [], threading.Event()

            def consume():
                try:
                    reader.read()
                except BaseException as error:
                    errors.append(error)
                finally:
                    finished.set()

            worker = threading.Thread(target=consume, daemon=True)
            worker.start()
            try:
                self.assertTrue(waiting.wait(1))
                before = time.monotonic()
                reader.close()
                self.assertTrue(finished.wait(0.5))
                self.assertLess(time.monotonic() - before, 0.5)
                self.assertTrue(peer_closed.wait(0.5))
                self.assertEqual(len(errors), 1)
                self.assertIsInstance(errors[0], InterruptedError)
                self.assertEqual(self.net.req(server.origin + "/other")["content"], "independent")
            finally:
                release.set()
                reader.close()
                worker.join(2)

    def test_close_during_original_backoff_prevents_reopen(self):
        sleeping, finished = threading.Event(), threading.Event()
        errors = []

        def sleep(milliseconds):
            self.assertEqual(milliseconds, 500)
            sleeping.set()
            self.net.sleep(milliseconds)

        body = FLV_HEADER + flv_tag(9, 0, b"\x17\x01short")
        with http_fixture(lambda handler: reply(handler, body)) as server:
            reader = self.stream(server.origin, sleep=sleep, min_duration=10000)
            self.assertEqual(reader.read(), FLV_HEADER)
            self.assertTrue(reader.read())

            def consume():
                try:
                    reader.read()
                except BaseException as error:
                    errors.append(error)
                finally:
                    finished.set()

            worker = threading.Thread(target=consume, daemon=True)
            worker.start()
            try:
                self.assertTrue(sleeping.wait(1))
                reader.close()
                self.assertTrue(finished.wait(0.5))
                self.assertEqual(len(errors), 1)
                self.assertIsInstance(errors[0], InterruptedError)
                self.assertEqual(len(server.requests), 1)
                self.assertEqual(self.net.stream(iter([b"sibling"]))["stream"].read(), b"sibling")
            finally:
                reader.close()
                worker.join(2)

    def test_yy_normalizer_inserts_valid_aac_silence_and_preserves_restart_order(self):
        for config, silence in ((b"\xaf\x00\x12\x08", b"\x00\xc8\x00\x80\x23\x80"),
                                (b"\xaf\x00\x12\x10", b"\x21\x00\x49\x90\x02\x19\x00\x23\x80")):
            with self.subTest(config=config):
                body = (FLV_HEADER + flv_tag(8, 0, config)
                        + flv_tag(9, 0, b"\x17\x01start") + flv_tag(9, 1000, b"\x17\x01next")
                        + flv_tag(9, 1000, b"\x17\x01duplicate") + flv_tag(18, 0, b"restart")
                        + flv_tag(9, 20, b"\x17\x01restarted") + flv_tag(9, 60, b"\x17\x01continued"))
                with http_fixture(lambda handler: reply(handler, body)) as server:
                    reader = self.stream(server.origin, normalize=True)
                    tags = decode_tags(reader.read() + reader.read())
                    reader.close()
                videos = [(stamp, data) for kind, stamp, data in tags if kind == 9]
                self.assertEqual([stamp for stamp, _ in videos], [0, 1000, 1001, 1041])
                self.assertNotIn(b"\x17\x01duplicate", [data for _, data in videos])
                audio = [(stamp, data) for kind, stamp, data in tags if kind == 8 and data[1] == 1]
                self.assertEqual(len(audio), 26)
                self.assertEqual(audio[0], (0, b"\xaf\x01" + silence))
                self.assertTrue(all(data == b"\xaf\x01" + silence for _, data in audio))
                self.assertTrue(all(b[0] - a[0] in (23, 24) for a, b in zip(audio, audio[1:])))

    def test_yy_timestamp_wrap_and_invalid_audio_config_do_not_fabricate_audio(self):
        body = (FLV_HEADER + flv_tag(8, 0, b"\xaf\x00\x12\x00")
                + flv_tag(9, 0xfffffff0, b"\x17\x01first") + flv_tag(9, 16, b"\x17\x01second"))
        with http_fixture(lambda handler: reply(handler, body)) as server:
            reader = self.stream(server.origin, normalize=True)
            tags = decode_tags(reader.read() + reader.read())
            reader.close()
        self.assertEqual([stamp for kind, stamp, _ in tags if kind == 9], [0, 32])
        self.assertEqual([data for kind, _, data in tags if kind == 8], [b"\xaf\x00\x12\x00"])

    def test_original_parser_rejects_bad_header_and_tag_lengths_without_retry(self):
        for body in (b"not a FLV stream", FLV_HEADER + flv_tag(9, 0, b"\x17\x01bad")[:-4] + b"\0\0\0\0"):
            with self.subTest(body=body), http_fixture(lambda handler: reply(handler, body)) as server:
                reader = self.stream(server.origin)
                with self.assertRaises(ValueError):
                    for _ in range(3):
                        reader.read()
                reader.close()
                self.assertEqual(len(server.requests), 1)


if __name__ == "__main__":
    unittest.main()
