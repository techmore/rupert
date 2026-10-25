"""Gateway concurrency and HTTP contracts; no model/GPU is needed."""
import importlib.util
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('llm_gateway', Path(__file__).parents[1] / 'team-chat/llm-gateway/llm_gateway.py')
gateway = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gateway)


def engine(**kwargs):
    return gateway.Engine({'qwen3.5-4b': {}}, 'unused', 0, 8, 600, 240, keep_loaded='qwen3.5-4b', **kwargs)


class QueueTest(unittest.TestCase):
    def test_queue_is_bounded_and_releases_after_exception(self):
        e = engine(max_queued=0)
        with e.request_slot():
            with self.assertRaisesRegex(gateway.Busy, 'queue full'):
                with e.request_slot():
                    self.fail('admitted a second inference')
        with self.assertRaises(ValueError):
            with e.request_slot():
                raise ValueError('failed inference')
        with e.request_slot():
            self.assertTrue(e.lock.locked())
        self.assertEqual(0, e.waiting)
        self.assertEqual(1, e.rejected)

    def test_queue_deadline_does_not_start_inference(self):
        e = engine(queue_timeout=0.02)
        e.lock.acquire()
        try:
            with self.assertRaisesRegex(gateway.Busy, 'deadline'):
                with e.request_slot():
                    self.fail('expired request ran')
        finally:
            e.lock.release()
        with e.request_slot():
            pass
        self.assertEqual(0, e.waiting)

    def test_waiting_request_runs_serially(self):
        e = engine(queue_timeout=1)
        waiting = threading.Event()
        finished = threading.Event()

        def request():
            waiting.set()
            with e.request_slot() as elapsed:
                self.assertGreaterEqual(elapsed, 0)
                finished.set()

        with e.request_slot():
            thread = threading.Thread(target=request)
            thread.start()
            self.assertTrue(waiting.wait(1))
            self.assertFalse(finished.wait(0.02))
        thread.join(1)
        self.assertTrue(finished.is_set())


class MemoryTest(unittest.TestCase):
    def test_missing_counters_are_unknown_and_shared_gpu_is_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            empty = gateway.memory_status(proc_root=root, drm_root=root)
            self.assertNotIn('available_bytes', empty)
            (root / 'meminfo').write_text('MemTotal: 28000000 kB\nMemAvailable: 8000000 kB\nSwapTotal: 1000 kB\nSwapFree: 500 kB\n')
            (root / '42').mkdir()
            (root / '42/status').write_text('VmRSS: 2000 kB\n')
            gpu = root / 'card0/device'
            gpu.mkdir(parents=True)
            (gpu / 'mem_info_gtt_used').write_text('12345')
            status = gateway.memory_status(42, proc_root=root, drm_root=root)
            self.assertEqual(8000000 * 1024, status['available_bytes'])
            self.assertEqual(2000 * 1024, status['model_rss_bytes'])
            self.assertEqual(12345, status['gpu']['card0']['mem_info_gtt_used_bytes'])
            self.assertEqual(28000000 * 1024, status['total_bytes'])


