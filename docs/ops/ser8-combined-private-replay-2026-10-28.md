# Combined-runtime local real-snapshot replay — 2026-10-28

LFM3 and Qwen each answered the same eight questions against independent copies of the same private database snapshot using server runtime `39af99c3`. Both completed 8/8. All model inference ran locally; full answers and business data remain in the private test container, and the source database and production application were not modified.

| Targeted mechanical check | LFM | Qwen |
|---|---|---|
| Sales source, amount and period | Matched | Matched |
| Register names and amounts | Matched | Matched |
| Alert SKU, quantity, threshold and pagination qualification | Matched | Matched |
| Shipping and reconciliation queue counts | Matched | Matched |
| Tax source, store, currency and amount | Matched | Matched |
| Recorded hours and scope | Matched | Matched |
| Returned overdue titles and no unsupported whole-board claim | Matched | Matched |

These are narrow, automated checks against the frozen tool references; they do not assess every sentence, prove all records are represented, or establish a general model ranking. There was one run per model and question. The offline grader collected zero reference records during the run, so the checks use the separate pre-captured private cohort; neither model was graded by a hosted service. See the earlier targeted replays for baseline comparisons.
