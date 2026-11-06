-- Production computers sign in with their Computer name.
--
-- Until now the technical sign-in email of a production computer was built from its
-- Computer code (FINISH-T2-PC01 -> finish-t2-pc01@terminal.eliscaretex.local). The owner
-- wants the operator to type the Computer name instead (for example TABLE2_PC1).
--
-- The sign-in name is the Computer name in lower case with every run of characters other
-- than a-z and 0-9 replaced by "-" (TABLE2_PC1 -> table2-pc1). The login screen applies the
-- same rule, so TABLE2_PC1, table2_pc1 and "Table2 PC1" all work.
--
-- A trigger keeps the auth email in step with the Computer name whenever a computer is
-- created, renamed or re-bound. It only ever touches accounts whose email is already a
-- technical @terminal.eliscaretex.local address, so it can never take over a personal
-- account. Nothing is exposed to the browser: no new grants to anon or authenticated, and
-- the directory still returns only masked emails.

create or replace function public.production_computer_sign_in_name(p_device_name text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select btrim(regexp_replace(lower(coalesce(p_device_name, '')), '[^a-z0-9]+', '-', 'g'), '-');
$$;

revoke all on function public.production_computer_sign_in_name(text) from public, anon, authenticated;
grant execute on function public.production_computer_sign_in_name(text) to service_role;

alter table public.production_station_devices
  drop constraint if exists production_station_devices_sign_in_name_check;
alter table public.production_station_devices
  add constraint production_station_devices_sign_in_name_check
  check (length(public.production_computer_sign_in_name(device_name)) between 1 and 64);

-- Two computers may not share a sign-in name (TABLE2_PC1 and table2-pc1 collide).
create unique index if not exists production_station_devices_sign_in_name_key
  on public.production_station_devices (public.production_computer_sign_in_name(device_name));

create or replace function public.sync_production_computer_sign_in_email(p_auth_user_id uuid, p_device_name text)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_email text := public.production_computer_sign_in_name(p_device_name) || '@terminal.eliscaretex.local';
begin
  if p_auth_user_id is null then
    return;
  end if;

  if exists (select 1 from auth.users u where lower(u.email) = v_email and u.id <> p_auth_user_id) then
    raise exception 'Another account already signs in as "%". Choose a different computer name.', p_device_name
      using errcode = 'unique_violation';
  end if;

  update auth.users u
  set email = v_email, updated_at = now()
  where u.id = p_auth_user_id
    and lower(u.email) like '%@terminal.eliscaretex.local'
    and u.email is distinct from v_email;

  if found then
    update auth.identities i
    set identity_data = jsonb_set(i.identity_data, '{email}', to_jsonb(v_email)), updated_at = now()
    where i.user_id = p_auth_user_id and i.provider = 'email';
  end if;
end;
$$;

revoke all on function public.sync_production_computer_sign_in_email(uuid, text) from public, anon, authenticated;

create or replace function public.production_station_devices_sync_sign_in()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.sync_production_computer_sign_in_email(new.device_auth_user_id, new.device_name);
  return new;
end;
$$;

revoke all on function public.production_station_devices_sync_sign_in() from public, anon, authenticated;

drop trigger if exists production_station_devices_sync_sign_in on public.production_station_devices;
create trigger production_station_devices_sync_sign_in
after insert or update of device_name, device_auth_user_id on public.production_station_devices
for each row execute function public.production_station_devices_sync_sign_in();

-- Bring existing computers in line (only FINISH-T2-PC01 / TABLE2_PC1 changes today; the
-- others already have Computer name = Computer code).
do $$
declare
  r record;
begin
  for r in select device_auth_user_id, device_name from public.production_station_devices where device_auth_user_id is not null loop
    perform public.sync_production_computer_sign_in_email(r.device_auth_user_id, r.device_name);
  end loop;
end;
$$;
