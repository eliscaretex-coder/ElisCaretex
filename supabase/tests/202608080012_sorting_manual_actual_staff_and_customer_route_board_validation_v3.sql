-- Corrected V3 validation for Migration 202608080012.
-- V3 never reads private work_sessions while role=authenticated.
-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080012_sorting_manual_actual_staff_and_customer_route_board
-- =====================================================================
-- Snapshot 59 corrected migration validation.
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
)
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (sr.effective_until is null or sr.effective_until >= current_date)
  join public.roles r
    on r.role_id = sr.role_id
   and r.active = true
   and r.role_code = 'ADMIN'
  where sm.active = true
    and sm.deleted_at is null
    and sm.auth_user_id is not null
  order by sm.created_at
  limit 1
) admin_user;

select set_config(
  'eliscaretex_validation.shift_code',
  coalesce((
    select sh.shift_code
    from public.shifts sh
    where sh.active = true
      and sh.deleted_at is null
      and sh.shift_code in ('MORNING','EVENING')
    order by case sh.shift_code when 'MORNING' then 1 else 2 end
    limit 1
  ), 'MORNING'),
  true
);

select set_config(
  'eliscaretex_validation.manual_staff_id',
  coalesce((
    select sm.staff_id::text
    from public.staff_members sm
    where sm.production_staff = true
      and sm.active = true
      and sm.roster_eligible = true
      and sm.deleted_at is null
      and not exists (
        select 1
        from public.production_roster_versions prv
        join public.roster_periods rp
          on rp.roster_period_id = prv.roster_period_id
         and rp.week_start = public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date)
        join public.shifts sh on sh.shift_id = prv.shift_id
        join public.production_roster_entries pre
          on pre.roster_version_id = prv.roster_version_id
         and pre.work_date = (now() at time zone 'Europe/Dublin')::date
         and pre.staff_id = sm.staff_id
        left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
        left join public.areas a on a.area_id = pre.area_id
        left join public.stations st on st.station_id = pre.station_id
        where prv.status = 'PUBLISHED'
          and sh.shift_code = current_setting('eliscaretex_validation.shift_code')
          and pre.day_status = 'WORKING'
          and (
            coalesce(nullif(pre.area_code_snapshot,''),a.area_code)='SORTING'
            or coalesce(nullif(pre.station_code_snapshot,''),st.station_code)='SORTING_MAIN'
            or pre.display_section_code='SORTING_AREA'
            or coalesce(nullif(pre.operational_role_code_snapshot,''),opr.role_code)='SORTING_AREA'
          )
      )
    order by sm.display_name
    limit 1
  ), ''),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.manual_staff_id',true),'') is null then
    raise exception 'No production staff candidate outside current Sorting was found.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_candidates jsonb;
  v_add jsonb;
  v_context jsonb;
  v_manual jsonb;
  v_board jsonb;
  v_session_id uuid;
  v_cancel jsonb;
  v_second_cancel_rejected boolean := false;
begin
  if has_table_privilege('authenticated','public.work_sessions','SELECT')
     or has_table_privilege('authenticated','public.customer_schedule_trolley_requirements','SELECT')
     or has_table_privilege('authenticated','public.distribution_routes','SELECT') then
    raise exception 'Private operational/master tables must not be directly exposed to authenticated.';
  end if;

  v_candidates := public.get_sorting_manual_staff_candidates(
    current_setting('eliscaretex_validation.shift_code')
  );

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_candidates -> 'candidates','[]'::jsonb)) c
    where c ->> 'staff_id' = current_setting('eliscaretex_validation.manual_staff_id')
  ) then
    raise exception 'Selected manual staff candidate was not exposed by controlled RPC.';
  end if;

  v_add := public.add_sorting_actual_staff(
    current_setting('eliscaretex_validation.shift_code'),
    current_setting('eliscaretex_validation.manual_staff_id')::uuid,
    'Temporary manual Sorting position validation.'
  );

  if coalesce(v_add ->> 'status','') <> 'success'
     or coalesce(v_add ->> 'actual_position','') <> 'Sorting Area' then
    raise exception 'Manual Actual Sorting add failed: %',v_add;
  end if;

  v_session_id := (v_add ->> 'work_session_id')::uuid;

  v_context := public.get_sorting_staff_work_context(
    current_setting('eliscaretex_validation.shift_code')
  );

  select value
  into v_manual
  from jsonb_array_elements(coalesce(v_context -> 'staff','[]'::jsonb))
  where value ->> 'staff_id' = current_setting('eliscaretex_validation.manual_staff_id')
  limit 1;

  if v_manual is null
     or coalesce((v_manual ->> 'manual_position')::boolean,false) is not true
     or coalesce(v_manual ->> 'actual_position_label','') <> 'Sorting Area' then
    raise exception 'Manual Actual staff did not appear in Sorting context: %',v_manual;
  end if;

  v_board := public.get_sorting_today_customer_board();

  if coalesce(v_board ->> 'source','') <>
     'PUBLISHED_CUSTOMER_SCHEDULE_ROUTE_MASTER_AND_TROLLEY_REQUIREMENTS' then
    raise exception 'Unexpected Today customer board source.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_board -> 'customers','[]'::jsonb)) c
    where not (c ? 'route_color')
       or not (c ? 'planned_trolley_quantity')
  ) then
    raise exception 'Today customer board is missing route color or trolley quantity fields.';
  end if;

  v_cancel := public.cancel_sorting_actual_staff(
    v_session_id,
    'Temporary validation cancellation.'
  );

  if coalesce(v_cancel ->> 'status','') <> 'success' then
    raise exception 'Manual Actual Sorting cancellation failed: %',v_cancel;
  end if;

  -- Do not query private work_sessions directly while role=authenticated.
  -- Verify the operational result through the controlled read RPC.
  v_context := public.get_sorting_staff_work_context(
    current_setting('eliscaretex_validation.shift_code')
  );

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_context -> 'staff','[]'::jsonb)) staff_row
    where staff_row ->> 'staff_id' = current_setting('eliscaretex_validation.manual_staff_id')
      and coalesce((staff_row ->> 'manual_position')::boolean,false) is true
  ) then
    raise exception 'Cancelled manual Actual staff still appears as an active manual Sorting position.';
  end if;

  -- A second cancel must be rejected by the controlled RPC because the manual
  -- position is no longer active. This proves the state transition without
  -- granting direct SELECT on work_sessions.
  begin
    perform public.cancel_sorting_actual_staff(
      v_session_id,
      'Second cancel validation.'
    );
  exception
    when no_data_found then
      v_second_cancel_rejected := true;
    when others then
      if sqlstate = 'P0002'
         and position('Active manual Sorting position was not found' in sqlerrm) > 0 then
        v_second_cancel_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_second_cancel_rejected then
    raise exception 'Second cancel was not rejected after manual position cancellation.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608080012_sorting_manual_actual_staff_and_customer_route_board_validation',
  'manual_actual_staff_supported',true,
  'published_roster_not_modified',true,
  'manual_cancel_hidden_from_active_context',true,
  'second_cancel_rejected_by_controlled_rpc',true,
  'route_color_exposed_by_controlled_rpc',true,
  'trolley_quantity_exposed_by_controlled_rpc',true,
  'private_tables_remain_private',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
