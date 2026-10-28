# SER8 depth review: cross-domain questions

The independent masked review scored all 10 original cross-domain questions using frozen synthetic references and authored expectations. Scores were written before revealing the per-question shuffled model labels (decisions SHA-256 `517f7db9b984aafeb056eb5cf1f021c1a7dcdf0e07b0393e3350dd55b8ebeee0`). No model graded its own output.

| Model and server | Points / 50 | Correctness / 20 | Complete coverage / 10 | Relevance / 10 |
| --- | ---: | ---: | ---: | ---: |
| LFM with adjusted server | 37 | 16 | 6 | 5 |
| DeepSeek with earlier server | 32 | 15 | 5 | 2 |
| Qwen with earlier server | 29 | 11 | 3 | 6 |

Across the 21 general, 29 finance and 10 cross-domain questions with usable references, LFM scored 226/300, Qwen 220/300 and DeepSeek 207/300. Six finance questions were excluded for all models because their references could not support a fair judgment. The models used different server revisions; this evaluates combinations of model and server. The questions and synthetic fixture were reused during tuning, the reviewer had seen prior benchmark material, and each model ran once. The scoring depends on judgment and rubric weighting. This narrow result is encouraging but does not prove general superiority or a plateau; broader and held-out validation remain necessary.

Failure patterns include confusing an open alert's recorded quantity with current stock, claiming watch items must block a month lock, failing to explain missing physical-store data, and burying correct answers in unrelated tool output. The later alert and chart guards, refunded-order handoff and chart fallback were not part of this depth run and require separate replay.
