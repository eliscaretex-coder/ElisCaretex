-- Give Distribution accounts (role DISTRIBUTION_OPERATOR) full view and edit access to
-- customers, the same as a Production Planner:
--   - Customer Master: read the directory, overview and record; create, edit,
--     deactivate and reactivate customers.
--   - Customer schedules: create, save, compare, publish, cancel and restore schedule
--     revisions (trolley quantities per day) and reorder planner days (route position).
--   - Schedule history, Clothes and MOP planners and customer KG history.
--   - Trolley plan checks reported by production: list them in the Customer Workspace.
--     Resolving them was already allowed through can_handle_trolley_plan_checks().
--
-- Every write path already records the actor, old and new data and the reason in
-- public.audit_log (create_customer, update_customer, deactivate_customer,
-- reactivate_customer, create_customer_schedule_draft, save_customer_schedule_draft*,
-- publish_customer_schedule*, cancel_customer_schedule_version,
-- restore_customer_schedule_management_draft, reorder_customer_planner_day,
-- review_operational_schedule_report). The wrappers without their own insert delegate
-- to one of these. No write path is added here; only the role lists change.
--
-- Functions whose live body is large are patched in place: the exact role-list text is
-- replaced in the current definition and re-created. Each replacement must match the
-- expected number of times, otherwise the migration fails and nothing is changed.

create or replace function public.require_customer_schedule_edit_role()
returns void language plpgsql security definer set search_path = public, auth, pg_temp as $$
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using
      errcode = '42501',
      message = 'An active authenticated account is required.';
  end if;

  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to manage Customer Schedules.';
  end if;
end;
$$;

revoke all on function public.require_customer_schedule_edit_role() from public, anon;
grant execute on function public.require_customer_schedule_edit_role() to authenticated;

create or replace function public.require_customer_schedule_history_role()
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  if not public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']
  ) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to view Customer Schedule history.';
  end if;
end;
$$;

revoke all on function public.require_customer_schedule_history_role() from public, anon;
grant execute on function public.require_customer_schedule_history_role() to authenticated;

create or replace function public.get_customer_read_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_can_manage_schedules boolean;
  v_can_view_distribution boolean;
  v_pending_reports integer := 0;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'MOP_OPERATOR',
      'DISTRIBUTION_OPERATOR'
    ]
  );
  v_can_manage_schedules := public.has_any_role(array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR']);
  v_can_view_distribution := public.has_any_role(array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR','AUDITOR']);
  if v_can_manage_schedules then
    select count(*)::integer into v_pending_reports
    from public.operational_data_reports where status='PENDING';
  end if;

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'can_view_customer_directory', public.has_any_role(array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']),
    'can_edit_customers', public.has_any_role(array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR']),
    'can_deactivate_customers', public.has_any_role(array['ADMIN','MANAGER','DISTRIBUTION_OPERATOR']),
    'can_edit_schedules', v_can_manage_schedules,
    'can_create_schedule_draft', v_can_manage_schedules,
    'can_save_schedule_draft', v_can_manage_schedules,
    'can_compare_schedule_draft', v_can_manage_schedules,
    'can_publish_schedule_draft', v_can_manage_schedules,
    'can_cancel_schedule_draft', v_can_manage_schedules,
    'can_restore_schedule_version', v_can_manage_schedules,
    'can_view_schedule_history', public.has_any_role(array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']),
    'can_view_clothes_planner', public.has_any_role(array['ADMIN','MANAGER','PLANNER','SUPERVISOR','SORTING_OPERATOR','FINISH_OPERATOR','AUDITOR','DISTRIBUTION_OPERATOR']),
    'can_view_mop_planner', public.has_any_role(array['ADMIN','MANAGER','PLANNER','SUPERVISOR','MOP_OPERATOR','AUDITOR','DISTRIBUTION_OPERATOR']),
    'can_view_distribution', v_can_view_distribution,
    'can_view_operational_reports', v_can_manage_schedules,
    'can_review_operational_reports', v_can_manage_schedules,
    'pending_operational_report_count', v_pending_reports
  );
end;
$$;

revoke all on function public.get_customer_read_capabilities() from public, anon;
grant execute on function public.get_customer_read_capabilities() to authenticated;

do $migration$
declare
  v_patch record;
  v_definition text;
  v_matches integer;
begin
  for v_patch in
    select *
    from (values
      -- Customer Master writes and record.
      ('public.create_customer(text,text,text,numeric,integer,text,text,text[],text,text)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.create_customer_master(text,text,numeric,integer,text,text,text[],text,text)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.deactivate_customer(uuid,text,text)',
       $p$array['ADMIN', 'MANAGER']$p$, $p$array['ADMIN', 'MANAGER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.reactivate_customer(uuid,text[],text,text)',
       $p$array['ADMIN', 'MANAGER']$p$, $p$array['ADMIN', 'MANAGER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.get_customer_master_record(uuid,date)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.get_customer_master_reference_data()',
       $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.get_customer_master_reference_data()',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      -- Customer schedule versions (trolley quantities and order).
      ('public.create_customer_schedule_draft(uuid,date,uuid,text,text)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.publish_customer_schedule(uuid,text,text)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.cancel_customer_schedule_version(uuid,text,text)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.get_customer_schedule_history(uuid,uuid,date,integer)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']$p$, 1),
      -- Customer reads.
      ('public.get_customer_directory(text,text,text,date,integer,integer)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.get_customer_overview(uuid,date)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.get_customer_schedule_history(uuid)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.get_customer_weekly_schedule(uuid,date)',
       $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']$p$, $p$array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']$p$, 1),
      ('public.get_customer_weekly_schedule(uuid,date)',
       $p$'FINISH_OPERATOR', 'MOP_OPERATOR'$p$, $p$'FINISH_OPERATOR', 'MOP_OPERATOR', 'DISTRIBUTION_OPERATOR'$p$, 1),
      ('public.get_clothes_weekly_planner(date,smallint,text)',
       $p$'SORTING_OPERATOR', 'FINISH_OPERATOR', 'AUDITOR'$p$, $p$'SORTING_OPERATOR', 'FINISH_OPERATOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR'$p$, 1),
      ('public.get_mop_weekly_planner(date,smallint,text)',
       $p$'MOP_OPERATOR', 'AUDITOR'$p$, $p$'MOP_OPERATOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR'$p$, 1),
      ('public.get_customer_kg_history(uuid,date,date,integer)',
       $p$array['ADMIN','MANAGER','PLANNER']$p$, $p$array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR']$p$, 1)
    ) as patches(signature, old_text, new_text, expected)
  loop
    v_definition := pg_get_functiondef(v_patch.signature::regprocedure);
    v_matches := (length(v_definition) - length(replace(v_definition, v_patch.old_text, '')))
                 / length(v_patch.old_text);
    if v_matches <> v_patch.expected then
      raise exception 'Expected % match(es) of [%] in %, found %.',
        v_patch.expected, v_patch.old_text, v_patch.signature, v_matches;
    end if;
    execute replace(v_definition, v_patch.old_text, v_patch.new_text);
  end loop;
end;
$migration$;
