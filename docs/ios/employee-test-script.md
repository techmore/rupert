# iPhone app: staff shift test script

A script a person follows to check what a staff account (role **employee**) can do in the iPhone
app during a normal shift, and what it must be refused. Run it before a TestFlight build goes to
staff, and after any change to sign-in, the tab bar, the register or permissions.

Use a local Rupert or a demo workspace. **Never run it against a real shop's data, and never with
real payment credentials.** Card steps marked *hardware* need a real reader and are not part of
the simulator run.

The automated version of sections 1, 2, 4, 5 (exact cash) and 8 is `ios/RupertApp/UITests/EmployeeShiftUITests.swift`.
The pages for an unreachable Rupert and a session that ended (sections 8 and 9) are in
`ios/RupertApp/UITests/OfflineAndSessionUITests.swift`. What the server allows each role is tested in `web/test/integration/` (`employee_*`,
`navigation_access_boundaries_test.rb`, `native_app_tabs_test.rb`).

## Set up

1. Start a local Rupert with the fictional demo shop and its made-up test register:

   ```bash
   cd web
   bin/rails db:prepare
   REVIEW_PASSWORD='<a password of 12+ characters>' bin/rails rupert:app_review_demo
   bin/rails server -c test/support/sim_register.ru -b 127.0.0.1 -p 3005
   ```

   The staff account is `sam.okafor@juniper-pine.example` (the review password, clock PIN 2580).
   The owner account is `appreview@rupertpos.com`.

2. `test/support/sim_register.ru` is what gives the demo shop a register (the plain
   `bin/rails server` has none). It adds a store called "Test register" with four made-up
   products at 6% tax, cash turned on and an open register "Front counter", and it answers the
   stock check that checkout makes before payment from that made-up stock, the same way the Rails
   checkout tests do. Nothing is sent anywhere, so a cash sale completes with a receipt. It
   refuses to load outside development. Card is not set up on it. **More → Demo both screens**
   still runs a practice sale that records nothing.

3. Build and run the app pointed at it (see `ios/README.md`, "Build and run on a Mac"):
   `SIMCTL_CHILD_RUPERT_DEV_ORIGIN=http://127.0.0.1:3005 xcrun simctl launch booted com.rupertpos.Rupert`.

## 1. Sign in

| Step | Expect |
|---|---|
| Open the app signed out | The sign-in page ("Sign in to continue."), with no tab bar. The person button (App settings) is at the top. |
| Sign in with a wrong password | "Invalid email or password". Still signed out. |
| Sign in as the staff account | Lands on **My time** ("Hi, …"). |
| Look at the tab bar | **Time** and **Notifications** only. No Home, Team Chat or Ask Rupert. |
| "Stay in the loop" appears | **Not now** closes it and it does not come back on the next page. |
| Go to the Home Screen, press and hold the Rupert icon | **Clock in** and **Notifications**. No Team Chat or Ask Rupert (they appear for an owner after the owner signs in, and go again when staff sign in). |

## 2. Clock and shift (Time tab)

| Step | Expect |
|---|---|
| **Clock in** | The card changes to clocked in, with the start time. |
| Start and end a break (if the shop has breaks on) | The break shows on today's shift. |
| **Clock out** | Clocked out; today's hours update. |
| Schedule, Time off, Pay, Timesheets pills | Each opens. Only this person's own shifts, requests, pay and timesheets. |
| Time off → new request | The request appears as *Requested*. |
| Schedule → **More** → **My availability** | Opens as a sheet with **Cancel** (shown as ✕). Untouched, Cancel closes it. After typing, Cancel or a swipe down asks **Discard Changes**. |
| Timesheets → open a draft → **Submit** | Submitted. There is no Approve button on one's own sheet. |

## 3. Notifications tab

| Step | Expect |
|---|---|
| Open Notifications | The list (or "nothing yet"). Not a refusal. |
| Tap one | Opens its page inside the app. |

## 4. Ring up a sale (Time tab → Open POS)

