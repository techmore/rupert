# Fresh-question comparison on SER8

A 12-question comparison was authored and frozen after the earlier depth review. It covers source and currency separation, profit limitations, queue and stock evidence, retention and close status, refunds, settlement deposits, pay-week sales, and sync completeness. The questions are new to this run, but the synthetic database fixture has been used before; this is not a new data distribution or a real-business-data comparison.

All three model runs use the same Rupert runtime snapshot (`8b91593d`) and separate copies of the same synthetic fixture. The question file SHA-256 is `dd2e81f6c363a66be473b77fe05a54f5182937cfd8ade818f5f9db5cf9f8bf9a`; the frozen reference export SHA-256 is `10c5086ccdc4614b3aac3f639f427d646bca3c7a7507f89b7977d8bdd596f233`. The frozen cohort is `e1360dc347dc7fb7`, with zero capture errors; one question is evaluated against an authored capability expectation instead of a reference lookup. The questions, references, scripts and resulting synthetic answers reside in the local benchmark evidence directory, outside the runtime application.

DeepSeek generates synthetic-fixture answers only. It does not grade itself. LFM and Qwen run locally on the SER8, queued around the ongoing breadth benchmark. Once all three runs finish, review the answers in shuffled per-question order and record judgments before revealing the mapping. The reviewer has seen earlier benchmark work, so this is masked rather than fully blind. Retain failed answers and disclose reference gaps rather than silently omitting them.

The first attempt was stopped and invalidated after a reference-drift check exposed an extra synthetic order in the model copy. All subsequent copies come from a single frozen capture database. A preflight recapture from that database reproduced the same cohort ID with zero capture errors. The partial first-attempt answers are retained but must not be scored.

## Independent masked review

All three runs completed 12/12, with no frozen-reference drift. The exact-run answer exports matched all 12 reference-log answers per model. The reviewer scored correctness (0–2), coverage (0–1), grounding (0–1), and relevance (0–1) before revealing the shuffled labels; the decisions SHA-256 is `ec93e38223485d2657a17407eefdb0e22235dc291dce5fa16a4052f2c1a2624b`. No questions were excluded.

| Model | Points / 60 | Correctness / 24 | Coverage / 12 | Relevance / 12 |
| --- | ---: | ---: | ---: | ---: |
| Qwen | 35 | 14 | 4 | 5 |
| DeepSeek | 34 | 15 | 6 | 1 |
| LFM | 28 | 12 | 3 | 1 |

LFM did not beat Qwen on these fresh questions. The main failures were wrong date scopes, long irrelevant evidence dumps, missing direct retention and lock answers, and substituting paid-order counts for requested refunded-order counts. All three omitted some refund amount/count details. The later refund-transaction evidence and deposit clarification were not in the frozen `8b91593d` runtime and must be evaluated independently; the earlier targeted handoffs do not establish that they handle these new phrasings.

This is one run per model on a previously used synthetic fixture, with a reviewer who had seen earlier work. The absolute scores and ordering depend on judgment and rubric weights. It is evidence of a regression on this sample, not proof of a universal model ranking.
