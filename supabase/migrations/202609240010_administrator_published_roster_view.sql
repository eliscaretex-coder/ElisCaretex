-- Administrators can review every published Production roster without being
-- linked to a Production Staff record. Regular accounts remain self-service only.

create or replace function public.get_my_account_roster_portal()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare
 v_staff public.staff_members%rowtype;
 v_current_week date:=public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date);
 v_administrator boolean:=public.has_any_role(array['ADMIN']);
begin
 if auth.uid() is null then raise exception using errcode='42501',message='Authentication is required.'; end if;
 if not public.has_account_permission('MY_ROSTER','VIEW','OWN') then raise exception using errcode='42501',message='Your account cannot view My Roster.'; end if;

 select * into v_staff
 from public.staff_members
 where auth_user_id=auth.uid() and active and production_staff and deleted_at is null;

 if not found and not v_administrator then
   raise exception using errcode='P0002',message='This account is not linked to an active Production Staff record.';
 end if;

 return jsonb_build_object(
 'generated_at',now(),
 'fixed_link',false,
 'administrator_view',v_administrator,
 'staff',case when v_administrator then null else jsonb_build_object('staff_id',v_staff.staff_id,'display_name',v_staff.display_name) end,
 'shifts',coalesce((select jsonb_agg(jsonb_build_object('shift_code',s.shift_code,'shift_name',s.shift_name,
 'weeks',coalesce((select jsonb_agg(week_json order by (week_json->>'week_start')::date) from (
   select jsonb_build_object('week_start',rp.week_start,'week_end',rp.week_start+6,'version_number',prv.version_number,'published_at',prv.published_at,'week_note',prv.week_note,'include_sunday',prv.include_sunday,
   'entries',coalesce((select jsonb_agg(jsonb_build_object(
    'staff_id',pre.staff_id,'display_name',pre.staff_display_name_snapshot,'work_date',pre.work_date,'day_status',pre.day_status,'assignment_type',pre.assignment_type,
    'operational_role_code',pre.operational_role_code_snapshot,'operational_role_name',pre.operational_role_name_snapshot,'area_code',pre.area_code_snapshot,'area_name',pre.area_name_snapshot,
    'station_code',pre.station_code_snapshot,'station_name',pre.station_name_snapshot,'sorting_work_mode',pre.sorting_work_mode,
    'display_section_code',coalesce(pre.display_section_code,public.production_roster_default_display_section(pre.staff_primary_role_code_snapshot,pre.staff_default_station_code_snapshot)),
    'staff_primary_role_code',pre.staff_primary_role_code_snapshot,'staff_primary_role_name',pre.staff_primary_role_name_snapshot,
    'staff_default_area_code',pre.staff_default_area_code_snapshot,'staff_default_area_name',pre.staff_default_area_name_snapshot,
    'staff_default_station_code',pre.staff_default_station_code_snapshot,'staff_default_station_name',pre.staff_default_station_name_snapshot,
    'staff_default_shift_code',coalesce(pre.staff_default_shift_code_snapshot,pre.shift_code_snapshot),'staff_default_shift_name',coalesce(pre.staff_default_shift_name_snapshot,pre.shift_name_snapshot),
    'roster_shift_code',pre.shift_code_snapshot,'roster_shift_name',pre.shift_name_snapshot,'fire_training',pre.fire_training_snapshot,'first_aid_training',pre.first_aid_training_snapshot,'eod_capable',pre.eod_capable_snapshot,'notes',pre.notes
   ) order by pre.work_date,pre.staff_display_name_snapshot) from public.production_roster_entries pre
     where pre.roster_version_id=prv.roster_version_id and (v_administrator or pre.staff_id=v_staff.staff_id)),'[]'::jsonb)) week_json
   from public.production_roster_versions prv join public.roster_periods rp on rp.roster_period_id=prv.roster_period_id
   where prv.shift_id=s.shift_id and prv.status='PUBLISHED' and rp.week_start in(v_current_week,v_current_week+7)
     and (v_administrator or exists(select 1 from public.production_roster_entries pre where pre.roster_version_id=prv.roster_version_id and pre.staff_id=v_staff.staff_id))
 ) published_weeks),'[]'::jsonb)) order by case upper(s.shift_code) when 'MORNING' then 1 when 'EVENING' then 2 else 99 end)
 from public.shifts s where s.active and s.deleted_at is null and upper(s.shift_code) in('MORNING','EVENING')),'[]'::jsonb));
end; $$;

revoke all on function public.get_my_account_roster_portal() from public,anon;
grant execute on function public.get_my_account_roster_portal() to authenticated;
