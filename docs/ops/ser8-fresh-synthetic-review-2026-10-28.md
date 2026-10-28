# Fresh synthetic answer review — 2026-10-28

Eight newly worded questions were run once per model against the same frozen application snapshot at `a5c7c3a1` and synthetic reference cohort `13fdc6180db3ee92`. The fixture extends a previously used synthetic database, so this is neither an independent real-data audit nor a broad estimate of general quality. The Qwen comparison is local Qwen 3.5 4B, not the separately tested Qwen 3.8 2B distill. DeepSeek was hosted; only synthetic data was sent.

The reviewer scored randomized, per-question labels on a 1–5 scale (1 materially wrong or unusable; 2 limited; 3 partial; 4 materially correct with clutter or minor issues; 5 complete). Decisions were frozen before opening the model key. This is a partially masked self-review: the reviewer authored the questions, had seen previous related runs, and saw the identities of two answers to the first question before masking. Each answer was checked against the same frozen reference, including actual chart rows. One run and one reviewer are insufficient for confident model-wide rankings.

| Question | LFM | Qwen | DeepSeek | Main observation |
|---|---:|---:|---:|---|
| Seven-day revenue by source | 1 | 2 | 4 | LFM used unrelated months; Qwen used eight days; DeepSeek used the requested seven. |
| Day-over-day sales | 1 | 4 | 4 | LFM used unrelated periods; the others reported requested dates and changes with extra information. |
| Adjustable daily sales chart | 4 | 5 | 4 | All created views with correct rows and missing values; LFM and DeepSeek added unrelated details. |
| Refund transactions | 4 | 5 | 4 | All gave correct currency amounts, counts, rates and date caveat; two added unrelated facts. |
| Product leaders | 4 | 5 | 4 | All gave correct currency-separated product leaders; two added clutter. |
| Latest upload | 5 | 3 | 5 | LFM and DeepSeek reported the empty inbox and uncertainty; Qwen omitted the empty result. |
| Month lock | 3 | 3 | 5 | DeepSeek clearly identified an unlocked month; LFM buried the row, Qwen misstated the warning. |
| Sync completeness | 3 | 4 | 4 | All indicated coverage could not be established, but LFM suggested checks could prove it. |
| **Total** | **25/40** | **31/40** | **34/40** | **LFM did not beat Qwen on this sample.** |

Median per-question elapsed times were LFM 15.0 s, Qwen 28.6 s, and hosted DeepSeek 9.2 s. These include different model and hosting paths and are not a controlled throughput benchmark. All 24 runs completed. Scores include server-side tool and response handling, not just the underlying models.

The first priority is preserving the user's stated date window and comparison when model tool arguments are wrong. The chart and refund results provide encouraging evidence for the recent server changes, but the reused question families and fixture prevent a general improvement claim. Continue with fresh held-out questions, local real-data checks without exporting business data, and an independently assessed larger sample before claiming LFM beats Qwen.

Evidence retained locally under `models-lfm3/benchmark-evidence/fresh2-review-20261028`: masked inputs SHA-256 `4a38105dc433d85d953f5a533676972820784a70455a5d83d3cc2690b1e2bbc1`; frozen decisions SHA-256 `e52d2e3789e239c8fd323ba5ca78662ad813de13ff0070a263e78ea69498ce07`.
