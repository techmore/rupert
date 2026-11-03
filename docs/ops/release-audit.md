# Release audit

Every Rupert release passes a security, privacy and partner-readiness audit. Most of it is automatic and blocks the build. A short manual part is signed off by a named person for each stable release. The partner-facing summary is [docs/security/partner-security-overview.md](../security/partner-security-overview.md).

## What runs where

| Check | Every PR and every `main` push | Release tag `v*` | Updater (before each install) |
| --- | --- | --- | --- |
| Card data redaction tests (logs, errors, chat, AI prompts) | **Blocks**: `CI (sqlite3)` step "Card data redaction tests" | Required check must be green on the tagged commit | Needs a green `CI (sqlite3)` |
| Card numbers / track data in the repository | **Blocks**: `Product site consistency` → `bin/release-audit` | **Blocks** | Needs a green `Product site consistency` |
| Customer names on public pages (hashed deny-list) | **Blocks** new findings (needs the secret, below) | **Blocks**, and a missing deny-list blocks a final release | Same check |
| Email addresses / forwarded-email evidence on public pages | **Blocks** new findings | **Blocks** | Same check |
| "PCI certified", "SOC 2", "ISO 27001", "pen-tested" without evidence | **Blocks** | **Blocks** | Same check |
| Draft notice or owner placeholders on `/terms`, `/refunds` | Warning | **Blocks a final release** (`vX.Y.Z`); a pre-release (`vX.Y.Z-rc.N`) only warns | Warning |
| Secrets (gitleaks) | **Blocks**: `Dependency and static scan` scans the new commits | **Blocks**: whole tree | Needs a green `Dependency and static scan` |
| Vulnerable gems, Brakeman | **Blocks** (unchanged) | Required check | Same check |
| Backups ok, encrypted, < 26 h old | — | — | `rupert-release-audit` (warn or enforce) |
| `/up` healthy, TLS valid ≥ 14 days | — | — | same |
| DMARC record for `rupertpos.com` | — | — | same |
| Company facts in `/etc/rupert.env` set, not placeholders | — | — | same |

"Blocks new findings" means the hashed baseline `.github/release-audit-baseline.json` lists known findings. These warn on PRs and on `main` so existing pages don't stop deploys. A **final release ignores the baseline**, so every known finding must be fixed before a stable `vX.Y.Z` tag can publish. The baseline holds only hashes and never names or text. Regenerate it with `bin/release-audit --write-baseline .github/release-audit-baseline.json` after fixing findings. Never regenerate it to hide a new one.

The audit report shows the file, line and rule, but never the matched name, number or address.

## The privacy deny-list (owner, one time)

The deny-list is the list of merchant and customer names, people's names, processor names tied to a merchant, and any other text that must never appear in public content. It lives only in the GitHub Actions secret `RUPERT_PRIVACY_DENYLIST`, as an HMAC-SHA256 list with a random key. Matching ignores case, accents, punctuation and spacing ("Acme Hemp" = "acmehemp" = "ACME-HEMP").

On a trusted computer:

1. Write the names, one per line, into a file outside the repository.
2. Hash the names and store the result as the secret:

   ```bash
   bin/release-audit privacy-hash < ~/private/rupert-denylist.txt | gh secret set RUPERT_PRIVACY_DENYLIST --repo techmore/rupert
   ```

3. Delete the text file, or keep it in the password manager.

To add names later, re-run with the same key (`RUPERT_PRIVACY_KEY=<key from the current secret>`) or simply hash the full list again.

To check locally, put the JSON in a private file and run:

```bash
RUPERT_PRIVACY_DENYLIST_FILE=~/private/denylist.json bin/release-audit --strict-docs
```

**Order matters.** As soon as the secret exists, every page that still names a customer becomes a blocking finding on `main`, and a red `main` stops the updater. So:

1. Load the deny-list locally first:

   ```bash
   RUPERT_PRIVACY_DENYLIST_FILE=~/private/denylist.json bin/release-audit --strict-docs
   ```

2. Fix what you can (the website session is redacting the guides).
3. Record the rest in the baseline:

   ```bash
   RUPERT_PRIVACY_DENYLIST_FILE=~/private/denylist.json bin/release-audit --write-baseline .github/release-audit-baseline.json
   ```

4. Merge that baseline.
5. Then run `gh secret set`.

Known findings keep warning on every run and still block a final release.

Pull requests from forks cannot read secrets. Their runs skip the name check and say so in the report.

## Evidence for certification wording

Public wording like "PCI certified", "SOC 2", "ISO 27001" or "pen-tested" is allowed only when a matching evidence file exists in `docs/security/evidence/`:

| File | Evidence |
| --- | --- |
| `pci-dss-aoc.md` | Current AOC: date, assessor, scope |
| `soc2-report.md` | Current report: type, period, auditor |
| `iso27001-certificate.md` | Current certificate: number, scope, expiry |
| `penetration-test.md` | Test date, tester, scope and remediation status |

Negated or planned wording ("Rupert has no SOC 2 report", "a penetration test is planned") passes without evidence.

## Runtime audit on the server

`deploy/ser8/rupert-release-audit` runs inside the `rupert` container as root. It reads:
- the backup reports the app shows on System → Backups;
- the public `/up` endpoint and TLS certificate;
- the `_dmarc.rupertpos.com` record;
- the names, never the values, of the company facts in `/etc/rupert.env` (`RUPERT_LEGAL_NAME`, `RUPERT_BUSINESS_ADDRESS`, `RUPERT_SUPPORT_PHONE`, `RUPERT_SECURITY_EMAIL`).

Install it once:

```bash
install -m 0755 deploy/ser8/rupert-release-audit /usr/local/sbin/rupert-release-audit
```

The updater runs it before every install and keeps `/var/lib/rupert-autodeploy/audits/<sha>.md`.

- **warn** (the default) installs anyway and logs the failure.
- **enforce** refuses the install while the audit fails. To switch modes:
  - `echo enforce > /var/lib/rupert-autodeploy/audit-mode` turns enforce on.
  - `rm /var/lib/rupert-autodeploy/audit-mode` returns to warn.

Turn on enforce once backups, DMARC and the company facts pass. Until then every install would be refused. An emergency fix can still go out by switching back to warn for that install.

Run it by hand for a release:

```bash
rupert-release-audit --report /tmp/runtime-audit.md
```

## Manual sign-off (each stable release)

The release owner `[CONFIRM: name]` signs off, and a second person `[CONFIRM: name, or "none: single maintainer"]` reviews. Steps:

1. Check that the Release workflow's **Release audit** job passed and the static report is attached to the GitHub release.
2. Run the runtime audit on the server and attach the result:

   ```bash
   gh release upload vX.Y.Z runtime-audit.md
   ```

3. Check that a restore drill passed within the last month (`docs/ops/backups.md`, "Restore drill").
4. Check that `docs/security/partner-security-overview.md` is still true: no new sub-processor, no new card-data path, and the placeholders are filled in.
5. Read the public pages that changed in this release: no customer names, emails or processor history.
6. Record the sign-off in the release notes: `Release audit: static PASS (attached), runtime PASS (attached), restore drill <date>, signed off by <name>`.

The GitHub release (its attached reports and notes) is the audit log for each release.
