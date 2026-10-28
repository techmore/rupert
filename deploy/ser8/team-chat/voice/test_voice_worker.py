import importlib.util
import subprocess
import socket
import threading
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('voice_worker', Path(__file__).with_name('voice_worker.py'))
voice = importlib.util.module_from_spec(spec)
spec.loader.exec_module(voice)


class VoiceWorkerTest(unittest.TestCase):
    def test_incomplete_request_body_times_out(self):
        old_timeout = voice.SOCKET_TIMEOUT
        voice.SOCKET_TIMEOUT = 0.1
        server = voice.make_server(object(), 't' * 32, 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with socket.create_connection(server.server_address, timeout=2) as client:
                client.sendall(b'POST /transcribe HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ' +
                               b't' * 32 + b'\r\nContent-Length: 10\r\n\r\nx')
                response = client.recv(4096)
                self.assertIn(b'503', response)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            voice.SOCKET_TIMEOUT = old_timeout

    def test_input_formats_are_detected_from_bytes(self):
        self.assertEqual('wav', voice.audio_format(b'RIFF' + b'\0' * 4 + b'WAVE'))
        self.assertEqual('webm', voice.audio_format(b'\x1a\x45\xdf\xa3payload'))
        self.assertEqual('ogg', voice.audio_format(b'OggSpayload'))
        self.assertEqual('mov', voice.audio_format(b'\0\0\0\x18ftypxxxx'))
        with self.assertRaises(ValueError):
            voice.audio_format(b'not audio')

    def test_empty_oversized_and_invalid_text_are_rejected_before_execution(self):
        worker = voice.Worker(model='m', projector='p', mtmd='a', tts='b')
        for data in (b'', b'x' * (voice.MAX_AUDIO + 1), b'bad'):
            with self.assertRaises(ValueError):
                worker.transcribe(data)
        for text in ('', 'x' * (voice.MAX_TEXT + 1), None):
            with self.assertRaises(ValueError):
                worker.speak(text)

    def test_simultaneous_requests_fail_fast_instead_of_waiting_unbounded(self):
        worker = voice.Worker(model='m', projector='p', mtmd='a', tts='b')
        with worker.slot():
            with self.assertRaises(BlockingIOError):
                with worker.slot():
                    pass

    def test_streamed_webm_without_duration_metadata_and_long_recording(self):
        worker = voice.Worker(model='m', projector='p', mtmd='model-cli', tts='b')
        original = worker.command
        worker.command = lambda args, timeout: b'Hello' if args[0] == 'model-cli' else original(args, timeout=timeout)
        short = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=0.3',
                                '-c:a', 'libopus', '-f', 'webm', 'pipe:1'], check=True, stdout=subprocess.PIPE).stdout
        self.assertEqual('Hello', worker.transcribe(short))
        long = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=31',
                               '-f', 'wav', 'pipe:1'], check=True, stdout=subprocess.PIPE).stdout
        with self.assertRaises(ValueError):
            worker.transcribe(long)


if __name__ == '__main__':
    unittest.main()
