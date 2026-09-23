-- Keep the Finish terminal attendance wrapper scoped to the selected shift.

begin;

create or replace function public.terminal_set_finish_staff_attendance_v1(
  p_shift_code text,p_staff_id uuid,p_attendance_status text,p_absence_reason text default null,p_notes text default null
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_table_code text; v_shift_id uuid;
begin
  select shift_id into v_shift_id from public.shifts
  where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null
  limit 1;
  if v_shift_id is null then raise exception using errcode='22023',message='Shift must be Morning or Evening.'; end if;
  select coalesce(pre.station_code_snapshot,st.station_code) into v_table_code
  from public.production_roster_entries pre join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
  left join public.stations st on st.station_id=pre.station_id
  where pre.staff_id=p_staff_id and pre.work_date=public.operational_business_date_for_shift(p_shift_code) and prv.status='PUBLISHED'
    and prv.shift_id=v_shift_id and upper(coalesce(pre.area_code_snapshot,''))='FINISH'
  order by prv.version_number desc,prv.published_at desc nulls last limit 1;
  if v_table_code is null then raise exception using errcode='22023',message='This staff member is not planned for a Finish Table in this shift.'; end if;
  perform public.require_production_terminal('FINISH',v_table_code);
  return public.set_finish_staff_attendance_v1(p_shift_code,p_staff_id,p_attendance_status,p_absence_reason,p_notes);
end;
$$;

revoke all on function public.terminal_set_finish_staff_attendance_v1(text,uuid,text,text,text) from public,anon;
grant execute on function public.terminal_set_finish_staff_attendance_v1(text,uuid,text,text,text) to authenticated;

commit;
