"""Real runner pipes: unsolicited events, cancellation and instance ownership."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

RUNNER = Path(__file__).resolve().parents[1] / "runner.py"
SCRIPT = r'''
import json, os, sys, threading, time
from pathlib import Path
class Spider:
    def init(self, ext=''):
        self.root = Path(ext)
        self.stop = None
    def action(self, value):
        if value == 'block':
            (self.root / 'blocked').write_text('yes')
            while not (self.root / 'release').exists(): time.sleep(.005)
        return {'value': value, 'pid': os.getpid()}
    def danmaku(self, room, emit):
        if self.stop: self.stop()
        print('ordinary-log-not-protocol')
        if room == 'burst':
            interval = sys.getswitchinterval()
            sys.setswitchinterval(1)
            try:
                emit({'state': 'ready'})
                for index in range(600): emit({'text': str(index), 'color': 1})
            finally:
                sys.setswitchinterval(interval)
        else:
            emit({'state': 'ready'})
        stopped = threading.Event()
        def close():
            if stopped.is_set(): return
            stopped.set()
            with (self.root / 'stops').open('a') as out: out.write(room + '\n')
            emit({'text': 'late-after-stop', 'color': 1})
        self.stop = close
        if room == 'early':
            (self.root / 'entered').write_text('yes')
            while not (self.root / 'return-stop').exists(): time.sleep(.005)
        def events():
            if room == 'invalid':
                for item in ({'text': 'x' * 17000, 'color': 1}, {'text': 'bad', 'color': True},
                             {'text': 'bad', 'colors': [1] * 9}, {'state': 'unknown'},
                             {'text': object()}, {'text': 'bad', 'color': -1}): emit(item)
            for index in range(5):
                if stopped.wait(.02): return
                emit({'text': room + ':' + str(index), 'color': 0x0080ff, 'colors': [1, 0xffffff]})
        threading.Thread(target=events, daemon=True).start()
        return close
    def destroy(self):
        if self.stop: self.stop()
'''


class Runner:
    def __init__(self, root):
        self.root = root
        self.script = root / 'source.py'
        self.script.write_text(SCRIPT, encoding='utf-8')
        self.logs = (root / 'stderr.log').open('w', encoding='utf-8')
        self.process = subprocess.Popen(
            [sys.executable, '-B', '-X', 'utf8', str(RUNNER)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.logs,
            encoding='utf-8', env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'), cwd=root)
        self.frames = queue.Queue()
        self.saved = []
        self.sequence = 0
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        self.wait(lambda item: item.get('type') == 'ready')
        self.load()

    def _read(self):
        for line in self.process.stdout:
            try: self.frames.put(json.loads(line))
            except Exception: self.frames.put({'invalid': line})

    def send(self, action, **data):
        self.sequence += 1
        data.update(id=self.sequence, action=action)
        self.process.stdin.write(json.dumps(data) + '\n')
        self.process.stdin.flush()
        return self.sequence

    def wait(self, predicate, timeout=3):
        end = time.monotonic() + timeout
        while True:
            for index, item in enumerate(self.saved):
                if predicate(item): return self.saved.pop(index)
            remaining = end - time.monotonic()
            if remaining <= 0: raise AssertionError('runner response deadline')
            try: item = self.frames.get(timeout=remaining)
            except queue.Empty: raise AssertionError('runner response deadline') from None
            if 'invalid' in item: raise AssertionError('stdout polluted')
            if predicate(item): return item
            self.saved.append(item)

    def response(self, rid, timeout=3):
        return self.wait(lambda item: item.get('id') == rid, timeout)

    def load(self):
        response = self.response(self.send('load', api=str(self.script), ext=str(self.root)))
        if response.get('type') != 'result': raise AssertionError(response)
        self.generation = response['value'].get('generation', '')

    def start(self, room):
        sub = uuid.uuid4().hex
        rid = self.send('danmakuStart', subscriptionId=sub, generation=self.generation, roomId=room)
        return sub, rid

    def stop(self, sub):
        return self.response(self.send('danmakuStop', subscriptionId=sub, generation=self.generation))

    def close(self):
        for name in ('release', 'return-stop'): (self.root / name).touch()
        if self.process.poll() is None:
            try:
                self.send('exit')
                self.process.stdin.close()
                self.process.wait(timeout=3)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=3)
        self.thread.join(timeout=2)
        self.process.stdout.close()
        if not self.process.stdin.closed: self.process.stdin.close()
        self.logs.close()


def await_file(path, timeout=3):
    end = time.monotonic() + timeout
    while not path.exists() and time.monotonic() < end: time.sleep(.005)
    if not path.exists(): raise AssertionError('script boundary not reached: ' + path.name)


class DanmakuProtocolTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='xiugou-danmaku-protocol-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runner = Runner(self.root)
        self.addCleanup(self.runner.close)

    def test_idle_events_and_ordinary_rpc_keep_ids_and_logs_separate(self):
        r = self.runner
        sub, rid = r.start('room')
        self.assertEqual(r.response(rid)['type'], 'result')
        event = r.wait(lambda frame: frame.get('type') == 'event' and 'text' in frame.get('item', {}))
        self.assertEqual(event['subscriptionId'], sub)
        self.assertEqual(event['generation'], r.generation)
        self.assertEqual(event['topic'], 'danmaku')
        self.assertEqual(event['item']['colors'], [1, 0xffffff])
        call = r.send('call', method='action', args=['ordinary'])
        self.assertEqual(r.response(call)['value']['value'], 'ordinary')
        self.assertEqual(r.stop(sub)['type'], 'result')
        self.assertIn('ordinary-log-not-protocol', (self.root / 'stderr.log').read_text())

    def test_stop_bypasses_blocked_ordinary_call_without_killing_process(self):
        r = self.runner
        sub, rid = r.start('blocked-room')
        self.assertEqual(r.response(rid)['type'], 'result')
        blocked = r.send('call', method='action', args=['block'])
        await_file(self.root / 'blocked')
        started = time.monotonic()
        self.assertEqual(r.stop(sub)['type'], 'result')
        self.assertLess(time.monotonic() - started, 1)
        self.assertIsNone(r.process.poll())
        self.assertEqual((self.root / 'stops').read_text().splitlines(), ['blocked-room'])
        (self.root / 'release').touch()
        self.assertEqual(r.response(blocked)['value']['value'], 'block')

    def test_cancel_before_stop_return_calls_late_stop_exactly_once(self):
        r = self.runner
        sub, rid = r.start('early')
        await_file(self.root / 'entered')
        self.assertEqual(r.stop(sub)['type'], 'result')
        self.assertFalse((self.root / 'stops').exists())
        (self.root / 'return-stop').touch()
        self.assertEqual(r.response(rid)['type'], 'result')
        await_file(self.root / 'stops')
        self.assertEqual(r.stop(sub)['type'], 'result')
        barrier = r.send('call', method='action', args=['barrier'])
        r.response(barrier)
        self.assertEqual((self.root / 'stops').read_text().splitlines(), ['early'])
        self.assertFalse(any(f.get('item', {}).get('text') == 'late-after-stop' for f in r.saved))

    def test_replace_and_reload_retire_old_owner_and_generation(self):
        r = self.runner
        old, rid = r.start('first')
        self.assertEqual(r.response(rid)['type'], 'result')
        new, rid = r.start('second')
        self.assertEqual(r.response(rid)['type'], 'result')
        self.assertEqual((self.root / 'stops').read_text().splitlines(), ['first'])
        generation = r.generation
        r.load()
        self.assertNotEqual(r.generation, generation)
        self.assertEqual((self.root / 'stops').read_text().splitlines(), ['first', 'second'])
        stale = r.send('danmakuStart', subscriptionId=old, generation=generation, roomId='stale')
        self.assertEqual(r.response(stale)['type'], 'error')
        self.assertEqual(r.stop(new)['type'], 'result')

    def test_latest_state_survives_runner_queue_overflow(self):
        r = self.runner
        sub, rid = r.start('burst')
        self.assertEqual(r.response(rid)['type'], 'result')
        last = r.wait(lambda frame: frame.get('item', {}).get('text') == '599')
        events = [frame for frame in r.saved if frame.get('type') == 'event'] + [last]
        self.assertTrue(any(frame.get('item', {}).get('state') == 'ready' for frame in events))
        self.assertLess(len(events), 601, 'fixture must exercise actual producer overflow')
        sequence = [frame['seq'] for frame in events]
        self.assertEqual(sequence, sorted(set(sequence)))
        self.assertEqual(r.stop(sub)['type'], 'result')

    def test_invalid_events_are_dropped_and_valid_schema_survives(self):
        r = self.runner
        sub, rid = r.start('invalid')
        self.assertEqual(r.response(rid)['type'], 'result')
        event = r.wait(lambda frame: frame.get('item', {}).get('text') == 'invalid:4')
        events = [frame for frame in r.saved if frame.get('type') == 'event'] + [event]
        self.assertTrue(all(len(json.dumps(frame, ensure_ascii=False).encode()) <= 16384 for frame in events))
        self.assertTrue(all(frame['item'].get('text', '').startswith('invalid:') or 'state' in frame['item'] for frame in events))
        self.assertEqual(r.stop(sub)['type'], 'result')


if __name__ == '__main__':
    unittest.main()
