# Learning center (LMS)

The Learning center is Rupert's course player and the data model behind it. **Me → Learning center**
(`/learning-center`) for every signed-in account, including staff in their own shell; **Team completion**
(`/learning-center/team`, `hr.read`); **Manage courses** (`/learning-center/admin/courses`, `hr.write`).
The first course is *How our card payments work* (`web/db/seeds/lms/how_our_card_payments_work.yml`).

## Shape

```
Lms::Course ──< Lms::Lesson ──< Lms::Question
    │                │
    ├──< Lms::GlossaryTerm        [[key]] in lesson text → tap-to-define
    ├──< Lms::AssignmentRule      "everyone with role X takes this" (required, due within N days)
    └──< Lms::Enrollment ──< Lms::LessonProgress ──< Lms::QuizAttempt (append-only)
```

- **Content is data.** Courses, lessons, quiz questions and glossary live in `lms_*` tables per workspace and
  are editable by anyone with `hr.write`. Diagrams are view partials (`web/app/views/lms/diagrams/`) referenced
  by key, so a course can show a picture without an image upload.
- **Seeded, not hard-coded.** `Lms::Seeder` loads every `web/db/seeds/lms/*.yml` into a workspace the first
  time anyone opens the Learning center there (and from `bin/rails lms:seed`). Bump `version` in the file to
  update lessons in place (matched by slug, so progress survives). A course that someone has edited in the app
  (`edited_at`) is never overwritten. Default assignment rules are written only on first load.
- **Assignment** is lazy and idempotent (`Lms::Enroller`): rules are applied when a person opens the Learning
  center and when a rule is added; managers can also assign named people with a due date. Re-assigning only
  ever tightens (required, earlier due date). Location-scoped rules are modelled but match nobody until
  accounts have a home location (see OPEN-QUESTIONS.md).
- **Progress** (`Lms::Progress`): viewing a lesson starts the course; passing its quiz (every answer right)
  passes the lesson; passing every lesson completes the course and awards the badge. Every graded attempt is
  kept. Writes take a row lock on the enrollment.
- **Lesson text** is a small safe format rendered by `Lms::Markup` (headings, lists, bold, callouts, tables,
  step cards, `[[term]]`, `{{diagram:key}}`, `{{contacts}}`). Every character of content is HTML-escaped.
- **Support contacts** shown in the "When things break" lesson come from workspace settings
  (`Lms::SupportContacts`, encrypted `Setting` row `lms.support_contacts`), not from lesson text.
- **Strings**: UI chrome in `config/locales/lms.en.yml` with a Spanish `lms.es.yml`; a course carries `locale`.

## Adding a course

1. Copy `web/db/seeds/lms/how_our_card_payments_work.yml`, change `key`, `slug`, `title`, lessons, quiz,
   glossary and `assign` rules. Keep lessons at 300–600 words and 2–4 quiz questions.
2. Run `cd web && bin/rails lms:seed` (or just open the Learning center; it seeds itself).
3. Quiz answers are 0-based indexes into `choices`. A lesson with no `quiz` passes when marked as read.
4. Verify with `bin/rails test test/services/lms test/integration/lms_flow_test.rb`; the markup test renders
   every shipped lesson and checks that every `[[term]]` and `{{diagram}}` exists.

## Tests

`web/test/services/lms/*` (markup, grader, progress, enroller, seeder) and `web/test/integration/lms_flow_test.rb`
(learner flow, badge, staff shell, team permissions, admin editing, tenant isolation, drafts).

## Files

| Area | Where |
| --- | --- |
| Models | `web/app/models/lms/*.rb`, `web/app/models/lms.rb` |
| Services | `web/app/services/lms/*.rb` |
| Controllers | `web/app/controllers/lms/**` |
| Views | `web/app/views/lms/**` (`diagrams/` holds the figures) |
| Styles | `web/app/assets/tailwind/application.css`, block "Learning center (LMS)" |
| JavaScript | `lms_term_controller.js` (definition popover), `lms_editor_controller.js` (lesson editor) |
| Routes | `scope path: 'learning-center', module: 'lms'` in `web/config/routes.rb` |
| Navigation | `learning_center` entry in `ModuleRegistry` (section Me); staff shell link in `layouts/employee` |
| Migration | `web/db/migrate/20261106120000_create_lms.rb` (additive) |
