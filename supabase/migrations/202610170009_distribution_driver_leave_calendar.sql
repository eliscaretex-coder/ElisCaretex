begin;

create or replace function public.get_distribution_driver_leave_calendar(
  p_from date default current_date,
  p_months integer default 12
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_from date:=coalesce(p_from,current_date);
  v_months integer:=greatest(1,least(coalesce(p_months,12),24));
  v_until date;
begin
  if not public.can_manage_driver_guides() then
    raise exception using errcode='42501',message='Distribution management access is required.';
  end if;
  v_until:=(date_trunc('month',v_from)::date+(v_months||' months')::interval-interval '1 day')::date;
  return jsonb_build_object(
    'from_date',v_from,
    'until_date',v_until,
    'drivers',coalesce((
      select jsonb_agg(jsonb_build_object('driver_id',d.driver_id,'driver_code',d.driver_code,'display_name',d.display_name) order by d.display_name)
      from public.distribution_drivers d
      where d.deleted_at is null and d.employment_status='ACTIVE' and not d.roster_hidden
    ),'[]'::jsonb),
    'pending',coalesce((
      select jsonb_agg(to_jsonb(a)||jsonb_build_object('driver_name',d.display_name,'driver_code',d.driver_code,'published_roster_conflict',exists(
        select 1 from public.distribution_roster_entries e
        join public.distribution_roster_versions v on v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='PUBLISHED'
        where e.work_date between a.starts_on and a.ends_on and d.driver_id in(e.primary_driver_id,e.support_driver_id)
      )) order by a.created_at)
      from public.distribution_driver_absences a
      join public.distribution_drivers d on d.driver_id=a.driver_id
      where a.absence_status='REQUESTED'
    ),'[]'::jsonb),
    'approved',coalesce((
      select jsonb_agg(to_jsonb(a)||jsonb_build_object('driver_name',d.display_name,'driver_code',d.driver_code) order by a.starts_on,d.display_name)
      from public.distribution_driver_absences a
      join public.distribution_drivers d on d.driver_id=a.driver_id
      where a.absence_status='APPROVED' and a.starts_on<=v_until and a.ends_on>=date_trunc('month',v_from)::date
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.save_distribution_driver_leave_admin(p_absence jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_id uuid:=nullif(p_absence->>'absence_id','')::uuid;
  v_driver uuid:=nullif(p_absence->>'driver_id','')::uuid;
  v_type text:=upper(coalesce(nullif(trim(p_absence->>'absence_type'),''),'HOLIDAY'));
  v_start date:=nullif(p_absence->>'starts_on','')::date;
  v_end date:=nullif(p_absence->>'ends_on','')::date;
  v_row public.distribution_driver_absences%rowtype;
begin
  if not public.can_manage_driver_guides() then
    raise exception using errcode='42501',message='Distribution management access is required.';
  end if;
  if v_driver is null or not exists(select 1 from public.distribution_drivers where driver_id=v_driver and deleted_at is null) then
    raise exception using errcode='22023',message='Choose an active driver.';
  end if;
  if v_type not in('HOLIDAY','DAY_OFF') then
    raise exception using errcode='22023',message='Leave type must be Holiday or Day off.';
  end if;
  if v_start is null or v_end is null or v_end<v_start then
    raise exception using errcode='22023',message='Enter a valid leave date range.';
  end if;
  if exists(
    select 1 from public.distribution_driver_absences a
    where a.driver_id=v_driver and a.absence_status in('REQUESTED','APPROVED')
      and a.absence_id is distinct from v_id and a.starts_on<=v_end and a.ends_on>=v_start
  ) then
    raise exception using errcode='23505',message='Another pending or approved leave already covers part of these dates.';
  end if;

  insert into public.distribution_driver_absences(absence_id,driver_id,absence_type,starts_on,ends_on,absence_status,notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),v_driver,v_type,v_start,v_end,'APPROVED',nullif(trim(p_absence->>'notes'),''),auth.uid(),auth.uid())
  on conflict(absence_id) do update set
    driver_id=excluded.driver_id,absence_type=excluded.absence_type,starts_on=excluded.starts_on,ends_on=excluded.ends_on,
    absence_status='APPROVED',notes=excluded.notes,updated_at=now(),updated_by=auth.uid(),row_version=public.distribution_driver_absences.row_version+1
  returning * into v_row;

  update public.distribution_roster_entries e set
    support_driver_id=null,support_driver_name_snapshot=null,updated_at=now(),updated_by=auth.uid(),row_version=e.row_version+1
  from public.distribution_roster_versions v
  where v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='DRAFT'
    and e.support_driver_id=v_driver and e.primary_driver_id is distinct from v_driver and e.work_date between v_start and v_end;

  delete from public.distribution_roster_entries e using public.distribution_roster_versions v
  where v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='DRAFT'
    and e.primary_driver_id=v_driver and e.work_date between v_start and v_end;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.review_driver_leave_request(p_absence_id uuid,p_decision text)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_row public.distribution_driver_absences%rowtype;
  v_decision text:=upper(trim(p_decision));
begin
  if not public.can_manage_driver_guides() then
    raise exception using errcode='42501',message='Distribution management access is required.';
  end if;
  if v_decision not in('APPROVED','REJECTED') then
    raise exception using errcode='22023',message='Decision must be Approved or Rejected.';
  end if;
  update public.distribution_driver_absences set
    absence_status=v_decision,updated_by=auth.uid(),updated_at=now(),row_version=row_version+1
  where absence_id=p_absence_id and absence_status='REQUESTED'
  returning * into v_row;
  if not found then
    raise exception using errcode='P0002',message='Pending driver request was not found.';
  end if;
  if v_decision='APPROVED' then
    update public.distribution_roster_entries e set
      support_driver_id=null,support_driver_name_snapshot=null,updated_at=now(),updated_by=auth.uid(),row_version=e.row_version+1
    from public.distribution_roster_versions v
    where v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='DRAFT'
      and e.support_driver_id=v_row.driver_id and e.primary_driver_id is distinct from v_row.driver_id
      and e.work_date between v_row.starts_on and v_row.ends_on;
    delete from public.distribution_roster_entries e using public.distribution_roster_versions v
    where v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='DRAFT'
      and e.primary_driver_id=v_row.driver_id and e.work_date between v_row.starts_on and v_row.ends_on;
  end if;
  return to_jsonb(v_row);
end;
$$;

create or replace function public.delete_distribution_driver_leave_admin(p_absence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare v_row public.distribution_driver_absences%rowtype;
begin
  if not public.can_manage_driver_guides() then
    raise exception using errcode='42501',message='Distribution management access is required.';
  end if;
  delete from public.distribution_driver_absences
  where absence_id=p_absence_id and absence_status in('APPROVED','REJECTED','CANCELLED')
  returning * into v_row;
  if not found then raise exception using errcode='P0002',message='Driver leave was not found or still awaits a decision.'; end if;
  return to_jsonb(v_row);
end;
$$;

revoke all on function public.get_distribution_driver_leave_calendar(date,integer),public.save_distribution_driver_leave_admin(jsonb),public.delete_distribution_driver_leave_admin(uuid) from public,anon;
grant execute on function public.get_distribution_driver_leave_calendar(date,integer),public.save_distribution_driver_leave_admin(jsonb),public.delete_distribution_driver_leave_admin(uuid) to authenticated;

commit;
