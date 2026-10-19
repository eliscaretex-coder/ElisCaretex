begin;
select plan(8);

select has_column('public','fleet_vehicles','is_temporary','temporary flag exists');
select has_column('public','fleet_vehicles','available_until','available-until date exists');
select has_column('public','fleet_vehicles','hire_company','hire company exists');
select ok(not has_function_privilege('anon','public.save_fleet_vehicle(jsonb)','execute'),'anon cannot save vehicles');
select ok(pg_get_functiondef('public.save_fleet_vehicle(jsonb)'::regprocedure) like '%require_distribution_master_access%','vehicle save requires Distribution master access');

-- A temporary vehicle is free until its available-until date and blocked after it.
insert into public.fleet_vehicles(vehicle_id, registration_number, vehicle_type, operational_status, active, is_temporary, available_until)
values ('00000000-0000-0000-0000-00000000f1ef', 'ZZTEST2', 'TRUCK', 'AVAILABLE', true, true, current_date + 2);
select ok(public.distribution_vehicle_block_reason('00000000-0000-0000-0000-00000000f1ef', current_date + 2) is null, 'temporary vehicle is free on its last day');
select ok(public.distribution_vehicle_block_reason('00000000-0000-0000-0000-00000000f1ef', current_date + 3) like 'Temporary vehicle, hire ended%', 'temporary vehicle is blocked after its last day');
update public.fleet_vehicles set is_temporary = false where vehicle_id = '00000000-0000-0000-0000-00000000f1ef';
select ok(public.distribution_vehicle_block_reason('00000000-0000-0000-0000-00000000f1ef', current_date + 3) is null, 'available-until only applies to temporary vehicles');

select * from finish();
rollback;
