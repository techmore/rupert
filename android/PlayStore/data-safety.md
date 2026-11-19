# Data safety and content rating answers

## Data safety (Play Console → App content → Data safety)

Google counts what Rupert's server collects through the app, not only the app's own code. The app
itself adds nothing: no analytics, ads, crash reporting or tracking SDKs, and no runtime permissions.
The barcode scanner runs on the phone inside Google Play services and sends no images to Rupert.

**Does your app collect or share any of the required user data types?** Yes.
**Is all of the user data collected by your app encrypted in transit?** Yes (HTTPS only; plain http
only to a server on the person's own device or local network, which they choose).
**Do you provide a way for users to request that their data is deleted?** Yes: in the app (App
settings → Delete account) and on the web at `https://pos.rupertpos.com/account/delete`.

| Category → type | Collected | Shared | Optional? | Purpose |
|---|---|---|---|---|
| Personal info → Name | Yes | No | Required | App functionality, Account management |
| Personal info → Email address | Yes | No | Required | App functionality, Account management |
| Personal info → User IDs | Yes | No | Required | App functionality, Account management |
| Photos and videos → Photos, Videos (attachments) | Yes | No | Optional | App functionality |
| Files and docs (attachments, receipts) | Yes | No | Optional | App functionality |
| Messages → Other in-app messages (Team chat) | Yes | No | Optional | App functionality |
| App activity → Other user-generated content (Ask Rupert questions, business records) | Yes | No | Optional | App functionality |
| App info and performance → Diagnostics (page details sent with Report a problem) | Yes | No | Optional | App functionality |

Collected data is processed ephemerally? **No** (it is stored in the business's Rupert).
Not collected: location, financial info of the person, health, contacts, calendar, audio, web
browsing, installed apps, device or other IDs, crash logs.

## Content rating (IARC questionnaire)

Category: **Reference, News, or Educational**? No: choose **All Other App Types**.

| Question | Answer |
|---|---|
| Violence, fear, sexuality, language, controlled substances, gambling | No |
| Users can interact or exchange content | Yes (private team chat within a business) |
| Shares the user's current location with other users | No |
| Allows purchases of digital goods | No |
| Unrestricted internet access (a browser) | No (only Rupert's own sites; other links open in the browser) |

Merchant catalogs (for example a shop selling vapes or hemp products) can show product names in
the app; if a reviewer asks, the app is a business tool for the shop's own staff, not a store.

## Google Play services (barcode scanner)

The camera scanner is Google's code scanner, which runs inside Google Play services, not in Rupert.
Images stay on the phone. Google's ML Kit documentation says Play services may send Google
diagnostics about the scanner API itself (API usage and performance, no images or codes). Check
Google's current "ML Kit data disclosure" page when filling the form; if it still lists that, add
**App info and performance → Diagnostics** as collected for analytics by a third party (Google) as
the page directs.
