# Masked side-panel visualization review — 2026-10-28

Four newly authored questions were run once per model on the same frozen synthetic fixture and server runtime `e4a12f38`. LFM3 and Qwen ran locally; DeepSeek generated answers using synthetic data only. I independently reviewed answers and view rows against the tool references. Model labels were shuffled separately for each question and revealed after the decisions were saved. I had seen related results and progress, so this is masked, not fully blind. Rubric SHA-256 `1d67498bc2a6808e7a6094bc250316e940607a11222b659eb61128d8479021a3`; decision SHA-256 `8dec779879eb1d41eb942822afa2900f1b5441cb2b10a88ce57ea1dce22c8023`.

| Question | LFM | Qwen | DeepSeek |
|---|---|---|---|
| Gross sales by source | Adjustable chart, **wrong** source labels, units and fabricated zero | Adjustable chart, correct recorded figures with a confusing scope note and extra missing-source rows | Adjustable chart, correct recorded source figures and currency |
| Daily sales trend | Adjustable table, **wrong**: weekly total assigned to a single day | Adjustable chart, **wrong**: missing-order days plotted as zero | Adjustable chart, **wrong**: missing-order days plotted as zero |
| Month vs previous month | No view; correctly says prior data is unavailable | Adjustable chart, incomplete: period label missing and source note narrower than the evidence | Adjustable chart, **wrong**: missing daily values plotted as zero |
| Open stock alerts | Adjustable table, but answer incorrectly treats alert quantity as current stock | Adjustable table, but answer incorrectly calls alert quantity on-hand stock | Adjustable table, correct alert values and current-stock limitation; staleness could be clearer |

**Do not treat these visualizations as validated factual output.** In the source-sales chart, LFM assigned recorded values to the wrong sources and described dollar values as cents; the numeric check nevertheless reported zero unmatched figures. The daily charts also converted missing-order days into zero. The frontend controls passed separate tests, but a structured, adjustable view and matching numbers do not establish correct labels, units or data provenance. No private database records were sent to DeepSeek.

The later server code preserves missing daily amounts as unknown and has a sign-aware numeric warning; those changes were not included in this baseline. An updated LFM replay is queued against the same synthetic references. Four cases, one answer per model, a reused fixture and subjective qualitative review are not enough to rank models generally. Full synthetic answers, references, model views, blinded mapping and decisions remain in the local evidence directory `models-lfm3/benchmark-evidence/visualization2-20261028/`.
