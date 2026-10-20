begin;
select plan(8);

select ok(exists(select 1 from public.operational_roles where role_code='MAINTENANCE' and allow_as_primary and active),'Maintenance is a primary role');
select ok(exists(select 1 from public.operational_roles where role_code='PRODUCTION_MANAGER' and allow_as_primary and active),'Production Manager is a primary role');
select ok(exists(select 1 from public.operational_roles where role_code='SORTING_AREA' and not allow_as_primary and allow_as_cover),'Sorting Area is a COVER capability, not a primary role');
select is((select count(*)::integer from public.staff_members sm join public.operational_roles r on r.operational_role_id=sm.primary_operational_role_id where r.role_code='SORTING_AREA' and sm.deleted_at is null),0,'no staff keeps Sorting Area as primary role');
select is(public.production_roster_default_display_section('GENERAL_OPERATIVE','SORTING_MAIN'),'SORTING_AREA','General Operative in Sorting goes to the Sorting roster section');
select is(public.production_roster_default_display_section('GENERAL_OPERATIVE','FINISH_TABLE_2'),'FINISH_TABLE_2','General Operative at a Finish table keeps the table section');
select is(public.production_roster_default_display_section('MAINTENANCE',null),'SUPPORT_ROLE','Maintenance goes to the Support Role section');
select is(public.production_roster_default_display_section('PRODUCTION_MANAGER',null),'SUPERVISOR','Production Manager goes to the Supervisor section');

select * from finish();
rollback;
