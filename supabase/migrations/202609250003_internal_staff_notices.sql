create table if not exists public.staff_notices(notice_id uuid primary key default gen_random_uuid(),title text not null check(char_length(btrim(title)) between 3 and 120),message text not null check(char_length(btrim(message)) between 3 and 2000),notice_type text not null default 'INFORMATION' check(notice_type in('INFORMATION','ACTION_REQUIRED','TRAINING')),acknowledgement_required boolean not null default false,created_by_auth_user_id uuid not null references auth.users(id),created_at timestamptz not null default now(),expires_at timestamptz);
create table if not exists public.staff_notice_recipients(notice_id uuid not null references public.staff_notices(notice_id) on delete cascade,auth_user_id uuid not null references auth.users(id) on delete cascade,read_at timestamptz,acknowledged_at timestamptz,primary key(notice_id,auth_user_id));
create index if not exists staff_notice_recipients_user_idx on public.staff_notice_recipients(auth_user_id,read_at,acknowledged_at);
alter table public.staff_notices enable row level security; alter table public.staff_notice_recipients enable row level security;
revoke all on public.staff_notices,public.staff_notice_recipients from public,anon,authenticated;

create or replace function public.get_notification_recipient_options() returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$ declare v jsonb; begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot send staff notices.'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('auth_user_id',auth_user_id,'name',display_name,'employee_code',employee_code) order by display_name),'[]') into v from public.staff_members where auth_user_id is not null and active and deleted_at is null;
 return jsonb_build_object('items',v); end; $$;

create or replace function public.send_staff_notice(p_title text,p_message text,p_notice_type text default 'INFORMATION',p_acknowledgement_required boolean default false,p_recipient_auth_user_ids uuid[] default null) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$ declare n uuid; c integer; begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot send staff notices.'; end if;
 if nullif(btrim(p_title),'') is null or nullif(btrim(p_message),'') is null then raise exception using errcode='22023',message='Title and message are required.'; end if;
 if p_notice_type not in('INFORMATION','ACTION_REQUIRED','TRAINING') then raise exception using errcode='22023',message='Invalid notice type.'; end if;
 insert into public.staff_notices(title,message,notice_type,acknowledgement_required,created_by_auth_user_id) values(btrim(p_title),btrim(p_message),p_notice_type,coalesce(p_acknowledgement_required,false),auth.uid()) returning notice_id into n;
 insert into public.staff_notice_recipients select n,auth_user_id,null,null from public.staff_members where auth_user_id is not null and active and deleted_at is null and (p_recipient_auth_user_ids is null or cardinality(p_recipient_auth_user_ids)=0 or auth_user_id=any(p_recipient_auth_user_ids)) on conflict do nothing;
 get diagnostics c=row_count; if c=0 then raise exception using errcode='22023',message='No active linked staff were selected.'; end if; return jsonb_build_object('notice_id',n,'recipient_count',c); end; $$;

create or replace function public.acknowledge_staff_notice(p_notice_id uuid) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$ begin
 if auth.uid() is null then raise exception using errcode='42501',message='Authentication is required.'; end if;
 update public.staff_notice_recipients set read_at=coalesce(read_at,now()),acknowledged_at=coalesce(acknowledged_at,now()) where notice_id=p_notice_id and auth_user_id=auth.uid();
 if not found then raise exception using errcode='P0002',message='Notice not found.'; end if; return jsonb_build_object('notice_id',p_notice_id); end; $$;

create or replace function public.get_my_staff_notices() returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$ declare v jsonb; u integer; begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','VIEW',null) then raise exception using errcode='42501',message='Your account cannot view notifications.'; end if;
 update public.staff_notice_recipients set read_at=coalesce(read_at,now()) where auth_user_id=auth.uid();
 select count(*) into u from public.staff_notice_recipients r join public.staff_notices n using(notice_id) where r.auth_user_id=auth.uid() and n.acknowledgement_required and r.acknowledged_at is null and (n.expires_at is null or n.expires_at>now());
 select coalesce(jsonb_agg(jsonb_build_object('id','notice-'||n.notice_id,'notice_id',n.notice_id,'kind',n.notice_type,'title',n.title,'message',n.message,'status',case when r.acknowledged_at is not null then 'ACKNOWLEDGED' when n.acknowledgement_required then 'ACKNOWLEDGEMENT_REQUIRED' else 'READ' end,'acknowledgement_required',n.acknowledgement_required,'acknowledged_at',r.acknowledged_at,'occurred_at',n.created_at) order by n.created_at desc),'[]') into v from public.staff_notice_recipients r join public.staff_notices n using(notice_id) where r.auth_user_id=auth.uid() and (n.expires_at is null or n.expires_at>now());
 return jsonb_build_object('items',v,'unacknowledged_count',u,'can_send',public.has_account_permission('NOTIFICATIONS','CREATE',null)); end; $$;
revoke all on function public.get_notification_recipient_options(),public.send_staff_notice(text,text,text,boolean,uuid[]),public.acknowledge_staff_notice(uuid),public.get_my_staff_notices() from public,anon;
grant execute on function public.get_notification_recipient_options(),public.send_staff_notice(text,text,text,boolean,uuid[]),public.acknowledge_staff_notice(uuid),public.get_my_staff_notices() to authenticated;
