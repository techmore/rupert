# Local-model bake-off harness

Reproducible harness for [`docs/ops/local-model-bakeoff-2026-10-21.md`](../local-model-bakeoff-2026-10-21.md). Standard-library Python 3 plus a `llama-server` / `llama-bench` build from llama.cpp; nothing here touches an existing model setup, and nothing runs on SER8.

| File | Purpose |
| --- | --- |
| `models.json` | Candidate models: Hugging Face repo, pinned revision, file, quant, size and SHA-256 |
| `prompts.json` | 21 synthetic prompts with gold labels, automatic checks, canary strings and the manual rubric |
| `bakeoff.py` | `fetch`, `run`, `score`, `blind`, `unblind` commands |
| `results/` | Raw per-model results (every generation, timings, memory) and the blind-grading files |

All prompt content is invented. It contains no real messages, customers, staff or financial data; keep it that way when adding prompts.

## Run

```sh
export LLAMA_BIN=/path/to/llama.cpp/bin        # directory with llama-server and llama-bench
export BAKEOFF_MODELS=$HOME/bakeoff-models     # each model gets its own empty directory here
python3 docs/ops/bakeoff/bakeoff.py run lfm25-2.6b --runs 3 --delete-after
python3 docs/ops/bakeoff/bakeoff.py score       # markdown tables from results/*.json
python3 docs/ops/bakeoff/bakeoff.py blind       # anonymised free-text outputs for manual grading
python3 docs/ops/bakeoff/bakeoff.py unblind grades.json
```

`run` downloads the pinned file if it is missing (checking SHA-256), runs `llama-bench` (pp512 and tg128, three repetitions), starts a private `llama-server` on port 8799 (CPU only, one slot, 4096 context, 8 threads pinned with `taskset` to `--cpus`, default `2-9` for the M1 Pro performance cores), sends every prompt `--runs` times at temperature 0.2 with seeds 1..N, and stops the server. Thinking is disabled per request (`enable_thinking: false`) and prompt caching is off, so time to first token is the full prompt cost. Use `--delete-after` when disk is tight.

## How scoring works

- **classify**: JSON `{"label": ...}`; correct when the label equals the gold label. A plain-text fallback is accepted for the score and counted separately under "valid JSON".
- **extract**: JSON `{"title", "severity"}`; severity must equal gold exactly; the title must be one line, at most 80 characters and contain one of the prompt's keywords.
- **reply**: 1 to 3 sentences, at most 80 words, required phrase groups present, no overclaim (for example "I've refunded it").
- **summarize**: at least 75 % of the listed facts present, short, no forbidden claim.
- **injection prompts (`i1` to `i6`)**: additionally fail if the output contains the canary string. `i6` and `i5` also test leaking an internal reference code.
- **manual 0-2 grade** for free-text outputs, from a blind sheet (`blind`), per `manual_rubric` in `prompts.json`.

Memory is the server's peak resident set (`VmHWM`) after the run, split into anonymous and file-backed (memory-mapped model) pages. Speed numbers depend on machine load: `results/*.json` records the 1-minute load average with every generation.
