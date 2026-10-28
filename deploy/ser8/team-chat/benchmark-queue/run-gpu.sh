#!/usr/bin/env bash
set -euo pipefail
umask 077
root=${RUPERT_BENCHMARK_MODEL_ROOT:?Set the local model root}
out=${RUPERT_BENCHMARK_OUTPUT:?Set the private host evidence directory}
work=${RUPERT_BENCHMARK_FIXTURE_DIR:?Set the fixture directory inside rupert-test}
: "${RUPERT_BENCHMARK_GRADER_KEY:?Set the grader key}"
export RUPERT_BENCHMARK_OUTPUT
binary=$root/llama-build-vulkan/bin/llama-server
exec 9>"$out/.gpu.lock"
flock -n 9 || exit 1
pid=''
cleanup() { if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; }
trap cleanup EXIT
for ((i=0; i<1800; i++)); do [ -x "$binary" ] && break; sleep 1; done
[ -x "$binary" ] || { echo 'Vulkan build did not finish'; exit 1; }
"$binary" --list-devices > "$out/vulkan-devices.txt" 2>&1
grep -q 'Vulkan0: AMD Radeon 780M' "$out/vulkan-devices.txt" || { echo 'Radeon Vulkan device unavailable'; exit 1; }
env_args=(--env PATH=/opt/rbenv/versions/4.0.6/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin --env BUNDLE_PATH=/tmp/rupert-benchmark-gems --env RAILS_ENV=test --env RUPERT_SQLITE_DATABASE_TEST=/tmp/rupert-120-benchmark.sqlite3 --env 'BENCHMARK_ANCHOR=2026-10-27 12:00:00' --env RUPERT_LOCAL_LLM_URL=http://127.0.0.1:18081/v1)
for set in default finance cross bank; do
  for agent in qwen lfm3-text lfm3-vl lfm3-audio lfm3-omni; do
    report="$work/$agent-$set.md"
    if incus exec rupert-test -- test -f "$report"; then echo "SKIP $agent/$set"; continue; fi
    case "$agent" in
      qwen) model="$root/baselines/Qwen3.5-4B-Q4_K_M.gguf"; alias=qwen3.5-4b; projector='' ;;
      lfm3-text) model="$root/LFM3-1.7B-Q4_K_M.gguf"; alias=lfm3-text; projector='' ;;
      lfm3-vl) model="$root/LFM3-VL-2B-Q4_K_M.gguf"; alias=lfm3-vl; projector="$root/mmproj-LFM3-VL-2B-Q8_0.gguf" ;;
      lfm3-audio) model="$root/LFM3-Audio-2B-Q4_K_M.gguf"; alias=lfm3-audio; projector="$root/mmproj-LFM3-Audio-2B-Q8_0.gguf" ;;
      lfm3-omni) model="$root/LFM3-Omni-2B-Q4_K_M.gguf"; alias=lfm3-omni; projector="$root/mmproj-LFM3-Omni-2B-Q8_0.gguf" ;;
    esac
    args=(--model "$model" --alias "$alias" --host 127.0.0.1 --port 18081 --api-key local --ctx-size 16384 --threads 4 --jinja --parallel 1 --no-webui --no-warmup --verbose --n-gpu-layers 99 --chat-template-kwargs '{"enable_thinking":false}' --reasoning-budget 0 --n-predict 1024)
    [ -z "$projector" ] || args+=(--mmproj "$projector")
    "$binary" "${args[@]}" > "$out/server-$agent-$set.log" 2>&1 & pid=$!
    ready=''
    for ((i=0; i<120; i++)); do kill -0 "$pid" 2>/dev/null || { echo "server failed $agent"; exit 1; }; if curl -fsS --max-time 2 http://127.0.0.1:18081/health >/dev/null 2>&1; then ready=1; break; fi; sleep 1; done
    [ -n "$ready" ] || { echo 'server timed out'; exit 1; }
    grep -Eq 'offloaded [1-9][0-9]*/' "$out/server-$agent-$set.log" || { echo 'GPU layers were not offloaded'; exit 1; }
    echo "START $agent/$set $(date -Is)"
    printf '%s\n' "$RUPERT_BENCHMARK_GRADER_KEY" |
      timeout 21600 incus exec rupert-test "${env_args[@]}" --env MODE=run --env "BATTERY=$set" --env "COHORT=$work/$set.enc" --env "AGENT=$agent" --env "REPORT=$report" -- sh -c 'read -r RUPERT_CHAT_API_KEY; export RUPERT_CHAT_API_KEY; cd /tmp/rupert-benchmark-audit/web && bundle exec rails runner script/team_chat_fixture_battery.rb'
    incus file pull "rupert-test$report" "$out/$agent-$set.md"
    kill "$pid"; wait "$pid" || true; pid=''
    "$(dirname "$0")/compare-ready.sh"
    echo "DONE $agent/$set $(date -Is)"
  done
done
