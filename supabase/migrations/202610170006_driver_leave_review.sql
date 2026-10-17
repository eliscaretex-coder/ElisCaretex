begin;
create or replace function public.get_driver_leave_requests_admin()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
 if not public.can_manage_driver_guides() then raise exception using errcode='42501',message='Distribution management access is required.'; end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by case x.absence_status when 'REQUESTED' then 0 else 1 end,x.created_at desc) from (
  select a.*,d.display_name as driver_name,d.driver_code,exists(
   select 1 from public.distribution_roster_entries e join public.distribution_roster_versions v on v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='PUBLISHED'
   where e.work_date between a.starts_on and a.ends_on and d.driver_id in(e.primary_driver_id,e.support_driver_id)
  ) as published_roster_conflict
  from public.distribution_driver_absences a join public.distribution_drivers d on d.driver_id=a.driver_id where a.created_at>=now()-interval '12 months'
 ) x),'[]'::jsonb);
end;$$;
create or replace function public.review_driver_leave_request(p_absence_id uuid,p_decision text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.distribution_driver_absences%rowtype; v_decision text:=upper(trim(p_decision));
begin
 if not public.can_manage_driver_guides() then raise exception using errcode='42501',message='Distribution management access is required.'; end if;
 if v_decision not in('APPROVED','REJECTED') then raise exception using errcode='22023',message='Decision must be Approved or Rejected.'; end if;
 update public.distribution_driver_absences set absence_status=v_decision,updated_by=auth.uid(),updated_at=now(),row_version=row_version+1 where absence_id=p_absence_id and absence_status='REQUESTED' returning * into v_row;
 if not found then raise exception using errcode='P0002',message='Pending driver request was not found.'; end if; return to_jsonb(v_row);
end;$$;
revoke all on function public.get_driver_leave_requests_admin(),public.review_driver_leave_request(uuid,text) from public,anon;
grant execute on function public.get_driver_leave_requests_admin(),public.review_driver_leave_request(uuid,text) to authenticated;
commit;
