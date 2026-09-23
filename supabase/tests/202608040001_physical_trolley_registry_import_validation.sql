-- =====================================================================
-- ElisCaretex V2
-- Validation:
-- 202608040001_physical_trolley_registry_import_validation.sql
-- Read-only validation of CentralDB (1)(3).xlsx / Trolley import.
-- =====================================================================

with registry as (
  select
    t.*,
    tt.trolley_type_code
  from public.trolleys t
  join public.trolley_types tt
    on tt.trolley_type_id = t.trolley_type_id
  where t.metadata ->> 'registry_import_batch' = 'CENTRALDB_TROLLEY_2026_08_04'
), checks as (
  select
    count(*) = 633 as total_ok,
    count(*) filter (where trolley_type_code = 'SMALL') = 264 as small_ok,
    count(*) filter (where trolley_type_code = 'MEDIUM') = 157 as medium_ok,
    count(*) filter (where trolley_type_code = 'LARGE') = 212 as large_ok,
    count(*) filter (where status = 'LOCATION_UNCONFIRMED') = 631 as unconfirmed_ok,
    count(*) filter (where status = 'OUT_OF_SERVICE') = 2 as out_of_service_ok,
    count(*) filter (where metadata ? 'data_quality_flag') = 1 as quality_flag_ok,
    count(distinct trolley_code) = count(*) as unique_codes_ok,
    bool_and(active) as active_ok,
    bool_and(deleted_at is null) as not_deleted_ok
  from registry
), exact_rows as (
  select
    exists (
      select 1 from registry
      where trolley_code = 'T7882025T'
        and trolley_type_code = 'MEDIUM'
        and status = 'OUT_OF_SERVICE'
        and status_before_service_hold = 'LOCATION_UNCONFIRMED'
    ) as t788_ok,
    exists (
      select 1 from registry
      where trolley_code = 'T7902025T'
        and trolley_type_code = 'MEDIUM'
        and status = 'OUT_OF_SERVICE'
        and status_before_service_hold = 'LOCATION_UNCONFIRMED'
    ) as t790_ok,
    exists (
      select 1 from registry
      where trolley_code = 'T164025T'
        and trolley_type_code = 'SMALL'
        and metadata ->> 'data_quality_flag' = 'NONSTANDARD_CODE_PATTERN'
        and metadata ->> 'possible_related_code' = 'T1642025T'
    ) as nonstandard_code_preserved_ok,
    exists (
      select 1 from registry
      where trolley_code = 'T1642025T'
        and trolley_type_code = 'SMALL'
    ) as related_code_preserved_ok
)
select case
  when checks.total_ok
   and checks.small_ok
   and checks.medium_ok
   and checks.large_ok
   and checks.unconfirmed_ok
   and checks.out_of_service_ok
   and checks.quality_flag_ok
   and checks.unique_codes_ok
   and checks.active_ok
   and checks.not_deleted_ok
   and exact_rows.t788_ok
   and exact_rows.t790_ok
   and exact_rows.nonstandard_code_preserved_ok
   and exact_rows.related_code_preserved_ok
  then jsonb_build_object(
    'status', 'PASS',
    'test', '202608040001_physical_trolley_registry_import_validation',
    'registry_count', 633,
    'small', 264,
    'medium', 157,
    'large', 212,
    'location_unconfirmed', 631,
    'out_of_service', 2,
    'nonstandard_code_preserved_for_review', 'T164025T'
  )
  else jsonb_build_object(
    'status', 'FAIL',
    'test', '202608040001_physical_trolley_registry_import_validation',
    'checks', to_jsonb(checks),
    'exact_rows', to_jsonb(exact_rows)
  )
end as validation_result
from checks
cross join exact_rows;
