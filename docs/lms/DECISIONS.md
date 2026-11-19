# Learning center: decisions

Recorded 2026-11-06 while building the first course. Each is a call the owner can reverse.

1. **A new `Lms::` namespace beside the existing pieces, not inside them.** Rupert already has *Learn Rupert*
   (`LearningCatalog`, code-defined lessons about Rupert itself) and *Training* (`TrainingModule`, owner-typed
   text with files and work-item assignments). Neither is lessons → quizzes as editable data with per-lesson
   progress, and both are in active use. The Learning center is the "Training as its own section" direction in
   `docs/ui-standards.md` §13; folding Learn Rupert into it is a later step.
2. **Permissions reuse `hr.read` / `hr.write`.** No new permission strings, so the role matrix (a shared file)
   is untouched. Learners need nothing; team completion matches the existing Training progress rule.
3. **One nav entry, in Me.** "Learning center" sits beside Learn Rupert. Team completion and Manage courses are
   reached from its `More` menu, not from the rail, per the single-entry coordination rule.
4. **Pass = every answer right, unlimited retries, attempts kept.** Same rule as Learn Rupert's knowledge
   checks; keeps the quiz quick and the completion meaningful. A lesson with no questions passes on reading.
5. **Progress saves on every view and answer, server side.** No client-side state to lose; works in the
   iOS app (Hotwire Native) and without JavaScript. The definition popover and the editor helpers are the only
   JavaScript, and both degrade (the "Words in this lesson" fold lists every definition).
6. **Diagrams are HTML, not SVG images.** They reflow at 375px, read aloud, print, and recolour per appearance
   from tokens. The only inline styles are data-driven widths on the fee bar, which the UI standards allow.
7. **Lesson text format is deliberately tiny.** No Markdown gem is in the bundle; `Lms::Markup` covers what a
   lesson needs and escapes everything, so an owner can edit in a textarea without a security review.
8. **Seeder never overwrites an edited course.** The owner's edits win over a new shipped version; the course
   list shows "Edited by you" vs "Shipped with Rupert" so the trade-off is visible.
9. **Support contacts are configuration.** Lesson 8 renders `{{contacts}}` from an encrypted setting with
   public company numbers as defaults, so phone numbers are never baked into content.
10. **In-store vs online gateways are taught as they are built.** The P18 talks to Dejavoo's cloud (SPIn);
    Authorize.net is the gateway for online checkout. The course does not claim the terminal is boarded on
    Authorize.net; that is an open question for Valmar.
11. **Square is described as the previous card provider.** The repo (`PosProviderCatalog`, `PosCheckout::TENDERS`)
    shows no card tender through Square today; Square remains the catalog/orders/loyalty/timecard sync.
12. **Figures that depend on the Valmar contract are not guessed.** Markup, monthly fees, pricing model,
    chargeback fee, batch time and funding days say "check the statement" and are listed in OPEN-QUESTIONS.md.
