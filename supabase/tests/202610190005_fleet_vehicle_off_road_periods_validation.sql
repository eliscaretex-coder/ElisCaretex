begin;
select plan(20);

select has_column('public','fleet_vehicle_defects','vehicle_condition','defect vehicle condition column exists');
select has_column('public','fleet_vehicle_defects','expected_return_on','defect expected return column exists');
select has_column('public','fleet_vehicle_defects','returned_on','defect actual return column exists');
select has_column('public','fleet_vehicle_maintenance','expected_return_on','maintenance expected return column exists');
select has_column('public','fleet_vehicle_maintenance','returned_on','maintenance actual return column exists');
select results_eq($$select count(*)::integer from public.fleet_vehicle_defects where vehicle_condition is null$$, array[0], 'every defect has a vehicle condition');

select has_function('public','return_fleet_vehicle_to_service',array['uuid','date','text'],'return to service RPC exists');
select has_function('public','get_fleet_vehicle_history',array['uuid'],'vehicle history RPC exists');
select ok(not has_function_privilege('anon','public.return_fleet_vehicle_to_service(uuid,date,text)','execute'),'anon cannot return vehicles');
select ok(not has_function_privilege('anon','public.get_fleet_vehicle_history(uuid)','execute'),'anon cannot read vehicle history');
select ok(not has_function_privilege('authenticated','public.distribution_vehicle_block_reason(uuid,date)','execute'),'block rule is internal');
select ok(not has_function_privilege('authenticated','public.fleet_vehicle_metrics(uuid)','execute'),'metrics helper is internal');
select ok(not has_function_privilege('authenticated','public.fleet_vehicle_roster_conflicts(uuid)','execute'),'conflict helper is internal');
select ok(pg_get_functiondef('public.return_fleet_vehicle_to_service(uuid,date,text)'::regprocedure) like '%require_distribution_master_access%','return requires Distribution master access');
select ok(pg_get_functiondef('public.get_fleet_vehicle_history(uuid)'::regprocedure) like '%require_distribution_read_access%','history requires Distribution read access');
select ok(pg_get_functiondef('public.validate_distribution_roster_version(uuid)'::regprocedure) like '%distribution_vehicle_block_reason%','roster validation uses the dated vehicle rule');
select ok(pg_get_functiondef('public.save_distribution_route_run(jsonb)'::regprocedure) like '%distribution_vehicle_block_reason%','daily route plan uses the dated vehicle rule');

-- Dated rule on a temporary vehicle: off road from today, back in 3 days.
insert into public.fleet_vehicles(vehicle_id, registration_number, vehicle_type, operational_status, active)
values ('00000000-0000-0000-0000-00000000f1ee', 'ZZTEST1', 'TRUCK', 'AVAILABLE', true);
insert into public.fleet_vehicle_defects(vehicle_id, reported_on, severity, defect_category, description, defect_status, vehicle_condition, expected_return_on)
values ('00000000-0000-0000-0000-00000000f1ee', now(), 'HIGH', 'Engine', 'test', 'OPEN', 'OFF_ROAD', current_date + 3);
select ok(public.distribution_vehicle_block_reason('00000000-0000-0000-0000-00000000f1ee', current_date + 2) is not null, 'vehicle is blocked before the expected return date');
select ok(public.distribution_vehicle_block_reason('00000000-0000-0000-0000-00000000f1ee', current_date + 3) is null, 'vehicle is free from the expected return date');
insert into public.fleet_vehicle_defects(vehicle_id, reported_on, severity, defect_category, description, defect_status, vehicle_condition, expected_return_on)
values ('00000000-0000-0000-0000-00000000f1ee', now(), 'LOW', 'Lights', 'test', 'OPEN', 'ROADWORTHY', current_date + 10);
select ok(public.distribution_vehicle_block_reason('00000000-0000-0000-0000-00000000f1ee', current_date + 5) is null, 'a roadworthy defect never blocks');

select * from finish();
rollback;
