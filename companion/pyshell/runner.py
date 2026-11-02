"""py 源 runner：stdin/stdout 行式 JSON-RPC，由 companion 以子进程拉起。

协议（每行一个 JSON）：
  请求  {"id":1,"action":"load","api":"<本地 .py 路径>","ext":"<初始化参数>"}
        {"id":2,"action":"call","method":"homeContent","args":[false]}
        {"id":3,"action":"exit"}
  响应  {"id":1,"type":"result","value":{...}}
        {"id":2,"type":"error","error":"...","trace":"..."}

关键细节：脚本自己会 print，所以协议必须独占原始 stdout，
把 sys.stdout 改指向 stderr，否则协议流会被日志污染。
"""

import importlib.util
import inspect
import json
import os
import sys
import threading
import time
import traceback

_PROTO = sys.stdout
sys.stdout = sys.stderr

_WRITE_LOCK = threading.Lock()

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

_inst = None


def _reply(obj):
    with _WRITE_LOCK:
        _PROTO.write(json.dumps(obj, ensure_ascii=False, default=str) + "\n")
        _PROTO.flush()


def _start_heartbeat():
    """父进程（companion）消失后自行退出，避免强退时留下孤儿 python 进程。

    Windows 上父进程被 kill 不会自动关闭子进程的 stdin 副本，光靠 EOF 不可靠；
    这里定期往协议管道写心跳：管道断了写就会抛错，立刻自尽。
    宿主侧会把 `type=ping` 的行直接跳过，不影响正常请求。
    """

    def loop():
        while True:
            time.sleep(10)
            try:
                with _WRITE_LOCK:
                    _PROTO.write('{"type":"ping"}\n')
                    _PROTO.flush()
            except Exception:
                os._exit(0)

    t = threading.Thread(target=loop, name="hb", daemon=True)
    t.start()


def _fit_args(fn, args):
    """按被调方法的实际签名裁剪实参个数（不补，只裁）。"""
    try:
        params = inspect.signature(fn).parameters.values()
    except (TypeError, ValueError):
        return args
    if any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in params):
        return args
    positional = [p for p in params
                  if p.kind in (inspect.Parameter.POSITIONAL_ONLY,
                                inspect.Parameter.POSITIONAL_OR_KEYWORD)]
    if len(args) > len(positional):
        return args[:len(positional)]
    return args


def _load(path, ext=""):
    global _inst
    if not os.path.isfile(path):
        raise RuntimeError("脚本不存在: %s" % path)
    name = "xiugou_spider_%d" % (abs(hash(path)) % (10 ** 9))
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)

    cls = getattr(mod, "Spider", None)
    if cls is None:
        raise RuntimeError("脚本里没有 Spider 类")
    _inst = cls()
    if hasattr(_inst, "init"):
        _inst.init(ext or "")
    name_out = ""
    try:
        name_out = _inst.getName()
    except Exception:
        pass
    return {
        "class": type(_inst).__name__,
        "name": name_out,
        # 供宿主判断可选方法是否存在（liveContent / action / homeVideoContent …）
        "methods": [m for m in dir(_inst) if not m.startswith("_")],
    }


def main():
    _reply({"type": "ready", "python": sys.version.split()[0]})
    _start_heartbeat()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as e:
            _reply({"type": "error", "error": "bad json: %s" % e})
            continue

        rid = req.get("id")
        action = req.get("action")
        try:
            if action == "load":
                _reply({"id": rid, "type": "result", "value": _load(req["api"], req.get("ext", ""))})
            elif action == "call":
                if _inst is None:
                    raise RuntimeError("尚未 load 脚本")
                method = req["method"]
                args = req.get("args") or []
                fn = getattr(_inst, method, None)
                if fn is None:
                    raise RuntimeError("脚本没有方法 %s" % method)
                # 参数自适应：CatVod 契约里 searchContent 有 2 参与 3 参两个重载，
                # 脚本侧的签名也两种都有。宿主统一按"最多"传，这里按实际签名截断，
                # 避免 `missing 1 required positional argument`。
                args = _fit_args(fn, args)
                _reply({"id": rid, "type": "result", "value": fn(*args)})
            elif action == "exit":
                _reply({"id": rid, "type": "result", "value": "bye"})
                return
            else:
                _reply({"id": rid, "type": "error", "error": "未知 action: %r" % action})
        except Exception as e:
            _reply({
                "id": rid,
                "type": "error",
                "error": "%s: %s" % (type(e).__name__, e),
                "trace": traceback.format_exc()[-2000:],
            })


main()
