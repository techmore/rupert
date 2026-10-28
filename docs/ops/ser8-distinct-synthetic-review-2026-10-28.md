# SER8 altered-fixture response review — 2026-10-28

Eight questions used an altered copy of a previously used synthetic fixture, with added paid orders in USD and CAD and one partial refund. The frozen references reproduced on another copy before inference. The application snapshot matched `b3a54d7a` for tracked runtime files, with an isolated review question file added. DeepSeek received synthetic data only. These are not real-business results, independent data distributions, or a general model ranking.

One response per model was scored manually on a 1–5 scale, with identities shuffled separately for each question. The reviewer had seen earlier benchmark work. Scores were frozen before the key was opened; the decision file SHA-256 is `0f74aa1625a8a77263a636a342e59fc10421e4f6545831a753609d3298783d89`. The Qwen3.8 2B distillation trial used a 30-second question limit, compared with 120 seconds for the others. None of its eight questions timed out. Its trial route retained Qwen's server tooling but identified the actual model in the request.

| Question | LFM3 1.7B | DeepSeek V4.1 Flash | Qwen3.8 2B distillation |
| --- | ---: | ---: | ---: |
| Sales by source | 4 | 4 | 1 |
| Compare two days | 5 | 5 | 1 |
| Refund transactions | 1 | 4 | 1 |
| Adjustable daily chart | 2 | 5 | 1 |
| Top products | 1 | 2 | 1 |
| Processor deposits | 1 | 1 | 1 |
| Refunded-order status | 1 | 1 | 2 |
| Net profit limitations | 2 | 3 | 2 |
| **Total / 40** | **17** | **25** | **10** |

LFM answered the source and daily comparison questions accurately but used an unrelated date for the refund metric, did not create the requested daily view, and omitted the requested product leaders. All three responses to the processor-deposit question missed the limitation; one asserted unsupported processing status. The Qwen3.8 2B trial used no tools on seven questions, so its low score does not establish what it could achieve with a different tool-calling integration. Median end-to-end answer times were 20.1 seconds for LFM, 12.0 seconds for DeepSeek and 13.8 seconds for the 2B distillation; the hosted backend differs from local inference and these are not controlled throughput measurements.

The view review checked the actual rows and labels, not just whether a chart existed. DeepSeek's view correctly used separate currencies and blank missing values. LFM produced no view for the explicit-date daily request in this snapshot.

Qwen3.5 4B later completed the same eight questions against the same cohort and application snapshot. Its responses were reviewed after the three-model key had been opened, so this additional assessment was **not blind**. All eight reference checks matched; its median time was 27.2 seconds. Using the same 1–5 rubric:

| Question | Qwen3.5 4B | Main finding |
| --- | ---: | --- |
| Sales by source | 1 | Used the wrong date range and omitted the requested source breakdown. |
| Compare two days | 5 | Correct amounts and changes by currency. |
| Refund transactions | 5 | Correct amount, count, rate and refund-date caveat. |
| Adjustable daily chart | 3 | Correct daily rows and missing-data caveat, but no adjustable view was retained. |
| Top products | 2 | Correct CAD product, but omitted the USD leader. |
| Processor deposits | 4 | Correctly stated the amount could not be established and suggested checking bank statements. |
| Refunded-order status | 1 | Returned paid-order sales instead of refunded-status counts. |
| Net profit limitations | 2 | Avoided guessing but did not explain the profit-specific limitation. |
| **Total / 40** | **23** | One run on an altered synthetic fixture; not a general ranking. |

On this run LFM's 17/40 did not beat Qwen3.5's 23/40. Subsequent fixes for explicit-date charts, metric retrieval, refunded-order status and received-deposit limitations are not included in these results. A replay of the tuned cases is queued; a fresh independent comparison is still needed to measure improvement without using these questions as held-out evidence.
