# SER8 depth review: first 21 general questions

This is a preliminary independent review of the same 21 synthetic-fixture questions for three model-and-server combinations. It is not a held-out test: these questions and the fixture have been used during tuning. LFM ran on a later Rupert server snapshot than Qwen and DeepSeek, so the comparison measures the complete combinations, not model weights alone. One run and one reviewer cannot establish a general ranking.

The reviewer scored each answer against frozen references and authored expectations, with model labels shuffled independently per question. Scores were recorded before revealing model labels (decisions SHA-256 `17343400e0f743253711c0ecb70ed135632df9acadb16db05ae0b2ebf1cdd473`). The reviewer had seen earlier benchmark material, so this is masked, not fully blind. The rubric awards up to two points for correctness and one each for coverage, grounding and relevance.

| Model and server | Total / 105 | Correctness / 42 | Complete coverage / 21 | Relevant / 21 |
| --- | ---: | ---: | ---: | ---: |
| LFM with adjusted server | 86 | 36 | 16 | 13 |
| Qwen with earlier server | 81 | 33 | 12 | 16 |
| DeepSeek with earlier server | 76 | 33 | 13 | 9 |

LFM leads this small, reused subset, but Qwen is more relevant by this rubric. The remaining 45 questions, visualization replay, and broader test are required before drawing a wider conclusion. DeepSeek generated answers only; no model graded itself. Review and generation used synthetic data.

Recurring gaps were failure to state directly whether a month or quarter is locked, large unrelated tool-result dumps, and incomplete directions for approving timesheets. In one queue answer the relevant oldest order was listed without saying it was oldest. The later server includes a narrower purchase-order queue response, but that change was not part of this LFM run and needs its own replay.

A preliminary export initially selected old runs because multiple runs shared a frozen timestamp. That review was invalidated. Corrected exports identify each run by the exact run key reported in its completion log, and all 21 exported answers per model matched the corresponding reference logs. Finance exports were also verified by exact run key. The evidence and decisions reside in the local benchmark evidence directory; only synthetic material was used.
