#!/usr/bin/env python3
"""One-model-at-a-time gateway for Team chat's local @agents (rupert-llm container on SER8).

Serves an OpenAI-compatible API (GET /v1/models, POST /v1/chat/completions, streaming or not) in front of
llama.cpp's llama-server. Only ONE model is ever loaded: a request for another model waits for the request in
flight, stops the running llama-server and starts the requested one. Requests are handled one at a time.
A model with no request for IDLE_SECONDS (default 300) is unloaded, so nothing sits in memory between chats.
With --keep-loaded MODEL that model is never unloaded for being idle, and is loaded again in the background once
another model has been idle for IDLE_SECONDS, so the main bot never waits for a load. /health reports the last load
(model, seconds, when, and whether a request or the keep-loaded warm-up caused it), so Rupert can show load time, and
/health `last_timing` reports the last request's time to first token (ttft_ms: from sending the request to llama-server,
so after queueing and model loading, to the first upstream chunk carrying content, reasoning or a tool-call delta;
for a non-streaming request that is when the reply arrives), queue_ms and token counts. Requests are serialized, so
'last' is unambiguous.

Models come from models.json: {"id": {"file": "/path/model.gguf", "ctx": 16384, "args": [...]}}.
Only the clients in --allow may call it. Python standard library only.
Admission defaults to one active request plus two waiters, with a 30-second queue
deadline. Handler count and request body size are also bounded. /health exposes
queue counters and gateway-visible memory; shared GPU RAM is not extra capacity.
"""
import argparse
from contextlib import contextmanager
from pathlib import Path
import http.client
import json
import re
import logging
import os
import signal
import select
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger('llm_gateway')


class Engine:
    """Owns the single llama-server process."""

    def __init__(self, models, server_bin, port, threads, idle_seconds, start_timeout, keep_loaded=None, max_queued=2, queue_timeout=30, inference_timeout=180):
        self.admission = threading.BoundedSemaphore(max_queued + 1)
        self.queue_timeout = queue_timeout
        self.inference_timeout = inference_timeout
        self.metrics_lock = threading.Lock()
        self.waiting = 0
        self.rejected = 0
        self.last_request = None
        self.models = models
        self.server_bin = server_bin
        self.port = port
        self.threads = threads
        self.idle_seconds = idle_seconds
        self.start_timeout = start_timeout
        self.lock = threading.Lock()  # one request (and so one model) at a time
        self.proc = None
        self.current = None
        self.last_used = time.monotonic()
        self.keep_loaded = keep_loaded if keep_loaded in models else None
        self.last_load = None
        self.last_timing = None
        self.warm_failed_at = 0.0

    def status(self):
        proc = self.proc
        with self.metrics_lock:
            queue = {'waiting': self.waiting, 'rejected': self.rejected, 'last_request': self.last_request}
            last_timing = self.last_timing
        return {'loaded': self.current, 'idle_seconds': round(time.monotonic() - self.last_used), 'busy': self.lock.locked(),
                'keep_loaded': self.keep_loaded, 'last_load': self.last_load, 'last_timing': last_timing, 'queue': queue,
                'memory': memory_status(proc.pid if proc else None)}

    @contextmanager
    def request_slot(self):
        started = time.monotonic()
        if not self.admission.acquire(blocking=False):
            with self.metrics_lock:
                self.rejected += 1
            raise Busy('queue full')
        acquired = False
        with self.metrics_lock:
            self.waiting += 1
        try:
            acquired = self.lock.acquire(timeout=self.queue_timeout)
            with self.metrics_lock:
                self.waiting -= 1
                if not acquired:
                    self.rejected += 1
            if not acquired:
                raise Busy('queue deadline exceeded')
            yield round((time.monotonic() - started) * 1000, 1)
        finally:
            if acquired:
                self.lock.release()
            self.admission.release()

    def ensure(self, model_id, reason='request'):
        """Load model_id, unloading any other model first. Caller holds self.lock."""
        if self.current == model_id and self.proc and self.proc.poll() is None:
            return
        self.stop()
        spec = self.models[model_id]
        cmd = [self.server_bin, '--model', spec['file'], '--host', '127.0.0.1', '--port', str(self.port),
               '--ctx-size', str(spec.get('ctx', 16384)), '--threads', str(self.threads), '--jinja',
               '--parallel', '1', '--no-webui'] + list(spec.get('args', []))
        log.info('loading %s', model_id)
        started = time.monotonic()
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.current = model_id
        while time.monotonic() - started < self.start_timeout:
            if self.proc.poll() is not None:
                self.current = None
                raise RuntimeError('llama-server exited while loading %s' % model_id)
            try:
                conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=2)
                conn.request('GET', '/health')
                ready = conn.getresponse().status == 200
                conn.close()
                if ready:
                    seconds = time.monotonic() - started
                    log.info('loaded %s in %.1fs (%s)', model_id, seconds, reason)
                    self.last_load = {'model': model_id, 'seconds': round(seconds, 1), 'finished_at': round(time.time(), 1), 'reason': reason}
                    return
            except OSError:
                pass
            time.sleep(0.5)
        self.stop()
        raise RuntimeError('timed out loading %s' % model_id)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            log.info('unloading %s', self.current)
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait()
        self.proc = None
        self.current = None

    def reap_idle(self):
        while True:
            if self.lock.acquire(blocking=False):
                try:
                    self.tidy()
                finally:
                    self.lock.release()
            time.sleep(15)

    def tidy(self):
        """Unload an idle model; with keep_loaded, put the kept model back instead. Caller holds self.lock."""
        idle = time.monotonic() - self.last_used > self.idle_seconds
        if self.keep_loaded:
            if self.current == self.keep_loaded and self.proc and self.proc.poll() is None:
                return
            if self.current and not idle:
                return
            if time.monotonic() - self.warm_failed_at < 300:
                return
            try:
                self.ensure(self.keep_loaded, reason='keep_loaded')
            except RuntimeError as error:
                self.warm_failed_at = time.monotonic()
                log.warning('could not load %s to keep it loaded: %s', self.keep_loaded, error)
        elif self.current and idle:
            log.info('idle for %ss', self.idle_seconds)
            self.stop()


