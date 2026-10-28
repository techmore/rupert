#!/usr/bin/env python3
"""Isolated diagnostic, not part of the scored business battery."""
import hashlib
import os
import fcntl
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(os.environ.get('RUPERT_BENCHMARK_MODEL_ROOT', str(Path.home() / 'models-lfm3')))
OUT = Path(os.environ.get('RUPERT_BENCHMARK_OUTPUT', str(ROOT / 'benchmark-evidence/multimodal')))
MODELS = {
    'lfm3-omni': (ROOT / 'LFM3-Omni-2B-Q4_K_M.gguf', ROOT / 'mmproj-LFM3-Omni-2B-Q8_0.gguf'),
}
SERVER = ROOT / 'llama-build-clean/bin/llama-server'
URL = 'http://127.0.0.1:18083'
BODY = {'model': 'lfm3-omni', 'temperature': 0, 'max_tokens': 256,
        'messages': [{'role': 'user', 'content': 'Use the get_weather tool to look up the weather in Oslo.'}],
        'tools': [{'type': 'function', 'function': {'name': 'get_weather', 'description': 'Get current weather.',
                  'parameters': {'type': 'object', 'properties': {'city': {'type': 'string'}}, 'required': ['city']}}}],
        'tool_choice': 'auto'}

def main():
    path = OUT / 'tool-compatibility.jsonl'
    seen = set()
    if path.exists():
        with path.open() as f:
            seen = {(row['model'], row['setting']) for row in map(json.loads, f)}
    for model, setting in ((model, setting) for model in MODELS for setting in ('current', 'reasoning-off', 'reasoning-off-unlimited', 'current-vulkan')):
        if (model, setting) in seen:
            continue
        model_file, projector = MODELS[model]
        server_binary = ROOT / 'llama-build-vulkan/bin/llama-server' if setting == 'current-vulkan' else SERVER
        cmd = [str(server_binary), '--model', str(model_file), '--alias', model,
               '--host', '127.0.0.1', '--port', '18083', '--api-key', 'local', '--ctx-size', '4096',
               '--threads', '2', '--jinja', '--parallel', '1', '--no-webui', '--no-warmup',
               '--reasoning-budget', '-1' if setting == 'reasoning-off-unlimited' else '0']
        if projector:
            cmd += ['--mmproj', str(projector)]
        cmd += ['--chat-template-kwargs', '{"enable_thinking":false}'] if setting in ('current', 'current-vulkan') else ['--reasoning', 'off']
        if setting == 'current-vulkan':
            cmd += ['--n-gpu-layers', '99']
        with model_file.open('rb') as model_stream:
            model_hash = hashlib.file_digest(model_stream, 'sha256').hexdigest()
        body = dict(BODY, model=model)
        result = {'model': model, 'setting': setting, 'model_sha256': model_hash,
                  'request': body, 'status': 'error'}
        with (OUT / (model + '-tool-' + setting + '.log')).open('wb') as log:
            process = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(90):
                    if process.poll() is not None:
                        raise RuntimeError('server exited during startup')
                    try:
                        with urllib.request.urlopen(URL + '/health', timeout=1) as response:
                            if response.status == 200:
                                break
                    except (OSError, urllib.error.URLError):
                        time.sleep(1)
                else:
                    raise RuntimeError('server startup timed out')
                request = urllib.request.Request(URL + '/v1/chat/completions', data=json.dumps(body).encode(),
                            headers={'Authorization': 'Bearer local', 'Content-Type': 'application/json'})
                started = time.monotonic()
                with urllib.request.urlopen(request, timeout=120) as response:
                    result['response'] = json.load(response)
                result['seconds'] = round(time.monotonic() - started, 2)
                result['status'] = 'ok'
            except Exception as exc:
                result['error'] = type(exc).__name__ + ': ' + str(exc)[:300]
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        with path.open('a') as f:
            f.write(json.dumps(result, ensure_ascii=False) + '\n')
        path.chmod(0o600)
        print(model, 'tool compatibility', setting, result['status'], flush=True)

if __name__ == '__main__':
    with (OUT / '.omni-tool.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        main()
