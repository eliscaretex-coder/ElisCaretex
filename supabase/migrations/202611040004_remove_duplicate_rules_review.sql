-- ElisCaretex V2
-- 202611040004_remove_duplicate_rules_review
--
-- General review of overlapping rules (2026-11-04). Two small corrections:
--
-- 1. Three unique indexes exist twice with exactly the same definition
--    (Supabase "duplicate_index" advisor). Each pair enforces the same rule
--    twice and doubles the write cost. The copy that the planner never uses
--    (0 scans) is dropped; the copy in use stays, so the rules do not change:
--      - one DRAFT roster per week          keeps distribution_roster_one_draft_per_week_idx
--      - one PUBLISHED roster per week      keeps distribution_roster_one_published_per_week_idx
--      - one roster line per driver per day keeps distribution_roster_entries_primary_driver_day_unique
--    None of the dropped indexes backs a constraint.
--
-- 2. MOP Type photos: the Storage policies still checked only the legacy role
--    (ADMIN, MANAGER), while the MOP Type RPCs (create/update_sorting_mop_type_master)
--    use the module permission (MOP: MANAGE) decided on 2026-10-23. The policies
--    now use the same helper, so the photo upload follows the same rule as the
--    MOP Type save. Accounts without module permissions (terminals) keep the
--    legacy-role rule, exactly as account_module_allowed does elsewhere.
--    The bucket stays public for reading, as before.
--
-- No data is changed.

drop index if exists public.distribution_roster_one_draft_per_week;
drop index if exists public.distribution_roster_one_published_per_week;
drop index if exists public.distribution_roster_primary_driver_date_unique;

drop policy if exists mop_type_photos_manager_select on storage.objects;
drop policy if exists mop_type_photos_manager_insert on storage.objects;
drop policy if exists mop_type_photos_manager_update on storage.objects;
drop policy if exists mop_type_photos_manager_delete on storage.objects;

create policy mop_type_photos_manager_select on storage.objects
  for select to authenticated
  using (bucket_id = 'mop-type-photos'
         and public.account_module_allowed(array['MOP'], 'MANAGE', array['ADMIN', 'MANAGER']));

create policy mop_type_photos_manager_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'mop-type-photos'
              and public.account_module_allowed(array['MOP'], 'MANAGE', array['ADMIN', 'MANAGER']));

create policy mop_type_photos_manager_update on storage.objects
  for update to authenticated
  using (bucket_id = 'mop-type-photos'
         and public.account_module_allowed(array['MOP'], 'MANAGE', array['ADMIN', 'MANAGER']))
  with check (bucket_id = 'mop-type-photos'
              and public.account_module_allowed(array['MOP'], 'MANAGE', array['ADMIN', 'MANAGER']));

create policy mop_type_photos_manager_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'mop-type-photos'
         and public.account_module_allowed(array['MOP'], 'MANAGE', array['ADMIN', 'MANAGER']));