class Busy(RuntimeError):
    pass


def memory_status(pid=None, proc_root=Path('/proc'), drm_root=Path('/sys/class/drm')):
    """Visible Linux counters only. GPU shared allocations are NOT extra RAM.

    Incus can virtualize /proc; these are not guaranteed host-wide measurements.
    Missing counters remain absent, never a fabricated zero.
    """
    result = {'scope': 'gateway-visible; verify host totals separately'}
    try:
        values = dict(line.split(':', 1) for line in (proc_root / 'meminfo').read_text().splitlines())
        for source, key in [('MemTotal', 'total_bytes'), ('MemAvailable', 'available_bytes'), ('SwapTotal', 'swap_total_bytes'), ('SwapFree', 'swap_free_bytes')]:
            if source in values:
                result[key] = int(values[source].split()[0]) * 1024
    except (OSError, ValueError):
        pass
    if pid:
        try:
            for line in (proc_root / str(pid) / 'status').read_text().splitlines():
                if line.startswith('VmRSS:'):
                    result['model_rss_bytes'] = int(line.split()[1]) * 1024
        except (OSError, ValueError):
            pass
    devices = {}
    for device in drm_root.glob('card[0-9]*/device'):
        counters = {}
        for name in ('mem_info_vram_used', 'mem_info_gtt_used'):
            try:
                counters[name + '_bytes'] = int((device / name).read_text().strip())
            except (OSError, ValueError):
                pass
        if counters:
            devices[device.parent.name] = counters
    if devices:
        result['gpu'] = devices
    return result


class BoundedHTTPServer(ThreadingHTTPServer):
    """Bound handlers too, including clients stalled while uploading a body."""
    daemon_threads = True

    def __init__(self, address, handler, max_handlers=8):
        self.handlers = threading.BoundedSemaphore(max_handlers)
        super().__init__(address, handler)

    def process_request(self, request, client_address):
        if not self.handlers.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b'HTTP/1.0 503 Service Unavailable\r\nRetry-After: 5\r\nContent-Length: 0\r\n\r\n')
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.handlers.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(15)
            super().process_request_thread(request, client_address)
        finally:
            self.handlers.release()


def log_timings(model_id, tail, seconds):
    """One line per request: prompt tokens read fresh vs reused from the cache, and speeds (llama-server 'timings')."""
    match = None
    for match in re.finditer(rb'"timings"\s*:\s*(\{[^{}]*\})', tail):
        pass
    if not match:
        log.info('request model=%s seconds=%.1f (no timings)', model_id, seconds)
        return
    try:
        t = json.loads(match.group(1))
    except ValueError:
        return
    log.info('request model=%s seconds=%.1f prompt_new=%s prompt_cached=%s prompt_ms=%.0f prompt_tps=%.0f gen=%s gen_tps=%.1f',
             model_id, seconds, t.get('prompt_n'), t.get('cache_n'), t.get('prompt_ms', 0), t.get('prompt_per_second', 0),
             t.get('predicted_n'), t.get('predicted_per_second', 0))
    return {key: t[key] for key in ('prompt_n', 'cache_n', 'prompt_ms', 'prompt_per_second', 'predicted_n', 'predicted_ms', 'predicted_per_second') if key in t}


