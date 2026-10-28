# LFM period-review replay — 2026-10-28

Three earlier synthetic questions were replayed once with the same frozen fixture and references using the period-comparison change (`de8d1987`). The comparison is targeted and reuses questions already reviewed, so it is not a holdout or a general model ranking. Full synthetic answers are retained locally under `models-lfm3/benchmark-evidence/period-replay-20261028/`.

| Question | Previous answer | Replay |
|---|---|---|
| Current quarter vs prior quarter | Current totals, but omitted the available USD comparison | Current and prior totals, recorded 227.5% USD change, and explicit missing CAD comparison |
| Last week vs prior week | Current total; comparison not explained specifically | Current total and missing prior rows, with an unnecessary offer to look up more |
| Last month vs prior month | Current total; comparison not explained specifically | Missing prior rows stated, but model prose also contradictorily claimed the tool reported a change |

The quarter and missing-comparison evidence reached the answer, but the contradictory monthly prose was a regression. A subsequent change forces period-review answers through the deterministic evidence renderer; focused tests cover the contradiction. That subsequent change requires a fresh model replay before claiming the overall fix is validated. No hosted grader was used.
