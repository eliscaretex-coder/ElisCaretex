begin;

do $$
begin
  if to_regclass('public.application_modules') is null then raise exception 'application_modules was not created'; end if;
  if to_regclass('public.account_permission_grants') is null then raise exception 'account_permission_grants was not created'; end if;
  if to_regclass('public.privacy_notice_versions') is null then raise exception 'privacy_notice_versions was not created'; end if;
  if to_regclass('public.account_privacy_acknowledgements') is null then raise exception 'account_privacy_acknowledgements was not created'; end if;
  if (select count(*) from public.application_modules where active) < 16 then raise exception 'application module catalogue is incomplete'; end if;
  if not exists(select 1 from public.privacy_notice_versions where active and version_code='2026-09-24-INTERIM') then raise exception 'active interim privacy notice is missing'; end if;
  if to_regprocedure('public.has_account_permission(text,text,text)') is null then raise exception 'permission helper is missing'; end if;
  if to_regprocedure('public.get_my_privacy_notice_status()') is null then raise exception 'privacy status function is missing'; end if;
end;$$;

rollback;
