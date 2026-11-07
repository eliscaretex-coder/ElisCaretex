-- =====================================================================
-- ElisCaretex V2
-- Notices to drivers (Distribution supervisor / manager -> drivers)
--
-- Owner request 2026-11-07: a Distribution supervisor or manager must be able
-- to send a notice straight to the drivers.
--
-- Reuses the existing staff notices (Notifications page, 202609250003 to
-- 202609250005): same tables, same inbox, read and acknowledgement receipts.
-- What changes:
-- * DRIVER job title: Notifications VIEW (own inbox), so a driver with a
--   sign-in sees the notices, the sidebar badge and the Home badge.
-- * LOGISTICS_MANAGER job title: Notifications VIEW/CREATE with scope
--   DISTRIBUTION (sends to drivers only).
-- * Who a sender can reach (one helper, used by the options and the send):
--     ALL scope            -> every active linked staff member (as before);
--     PRODUCTION scope     -> production staff (as before);
--     DISTRIBUTION scope,
--     or Distribution EDIT -> plus the active Distribution drivers.
--   A driver is reachable only when the driver record is linked to a Staff
--   Master record with a sign-in (current_distribution_driver_id rule).
-- * get_notification_recipient_options returns is_driver per person and the
--   number of active drivers without a sign-in, so the page can say who will
--   not receive the notice.
-- Function signatures do not change.
-- =====================================================================

begin;

-- Permissions ------------------------------------------------------------

insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) values
 ('DRIVER','NOTIFICATIONS','OWN',true,false,false,false,false),
 ('LOGISTICS_MANAGER','NOTIFICATIONS','DISTRIBUTION',true,true,true,false,false)
on conflict(job_title_code,module_code) do update set
 access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,can_edit=excluded.can_edit;

