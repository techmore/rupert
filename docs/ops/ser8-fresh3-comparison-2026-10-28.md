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

## Remaining four and complete result

| Question | LFM | Qwen 3.5 4B | DeepSeek | Observation |
|---|---:|---:|---:|---|
| Uploaded bank lines awaiting a decision | 1 | 1 | 1 | None reported the matching bank-line row; the local models inferred status from the uploads inbox. |
| Sync completeness | 4 | 3 | 3 | LFM reported the empty source tracking and the completeness limitation; the others had evidence or qualification gaps. |
| Processor payouts in transit | 5 | 5 | 5 | All correctly stated that pending payouts could not be established. |
| Receipt count and Drive retention | 5 | 5 | 5 | All reported the recorded count and retention status separately. |
| **Total, nine questions** | **33/45** | **31/45** | **31/45** | **LFM leads by two points in this targeted synthetic run.** |

This is one run per model and one partially masked self-review. The first five labels were opened before the final four were reviewed, and the model-independent receipt response was identical. Scores reflect the same server-side tooling, and small differences do not establish a general ranking. The bank-line question identified a correctness gap across all models; the corrected path and later replays do not alter this frozen score. Final-four masked-input SHA-256 `9a4a5f6feab1b7fbe94e531727670876ba4df2359e98707232682135b7ae71b4`; decisions SHA-256 `fdce7a672e1b9919e32161c86c4c8197c0de6b21b81751a605a3fbc8f2638aa8`.

## Targeted product-leader replay

After the product-leader handling change, a live LFM replay of the known synthetic question gave both product rankings and amounts for both currencies, while still appending unrelated source information. It completed in 9.1 seconds. This replay is not an independent new score; evidence is under `models-lfm3/benchmark-evidence/product-leader-replay-20261028`.
