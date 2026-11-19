# Learning center: open questions for the owner

Answers go into the course (edit the lesson in **Manage courses**) or into **Support contacts**.

## Valmar / contract

1. **Pricing model and markup.** Interchange-plus, tiered or flat? What is our markup (percent + per item),
   monthly fee, statement fee, PCI fee, batch fee? Lesson 3 says "check the statement"; a worked example from a
   real statement (with the MID removed) would make it concrete.
2. **Chargeback fee** charged by our processor (the course says "commonly $15–$40").
3. **Funding timing** we actually see (the course says "one to three business days"; Authorize.net's own
   figure for its merchants is two to three).
4. **Reserve.** Is any rolling reserve held on the account, and how much?
5. **Which SAQ applies** to us for the P18 (P2PE vs B-IP) and for online checkout (A vs A-EP). Lesson 7 says
   "a short one, provided the hardware is on the PCI-listed encryption list".
6. **Account representative** name and direct line, and Valmar's support hours → Support contacts.

## Terminal and gateway

7. **Is the P18 boarded through Authorize.net or straight to the processor front end?** The repo's Dejavoo work
   uses SPIn cloud; `docs/integrations/dejavoo-valmar-meeting-brief.md` names a P1. Lesson 2 teaches Dejavoo's
   cloud for the counter and Authorize.net for online. Confirm the model (P18 vs P1) and the path.
8. **Terminal batch auto-close time**, and whether tips are prompted on the terminal screen or confirmed on
   Rupert's customer display (lesson 4 describes both; the brief lists this as an undecided item).
9. **Authorize.net transaction cut-off** on our account (default 4:00 PM Pacific; one Authorize.net help page
   says 3:00 PM).
10. **Dejavoo support number** for the store (left blank by default; Valmar first).

## Rupert

11. **Any Square reader still in use for sales?** Lesson 2 says cards do not run through Square today.
12. **Home location for accounts.** Assignment rules carry a `location_id` but accounts have no home location,
    so location rules reach nobody. If per-store courses are wanted, decide where a person's location lives
    (employee record? scheduled shifts?) and `Lms::Audience.location_ids_for` can read it.
13. **Who should be required.** The shipped rule requires managers within 30 days and offers the course to
    admins and shift leaders. Cashiers could reasonably be required for lessons 5–8 only; the model is
    per-course today, not per-lesson.
14. **Spanish course content.** UI strings are translated (`lms.es.yml`); the lessons are English. A Spanish
    course is a second YAML file with `locale: es` once the English content is signed off.