-- Existing accounts with these titles get the new module (other grants untouched).
insert into public.account_permission_grants(auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
select ap.auth_user_id,t.module_code,t.access_scope,t.can_view,t.can_create,t.can_edit,t.can_approve,t.can_manage
from public.account_access_profiles ap
join public.job_title_permission_templates t on t.job_title_code=ap.job_title_code and t.module_code='NOTIFICATIONS'
where ap.job_title_code in('DRIVER','LOGISTICS_MANAGER') and ap.account_type='USER'
on conflict(auth_user_id,module_code) do nothing;

-- Linked drivers whose sign-in has another job title (or none) can read their inbox too.
insert into public.account_permission_grants(auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
select distinct sm.auth_user_id,'NOTIFICATIONS','OWN',true,false,false,false,false
from public.distribution_drivers d
join public.staff_members sm on sm.staff_id=d.staff_id
where d.deleted_at is null and d.employment_status='ACTIVE'
  and sm.auth_user_id is not null and sm.active and sm.deleted_at is null
  and not exists(select 1 from public.production_station_devices x where x.device_auth_user_id=sm.auth_user_id)
on conflict(auth_user_id,module_code) do nothing;

-- Sender scope -----------------------------------------------------------

-- The widest Notifications CREATE scope of the signed-in account (Administrator = ALL).
create or replace function public.staff_notice_sender_scope()
returns text language sql stable security definer set search_path=public,auth,pg_temp as $$
  select case when public.has_any_role(array['ADMIN']) then 'ALL' else (
    select g.access_scope from public.account_permission_grants g
    where g.auth_user_id=auth.uid() and g.module_code='NOTIFICATIONS' and g.active and (g.can_create or g.can_manage)
      and current_date between g.effective_from and coalesce(g.effective_until,'infinity'::date)
    order by case g.access_scope when 'ALL' then 1 when 'PRODUCTION' then 2 when 'DISTRIBUTION' then 3 else 4 end limit 1) end
$$;
revoke all on function public.staff_notice_sender_scope() from public,anon,authenticated;

-- Can the signed-in sender reach the drivers?
create or replace function public.staff_notice_sender_reaches_drivers()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select auth.uid() is not null and public.has_account_permission('NOTIFICATIONS','CREATE',null)
     and (public.staff_notice_sender_scope() in('ALL','DISTRIBUTION') or public.has_account_permission('DISTRIBUTION','EDIT',null))
$$;
revoke all on function public.staff_notice_sender_reaches_drivers() from public,anon,authenticated;

-- Everyone the signed-in sender may send a notice to.
create or replace function public.staff_notice_eligible_recipients()
returns table(auth_user_id uuid,display_name text,employee_code text,is_driver boolean)
language sql stable security definer set search_path=public,auth,pg_temp as $$
  with ctx as (select public.staff_notice_sender_scope() as s,public.staff_notice_sender_reaches_drivers() as drivers)
  select distinct on (sm.auth_user_id) sm.auth_user_id,
         coalesce(d.display_name,sm.display_name),
         coalesce(d.driver_code,sm.employee_code),
         d.driver_id is not null
  from public.staff_members sm
  cross join ctx
  left join lateral (
    select dd.driver_id,dd.display_name,dd.driver_code from public.distribution_drivers dd
    where dd.staff_id=sm.staff_id and dd.deleted_at is null and dd.employment_status='ACTIVE' limit 1
  ) d on true
  where sm.auth_user_id is not null and sm.active and sm.deleted_at is null
    and (ctx.s='ALL' or (ctx.s='PRODUCTION' and sm.production_staff) or (ctx.drivers and d.driver_id is not null))
  order by sm.auth_user_id
$$;
revoke all on function public.staff_notice_eligible_recipients() from public,anon,authenticated;

-- RPCs (same signatures) -------------------------------------------------

create or replace function public.get_notification_recipient_options()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v jsonb; s text; r boolean; nl integer:=0; nt integer:=0;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot send staff notices.'; end if;
 s:=public.staff_notice_sender_scope(); r:=public.staff_notice_sender_reaches_drivers();
 select coalesce(jsonb_agg(jsonb_build_object('auth_user_id',e.auth_user_id,'name',e.display_name,'employee_code',e.employee_code,'is_driver',e.is_driver) order by e.is_driver desc,e.display_name),'[]') into v
 from public.staff_notice_eligible_recipients() e;
 if r then
   select count(*),count(*) filter(where not exists(
     select 1 from public.staff_members sm where sm.staff_id=d.staff_id and sm.auth_user_id is not null and sm.active and sm.deleted_at is null))
   into nt,nl from public.distribution_drivers d where d.deleted_at is null and d.employment_status='ACTIVE';
 end if;
 return jsonb_build_object('items',v,'scope',s,'can_reach_drivers',r,'active_driver_count',nt,'drivers_without_sign_in',nl);
end; $$;

create or replace function public.send_staff_notice(p_title text,p_message text,p_notice_type text default 'INFORMATION',p_acknowledgement_required boolean default false,p_recipient_auth_user_ids uuid[] default null,p_visible_days integer default 30)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare n uuid; c integer; d integer:=greatest(7,least(coalesce(p_visible_days,30),60));
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot send staff notices.'; end if;
 if nullif(btrim(p_title),'') is null or nullif(btrim(p_message),'') is null then raise exception using errcode='22023',message='Title and message are required.'; end if;
 if p_notice_type not in('INFORMATION','ACTION_REQUIRED','TRAINING') then raise exception using errcode='22023',message='Invalid notice type.'; end if;
 insert into public.staff_notices(title,message,notice_type,acknowledgement_required,created_by_auth_user_id,expires_at)
 values(btrim(p_title),btrim(p_message),p_notice_type,coalesce(p_acknowledgement_required,false),auth.uid(),now()+make_interval(days=>d)) returning notice_id into n;
 insert into public.staff_notice_recipients(notice_id,auth_user_id)
 select n,e.auth_user_id from public.staff_notice_eligible_recipients() e
 where p_recipient_auth_user_ids is null or cardinality(p_recipient_auth_user_ids)=0 or e.auth_user_id=any(p_recipient_auth_user_ids)
 on conflict do nothing;
 get diagnostics c=row_count;
 if c=0 then raise exception using errcode='22023',message='No eligible active staff were selected.'; end if;
 return jsonb_build_object('notice_id',n,'recipient_count',c,'visible_days',d);
end; $$;

revoke all on function public.get_notification_recipient_options(),public.send_staff_notice(text,text,text,boolean,uuid[],integer) from public,anon;
grant execute on function public.get_notification_recipient_options(),public.send_staff_notice(text,text,text,boolean,uuid[],integer) to authenticated;

commit;
