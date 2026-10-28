# Fresh-wording synthetic comparison — first five answers

Nine newly worded questions use the frozen server runtime at `7ab0f07e`, cohort `53fa3d3054b304ea`, and separate copies of a synthetic fixture with five new July orders and one refund. The fixture builds on previous synthetic data, the questions cover familiar task families and some recent fixes, and the reviewer authored them. DeepSeek received synthetic data only. The first five answers were assessed on the same 1–5 rubric with labels shuffled per question; decisions were frozen before the labels were opened. One run and one reviewer are insufficient for a general ranking.

| Question | LFM | Qwen 3.5 4B | DeepSeek | Observation |
|---|---:|---:|---:|---|
| Revenue by source and currency | 4 | 4 | 4 | All reported the correct amounts; each added unrelated details. |
| Adjustable daily chart | 4 | 4 | 4 | All returned correct dates, currency rows and missing values; extra details varied. |
| Refund amount, count and rate | 4 | 5 | 4 | All gave the requested figures and date caveat; two added unrelated details. |
| Order counts by currency | 5 | 3 | 3 | LFM gave both totals directly; the others gave source counts without the requested USD total. |
| Product revenue leaders | 1 | 1 | 2 | None gave both requested leaders; source totals or unrelated product results dominated. |
| **First five total** | **18/25** | **17/25** | **17/25** | **The remaining four questions are pending.** |

The source, refund and product reference figures were checked against the authored synthetic seed. The question set is targeted and small, and scores reflect server behavior as well as model selection. The product failure prompted a later server fix; replays of that known case do not change these frozen scores. Masked input SHA-256 `d06c34cffe03bda352ef28505465dad23fbcb4bb63ca1b3ce46d7eacf620fb15`; frozen decision SHA-256 `94186973d0aa0c9ac5213d13cfc93ed4b526f4d801e445d4a1c79f868484ef5c`. Full synthetic evidence remains under `models-lfm3/benchmark-evidence/fresh3-review-20261028`.