class HTTPTest(unittest.TestCase):
    def setUp(self):
        self.engine = engine(max_queued=0, queue_timeout=0.02)
        self.server = gateway.BoundedHTTPServer(('127.0.0.1', 0), gateway.make_handler(self.engine, {'127.0.0.1'}), max_handlers=4)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(1)

    def request(self, method, body=None, path='/v1/chat/completions', headers=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def test_overload_has_retry_after_and_does_not_load_model(self):
        with patch.object(self.engine, 'ensure') as ensure:
            with self.engine.request_slot():
                status, headers, body = self.request('POST', json.dumps({'model': 'qwen3.5-4b'}))
            self.assertEqual(429, status)
            self.assertEqual('5', headers['Retry-After'])
            ensure.assert_not_called()

    def test_invalid_and_oversized_bodies_do_not_reach_model(self):
        for body in ('[]', '{', '{"model": []}'):
            self.assertEqual(400, self.request('POST', body)[0])
        self.assertEqual(413, self.request('POST', headers={'Content-Length': '2097153'})[0])
        self.assertEqual(404, self.request('POST', '{"model":"other"}')[0])

    def test_real_proxy_round_trip_preserves_response_and_records_metrics(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        class Upstream(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                data = json.dumps({'model': body['model'], 'choices': [], 'timings': {'prompt_ms': 12, 'predicted_ms': 34}}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        thread.start()
        self.engine.port = upstream.server_address[1]
        try:
            with patch.object(self.engine, 'ensure') as ensure:
                status, headers, raw = self.request('POST', json.dumps({'model': 'qwen3.5-4b'}))
            self.assertEqual(200, status)
            self.assertEqual('qwen3.5-4b', json.loads(raw)['model'])
            self.assertIn('X-Rupert-Load-Ms', headers)
            # The handler records metrics after writing the final response bytes.
            with self.engine.lock:
                pass
            metrics = self.engine.status()['queue']['last_request']
            self.assertEqual('ok', metrics['outcome'])
            self.assertEqual(12, metrics['inference']['prompt_ms'])
            self.assertEqual(34, metrics['inference']['predicted_ms'])
            ensure.assert_called_once_with('qwen3.5-4b')
        finally:
            upstream.shutdown()
            upstream.server_close()
            thread.join(1)

    def test_load_failure_releases_slot_and_has_retry_hint(self):
        with patch.object(self.engine, 'ensure', side_effect=OSError('missing executable')):
            status, headers, _ = self.request('POST', json.dumps({'model': 'qwen3.5-4b'}))
        self.assertEqual(503, status)
        self.assertEqual('5', headers['Retry-After'])
        with self.engine.request_slot():
            pass

    def test_disconnected_client_is_not_sent_to_model(self):
        handler = gateway.make_handler(self.engine, set())
        request = object.__new__(handler)
        with patch.object(gateway.select, 'select', return_value=([object()], [], [])):
            from unittest.mock import Mock
            request.connection = Mock()
            request.connection.recv.return_value = b''
            self.assertTrue(request.disconnected())
            request.connection.recv.return_value = b'x'
            self.assertFalse(request.disconnected())

    def test_handler_capacity_rejects_without_spawning_another_thread(self):
        for _ in range(4):
            self.assertTrue(self.server.handlers.acquire(blocking=False))
        try:
            status, headers, body = self.request('GET', path='/health')
            self.assertEqual(503, status)
            self.assertEqual('5', headers['Retry-After'])
            self.assertEqual(b'', body)
        finally:
            for _ in range(4):
                self.server.handlers.release()
        self.assertEqual(200, self.request('GET', path='/health')[0])

    def test_health_is_available_while_model_busy(self):
        with self.engine.request_slot():
            status, _, raw = self.request('GET', path='/health')
        self.assertEqual(200, status)
        data = json.loads(raw)
        self.assertTrue(data['busy'])
        self.assertEqual('qwen3.5-4b', data['keep_loaded'])
        self.assertIn('memory', data)
        self.assertIn('queue', data)

    def test_forwarding_closes_connection_and_reports_timings(self):
        class Socket:
            def settimeout(self, seconds):
                pass
        class Response:
            status = 200
            chunks = iter([b'{"choices": []}', b''])
            def isclosed(self):
                return False
            def getheader(self, name, default):
                return default
            def read1(self, size):
                return next(self.chunks)
        with patch.object(gateway.http.client, 'HTTPConnection') as factory:
            upstream = factory.return_value
            upstream.sock = Socket()
            upstream.getresponse.return_value = Response()
            # Use the real client constructor outside the patched module.
            handler = gateway.make_handler(self.engine, set())
            request = object.__new__(handler)
            import io
            request.wfile = io.BytesIO()
            request.send_response = lambda status: None
            headers = {}
            request.send_header = lambda key, value: headers.update({key: value})
            request.end_headers = lambda: None
            self.assertEqual('ok', request.forward({'model': 'qwen3.5-4b'}, queue_ms=2, load_ms=3))
            self.assertEqual('2', headers['X-Rupert-Queue-Ms'])
            self.assertEqual('3', headers['X-Rupert-Load-Ms'])
            upstream.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
