"""Tests for the gateway's first-token timing. Run: python3 -m unittest test_llm_gateway (standard library only)."""
import http.client
import json
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import llm_gateway


def sse(*events):
    return b''.join(b'data: ' + (e if isinstance(e, bytes) else json.dumps(e).encode()) + b'\n\n' for e in events)


class FakeUpstream(BaseHTTPRequestHandler):
    delay = 0.3  # seconds before the first generated token

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.send_response(200)
        if body.get('stream'):
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.write(sse({'choices': [{'delta': {'role': 'assistant', 'content': ''}}]}))
            self.wfile.flush()
            time.sleep(self.delay)
            self.wfile.write(sse({'choices': [{'delta': {'content': 'Hi'}}]}))
            self.wfile.flush()
            self.wfile.write(sse({'choices': [], 'usage': {'prompt_tokens': 42, 'completion_tokens': 7},
                                  'timings': {'prompt_n': 40, 'cache_n': 2, 'predicted_n': 7}}, b'[DONE]'))
        else:
            time.sleep(self.delay)
            data = json.dumps({'choices': [{'message': {'content': 'Hi'}}], 'usage': {'prompt_tokens': 5, 'completion_tokens': 1}}).encode()
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)


class FakeEngine(llm_gateway.Engine):
    def ensure(self, model_id, reason='request'):
        self.current = model_id


def serve(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class HelpersTest(unittest.TestCase):
    def test_first_token_needs_content_reasoning_or_tool_call(self):
        self.assertFalse(llm_gateway.has_first_token(b'data: {"choices":[{"delta":{"role":"assistant","content":""}}]}'))
        self.assertFalse(llm_gateway.has_first_token(b'data: {"choices":[{"delta":{"content":null}}]}'))
        self.assertTrue(llm_gateway.has_first_token(b'data: {"choices":[{"delta":{"content":"Hi"}}]}'))
        self.assertTrue(llm_gateway.has_first_token(b'data: {"choices":[{"delta":{"reasoning_content":"Let me"}}]}'))
        self.assertTrue(llm_gateway.has_first_token(b'data: {"choices":[{"delta":{"tool_calls":[{"index":0}]}}]}'))

    def test_token_counts_prefer_usage_then_timings(self):
        self.assertEqual((42, 7), llm_gateway.token_counts(b'..."usage":{"prompt_tokens":42,"completion_tokens":7}', {'prompt_n': 1}))
        self.assertEqual((42, 7), llm_gateway.token_counts(b'', {'prompt_n': 40, 'cache_n': 2, 'predicted_n': 7}))
        self.assertEqual((None, None), llm_gateway.token_counts(b'data: {}', None))


class LastTimingTest(unittest.TestCase):
    def setUp(self):
        self.upstream = serve(ThreadingHTTPServer(('127.0.0.1', 0), FakeUpstream))
        self.engine = FakeEngine({'m': {'file': 'x'}}, 'unused', self.upstream.server_address[1], 1, 300, 5)
        self.gateway = serve(llm_gateway.BoundedHTTPServer(('127.0.0.1', 0), llm_gateway.make_handler(self.engine, {'127.0.0.1'})))
        self.port = self.gateway.server_address[1]

    def tearDown(self):
        self.gateway.shutdown()
        self.upstream.shutdown()
        self.gateway.server_close()
        self.upstream.server_close()

    def call(self, method, path, body=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        conn.request(method, path, body=json.dumps(body) if body else None, headers={'Content-Type': 'application/json'})
        return conn.getresponse().read()

    def health(self):
        return json.loads(self.call('GET', '/health'))

    def test_streaming_ttft_skips_the_empty_role_delta(self):
        self.assertIsNone(self.health()['last_timing'])
        self.call('POST', '/v1/chat/completions', {'model': 'm', 'stream': True})
        timing = self.health()['last_timing']
        self.assertEqual('m', timing['model'])
        self.assertEqual('ok', timing['outcome'])
        self.assertGreaterEqual(timing['ttft_ms'], 250, 'waits for the content chunk, not the role chunk')
        self.assertLess(timing['ttft_ms'], 2000)
        self.assertEqual((42, 7), (timing['prompt_tokens'], timing['completion_tokens']))
        self.assertIn('queue_ms', timing)
        self.assertIn('last_load', self.health(), 'existing health fields stay')

    def test_non_streaming_request_reports_when_the_reply_arrived(self):
        self.call('POST', '/v1/chat/completions', {'model': 'm'})
        timing = self.health()['last_timing']
        self.assertGreaterEqual(timing['ttft_ms'], 250)
        self.assertEqual((5, 1), (timing['prompt_tokens'], timing['completion_tokens']))


if __name__ == '__main__':
    unittest.main()
