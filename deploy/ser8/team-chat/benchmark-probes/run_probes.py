#!/usr/bin/env python3
"""Small synthetic multimodal probes; these are not a representative benchmark."""
import hashlib
import os
import json
import re
import subprocess
import time
from pathlib import Path

ROOT = Path(os.environ.get('RUPERT_BENCHMARK_MODEL_ROOT', str(Path.home() / 'models-lfm3')))
OUT = Path(os.environ.get('RUPERT_BENCHMARK_OUTPUT', str(ROOT / 'benchmark-evidence/multimodal')))
FIX = OUT / 'fixtures'
CLI = ROOT / 'llama-build-clean/bin/llama-mtmd-cli'
MODELS = {
    'lfm3-audio': ('LFM3-Audio-2B-Q4_K_M.gguf', 'mmproj-LFM3-Audio-2B-Q8_0.gguf'),
    'lfm3-omni': ('LFM3-Omni-2B-Q4_K_M.gguf', 'mmproj-LFM3-Omni-2B-Q8_0.gguf'),
    'lfm3-vl': ('LFM3-VL-2B-Q4_K_M.gguf', 'mmproj-LFM3-VL-2B-Q8_0.gguf'),
}
CASES = [
    ('lfm3-audio', 'asr', 'clean.wav', 'hello the answer is 42'),
    ('lfm3-audio', 'asr', 'noisy.wav', 'hello the answer is 42'),
    ('lfm3-audio', 'asr', 'order.wav', 'please check the oldest unpaid order'),
    ('lfm3-audio', 'asr', 'task.wav', 'the inventory count is due on friday'),
    ('lfm3-omni', 'asr', 'clean.wav', 'hello the answer is 42'),
    ('lfm3-omni', 'asr', 'noisy.wav', 'hello the answer is 42'),
    ('lfm3-omni', 'asr', 'order.wav', 'please check the oldest unpaid order'),
    ('lfm3-omni', 'asr', 'task.wav', 'the inventory count is due on friday'),
    ('lfm3-vl', 'color', 'one-red.png', 'red'),
    ('lfm3-vl', 'color', 'two-blue.png', 'blue'),
    ('lfm3-vl', 'color', 'one-green.png', 'green'),
    ('lfm3-omni', 'color', 'one-red.png', 'red'),
    ('lfm3-omni', 'color', 'two-blue.png', 'blue'),
    ('lfm3-omni', 'color', 'one-green.png', 'green'),
]

def words(text):
    text = re.sub(r'\bforty[ -]two\b', '42', text.lower())
    return re.findall(r'[a-z]+|[0-9]+', text)

def distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        nxt = [i]
        for j, y in enumerate(b, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j-1] + (x != y)))
        row = nxt
    return row[-1]

def main():
    results = OUT / 'results.jsonl'
    existing = set()
    if results.exists():
        with results.open() as f:
            existing = {(r['model'], r['kind'], r['fixture']) for r in map(json.loads, f)}
    for model, kind, filename, expected in CASES:
        if (model, kind, filename) in existing:
            continue
        model_file, projector = MODELS[model]
        args = [str(CLI), '-m', str(ROOT / model_file), '-mm', str(ROOT / projector),
                '-t', '2', '-c', '2048', '-n', '128', '--temp', '0', '--no-warmup', '--log-disable']
        if kind == 'asr':
            args += ['--audio', str(FIX / filename), '-sys', 'Perform ASR.', '-p', '<__media__>']
        else:
            args += ['--image', str(FIX / filename), '-p', 'What color are the shapes? Answer with just the color. <__media__>']
        started = time.monotonic()
        row = {'model': model, 'kind': kind, 'fixture': filename, 'expected': expected,
               'fixture_sha256': hashlib.sha256((FIX / filename).read_bytes()).hexdigest()}
        try:
            result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            row.update(status='ok' if result.returncode == 0 else 'error', exit_code=result.returncode,
                       response=result.stdout.decode('utf-8', errors='replace').strip())
            if result.returncode != 0:
                row['error'] = result.stderr.decode('utf-8', errors='replace')[-2000:]
            if result.returncode == 0:
                actual = words(row['response'])
                if kind == 'asr':
                    reference = words(expected)
                    row['word_errors'] = distance(reference, actual)
                    row['reference_words'] = len(reference)
                else:
                    colors = [x for x in actual if x in {'red','blue','green','yellow','black','white'}]
                    row['correct'] = bool(colors) and set(colors) == {expected}
        except subprocess.TimeoutExpired as exc:
            row['status'] = 'timeout'
            row['response'] = (exc.stdout or b'').decode('utf-8', errors='replace').strip()
        row['seconds'] = round(time.monotonic() - started, 2)
        with results.open('a') as f:
            f.write(json.dumps(row, ensure_ascii=False) + '\n')
            f.flush()
        results.chmod(0o600)
        print(f"{model} {kind} {filename}: {row['status']}", flush=True)

if __name__ == '__main__':
    main()
