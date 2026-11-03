# Play review: App access

Play Console → App content → App access → "All or some functionality is restricted" → add
instructions. Use the same fictional demo shop as App Review (`REVIEW_PASSWORD=… bin/rails
rupert:app_review_demo` on the server; see `ios/AppStore/review-notes.md`).

| Field | Value |
|---|---|
| Name | Rupert demo shop |
| Username | the review account's email (from `rupert:app_review_demo`) |
| Password | (the owner sets it) |
| Any other information | paste the notes below |

```
Rupert is back-office software for independent retail shops (sales, inventory, staff, bookkeeping). Accounts are created by a business, so we made a demo shop filled with sample data. No real customer data is in it.

To sign in: on the first screen, tap "Sign in with email and password" and use the username and password above. (Google sign-in is for business Google accounts.)

Native features to try:
1. Barcode scanning with the camera (Google code scanner): Home → menu → Inventory → Counts → open the draft count → Scan → "Scan with camera". The code is saved to the count.
2. App lock: tap the person icon at the top right of the Home tab → App settings → "Require screen lock". Leave and return to the app; it asks for your fingerprint, face or screen lock and hides its pages in recent apps.
3. Launcher shortcuts: long-press the Rupert icon → Team Chat, Ask Rupert, Notifications or Search.
4. Native tab bar with a separate back stack per tab, full-screen forms, pull to refresh, and a server picker (App settings → Rupert server) for businesses that run their own Rupert.

Account deletion: person icon on the Home tab → App settings → "Delete account". Please do not delete the review account.

The app sells nothing. Businesses subscribe on our website; the app shows no prices, plans or purchase links.
```
