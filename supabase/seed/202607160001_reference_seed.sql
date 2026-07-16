-- =====================================================================
-- Laundry Platform V2
-- Seed: 202607160001_reference_seed.sql
-- Run after 202607160001_foundation.sql
-- =====================================================================

begin;

insert into public.app_config (
  config_key,
  value_json,
  description
)
values
  (
    'trolley_warning_days',
    '14'::jsonb,
    'Show a warning when a trolley has remained at a customer for this many days.'
  ),
  (
    'trolley_overdue_days',
    '30'::jsonb,
    'Mark a trolley as overdue when it has remained at a customer for this many days.'
  )
on conflict (config_key) do update
set
  value_json = excluded.value_json,
  description = excluded.description,
  updated_at = now();

insert into public.roles (
  role_code,
  role_name,
  description
)
values
  ('ADMIN', 'Administrator', 'Full platform administration.'),
  ('MANAGER', 'Manager', 'Management dashboards, reports and operational oversight.'),
  ('SUPERVISOR', 'Supervisor', 'Operational supervision and controlled corrections.'),
  ('PLANNER', 'Production Planner', 'Customer schedules and production planning.'),
  ('ROSTER_MANAGER', 'Roster Manager', 'Creates and publishes staff rosters.'),
  ('SORTING_OPERATOR', 'Sorting Operator', 'Sorting, washing preparation and trolley reception.'),
  ('FINISH_OPERATOR', 'Finish Operator', 'Finish Area production.'),
  ('MOP_OPERATOR', 'Mop Operator', 'Mop Production.'),
  ('DISTRIBUTION_OPERATOR', 'Distribution Operator', 'Routes, deliveries and trolley outbound registration.'),
  ('AUDITOR', 'Auditor', 'Read-only access to traceability and audit information.')
on conflict (role_code) do update
set
  role_name = excluded.role_name,
  description = excluded.description,
  active = true;

insert into public.areas (
  area_code,
  area_name,
  sort_order
)
values
  ('SORTING', 'Sorting Area', 10),
  ('WASHING', 'Washing', 20),
  ('FINISH', 'Finish Area', 30),
  ('MOP', 'Mop Production', 40),
  ('DISTRIBUTION', 'Distribution', 50),
  ('ROSTER', 'Roster', 60),
  ('REPORTS', 'Reports', 70),
  ('ADMIN', 'Administration', 80)
on conflict (area_code) do update
set
  area_name = excluded.area_name,
  sort_order = excluded.sort_order,
  active = true,
  updated_at = now();

commit;
