# Uploads inbox

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

One front door for files sent to Rupert (bank statements, QuickBooks,
SwipeSimple, NAB / IRIS, Authorize.net exports and others). A file is kept,
recognized and previewed; only a person's approval after a dry run changes a
business record. Product owner: the store owner. Full operator detail is in the
[Uploads inbox guide](../ops/uploads-inbox.md); this guide does not repeat it.

`ModuleRegistry` key `uploads` ("Uploads"), section **System**, group
**Connections**, permission `uploads.read`.

## Data model

- `Upload` (`TenantScoped`) is the source of truth: file name label, origin
  (browser, API, Google Drive, drop folder), SHA-256, byte size, format,
  detected type and confidence, importer key, status, `reason` and
  `reason_code`, dry-run digest, who imported or discarded it and when.
- The original bytes are stored once, encrypted (`encrypts :content_base64`),
  with `summary_json` and `params_json` also encrypted. A duplicate row points
  at the first copy (`duplicate_of`). A refused file keeps only metadata.
- Metadata (`filename`, `sha256`, size, type) stays plaintext on purpose: the
  inbox searches file names with `LIKE` and `sha256` backs the replay index
  ([encryption-at-rest.md](../ops/encryption-at-rest.md)).
- Importers are listed in `Uploads::Registry::IMPORTERS`; each writes to its
  own destination module.

## Permissions and tenant boundary

- `uploads.read` to see the list, details, originals and insights;
  `uploads.write` for everything else (`authorize(:module, …)` in
  `UploadsController`).
- Approving an import also needs the destination's permission (for example
  `finance.write` for bank statements), checked by `Uploads::Workflow.allowed?`.
- Intake refuses files unless the workspace is active. Every query is
  tenant-scoped; another workspace's upload is a `404`.

## Routes and API

- Web: `/uploads` (index, show, create), `recognize_all`, `insights`, and per
  file `choose`, `dry_run`, `approve`, `discard`, `reopen`, `recognize`,
  `original`. Google Drive copy at `/uploads/drive`.
- API: `POST /api/v1/uploads` (`uploads:write`), `GET /api/v1/uploads` and
  `GET /api/v1/uploads/:id` (`uploads:read`). A token can send files and read
  status but can never approve an import.
- MCP: `list_uploads` (`uploads:read`), read-only.
- Contract details: [API standards](../api-standards.md) and
  [API v1](../api-v1.md).

## Workflow and status transitions

Statuses (`Upload::STATUSES`): `received`, `recognized`, `needs_review`,
`imported`, `rejected`, `duplicate`. Open statuses are the first three.

- Intake (`Uploads::Intake`) sets `received`, `duplicate` or `rejected`, then
  recognition (`Uploads::Recognizer`) sets `recognized` or `needs_review`.
- A person may choose the importer by hand (`choose!` → `recognized`).
- Dry run runs in a transaction that is always rolled back; success keeps
  `recognized` with a digest, failure sets `needs_review`.
- Approve imports in one transaction with the status change → `imported`;
  a failed import returns to `needs_review`.
- Discard → `rejected` (not allowed once imported); reopen a discarded file →
  `received`.

All transitions are in `Uploads::Workflow`.

## UI patterns

List template for `/uploads` (upload box, status filter, table), Detail
template for one file (facts, preview, dry-run result, one primary action
**Approve and import**), Report template for Insights. Departures from the
interface guidelines: Unknown.

## Integration and sync

- Google Drive copy reads one chosen folder with `drive.readonly`; it never
  writes to Drive. Not verified against real Google.
- The drop folder is off unless `UPLOADS_DROP_ENABLED` and `UPLOADS_DROP_DIR`
  are set; `UploadsDropScanJob` runs every minute.
- Imports write only Rupert records. Nothing here writes to Shopify, Square or
  another outside system.

## Audit history

`Uploads::Audit` writes an Activity entry (`upload_<event>`) and an OpsLog
`upload` event with id, SHA-256, size, format, detected type, status, origin
and actor. File contents, cell values, parameters and file names never reach
the log. Upload rows also keep dry-run, import and discard actor names and
times.

## Failure and recovery

- Refusals and holds carry a plain-language `reason` and a `reason_code`.
- Identical bytes become a `duplicate`, so a repeat is never imported twice.
- Approval only works after a dry run of the same file, importer and settings.
- Limits: 10 files and 25 MiB per send, 10 MiB per file, 500 uploads per
  workspace per day, 2 GiB retained, 30 sends per minute (`Uploads::Limits`,
  `Uploads::Intake::DAILY_LIMIT` and `STORAGE_LIMIT`, Rack::Attack). Over-limit API calls get `413` or `429`.
- Originals are append-only and checksummed on read; there is no delete path.
  Recovery of upload bytes depends on database backups (see
  [backups](backups.md)).

## Required tests

- `web/test/integration/uploads_test.rb`, `uploads_api_test.rb`,
  `uploads_drive_test.rb`, `uploads_insights_test.rb`
- `web/test/services/uploads/` (intake, recognizer, workflow, files,
  drop scanner, insights, QuickBooks adapter and end-to-end)

## Open gaps

- #418: prove retained upload bytes are in a consistent backup and recoverable
  with the original keys. Open.
- Not verified: real exports other than through existing importer contracts,
  the drop folder on SER8, behaviour behind the production proxy body limit,
  and Google Drive copy against real Google.
