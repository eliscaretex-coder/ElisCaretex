create table if not exists public.staff_notice_sender_preferences(
 notice_id uuid not null references public.staff_notices(notice_id) on delete cascade,
 auth_user_id uuid not null references auth.users(id) on delete cascade,
 hidden_at timestamptz,
 primary key(notice_id,auth_user_id)
);
alter table public.staff_notice_sender_preferences enable row level security;
revoke all on public.staff_notice_sender_preferences from public,anon,authenticated;

create or replace function public.get_sent_staff_notices() returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v jsonb; m boolean; h integer;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot manage staff notices.'; end if;
 m:=public.has_account_permission('NOTIFICATIONS','MANAGE',null);
 select count(*) into h from public.staff_notice_sender_preferences where auth_user_id=auth.uid() and hidden_at is not null;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into v from(
  select n.notice_id,n.title,n.message,n.notice_type,n.acknowledgement_required,n.created_at,n.expires_at,coalesce(p.display_name,u.email,'System user') created_by,
   count(r.*)::int recipient_count,count(*) filter(where r.read_at is not null)::int read_count,count(*) filter(where r.acknowledged_at is not null)::int acknowledged_count,count(*) filter(where r.read_at is null)::int unopened_count
  from public.staff_notices n join public.staff_notice_recipients r using(notice_id) left join public.account_access_profiles p on p.auth_user_id=n.created_by_auth_user_id left join auth.users u on u.id=n.created_by_auth_user_id
  left join public.staff_notice_sender_preferences sp on sp.notice_id=n.notice_id and sp.auth_user_id=auth.uid() and sp.hidden_at is not null
  where (m or n.created_by_auth_user_id=auth.uid()) and sp.notice_id is null group by n.notice_id,p.display_name,u.email order by n.created_at desc limit 50
 )x; return jsonb_build_object('items',v,'can_manage_all',m,'hidden_count',h); end; $$;

create or replace function public.hide_sent_staff_notice(p_notice_id uuid) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare n public.staff_notices; m boolean;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot manage staff notices.'; end if;
 select * into n from public.staff_notices where notice_id=p_notice_id; m:=public.has_account_permission('NOTIFICATIONS','MANAGE',null);
 if n.notice_id is null or (not m and n.created_by_auth_user_id<>auth.uid()) then raise exception using errcode='42501',message='You cannot hide this notice.'; end if;
 insert into public.staff_notice_sender_preferences(notice_id,auth_user_id,hidden_at) values(p_notice_id,auth.uid(),now()) on conflict(notice_id,auth_user_id) do update set hidden_at=excluded.hidden_at;
 return jsonb_build_object('notice_id',p_notice_id,'hidden',true); end; $$;

create or replace function public.restore_sent_staff_notice(p_notice_id uuid) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot manage staff notices.'; end if;
 update public.staff_notice_sender_preferences set hidden_at=null where notice_id=p_notice_id and auth_user_id=auth.uid();
 if not found then raise exception using errcode='P0002',message='Hidden notice preference not found.'; end if;
 return jsonb_build_object('notice_id',p_notice_id,'restored',true); end; $$;

revoke all on function public.hide_sent_staff_notice(uuid),public.restore_sent_staff_notice(uuid) from public,anon;
grant execute on function public.hide_sent_staff_notice(uuid),public.restore_sent_staff_notice(uuid) to authenticated;
