begin;

create or replace function public.get_distribution_activity_history(p_from date default null, p_to date default null, p_limit integer default 250)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_from date := coalesce(p_from, current_date - 90);
  v_to date := coalesce(p_to, current_date + 30);
  v_limit integer := least(greatest(coalesce(p_limit, 250), 1), 500);
begin
  perform public.require_distribution_read_access();
  return jsonb_build_object(
    'range_from', v_from,
    'range_to', v_to,
    'events', coalesce((
      select jsonb_agg(
        to_jsonb(x) || jsonb_build_object(
          'recorded_by_name', coalesce(ap.display_name, sm.display_name, au.email, case when x.recorded_by is null then 'System' else 'Account user' end)
        ) order by x.event_at desc
      )
      from (
        select 'Roster'::text as source,e.event_type,e.event_at,e.recorded_by,rv.week_start,rv.version_number,rv.roster_status,
          case when e.event_type='DRAFT_CREATED' then format('Week %s draft created',rv.week_start)
               when e.event_type='DRAFT_SAVED' then format('Week %s draft saved with %s entries',rv.week_start,coalesce(e.event_payload->>'entry_count','0'))
               when e.event_type='PUBLISHED' then format('Week %s published as version %s',rv.week_start,rv.version_number)
               else format('Roster week %s: %s',rv.week_start,e.event_type) end as summary
        from public.distribution_roster_events e join public.distribution_roster_versions rv on rv.distribution_roster_version_id=e.distribution_roster_version_id
        where e.event_at::date between v_from and v_to
        union all
        select 'Daily route',e.event_type,e.event_at,e.recorded_by,r.business_date,null::integer,r.run_status,
          format('%s on %s: %s',coalesce(dr.display_name,dr.route_code,'Route'),r.business_date,e.event_type)
        from public.distribution_run_events e join public.distribution_route_runs r on r.run_id=e.run_id left join public.distribution_routes dr on dr.route_id=r.route_id
        where e.event_at::date between v_from and v_to
        union all
        select 'Actual hours','HOURS_SAVED',a.updated_at,a.updated_by,a.week_start,null::integer,'ACTUALS',
          format('%s: %s actual hours, planned %s',d.display_name,a.actual_hours,a.planned_hours)
        from public.distribution_driver_weekly_actuals a join public.distribution_drivers d on d.driver_id=a.driver_id
        where a.updated_at::date between v_from and v_to
        union all
        select 'Vehicle mileage','MILEAGE_SAVED',m.updated_at,m.updated_by,m.week_start,null::integer,'MILEAGE',
          format('%s: %s actual KM, odometer %s',v.registration_number,m.actual_km,coalesce(m.odometer_km::text,'not recorded'))
        from public.distribution_vehicle_weekly_mileage m join public.fleet_vehicles v on v.vehicle_id=m.vehicle_id
        where m.updated_at::date between v_from and v_to
        union all
        select
          case e.entity_table when 'distribution_drivers' then 'Driver records' when 'distribution_driver_absences' then 'Driver leave' when 'fleet_vehicles' then 'Fleet records' when 'distribution_routes' then 'Route records' else 'Master data' end,
          e.event_type,e.event_at,e.recorded_by,null::date,null::integer,e.entity_table,
          case
            when e.entity_table='distribution_drivers' then
              format('%s (%s)%s',
                coalesce(e.event_payload->'new'->>'display_name',e.event_payload->'old'->>'display_name','Driver'),
                coalesce(e.event_payload->'new'->>'driver_code',e.event_payload->'old'->>'driver_code','No code'),
                case when e.event_type='UPDATE' then ': ' || coalesce((
                  select string_agg(format('%s: %s -> %s',
                    case k when 'display_name' then 'Name' when 'phone' then 'Phone' when 'email' then 'Email' when 'licence_number' then 'Licence number' when 'licence_categories' then 'Licence type' when 'licence_expires_on' then 'Licence expiry' when 'cpc_expires_on' then 'CPC expiry' when 'employment_status' then 'Employment' when 'availability_status' then 'Availability' when 'notes' then 'Notes' else k end,
                    case when k='licence_categories' then coalesce((select string_agg(value,', ') from jsonb_array_elements_text(coalesce(e.event_payload->'old'->k,'[]'::jsonb))), 'Not set') else coalesce(nullif(trim(both '"' from (e.event_payload->'old'->k)::text),'null'),'Not set') end,
                    case when k='licence_categories' then coalesce((select string_agg(value,', ') from jsonb_array_elements_text(coalesce(e.event_payload->'new'->k,'[]'::jsonb))), 'Not set') else coalesce(nullif(trim(both '"' from (e.event_payload->'new'->k)::text),'null'),'Not set') end
                  ),'; ' order by array_position(array['display_name','phone','email','licence_number','licence_categories','licence_expires_on','cpc_expires_on','employment_status','availability_status','notes'],k))
                  from unnest(array['display_name','phone','email','licence_number','licence_categories','licence_expires_on','cpc_expires_on','employment_status','availability_status','notes']) k
                  where e.event_payload->'old'->k is distinct from e.event_payload->'new'->k
                ),'Record saved') else '' end)
            when e.entity_table='distribution_driver_absences' then
              format('%s leave: %s to %s',coalesce(d.display_name,'Driver'),coalesce(e.event_payload->'new'->>'starts_on',e.event_payload->'old'->>'starts_on',''),coalesce(e.event_payload->'new'->>'ends_on',e.event_payload->'old'->>'ends_on',''))
            when e.entity_table='fleet_vehicles' then format('Vehicle %s',coalesce(e.event_payload->'new'->>'registration_number',e.event_payload->'old'->>'registration_number','updated'))
            when e.entity_table='distribution_routes' then format('Route %s',coalesce(e.event_payload->'new'->>'route_code',e.event_payload->'old'->>'route_code','updated'))
            else format('%s %s',replace(e.entity_table,'_',' '),lower(e.event_type))
          end
        from public.distribution_master_events e
        left join public.distribution_drivers d on d.driver_id::text=coalesce(e.event_payload->'new'->>'driver_id',e.event_payload->'old'->>'driver_id')
        where e.event_at::date between v_from and v_to
        order by event_at desc
        limit v_limit
      ) x
      left join public.account_access_profiles ap on ap.auth_user_id=x.recorded_by
      left join public.staff_members sm on sm.auth_user_id=x.recorded_by
      left join auth.users au on au.id=x.recorded_by
    ),'[]'::jsonb),
    'roster_versions',coalesce((
      select jsonb_agg(to_jsonb(rv) || jsonb_build_object('created_by_name',coalesce(ap.display_name,sm.display_name,au.email,'System')) order by rv.week_start desc,rv.version_number desc)
      from public.distribution_roster_versions rv
      left join public.account_access_profiles ap on ap.auth_user_id=rv.created_by
      left join public.staff_members sm on sm.auth_user_id=rv.created_by
      left join auth.users au on au.id=rv.created_by
      where rv.created_at::date between v_from and v_to or coalesce(rv.published_at,rv.created_at)::date between v_from and v_to
      limit v_limit
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_distribution_activity_history(date,date,integer) from public,anon;
grant execute on function public.get_distribution_activity_history(date,date,integer) to authenticated;

commit;
