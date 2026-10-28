# Randomized repository-battery answer review — 2026-10-28

The 12 questions were selected before the runs using a fixed seed: four checked questions each from the existing core, finance, and cross-tool batteries. The same synthetic fixture and `c2254878` runtime were used for LFM3, Qwen and DeepSeek. One question, `finance-f33`, was excluded for every model before inspecting completed answers because its aggregate reference could not establish the requested online-versus-Square scope. The other 11 were scored against frozen tool references. Answers were randomized per question and labels withheld until the decisions were recorded; I had seen related questions and model behavior previously, so this is masked, not fully blind. DeepSeek generated answers only; no model generated the scores.

Scoring: correctness 0–2; coverage, grounding, and relevance 0–1 each. Decisions were saved before the labels were revealed (SHA-256 `87c760d48cd0359acf95c33c05bb5c40cc698292f8907a82b08e2b884bf71f24`).

| Question | LFM | Qwen | DeepSeek | Review |
|---|---:|---:|---:|---|
| Are there any card payments stuck or not resolved? | 4 | 4 | 4 | Correct unresolved-card count; unrelated queues and other output reduce relevance. |
| Is our document retention to Google Drive working? | 1 | 0 | 4 | The Drive retention reference is disconnected. One answer reports it; another checks backup only and asks for clarification; the remaining answer omits the retention row. |
| What is waiting to be processed right now? | 5 | 5 | 5 | Returned the requested queue summary with scoped counts. |
| Which tasks are overdue? | 5 | 5 | 5 | The task lookup returned no overdue tasks and the answer reports none. |
| What were total gross sales last month, by source? | 2 | 4 | 2 | Square gross is 80 USD; a complete answer needs the total and source. Extra periods or unrelated daily-close data reduce relevance. |
| How did last month compare with the month before? | 2 | 2 | 4 | The previous-month comparison is unavailable. The complete answer states the missing August reference as well as September gross; other responses do not establish the asked comparison. |
| Are last month's books closed? What is still open? | 3 | 3 | 3 | Lists the open month-close items and lock status evidence but does not directly answer whether the month is closed; substantial unrelated checks reduce relevance. |
| Which of last month's top-selling products are low on stock right now? | 2 | 5 | 4 | Tea is the top product and current inventory observations are empty; current stock must remain unknown. Alerts alone do not establish current stock or identity. |
| Which source sold the most last week, and is that source syncing correctly? | 4 | 4 | 4 | Correct top source, share and unknown sync status, with substantial unrelated information. |
| Is anything stopping us from closing last month's books, and does any of it involve sales or payments? | 2 | 2 | 2 | Lists relevant source/payment and month-close records but does not clearly relate the payment issue to the requested month-close decision; substantial unrelated data remains. |
| How many hours did the team work last pay week, and how did sales do over the same days? | 4 | 4 | 4 | Correct worked hours and gross sales for the matching pay-week dates; unrelated details reduce relevance. |

| Mean | 3.09 | 3.45 | 3.73 | Out of 5 across 11 comparable cases. |

LFM failed to establish the named Drive document-retention status, the full sales-by-source answer, and current stock for the top product. Qwen also missed the retention status. All three produced substantial unrelated output for several questions, and none clearly connected the month-close issues to the requested payment question. These are independent manual judgments, not ground truth; scores are sensitive to the rubric and to whether an implicit answer is treated as complete.

This was one run per model on a small, stratified sample of existing questions and the same synthetic fixture. Some questions may have been seen during previous tuning, and the references come from Rupert’s own tools. The result does not establish a general ranking, prove that LFM beats Qwen, or measure real-data accuracy. The unrelated source-scope case and any reference failures are retained as exclusions rather than silently scored. Full synthetic answers, frozen references, masked decisions and model runs remain in the local evidence directory.
