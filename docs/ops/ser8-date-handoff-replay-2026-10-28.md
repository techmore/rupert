# SER8 explicit-date handoff replay

LFM replayed two synthetic questions with server snapshot `0e35fe02` and the frozen fresh-question cohort. Both references matched. The week-ending question returned Shopify 60.00 USD and Rupert POS 40.00 USD for the requested week, separately. The consecutive-day question returned the requested daily totals and the recorded USD change, instead of the unrelated monthly period seen in the earlier run.

The second answer warned generically that a missing value was not zero, but did not identify the absent prior CAD value. The later `4220dcc6` change names missing comparison currencies and has focused tests; it was not part of this replay. These two questions guided the date changes, so this is an exploratory regression replay, not a held-out estimate or evidence of a general ranking.
