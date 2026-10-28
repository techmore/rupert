# Local real-data sales-by-source replay — 2026-10-28

Two explicit total-and-source questions were replayed as the same authorized requester against independent copies of the same private database snapshot, anchored at 09:50 America/New_York. LFM3 and Qwen ran locally. Full answers and business figures remain in the private test container; no hosted model received them. The baseline runtime includes the retention change; the candidate is `055e887a`. Production data and the running application were not modified.

| Model | Period | Before: literal total and sources matched | After: literal total and sources matched |
|---|---|---|---|
| LFM | Last month | Not established | Yes |
| LFM | Yesterday | Yes | Yes |
| Qwen | Last month | Yes | Yes |
| Qwen | Yesterday | Not established | Yes |

All four copies returned identical currency totals and source values for each period. The check looked for every captured total and source amount in the final answer with the corresponding currency and source label. It is conservative: alternate correct wording can fail, and matching those values does not verify every other claim. One run per model and period is not a representative financial audit or a controlled timing test. The correction preserves explicit source filters and comparison arguments, and the original tool arguments remain in the execution record.
