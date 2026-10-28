# Full benchmark checkpoint — 2026-10-28

The user requested a checkpoint and full benchmark before further tuning. The tracked runtime was frozen from commit `4c2872099bdf7db3af6dc63fad96bbbc53b6412f` in an isolated test application, using copies of a synthetic fixture and a fixed October 27 anchor. Each answering model receives its own database copy. No business records are sent to a hosted model. Further implementation tuning should wait until the results are reviewed.

The previous breadth run used an older runtime and was stopped. Its latest preserved checkpoints contain 250 bookkeeping answers, 250 cross-module answers and 160 daily answers, including 42 failed executions. They must not be combined with the new runtime's results. Synthetic checkpoint files and their SHA-256 hashes are retained in `models-lfm3/benchmark-evidence/checkpoint-full-20261028`.

| Mode | Questions per model | Models | Reference capture | Purpose |
|---|---:|---|---|---|
| Depth | 73 | Local LFM3 1.7B Q4, local Qwen 3.5 4B Q4, hosted DeepSeek | 71 tool-reference entries, 2 expectation-only; no capture errors | Detailed answer and structured-view review against a shared cohort. |
| Breadth | 2,500 | Local LFM and Qwen | 341 tool-reference entries, 611 expectation-only, 1,548 capture errors | Full question-bank execution, routing, failures, timings and reference coverage; answers with insufficient references remain ungraded. |

Cohort IDs are `3a7bcc0216feb54a` (depth) and `fa7ef98b1b76706a` (breadth). A captured reference is not automatically sufficient for semantic grading and must be checked against the question. The fixture is synthetic and partly reused; the depth questions include familiar cases, so neither mode alone proves real-data accuracy or a general model ranking. Model output, chart rows, failures and reference errors are retained. Scoring is offline and requires an independent review; no automated answer-quality score is implied by execution counts.

The local scheduler runs depth on both models first, then breadth on both, in batches of at most ten and with checkpoints after each batch. DeepSeek runs the synthetic depth set separately. The full breadth run may take many hours on one GPU. LFM model SHA-256 `3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4`; Qwen model SHA-256 `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4`. Runtime and evidence are separate from production, and scores from this run should not be mixed with previous snapshots.

## Pre-review reference scope exclusions

Before inspecting this run's model answers, the captured references for `f23`, `f26`, `f32`, `f33` and `f34` were marked for exclusion from all-model comparative scoring. `f23` asks about physical-store cash but the captured rows are online records; the other four ask for online/Square scope while the supplied aggregate evidence does not fully establish that scope and can include Rupert POS. Their executions and answers remain recorded. A captured reference with no machine error is not proof that it answers the question. The frozen synthetic exclusion list is retained in the local evidence directory as `scope-exclusions-depth.json`, SHA-256 `3f90d714a140f8d61b499e297ee0cb2ffe14ba1d4e77c759206efe936dbea797`. Further exclusions may be required if other reference problems are found; report the actual denominator and reasons.
