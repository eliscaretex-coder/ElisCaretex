# AGENTS.md — shared rules for every AI agent on this repository

Two AI agents work on this project for the owner (Paulo Bressan):

- **Codex** — works in a local Windows working copy and pushes to `master`.
- **Claude** — works in a cloud clone of this repository and delivers through Pull Requests.

Neither agent remembers previous sessions. Everything the next agent needs must be
in this repository. Read this file first, then follow the checklists below.

Codex reads this file automatically. Claude reads it through `CLAUDE.md`.

## 1. Source of truth

| What | Where |
| --- | --- |
| Code and documentation | GitHub `eliscaretex-coder/ElisCaretex`, branch **`master`** |
| Live application | GitHub Pages `https://eliscaretex-coder.github.io/ElisCaretex/`, deployed from `master` |
| Database | Supabase project `ElisCaretex-dev` (ref `fcimmysqifzxoanmpylh`, eu-west-1) |
| Project knowledge | `docs/handover/ElisCaretex_V2_PROJECT_INIT_2026-09-10_v87_CURRENT.md` (INIT, authoritative) |
| Who changed what, recently | `docs/handover/WORKLOG.md` |

The branch `main` is an obsolete upload from 2026-09-23 (15 files). Do not read it,
branch from it or open Pull Requests against it.

Local copies (the Codex working copy and the owner's OneDrive copy) are not the
source of truth. Anything that is not pushed to `master` does not exist for the
other agent.

## 2. Required reading before any change

1. This file.
2. The last entries of `docs/handover/WORKLOG.md`. These record work that the INIT may not cover yet.
3. The INIT handover named above, in full, including its section 18 (startup checklist).
4. `docs/handover/REVIEW_2026-10-16.md`.
5. `docs/database/APPS_SCRIPT_DATA_IMPORT_GUIDE.md` before any data import work.

## 3. Start-of-task checklist

```text
git fetch origin
git status                  # never discard uncommitted changes; they may be the owner's
git pull origin master      # or rebase your branch on origin/master
git log --oneline -15       # see what the other agent did since your last session
```

Then check open Pull Requests and `claude/*` branches on GitHub. Do not edit files
that an open Pull Request is changing without telling the owner.

## 4. How changes reach production

Every push to `master` runs `.github/workflows/pages.yml`. It runs
`node scripts/validate-repository.mjs` (JavaScript syntax and an exact Supabase JS
version pin) and then publishes `frontend/` to GitHub Pages. **A push to `master`
is a production deployment.**

- **Claude** works only on branches named `claude/<topic>` and opens a Pull Request
  into `master`. The owner (or Codex, on the owner's request) reviews and merges.
- **Codex** currently commits directly to `master`, as agreed with the owner.
  If the owner changes this, record the decision here.
- Before pushing to `master`, run `node scripts/validate-repository.mjs` locally.

## 5. Database changes (shared, immediately live)

There is one Supabase project. A migration applied by one agent changes the
database for the other agent and for the live application at once.

- New migration files go in `supabase/migrations/` and are named
  `YYYYMMDDNNNN_snake_case_description.sql` (for example
  `202610170012_customer_guide_history.sql`).
- Commit the migration file in the same change set as the code that depends on it.
- Apply only migrations that exist as committed files. Never apply ad-hoc DDL
  without also committing it as a migration file.
- Never edit, rename or re-run a historical migration.
- Record every applied migration in `docs/handover/WORKLOG.md`.
- Validation SQL lives in `supabase/tests/` (pgTAP: `select plan(...)` …
  `finish()`, wrapped in `begin; … rollback;`). These tests are run manually
  against the development project; CI does not run them.
- Run the Supabase security advisors after database work.

**Migration history caveat (verified 2026-10-18).** The live
`supabase_migrations` history starts at `20260811163258` and lists 94 entries,
while `supabase/migrations/` holds 179 files from `202607160001` onwards. The 50
files dated before 2026-08-11 and 41 later files (for example
`202608120008_finish_v2_production_foundation.sql`) were applied outside the
tracked history; spot checks confirmed their objects exist in the database. Four
live entries use different names from the matching files, and two live entries
(`production_intelligence_forward_capacity_compact_learning`,
`production_intelligence_forward_capacity_final_states`) are consolidated in
`202609260005_production_intelligence_forward_capacity.sql`. To know whether a
change is applied, query the database objects; do not rely on the history table
or on file names alone.

## 6. End-of-task checklist

1. Append an entry to `docs/handover/WORKLOG.md` (format at the top of that file).
2. For material behaviour, security or database changes, also update the INIT
   handover. Keep its "evidence terms" honest: Applied, Validated, Owner
   confirmed, Prepared.
3. Write commit messages that say what changed and why.
4. Leave the working tree clean: commit or explicitly report anything unfinished.

## 7. Non-negotiable project rules (summary — the INIT has the full list)

- Code, database objects, file names and UI text are in English. Conversation
  with the owner is in Portuguese.
- The frontend is not a security boundary. Authorization lives in PostgreSQL
  (RLS, controlled RPCs, constraints) and Edge Functions.
- A new `SECURITY DEFINER` RPC revokes `PUBLIC` execution and checks identity and
  permission internally. New UI permissions need matching database authorization
  and negative tests.
- `frontend/assets/js/config.js` holds only the project URL, the publishable key
  and the public app URL. Never commit service-role keys, secret keys, SMTP or
  personal passwords.
- Never silently overwrite published schedules, rosters, approvals or production
  history. Correct through versioning, cancellation or append-only events.
- Official Clothes KG comes only from Finish production `KG` lines; official MOP KG
  from MOP batches. Sorting wash weight is approximate and never official.
- Keep personal accounts, Staff Master records and production terminal accounts separate.
- Historical Apps Script data goes through restricted staging and reconciliation,
  never directly into operational tables.
