# Local private-snapshot handoff checks

LFM3 and Qwen each answered two questions against separate copies of the same previously captured private database snapshot using server snapshot `c4647437`, anchored at 09:50 America/New_York. Both models ran locally on the SER8. Full answers, detailed references and business records remain inside the private test container; no hosted model received the business data. The source snapshot and production application were not modified.

| Check | LFM | Qwen |
| --- | --- | --- |
| Month-close period and lock state matched the returned checklist | Matched | Matched |
| Refunded-order counts, order-date window and date distinction matched the lookup | Matched | Matched |

These checks mechanically compare selected claims with the recorded tool data; they do not grade every sentence or establish complete source coverage. Each model answered each question once. The checks use the existing private snapshot and question wordings, so they do not establish a general ranking or replace a fresh-data audit.
