# Broader synthetic comparison — first five questions

The 13-question comparison uses a frozen synthetic fixture and runtime through `292c80d6`, prior to subsequent chart changes. It includes existing battery questions and is not a fully unseen holdout. The same cohort `7cfd6e9d65f9669b` was reproduced on a second copy. Each model ran once; DeepSeek was hosted and the local models shared a GPU. This self-review used per-question shuffled labels. The reviewer knew the prior work and some run-level execution details, so this is not an independent external audit.

A 1–5 scale was used: 1 unusable or materially wrong; 2 limited; 3 partial; 4 materially correct with clutter or minor issues; 5 complete. The first five decisions were frozen before their model identities were opened. The unsafe f20 instruction allowing subtraction without established currency compatibility was explicitly corrected for scoring before reviewing answers.

| Question | LFM | Qwen 3.5 4B | DeepSeek | Observation |
|---|---:|---:|---:|---|
| Sales so far today | 3 | 4 | 4 | No orders were recorded; all qualified missing data, but LFM added unrelated previous-day and queue results. |
| Last week's average order value | 4 | 4 | 5 | All gave the correct amount; local outputs added prior-period warnings. |
| Best sales day in last 30 days | 2 | 2 | 4 | Both local models reported separate calendar months instead of the requested 30-day window. |
| Last month's expenses | 3 | 3 | 2 | None directly gave the visible expense total and currency limitation; DeepSeek added unrelated sales details. |
| Last month's profit margin | 4 | 3 | 4 | None invented a margin; Qwen did not explain the missing evidence. |
| **First five total** | **16/25** | **16/25** | **19/25** | **Partial result only; the remaining eight answers are pending.** |

The best-day result motivated a server-side date-window correction; its tests and any live replay must be reported separately, not substituted into these frozen results. The DeepSeek chart execution failure remains part of the pending eight questions. Full-quality rankings cannot be inferred from these five observations.

Synthetic local evidence is retained in `models-lfm3/benchmark-evidence/breadth-review-20261028`: masked first-five inputs SHA-256 `fb5bf7c71fd3f656d7506bac9d315d6799dd100087a7886a9ebc7f607e5022c5`; frozen decisions SHA-256 `c8e76e0bf1c5c9349985dd0460218dea5d1c2008801ab907691c745a8d038d66`.

## Next five questions

| Question | LFM | Qwen 3.5 4B | DeepSeek | Observation |
|---|---:|---:|---:|---|
| Processor deposits in transit | 5 | 5 | 5 | All correctly reported that the available records could not establish pending deposits. |
| Sales versus expenses | 3 | 3 | 3 | All gave the sales figure, but none reported the visible expense total; no unsupported profit calculation. |
| Pay-week hours and sales | 4 | 4 | 4 | All supplied the correct values for the same dates, with extra information. |
| Today's business health check | 4 | 1 | 4 | Qwen could not check the requested records; the other two covered the essentials with clutter. |
| Yesterday's sales and sync coverage | 4 | 4 | 4 | All gave correct currency totals and qualified completeness, with extra information. |
| **Ten-question cumulative total** | **36/50** | **33/50** | **39/50** | **LFM leads Qwen by 3 points on these ten; the last three are pending.** |

These are single runs on one synthetic fixture, rated by one partially masked reviewer. The first five decisions were frozen and their labels opened before the second batch was masked; per-question label randomization continued, but reviewer exposure limits blindness. The second-batch masked inputs SHA-256 is `c9d1c6c44d60624f227fb9d601f2f77949cc5c791e7e0886fd7704e627062b2d`; decisions SHA-256 is `085376f497a427835bb8bb70a0dac4e68a52a3d8c4784c5cc3610c8f1d80931f`.
