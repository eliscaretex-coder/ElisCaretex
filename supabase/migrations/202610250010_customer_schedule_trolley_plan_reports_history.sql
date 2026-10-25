-- Customer Schedule Version History: show the trolley plan reports of one customer.
--
-- Finish and MOP send "Report trolley plan" when the published trolley quantity or
-- type looks wrong. Until now the reports could only be read in Customers →
-- Operational Reports (all customers mixed) or in the app-wide alert while still
-- pending. This adds a read-only list for one customer, so the Schedule → Version
-- history window can show who asked, when, what they asked for, and who resolved or
-- rejected it and when.
--
-- New function only. No table, column or row changes. Same audience as the
-- Version history itself (require_customer_schedule_history_role). Names are resolved
-- with production_roster_actor_name (account name, Staff Master name, login email).

create or replace function public.get_customer_trolley_plan_reports(
  p_customer_id uuid,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  perform public.require_customer_schedule_history_role();
  if p_customer_id is null then
    raise exception using errcode = '22023', message = 'Customer is required.';
  end if;
  if not exists (select 1 from public.customers c where c.customer_id = p_customer_id) then
    raise exception using errcode = 'P0002', message = 'Customer was not found.';
  end if;

  return jsonb_build_object(
    'customer_id', p_customer_id,
    'can_review', public.can_handle_trolley_plan_checks(),
    'summary', jsonb_build_object(
      'total', (select count(*) from public.operational_data_reports where customer_id = p_customer_id),
      'pending', (select count(*) from public.operational_data_reports where customer_id = p_customer_id and status = 'PENDING'),
      'resolved', (select count(*) from public.operational_data_reports where customer_id = p_customer_id and status = 'RESOLVED'),
      'rejected', (select count(*) from public.operational_data_reports where customer_id = p_customer_id and status = 'REJECTED')
    ),
    'items', coalesce((
      select jsonb_agg(x.item order by x.reported_at desc)
      from (
        select r.reported_at, jsonb_build_object(
          'operational_report_id', r.operational_report_id,
          'report_type', r.report_type,
          'status', r.status,
          'customer_id', r.customer_id,
          'customer_code', c.customer_code,
          'customer_name', c.customer_name,
          'business_date', r.business_date,
          'product_code', r.product_code,
          'source_area_code', r.source_area_code,
          'reported_by', coalesce(public.production_roster_actor_name(r.reported_by_auth_user_id, r.reported_by_staff_id), 'Operator'),
          'reported_at', r.reported_at,
          'reason', r.reason,
          'planned_snapshot', r.planned_snapshot,
          'reported_snapshot', r.reported_snapshot,
          'observed_snapshot', r.observed_snapshot,
          'reviewed_by', case when r.reviewed_at is not null
            then coalesce(public.production_roster_actor_name(r.reviewed_by_auth_user_id, r.reviewed_by_staff_id), 'Reviewer') end,
          'reviewed_at', r.reviewed_at,
          'review_notes', r.review_notes,
          'source_schedule_version_id', r.source_schedule_version_id,
          'source_version_number', sv.version_number,
          'resolution_schedule_version_id', r.resolution_schedule_version_id,
          'resolution_version_number', rv.version_number
        ) as item
        from public.operational_data_reports r
        join public.customers c on c.customer_id = r.customer_id
        left join public.customer_schedule_versions sv on sv.schedule_version_id = r.source_schedule_version_id
        left join public.customer_schedule_versions rv on rv.schedule_version_id = r.resolution_schedule_version_id
        where r.customer_id = p_customer_id
        order by r.reported_at desc
        limit v_limit
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_customer_trolley_plan_reports(uuid, integer) from public, anon;
grant execute on function public.get_customer_trolley_plan_reports(uuid, integer) to authenticated;

comment on function public.get_customer_trolley_plan_reports(uuid, integer) is
  'Read-only list of one customer''s trolley plan reports (Finish/MOP) for Customer Schedule Version history.';
