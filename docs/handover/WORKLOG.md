# Work log — shared by Codex, Claude and the owner

One entry per finished task, newest at the top. Read the open action items and the
latest entries before starting work: they record changes the INIT handover may not
cover yet.

## Open action items

Whoever completes an item ticks it (`[x]`), adds the date and commit, and records the
work as a normal entry below. Remove ticked items at the next INIT refresh.

### For Codex

Completed 2026-10-18 in c796ff3 (INIT v91); recorded by this WORKLOG entry.
The two recurring checklist items below are adopted ongoing rules, not retired obligations.

- [x] **Refresh the INIT handover to v91** in
      `docs/handover/ElisCaretex_V2_PROJECT_INIT_2026-09-10_v87_CURRENT.md`:
  - [x] Add the Distribution work from the 2026-10-17 entry below (commits `1f69f2e` to
        `acfca47`, migrations `202610170002` to `202610170012`): what each workspace now
        does, which permissions/RPCs protect it, and its validation status using the INIT
        evidence terms (Applied, Validated, Owner confirmed, Prepared).
  - [x] Add My Driver Roster and Customer Guides to section 4 (workspaces), the new
        migrations to section 14 and the commits to section 15.
  - [x] Update "Repository state reviewed through" to the newest commit.
  - [x] Section 2: name `AGENTS.md` and `WORKLOG.md` as required reading and state that
        Claude also works on this repository through `claude/*` Pull Requests.
  - [x] Section 18: close checklist item 10. Verified 2026-10-18: the customer KG change set
        (frontend and `202610170001_customer_kg_history_and_weekday_suggestions.sql`) is
        on `master` in commit `9308683` and deployed.
  - [x] Add the migration-history caveat from `AGENTS.md` section 5 to section 14.
- [x] **From now on, after every task:** add a WORKLOG entry (format above), including
      every migration applied to `ElisCaretex-dev`.
- [x] **Before every task:** `git pull origin master`, read this file, and check open Pull
      Requests from Claude so you do not edit the same files at the same time.

### For the owner

- [ ] Review and merge Pull Request #1 (this coordination setup).
- [ ] Decide whether `.reference-distribution/` is still needed. `README.md` describes it,
      but it is not in the repository. Either commit it or remove the README line.
- [ ] Enable leaked-password protection in Supabase Auth (open since INIT v90, section 16).

### Done

- [x] 2026-10-18 — Owner: set `master` as the GitHub default branch and deleted `main`.
- [x] 2026-10-18 — Owner decision, Claude: Graphify is no longer used. Its references were
      removed from `README.md` and `docs/architecture/overview.md`.

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

## 2026-10-18 — Codex — INIT v91 and working copy on the new computer

- Branch / commits: `master`, `c796ff3` (INIT refresh); this accompanying WORKLOG
  completion commit records the checklist and validation.
- Changed: refreshed INIT to v91, documenting Distribution publication/printing,
  My Driver Roster, Customer Guides, leave calendar/review, driver identity and
  readable history, with actual permission/RPC guards and honest evidence status.
  Added migrations `202610170002`–`202610170012`, all 12 Distribution commits,
  coordination milestones and the migration-history caveat. Closed startup item 10:
  customer KG frontend/migration reached master and deployment in `9308683`, per
  the existing verified action item. Added AGENTS/WORKLOG reading, Claude PR
  coordination and per-task logging as ongoing requirements.
- Working copy: Codex now works on this new computer at
  `C:/Users/bress/Documents/Codex/2026-10-18/clone-o-reposit-rio-https-github/ElisCaretex`,
  cloned from GitHub `master`; the INIT replaces the previous Codex computer path.
  GitHub master remains authoritative. Follow `AGENTS.md` on every future task.
- Database: none. No migrations applied, no operational records changed and no
  live database revalidation. Applied evidence is attributed to Claude's prior
  2026-10-18 review; SQL tests and Distribution owner acceptance remain unconfirmed.
- Validation: read AGENTS, WORKLOG, full INIT, review and import guide; fetched,
  checked clean status, pulled master and inspected recent history. GitHub open-PR
  search returned no open PRs; remote `claude/coordination-setup` still exists but
  PR #1 is already merged in `296e117`. Reviewed migration definitions and frontend
  RPC/Storage usage. `node scripts/validate-repository.mjs` passed (24 JavaScript
  files, 20 HTML files); `git diff --check` passed. No browser or SQL tests run.
- Open / next: push to origin/master is pending: Git Credential Manager on this new
  computer returned Access is denied while retrieving GitHub credentials. Both
  documentation commits are local; remote master remains at `296e117`.
  Recurring start/end checklists continue on every task. Distribution
  browser/negative permission tests and owner acceptance remain pending. Owner
  items concerning `.reference-distribution/` and leaked-password protection are
  unchanged; the old owner PR #1 action is already satisfied by merge `296e117`.

## 2026-10-18 — Claude — Repository and database review; coordination files

- Branch / commits: `claude/coordination-setup` (Pull Request into `master`).
- Changed: added `AGENTS.md`, `CLAUDE.md` and this work log; linked them from `README.md`
  and `docs/README.md`; removed the unused Graphify references (owner decision). No code
  or database change.
- Database: none. Read-only checks only.
- Validation, against `master` at `acfca47`:
  - `node scripts/validate-repository.mjs` passed (24 JavaScript files, 20 HTML files).
  - No service-role key, secret key or password found in tracked files.
    `frontend/assets/js/config.js` contains only the project URL, the publishable key and the public app URL.
  - Every file and commit hash cited in the INIT exists. `README.md` also mentioned
    `.reference-distribution/` and `graphify-out/`, which are not in the repository.
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
- Open / next: see "Open action items" at the top. The INIT handover (last updated in
  `9308683`, 2026-10-17 17:48) does not yet describe the Distribution work below.

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
