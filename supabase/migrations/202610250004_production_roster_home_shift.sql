-- Production Roster: the signed-in account's own shift.
-- Each supervisor (Morning / Evening) opens the roster on their own shift by default.
-- The shift comes from the Staff Master record linked to the account (Accounts & Access).
-- This only sets the default: the shift selector still lets a supervisor open the other
-- shift's roster when they cover it, with the same permissions as today.

create or replace function public.get_current_account_home_shift()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_result jsonb;
begin
  perform public.require_production_roster_read_role();

  select jsonb_build_object('shift_code', s.shift_code, 'shift_name', s.shift_name)
    into v_result
  from public.staff_members sm
  join public.shifts s on s.shift_id = sm.default_shift_id and s.active
  where sm.auth_user_id = auth.uid()
    and sm.deleted_at is null
  limit 1;

  return coalesce(v_result, jsonb_build_object('shift_code', null, 'shift_name', null));
end;
$$;

revoke all on function public.get_current_account_home_shift() from public, anon;
grant execute on function public.get_current_account_home_shift() to authenticated;
