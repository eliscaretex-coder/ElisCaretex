-- Fixed computer access for Finish and Sorting.
-- Staff attribution is supplied by the existing Roster/Actual workflow.

create table if not exists public.production_station_devices (
  station_device_id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(station_id) on delete restrict,
  device_code text not null unique,
  device_name text not null,
  device_auth_user_id uuid not null unique references auth.users(id) on delete restrict,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.production_station_devices enable row level security;
revoke all on public.production_station_devices from anon, authenticated;

create or replace function public.production_station_device_context(p_area_code text default null)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce((
    select jsonb_build_object(
      'device_code',psd.device_code,
      'device_name',psd.device_name,
      'station_code',s.station_code,
      'station_name',s.station_name,
      'area_code',a.area_code
    )
    from public.production_station_devices psd
    join public.stations s on s.station_id=psd.station_id and s.active=true and s.deleted_at is null
    join public.areas a on a.area_id=s.area_id and a.active=true and a.deleted_at is null
    where psd.device_auth_user_id=auth.uid() and psd.active=true
      and (p_area_code is null or upper(a.area_code)=upper(trim(p_area_code)))
    limit 1
  ),'{}'::jsonb);
$$;

create or replace function public.require_production_terminal(p_area_code text,p_station_code text default null)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_terminal jsonb := public.production_station_device_context(p_area_code);
begin
  if auth.uid() is null then
    raise exception using errcode='28000', message='This production terminal is not signed in.';
  end if;
  if coalesce(v_terminal->>'device_code','')='' then
    raise exception using errcode='42501', message='This signed-in account is not registered as this production terminal.';
  end if;
  if p_station_code is not null and upper(v_terminal->>'station_code')<>upper(trim(p_station_code)) then
    raise exception using errcode='42501', message='This terminal is registered for another production station.';
  end if;
end;
$$;

create or replace function public.get_production_terminal_context(p_area_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare v_terminal jsonb := public.production_station_device_context(p_area_code);
begin
  if coalesce(v_terminal->>'device_code','')='' then
    raise exception using errcode='42501', message='This signed-in account is not registered to this production terminal.';
  end if;
  return v_terminal || jsonb_build_object('staff_source','ROSTER');
end;
$$;

create or replace function public.terminal_record_finish_production_v1(
  p_production_flow_item_id uuid,p_shift_code text,p_table_code text,p_processed_by_staff_id uuid,p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],p_trolley_pending boolean default false,
  p_accept_trolley_mismatch boolean default false,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('FINISH',p_table_code);
  return public.record_finish_production_v3(p_production_flow_item_id,p_shift_code,p_table_code,p_processed_by_staff_id,p_lines,p_trolley_codes,p_trolley_pending,p_accept_trolley_mismatch,p_notes);
end; $$;

create or replace function public.terminal_correct_finish_production_v1(
  p_finish_production_entry_id uuid,p_processed_by_staff_id uuid,p_lines jsonb,p_trolley_codes text[] default array[]::text[],
  p_trolley_pending boolean default false,p_accept_trolley_mismatch boolean default false,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_table_code text;
begin
  select table_code into v_table_code from public.finish_production_entries where finish_production_entry_id=p_finish_production_entry_id and status='ACTIVE';
  perform public.require_production_terminal('FINISH',v_table_code);
  return public.correct_finish_production_v3(p_finish_production_entry_id,p_processed_by_staff_id,p_lines,p_trolley_codes,p_trolley_pending,p_accept_trolley_mismatch,p_notes);
end; $$;

create or replace function public.terminal_save_sorting_wash_run_v4(
  p_shift_code text,p_washer_id uuid,p_operator_staff_id uuid,p_start_time time,p_weight_kg numeric,p_wash_type text,
  p_customer_selections jsonb,p_reception_exceptions jsonb default '[]'::jsonb,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.save_sorting_wash_run_v4(p_shift_code,p_washer_id,p_operator_staff_id,p_start_time,p_weight_kg,p_wash_type,p_customer_selections,p_reception_exceptions,p_notes);
end; $$;

create or replace function public.terminal_save_sorting_missed_wash_v4(
  p_shift_code text,p_washer_id uuid,p_operator_staff_id uuid,p_start_time time,p_weight_kg numeric,p_wash_type text,
  p_customer_selections jsonb,p_reception_exceptions jsonb,p_notes text,p_reason text
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.save_sorting_missed_wash_v4(p_shift_code,p_washer_id,p_operator_staff_id,p_start_time,p_weight_kg,p_wash_type,p_customer_selections,p_reception_exceptions,p_notes,p_reason);
end; $$;

create or replace function public.terminal_correct_sorting_wash_run_v4(
  p_wash_run_id uuid,p_expected_row_version integer,p_shift_code text,p_washer_id uuid,p_operator_staff_id uuid,p_start_time time,
  p_weight_kg numeric,p_wash_type text,p_customer_selections jsonb,p_reception_exceptions jsonb,p_notes text,p_reason text
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.correct_sorting_wash_run_v4(p_wash_run_id,p_expected_row_version,p_shift_code,p_washer_id,p_operator_staff_id,p_start_time,p_weight_kg,p_wash_type,p_customer_selections,p_reception_exceptions,p_notes,p_reason);
end; $$;

create or replace function public.terminal_record_sorting_trolley_intake_v2(
  p_shift_code text,p_trolley_code text,p_operator_staff_id uuid,p_customer_id uuid,p_contents_status text,p_scheduled_for_date date,
  p_product_codes text[],p_customer_override_reason text default null,p_off_schedule_reason text default null,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.record_sorting_trolley_intake_v2(p_shift_code,p_trolley_code,p_operator_staff_id,p_customer_id,p_contents_status,p_scheduled_for_date,p_product_codes,p_customer_override_reason,p_off_schedule_reason,p_notes);
end; $$;

create or replace function public.terminal_record_sorting_non_trolley_arrival(
  p_shift_code text,p_customer_id uuid,p_scheduled_for_date date,p_product_code text,p_operator_staff_id uuid,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.record_sorting_non_trolley_arrival(p_shift_code,p_customer_id,p_scheduled_for_date,p_product_code,p_operator_staff_id,p_notes);
end; $$;

revoke all on function public.production_station_device_context(text) from public,anon;
revoke all on function public.require_production_terminal(text,text) from public,anon,authenticated;
revoke all on function public.get_production_terminal_context(text) from public,anon;
revoke all on function public.terminal_record_finish_production_v1(uuid,text,text,uuid,jsonb,text[],boolean,boolean,text) from public,anon;
revoke all on function public.terminal_correct_finish_production_v1(uuid,uuid,jsonb,text[],boolean,boolean,text) from public,anon;
revoke all on function public.terminal_save_sorting_wash_run_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text) from public,anon;
revoke all on function public.terminal_save_sorting_missed_wash_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text) from public,anon;
revoke all on function public.terminal_correct_sorting_wash_run_v4(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text) from public,anon;
revoke all on function public.terminal_record_sorting_trolley_intake_v2(text,text,uuid,uuid,text,date,text[],text,text,text) from public,anon;
revoke all on function public.terminal_record_sorting_non_trolley_arrival(text,uuid,date,text,uuid,text) from public,anon;

grant execute on function public.production_station_device_context(text) to authenticated;
grant execute on function public.get_production_terminal_context(text) to authenticated;
grant execute on function public.terminal_record_finish_production_v1(uuid,text,text,uuid,jsonb,text[],boolean,boolean,text) to authenticated;
grant execute on function public.terminal_correct_finish_production_v1(uuid,uuid,jsonb,text[],boolean,boolean,text) to authenticated;
grant execute on function public.terminal_save_sorting_wash_run_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text) to authenticated;
grant execute on function public.terminal_save_sorting_missed_wash_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text) to authenticated;
grant execute on function public.terminal_correct_sorting_wash_run_v4(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text) to authenticated;
grant execute on function public.terminal_record_sorting_trolley_intake_v2(text,text,uuid,uuid,text,date,text[],text,text,text) to authenticated;
grant execute on function public.terminal_record_sorting_non_trolley_arrival(text,uuid,date,text,uuid,text) to authenticated;

revoke execute on function public.record_finish_production_v3(uuid,text,text,uuid,jsonb,text[],boolean,boolean,text) from authenticated;
revoke execute on function public.correct_finish_production_v3(uuid,uuid,jsonb,text[],boolean,boolean,text) from authenticated;
revoke execute on function public.save_sorting_wash_run_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text) from authenticated;
revoke execute on function public.save_sorting_missed_wash_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text) from authenticated;
revoke execute on function public.correct_sorting_wash_run_v4(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text) from authenticated;
revoke execute on function public.record_sorting_trolley_intake_v2(text,text,uuid,uuid,text,date,text[],text,text,text) from authenticated;
revoke execute on function public.record_sorting_non_trolley_arrival(text,uuid,date,text,uuid,text) from authenticated;

comment on table public.production_station_devices is 'Fixed low-privilege computer identities for Finish and Sorting. Staff attribution remains roster-driven.';
