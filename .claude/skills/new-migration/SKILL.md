---
name: new-migration
description: Create a Supabase migration in this project's format, with its pgTAP validation test, PUBLIC revokes for SECURITY DEFINER RPCs and the WORKLOG entry
disable-model-invocation: true
---

# New migration

Use for any database change. Read `AGENTS.md` section 5 first. There is one Supabase
project (`ElisCaretex-dev`, ref `fcimmysqifzxoanmpylh`): applying a migration changes the
live application at once.

## 1. Name the file

- `supabase/migrations/YYYYMMDDNNNN_snake_case_description.sql`, where `YYYYMMDD` is today
  and `NNNN` is the next free number for today (`ls supabase/migrations | grep ^YYYYMMDD`).
- The matching test is `supabase/tests/YYYYMMDDNNNN_<same_description>_validation.sql`.
- Never edit, rename or re-run an existing migration. Correct through a new one.

## 2. Write the migration

Every new or replaced function that is `security definer` must:

```sql
create or replace function public.<name>(<args>)
returns <type>
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_<area>_<level>_access();  -- identity and permission check first
  -- ...
end;
$$;

revoke all on function public.<name>(<arg types>) from public, anon;
grant execute on function public.<name>(<arg types>) to authenticated;
```

- Internal or cron-only functions also revoke from `authenticated`.
- New views use `with (security_invoker = true)`.
- New tables enable RLS in the same migration.
- Published schedules, rosters, approvals and production history are corrected through
  versioning, cancellation or append-only events, never overwritten.

## 3. Write the pgTAP test

```sql
begin;
select plan(<n>);
select has_function('public','<name>',array['<arg types>'],'<name> exists');
select ok(not has_function_privilege('anon','public.<name>(<arg types>)','execute'),'anon cannot call <name>');
select ok(pg_get_functiondef('public.<name>(<arg types>)'::regprocedure) like '%require_<area>_<level>_access%','<name> checks permission');
-- negative tests: a role without the permission is refused
select * from finish();
rollback;
```

## 4. Apply and verify

1. Commit the migration and the code that depends on it in the same change set.
2. Apply it only after the owner asks, and only from the committed file.
3. Run the test file against the project and confirm every assertion passes.
4. Run the Supabase security advisors and report new findings.
5. Check that objects exist by querying them; the migration history table is incomplete
   (see the caveat in `AGENTS.md` section 5).

## 5. Record it

Add the migration under **Database** in the `docs/handover/WORKLOG.md` entry for the task,
saying whether it was **applied** and how it was verified. Use the finish-task skill.
