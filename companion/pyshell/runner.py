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

import base64
import importlib.util
import inspect
import json
import os
import queue
import re
import sys
import threading
import time
import traceback
import uuid

_PROTO = sys.stdout
sys.stdout = sys.stderr

_WRITE_LOCK = threading.Lock()

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from base.net import RuntimeReader

_inst = None
_MAX_PROXY_BODY = 4 * 1024 * 1024
_MAX_STREAMS = 16
_MAX_STREAM_CHUNK = 65536
_streams = {}
_STREAM_LOCK = threading.Lock()
_stream_generation = uuid.uuid4().hex
_HEADER_NAME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
_DANMAKU_LOCK = threading.Lock()
_danmaku = None
_danmaku_owners = {}
_events = queue.Queue(maxsize=256)


class _DanmakuOwner:
    def __init__(self, subscription, generation):
        self.subscription = subscription
        self.generation = generation
        self.active = True
        self.stop = None
        self.seq = 0
        self.state_frame = None
        self.last_sent = 0
        self.lock = threading.Lock()

    def retire(self):
        with self.lock:
            self.active = False
            stop, self.stop = self.stop, None
            return stop

    def install(self, stop):
        if not callable(stop):
            raise ValueError('danmaku must return stop')
        with self.lock:
            active = self.active
            if active:
                self.stop = stop
        if not active:
            stop()

    def emit(self, item):
        try:
            item = _danmaku_item(item)
            with self.lock:
                if not self.active:
                    return
                self.seq += 1
                frame = {'type': 'event', 'topic': 'danmaku',
                         'subscriptionId': self.subscription, 'generation': self.generation,
                         'seq': self.seq, 'item': item}
                if len(json.dumps(frame, ensure_ascii=False, allow_nan=False).encode('utf-8')) > 16384:
                    return
                if 'state' in item:
                    self.state_frame = frame
                try:
                    _events.put_nowait((self, frame))
                except queue.Full:
                    try:
                        _events.get_nowait()
                    except queue.Empty:
                        pass
                    _events.put_nowait((self, frame))
        except (ValueError, TypeError, UnicodeError, queue.Full):
            return


def _danmaku_item(item):
    if not isinstance(item, dict):
        raise ValueError('invalid event')
    if 'state' in item:
        if item['state'] not in ('ready', 'retrying', 'error'):
            raise ValueError('invalid state')
        result = {'state': item['state']}
        if 'msg' in item:
            if not isinstance(item['msg'], str):
                raise ValueError('invalid message')
            result['msg'] = item['msg'][:512]
        return result
    text, color = item.get('text'), item.get('color', 0xffffff)
    if not isinstance(text, str) or not text or type(color) is not int or not 0 <= color <= 0xffffff:
        raise ValueError('invalid text event')
    result = {'text': text, 'color': color}
    if 'colors' in item:
        colors = item['colors']
        if not isinstance(colors, (list, tuple)) or not 1 <= len(colors) <= 8 or any(
                type(value) is not int or not 0 <= value <= 0xffffff for value in colors):
            raise ValueError('invalid colors')
        result['colors'] = list(colors)
    return result


def _prepare_danmaku(req):
    global _danmaku
    sub, generation, room = req.get('subscriptionId'), req.get('generation'), req.get('roomId')
    if not isinstance(sub, str) or not re.fullmatch('[0-9a-f]{32}', sub) or generation != _stream_generation:
        raise ValueError('invalid subscription')
    if not isinstance(room, str) or not room or len(room.encode('utf-8')) > 4096:
        raise ValueError('invalid room')
    with _DANMAKU_LOCK:
        if sub in _danmaku_owners:
            raise ValueError('duplicate subscription')
        owner = _DanmakuOwner(sub, generation)
        previous, _danmaku = _danmaku, owner
        _danmaku_owners[sub] = owner
        previous_stop = previous.retire() if previous is not None else None
        if previous is not None:
            _danmaku_owners.pop(previous.subscription, None)
    return owner, previous_stop


def _retire_danmaku(req):
    global _danmaku
    with _DANMAKU_LOCK:
        owner = _danmaku_owners.get(req.get('subscriptionId'))
        if owner is None or owner.generation != req.get('generation'):
            return None
        _danmaku_owners.pop(owner.subscription, None)
        if _danmaku is owner:
            _danmaku = None
        return owner.retire()


def _close_danmaku():
    global _danmaku
    with _DANMAKU_LOCK:
        owners = list(_danmaku_owners.values())
        _danmaku_owners.clear()
        _danmaku = None
        stops = [owner.retire() for owner in owners]
    for stop in stops:
        if stop is not None:
            try:
                stop()
            except Exception:
                pass


