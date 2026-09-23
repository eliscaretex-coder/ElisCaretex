-- ElisCaretex V2
-- Migration 043: operational trolley-requirement reports + history-only trolley exceptions
-- Date: 2026-08-12
-- Purpose:
--   - stop treating missing-outbound/customer-mismatch trolley evidence as a review queue;
--   - preserve those lifecycle facts as immutable/history-visible evidence only;
--   - add a governed Operational Data Report for incorrect Customer Schedule trolley requirements;
--   - allow MOP/Finish operators to report the mismatch without editing the published schedule;
--   - route review to the same ADMIN/MANAGER/PLANNER roles that can edit Customer Schedules;
--   - preserve published schedule versioning and private source-table boundaries.

create table if not exists public.operational_data_reports (
  operational_report_id uuid primary key default gen_random_uuid(),
  report_type text not null,
  status text not null default 'PENDING',
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  business_date date not null,
  product_code text not null,
  source_area_code text not null,
  source_application text not null,
  production_flow_item_id uuid references public.production_flow_items(production_flow_item_id) on delete restrict,
  source_schedule_version_id uuid references public.customer_schedule_versions(schedule_version_id) on delete restrict,
  source_schedule_day_id uuid references public.customer_schedule_days(schedule_day_id) on delete restrict,
  source_schedule_product_id uuid references public.customer_schedule_products(schedule_product_id) on delete restrict,
  reported_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  reported_by_auth_user_id uuid,
  reported_at timestamptz not null default now(),
  reason text not null,
  planned_snapshot jsonb not null default '{}'::jsonb,
  reported_snapshot jsonb not null default '{}'::jsonb,
  observed_snapshot jsonb not null default '{}'::jsonb,
  reviewed_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  reviewed_by_auth_user_id uuid,
  reviewed_at timestamptz,
  review_notes text,
  resolution_schedule_version_id uuid references public.customer_schedule_versions(schedule_version_id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version integer not null default 1,
  constraint operational_data_reports_type_ck
    check (report_type in ('CUSTOMER_TROLLEY_REQUIREMENT')),
  constraint operational_data_reports_status_ck
    check (status in ('PENDING','RESOLVED','REJECTED')),
  constraint operational_data_reports_product_ck
    check (product_code in ('CLOTHES','MOP')),
  constraint operational_data_reports_area_ck
    check (source_area_code in ('FINISH','MOP')),
  constraint operational_data_reports_reason_ck
    check (length(trim(reason)) between 1 and 1000),
  constraint operational_data_reports_review_ck
    check (
      (status='PENDING' and reviewed_at is null)
      or (status in ('RESOLVED','REJECTED') and reviewed_at is not null and nullif(trim(review_notes),'') is not null)
    )
);

create index if not exists operational_data_reports_pending_idx
  on public.operational_data_reports(status, reported_at desc);
create index if not exists operational_data_reports_customer_idx
  on public.operational_data_reports(customer_id, business_date desc, reported_at desc);
create unique index if not exists operational_data_reports_one_pending_flow_uq
  on public.operational_data_reports(production_flow_item_id, report_type)
  where status='PENDING' and production_flow_item_id is not null;

alter table public.operational_data_reports enable row level security;
revoke all on table public.operational_data_reports from public, anon, authenticated;

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
  v_area text := upper(trim(coalesce(p_source_area_code,'')));
  v_product text := upper(trim(coalesce(p_product_code,'')));
begin
  if auth.uid() is null or public.current_staff_id() is null then
    raise exception using errcode='42501', message='An active authenticated staff account is required.';
  end if;

  if v_area='MOP' and v_product='MOP' then
    if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','MOP_OPERATOR','SORTING_OPERATOR']) then
      raise exception using errcode='42501', message='Your role cannot report MOP operational schedule data.';
    end if;
    return;
  end if;

  if v_area='FINISH' and v_product='CLOTHES' then
    if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']) then
      raise exception using errcode='42501', message='Your role cannot report Finish operational schedule data.';
    end if;
    return;
  end if;

  raise exception using errcode='42501', message='The requested operational report area/product scope is not allowed.';
end;
$$;

revoke all on function public.require_operational_report_submit_access(text,text) from public, anon, authenticated;

create or replace function public.report_customer_trolley_requirement_issue(
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
declare
  v_flow public.production_flow_items%rowtype;
  v_area text := upper(trim(coalesce(p_source_area_code,'')));
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_staff_id uuid;
  v_planned_requirements jsonb := '[]'::jsonb;
  v_planned_map jsonb := '{}'::jsonb;
  v_reported_requirements jsonb := '[]'::jsonb;
  v_reported_map jsonb := '{}'::jsonb;
  v_observed jsonb := '[]'::jsonb;
  v_req jsonb;
  v_type_id uuid;
  v_qty integer;
  v_type record;
  v_existing public.operational_data_reports%rowtype;
  v_report public.operational_data_reports%rowtype;
begin
  if p_production_flow_item_id is null then
    raise exception using errcode='22023', message='Production Flow item is required.';
  end if;
  if v_reason is null then
    raise exception using errcode='22023', message='Please explain why the planned trolley requirement is incorrect.';
  end if;
  if length(v_reason)>1000 then
    raise exception using errcode='22023', message='Report reason must be 1000 characters or fewer.';
  end if;
  if p_reported_requirements is null or jsonb_typeof(p_reported_requirements)<>'array' then
    raise exception using errcode='22023', message='Reported trolley requirements must be an array.';
  end if;

  select * into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id;
  if not found then
    raise exception using errcode='P0002', message='Production Flow item was not found.';
  end if;

  perform public.require_operational_report_submit_access(v_area, v_flow.product_code);
  v_staff_id := public.current_staff_id();

  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'trolley_type_id',tt.trolley_type_id,
        'trolley_type_code',tt.trolley_type_code,
        'display_code',coalesce(tt.display_code,tt.trolley_type_code),
        'trolley_type_name',tt.trolley_type_name,
        'quantity',r.quantity,
        'empty_trolley',r.empty_trolley
      ) order by tt.sort_order,tt.trolley_type_code
    ),'[]'::jsonb),
    coalesce(jsonb_object_agg(tt.trolley_type_code,to_jsonb(r.quantity)),'{}'::jsonb)
  into v_planned_requirements,v_planned_map
  from public.customer_schedule_trolley_requirements r
  join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id
  where r.active=true
    and r.owner_schedule_product_id=v_flow.source_schedule_product_id;

  for v_req in select value from jsonb_array_elements(p_reported_requirements)
  loop
    begin
      v_type_id := nullif(v_req->>'trolley_type_id','')::uuid;
      v_qty := coalesce(nullif(v_req->>'quantity','')::integer,0);
    exception when others then
      raise exception using errcode='22023', message='A reported trolley type or quantity is invalid.';
    end;

    if v_type_id is null then
      raise exception using errcode='22023', message='Every reported trolley requirement must identify a trolley type.';
    end if;
    if v_qty<0 or v_qty>100 then
      raise exception using errcode='22023', message='Reported trolley quantity must be between 0 and 100.';
    end if;
    if v_qty=0 then
      continue;
    end if;

    select tt.* into v_type
    from public.trolley_types tt
    where tt.trolley_type_id=v_type_id
      and tt.active=true
      and tt.deleted_at is null
      and tt.allowed_in_customer_schedule=true;
    if not found then
      raise exception using errcode='22023', message='Reported trolley type is not available for Customer Schedule planning.';
    end if;

    if v_reported_map ? v_type.trolley_type_code then
      raise exception using errcode='22023', message='The same trolley type cannot be reported twice.';
    end if;

    v_reported_requirements := v_reported_requirements || jsonb_build_array(jsonb_build_object(
      'trolley_type_id',v_type.trolley_type_id,
      'trolley_type_code',v_type.trolley_type_code,
      'display_code',coalesce(v_type.display_code,v_type.trolley_type_code),
      'trolley_type_name',v_type.trolley_type_name,
      'quantity',v_qty
    ));
    v_reported_map := v_reported_map || jsonb_build_object(v_type.trolley_type_code,v_qty);
  end loop;

  if v_reported_map=v_planned_map then
    raise exception using errcode='22023', message='The reported trolley requirement matches the current published plan. Change at least one quantity/type before sending the report.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'trolley_code',codes.code,
    'exists',t.trolley_id is not null,
    'trolley_type_id',tt.trolley_type_id,
    'trolley_type_code',tt.trolley_type_code,
    'display_code',coalesce(tt.display_code,tt.trolley_type_code),
    'trolley_type_name',tt.trolley_type_name
  ) order by codes.code),'[]'::jsonb)
  into v_observed
  from (
    select distinct upper(trim(code)) as code
    from unnest(coalesce(p_observed_trolley_codes,array[]::text[])) code
    where nullif(trim(code),'') is not null
  ) codes
  left join public.trolleys t on upper(t.trolley_code)=codes.code and t.deleted_at is null
  left join public.trolley_types tt on tt.trolley_type_id=t.trolley_type_id;

  select * into v_existing
  from public.operational_data_reports r
  where r.production_flow_item_id=v_flow.production_flow_item_id
    and r.report_type='CUSTOMER_TROLLEY_REQUIREMENT'
    and r.status='PENDING'
  order by r.reported_at desc
  limit 1;
  if found then
    return jsonb_build_object(
      'status','already_pending',
      'operational_report_id',v_existing.operational_report_id,
      'message','A trolley-requirement report for this production item is already waiting for Customer Schedule review.'
    );
  end if;

  insert into public.operational_data_reports(
    report_type,status,customer_id,business_date,product_code,source_area_code,source_application,
    production_flow_item_id,source_schedule_version_id,source_schedule_day_id,source_schedule_product_id,
    reported_by_staff_id,reported_by_auth_user_id,reason,planned_snapshot,reported_snapshot,observed_snapshot
  ) values (
    'CUSTOMER_TROLLEY_REQUIREMENT','PENDING',v_flow.customer_id,v_flow.scheduled_for_date,v_flow.product_code,v_area,
    case when v_area='MOP' then 'MOP_PRODUCTION' else 'FINISH_PRODUCTION' end,
    v_flow.production_flow_item_id,v_flow.source_schedule_version_id,v_flow.source_schedule_day_id,v_flow.source_schedule_product_id,
    v_staff_id,auth.uid(),v_reason,
    jsonb_build_object(
      'customer_code',v_flow.customer_code_snapshot,
      'customer_name',v_flow.customer_name_snapshot,
      'route_code',v_flow.route_code_snapshot,
      'route_display_name',v_flow.route_display_name_snapshot,
      'schedule_version_id',v_flow.source_schedule_version_id,
      'schedule_day_id',v_flow.source_schedule_day_id,
      'schedule_product_id',v_flow.source_schedule_product_id,
      'requirements',v_planned_requirements
    ),
    jsonb_build_object('requirements',v_reported_requirements),
    jsonb_build_object('trolleys',v_observed,'scanned_count',jsonb_array_length(v_observed))
  ) returning * into v_report;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application
  ) values (
    auth.uid(),v_staff_id,'OPERATIONAL_TROLLEY_REQUIREMENT_REPORTED','operational_data_reports',
    v_report.operational_report_id::text,to_jsonb(v_report),v_reason,v_report.source_application
  );

  return jsonb_build_object(
    'status','success',
    'operational_report_id',v_report.operational_report_id,
    'message','Trolley plan report sent for Customer Schedule review. The published schedule was not changed.'
  );
