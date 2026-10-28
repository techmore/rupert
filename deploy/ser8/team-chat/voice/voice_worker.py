#!/usr/bin/env python3
"""Local LFM3 speech worker. It accepts only bounded audio or text, never paths."""
import argparse
import base64
from contextlib import contextmanager
import hmac
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_AUDIO = 4 * 1024 * 1024
MAX_TEXT = 4000
MAX_SECONDS = 30
SOCKET_TIMEOUT = 15


def audio_format(data):
    if len(data) >= 12 and data[:4] == b'RIFF' and data[8:12] == b'WAVE':
        return 'wav'
    if data.startswith(b'\x1a\x45\xdf\xa3'):
        return 'webm'
    if data.startswith(b'OggS'):
        return 'ogg'
    if len(data) >= 12 and data[4:8] == b'ftyp':
        return 'mov'
    raise ValueError('Unsupported recording format')


class Worker:
    def __init__(self, *, model, projector, mtmd, tts, ffmpeg='ffmpeg', threads=2):
        self.model, self.projector, self.mtmd, self.tts = model, projector, mtmd, tts
        self.ffmpeg, self.threads = ffmpeg, threads
        self.lock = threading.BoundedSemaphore(1)

    @contextmanager
    def slot(self):
        if not self.lock.acquire(blocking=False):
            raise BlockingIOError('Speech service is busy')
        try:
            yield
        finally:
            self.lock.release()

    def command(self, args, *, timeout):
        result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, check=True)
        return result.stdout

    def transcribe(self, data):
        if not data or len(data) > MAX_AUDIO:
            raise ValueError('Recording is empty or too large')
        kind = audio_format(data)
        with self.slot(), tempfile.TemporaryDirectory(prefix='rupert-voice-') as directory:
            source, wav = Path(directory) / 'input', Path(directory) / 'input.wav'
            source.write_bytes(data)
            os.chmod(source, 0o600)
            self.command([self.ffmpeg, '-nostdin', '-v', 'error', '-protocol_whitelist', 'file,pipe', '-f', kind,
                          '-i', str(source), '-t', str(MAX_SECONDS + 1), '-ac', '1', '-ar', '16000', '-y', str(wav)], timeout=30)
            try:
                with wave.open(str(wav), 'rb') as decoded:
                    seconds = decoded.getnframes() / decoded.getframerate()
            except (wave.Error, EOFError, ZeroDivisionError) as exc:
                raise ValueError('Could not decode the recording') from exc
            if not 0 < seconds <= MAX_SECONDS:
                raise ValueError('Recordings must be 30 seconds or shorter')
            output = self.command([self.mtmd, '-m', self.model, '-mm', self.projector, '--audio', str(wav),
                                   '-sys', 'Perform ASR.', '-p', '<__media__>', '--temp', '0', '-n', '512', '-c', '2048',
                                   '-t', str(self.threads), '--no-warmup'], timeout=120)
            text = output.decode('utf-8', 'strict').strip()
            if not text or len(text) > MAX_TEXT:
                raise ValueError('Speech could not be transcribed')
            return text

    def speak(self, text):
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
            raise ValueError('Message is empty or too long')
        with self.slot(), tempfile.TemporaryDirectory(prefix='rupert-voice-') as directory:
            prompt, output = Path(directory) / 'text', Path(directory) / 'speech.wav'
            prompt.write_text(text, encoding='utf-8')
            os.chmod(prompt, 0o600)
            self.command([self.tts, '-m', self.model, '-mm', self.projector, '-f', str(prompt), '-o', str(output),
                          '-t', str(self.threads), '-n', '-1'], timeout=180)
            data = output.read_bytes()
            if len(data) > 16 * 1024 * 1024 or not data.startswith(b'RIFF'):
                raise ValueError('Speech output was invalid')
            return data


def make_server(worker, token, port):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(SOCKET_TIMEOUT)

        def log_message(self, *_args):
            pass  # Never log speech or text.

        def reply(self, code, body):
            raw = json.dumps(body).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(raw)

        def do_POST(self):
            if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token):
                return self.reply(401, {'error': 'Unauthorized'})
            try:
                size = int(self.headers.get('Content-Length', '-1'))
                limit = MAX_AUDIO if self.path == '/transcribe' else 32768
                if size < 1 or size > limit:
                    return self.reply(413, {'error': 'Request too large'})
                data = self.rfile.read(size)
                if len(data) != size:
                    return self.reply(400, {'error': 'Incomplete request'})
                if self.path == '/transcribe':
                    return self.reply(200, {'text': worker.transcribe(data)})
                if self.path == '/speak':
                    payload = json.loads(data)
                    if not isinstance(payload, dict):
                        return self.reply(422, {'error': 'Invalid message'})
                    return self.reply(200, {'audio': base64.b64encode(worker.speak(payload.get('text'))).decode('ascii')})
                return self.reply(404, {'error': 'Not found'})
            except (ValueError, UnicodeError, json.JSONDecodeError):
                return self.reply(422, {'error': 'Could not process the recording or message'})
            except BlockingIOError:
                return self.reply(429, {'error': 'Speech service is busy'})
            except (OSError, subprocess.SubprocessError):
                return self.reply(503, {'error': 'Speech service unavailable'})

    return ThreadingHTTPServer(('127.0.0.1', port), Handler)


def main():
    parser = argparse.ArgumentParser()
    for name in ('model', 'projector', 'mtmd', 'tts', 'token-file'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--port', type=int, default=18082)
    parser.add_argument('--threads', type=int, default=2)
    args = parser.parse_args()
    token = Path(args.token_file).read_text().strip()
    if len(token) < 32:
        raise SystemExit('Token must have at least 32 characters')
    make_server(Worker(model=args.model, projector=args.projector, mtmd=args.mtmd, tts=args.tts, threads=args.threads), token, args.port).serve_forever()


if __name__ == '__main__':
    main()
