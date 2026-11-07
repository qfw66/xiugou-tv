"""Synchronous, isolated JavaScript evaluation through the host's restricted JVM helper."""

import json
import math
import os
import subprocess
import threading
import time


_MAX_INPUT = 1024 * 1024
_MAX_OUTPUT = 1024 * 1024
_MAX_DEPTH = 64
_MAX_NODES = 10000
_ERRORS = {
    "invalid-request": "JavaScript request is invalid",
    "input-limit": "JavaScript input exceeds the limit",
    "js-error": "JavaScript evaluation failed",
    "unsupported-result": "JavaScript result must be a synchronous JSON value",
    "output-limit": "JavaScript output exceeds the limit",
    "engine-error": "JavaScript engine failed",
}


def _validate_json(value, depth=0, budget=None, ancestors=None):
    if budget is None:
        budget, ancestors = [_MAX_NODES], set()
    budget[0] -= 1
    if budget[0] < 0 or depth > _MAX_DEPTH:
        raise ValueError("JavaScript JSON exceeds the structure limit")
    if value is None or type(value) is bool:
        return
    if type(value) is str:
        if len(value) > _MAX_INPUT:
            raise ValueError("JavaScript input exceeds the limit")
        return
    if type(value) is int:
        if abs(value) > 9007199254740991:
            raise ValueError("JavaScript integer exceeds the safe range")
        return
    if type(value) is float:
        if not math.isfinite(value):
            raise ValueError("JavaScript numbers must be finite")
        return
    if type(value) not in (dict, list):
        raise TypeError("JavaScript globals must contain JSON values")
    identity = id(value)
    if identity in ancestors:
        raise ValueError("JavaScript globals must not contain cycles")
    ancestors.add(identity)
    try:
        if type(value) is dict:
            for key, item in value.items():
                if type(key) is not str:
                    raise TypeError("JavaScript JSON keys must be strings")
                _validate_json(key, depth + 1, budget, ancestors)
                _validate_json(item, depth + 1, budget, ancestors)
        else:
            for item in value:
                _validate_json(item, depth + 1, budget, ancestors)
    finally:
        ancestors.remove(identity)


def _encode_request(request):
    payload = bytearray()
    encoder = json.JSONEncoder(ensure_ascii=True, allow_nan=False, separators=(",", ":"))
    for part in encoder.iterencode(request):
        chunk = part.encode("ascii")
        if len(payload) + len(chunk) > _MAX_INPUT:
            raise ValueError("JavaScript input exceeds the limit")
        payload.extend(chunk)
    return bytes(payload)


class RuntimeJS:
    """eval(source, {globals: JSON object, timeout: positive integer milliseconds}).

    Each call starts a fresh process and context. The default total deadline is
    5000 ms. Input/output are limited to 1 MiB, depth 64 and 10000 JSON nodes;
    integers in globals must fit JavaScript's exact integer range. Errors never
    include source, globals, guest exception text, or raw JVM diagnostics.
    """

    def eval(self, source, options=None):
        started = time.monotonic()
        if type(source) is not str:
            raise TypeError("JavaScript source must be a string")
        if len(source) > _MAX_INPUT:
            raise ValueError("JavaScript input exceeds the limit")
        if options is None:
            options = {}
        if type(options) is not dict or set(options) - {"globals", "timeout"}:
            raise TypeError("JavaScript options must contain only globals and timeout")
        timeout = options.get("timeout", 5000)
        if type(timeout) is not int or not 0 < timeout <= 2147483647:
            raise ValueError("JavaScript timeout must be a positive 32-bit integer in milliseconds")
        globals_ = options.get("globals", {})
        if type(globals_) is not dict:
            raise TypeError("JavaScript globals must be a JSON object")
        if any(name in globals_ for name in ("md5X", "__proto__", "constructor", "prototype")):
            raise ValueError("JavaScript globals must not replace protected names")
        _validate_json(globals_)
        payload = _encode_request({"source": source, "globals": globals_, "timeout": timeout})
        deadline = started + timeout / 1000.0
        java = os.environ.get("XIUGOU_JAVA_BIN", "")
        classpath = os.environ.get("XIUGOU_JAVA_CLASSPATH", "")
        if not os.path.isabs(java) or not classpath or any(
                not os.path.isabs(entry) for entry in classpath.split(os.pathsep)):
            raise RuntimeError("JavaScript requires the host's absolute Java executable and classpath")
        if time.monotonic() >= deadline:
            raise TimeoutError("JavaScript evaluation timed out")
        environment = dict(os.environ)
        for key in list(environment):
            if key.upper() in {"JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"}:
                del environment[key]
        command = [java, "-Xmx128m", "-Xss512k", "-Dfile.encoding=UTF-8", "-cp", classpath,
                   "com.fongmi.companion.ScriptJsEvaluator"]
        try:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, shell=False, env=environment,
                                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except OSError:
            raise RuntimeError("JavaScript helper could not start") from None
        output = bytearray()
        overflow = threading.Event()
        io_failed = threading.Event()

        def read_stdout():
            try:
                while True:
                    chunk = process.stdout.read(8192)
                    if not chunk:
                        return
                    if len(output) + len(chunk) > _MAX_OUTPUT:
                        overflow.set()
                        process.kill()
                        return
                    output.extend(chunk)
            except OSError:
                io_failed.set()

        def drain_stderr():
            # Guest output and raw JVM errors may contain credentials; never log them.
            try:
                while process.stderr.read(4096):
                    pass
            except OSError:
                io_failed.set()

        def send_request():
            try:
                process.stdin.write(payload)
                process.stdin.close()
            except OSError:
                io_failed.set()

        workers = [threading.Thread(target=target, name="runtime-js-" + name, daemon=True)
                   for target, name in ((read_stdout, "stdout"), (drain_stderr, "stderr"),
                                        (send_request, "stdin"))]
        try:
            for worker in workers:
                worker.start()
            try:
                process.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise TimeoutError("JavaScript evaluation timed out") from None
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            for worker in workers:
                if worker.ident is not None:
                    worker.join()
            for stream in (process.stdin, process.stdout, process.stderr):
                try:
                    stream.close()
                except OSError:
                    pass
        if overflow.is_set():
            raise RuntimeError(_ERRORS["output-limit"])
        if process.returncode or io_failed.is_set():
            raise RuntimeError("JavaScript helper failed")
        try:
            result = json.loads(output.decode("utf-8"))
            if type(result) is not dict or type(result.get("ok")) is not bool:
                raise ValueError()
            if result["ok"]:
                if set(result) != {"ok", "result"}:
                    raise ValueError()
                _validate_json(result["result"])
                return result["result"]
            if set(result) != {"ok", "error"} or type(result["error"]) is not str:
                raise ValueError()
        except (UnicodeError, ValueError, TypeError, RecursionError):
            raise RuntimeError("JavaScript helper returned an invalid response") from None
        if result["error"] == "timeout":
            raise TimeoutError("JavaScript evaluation timed out")
        raise RuntimeError(_ERRORS.get(result["error"], "JavaScript helper failed"))
