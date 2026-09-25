-- Manager/supervisor notice dashboard and production-scoped recipients.
update public.job_title_permission_templates
set can_create=true,can_edit=true
where module_code='NOTIFICATIONS' and job_title_code in('PRODUCTION_SUPERVISOR','PRODUCTION_MANAGER','GENERAL_MANAGER');

update public.account_permission_grants g set can_create=true,can_edit=true,updated_at=now()
from public.account_access_profiles p
where p.auth_user_id=g.auth_user_id and g.module_code='NOTIFICATIONS'
  and p.job_title_code in('PRODUCTION_SUPERVISOR','PRODUCTION_MANAGER','GENERAL_MANAGER');

create or replace function public.get_notification_recipient_options() returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v jsonb; s text;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot send staff notices.'; end if;
 select access_scope into s from public.account_permission_grants where auth_user_id=auth.uid() and module_code='NOTIFICATIONS' and active and can_create and current_date between effective_from and coalesce(effective_until,'infinity'::date) order by case access_scope when 'ALL' then 1 when 'PRODUCTION' then 2 else 3 end limit 1;
 select coalesce(jsonb_agg(jsonb_build_object('auth_user_id',auth_user_id,'name',display_name,'employee_code',employee_code) order by display_name),'[]') into v
 from public.staff_members where auth_user_id is not null and active and deleted_at is null and (s='ALL' or (s='PRODUCTION' and production_staff));
 return jsonb_build_object('items',v,'scope',s); end; $$;

create or replace function public.send_staff_notice(p_title text,p_message text,p_notice_type text default 'INFORMATION',p_acknowledgement_required boolean default false,p_recipient_auth_user_ids uuid[] default null) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare n uuid; c integer; s text;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot send staff notices.'; end if;
 if nullif(btrim(p_title),'') is null or nullif(btrim(p_message),'') is null then raise exception using errcode='22023',message='Title and message are required.'; end if;
 if p_notice_type not in('INFORMATION','ACTION_REQUIRED','TRAINING') then raise exception using errcode='22023',message='Invalid notice type.'; end if;
 select access_scope into s from public.account_permission_grants where auth_user_id=auth.uid() and module_code='NOTIFICATIONS' and active and can_create and current_date between effective_from and coalesce(effective_until,'infinity'::date) order by case access_scope when 'ALL' then 1 when 'PRODUCTION' then 2 else 3 end limit 1;
 insert into public.staff_notices(title,message,notice_type,acknowledgement_required,created_by_auth_user_id) values(btrim(p_title),btrim(p_message),p_notice_type,coalesce(p_acknowledgement_required,false),auth.uid()) returning notice_id into n;
 insert into public.staff_notice_recipients select n,auth_user_id,null,null from public.staff_members where auth_user_id is not null and active and deleted_at is null and (s='ALL' or (s='PRODUCTION' and production_staff)) and (p_recipient_auth_user_ids is null or cardinality(p_recipient_auth_user_ids)=0 or auth_user_id=any(p_recipient_auth_user_ids)) on conflict do nothing;
 get diagnostics c=row_count; if c=0 then raise exception using errcode='22023',message='No eligible active staff were selected.'; end if; return jsonb_build_object('notice_id',n,'recipient_count',c); end; $$;

create or replace function public.get_sent_staff_notices() returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v jsonb; m boolean;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot manage staff notices.'; end if;
 m:=public.has_account_permission('NOTIFICATIONS','MANAGE',null);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into v from(
  select n.notice_id,n.title,n.message,n.notice_type,n.acknowledgement_required,n.created_at,coalesce(p.display_name,u.email,'System user') created_by,
   count(r.*)::int recipient_count,count(*) filter(where r.read_at is not null)::int read_count,count(*) filter(where r.acknowledged_at is not null)::int acknowledged_count,
   count(*) filter(where r.read_at is null)::int unopened_count
  from public.staff_notices n join public.staff_notice_recipients r using(notice_id) left join public.account_access_profiles p on p.auth_user_id=n.created_by_auth_user_id left join auth.users u on u.id=n.created_by_auth_user_id
  where m or n.created_by_auth_user_id=auth.uid() group by n.notice_id,p.display_name,u.email order by n.created_at desc limit 50
 )x; return jsonb_build_object('items',v,'can_manage_all',m); end; $$;

create or replace function public.get_staff_notice_receipts(p_notice_id uuid) returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v jsonb; n public.staff_notices; m boolean;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot manage staff notices.'; end if;
 select * into n from public.staff_notices where notice_id=p_notice_id; m:=public.has_account_permission('NOTIFICATIONS','MANAGE',null);
 if n.notice_id is null or (not m and n.created_by_auth_user_id<>auth.uid()) then raise exception using errcode='42501',message='You cannot view this notice.'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('name',coalesce(sm.display_name,p.display_name,u.email),'employee_code',sm.employee_code,'read_at',r.read_at,'acknowledged_at',r.acknowledged_at,'status',case when r.acknowledged_at is not null then 'ACKNOWLEDGED' when r.read_at is not null then case when n.acknowledgement_required then 'AWAITING_ACKNOWLEDGEMENT' else 'READ' end else 'NOT_OPENED' end) order by coalesce(sm.display_name,p.display_name,u.email)),'[]') into v
 from public.staff_notice_recipients r left join public.staff_members sm on sm.auth_user_id=r.auth_user_id left join public.account_access_profiles p on p.auth_user_id=r.auth_user_id left join auth.users u on u.id=r.auth_user_id where r.notice_id=p_notice_id;
 return jsonb_build_object('notice_id',p_notice_id,'items',v); end; $$;

revoke all on function public.get_sent_staff_notices(),public.get_staff_notice_receipts(uuid) from public,anon;
grant execute on function public.get_sent_staff_notices(),public.get_staff_notice_receipts(uuid) to authenticated;
