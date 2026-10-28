# Breadth checkpoint — 2026-10-28

These are synthetic LFM-only runs using the older `53f0392f` runtime, not the latest tooling. Checkpoints below were inspected while the ten-question scheduler continued. A completed answer is not necessarily a correct answer. `reference_or_grader_unavailable` means there is no usable grade, not a low quality score. Failed executions are counted separately and must not be omitted from reliability reporting.

| Area | Checkpointed | Done | Failed | Reference or grader unavailable | Median elapsed |
|---|---:|---:|---:|---:|---:|
| Bookkeeping | 250 | 222 | 28 | 116 | 10.4 s |
| Cross-module | 250 | 242 | 8 | 215 | 13.4 s |
| Daily | 10 | 10 | 0 | 10 | 13.4 s |
| **Total** | **510** | **474** | **36** | **341** | — |

The failure messages include model connection failures and generic execution failures; the checkpoint alone does not establish a precise underlying cause for every case. The run uses a frozen earlier cohort, so the subsequently authored expectations do not retroactively grade it. Results cannot establish whether the latest LFM implementation beats Qwen. Current breadth work and the separate comparative review share the GPU through short batches.
