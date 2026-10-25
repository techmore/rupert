# Encryption at rest: database columns

Rupert stores everything in one SQLite file, and that file is plaintext on disk (#421). Sensitive columns are
protected with Rails Active Record encryption (`encrypts`). AES-256-GCM is keyed by the three
`RAILS_ENCRYPTION_*` variables in `/etc/rupert.env`; see [environment-reference.md](environment-reference.md).
This page lists which columns are encrypted and which stay readable on purpose. It also covers the backfill
that rewrites rows written before a column gained `encrypts`.

Column encryption does not protect a copy of the database that travels with `/etc/rupert.env`, because the
keys are in that file. Backups and host copies are covered in [#421](https://github.com/techmore/rupert/issues/421)
and [backups.md](../module-guides/backups.md).

## Encrypted columns added in #421

| Model (table) | Encrypted | Stays readable, and why |
|---|---|---|
| `TeamChat::Message` (`chat_messages`) | `body` | status, author, room, timestamps and `meta`: polling, threads, pins and run bookkeeping filter on them |
| `TeamChat::Attachment` (`chat_attachments`) | `data` (the file bytes) | `filename`, `content_type`, `byte_size` and the Drive columns: the room's file list and the Drive sweep filter on them |
| `FeedbackAttachment` | `text_body`, `binary_body` | `kind`, `content_type`, `byte_size` |
| `People::PayRate` (`pay_rates`) | `hourly_rate_cents`, `annual_salary_cents` | `pay_type`, `pay_frequency`, `effective_on` and `ended_on`: the current-rate lookup filters on the dates |
| `People::PayRun` (`pay_runs`) | `total_gross_cents`, `total_net_cents`, `notes` | `name`, period, `status`, `paid_on`: lists and 1099 totals filter on them |
| `People::Payslip` (`payslips`) | `hours`, `gross_cents`, `deductions_cents`, `net_cents`, `notes` | employee, pay run and pay rate ids |
| `People::Employee` (`employees`) | `address`, `date_of_birth`, `merge_snapshot` (a copy of the whole profile kept when duplicates are merged) | first, last and legal name, which are searched with SQL `LIKE` (timesheets, the `staff_schedule` tool) and sorted (`Employee.ordered`); employee number (unique); email, phone and emergency contact, which were not in the #421 scope |
| `Finance::TaxPayee` (`tax_payees`) | `tin` (already encrypted), `legal_name`, `business_name`, `tin_last4`, `address_line1`, `address_line2`, `city`, `postal_code` | `payee_key` (unique, matched by equality to expense and vendor payees, which are themselves plaintext), `state`, form and classification fields |
| `Finance::TaxFormFiling` (`tax_form_filings`) | `legal_name`, `tin_last4` | `paid_cents`, year, form and kind |

All of these columns use non-deterministic encryption, because none is looked up by equality.

Columns that were already encrypted before #421 are not listed here. They include upload bytes and parsed
JSON, import and reconciliation documents, Zelle, Authorize.net and SwipeSimple files, connection tokens,
settings and marketing bodies; grep `encrypts` under `web/app`. The backfill and status check below cover them too.

## What stays plaintext on purpose

- **Upload metadata** (`uploads.filename`, `sha256`, `byte_size`, `file_format`). The inbox and the
  `list_uploads` tool search file names with SQL `LIKE`. `sha256` drives the unique replay index, and these
  columns are `attr_readonly`. The file bytes themselves (`content_base64`) are encrypted.
- **Employee names**, which are searched and sorted in SQL. Contact fields, emergency contact fields and HR
  `notes` were not in the #421 scope. They can be encrypted later in the same way, if nothing queries them.
- **Payroll ids, dates and statuses.** They hold no amounts.

## What changed in the code

- **Totals are added up in Ruby.** SQLite's `SUM()` over ciphertext silently returns 0, so payroll totals
  never use it now. `PayRun#total_gross_cents` and `#total_net_cents` use `pluck`, which decrypts each value,
  and the finalize step and the yearly gross on the pay-run list do the same.
- **Never filter, sort or sum an encrypted column in SQL.** `where(gross_cents: …)`, `order(:legal_name)` and
  `SUM(net_cents)` compare or add ciphertext, and they do so without raising an error.
- **1099 payees are sorted by name in Ruby** (`Finance::Form1099Totals`).
- **Team chat file search runs in Ruby.** The Media tab's search (`GET /chat/:room/media.json?q=`) can no longer
  use `LIKE` on `chat_messages.body`. It reads the room's files newest first, in batches of 200 with their
  messages. It matches the file name, the message text and the poster's name or email, case-insensitively.
  Each request stops at a page of 60 matches or after 2,000 files. When it stops early, `has_more` and
  `next_before` tell the browser where to carry on, and "Load more" continues from there.
  - The search only ever reads one room, and only after the room-visibility check, so tenant and room scope
    are unchanged.
  - Trade-offs: a search over a very large room takes several "Load more" steps, and each step decrypts up to
    2,000 message bodies.
  - We chose not to keep a separate plaintext search index. It would have stored the same text this change
    removes from disk.

## Backfill: encrypt rows written before their column gained `encrypts`

`support_unencrypted_data = true` (in `config/initializers/active_record_encryption.rb`) keeps old plaintext
rows readable. New writes are always encrypted. Old rows stay plaintext on disk until this task rewrites them:

```sh
# Dry run (the default): counts the plaintext rows per model and writes nothing.
bin/rails ops:encrypt_sensitive_fields
bin/rails ops:encrypt_sensitive_fields TENANT_ID=<tenant id>

# Write: re-encrypts every value that is still plaintext.
CONFIRM=1 bin/rails ops:encrypt_sensitive_fields                       # every tenant
CONFIRM=1 bin/rails ops:encrypt_sensitive_fields TENANT_ID=<tenant id> # one tenant

# Read-only check: plaintext rows per model and a total; exits 1 while any remain.
bin/rails ops:encryption_status
bin/rails ops:encryption_status TENANT_ID=<tenant id>
```

How the task behaves:

- **It covers every model that declares `encrypts`**, not a fixed list. It loads `app/models`, `app/modules`
  and any loaded engine (Buzz), then scans every Active Record class with encrypted attributes. That is about
  60 models today: the nine in the table above plus the uploads, imports, reconciliation documents, Zelle,
  Authorize.net and SwipeSimple files, connection tokens, settings, marketing and the rest. A column that
  gains `encrypts` later is covered with no change to the task.
- **Skipped models** are printed as `skipped (reason)`:
  - `table … is missing`: a model whose table does not exist on this server, such as a gem model
    (`ActionText::EncryptedRichText`) or an engine that is not migrated. It has no rows.
  - `column … missing`: the column is not in the table yet.
  - `no tenant_id column` (only with `TENANT_ID`): global tables such as `shops` and `settings`. A run
    without `TENANT_ID` covers them.
  - `… not encrypted by every model on <table>`: a table shared by unrelated classes (`tasks` serves several
    kinds). A column is rewritten only when every class on that table decrypts it. No such column exists today.
- Under STI, the parent's scan covers the whole table. A subclass is scanned only for columns that it alone
  encrypts, with its type condition.
- It reads only the id and the encrypted columns, as raw values. No record is instantiated, so callbacks,
  `after_find` and default scopes do not run. Batches are 200 rows, 50 for JSON documents and payloads,
  and 10 for file bytes (`content_base64`, CSV exports, chat attachments, binary columns). Feedback attachments
  are read 20 at a time.
- A value is rewritten only when it is non-null and not ciphertext. Values already encrypted are left alone.
  The rewrite uses `update_all` on that row and writes only the plaintext columns. Validations, callbacks and
  `updated_at` are not touched. Read-only records (`attr_readonly` uploads and receipts, issued 1099 filings)
  are included. Deterministic columns are written with the deterministic key, so lookups by equality still match.
- Each batch is one transaction.
- It is idempotent. A second run reports 0 rows with plaintext.
- It prints, per model, how many rows it checked, how many still had plaintext, and how many it encrypted.
- `ops:encryption_status` runs the same scan read-only. It prints `Model: N plaintext of M rows` and a total.
  It ends with `Ready: …` when the total is 0, or `Not ready: …` and exit status 1 otherwise. A run without
  `TENANT_ID` also records the total in `storage/ops/encryption_status.json`, and **System health → Database**
  shows it as "Plaintext in encrypted columns" with the time of the check.

Procedure on live (the owner runs this; agents do not):

1. Take a fresh backup (`bin/backup.sh`) and confirm `/etc/rupert.env` has the same three keys that the app uses.
2. Run the dry run and note the counts.
3. Run with `CONFIRM=1`.
4. Run `bin/rails ops:encryption_status`. Every model should show `0 plaintext` and the total should be 0.
5. Spot-check a chat room, a pay run, an employee, an upload and the 1099 page.

`ops:encrypt_shop_tokens` is no longer needed: `Shop` is covered by this task.

## Phase b: turn plaintext support off

Do this only after `bin/rails ops:encryption_status` (no `TENANT_ID`) on live prints `Total: 0 rows with
plaintext` and `Ready`. Once plaintext support is off, any plaintext value left in an encrypted column raises
`ActiveRecord::Encryption::Errors::Decryption` when it is read.

1. Run the status check once more right before the change, and keep its output.
2. In `web/config/initializers/active_record_encryption.rb`, replace the last line:

   ```ruby
   # before
   Rails.application.config.active_record.encryption.support_unencrypted_data = true
   # after
   Rails.application.config.active_record.encryption.support_unencrypted_data = false
   ```

   Also update the comment above it: every encrypted column has been backfilled, so plaintext is no longer
   accepted.
3. Merge and deploy as usual, then watch the error tracker and the logs for `Decryption` errors. Open a chat
   room, a pay run, an employee, an upload, a reconciliation document and the 1099 page.
4. From then on, a model that gains `encrypts` over a column with existing rows needs its own plan. Either
   declare that column with `encrypts :name, support_unencrypted_data: true` until the backfill has run, or
   turn the global setting back on for that deploy.

Rollback: set the line back to `support_unencrypted_data = true` and deploy. Nothing on disk changes in either
direction, because the setting only controls whether plaintext is accepted when a value is read. If a
`Decryption` error shows up, roll back first. Then run `bin/rails ops:encryption_status` to find the model,
and run `CONFIRM=1 bin/rails ops:encrypt_sensitive_fields` before trying phase b again.
