#!/bin/sh
# Quality (GPU) then speed (CPU, waits for a quiet machine) for each model, deleting the download afterwards.
# Usage: BAKEOFF_MODELS=... LLAMA_BIN=... sh run-all.sh model-id [model-id ...]
cd "$(dirname "$0")" || exit 1
for id in "$@"; do
  python3 bakeoff.py run "$id" --mode quality || python3 bakeoff.py run "$id" --mode quality --cpu || continue
  python3 bakeoff.py run "$id" --mode speed --max-load 8 --wait-s 120 --delete-after
done