def _event_loop():
    while True:
        owner, frame = _events.get()
        # Never hold the owner lock while the pipe can block; retired frames are
        # additionally rejected by the Java subscription generation.
        with owner.lock:
            active = owner.active
            state = owner.state_frame
            if state is not None and not owner.last_sent < state['seq'] < frame['seq']:
                state = None
            owner.last_sent = frame['seq']
        if active:
            # A chat burst may evict the sole status frame from the bounded queue.
            if state is not None:
                _reply(state)
            _reply(frame)


def _close_reader(reader):
    try:
        reader.close()
    except Exception:
        pass


class _StreamOwner:
    def __init__(self, reader):
        self.reader = reader
        self.lock = threading.Lock()
        self.closed = False
        self.read_done = threading.Event()
        self.read_done.set()

    def read(self, size):
        with self.lock:
            if self.closed:
                raise InterruptedError('stream closed')
            self.read_done.clear()
        try:
            data = self.reader.read(size)
            with self.lock:
                if self.closed:
                    raise InterruptedError('stream closed')
            return data
        finally:
            self.read_done.set()

    def close(self, wait):
        with self.lock:
            first = not self.closed
            self.closed = True
        if first:
            self.reader.close()
        if wait and not self.read_done.wait(1):
            raise TimeoutError('stream close timeout')


def _stream_close(handle, wait=False):
    if not isinstance(handle, str):
        raise ValueError("invalid stream handle")
    with _STREAM_LOCK:
        owner = _streams.pop(handle, None)
    if owner is not None:
        owner.close(wait)
    return None


def _stream_read(handle, size):
    if not isinstance(handle, str):
        raise ValueError("invalid stream handle")
    with _STREAM_LOCK:
        owner = _streams.get(handle)
    if owner is None:
        raise ValueError("invalid stream handle")
    try:
        if type(size) is not int or not 1 <= size <= _MAX_STREAM_CHUNK:
            raise ValueError("invalid stream size")
        data = owner.read(size)
        if data is None or data == b"":
            _stream_close(handle)
            return {"dataBase64": "", "eof": True}
        if not isinstance(data, bytes) or len(data) > size:
            raise ValueError("invalid stream data")
        return {"dataBase64": base64.b64encode(data).decode("ascii"), "eof": False}
    except Exception:
        _stream_close(handle)
        raise


def _close_instance():
    global _inst, _stream_generation
    _close_danmaku()
    with _STREAM_LOCK:
        owners = list(_streams.values())
        _streams.clear()
    for owner in owners:
        try:
            owner.close(False)
        except Exception:
            pass
    _stream_generation = uuid.uuid4().hex
    instance, _inst = _inst, None
    if instance is None:
        return
    # Read the stored client without evaluating the lazy `net` property.
    net = getattr(instance, "__dict__", {}).get("_net")
    try:
        destroy = getattr(instance, "destroy", None)
        if callable(destroy):
            destroy()
    except Exception:
        pass
    finally:
        if net is not None:
            try:
                net.close()
            except Exception:
                pass


def _header_value(value):
    if isinstance(value, (list, tuple)):
        if not all(isinstance(item, str) for item in value):
            raise ValueError("invalid proxy header")
        value = ", ".join(value)
    if not isinstance(value, str) or any(ord(c) < 32 and c != "\t" or ord(c) == 127 for c in value):
        raise ValueError("invalid proxy header")
    return value


def _proxy_result(value):
    reader = value[2] if isinstance(value, (list, tuple)) and len(value) > 2 else None
    reader = reader if isinstance(reader, RuntimeReader) else None
    try:
        if not isinstance(value, (list, tuple)) or len(value) not in (3, 4):
            raise ValueError("proxy requires three or four items")
        status, mime, body = value[:3]
        if type(status) is not int or not 200 <= status <= 599:
            raise ValueError("invalid proxy status")
        if not isinstance(mime, str) or not mime or any(ord(c) < 32 or ord(c) > 126 for c in mime):
            raise ValueError("invalid proxy MIME type")
        headers = value[3] if len(value) == 4 and value[3] is not None else {}
        if not isinstance(headers, dict):
            raise ValueError("invalid proxy headers")
        normalized = {}
        for name, content in headers.items():
            if not isinstance(name, str) or not _HEADER_NAME.fullmatch(name):
                raise ValueError("invalid proxy header name")
            normalized[name] = _header_value(content)
        envelope = {"__xiugou_proxy__": 1, "status": status, "mime": mime, "headers": normalized}
        if reader is not None:
            handle = _stream_generation + ":" + uuid.uuid4().hex
            envelope.update({"__xiugou_proxy__": 2, "streamId": handle})
            json.dumps(envelope, ensure_ascii=False, allow_nan=False).encode("utf-8")
            with _STREAM_LOCK:
                if len(_streams) >= _MAX_STREAMS or any(item.reader is reader for item in _streams.values()):
                    raise ValueError("stream capacity exceeded")
                _streams[handle] = _StreamOwner(reader)
        else:
            if isinstance(body, str):
                body = body.encode("utf-8")
            elif isinstance(body, bytearray):
                body = bytes(body)
            if not isinstance(body, bytes) or len(body) > _MAX_PROXY_BODY:
                raise ValueError("unsupported proxy body")
            envelope["bodyBase64"] = base64.b64encode(body).decode("ascii")
        return envelope
    except Exception:
        if reader is not None:
            with _STREAM_LOCK:
                for handle, owned in list(_streams.items()):
                    if owned.reader is reader:
                        _streams.pop(handle, None)
            _close_reader(reader)
        raise


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


