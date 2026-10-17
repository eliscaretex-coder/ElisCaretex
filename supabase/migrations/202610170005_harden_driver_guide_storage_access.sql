begin;

create or replace function public.can_view_driver_guide_customer(p_customer_id uuid)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.can_manage_driver_guides() or exists(
    select 1 from public.distribution_route_run_stops s
    join public.distribution_route_runs r on r.run_id=s.run_id
    join public.distribution_roster_entries e on e.work_date=r.business_date and e.route_id=r.route_id
    join public.distribution_roster_versions v on v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='PUBLISHED'
    where s.customer_id=p_customer_id and public.current_distribution_driver_id() in (e.primary_driver_id,e.support_driver_id)
  )
$$;

create or replace function public.can_view_driver_guide_object(p_object_name text)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
 select exists(select 1 from public.customer_driver_guides g where g.storage_path=p_object_name and g.active and public.can_view_driver_guide_customer(g.customer_id))
$$;

drop policy if exists customer_driver_guides_select on storage.objects;
create policy customer_driver_guides_select on storage.objects for select to authenticated
using (bucket_id='customer-driver-guides' and public.can_view_driver_guide_object(name));

revoke all on function public.can_view_driver_guide_object(text) from public,anon;
grant execute on function public.can_view_driver_guide_object(text) to authenticated;

commit;
