# Local real-data compliance replay — 2026-10-28

Two compliance questions were replayed as the same authorized requester against independent copies of one private database snapshot, anchored at 09:50 America/New_York. LFM3 and Qwen ran locally. Full answers and business records remain in the private test container; no hosted model received them. The baseline includes the sales-by-source correction; the combined candidate is `39af99c3`. Production data and the running application were not modified.

| Model | Question | Before: literal count matched | After: literal count matched |
|---|---|---|---|
| LFM | Timesheets awaiting approval | Not established | Yes |
| LFM | Bank statement lines | Not established | Yes |
| Qwen | Timesheets awaiting approval | Not established | Yes |
| Qwen | Bank statement lines | Not established | Yes |

All four copies returned identical selected compliance references. The check compared the returned named count with the final answer; it can miss correct paraphrases and does not verify every claim. The bank answer explicitly describes uploaded lines awaiting a decision and does not claim that all decided lines were matched. Each model and question ran once; this is not a representative real-data audit or controlled timing test.

Separate synthetic replays and focused tests covered nonzero and missing counts, withheld permissions, all-tools mode, and mixed timesheet/backup and retention/backup questions. The mixed responses use independently captured evidence for each subject and state when backup freshness is unavailable.
