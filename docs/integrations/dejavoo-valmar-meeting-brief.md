# Dejavoo + Valmar meeting brief

For Rupert's developer, ahead of the introduction Valmar made to Dejavoo on 2026-11-02.
Research details, sources and the gap list are in [dejavoo-spin.md](dejavoo-spin.md).
Keep merchant IDs, TPNs, auth keys, statements and the store's product approvals out
of this public repository.

## Our position in one paragraph

Rupert wants to drive the store's Dejavoo terminal from its register through **SPIn
REST in cloud mode** (semi-integrated). The terminal reads the card; Rupert sends the
amount and gets back approval, brand, last four and auth code, never the card number.
A sandbox adapter is already written and tested against Dejavoo's public docs. We need
a sandbox account, a UAT terminal and TPN, and clear certification steps. Valmar must
confirm the account is underwritten for hemp/CBD on the network the TPN is boarded to.

## Ask Dejavoo

1. **API choice.** Is SPIn REST (cloud) the right integration for a web-based POS? Is
   there a LAN/local mode, and does SPIn USB matter for us? Anything replacing SPIn soon?
2. **Hosts and credentials.** Confirm the sandbox host (`test.spinpos.net/spin`) and
   production host (`api.spinpos.net`). REST marks `RegisterId` obsolete but the portal
   says to copy the Register ID. Which do we send? What is `SPInToken`?
3. **Sandbox access.** An iPOSpays UAT merchant, a **UAT terminal** (loaner or
   purchase?) and a TPN with SPIn enabled. Developer portal access for us.
4. **Certification.** Is there an ISV certification or integration review for SPIn?
   What test script, who signs off, how long it takes, any fee. Do we need an `IsvId`?
   Who holds EMV certification (the terminal app, we assume)?
5. **Terminal models.** Which models support SPIn cloud today: P line (P1–P18), QD
   line, Z line? Which do you recommend for a counter and for pop-up events (battery,
   Wi-Fi/LTE)?
6. **Behaviour we must handle.** Is `Amount` the total before or after `TipAmount`? Can
   we turn off the terminal's own tip prompt and surcharge/dual pricing per TPN? Is
   partial approval on by default, and how do we read the approved amount? What does
   `AbortTransaction` do? Is a `ReferenceId` enough to make a retry safe?
7. **Callbacks.** The `CallbackInfo.Url` payload, retries and signing. Or should we
   poll `Status`? Any rate limits?
8. **Offline and batches.** Can the terminal store and forward when the cloud is
   down? Does the batch auto-close, and at what time? Is there an API for closed-batch
   reports by TPN?
9. **Hemp/CBD.** Any Dejavoo or iPOSpays restriction on hemp/CBD merchants or MCCs?

## Ask Valmar

1. **Underwriting.** Is the merchant account approved for hemp/CBD **on the network and
   sponsor bank the Dejavoo TPN will use** (TSYS, Fiserv, other)? Please confirm it in
   writing. Card networks only accept products inside the federal hemp definition.
2. **Approved product list.** Which products or categories did underwriting approve?
   Rupert enforces that list per processor: anything not on it cannot be run on the
   terminal. Send it in a form we can load (SKUs or categories).
3. **The federal hemp change.** From **12 November 2026** (non-naturally-produced
   cannabinoids) and **11 December 2026** (total-THC and per-container limits) some
   current products leave the hemp definition. Will you re-underwrite before 11 December?
   What documents do you need (COAs, labels, a revised product list)? Is there a risk
   of termination or a reserve change?
4. **Integration approval.** Do you need to approve or certify Rupert as an integrated
   POS? Is there a partner agreement? Is Dejavoo's certified terminal app enough?
5. **Timeline and fees.** Terminal cost or lease, per-terminal fees, gateway or SPIn
   fees, surcharge or dual-pricing setup (we want it off unless agreed), batch time,
   funding timing.
6. **Test terminal.** Can you issue a UAT TPN and terminal, or must it come from Dejavoo?
7. **PCI.** Which self-assessment (SAQ) applies with SPIn cloud? Any scan or portal
   requirement?
8. **Reporting.** Will the existing reporting portal (deposits, batches) show Dejavoo
   batches? Any API access for reconciliation?
9. **Events.** Is a second terminal or TPN for pop-up events allowed under the same
   account and location rules?

## Rupert summary to share

> **Rupert** is the store's own point-of-sale and back-office system. It runs the
> register, a customer-facing display, inventory (synced with the store's C-Trax
> catalog), online orders, staff timesheets and bookkeeping. It is a web app hosted on
> the business's own server.
>
> **Payments today:** cash, and Authorize.net / NMI card gateways (sandbox and
> production, behind processor approval). Card data is collected only in the gateway's
> hosted fields; Rupert never sees or stores a card number.
>
> **Compliance controls:** each processor has an approved product list, and Rupert
> blocks any item not on it before a card is charged (the cashier is offered cash
> instead). Products also carry certificates of analysis, card-eligibility and THC
> data, with ID checks and audited manager overrides. Event (pop-up) sales use the same
> approved list.
>
> **Dejavoo plan:** semi-integrated SPIn REST, cloud mode. Rupert sends sale, void,
> return and status requests with a unique reference per attempt, never retries blindly
> after a timeout (it asks for the status first), and reconciles batches against its
> own sales. A sandbox adapter is built and tested; we need a UAT terminal to run it
> live.

## What the store owner needs to provide

- Permission for Dejavoo/Valmar to give the developer iPOSpays sandbox and portal access.
- The written hemp/CBD approval and the approved product list from Valmar (kept
  privately, entered in Rupert under Processor-approved products).
- A decision on tips (terminal or Rupert's customer display) and surcharging (off, or
  priced into Rupert).
