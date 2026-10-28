# Breadth checkpoint — 2026-10-28

These are synthetic LFM-only runs using the older `53f0392f` runtime, not the latest tooling. Checkpoints below were inspected while the ten-question scheduler continued. A completed answer is not necessarily a correct answer. `reference_or_grader_unavailable` means there is no usable grade, not a low quality score. Failed executions are counted separately and must not be omitted from reliability reporting.

| Area | Checkpointed | Done | Failed | Reference or grader unavailable | Median elapsed |
|---|---:|---:|---:|---:|---:|
| Bookkeeping | 250 | 222 | 28 | 116 | 10.4 s |
| Cross-module | 250 | 242 | 8 | 215 | 13.4 s |
| Daily | 10 | 10 | 0 | 10 | 13.4 s |
| **Total** | **510** | **474** | **36** | **341** | — |

The failure messages include model connection failures and generic execution failures; the checkpoint alone does not establish a precise underlying cause for every case. The run uses a frozen earlier cohort, so the subsequently authored expectations do not retroactively grade it. Results cannot establish whether the latest LFM implementation beats Qwen. Current breadth work and the separate comparative review share the GPU through short batches.

## Oversized comparison-chart reply

A separate DeepSeek comparison run failed its month-over-month chart question with `ActiveRecord::RecordInvalid` after three view attempts were rejected. Reconstructing the financial evidence from its saved tool results produced 8,374 characters before additional sections, exceeding the message's 8,000-character validation limit. This supports a reply-size failure, though the stored telemetry did not record the invalid field. Commit `fbb4fc3c` bounds replies on complete lines and discloses omitted details and caveats; it does not itself make a rejected chart valid. A synthetic live replay is pending, and the original failure remains in the frozen comparison.

The later live replay completed in 37.0 seconds with a 6,228-character answer, but produced no accepted view and did not trigger the size cap. It therefore confirms neither an adjustable chart nor that the cap fixed the earlier failure; the bounded-reply tests cover the size limit directly. The replay evidence is retained under `models-lfm3/benchmark-evidence/long-reply-replay-20261028`.

After the period-comparison view contract in `553ae8a0`, the same synthetic question was replayed through hosted DeepSeek. The run completed in 31.9 seconds and returned an adjustable bar chart with August and September labels, separate CAD and USD columns, recorded values 151.90 CAD / 425.25 USD and 80.00 USD respectively, and a blank missing September CAD value. The note distinguishes missing records from zero or complete coverage. This is a targeted known-case replay, not a new comparative score. Evidence is retained under `models-lfm3/benchmark-evidence/period-chart-replay-20261028`.
