-- Add Driver as an official Staff Master operational role.
-- This lets a production staff member move to Distribution without rewriting
-- historical production records or roster snapshots.

insert into public.operational_roles (
  role_code,
  role_name,
  description,
  allow_as_primary,
  allow_as_cover,
  active,
  sort_order
)
values (
  'DRIVER',
  'Driver',
  'Distribution driver role for route and vehicle operations.',
  true,
  false,
  true,
  80
)
on conflict (role_code) do update
set
  role_name = excluded.role_name,
  description = excluded.description,
  allow_as_primary = excluded.allow_as_primary,
  allow_as_cover = excluded.allow_as_cover,
  active = true,
  sort_order = excluded.sort_order,
  updated_at = now(),
  deleted_at = null;
