# Combined-runtime masked answer review — 2026-10-28

Ten questions were randomly selected before the run from the existing core, finance and cross-tool batteries, excluding the preceding two random samples. One source-specific tax question was excluded for all models before reviewing any answers: its aggregate reference cannot establish online and Square scope. The remaining nine ran once per model against the same synthetic fixture and combined server runtime `39af99c3`. The fixture and questions were already available and could have appeared in earlier work. The references are Rupert tool outputs, not independent ground truth.

I scored answers against the frozen references, without model-generated grades. Model names were randomized independently for each question and revealed after the decision file was saved. I had seen related questions and run progress, so the review is masked, not fully blind. The fixed rubric awards correctness 0–2 and coverage, grounding and relevance 0–1 each. Decision SHA-256: `4cafb1cde4c1dc7a916238552dd6159fd335c6ce250975d04f852a2ae1ad03c3`.

| Question | LFM | Qwen | DeepSeek | Main observation |
|---|---:|---:|---:|---|
| This quarter vs prior quarter | 3 | 3 | 5 | All reported current totals; DeepSeek included the recorded USD change. |
| Last week vs prior week | 3 | 0 | 4 | Qwen made no lookup; DeepSeek identified missing comparison rows but included extra detail. |
| Late or waiting purchase orders | 4 | 4 | 4 | LFM and Qwen gave queue counts with unrelated queues; DeepSeek gave page-limited results. |
| Last month vs prior month | 3 | 0 | 4 | Qwen made no lookup; DeepSeek identified missing comparison rows but included extra detail. |
| Last month's profit margin | 4 | 2 | 4 | None invented a margin; Qwen made no lookup and gave only a generic inability. |
| Sales today | 4 | 5 | 4 | All preserved the distinction between missing rows and zero sales; LFM and DeepSeek added prior-day detail. |
| Best product's revenue share | 2 | 3 | 2 | All named Tea but omitted its recorded 100% share. |
| Overdue inventory tasks and current stock | 4 | 3 | 5 | Qwen reported an alert without establishing current stock; others noted unknown inventory. |
| Last month's sales vs expenses | 3 | 4 | 3 | All gave sales and missing expense rows; none explained the currency limitation explicitly. |
| **Mean out of 5** | **3.33** | **2.67** | **3.89** | Nine questions; one answer per model per question. |

The result favors LFM over Qwen in this small sample under this rubric, but does not establish a general advantage. DeepSeek scored higher here; it generated answers only, and did not grade them. Other defensible weighting can change the ordering, and prior reviews used different questions and server revisions, so their means are not a controlled before/after comparison. Detailed synthetic answers, references, frozen selection and masked decisions are retained locally under `models-lfm3/benchmark-evidence/independent-final-20261028/`.
