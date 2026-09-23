-- Direct system accounts and production terminals do not have a Staff Master
-- record. Read access must rely on the authenticated account role instead.
-- Operational writes keep their existing terminal and staff attribution guards.

create or replace function public.require_any_customer_read_role(
  p_role_codes text[]
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'An authenticated account is required.';
  end if;

  if not public.has_any_role(p_role_codes) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to read this customer information.';
  end if;
end;
$$;

create or replace function public.require_production_flow_read_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null
     or not public.has_any_role(array[
       'ADMIN','MANAGER','SUPERVISOR','AUDITOR',
       'SORTING_OPERATOR','FINISH_OPERATOR','MOP_OPERATOR','DISTRIBUTION_OPERATOR'
     ]) then
    raise exception using
      errcode = '42501',
      message = 'Your active role does not allow access to Production Flow.';
  end if;
end;
$$;

comment on function public.require_any_customer_read_role(text[]) is
  'Read-only customer access controlled by authenticated account roles. Does not require a Staff Master record.';
comment on function public.require_production_flow_read_role() is
  'Shared Production Tracker read access controlled by authenticated account roles. Does not require a Staff Master record.';
