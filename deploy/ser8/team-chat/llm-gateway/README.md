# rupert-llm: local models for Team chat's @agents

Runs in its own Incus container on SER8 (`rupert-llm`, 10.96.131.7), never inside `rupert`. See docs/ops/team-chat.md.

The commands below describe the historical CPU bootstrap. On the provisioned
Vulkan SER8, follow the shared-gateway rollout section below instead; preserve the
current Vulkan binary link and model files.

```bash
incus launch images:ubuntu/24.04 rupert-llm -c limits.cpu=8 -c limits.memory=14GiB -c boot.autostart=true -c security.idmap.isolated=true
incus config device override rupert-llm eth0 ipv4.address=10.96.131.7 && incus restart rupert-llm
# llama.cpp (PrismML fork, CPU) + the three models, all sha256-checked:
incus file push setup.sh rupert-llm/root/setup.sh && incus exec rupert-llm -- bash /root/setup.sh
incus exec rupert-llm -- ln -sfn /opt/llama/llama-prism-b10787-73bfe6c /opt/llama/current
incus file push llm_gateway.py rupert-llm/usr/local/lib/rupert-llm/llm_gateway.py --create-dirs
incus file push models.json rupert-llm/etc/rupert-llm/models.json --create-dirs
incus file push rupert-llm-gateway.service rupert-llm/etc/systemd/system/
incus exec rupert-llm -- systemctl enable --now rupert-llm-gateway
incus exec rupert-llm -- curl -s 127.0.0.1:8080/health
```

Adding a model: put its GGUF in `/var/lib/rupert-llm/models/`, add it to `models.json`, restart the gateway, and add
an entry to `TeamChat::LocalAgents::ALL` (handle, name, model id).

## Shared Ask Rupert gateway and SER8 limits

When `RUPERT_LOCAL_LLM_URL` is configured, Ask Rupert uses this gateway for its
local provider too, with `qwen3.5-4b`, at most 700 output tokens, native function
schemas and the existing Rails tool authorization. Without that URL, its Ollama
adapter remains available. `ASK_RUPERT_MODE=local_only` never falls back to cloud;
`auto` retains the existing short-how-to routing and cloud backup. Cloud mode is
unchanged. A saved workspace mode overrides the environment default.

Keep the Qwen 4B GGUF, Vulkan backend, model context and one-model policy unchanged.
This change installs no model, raises no GPU allocation and does not increase the
SER8's 32 GB physical RAM or the existing container limit. GPU GTT and RAM share
physical capacity: do not add them together or rely on the container RSS limit to
account for GPU allocations.

The service explicitly admits one request plus at most two waiting requests. A
waiter expires after 30 seconds; full/expired queues return HTTP 429 with
`Retry-After: 5`. There are at most six HTTP handler threads, a 15-second client
socket timeout and a 2 MiB request-body limit. Exhausted handler capacity returns
503. Health requests do not acquire the inference lock. Queued clients that close
their connection are discarded before loading/generating; an active inference
has a 180-second deadline and closes on transport errors. Model startup retains
its separate existing 240-second deadline. Ask Rupert's local request has its own
120-second total deadline and does not stream drafts or tool-call fragments.

`/health` adds `queue.waiting`, `queue.rejected` and `queue.last_request` (model,
queue/load/active duration, outcome and upstream inference timings when supplied).
Responses include `X-Rupert-Queue-Ms` and `X-Rupert-Load-Ms`. Existing timing logs
separate prompt evaluation, cache reuse and generation. The resource log and
`memory` health field report available `/proc/meminfo`, model RSS, and DRM
VRAM/GTT counters. Missing counters are omitted. Incus can virtualize or hide
these counters: they are explicitly **gateway-visible**, not verified host totals.
No prompts, results or business figures are added to these logs.

Before rollout, record the deployed revision and the host's `free -h`, `vmstat 1`
and `/sys/class/drm/card*/device/mem_info_{vram,gtt}_used` while web/database/jobs
and Qwen are active. Compare warm, cold, and competing Ask Rupert/team-chat
requests. Keep headroom for the OS, web workers, database and jobs; do not promote
a configuration with sustained swap, OOMs or increased web/job latency. The new
telemetry helps evaluate that budget; it does not claim a measured RAM reserve.

Validate with `python3 -m unittest discover -s deploy/ser8/tests -p test_llm_gateway.py -v`
and the Rails Ask Rupert, tools, permission and team-chat tests before deployment.
Deploy the gateway script and service together, reload systemd and restart the
gateway during a maintenance window; then verify `/health` and one local-only
question from each surface. Existing local modes automatically select the shared
adapter when the URL is set. For rollback restore the previous script/service and
unset the shared URL only if returning Ask Rupert to Ollama is intended (that URL
also enables team-chat local models). No database migration is required.

The CLI prompt budget now retains the full policy/schema section and whole recent
turns/tool exchanges. It discards old turns first and fails explicitly if required
sections alone exceed the budget. The gateway also budgets schema characters and
rejects malformed, unknown, multiple or truncated native tool calls. Rails still
rechecks permissions and argument schemas at execution time.
