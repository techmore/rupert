# SER8 targeted handoff replay

On synthetic data, LFM replayed two previously reviewed finance questions with server snapshot `f547d345`. Both reference checks completed without drift. The refunded-order question reported that no matching orders were returned, distinguished order date and current status from refund transaction date, and did not claim missing sources prove zero. The month-close question identified September 2026 as not locked, listed the recorded open checklist items, and correctly stated that the month could be locked with a note about open items.

This is one replay of two reused questions, not evidence of broad improvement. The separate refund-transaction metric and fresh-question comparison use different snapshots and must be evaluated separately. The first launch of this targeted replay stopped before model inference because its database filename did not satisfy the isolated-runner check; the successful replay used a correctly named isolated synthetic database.
