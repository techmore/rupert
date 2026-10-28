# Local real-data retention replay — 2026-10-28

Two phrasings of a Google Drive document-retention status question were replayed as the same authorized requester against independent copies of the same private database snapshot, anchored at 09:50 America/New_York. Both models ran locally. Business records and full answers remain in the private test container; no hosted model received them. The baseline runtime includes the order-count change; the candidate is `4731a14c`. Production data and the running application were not modified.

| Model | Before: literal reference detail found | After: recorded status and detail matched | Candidate tool names |
|---|---:|---:|---|
| LFM, wording 1 | No | Yes | compliance_check |
| LFM, wording 2 | No | Yes | compliance_check |
| Qwen, wording 1 | No | Yes | compliance_check |
| Qwen, wording 2 | No | Yes | compliance_check |

The four copies returned identical reference records. The baseline check searched for the captured detail literally and is conservative: a paraphrase can fail that check even if it is correct. The candidate check compared both the recorded status and detail. There was one run per model and wording, so this is not representative of other retention states or a controlled latency measurement. Tests separately cover healthy status, missing records, truncated output, permissions, mixed questions, all-tools mode and preventing unverified streaming text.
