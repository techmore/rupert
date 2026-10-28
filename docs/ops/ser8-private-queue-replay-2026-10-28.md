# Local real-data queue replay, 2026-10-28

Three queue questions were run as the same authorized requester against independent copies of the same private database snapshot, anchored at 09:50 America/New_York. The baseline application matches the earlier 5bb821fa runtime; the candidate includes c2254878. LFM3 and Qwen ran locally. The captured business references and full answers remain in the private test container; no hosted model received the real data. The source data and production app were not modified. Each model/version ran once; this is not a representative sample or a controlled latency test.

| Model | Request | Baseline | Candidate |
|---|---|---|---|
| LFM | Receipt review count | Queue count matched; 5 tool calls, 5,477 characters | Queue count matched; 1 tool call, 170 characters |
| LFM | Reconciliation follow-ups | Queue count matched; 2 tool calls, 3,123 characters | Queue count matched; 1 tool call, 168 characters |
| LFM | Late purchase orders | Used purchase-order lookup; reported no results on its returned page; not judged against a full-population reference | Queue count and late count matched; 1 tool call, 176 characters |
| Qwen | Receipt review count | Queue count matched; 1 tool call, 1,229 characters | Queue count matched; 1 tool call, 170 characters |
| Qwen | Reconciliation follow-ups | Queue count matched; 1 tool call, 1,229 characters | Queue count matched; 1 tool call, 168 characters |
| Qwen | Late purchase orders | Used purchase-order lookup; reported no results on its returned page; not judged against a full-population reference | Queue count and late count matched; 1 tool call, 176 characters |

The four copies returned identical queue references. Matching was checked mechanically against the requested named queue and the count; the purchase-order candidate was also checked against the late count. The literal count check is narrower than a full independent answer audit. A purchase-order page result is not automatically a failed lookup or a complete global count, so the baseline page answers were not scored as wrong. Tool counts are distinct tool names as recorded by the application, not necessarily the number of calls.
