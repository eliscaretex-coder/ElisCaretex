-- Legacy Sync: match the earlier-import EntryID reference whatever punctuation follows it.
--
-- 202610270003 matched "source group FINISH:<EntryID>" only when the ID was followed
-- by ';' or the end of the notes. The 2026-10-24 local workbook import ends its notes
-- with a full stop ("... source group FINISH:FE-20261024-085110-3DBCFBA1."), so the
-- live dry run on 2026-10-27 did not find those 24 entries and planned them as
-- BLOCKED (CELL_HAS_ACTIVE_ENTRY) instead of ADOPT.
--
-- The new rule extracts every "source group FINISH:<ID>" token, where the ID is the
-- run of letters, digits, '-' and '_' after the colon, and compares it whole to the
-- legacy EntryID. FE-1 still does not match FE-12. Signature, grants and callers are
-- unchanged.

create or replace function integration.legacy_sync_notes_reference(p_notes text, p_entry_id text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_notes is not null and p_entry_id is not null
     and exists (
       select 1
       from regexp_matches(p_notes, 'source group FINISH:([A-Za-z0-9_-]+)', 'g') m
       where m[1] = p_entry_id
     );
$$;

revoke all on function integration.legacy_sync_notes_reference(text,text) from public, anon, authenticated;
