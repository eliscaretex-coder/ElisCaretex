---
name: finish-task
description: End-of-task checklist for this repository (AGENTS.md section 6) - WORKLOG entry, INIT update with honest evidence terms, validation and a clean working tree
---

# Finish task

Run before the final commit of any task, and before telling the owner a task is done.

1. **Validate.** `node scripts/validate-repository.mjs` passes. For database work, the
   matching `supabase/tests/` file passed and the security advisors were checked.
2. **WORKLOG.** Add an entry at the top of the entries in `docs/handover/WORKLOG.md`
   (below "Open action items" and the `---`), in this exact format:

   ```text
   ## YYYY-MM-DD — Claude — <short title>

   - Branch / commits: <claude/<topic>, Pull Request>
   - Changed: <what changed, in one to five lines>
   - Database: <migration files applied to ElisCaretex-dev, or "none">
   - Validation: <what was checked and how; say "not validated" if nothing was>
   - Open / next: <what is unfinished, risks, owner decisions needed>
   ```

   Tick (`[x]`, with date and commit) any open action item the task completed.
3. **INIT.** For material behaviour, security or database changes, update
   `docs/handover/ElisCaretex_V2_PROJECT_INIT_2026-09-10_v87_CURRENT.md` (workspaces,
   migrations in section 14, commits in section 15). Use the evidence terms honestly:
   **Applied** (in the database), **Validated** (a test or check passed),
   **Owner confirmed** (the owner tested it), **Prepared** (written, not applied).
   Never write Validated or Owner confirmed for something that was not.
4. **Commit.** The message says what changed and why.
5. **Clean tree.** `git status` is clean, or anything unfinished is listed under
   "Open / next" and reported to the owner.
6. **Deliver.** Push the `claude/<topic>` branch and open a Pull Request into `master`.
   Never push to `master`.
