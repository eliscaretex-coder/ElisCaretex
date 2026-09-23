# ADR-001 — Centralize Shared Business Rules

## Status

Accepted.

## Context

The current system has separate Google Apps Script applications for Sorting,
Finish, Distribution, Roster and Data Management. Several screens and rules are
copied between applications. When one copy changes, other copies can remain
outdated.

## Decision

Critical shared rules will be implemented in PostgreSQL through:

- foreign keys;
- check constraints;
- unique and exclusion indexes;
- transactional database functions;
- shared views;
- RLS policies;
- audit events.

The frontend will call controlled operations instead of making several
independent writes.

## Consequences

- One rule serves all screens.
- Data stays consistent when several computers write concurrently.
- Changes require database migrations and testing.
- The frontend becomes smaller and easier to replace.