end;
$$;

revoke all on function public.report_customer_trolley_requirement_issue(uuid,text,jsonb,text[],text) from public, anon;
grant execute on function public.report_customer_trolley_requirement_issue(uuid,text,jsonb,text[],text) to authenticated;

create or replace function public.get_operational_schedule_reports(
  p_status text default 'PENDING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_status text := upper(trim(coalesce(p_status,'PENDING')));
begin
  perform public.require_customer_schedule_edit_role();
  if v_status not in ('PENDING','RESOLVED','REJECTED','ALL') then
    raise exception using errcode='22023', message='Report status filter must be PENDING, RESOLVED, REJECTED or ALL.';
  end if;

  return jsonb_build_object(
    'summary',jsonb_build_object(
      'pending',(select count(*) from public.operational_data_reports where status='PENDING'),
      'resolved',(select count(*) from public.operational_data_reports where status='RESOLVED'),
      'rejected',(select count(*) from public.operational_data_reports where status='REJECTED')
    ),
    'items',coalesce((
      select jsonb_agg(jsonb_build_object(
        'operational_report_id',r.operational_report_id,
        'report_type',r.report_type,
        'status',r.status,
        'customer_id',r.customer_id,
        'customer_code',c.customer_code,
        'customer_name',c.customer_name,
        'business_date',r.business_date,
        'product_code',r.product_code,
        'source_area_code',r.source_area_code,
        'source_application',r.source_application,
        'production_flow_item_id',r.production_flow_item_id,
        'reported_by_staff_id',r.reported_by_staff_id,
        'reported_by',reporter.display_name,
        'reported_at',r.reported_at,
        'reason',r.reason,
        'planned_snapshot',r.planned_snapshot,
        'reported_snapshot',r.reported_snapshot,
        'observed_snapshot',r.observed_snapshot,
        'reviewed_by',reviewer.display_name,
        'reviewed_at',r.reviewed_at,
        'review_notes',r.review_notes,
        'resolution_schedule_version_id',r.resolution_schedule_version_id,
        'row_version',r.row_version
      ) order by case r.status when 'PENDING' then 1 when 'RESOLVED' then 2 else 3 end,r.reported_at desc)
      from public.operational_data_reports r
      join public.customers c on c.customer_id=r.customer_id
      left join public.staff_members reporter on reporter.staff_id=r.reported_by_staff_id
      left join public.staff_members reviewer on reviewer.staff_id=r.reviewed_by_staff_id
      where v_status='ALL' or r.status=v_status
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_operational_schedule_reports(text) from public, anon;
grant execute on function public.get_operational_schedule_reports(text) to authenticated;

create or replace function public.review_operational_schedule_report(
  p_operational_report_id uuid,
  p_action text,
  p_notes text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_action text := upper(trim(coalesce(p_action,'')));
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_report public.operational_data_reports%rowtype;
  v_staff_id uuid;
  v_resolution_version uuid;
begin
  perform public.require_customer_schedule_edit_role();
  if p_operational_report_id is null then
    raise exception using errcode='22023', message='Operational report is required.';
  end if;
  if v_action not in ('RESOLVED','REJECTED') then
    raise exception using errcode='22023', message='Review action must be RESOLVED or REJECTED.';
  end if;
  if v_notes is null then
    raise exception using errcode='22023', message='Review notes are required.';
  end if;
  if length(v_notes)>1000 then
    raise exception using errcode='22023', message='Review notes must be 1000 characters or fewer.';
  end if;

  select * into v_report
  from public.operational_data_reports
  where operational_report_id=p_operational_report_id
  for update;
  if not found then
    raise exception using errcode='P0002', message='Operational report was not found.';
  end if;
  if v_report.status<>'PENDING' then
    raise exception using errcode='22023', message='This operational report has already been reviewed.';
  end if;

  if v_action='RESOLVED' then
    select v.schedule_version_id into v_resolution_version
    from public.customer_schedule_versions v
    where v.customer_id=v_report.customer_id
      and v.status='PUBLISHED'
      and v_report.business_date>=v.effective_from
      and (v.effective_until is null or v_report.business_date<=v.effective_until)
    order by v.version_number desc
    limit 1;
  end if;

  v_staff_id := public.current_staff_id();
  update public.operational_data_reports
  set status=v_action,
      reviewed_by_staff_id=v_staff_id,
      reviewed_by_auth_user_id=auth.uid(),
      reviewed_at=now(),
      review_notes=v_notes,
      resolution_schedule_version_id=v_resolution_version,
      updated_at=now(),
      row_version=row_version+1
  where operational_report_id=p_operational_report_id
  returning * into v_report;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application
  ) values (
    auth.uid(),v_staff_id,'OPERATIONAL_TROLLEY_REQUIREMENT_'||v_action,'operational_data_reports',
    v_report.operational_report_id::text,to_jsonb(v_report),v_notes,'CUSTOMER_SCHEDULE_UI'
  );

  return jsonb_build_object(
    'status','success',
    'operational_report_id',v_report.operational_report_id,
    'report_status',v_report.status,
    'message',case when v_action='RESOLVED'
      then 'Operational report marked resolved. Published schedule history remains versioned.'
      else 'Operational report rejected with the review reason preserved.' end
  );
end;
$$;

revoke all on function public.review_operational_schedule_report(uuid,text,text) from public, anon;
grant execute on function public.review_operational_schedule_report(uuid,text,text) to authenticated;

-- Customer Schedule editors receive the shared report queue.
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
  v_can_manage_schedules := public.has_any_role(array['ADMIN','MANAGER','PLANNER']);
  v_can_view_distribution := public.has_any_role(array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR','AUDITOR']);
  if v_can_manage_schedules then
    select count(*)::integer into v_pending_reports
    from public.operational_data_reports where status='PENDING';
  end if;

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'can_view_customer_directory', public.has_any_role(array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR']),
    'can_edit_customers', public.has_any_role(array['ADMIN','MANAGER','PLANNER']),
    'can_deactivate_customers', public.has_any_role(array['ADMIN','MANAGER']),
    'can_edit_schedules', v_can_manage_schedules,
    'can_create_schedule_draft', v_can_manage_schedules,
    'can_save_schedule_draft', v_can_manage_schedules,
    'can_compare_schedule_draft', v_can_manage_schedules,
    'can_publish_schedule_draft', v_can_manage_schedules,
    'can_cancel_schedule_draft', v_can_manage_schedules,
    'can_restore_schedule_version', v_can_manage_schedules,
    'can_view_schedule_history', public.has_any_role(array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR']),
    'can_view_clothes_planner', public.has_any_role(array['ADMIN','MANAGER','PLANNER','SUPERVISOR','SORTING_OPERATOR','FINISH_OPERATOR','AUDITOR']),
    'can_view_mop_planner', public.has_any_role(array['ADMIN','MANAGER','PLANNER','SUPERVISOR','MOP_OPERATOR','AUDITOR']),
    'can_view_distribution', v_can_view_distribution,
    'can_view_operational_reports', v_can_manage_schedules,
    'can_review_operational_reports', v_can_manage_schedules,
    'pending_operational_report_count', v_pending_reports
  );
end;
$$;

-- Trolley exceptions become history-only evidence; no operational review queue.
create or replace function public.get_trolley_lifecycle_capabilities()
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select jsonb_build_object(
    'can_view_trolleys', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR','SORTING_OPERATOR','FINISH_OPERATOR','MOP_OPERATOR']),
    'can_assign_trolleys_from_production', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR','MOP_OPERATOR']),
    'can_assign_finish_trolleys', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']),
    'can_assign_mop_trolleys', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','MOP_OPERATOR']),
    'can_view_distribution_handoff', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR']),
    'can_dispatch_trolleys', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR']),
    'can_receive_trolleys', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR']),
    'can_confirm_sorting_arrival', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR']),
    'can_view_trolley_exceptions', false,
    'can_review_trolley_exceptions', false,
    'trolley_exception_policy','HISTORY_ONLY',
    'can_manage_trolley_master', public.has_any_role(array['ADMIN','MANAGER']),
    'can_manage_trolley_types', public.has_any_role(array['ADMIN','MANAGER'])
  );
$$;

revoke all on function public.get_trolley_lifecycle_capabilities() from public, anon;
grant execute on function public.get_trolley_lifecycle_capabilities() to authenticated;

-- Convert old pending/under-review exception tasks into history-only records without pretending they were reviewed.
insert into public.audit_log(
  actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application
)
select
  null,null,'TROLLEY_EXCEPTION_POLICY_CHANGED_TO_HISTORY_ONLY','trolley_customer_stays',s.stay_id::text,
  jsonb_build_object('status',s.status,'review_status',s.review_status,'exception_type',s.exception_type),
  jsonb_build_object('status','RECEIVED','review_status','NOT_REQUIRED','exception_type',s.exception_type),
  'Operational policy changed: trolley custody exceptions remain historical evidence and no longer require human review.',
  'MIGRATION_043'
from public.trolley_customer_stays s
where s.exception_type is not null
  and (s.status='REVIEW_REQUIRED' or s.review_status in ('PENDING','UNDER_REVIEW'));

update public.trolley_customer_stays s
set status='RECEIVED',
    review_status='NOT_REQUIRED',
    updated_at=now()
where s.exception_type is not null
  and (s.status='REVIEW_REQUIRED' or s.review_status in ('PENDING','UNDER_REVIEW'));

-- Current receipt contract: mismatch/missing-outbound remains recorded but is never a task queue item.
create or replace function public.receive_trolley_from_customer(
  p_trolley_code text,
  p_received_from_customer_id uuid,
  p_received_on date default current_date,
  p_confirmation_source text default 'MANUAL_SELECTION',
  p_notes text default null,
  p_source_application text default 'SORTING_TROLLEY_RECEPTION'
)
returns public.trolley_customer_stays
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff_id uuid;
  v_received_date date := coalesce(p_received_on,current_date);
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_mismatch boolean := false;
  v_event_type text;
begin
  perform public.require_any_trolley_role(array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR']);
  if p_received_from_customer_id is null then raise exception using errcode='22023',message='Confirmed customer is required.'; end if;
  if p_confirmation_source is null or p_confirmation_source not in ('OPEN_STAY','LAST_KNOWN_CUSTOMER','MANUAL_SELECTION','SUPERVISOR_CORRECTION') then
    raise exception using errcode='22023',message='Invalid confirmation source.';
  end if;
  v_staff_id:=public.current_staff_id();

  select * into v_trolley from public.trolleys t
  where lower(t.trolley_code)=lower(trim(p_trolley_code)) and t.deleted_at is null for update;
  if not found then raise exception using errcode='P0002',message=format('Trolley not found: %s',trim(p_trolley_code)); end if;
  if v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
    raise exception using errcode='23514',message=format('Trolley %s cannot be recorded at Sorting while its status is %s.',v_trolley.trolley_code,v_trolley.status);
  end if;
  if not exists(select 1 from public.customers c where c.customer_id=p_received_from_customer_id and c.active=true and c.deleted_at is null) then
    raise exception using errcode='22023',message='Confirmed customer is not active or does not exist.';
  end if;

  select * into v_stay from public.trolley_customer_stays s
  where s.trolley_id=v_trolley.trolley_id and s.received_on is null
  order by s.created_at desc limit 1 for update;

  if found then
    if v_stay.sent_on is not null and v_received_date<v_stay.sent_on then
      raise exception using errcode='22023',message='Sorting arrival date cannot be before the tracked delivery date.';
    end if;
    v_mismatch:=v_stay.outbound_customer_id is distinct from p_received_from_customer_id;
    update public.trolley_customer_stays
    set received_from_customer_id=p_received_from_customer_id,
        received_on=v_received_date,
        status='RECEIVED',
        exception_type=case when v_mismatch then 'CUSTOMER_MISMATCH' else null end,
        confirmation_source='OPEN_STAY',operator_confirmed=true,
        review_status='NOT_REQUIRED',
        review_started_at=null,review_started_by=null,reviewed_at=null,reviewed_by=null,review_decision=null,review_notes=null,
        received_recorded_by=v_staff_id,
        notes=case when nullif(trim(p_notes),'') is null then notes when nullif(trim(notes),'') is null then trim(p_notes) else notes||E'\nSorting arrival: '||trim(p_notes) end
    where stay_id=v_stay.stay_id returning * into v_stay;
    v_event_type:=case when v_mismatch then 'CUSTOMER_MISMATCH' else 'ARRIVED_AT_SORTING' end;
  else
    insert into public.trolley_customer_stays(
      trolley_id,outbound_customer_id,received_from_customer_id,sent_on,received_on,status,exception_type,
      confirmation_source,operator_confirmed,review_status,received_recorded_by,notes
    ) values (
      v_trolley.trolley_id,null,p_received_from_customer_id,null,v_received_date,'RECEIVED','MISSING_OUTBOUND_RECORD',
      p_confirmation_source,true,'NOT_REQUIRED',v_staff_id,nullif(trim(p_notes),'')
    ) returning * into v_stay;
    v_event_type:='ARRIVED_AT_SORTING_WITHOUT_OUTBOUND';
  end if;

  update public.trolleys set status='AVAILABLE',updated_by=auth.uid() where trolley_id=v_trolley.trolley_id;
  insert into public.trolley_events(trolley_id,stay_id,event_type,customer_id,business_date,performed_by,source_application,reason,metadata)
  values(v_trolley.trolley_id,v_stay.stay_id,v_event_type,p_received_from_customer_id,v_received_date,v_staff_id,p_source_application,p_notes,
    jsonb_build_object(
      'outbound_customer_id',v_stay.outbound_customer_id,'received_from_customer_id',v_stay.received_from_customer_id,
      'production_business_date',v_stay.production_business_date,'planned_delivery_on',v_stay.planned_delivery_on,
      'custody_start_source',v_stay.custody_start_source,'confirmation_source',v_stay.confirmation_source,
      'exception_type',v_stay.exception_type,'exception_policy','HISTORY_ONLY'
    ));
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application)
  values(auth.uid(),v_staff_id,
    case when v_event_type='ARRIVED_AT_SORTING_WITHOUT_OUTBOUND' then 'SORTING_ARRIVAL_WITHOUT_OUTBOUND'
         when v_event_type='CUSTOMER_MISMATCH' then 'SORTING_ARRIVAL_CUSTOMER_MISMATCH'
         else 'CONFIRM_TROLLEY_SORTING_ARRIVAL' end,
    'trolley_customer_stays',v_stay.stay_id::text,to_jsonb(v_stay),p_notes,p_source_application);
  return v_stay;
end;
$$;

revoke all on function public.receive_trolley_from_customer(text,uuid,date,text,text,text) from public, anon;
grant execute on function public.receive_trolley_from_customer(text,uuid,date,text,text,text) to authenticated;

-- Legacy review queue/actions are deliberately no longer browser-operational.
revoke all on function public.get_trolley_reconciliation_queue() from public, anon, authenticated;
revoke all on function public.review_trolley_exception(uuid,text,text,text) from public, anon, authenticated;

comment on table public.operational_data_reports is
  'Shared operational reports raised by production staff about published planned data. Operators report; Customer Schedule editors decide/correct through versioned schedule management.';
comment on function public.report_customer_trolley_requirement_issue(uuid,text,jsonb,text[],text) is
  'Reports an incorrect published trolley quantity/type from MOP or Finish production without modifying the Customer Schedule.';
comment on function public.get_operational_schedule_reports(text) is
  'Customer Schedule editor queue for operational reports. ADMIN/MANAGER/PLANNER only.';
comment on function public.receive_trolley_from_customer(text,uuid,date,text,text,text) is
  'Records Sorting trolley arrival. Missing outbound/customer mismatch are history-only lifecycle evidence; they never require a review queue.';
