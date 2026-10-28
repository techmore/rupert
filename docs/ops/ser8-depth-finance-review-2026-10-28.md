# SER8 depth review: finance questions

The independent masked review scored 29 of 35 synthetic-fixture finance questions. Six were excluded for all models: f06 exceeded the reference capture limit; f23, f26, f32, f33 and f34 had references that did not establish the requested physical-store or source scope. The reviewer used frozen references and expectations, not model-generated grades. Decisions were recorded before revealing the shuffled model mapping (SHA-256 `dceac647c87c755d4559a8b681d05d11ffdd208b1c0fd8170244d2e21fd7b587`).

| Model and server | Points / 145 | Correctness / 58 | Complete coverage / 29 | Relevance / 29 |
| --- | ---: | ---: | ---: | ---: |
| Qwen with earlier server | 110 | 45 | 17 | 20 |
| LFM with adjusted server | 103 | 43 | 17 | 14 |
| DeepSeek with earlier server | 99 | 44 | 18 | 8 |

Together with the 21 general questions, these scores are Qwen 191/250, LFM 189/250 and DeepSeek 175/250, before the cross-domain review. Scores depend on the rubric and individual judgment. This is a reused synthetic fixture with one run per model, different server snapshots and a reviewer who had seen earlier results. The comparison is masked, not fully blind, and does not establish a general ranking.

The strongest repeated issue is relevance: useful facts are buried in unrelated tool outputs. Other gaps include failure to identify refunded-order counts, directly answer whether a month is locked, distinguish a weekday aggregate from a single day, or explain unavailable pending card deposits. A later server change preserves refunded counts with their order-date scope; it is unit- and integration-tested but was not included in this comparison and needs a model replay.

Each 35-answer export was selected by the exact completion-log run key. All 34 answers present in each reference log matched their corresponding full export; the remaining over-limit reference was excluded rather than silently dropping its answer.
