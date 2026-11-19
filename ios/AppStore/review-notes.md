# App Review information

App Store Connect → version 1.1.0 → App Review Information.

**Sign-in required:** yes. Two accounts: a manager (the review account) and an hourly worker, so
the reviewer sees both sides of the time and pay features.

| Field | Value |
|---|---|
| User name | `appreview@rupertpos.com` |
| Password | (the owner sets it; see owner steps) |
| Contact | the owner's name, phone and email |

**Notes** (paste as is; fill in the worker password where marked):

```
Rupert is back-office software for independent retail shops (sales, inventory, staff, time and pay, bookkeeping). Accounts are created by a business, so we made a demo shop for you: "Juniper & Pine Market", filled with sample data. No real customer or employee data is in it.

TWO LOGINS
- Manager: the user name and password above (Sam Porter, admin of the demo shop).
- Hourly worker: sam.okafor@juniper-pine.example, password: <WORKER PASSWORD>. The worker's clock PIN is 2580.

To sign in: on the first screen, tap "Sign in with email and password", then enter the details. (Google sign-in is for business Google accounts.)

WHAT'S NEW IN 1.1.0: TIME, SCHEDULE AND PAY (the Time tab, first in the tab bar)
As the worker:
1. Time tab → "Clock in" (one tap). The card shows the running time; "Break" / "Meal" and "Clock out" are on the same card. On the shop's register (POS → clock button) the same worker clocks in with PIN 2580.
2. Schedule: next week's published shifts, the team's shifts, and an open Saturday shift with "Pick up".
3. Time off: balances, a request form (pick Vacation / Sick / Personal, dates, send), one approved and one waiting request.
4. Pay: this period's hours, estimated gross, card tips shared with a colleague and declared cash tips, next payday. Estimated vs final is labelled.
5. Timesheets: last week's sheet, submitted for the manager.
As the manager (review account): Home → menu → Team → Approvals shows the worker's waiting request and timesheet with Approve / Deny.

PUSH NOTIFICATIONS
After the first sign-in the app explains what notifications are for and then shows the system prompt ("Turn on"). They cover: schedule posted or changed, a request decided, a shift offered, a forgotten clock-out, a break reminder. Each kind can be switched off in Time → Settings → Notifications. If the server's push key is not yet installed on the review date, the same messages appear in the Notifications tab (the bell), which is the fallback the app is designed around.

OTHER NATIVE FEATURES
- Barcode scanning with the camera (VisionKit): Home → menu → Inventory → Counts → open the draft count → Scan → "Scan with camera".
- Face ID lock: person icon at the top right of a tab's first page → App settings → "Require Face ID".
- Home Screen quick actions: touch and hold the Rupert icon → Clock in, Team Chat, Ask Rupert or Notifications.
- Native tab bar with a separate navigation stack per tab, native sheets for forms, pull to refresh, Google sign-in in the system authentication sheet (ASWebAuthenticationSession).

Ask Rupert (the Ask Rupert tab) is an AI assistant for questions about using Rupert and about the shop's own records. The panel says which AI model writes the answers and that the question and the records it looks up are sent to that service. The demo shop's data is fictional.

Account deletion: person icon on a tab's first page → "Delete account", or the account menu (initials, top right of a page) → "Delete my account". It works for both logins. Please do not delete the review accounts, or the next reviewer cannot sign in.

Subscriptions: the app sells nothing. Businesses subscribe on our website; the app does not show prices, plans or purchase links (guideline 3.1.3(c), enterprise services sold to organizations). Account sign-up is not offered in the app; it signs in accounts a business already has (our own email/password accounts; Google is an alternative sign-in for those same accounts), so Sign in with Apple is not required (4.8).
```

## Owner steps

1. On SER8, run the demo task with both passwords (never printed or stored in Git):

   ```
   REVIEW_PASSWORD='…' REVIEW_WORKER_PASSWORD='…' bin/rails rupert:app_review_demo
   ```

   Add `REVIEW_DEMO_RESET=1` to rebuild the sample data with today's dates before a new review.
   The task is idempotent: running it again refreshes nothing it already made and keeps the
   passwords it is given.
2. Paste the notes above, replacing `<WORKER PASSWORD>`, and type the manager password in the
   User name / Password fields.
3. Check the two logins once in the TestFlight build before pressing Submit for Review.

## When Take payment ships (draft: do not paste before that version)

Add this block to the notes of the version that first contains the **Take payment** button. Fill in
the marked places. Background: `docs/compliance/dejavoo-tap-to-pay-compliance.md`.

```
NEW IN <VERSION>: TAKE PAYMENT (IN-PERSON CARD PAYMENTS FOR PHYSICAL GOODS)
Shops that use Rupert sell physical goods over the counter. This version lets a shop's staff take a contactless card payment for those goods on an iPhone.

How it works: Rupert does not read the card. On the register page the cashier taps Take payment, and Rupert opens the payment provider's own app (iPOSgo! by Dejavoo, which provides Tap to Pay on iPhone). The customer taps their card or phone there. iPOSgo! returns the result (approved or declined, amount, last four digits, approval code) and Rupert's server confirms it with the provider before the sale is marked paid. Rupert never receives the card number.

In-app purchase is not used because these are physical goods consumed outside the app (guideline 3.1.3(e)). The app still sells no digital goods or subscriptions.

HOW TO SEE IT
1. Sign in as the manager (the review account). The demo shop is connected to the provider's test system, so no money moves.
2. Home -> menu -> Register. Add any item, tap Take payment, choose the contactless option.
3. <IF iPOSgo! CAN BE INSTALLED BY THE REVIEWER: say where to get it and which test card or wallet works. IF NOT: say so plainly, and attach a short screen recording of a full test payment on a real iPhone.>
4. The receipt shows the card brand, last four digits and approval code.

The button appears only on iPhone (iPhone XS or later, US region). It is not shown on iPad, where Tap to Pay on iPhone is not supported. It is off for a shop until its administrator turns it on.

Data: the app's privacy label now includes Payment Info and Purchase History. Details are in the privacy policy at https://pos.rupertpos.com/privacy#card-payments.
```

Before pasting:

1. Confirm with Dejavoo how a reviewer can run a test payment (question Q1/Q8 in the compliance doc).
   If the reviewer cannot install iPOSgo!, attach a screen recording: guideline 2.1 asks for a demo
   of every feature.
2. Check the demo shop's catalog still shows no hemp, CBD, vape or THC products.
3. Update the App Privacy label first (checklist item T6), so the notes and the label agree.
