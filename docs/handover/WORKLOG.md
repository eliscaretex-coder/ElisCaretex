# Work log — shared by Codex, Claude and the owner

One entry per finished task, newest at the top. Read the latest entries before
starting work: they record changes the INIT handover may not cover yet.

Entry format:

```text
## YYYY-MM-DD — <agent: Codex | Claude | Owner> — <short title>
- Branch / commits: <branch, PR number or commit hashes>
- Changed: <what changed, in one to five lines>
- Database: <migration files applied to ElisCaretex-dev, or "none">
- Validation: <what was checked and how; say "not validated" if nothing was>
- Open / next: <what is unfinished, risks, owner decisions needed>
```

---

## 2026-10-18 — Claude — Repository and database review; coordination files

- Branch / commits: `claude/coordination-setup` (Pull Request into `master`).
- Changed: added `AGENTS.md`, `CLAUDE.md` and this work log. No code or database change.
- Database: none. Read-only checks only.
- Validation, against `master` at `acfca47`:
  - `node scripts/validate-repository.mjs` passed (24 JavaScript files, 20 HTML files).
  - No service-role key, secret key or password found in tracked files.
    `frontend/assets/js/config.js` contains only the project URL, the publishable key and the public app URL.
  - Every file and commit hash cited in the INIT exists, except `.reference-distribution/`
    and `graphify-out/`, which `README.md` mentions but are not in the repository.
  - All 11 migrations added after INIT v90 (`202610170002` to `202610170012`) appear in the
    live migration history. Spot checks found their objects (for example
    `customer_driver_guides`, `get_my_driver_roster`) in the database.
  - Edge Functions match the INIT: `production-roster-leave-email` v3 and
    `admin-account-management` v14, both active with `verify_jwt=true`.
  - Security advisors match INIT section 14: leaked-password protection disabled;
    `btree_gist` in the `public` schema; anonymous `SECURITY DEFINER` execution limited
    to the six token-based production roster endpoints; 281 authenticated
    `SECURITY DEFINER` functions (expected design, internal guards); 103 tables with RLS
    enabled and no policies (INFO; access goes through RPCs).
- Open / next:
  - The INIT handover (last updated in `9308683`, 2026-10-17 17:48) does not yet describe
    the Distribution driver-roster and customer-guide work from the entry below. The next
    INIT refresh should add it.
  - The GitHub default branch is still the obsolete `main`. Owner action: set `master` as
    default in Settings → General, then delete `main`.
  - `README.md` mentions `.reference-distribution/` and `graphify-out/`, which exist only in
    local copies, if anywhere.

## 2026-10-17 — Codex (recorded from Git history) — Distribution driver roster and customer guides

Not covered by INIT v90. Reconstructed by Claude on 2026-10-18 from Git history; commit
author recorded as Paulo Bressan.

- Commits: `1f69f2e` … `acfca47` (12 commits, 18:08–21:13).
- Changed: Distribution roster publication for non-working entries; new My Driver Roster
  (`frontend/pages/driver-roster.html`) and customer delivery guides
  (`frontend/pages/driver-guides.html`) with a private storage bucket; driver leave review
  and leave calendar; driver identity, codes and licence types; roster printing; readable
  Distribution history for administrators, including Customer Guide actions.
- Database: `202610170002` to `202610170012`, all present in the live migration history.
  New validation SQL: `supabase/tests/202610170002_…_validation.sql` and
  `supabase/tests/202610170003_…_validation.sql`.
- Validation: each push passed the GitHub Pages workflow. Browser and owner confirmation
  are not recorded.
- Open / next: document this work in the next INIT refresh.
