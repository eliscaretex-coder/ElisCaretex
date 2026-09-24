do $$
begin
  if to_regprocedure('public.production_roster_action_allowed(text)') is null then raise exception 'Roster permission helper is missing'; end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.production_roster_leave_requests'::regclass and tgname='enforce_production_leave_request_permission' and not tgisinternal) then raise exception 'Leave request permission trigger is missing'; end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.production_roster_leave_gm_reviews'::regclass and tgname='enforce_production_leave_gm_permission' and not tgisinternal) then raise exception 'GM review permission trigger is missing'; end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.app_config'::regclass and tgname='enforce_production_leave_settings_permission' and not tgisinternal) then raise exception 'Leave settings permission trigger is missing'; end if;
  if has_function_privilege('anon','public.production_roster_action_allowed(text)','execute') then raise exception 'anon must not execute roster permission helper'; end if;
end
$$;
