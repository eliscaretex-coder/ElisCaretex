-- My Driver Roster / Published Driver Roster: return approved driver leave for the week.
-- Published Distribution rosters have no entry for a driver on approved leave, so the
-- page showed "Off". The frontend overlays `approved_leave` to show Holiday / Day Off.
-- Read-only change: same permission checks and scope as before (management sees all
-- active drivers, a driver sees only their own leave).

begin;

create or replace function public.get_my_driver_roster(p_week_start date default null)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_driver uuid:=public.current_distribution_driver_id(); v_management boolean:=public.can_manage_driver_guides(); v_week date:=coalesce(p_week_start,date_trunc('week',current_date)::date); v_version uuid;
begin
 if auth.uid() is null then raise exception using errcode='42501',message='Sign in is required.'; end if;
 if v_driver is null and not v_management then raise exception using errcode='42501',message='This account is not linked to an active Distribution driver.'; end if;
 if v_week<>date_trunc('week',v_week)::date then raise exception using errcode='22023',message='The week must start on Monday.'; end if;
 select distribution_roster_version_id into v_version from public.distribution_roster_versions where week_start=v_week and roster_status='PUBLISHED' order by version_number desc limit 1;
 return jsonb_build_object('week_start',v_week,'week_end',v_week+6,'management_view',v_management,'driver_id',v_driver,
  'driver',case when v_driver is null then null else (select to_jsonb(d) from public.distribution_drivers d where d.driver_id=v_driver) end,
  'drivers',coalesce((select jsonb_agg(jsonb_build_object('driver_id',d.driver_id,'driver_code',d.driver_code,'display_name',d.display_name) order by d.display_name) from public.distribution_drivers d where d.deleted_at is null and d.employment_status='ACTIVE' and not d.roster_hidden and (v_management or d.driver_id=v_driver)),'[]'::jsonb),
  'document',(select to_jsonb(v) from public.distribution_roster_versions v where v.distribution_roster_version_id=v_version),
  'entries',coalesce((select jsonb_agg(to_jsonb(e) order by e.work_date,e.primary_driver_name_snapshot,e.route_code_snapshot) from public.distribution_roster_entries e where e.distribution_roster_version_id=v_version and (v_management or v_driver in(e.primary_driver_id,e.support_driver_id))),'[]'::jsonb),
  'requests',case when v_management then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from public.distribution_driver_absences a where a.driver_id=v_driver),'[]'::jsonb) end,
  'approved_leave',coalesce((select jsonb_agg(jsonb_build_object('absence_id',a.absence_id,'driver_id',a.driver_id,'absence_type',a.absence_type,'starts_on',a.starts_on,'ends_on',a.ends_on) order by a.starts_on) from public.distribution_driver_absences a where a.absence_status='APPROVED' and a.starts_on<=v_week+6 and a.ends_on>=v_week and (v_management or a.driver_id=v_driver)),'[]'::jsonb)
 );
end;$$;
revoke all on function public.get_my_driver_roster(date) from public,anon;
grant execute on function public.get_my_driver_roster(date) to authenticated;

commit;
