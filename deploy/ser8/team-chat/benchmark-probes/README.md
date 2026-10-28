# Experimental LFM3 probes

These scripts record small synthetic audio, image and tool-call checks. They are diagnostics, not a representative benchmark or a production service. `run_probes.py` requires the synthetic WAV and PNG fixtures in `RUPERT_BENCHMARK_OUTPUT/fixtures`; `omni_tool_probe.py` calls a local llama-server with a synthetic weather tool. Both require the named local GGUF files and llama.cpp builds under `RUPERT_BENCHMARK_MODEL_ROOT`.

Set `RUPERT_BENCHMARK_MODEL_ROOT` and `RUPERT_BENCHMARK_OUTPUT` to private directories before running. The default model root is `~/models-lfm3` and the default output is its `benchmark-evidence/multimodal` directory. Create the output directory with owner-only permissions. Model weights, fixtures, run outputs and production data do not belong in the repository. Run only when the local inference hardware is available; these scripts do not coordinate with a production gateway or a benchmark queue.

The Omni probe includes a Vulkan case and CPU cases with different reasoning settings. Their context and thread settings are not identical to the business benchmark, so results are a compatibility diagnostic, not a controlled leaderboard. Keep the recorded settings and raw results when evaluating changes.

`local-snapshot.sh` copies a consistent SQLite snapshot from the isolated benchmark fixture to a local evidence directory. Set `RUPERT_BENCHMARK_OUTPUT` to that directory and `RUPERT_BENCHMARK_CONTAINER` to the fixture container. The database and temporary snapshot paths are deliberately fixed to this test setup; do not use it on a production container. It does not write to the NAS. Its mocked checks run with `python3 -m unittest deploy.ser8.tests.test_benchmark_local_snapshot`.