def _load(path, ext="", cache_id=None):
    global _inst
    if not os.path.isfile(path):
        raise RuntimeError("脚本不存在: %s" % path)
    _close_instance()
    os.environ["XIUGOU_SCRIPT_ID"] = cache_id or os.path.normcase(os.path.realpath(path))
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
        "generation": _stream_generation,
        # 供宿主判断可选方法是否存在（liveContent / action / homeVideoContent …）
        "methods": [m for m in dir(_inst) if not m.startswith("_")],
    }


def _execute(req, prepared=None):
    rid, action = req.get('id'), req.get('action')
    value = None
    try:
        if action == 'load':
            value = _load(req['api'], req.get('ext', ''), req.get('cacheId'))
        elif action == 'call':
            if _inst is None:
                raise RuntimeError('尚未 load 脚本')
            method = req['method']
            fn = getattr(_inst, method, None)
            if fn is None:
                raise RuntimeError('脚本没有方法 %s' % method)
            value = fn(*_fit_args(fn, req.get('args') or []))
            if method == 'proxy':
                value = _proxy_result(value)
        elif action == 'danmakuStart':
            owner, previous_stop = prepared
            if previous_stop is not None:
                previous_stop()
            with owner.lock:
                active = owner.active
            if active:
                if _inst is None or owner.generation != _stream_generation:
                    raise ValueError('inactive script')
                owner.install(_inst.danmaku(req['roomId'], owner.emit))
            value = {'subscriptionId': owner.subscription, 'generation': owner.generation}
        elif action == 'streamRead':
            value = _stream_read(req.get('streamId'), req.get('size'))
        elif action == 'streamClose':
            value = _stream_close(req.get('streamId'))
        elif action == 'exit':
            value = 'bye'
        else:
            raise ValueError('unknown action')
        _reply({'id': rid, 'type': 'result', 'value': value})
    except Exception as error:
        if action == 'load':
            _close_instance()
        if action == 'danmakuStart':
            stop = _retire_danmaku(req)
            if stop is not None:
                try:
                    stop()
                except Exception:
                    pass
            _reply({'id': rid, 'type': 'error', 'error': 'script danmaku failed'})
        elif action in ('streamRead', 'streamClose') or action == 'call' and req.get('method') == 'proxy':
            if isinstance(value, dict) and value.get('__xiugou_proxy__') == 2:
                try:
                    _stream_close(value['streamId'])
                except Exception:
                    pass
            _reply({'id': rid, 'type': 'error', 'error': 'script proxy failed'})
        else:
            _reply({'id': rid, 'type': 'error', 'error': '%s: %s' % (type(error).__name__, error),
                    'trace': traceback.format_exc()[-2000:]})


def main():
    work, cancellations = queue.Queue(maxsize=64), queue.Queue(maxsize=64)

    def calls():
        try:
            while True:
                item = work.get()
                if item is None:
                    return
                _execute(*item)
        finally:
            _close_instance()

    def stops():
        while True:
            req, stop = cancellations.get()
            try:
                if stop is not None:
                    stop()
                _reply({'id': req.get('id'), 'type': 'result', 'value': None})
            except Exception:
                error = 'script proxy failed' if req.get('action') == 'streamClose' else 'script danmaku failed'
                _reply({'id': req.get('id'), 'type': 'error', 'error': error})

    worker = threading.Thread(target=calls, name='script-calls', daemon=True)
    worker.start()
    threading.Thread(target=stops, name='script-cancel', daemon=True).start()
    threading.Thread(target=_event_loop, name='script-events', daemon=True).start()
    _reply({'type': 'ready', 'python': sys.version.split()[0]})
    _start_heartbeat()
    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            req = None
            try:
                req = json.loads(line)
                if not isinstance(req, dict):
                    raise ValueError('invalid request')
                action = req.get('action')
                if action == 'danmakuStop':
                    stop = _retire_danmaku(req)
                    cancellations.put_nowait((req, stop))
                    continue
                if action == 'streamClose':
                    cancellations.put_nowait((req, lambda request=req: _stream_close(request.get('streamId'), True)))
                    continue
                prepared = _prepare_danmaku(req) if action == 'danmakuStart' else None
                work.put((req, prepared))
                if action == 'exit':
                    break
            except Exception:
                _reply({'id': req.get('id') if isinstance(req, dict) else None,
                        'type': 'error', 'error': 'invalid script request'})
    finally:
        work.put(None)
        worker.join()


main()
