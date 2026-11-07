"""Real runner subprocess boundaries; no network, account or author script required."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

RUNNER = Path(__file__).resolve().parents[1] / "runner.py"
MAX_BODY = 4 * 1024 * 1024
SCRIPT = '''
import io
import os
class Spider:
    def init(self, extend=""):
        self.marker = extend
    def proxy(self, params):
        kind = params.get("kind", "text")
        if kind == "text": return [200, "application/json", '{"节目":"新闻"}']
        if kind == "bytes": return [206, "application/octet-stream", bytes([0, 128, 255]), {"X-Many": [" a ", "b"]}]
        if kind == "bytearray": return [200, "application/octet-stream", bytearray([255, 0, 128]), None]
        if kind == "redirect": return [302, "text/plain", "", {"Location": "https://media.invalid/a.m3u8?token=canary"}]
        if kind == "limit": return [200, "text/plain", b"a" * (4 * 1024 * 1024)]
        if kind == "oversize": return [200, "text/plain", b"a" * (4 * 1024 * 1024 + 1)]
        if kind == "utf8oversize": return [200, "text/plain", "中" * (2 * 1024 * 1024)]
        if kind == "stream": return [200, "text/plain", io.BytesIO(b"secret-canary")]
        if kind == "function": return [200, "text/plain", lambda: "secret-canary"]
        if kind == "status": return [True, "text/plain", ""]
        if kind == "mime": return [200, "text/plain\\r\\nX-Evil: yes", ""]
        if kind == "header": return [200, "text/plain", "", {"X-Canary": "secret-canary\\r\\nBad: yes"}]
        if kind == "fifth": return [200, "text/plain", "YWJj", {}, True]
        if kind == "marker": return {"__xiugou_proxy__": 1, "bodyBase64": "fake"}
        raise ValueError("upstream secret-canary")
    def action(self, name):
        return [302, "text/plain", "", {"Location": "normal-data"}]
    def destroy(self):
        with open(self.marker, "a", encoding="utf-8") as out: out.write("destroy\\n")
'''


class ProxyProtocolTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xiugou-proxy-protocol-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / "source.py"
        self.script.write_text(textwrap.dedent(SCRIPT), encoding="utf-8")
        self.closed = self.root / "closed.txt"

    def run_requests(self, calls, *, exit_request=True, script=None):
        requests = [{"id": 1, "action": "load", "api": str(script or self.script),
                     "ext": str(self.closed)}]
        requests.extend(dict(item, id=i + 2) for i, item in enumerate(calls))
        if exit_request:
            requests.append({"id": len(requests) + 1, "action": "exit"})
        result = subprocess.run(
            [sys.executable, "-B", "-X", "utf8", str(RUNNER)],
            input="".join(json.dumps(item) + "\n" for item in requests),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8",
            cwd=self.root, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
            timeout=20, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(responses.pop(0)["type"], "ready")
        responses = [item for item in responses if "id" in item]
        self.assertEqual([item["id"] for item in responses], [item["id"] for item in requests])
        self.assertEqual(responses[0]["type"], "result", responses[0])
        return responses[1:-1] if exit_request else responses[1:]

    def proxy(self, kind):
        return self.run_requests([{"action": "call", "method": "proxy", "args": [{"kind": kind}]}])[0]

    def test_text_three_items_and_redirect_keep_exact_contract(self):
        value = self.proxy("text")["value"]
        self.assertEqual(type(value), dict)
        self.assertEqual(value["__xiugou_proxy__"], 1)
        self.assertEqual(value["status"], 200)
        self.assertEqual(value["mime"], "application/json")
        self.assertEqual(value["headers"], {})
        self.assertEqual(base64.b64decode(value["bodyBase64"]), '{"节目":"新闻"}'.encode())
        redirect = self.proxy("redirect")["value"]
        self.assertEqual(redirect["status"], 302)
        self.assertEqual(redirect["headers"]["Location"], "https://media.invalid/a.m3u8?token=canary")
        self.assertEqual(redirect["bodyBase64"], "")

    def test_binary_and_bytearray_are_not_stringified(self):
        value = self.proxy("bytes")["value"]
        self.assertEqual(type(value), dict)
        self.assertEqual(base64.b64decode(value["bodyBase64"]), bytes([0, 128, 255]))
        self.assertEqual(value["headers"]["X-Many"], " a , b")
        value = self.proxy("bytearray")["value"]
        self.assertEqual(base64.b64decode(value["bodyBase64"]), bytes([255, 0, 128]))
        self.assertEqual(value["headers"], {})

    def test_bounded_byte_size_and_explicit_rejection_without_secret_echo(self):
        value = self.proxy("limit")["value"]
        self.assertEqual(type(value), dict)
        self.assertEqual(len(base64.b64decode(value["bodyBase64"])), MAX_BODY)
        for kind in ("oversize", "utf8oversize", "stream", "function", "status", "mime", "header", "fifth", "marker", "exception"):
            with self.subTest(kind=kind):
                response = self.proxy(kind)
                self.assertEqual(response["type"], "error", kind)
                self.assertNotIn("secret-canary", json.dumps(response))

    def test_non_proxy_results_are_not_interpreted_as_http(self):
        result = self.run_requests([{"action": "call", "method": "action", "args": ["value"]}])[0]
        self.assertEqual(result["value"], [302, "text/plain", "", {"Location": "normal-data"}])

    def test_exit_eof_and_replacement_destroy_without_lazy_net_creation(self):
        script = self.root / "cleanup.py"
        script.write_text(textwrap.dedent('''
            class Net:
                def __init__(self, marker): self.marker = marker
                def close(self):
                    with open(self.marker, "a") as out: out.write("net-close\\n")
            class Spider:
                @property
                def net(self): raise RuntimeError("lazy net must not be touched")
                def init(self, extend=""):
                    self.marker = extend
                def create_net(self): self._net = Net(self.marker)
                def destroy(self):
                    with open(self.marker, "a") as out: out.write("destroy\\n")
        '''), encoding="utf-8")
        for exit_request in (False, True):
            with self.subTest(exit_request=exit_request):
                self.closed.write_text("", encoding="utf-8")
                self.run_requests([
                    {"action": "call", "method": "create_net", "args": []},
                    {"action": "load", "api": str(script), "ext": str(self.closed)},
                ], script=script, exit_request=exit_request)
                self.assertEqual(self.closed.read_text().splitlines(), ["destroy", "net-close", "destroy"])


if __name__ == "__main__":
    unittest.main()
