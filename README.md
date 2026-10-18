# Laundry Platform V2

ElisCaretex's shared operational platform for customer planning, distribution, roster, sorting, MOP, Finish, trolley custody and production tracking.

## Start here

- `AGENTS.md` holds the shared working rules for Codex and Claude: source of truth, branches, database changes and handover duties.
- `docs/handover/WORKLOG.md` records who changed what, newest first. Read it before starting work.
- `docs/handover/ElisCaretex_V2_PROJECT_INIT_2026-09-10_v87_CURRENT.md` is the authoritative AI handover (INIT v90, updated 2026-10-17) and delivery baseline.
- `docs/handover/REVIEW_2026-10-16.md` records the latest security, UI, database and browser validation review.
- `docs/architecture/overview.md` is the current architecture and access-model summary.
- `docs/architecture/PLATFORM_CORRECTION_REGISTER_20260818.md` is the active register of known risks and future corrections.
- `docs/NAVIGATION-ACCESS-MODEL.md` defines the role-aware workspace navigation.
- `supabase/migrations/` is the database change history. Do not alter or rerun historical migrations without an approved database deployment plan.
- `.reference-distribution/` holds the supplied Google Script distribution reference used for functional comparison.

## Project structure

```text
frontend/     Static operational frontend
supabase/     Database migrations, Edge Functions and validation SQL
docs/         Current architecture, operational, database, frontend and test guidance
```

## Working rules

1. Use controlled Supabase RPCs for protected operational data; navigation visibility is not authorization.
2. Keep production terminals separate from individual system-user accounts.
3. Preserve the distinction between planned, actual, reported and corrected operational facts.
4. Follow `AGENTS.md` for branches, database changes and the shared work log.