| Step | Expect |
|---|---|
| **Open POS** | The register: store name, **Register open · …** (or "Register closed. Ask a manager to open a register"), products. |
| Search a product name or SKU | The list narrows; each tile shows price and stock. |
| **Pair customer screen** | "Customer screen paired". The cart starts empty. |
| Tap a product → **Add to cart** | "Added 1 × …"; the cart shows 1 item, the price and the subtotal. |
| Change the quantity, remove a line | The totals follow. There is no price, discount or tax field to type into. |
| **Open customer screen** (hand the phone over, or open the link on a second screen) | "Your cart, your choice": the items, the tip choices. |
| Choose **No tip** → **Confirm my choice** | "Choice confirmed". |
| Back → **Checkout** | Register picker, **Cash**, **Card**, **Card (A920)**, the total with the confirmed tip. |

## 5. Take payment

| Step | Expect |
|---|---|
| Cash: **Exact** (or type the amount) → **Complete cash sale** | On a set-up store: paid, change due, a receipt link. |
| Cash received less than the total | Refused: "Cash received is less than the total." |
| Card on a store without card set up | **Card** is disabled with "Card payments are not set up for this store. Ask a manager to set this up." |
| Card (A920) → **?** | Explains that it only records a card already run on the terminal. |
| *Hardware:* Card on a Dejavoo terminal | The terminal prompts; approved shows paid, declined shows the reason and **Cancel unpaid checkout**. |
| *Hardware:* Tap to Pay on iPhone | Not built into this app yet (see the card reader pull requests). |
| Open the receipt | The receipt page; print or send as the shop has set up. |

## 6. A payment that fails or is cancelled

| Step | Expect |
|---|---|
| Change the staff account's password on the web while the register is open on the phone, then **Complete cash sale** | "You have been signed out. Sign in again, then check Unfinished before taking payment again." Never a browser error such as "The string did not match the expected pattern." |
| Stop the server, then **Complete cash sale** | A message, the button comes back, nothing is recorded twice when the server returns. |
| A checkout left *ready* or *declined* → **Cancel unpaid checkout** | "Unpaid checkout cancelled." The cart can be rung up again. |
| **Unfinished (n)** in the register's top bar | Lists this cashier's own unfinished checkouts only. |

## 7. What staff must be refused

Each of these should send a staff account back to My time with "Your account can use POS, your
own time records and assigned tasks.", or show a plain refusal. Type the address in Safari signed
in as the staff account, or use the web app; the app itself offers no link to them.

| Address | Why |
|---|---|
| `/sales`, `/orders`, `/reports`, `/ledger` | Sales history and reports |
| `/inventory`, `/inventory_counts/new` | Stock management (the register's product list is the only stock view) |
| `/settings`, `/users`, `/permissions`, `/api_access_tokens` | Settings and accounts |
| `/pos_settings/<store>`, `/pos_connections`, `/connections`, `/billing` | Payment configuration |
| `/sales/pos_sessions/new` | Opening or closing a register |
| `/people/timesheets/<someone else's id>` | Other people's time |
| `/chat`, `/ask_rupert` | Administrators only |
| A paid card checkout → refund | No refund button; `POST /pos_checkouts/<id>/reverse` is refused. Ask a manager. |

## 8. Sign out, and the session running out

| Step | Expect |
|---|---|
| Person button → **Sign out** → confirm | The sign-in page with no tab bar, ready for the next person. Signing in again straight away works. |
| Sign in as the owner on the same phone | All five tabs; Team Chat and Ask Rupert open. |
| Sign in as staff again, then change that account's password on the web | On the next page the app says **You've been signed out**, with what to do. **Sign In** leaves the sign-in page, with no tab bar. The same after the app has been closed for longer than Rupert keeps a session. |
| Sign out with the page's own **Sign out** button | The sign-in page, and no "You've been signed out" message. |
| Person button → **Switch workspace** | Signed out and back on the Rupert sign-in page. |
| Sign out while clocked in | Still clocked in after signing back in. |

## 9. Offline or server unreachable

| Step | Expect |
|---|---|
| Airplane mode, then open a tab | "You're offline", with **Try Again**; no blank screen and no "Error loading page". With the shop's Wi-Fi up but Rupert unreachable: "Can't reach Rupert". |
| Airplane mode off | The page loads by itself within a few seconds (or with **Try Again**); still signed in. |
| Airplane mode on My time → **Clock in** | The page says it is offline and keeps the punch to send later (if the shop allows offline punches), or says to try again. |

## Record

Note the build (person button → Version), the device and iOS version, the date, and each row that
did not match. A row that fails in section 7 is a security bug: report it privately (`SECURITY.md`).
