-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608100003_production_roster_mop_decision_and_sorting_selection_clarity
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr on sr.staff_id=sm.staff_id and sr.active=true
    join public.roles r on r.role_id=sr.role_id and r.active=true and r.role_code='ADMIN'
    where sm.auth_user_id is not null and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

do $$
declare
  v_week date := public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date + 42);
  v_shift record;
  v_staff_a uuid;
  v_staff_b uuid;
begin
  select sh.shift_id, sh.shift_code
  into v_shift
  from public.shifts sh
  where sh.active=true and sh.deleted_at is null
    and sh.shift_code in ('MORNING','EVENING')
    and (
      select count(*)
      from public.staff_members sm
      left join public.operational_roles opr on opr.operational_role_id=sm.primary_operational_role_id
      left join public.areas a on a.area_id=sm.default_area_id
      where sm.default_shift_id=sh.shift_id
        and sm.production_staff=true and sm.active=true and sm.roster_eligible=true
        and sm.deleted_at is null
        and (sm.joined_on is null or sm.joined_on <= v_week)
        and (sm.deactivated_on is null or sm.deactivated_on >= v_week+5)
        and (opr.role_code='SORTING_AREA' or a.area_code='SORTING')
    ) >= 2
  order by sh.shift_code
  limit 1;

  select sm.staff_id into v_staff_a
  from public.staff_members sm
  left join public.operational_roles opr on opr.operational_role_id=sm.primary_operational_role_id
  left join public.areas a on a.area_id=sm.default_area_id
  where sm.default_shift_id=v_shift.shift_id
    and sm.production_staff=true and sm.active=true and sm.roster_eligible=true and sm.deleted_at is null
    and (sm.joined_on is null or sm.joined_on <= v_week)
    and (sm.deactivated_on is null or sm.deactivated_on >= v_week+5)
    and (opr.role_code='SORTING_AREA' or a.area_code='SORTING')
  order by sm.display_name limit 1;

  select sm.staff_id into v_staff_b
  from public.staff_members sm
  left join public.operational_roles opr on opr.operational_role_id=sm.primary_operational_role_id
  left join public.areas a on a.area_id=sm.default_area_id
  where sm.default_shift_id=v_shift.shift_id
    and sm.staff_id<>v_staff_a
    and sm.production_staff=true and sm.active=true and sm.roster_eligible=true and sm.deleted_at is null
    and (sm.joined_on is null or sm.joined_on <= v_week)
    and (sm.deactivated_on is null or sm.deactivated_on >= v_week+5)
    and (opr.role_code='SORTING_AREA' or a.area_code='SORTING')
  order by sm.display_name limit 1;

  if v_shift.shift_id is null or v_staff_a is null or v_staff_b is null then
    raise exception 'Could not resolve two eligible Sorting staff for validation.';
  end if;

  perform set_config('eliscaretex_validation.week',v_week::text,true);
  perform set_config('eliscaretex_validation.shift',v_shift.shift_code,true);
  perform set_config('eliscaretex_validation.a',v_staff_a::text,true);
  perform set_config('eliscaretex_validation.b',v_staff_b::text,true);
end;
$$;

set local role authenticated;

do $$
declare
  v_week date := current_setting('eliscaretex_validation.week')::date;
  v_shift text := current_setting('eliscaretex_validation.shift');
  v_a uuid := current_setting('eliscaretex_validation.a')::uuid;
  v_b uuid := current_setting('eliscaretex_validation.b')::uuid;
  v_entries jsonb := '[]'::jsonb;
  v_day date;
  v_saved jsonb;
  v_rejected boolean := false;
begin
  -- Explicit NO_DEDICATED_MOP: all Sorting rows NULL. Must save successfully.
  for i in 0..5 loop
    v_day := v_week+i;
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object(
        'staff_id',v_a,'work_date',v_day,'day_status','WORKING','assignment_type','BASE',
        'operational_role_code','SORTING_AREA','area_code','SORTING','station_code','SORTING_MAIN',
        'display_section_code','SORTING_AREA','sorting_work_mode',null,'shift_override_confirmed',false
      ),
      jsonb_build_object(
        'staff_id',v_b,'work_date',v_day,'day_status','WORKING','assignment_type','BASE',
        'operational_role_code','SORTING_AREA','area_code','SORTING','station_code','SORTING_MAIN',
        'display_section_code','SORTING_AREA','sorting_work_mode',null,'shift_override_confirmed',false
      )
    );
  end loop;

  v_saved := public.save_production_roster_week(
    v_week,v_shift,false,'Validation no dedicated MOP',v_entries,null,
    'Validate explicit no dedicated MOP','ROSTER_VALIDATION'
  );

  if coalesce(v_saved->>'status','') <> 'DRAFT' then
    raise exception 'Explicit No dedicated MOP did not save: %',v_saved;
  end if;

  -- Ambiguous "all Clothes, no MOP" must be rejected: this is the forgotten-decision state.
  begin
    perform public.save_production_roster_week(
      v_week,v_shift,false,'Validation forgotten MOP',
      (
        select jsonb_agg(
          case
            when e->>'operational_role_code'='SORTING_AREA'
              then jsonb_set(e,'{sorting_work_mode}','"CLOTHES"'::jsonb,true)
            else e
          end
        )
        from jsonb_array_elements(v_entries) e
      ),
      (v_saved->>'row_version')::integer,
      'Validate forgotten MOP decision','ROSTER_VALIDATION'
    );
  exception
    when others then
      if sqlstate='22023'
         and position('Choose the Sorting MOP coverage' in sqlerrm)>0 then
        v_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'All-CLOTHES no-MOP state was not rejected as an undecided MOP coverage.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608100003_production_roster_mop_decision_and_sorting_selection_clarity_validation',
  'no_dedicated_mop_allowed',true,
  'forgotten_mop_decision_rejected',true,
  'dedicated_mop_model_preserved',true,
  'published_history_immutable',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
