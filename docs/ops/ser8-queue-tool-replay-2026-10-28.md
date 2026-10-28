# SER8 queue tool-selection replay — 2026-10-28

Five synthetic questions were run once per model against the previous queue renderer and the `c2254878` candidate. The candidate offered the authorized queue tool alone for narrow count/yes-no questions and retained the existing tool list for detail and mixed questions. The final question is a replay of the observed LFM failure, not an unseen test. All candidate answers contained the fixture’s requested zero receipt/follow-up counts and, for the mixed request, the correct late-PO count.

| Model | Question | Before seconds | After seconds | Before tools | After tools |
|---|---|---:|---:|---|---|
| LFM | How many expense receipts are awaiting review? | 14.7 | 4.2 | compliance_check, order_queues, metric, list_tasks, search | order_queues |
| LFM | Any reconciliation follow-ups waiting? | 10.9 | 11.0 | order_queues, compliance_check | order_queues |
| LFM | What receipts need review and are any purchase orders late? | 8.9 | 8.0 | order_queues, list_alerts, compliance_check | order_queues, list_alerts, compliance_check |
| LFM | Which expense receipts require review? | 12.8 | 14.1 | compliance_check, order_queues, search, metric, period_review, list_tasks | compliance_check, order_queues, search, metric, period_review, list_tasks |
| LFM | Are reconciliation follow-ups open? | 9.0 | 2.4 | compliance_check | order_queues |
| QWEN | How many expense receipts are awaiting review? | 13.9 | 8.0 | order_queues | order_queues |
| QWEN | Any reconciliation follow-ups waiting? | 12.9 | 5.4 | order_queues | order_queues |
| QWEN | What receipts need review and are any purchase orders late? | 18.7 | 4.0 | order_queues | order_queues |
| QWEN | Which expense receipts require review? | 4.1 | 2.4 | order_queues | order_queues |
| QWEN | Are reconciliation follow-ups open? | 4.4 | 4.8 | order_queues | order_queues |

LFM’s reconciliation failure changed from an unrelated compliance lookup to the queue count. Qwen used the queue tool before and after. These durations are single sequential runs on a shared machine; warmup and other activity could affect them, including on questions whose tool list did not change. They do not establish a general speedup. Tool lists are distinct tool names, not a count of calls.

The candidate was tested for withheld tool permission, all-tools mode, mixed-topic requests, missing counts and nonzero receipt detail requests. The broader 12-question review and private snapshot replay are separate evaluations.
