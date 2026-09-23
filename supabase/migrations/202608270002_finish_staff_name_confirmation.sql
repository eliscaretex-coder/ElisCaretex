-- Staff use the Finish workstation to confirm their actual table by name.
-- Only active production staff are exposed; the function does not change Roster.
create or replace function public.get_finish_staff_candidates_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_staff jsonb;
begin
  perform public.require_finish_production_access();

  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id',sm.staff_id,
    'display_name',sm.display_name
  ) order by sm.display_name),'[]'::jsonb)
  into v_staff
  from public.staff_members sm
  where sm.active=true
    and sm.production_staff=true
    and sm.roster_eligible=true
    and sm.deleted_at is null
    and nullif(trim(sm.display_name),'') is not null;

  return jsonb_build_object(
    'schema_version','FINISH_STAFF_CANDIDATES_V1',
    'staff',v_staff
  );
end;
$$;

revoke all on function public.get_finish_staff_candidates_v1() from public,anon;
grant execute on function public.get_finish_staff_candidates_v1() to authenticated;

comment on function public.get_finish_staff_candidates_v1() is
  'Returns active production-staff names for Finish actual attendance confirmation.';