FIRST_TOKEN = re.compile(rb'"(?:content|reasoning_content)"\s*:\s*"[^"]|"tool_calls"\s*:\s*\[\s*\{')


def has_first_token(chunk):
    """True when an upstream chunk carries generated output (content, reasoning or a tool-call delta), not just a role/empty delta."""
    return bool(FIRST_TOKEN.search(chunk))


def token_counts(tail, timings=None):
    """(prompt_tokens, completion_tokens) from the upstream usage object, else llama.cpp timings; None where unknown."""
    usage = None
    for match in re.finditer(rb'"usage"\s*:\s*(\{[^{}]*\})', tail):
        try:
            usage = json.loads(match.group(1))
        except ValueError:
            pass
    if isinstance(usage, dict) and usage.get('prompt_tokens') is not None:
        return usage.get('prompt_tokens'), usage.get('completion_tokens')
    if timings and timings.get('prompt_n') is not None:
        return timings['prompt_n'] + (timings.get('cache_n') or 0), timings.get('predicted_n')
    return None, None


def make_handler(engine, allow):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.0'  # streamed bodies end when the connection closes

        def log_message(self, fmt, *args):
            log.debug(fmt, *args)

        def allowed(self):
            if self.client_address[0] in allow:
                return True
            self.reply(403, {'error': {'message': 'not allowed'}})
            return False

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            if status in (429, 503):
                self.send_header('Retry-After', '5')
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if not self.allowed():
                return
            if self.path.rstrip('/') in ('/v1/models', '/models'):
                self.reply(200, {'object': 'list', 'data': [{'id': mid, 'object': 'model', 'owned_by': 'rupert-llm'} for mid in engine.models]})
            elif self.path.rstrip('/') in ('/health', '/v1/health'):
                self.reply(200, engine.status())
            else:
                self.reply(404, {'error': {'message': 'not found'}})

        def do_POST(self):
            if not self.allowed():
                return
            if self.path.rstrip('/') not in ('/v1/chat/completions', '/chat/completions'):
                return self.reply(404, {'error': {'message': 'not found'}})
            try:
                length = int(self.headers.get('Content-Length', 0))
                if not 0 < length <= 2_097_152:
                    return self.reply(413, {'error': {'message': 'request body must be 1 byte to 2 MiB'}})
                raw = self.rfile.read(length)
                if len(raw) != length:
                    return self.reply(400, {'error': {'message': 'incomplete body'}})
                body = json.loads(raw)
                if not isinstance(body, dict):
                    return self.reply(400, {'error': {'message': 'expected a JSON object'}})
            except (ValueError, RecursionError):
                return self.reply(400, {'error': {'message': 'bad json'}})
            model_id = body.get('model')
            if not isinstance(model_id, str):
                return self.reply(400, {'error': {'message': 'model must be a string'}})
            if model_id not in engine.models:
                return self.reply(404, {'error': {'message': 'unknown model %s' % model_id}})
            try:
                with engine.request_slot() as queue_ms:
                    engine.last_used = time.monotonic()
                    started = time.monotonic()
                    outcome = 'error'
                    load_started = time.monotonic()
                    load_ms = 0
                    self.timings = None
                    self.ttft_ms = None
                    self.tokens = (None, None)
                    try:
                        if self.disconnected():
                            outcome = 'cancelled'
                            return
                        try:
                            engine.ensure(model_id)
                        except OSError as error:
                            raise RuntimeError('model process unavailable') from error
                        load_ms = round((time.monotonic() - load_started) * 1000, 1)
                        if self.disconnected():
                            outcome = 'cancelled'
                            return
                        outcome = self.forward(body, queue_ms=queue_ms, load_ms=load_ms)
                    except RuntimeError as error:
                        log.warning('%s', error)
                        self.reply(503, {'error': {'message': 'model unavailable'}})
                    except (OSError, http.client.HTTPException):
                        # Headers may already have been sent: close the stream;
                        # never append a second HTTP response to partial output.
                        self.close_connection = True
                        log.warning('inference connection ended model=%s', model_id)
                    finally:
                        engine.last_used = time.monotonic()
                        with engine.metrics_lock:
                            engine.last_request = {'model': model_id, 'queue_ms': queue_ms,
                                'load_ms': load_ms, 'inference': self.timings,
                                'duration_ms': round((time.monotonic() - started) * 1000, 1), 'outcome': outcome}
                        with engine.metrics_lock:
                            engine.last_timing = {'model': model_id, 'finished_at': round(time.time(), 1), 'outcome': outcome,
                                'ttft_ms': self.ttft_ms, 'queue_ms': queue_ms,
                                'prompt_tokens': self.tokens[0], 'completion_tokens': self.tokens[1]}
                        log.info('resources %s', json.dumps(memory_status(engine.proc.pid if engine.proc else None)))
            except Busy as error:
                self.reply(429, {'error': {'message': str(error)}})

        def disconnected(self):
            try:
                readable, _, _ = select.select([self.connection], [], [], 0)
                return bool(readable) and not self.connection.recv(1, socket.MSG_PEEK)
            except OSError:
                return True

        def forward(self, body, queue_ms, load_ms):
            conn = http.client.HTTPConnection('127.0.0.1', engine.port, timeout=engine.inference_timeout)
            started = time.monotonic()
            tail = b''
            first = None
            try:
                data = json.dumps(body).encode()
                conn.request('POST', '/v1/chat/completions', body=data, headers={'Content-Type': 'application/json'})
                upstream_socket = conn.sock
                upstream = conn.getresponse()
                self.send_response(upstream.status)
                self.send_header('Content-Type', upstream.getheader('Content-Type', 'application/json'))
                self.send_header('X-Rupert-Queue-Ms', str(queue_ms))
                self.send_header('X-Rupert-Load-Ms', str(load_ms))
                self.end_headers()
                while not upstream.isclosed():
                    remaining = engine.inference_timeout - (time.monotonic() - started)
                    if remaining <= 0:
                        raise TimeoutError('inference deadline exceeded')
                    if upstream_socket:
                        upstream_socket.settimeout(remaining)
                    chunk = upstream.read1(65536)
                    if not chunk:
                        break
                    tail = (tail + chunk)[-32768:]
                    if first is None and upstream.status == 200 and has_first_token(chunk):
                        first = time.monotonic()
                        self.ttft_ms = round((first - started) * 1000, 1)
                    self.wfile.write(chunk)
                    self.wfile.flush()
                return 'ok' if upstream.status == 200 else 'upstream_error'
            finally:
                conn.close()
                self.timings = log_timings(body.get('model'), tail, time.monotonic() - started)
                self.tokens = token_counts(tail, self.timings)

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--models', default='/etc/rupert-llm/models.json')
    parser.add_argument('--listen', default='0.0.0.0:8080')
    parser.add_argument('--allow', action='append', default=['127.0.0.1'])
    parser.add_argument('--server-bin', default='/opt/llama/llama-server')
    parser.add_argument('--server-port', type=int, default=8081)
    parser.add_argument('--threads', type=int, default=8)
    parser.add_argument('--idle-seconds', type=int, default=300)
    parser.add_argument('--start-timeout', type=int, default=240)
    parser.add_argument('--keep-loaded', help='model id that stays loaded (the main bot); others still unload when idle')
    parser.add_argument('--max-queued', type=int, default=2)
    parser.add_argument('--queue-timeout', type=float, default=30)
    parser.add_argument('--inference-timeout', type=float, default=180)
    args = parser.parse_args()
    if not 0 <= args.max_queued <= 8 or not 0 < args.queue_timeout <= 120 or not 0 < args.inference_timeout <= 600:
        parser.error('max-queued must be 0..8, queue-timeout (0,120], inference-timeout (0,600]')
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    models = json.load(open(args.models))
    engine = Engine(models, args.server_bin, args.server_port, args.threads, args.idle_seconds, args.start_timeout, args.keep_loaded, args.max_queued, args.queue_timeout, args.inference_timeout)
    threading.Thread(target=engine.reap_idle, daemon=True).start()
    host, port = args.listen.rsplit(':', 1)
    server = BoundedHTTPServer((host, int(port)), make_handler(engine, set(args.allow)), max_handlers=args.max_queued + 4)
    log.info('listening on %s for %s; models: %s', args.listen, sorted(set(args.allow)), ', '.join(models))
    try:
        server.serve_forever()
    finally:
        engine.stop()


if __name__ == '__main__':
    main()
