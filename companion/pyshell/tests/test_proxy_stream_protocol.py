"""Real runner/RuntimeNet stream ownership and bounded protocol integration."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest

RUNNER = Path(__file__).resolve().parents[1] / "runner.py"
PAYLOAD = b"\x00\x80\xff" * (2 * 1024 * 1024 + 1)
SCRIPT = '''
import io, json, os
from base.net import RuntimeNet, RuntimeReader
class Spider:
    def init(self, ext=''):
        config = json.loads(ext)
        self.origin, self.marker = config['origin'], config['marker']
        self._net = RuntimeNet()
        self.items, self.closed, self.reads = [], set(), 0
        original_close = getattr(RuntimeReader.close, '_original', RuntimeReader.close)
        original_read = getattr(RuntimeReader.read, '_original', RuntimeReader.read)
        owner = self
        def close(reader):
            try: return original_close(reader)
            finally:
                if reader in owner.items and id(reader) not in owner.closed:
                    owner.closed.add(id(reader))
                    with open(owner.marker, 'a') as out: out.write('close\\n')
        close._original = original_close
        RuntimeReader.close = close
        def read(reader, size=65536):
            owner.reads += 1
            return original_read(reader, size)
        read._original = original_read
        RuntimeReader.read = read
    def proxy(self, params):
        kind = params.get('kind', 'small')
        if kind == 'unmanaged': return [200, 'text/plain', io.BytesIO(b'secret-canary')]
        if kind == 'generator-blocked':
            def chunks():
                reader = self._net.openStream(self.origin + '/blocked', {'timeout': 3000, 'callTimeout': 0})
                try:
                    yield reader.read(65536)
                finally:
                    reader.close()
                    with open(self.marker + '.finished', 'w') as out: out.write('finished')
            reader = self._net.stream(chunks())['stream']
            result = {'code': 206, 'contentType': 'video/x-flv', 'headers': {}}
        else:
            path = '/blocked' if kind == 'http-blocked' else '/huge' if kind == 'huge' else '/small'
            result = self._net.stream(self.origin + path, {'timeout': 3000, 'callTimeout': 0})
            reader = result['stream']
        if kind == 'close-error':
            close = reader.close
            def fail_close():
                close()
                raise ValueError('secret-canary')
            reader.close = fail_close
        self.items.append(reader)
        status, mime, headers = result['code'], result['contentType'], result['headers']
        if kind == 'status': status = True
        if kind == 'mime': mime = 'bad\\r\\nSecret: secret-canary'
        if kind == 'header': headers = {'X-Canary': 'secret-canary\\r\\nBAD'}
        if kind == 'fifth': return [status, mime, reader, headers, True]
        if kind == 'read-error':
            def fail(size=65536): raise ValueError('secret-canary')
            reader.read = fail
        return [status, mime, reader, headers]
    def action(self):
        return {'opened': len(self.items), 'closed': len(self.closed),
                'active': len(self.items) - len(self.closed), 'reads': self.reads}
'''


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAYLOAD if self.path == "/huge" else b"\x00\x80\xff"
        self.send_response(206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Range", "bytes 0-%s/%s" % (len(body) - 1, len(body)))
        self.end_headers()
        try:
            if self.path == '/blocked':
                self.wfile.flush()
                self.server.blocked.set()
                self.server.release.wait(5)
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


class Runner:
    def __init__(self, root, origin):
        self.script = root / "source.py"
        self.script.write_text(SCRIPT, encoding="utf-8")
        self.marker = root / "closed.txt"
        self.ext = json.dumps({"origin": origin, "marker": str(self.marker)})
        self.errors = (root / "stderr.log").open("w", encoding="utf-8")
        env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1", NO_PROXY="127.0.0.1,localhost")
        self.child = subprocess.Popen([sys.executable, "-B", str(RUNNER)], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=self.errors, text=True, encoding="utf-8", env=env)
        self.messages = queue.Queue()
        self.pending = {}
        self.sequence = 0
        def receive():
            for line in self.child.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)
        self.receiver = threading.Thread(target=receive, daemon=True)
        self.receiver.start()
        ready = self.messages.get(timeout=10)
        if ready.get("type") != "ready":
            raise AssertionError("runner must report ready")
        self.load()

    def send(self, **request):
        self.sequence += 1
        request["id"] = self.sequence
        self.child.stdin.write(json.dumps(request) + "\n")
        self.child.stdin.flush()
        return self.sequence

    def receive(self, request_id, timeout=10):
        if request_id in self.pending:
            return self.pending.pop(request_id)
        while True:
            response = self.messages.get(timeout=timeout)
            if response is None:
                raise AssertionError("runner exited early")
            if response.get("type") == "ping":
                continue
            if response.get("id") == request_id:
                return response
            self.pending[response['id']] = response

    def request(self, **request):
        return self.receive(self.send(**request))

    def result(self, **request):
        response = self.request(**request)
        if response.get("type") != "result":
            raise AssertionError("expected result, got %r" % response)
        return response.get("value")

    def load(self):
        return self.result(action="load", api=str(self.script), ext=self.ext)

    def proxy(self, kind="small"):
        return self.result(action="call", method="proxy", args=[{"kind": kind}])

    def stats(self):
        return self.result(action="call", method="action", args=[])

    def close(self, exit_request=True):
        if self.child.poll() is None:
            if exit_request:
                self.result(action="exit")
            self.child.stdin.close()
            try:
                self.child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=5)
                raise
        self.receiver.join(timeout=2)
        self.child.stdout.close()
        self.errors.close()


class ProxyStreamProtocolTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        cls.http.blocked, cls.http.release = threading.Event(), threading.Event()
        cls.worker = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.worker.start()
        cls.origin = "http://127.0.0.1:%s" % cls.http.server_port

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.worker.join(timeout=2)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xiugou-stream-protocol-")
        self.addCleanup(self.temporary.cleanup)
        self.runner = Runner(Path(self.temporary.name), self.origin)
        self.addCleanup(self.runner.close)

    def handle(self, kind="small"):
        result = self.runner.proxy(kind)
        self.assertEqual(result["__xiugou_proxy__"], 2)
        self.assertEqual(result["status"], 206)
        self.assertNotIn("bodyBase64", result)
        self.assertIsInstance(result["streamId"], str)
        return result["streamId"]

    def failed(self, **request):
        response = self.runner.request(**request)
        self.assertEqual(response.get("type"), "error")
        self.assertEqual(response.get("error"), "script proxy failed")
        self.assertNotIn("secret-canary", json.dumps(response))

    def test_large_binary_is_chunked_and_eof_releases_reader(self):
        handle = self.handle("huge")
        self.assertEqual(self.runner.stats()["reads"], 0)
        digest = hashlib.sha256()
        length = 0
        while True:
            part = self.runner.result(action="streamRead", streamId=handle, size=65536)
            data = base64.b64decode(part["dataBase64"], validate=True)
            self.assertLessEqual(len(data), 65536)
            digest.update(data)
            length += len(data)
            if part["eof"]:
                break
            self.assertTrue(data, "empty non-EOF chunks must never spin")
        self.assertEqual(length, len(PAYLOAD))
        self.assertEqual(digest.digest(), hashlib.sha256(PAYLOAD).digest())
        self.assertEqual(self.runner.stats()["active"], 0)
        self.runner.result(action="streamClose", streamId=handle)
        self.failed(action="streamRead", streamId=handle, size=1)

    def test_capacity_reload_and_stale_handle_isolation(self):
        handles = [self.handle() for _ in range(16)]
        self.assertEqual(len(set(handles)), 16)
        self.failed(action="call", method="proxy", args=[{}])
        self.assertEqual(self.runner.stats()["active"], 16)
        self.assertEqual(self.runner.stats()["closed"], 1, "overflow must close its unregistered reader")
        self.runner.result(action="streamClose", streamId=handles[0])
        self.runner.result(action="streamClose", streamId=handles[0])
        next_handle = self.handle()
        self.assertNotIn(next_handle, handles)
        self.runner.load()
        self.assertEqual(len(self.runner.marker.read_text().splitlines()), 18)
        replacement = self.handle()
        for old in handles + [next_handle]:
            self.failed(action="streamRead", streamId=old, size=1)
            self.runner.result(action="streamClose", streamId=old)
        self.assertEqual(self.runner.stats()["active"], 1)
        self.runner.result(action="streamClose", streamId=replacement)
        self.assertEqual(self.runner.stats()["active"], 0)

    def test_invalid_metadata_and_unmanaged_reader_are_safe(self):
        for kind in ("status", "mime", "header", "fifth", "unmanaged"):
            with self.subTest(kind=kind):
                self.failed(action="call", method="proxy", args=[{"kind": kind}])
                self.assertEqual(self.runner.stats()["active"], 0)

    def test_invalid_read_and_read_error_close_the_owned_reader(self):
        for size in (0, -1, 65537, True, 1.5, "64"):
            with self.subTest(size=size):
                handle = self.handle()
                self.failed(action="streamRead", streamId=handle, size=size)
                self.assertEqual(self.runner.stats()["active"], 0)
        handle = self.handle("read-error")
        self.failed(action="streamRead", streamId=handle, size=1)
        self.assertEqual(self.runner.stats()["active"], 0)

    def test_control_close_interrupts_only_target_sdk_stream(self):
        for kind in ('http-blocked', 'generator-blocked'):
            with self.subTest(kind=kind):
                self.http.blocked.clear()
                self.http.release.clear()
                sibling, target = self.handle(), self.handle(kind)
                read_id = self.runner.send(action='streamRead', streamId=target, size=65536)
                self.assertTrue(self.http.blocked.wait(2), 'real SDK upstream body is pending')
                close_id = self.runner.send(action='streamClose', streamId=target)
                read = close = None
                try:
                    close = self.runner.receive(close_id, timeout=1)
                    self.assertEqual(close['type'], 'result')
                    read = self.runner.receive(read_id, timeout=1)
                    self.assertEqual(read['type'], 'error')
                    self.assertEqual(read['error'], 'script proxy failed')
                    part = self.runner.result(action='streamRead', streamId=sibling, size=3)
                    self.assertEqual(base64.b64decode(part['dataBase64']), b'\x00\x80\xff')
                    self.assertEqual(self.runner.stats()['active'], 1)
                    if kind == 'generator-blocked':
                        self.assertTrue(Path(str(self.runner.marker) + '.finished').exists())
                    self.runner.result(action='streamClose', streamId=sibling)
                    self.assertEqual(self.runner.stats()['active'], 0)
                finally:
                    self.http.release.set()
                    if read is None:
                        self.runner.receive(read_id)
                    if close is None:
                        self.runner.receive(close_id)
                    self.runner.result(action='streamClose', streamId=sibling)

    def test_control_close_failure_is_reported_without_sensitive_details(self):
        target = self.handle('close-error')
        self.failed(action='streamClose', streamId=target)
        self.assertEqual(self.runner.stats()['active'], 0)
        self.runner.result(action='streamClose', streamId=target)

    def test_exit_closes_handles_without_reading(self):
        self.handle()
        self.handle()
        self.assertEqual(self.runner.stats()["reads"], 0)
        self.runner.close()
        self.assertEqual(len(self.runner.marker.read_text().splitlines()), 2)

    def test_stdin_eof_closes_handles_without_reading(self):
        self.handle()
        self.runner.close(exit_request=False)
        self.assertEqual(len(self.runner.marker.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
