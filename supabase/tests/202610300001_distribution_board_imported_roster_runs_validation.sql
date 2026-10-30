-- Validation for 202610300001_distribution_board_imported_roster_runs.sql
-- Run against ElisCaretex-dev after the migration. Read-only; rolled back.
begin;
-- ===== Conferência (tudo é desfeito pelo rollback no fim) =====
select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  where g.module_code = 'DISTRIBUTION' and g.active and g.can_view limit 1),'role','authenticated')::text, true);

create temporary table _dia on commit drop as
select case when extract(isodow from current_date) = 7 then current_date + 1 else current_date end as dia;

create temporary table _resultado (ordem int, teste text, esperado text, obtido text) on commit drop;

insert into _resultado
select 1, 'Rotas planejadas na escala publicada (semana atual e futuras) sem rota do dia', '0', count(*)::text
from public.distribution_roster_entries e
join public.distribution_roster_versions v using (distribution_roster_version_id)
where v.roster_status = 'PUBLISHED' and v.week_start + 6 >= current_date and e.assignment_status = 'PLANNED'
  and not exists (select 1 from public.distribution_route_runs r where r.business_date = e.work_date and r.route_id = e.route_id);

insert into _resultado
select 2, 'Rotas do dia com motorista ou veículo diferente da escala publicada', '0', count(*)::text
from public.distribution_roster_entries e
join public.distribution_roster_versions v using (distribution_roster_version_id)
join public.distribution_route_runs r on r.business_date = e.work_date and r.route_id = e.route_id
where v.roster_status = 'PUBLISHED' and v.week_start + 6 >= current_date and e.assignment_status = 'PLANNED'
  and r.run_status in ('DRAFT','READY')
  and (r.primary_driver_id is distinct from e.primary_driver_id or r.vehicle_id is distinct from e.vehicle_id
       or r.support_driver_id is distinct from e.support_driver_id);

insert into _resultado
select 3, 'Daily board de hoje: rotas com motorista',
  (select count(*) from public.distribution_roster_entries e join public.distribution_roster_versions v using (distribution_roster_version_id)
   where v.roster_status = 'PUBLISHED' and e.assignment_status = 'PLANNED' and e.work_date = (select dia from _dia))::text,
  (select count(*) from jsonb_array_elements(public.get_distribution_operations_dashboard_v2((select dia from _dia))->'runs') x
   where x->>'primary_driver_name' is not null)::text;

insert into _resultado
select 4, 'Daily board de hoje: rota, motorista e veículo', '(conferir)',
  (select string_agg((x->>'route_code')||' '||coalesce(x->>'primary_driver_name','-')||' '||coalesce(x->>'vehicle_registration','-'), ' | ' order by x->>'route_code')
   from jsonb_array_elements(public.get_distribution_operations_dashboard_v2((select dia from _dia))->'runs') x);

insert into _resultado
select 5, 'Paradas copiadas para as rotas de hoje = paradas da agenda publicada',
  (select count(*) from public.distribution_source_stops((select dia from _dia), null) s
   where exists (select 1 from public.distribution_route_runs r where r.business_date = (select dia from _dia) and r.route_id = s.route_id))::text,
  (select count(*) from public.distribution_route_run_stops rs join public.distribution_route_runs r on r.run_id = rs.run_id
   where r.business_date = (select dia from _dia) and rs.stop_kind = 'SCHEDULED')::text;

insert into _resultado
select 6, 'Hoje: clientes prontos / não iniciados (todas as rotas)', '(antes em 30/10: 65 prontos, 8 não iniciados)',
  (select (p->'summary'->>'ready_customers')||' prontos, '||(p->'summary'->>'not_started_customers')||' não iniciados, '
          ||(p->'summary'->>'produced_kg')||' kg produzidos'
   from (select public.get_distribution_production_load((select dia from _dia)) p) q);

insert into _resultado
select 7, 'Função interna não pode ser chamada pelo site (anon / authenticated)', 'false / false',
  has_function_privilege('anon','public.distribution_apply_published_roster_runs(uuid)','execute')::text || ' / ' ||
  has_function_privilege('authenticated','public.distribution_apply_published_roster_runs(uuid)','execute')::text;

insert into _resultado
select 8, 'Rodar de novo não cria nem muda nada', '0',
  (select coalesce(sum(public.distribution_apply_published_roster_runs(v.distribution_roster_version_id)),0)
   from public.distribution_roster_versions v where v.roster_status = 'PUBLISHED' and v.week_start + 6 >= current_date)::text;

select teste, esperado, obtido from _resultado order by ordem;

rollback;
