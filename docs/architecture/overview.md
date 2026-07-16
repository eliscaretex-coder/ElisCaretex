# Architecture Overview

## Target architecture

```text
Browser
  |
  v
Cloudflare Pages
  |
  | Supabase JavaScript client / controlled RPC calls
  v
Supabase Auth + PostgreSQL
  |
  +-- Master data
  +-- Customer schedules
  +-- Trolley custody
  +-- Sorting and washing
  +-- Finish and Mop production
  +-- Roster and work sessions
  +-- Reports
  +-- Audit
```

## Core design principles

1. One shared platform, not copied screens in several applications.
2. Shared business rules belong in PostgreSQL functions, constraints and views.
3. The frontend displays and collects information; it does not own critical rules.
4. Operational events are traceable and are not silently overwritten.
5. Planned work, actual work and reported work remain separate.
6. The current Google Apps Script system remains running during development.
7. Migration is incremental and reversible.
