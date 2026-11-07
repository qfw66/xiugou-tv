"""Offline legacy ABI checks; run with companion/pyruntime/python.exe -I -B.

The 421-byte synthetic module only echoes local state through three wbg imports.
The optional author check compiles only the original _Keygen class, never its
module initialization. This does not verify production WASM or live playback.
"""

import ast
import base64
import hashlib
from importlib import metadata
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

import pywasm
import numpy


RUNTIME = Path(__file__).resolve().parents[2] / "pyruntime"
AUTHOR = Path(os.environ.get("XIUGOU_AUTHOR_YSP") or
              r"E:\code\tvbox_1102\live-python-20261107\live\yangshipin.py")
AUTHOR_SHA256 = "67c66cf3f36723f41eb1e10ca0f48a11f24a69eb81c6ccf46e64aea45e75c850"
WASM_SHA256 = "0df0d751d771afd195a89d125cc1eabeded0a4425f45005362f3fd7033987754"
WASM = base64.b64decode(
    "AGFzbQEAAAABKghgAn9/AX9gAn9/AGABfwBgAX8Bf2ADf39/AGAAAX9gAn19AX1gAXwBfAJf"
    "AwN3YmcaX193YmdfZ2V0XzljMTg0MGY3ZWNkODEzNjMAAAN3YmcVX193YmluZGdlbl9zdHJp"
    "bmdfZ2V0AAEDd2JnGl9fd2JpbmRnZW5fb2JqZWN0X2Ryb3BfcmVmAAIDCAcAAwQCBQYHBQMB"
    "AAEGBwF/AUGAIAsHjgEJBm1lbW9yeQIAEV9fd2JpbmRnZW5fbWFsbG9jAAMfX193YmluZGdl"
    "bl9hZGRfdG9fc3RhY2tfcG9pbnRlcgAED19fd2JpbmRnZW5fZnJlZQAFDWdldF90b2tlbl9y"
    "bmQABg1nZXRfc2lnbmF0dXJlAAYEcGVlawAHB2YzMl9hZGQACAhmNjRfc3FydAAJCkQHBQBB"
    "gAQLCwAjACAAaiQAIwALAgALFgEBf0EQQRkQACEBIAAgARABIAEQAgsIAEGABC0AAAsHACAA"
    "IAGSCwUAIACfCwsfAQBBEAsZY2N0dmg1b3BlbmFwaS5zdGF0ZS5wcm9iZQ=="
)


def opcode_module(instructions, results=b""):
    """Build a tiny zero-argument module for a single unsupported-feature probe."""
    signature = b"\x01\x60\x00" + bytes([len(results)]) + results
    body = b"\x00" + instructions + b"\x0b"
    code = b"\x01" + bytes([len(body)]) + body
    return (b"\x00asm\x01\x00\x00\x00\x01" + bytes([len(signature)]) + signature +
            b"\x03\x02\x01\x00\x05\x03\x01\x00\x01" +
            b"\x07\x09\x01\x05probe\x00\x00\x0a" + bytes([len(code)]) + code)


class WasmCompatibilityTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="xiugou-wasm-abi-")
        self.addCleanup(directory.cleanup)
        self.wasm = Path(directory.name) / "synthetic.wasm"
        self.assertEqual(len(WASM), 421)
        self.assertEqual(hashlib.sha256(WASM).hexdigest(), WASM_SHA256)
        self.wasm.write_bytes(WASM)

    def test_imports_and_metadata_use_bundled_runtime(self):
        self.assertEqual(Path(sys.executable).resolve(), (RUNTIME / "python.exe").resolve())
        self.assertEqual(sys.implementation.name, "cpython")
        self.assertEqual(sys.version_info[:2], (3, 14))
        self.assertEqual(struct.calcsize("P"), 8)
        site = RUNTIME / "Lib/site-packages"
        for package, version in ((pywasm, "1.0.8"), (numpy, "2.3.4")):
            with self.subTest(package=package.__name__):
                self.assertEqual(Path(package.__file__).resolve(),
                                 (site / package.__name__ / "__init__.py").resolve())
                distribution = metadata.distribution(package.__name__)
                self.assertEqual(distribution.version, version)
                self.assertEqual(Path(distribution.locate_file("")).resolve(), site.resolve())
        self.assertEqual(metadata.requires("pywasm"), ["numpy"])
        self.assertEqual(metadata.requires("numpy") or [], [])
        self.assertEqual(numpy.__version__, "2.3.4")

    def test_callbacks_memory_and_reentrant_exec(self):
        events = []
        payload = "abi-中文".encode("utf-8")

        def get(context, pointer, length):
            self.assertIs(context, runtime.machine.store)
            self.assertEqual(bytes(memory.data[pointer:pointer + length]),
                             b"cctvh5openapi.state.probe")
            events.append("get")
            return 132

        def string_get(context, output, handle):
            self.assertIs(context, runtime.machine.store)
            self.assertEqual(handle, 132)
            pointer = runtime.exec("__wbindgen_malloc", [len(payload), 1])
            self.assertEqual(pointer, 512)
            memory.data[pointer:pointer + len(payload)] = payload
            struct.pack_into("<ii", memory.data, output, pointer, len(payload))
            events.append("string_get")

        def drop(context, handle):
            self.assertIs(context, runtime.machine.store)
            self.assertEqual(handle, 132)
            events.append("drop")

        runtime = pywasm.load(str(self.wasm), {"wbg": {
            "__wbg_get_9c1840f7ecd81363": get,
            "__wbindgen_string_get": string_get,
            "__wbindgen_object_drop_ref": drop,
        }})
        export = next(item for item in runtime.machine.module.export_list if item.name == "memory")
        self.assertEqual(export.value, 0)
        memory = runtime.machine.store.memory_list[export.value]
        self.assertIsInstance(memory.data, bytearray)
        output = runtime.exec("__wbindgen_add_to_stack_pointer", [-16])
        self.assertEqual(output, 4080)
        self.assertIsNone(runtime.exec("get_token_rnd", [output]))
        pointer, length = struct.unpack_from("<ii", memory.data, output)
        self.assertEqual(bytes(memory.data[pointer:pointer + length]), payload)
        self.assertEqual(runtime.exec("peek", []), ord("a"))
        memory.data[pointer] = ord("Z")
        self.assertEqual(runtime.exec("peek", []), ord("Z"))
        self.assertIsNone(runtime.exec("__wbindgen_free", [pointer, length, 1]))
        self.assertEqual(runtime.exec("__wbindgen_add_to_stack_pointer", [16]), 4096)
        self.assertEqual(runtime.exec("f32_add", [1.25, 2.5]), 3.75)
        self.assertEqual(runtime.exec("f64_sqrt", [9.0]), 3.0)
        self.assertEqual(events, ["get", "string_get", "drop"])

    @unittest.skipUnless(AUTHOR.is_file(), "author source missing; set XIUGOU_AUTHOR_YSP")
    def test_original_keygen_class_with_synthetic_wasm(self):
        source = AUTHOR.read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(), AUTHOR_SHA256,
                         "reference source changed; review its _Keygen AST before updating the pin")
        tree = ast.parse(source, filename=str(AUTHOR))
        keygen = next(node for node in tree.body
                      if isinstance(node, ast.ClassDef) and node.name == "_Keygen")
        namespace = {"struct": struct}
        exec(compile(ast.Module(body=[keygen], type_ignores=[]), str(AUTHOR), "exec"), namespace)
        original = namespace["_Keygen"](str(self.wasm))
        self.assertEqual(original.token_random({"probe": "abi-中文"}), "abi-中文")
        self.assertEqual(original.signature({"probe": "synthetic-signature"}), "synthetic-signature")
        self.assertEqual(original.heap, {})
        self.assertEqual(original.runtime.exec("__wbindgen_add_to_stack_pointer", [0]), 4096)

    def test_legacy_opcode_limits_remain_explicit(self):
        self.assertFalse(sys.flags.optimize, "run without -O; pywasm uses assertions")
        cases = (
            ("i32.extend8_s", b"\x41\xff\x01\xc0", b"\x7f", 192),
            ("memory.copy", b"\x41\x00\x41\x01\x41\x01\xfc\x0a\x00\x00", b"", 252),
            ("memory.fill", b"\x41\x00\x41\xc1\x00\x41\x01\xfc\x0b\x00", b"", 252),
            ("i32.trunc_sat_f32_s", b"\x43" + struct.pack("<f", 3.5) + b"\xfc\x00", b"\x7f", 252),
            ("v128.const", b"\xfd\x0c" + b"\x00" * 16 + b"\x1a", b"", 253),
        )
        for name, code, results, opcode in cases:
            with self.subTest(feature=name):
                self.wasm.write_bytes(opcode_module(code, results))
                with self.assertRaisesRegex(Exception, r"\('unsupported opcode', " + str(opcode) + r"\)"):
                    pywasm.load(str(self.wasm))
        self.wasm.write_bytes(opcode_module(b"\x41\x03\x41\x04", b"\x7f\x7f"))
        runtime = pywasm.load(str(self.wasm))
        with self.assertRaises(AssertionError):
            runtime.exec("probe", [])


if __name__ == "__main__":
    unittest.main()
