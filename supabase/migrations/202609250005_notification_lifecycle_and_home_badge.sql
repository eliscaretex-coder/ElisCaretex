alter table public.staff_notice_recipients add column if not exists archived_at timestamptz;
alter table public.staff_notices alter column expires_at set default (now()+interval '30 days');
update public.staff_notices set expires_at=created_at+interval '30 days' where expires_at is null;

create or replace function public.send_staff_notice(p_title text,p_message text,p_notice_type text default 'INFORMATION',p_acknowledgement_required boolean default false,p_recipient_auth_user_ids uuid[] default null,p_visible_days integer default 30) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare n uuid; c integer; s text; d integer:=greatest(7,least(coalesce(p_visible_days,30),60));
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot send staff notices.'; end if;
 if nullif(btrim(p_title),'') is null or nullif(btrim(p_message),'') is null then raise exception using errcode='22023',message='Title and message are required.'; end if;
 if p_notice_type not in('INFORMATION','ACTION_REQUIRED','TRAINING') then raise exception using errcode='22023',message='Invalid notice type.'; end if;
 select access_scope into s from public.account_permission_grants where auth_user_id=auth.uid() and module_code='NOTIFICATIONS' and active and can_create and current_date between effective_from and coalesce(effective_until,'infinity'::date) order by case access_scope when 'ALL' then 1 when 'PRODUCTION' then 2 else 3 end limit 1;
 insert into public.staff_notices(title,message,notice_type,acknowledgement_required,created_by_auth_user_id,expires_at) values(btrim(p_title),btrim(p_message),p_notice_type,coalesce(p_acknowledgement_required,false),auth.uid(),now()+make_interval(days=>d)) returning notice_id into n;
 insert into public.staff_notice_recipients select n,auth_user_id,null,null,null from public.staff_members where auth_user_id is not null and active and deleted_at is null and (s='ALL' or (s='PRODUCTION' and production_staff)) and (p_recipient_auth_user_ids is null or cardinality(p_recipient_auth_user_ids)=0 or auth_user_id=any(p_recipient_auth_user_ids)) on conflict do nothing;
 get diagnostics c=row_count; if c=0 then raise exception using errcode='22023',message='No eligible active staff were selected.'; end if; return jsonb_build_object('notice_id',n,'recipient_count',c,'visible_days',d); end; $$;

create or replace function public.get_my_notification_summary() returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare u integer; a integer; z integer; t text;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','VIEW',null) then raise exception using errcode='42501',message='Your account cannot view notifications.'; end if;
 select count(*) filter(where r.read_at is null),count(*) filter(where n.acknowledgement_required and r.acknowledged_at is null),count(*) filter(where r.read_at is null or (n.acknowledgement_required and r.acknowledged_at is null)),max(n.title) filter(where n.created_at=(select max(n2.created_at) from public.staff_notice_recipients r2 join public.staff_notices n2 using(notice_id) where r2.auth_user_id=auth.uid() and r2.archived_at is null and n2.expires_at>now()))
 into u,a,z,t from public.staff_notice_recipients r join public.staff_notices n using(notice_id) where r.auth_user_id=auth.uid() and r.archived_at is null and n.expires_at>now();
 return jsonb_build_object('unread_count',coalesce(u,0),'action_count',coalesce(a,0),'attention_count',coalesce(z,0),'latest_title',t); end; $$;

create or replace function public.get_my_staff_notices() returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$ declare v jsonb; u integer; a integer; z integer; begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','VIEW',null) then raise exception using errcode='42501',message='Your account cannot view notifications.'; end if;
 select count(*) filter(where r.read_at is null),count(*) filter(where n.acknowledgement_required and r.acknowledged_at is null),count(*) filter(where r.read_at is null or (n.acknowledgement_required and r.acknowledged_at is null)) into u,a,z from public.staff_notice_recipients r join public.staff_notices n using(notice_id) where r.auth_user_id=auth.uid() and r.archived_at is null and n.expires_at>now();
 select coalesce(jsonb_agg(jsonb_build_object('id','notice-'||n.notice_id,'notice_id',n.notice_id,'kind',n.notice_type,'title',n.title,'message',n.message,'status',case when r.acknowledged_at is not null then 'ACKNOWLEDGED' when n.acknowledgement_required then 'ACTION_REQUIRED' when r.read_at is null then 'NEW' else 'READ' end,'is_new',r.read_at is null,'read_at',r.read_at,'acknowledgement_required',n.acknowledgement_required,'acknowledged_at',r.acknowledged_at,'occurred_at',n.created_at,'expires_at',n.expires_at) order by (n.acknowledgement_required and r.acknowledged_at is null) desc,(r.read_at is null) desc,n.created_at desc),'[]') into v from public.staff_notice_recipients r join public.staff_notices n using(notice_id) where r.auth_user_id=auth.uid() and r.archived_at is null and n.expires_at>now();
 return jsonb_build_object('items',v,'unread_count',coalesce(u,0),'unacknowledged_count',coalesce(a,0),'attention_count',coalesce(z,0),'can_send',public.has_account_permission('NOTIFICATIONS','CREATE',null)); end; $$;

create or replace function public.mark_staff_notice_read(p_notice_id uuid) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$ begin
 if auth.uid() is null then raise exception using errcode='42501',message='Authentication is required.'; end if;
 update public.staff_notice_recipients set read_at=coalesce(read_at,now()) where notice_id=p_notice_id and auth_user_id=auth.uid() and archived_at is null;
 if not found then raise exception using errcode='P0002',message='Notice not found.'; end if; return jsonb_build_object('notice_id',p_notice_id,'read',true); end; $$;

create or replace function public.archive_staff_notice(p_notice_id uuid) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$ begin
 if auth.uid() is null then raise exception using errcode='42501',message='Authentication is required.'; end if;
 update public.staff_notice_recipients set archived_at=now() where notice_id=p_notice_id and auth_user_id=auth.uid() and read_at is not null and (acknowledged_at is not null or not exists(select 1 from public.staff_notices n where n.notice_id=p_notice_id and n.acknowledgement_required));
 if not found then raise exception using errcode='55000',message='Read or acknowledge this notice before archiving it.'; end if; return jsonb_build_object('notice_id',p_notice_id,'archived',true); end; $$;

revoke all on function public.get_my_notification_summary(),public.mark_staff_notice_read(uuid),public.archive_staff_notice(uuid),public.send_staff_notice(text,text,text,boolean,uuid[],integer) from public,anon;
grant execute on function public.get_my_notification_summary(),public.mark_staff_notice_read(uuid),public.archive_staff_notice(uuid),public.send_staff_notice(text,text,text,boolean,uuid[],integer) to authenticated;
