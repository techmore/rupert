# Independent answer review, 2026-10-28

The frozen 11-question synthetic set used server-side runtime commit `70d8f76b`, the same fixture and references for all models. Wording was new, but the questions were paraphrased from previously inspected cases; I had seen related answers and one LFM failure before scoring. The answers were shuffled per question and model labels withheld until all decisions were saved, so this is masked rather than fully blind. DeepSeek generated its own answers; it did not grade any answers. The source reference is Rupert’s own lookup on the fixture, not independent ground truth.

Rubric: correctness 0–2; coverage, grounding, and relevance each 0–1. Decision SHA-256: `f5f5f89b30c5d22daa05156e4bd5c0399861f8042e5f06ec100c4b3013b51729`.

| Question | LFM | Qwen | DeepSeek | Evidence |
|---|---:|---:|---:|---|
| Can you check inventory for the 500mg oil? | 5 | 5 | 4 | Correctly reports unknown inventory; irrelevant alerts lose relevance. |
| Which purchase orders are overdue? | 4 | 5 | 4 | Reports the overdue page or zero late count; unrelated PO and queue detail loses relevance. |
| Check whether any Calm Gummies are in stock. | 5 | 5 | 4 | Correctly reports unknown inventory; unrelated alerts and sync material lose relevance. |
| What inventory is recorded for the tea shelf? | 4 | 1 | 5 | Inventory lookup establishes unknown availability; no lookup and unnecessary clarification fail coverage and grounding. The failed completion and extra material lose relevance. |
| How many orders were recorded yesterday? | 4 | 4 | 4 | Correct counts by currency; unrequested previous-period comparison loses relevance. |
| How many hours did the team actually work this month? | 4 | 4 | 4 | Correct worked hours; unrelated sales and extra period lose relevance. |
| What portion of sales came from each source this month? | 4 | 4 | 4 | Correct source shares; previous-period and extra source detail lose relevance. |
| Compare order counts today with this date last year. | 4 | 5 | 4 | Correctly distinguishes missing periods from zero; unrelated extra periods or operational data lose relevance. |
| How many paid orders are waiting to ship? | 4 | 4 | 4 | Correct paid online order count; unrelated processing queues lose relevance. |
| Are reconciliation follow-ups open? | 0 | 5 | 5 | Correct scoped count when queue was checked; unrelated compliance lookup did not answer the question. |
| What receipts are awaiting review? | 5 | 5 | 5 | Correct receipt count, scoped to available queue evidence. |

| Mean | 3.91 | 4.27 | 4.27 | Out of 5; one run per model. |

LFM missed the reconciliation lookup and produced unrelated compliance details; Qwen did not look up tea inventory and asked for unnecessary clarification. The relevance point penalizes unrelated tool output, so a different defensible weighting can change the ranking. The post-run safety fix for nonzero receipt counts and POS ambiguity is not reflected in this run. A later candidate targets the missed reconciliation lookup and must be evaluated separately.

This small, selected, synthetic sample does not establish a general ranking or prove that LFM has beaten Qwen. It is not a real-data, audio, or production deployment result. Raw synthetic answers, tool calls, references, masked labels and decisions are retained in this directory.
