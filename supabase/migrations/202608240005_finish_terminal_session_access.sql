-- Finish terminal accounts are technical identities, not Staff Master records.
-- The Roster remains the source for the operational staff attribution.

create or replace function public.require_finish_production_access()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_terminal jsonb := public.production_station_device_context('FINISH');
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'An authenticated Finish account is required.';
  end if;

  if public.current_staff_id() is null
     and coalesce(v_terminal ->> 'device_code', '') = '' then
    raise exception using errcode = '42501', message = 'An active Finish staff account or registered Finish computer is required.';
  end if;

  if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']) then
    raise exception using errcode = '42501', message = 'Your role cannot use Finish Production.';
  end if;
end;
$$;

create or replace function public.require_operational_report_submit_access(
  p_source_area_code text,
  p_product_code text
)
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_area text := upper(trim(coalesce(p_source_area_code, '')));
  v_product text := upper(trim(coalesce(p_product_code, '')));
  v_terminal jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'An authenticated account is required.';
  end if;

  v_terminal := public.production_station_device_context(v_area);
  if public.current_staff_id() is null
     and coalesce(v_terminal ->> 'device_code', '') = '' then
    raise exception using errcode = '42501', message = 'An active staff account or registered production computer is required.';
  end if;

  if v_area = 'MOP' and v_product = 'MOP' then
    if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','MOP_OPERATOR','SORTING_OPERATOR']) then
      raise exception using errcode = '42501', message = 'Your role cannot report MOP operational schedule data.';
    end if;
    return;
  end if;

  if v_area = 'FINISH' and v_product = 'CLOTHES' then
    if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']) then
      raise exception using errcode = '42501', message = 'Your role cannot report Finish operational schedule data.';
    end if;
    return;
  end if;

  raise exception using errcode = '42501', message = 'The requested operational report area/product scope is not allowed.';
end;
$$;

create or replace function public.terminal_upsert_finish_staff_actual_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_table_code text,
  p_start_time time default null,
  p_end_time time default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_production_terminal('FINISH', p_table_code);
  return public.upsert_finish_staff_actual(
    p_staff_id,
    p_shift_code,
    p_table_code,
    p_start_time,
    p_end_time,
    p_reason
  );
end;
$$;

create or replace function public.terminal_report_finish_trolley_requirement_issue_v1(
  p_production_flow_item_id uuid,
  p_source_area_code text,
  p_reported_requirements jsonb,
  p_observed_trolley_codes text[] default array[]::text[],
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if upper(trim(coalesce(p_source_area_code, ''))) <> 'FINISH' then
    raise exception using errcode = '22023', message = 'Finish terminals can submit Finish reports only.';
  end if;

  perform public.require_production_terminal('FINISH');
  return public.report_customer_trolley_requirement_issue(
    p_production_flow_item_id,
    'FINISH',
    p_reported_requirements,
    p_observed_trolley_codes,
    p_reason
  );
end;
$$;

revoke all on function public.terminal_upsert_finish_staff_actual_v1(uuid,text,text,time,time,text) from public, anon;
revoke all on function public.terminal_report_finish_trolley_requirement_issue_v1(uuid,text,jsonb,text[],text) from public, anon;
grant execute on function public.terminal_upsert_finish_staff_actual_v1(uuid,text,text,time,time,text) to authenticated;
grant execute on function public.terminal_report_finish_trolley_requirement_issue_v1(uuid,text,jsonb,text[],text) to authenticated;

-- The existing browser release still calls the original Actual endpoint. The
-- terminal-only wrapper above is used by the next browser release.

comment on function public.require_finish_production_access() is
  'Allows an active Staff Master account or a registered Finish terminal, while keeping role checks. Finish staff attribution is roster-driven.';
comment on function public.terminal_upsert_finish_staff_actual_v1(uuid,text,text,time,time,text) is
  'Finish terminal-only Actual staff update, locked to the terminal table.';
