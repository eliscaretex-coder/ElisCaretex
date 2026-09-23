-- =====================================================================
-- ElisCaretex V2
-- Validation FIX V2:
-- 202607310002_customer_schedule_management_api_validation.sql
--
-- Why this version exists:
--   The previous validation stored state in a temporary table. In some
--   Supabase SQL Editor executions that temporary relation was no longer
--   resolvable by a later statement, producing:
--
--     relation "customer_schedule_test_state" does not exist
--
--   This version stores temporary test identifiers in transaction-local
--   PostgreSQL settings instead. It does not create a test table.
--
-- Controlled lifecycle covered:
--   create draft -> read -> save -> compare -> publish
--   create second draft -> cancel
--
-- After SET ROLE, application data is accessed only through controlled RPCs.
-- Every database change is rolled back at the end.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Test setup while SQL Editor still has its privileged execution role
-- ---------------------------------------------------------------------

-- Resolve one existing active ADMIN and emulate that authenticated user.
select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
) as test_admin_auth_user_id
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (
     sr.effective_until is null
     or sr.effective_until >= current_date
   )
  join public.roles r
    on r.role_id = sr.role_id
   and r.active = true
   and r.role_code = 'ADMIN'
  where sm.active = true
    and sm.deleted_at is null
    and sm.auth_user_id is not null
  order by sm.created_at
  limit 1
) admin_user;

do $$
begin
  if nullif(
       current_setting('request.jwt.claim.sub', true),
       ''
     ) is null then
    raise exception
      'No active ADMIN linked to auth.users was found for validation.';
  end if;
end;
$$;

-- Choose one safe active customer with a current published revision, no open
-- draft and no future published revision. Store only IDs/codes in a local
-- transaction setting; no application table is exposed after SET ROLE.
select set_config(
  'eliscaretex.validation.schedule_setup',
  jsonb_build_object(
    'customer_id', selected.customer_id,
    'customer_code', selected.customer_code,
    'base_version_id', selected.base_version_id
  )::text,
  true
) as selected_test_customer
from (
  select
    c.customer_id,
    c.customer_code,
    current_version.schedule_version_id as base_version_id
  from public.customers c
  join lateral (
    select v.schedule_version_id
    from public.customer_schedule_versions v
    where v.customer_id = c.customer_id
      and v.status = 'PUBLISHED'
      and public.current_business_date() >= v.effective_from
      and (
        v.effective_until is null
        or public.current_business_date() <= v.effective_until
      )
    order by v.effective_from desc, v.version_number desc
    limit 1
  ) current_version on true
  where c.active = true
    and c.deleted_at is null
    and not exists (
      select 1
      from public.customer_schedule_versions draft
      where draft.customer_id = c.customer_id
        and draft.status = 'DRAFT'
    )
    and not exists (
      select 1
      from public.customer_schedule_versions future_version
      where future_version.customer_id = c.customer_id
        and future_version.status = 'PUBLISHED'
        and future_version.effective_from > public.current_business_date()
    )
  order by c.customer_code
  limit 1
) selected;

do $$
begin
  if nullif(
       current_setting(
         'eliscaretex.validation.schedule_setup',
         true
       ),
       ''
     ) is null then
    raise exception
      'No suitable customer was found for the schedule API validation.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Capabilities and reference data
-- ---------------------------------------------------------------------

-- Expected schedule-management capabilities: true.
select public.get_customer_read_capabilities()
  as schedule_management_capabilities;

-- Expected:
-- - customer product types according to eligibility;
-- - active routes;
-- - allowed trolley types.
select public.get_customer_schedule_reference_data(
  p_customer_id => (
    current_setting(
      'eliscaretex.validation.schedule_setup'
    )::jsonb ->> 'customer_id'
  )::uuid,
  p_effective_date => public.current_business_date()
) as schedule_reference_data;

-- ---------------------------------------------------------------------
-- 2. Create a draft copied from the current published revision
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.draft_created',
  public.create_customer_schedule_management_draft(
    p_customer_id => (
      current_setting(
        'eliscaretex.validation.schedule_setup'
      )::jsonb ->> 'customer_id'
    )::uuid,
    p_effective_from => public.current_business_date(),
    p_based_on_version_id => (
      current_setting(
        'eliscaretex.validation.schedule_setup'
      )::jsonb ->> 'base_version_id'
    )::uuid,
    p_change_reason =>
      'Validate controlled Customer Schedule draft creation.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
) as draft_creation_result;

do $$
declare
  v_result jsonb := current_setting(
    'eliscaretex.validation.draft_created'
  )::jsonb;
begin
  if coalesce(v_result -> 'draft' ->> 'status', '') <> 'DRAFT' then
    raise exception
      'Draft creation validation failed. Returned payload: %',
      v_result;
  end if;

  if nullif(v_result ->> 'schedule_version_id', '') is null then
    raise exception
      'Draft creation did not return schedule_version_id.';
  end if;

  if nullif(v_result -> 'draft' ->> 'row_version', '') is null then
    raise exception
      'Draft creation did not return row_version.';
  end if;
end;
$$;

-- Expected:
-- - draft_schedule.status = DRAFT;
-- - published_schedule remains PUBLISHED.
select public.get_customer_schedule_management_state(
  p_customer_id => (
    current_setting(
      'eliscaretex.validation.schedule_setup'
    )::jsonb ->> 'customer_id'
  )::uuid,
  p_selected_version_id => (
    current_setting(
      'eliscaretex.validation.draft_created'
    )::jsonb ->> 'schedule_version_id'
  )::uuid,
  p_effective_date => public.current_business_date()
) as state_after_draft_creation;

-- ---------------------------------------------------------------------
-- 3. Save a controlled modification
-- ---------------------------------------------------------------------

-- The complete draft document is round-tripped. Only general instructions
-- are changed. The published base revision is not modified.
select set_config(
  'eliscaretex.validation.draft_saved',
  public.save_customer_schedule_draft(
    p_schedule_version_id => (
      current_setting(
        'eliscaretex.validation.draft_created'
      )::jsonb ->> 'schedule_version_id'
    )::uuid,
    p_expected_row_version => (
      current_setting(
        'eliscaretex.validation.draft_created'
      )::jsonb -> 'draft' ->> 'row_version'
    )::integer,
    p_draft => jsonb_set(
      public.get_customer_schedule_management_state(
        p_customer_id => (
          current_setting(
            'eliscaretex.validation.schedule_setup'
          )::jsonb ->> 'customer_id'
        )::uuid,
        p_selected_version_id => (
          current_setting(
            'eliscaretex.validation.draft_created'
          )::jsonb ->> 'schedule_version_id'
        )::uuid,
        p_effective_date => public.current_business_date()
      ) -> 'draft_schedule',
      '{general_instructions}',
      to_jsonb(
        'Temporary Customer Schedule API validation instruction.'::text
      ),
      true
    ),
    p_change_reason =>
      'Validate transactional Customer Schedule draft save.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
) as draft_save_result;

do $$
declare
  v_created jsonb := current_setting(
    'eliscaretex.validation.draft_created'
  )::jsonb;
  v_saved jsonb := current_setting(
    'eliscaretex.validation.draft_saved'
  )::jsonb;
begin
  if coalesce(v_saved ->> 'status', '') <> 'DRAFT' then
    raise exception
      'Draft save returned an unexpected status. Payload: %',
      v_saved;
  end if;

  if (v_saved ->> 'row_version')::integer <=
     (v_created -> 'draft' ->> 'row_version')::integer then
    raise exception
      'Draft row_version did not increase after save.';
  end if;

  if coalesce(v_saved ->> 'general_instructions', '') <>
     'Temporary Customer Schedule API validation instruction.' then
    raise exception
      'Draft general instructions were not saved as expected.';
  end if;
end;
$$;

-- Expected:
-- - has_changes = true;
-- - general_instructions_changed = true;
-- - day/product/trolley counts before and after remain equal.
select set_config(
  'eliscaretex.validation.draft_comparison',
  public.compare_customer_schedule_draft(
    (
      current_setting(
        'eliscaretex.validation.draft_created'
      )::jsonb ->> 'schedule_version_id'
    )::uuid
  )::text,
  true
) as comparison_after_save;

do $$
declare
  v_comparison jsonb := current_setting(
    'eliscaretex.validation.draft_comparison'
  )::jsonb;
begin
  if coalesce((v_comparison ->> 'has_changes')::boolean, false)
     is not true then
    raise exception
      'Draft comparison did not report has_changes = true.';
  end if;

  if coalesce(
       (v_comparison ->> 'general_instructions_changed')::boolean,
       false
     ) is not true then
    raise exception
      'Draft comparison did not report general_instructions_changed = true.';
  end if;

  if v_comparison -> 'summary' -> 'before' ->> 'days'
     is distinct from
     v_comparison -> 'summary' -> 'after' ->> 'days' then
    raise exception
      'Day count changed unexpectedly during general-instructions test.';
  end if;

  if v_comparison -> 'summary' -> 'before' ->> 'products'
     is distinct from
     v_comparison -> 'summary' -> 'after' ->> 'products' then
    raise exception
      'Product count changed unexpectedly during general-instructions test.';
  end if;

  if v_comparison -> 'summary' -> 'before' ->> 'trolley_requirements'
     is distinct from
     v_comparison -> 'summary' -> 'after' ->> 'trolley_requirements' then
    raise exception
      'Trolley requirement count changed unexpectedly during test.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Publish the draft as a new revision
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.draft_published',
  public.publish_customer_schedule_draft(
    p_schedule_version_id => (
      current_setting(
        'eliscaretex.validation.draft_created'
      )::jsonb ->> 'schedule_version_id'
    )::uuid,
    p_expected_row_version => (
      current_setting(
        'eliscaretex.validation.draft_saved'
      )::jsonb ->> 'row_version'
    )::integer,
    p_change_reason =>
      'Validate controlled Customer Schedule publication.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
) as draft_publication_result;

do $$
declare
  v_result jsonb := current_setting(
    'eliscaretex.validation.draft_published'
  )::jsonb;
begin
  if coalesce(
       v_result -> 'published_schedule' ->> 'status',
       ''
     ) <> 'PUBLISHED' then
    raise exception
      'Draft publication did not return PUBLISHED status. Payload: %',
      v_result;
  end if;
end;
$$;

-- Expected:
-- - selected_schedule.status = PUBLISHED;
-- - draft_schedule is null.
select public.get_customer_schedule_management_state(
  p_customer_id => (
    current_setting(
      'eliscaretex.validation.schedule_setup'
    )::jsonb ->> 'customer_id'
  )::uuid,
  p_selected_version_id => (
    current_setting(
      'eliscaretex.validation.draft_published'
    )::jsonb -> 'published_schedule' ->> 'schedule_version_id'
  )::uuid,
  p_effective_date => public.current_business_date()
) as state_after_publication;

-- ---------------------------------------------------------------------
-- 5. Create and cancel a second draft
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.second_draft_created',
  public.create_customer_schedule_management_draft(
    p_customer_id => (
      current_setting(
        'eliscaretex.validation.schedule_setup'
      )::jsonb ->> 'customer_id'
    )::uuid,
    p_effective_from => public.current_business_date(),
    p_based_on_version_id => (
      current_setting(
        'eliscaretex.validation.draft_published'
      )::jsonb -> 'published_schedule' ->> 'schedule_version_id'
    )::uuid,
    p_change_reason =>
      'Validate a second Customer Schedule draft.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
) as second_draft_creation_result;

select set_config(
  'eliscaretex.validation.second_draft_cancelled',
  public.cancel_customer_schedule_draft(
    p_schedule_version_id => (
      current_setting(
        'eliscaretex.validation.second_draft_created'
      )::jsonb ->> 'schedule_version_id'
    )::uuid,
    p_expected_row_version => (
      current_setting(
        'eliscaretex.validation.second_draft_created'
      )::jsonb -> 'draft' ->> 'row_version'
    )::integer,
    p_reason =>
      'Validate controlled Customer Schedule draft cancellation.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
) as cancelled_second_draft;

do $$
declare
  v_cancelled jsonb := current_setting(
    'eliscaretex.validation.second_draft_cancelled'
  )::jsonb;
begin
  if coalesce(v_cancelled ->> 'status', '') <> 'CANCELLED' then
    raise exception
      'Second draft cancellation did not return CANCELLED status. Payload: %',
      v_cancelled;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Function privileges
-- ---------------------------------------------------------------------

-- Expected authenticated_can_execute = true for every row.
select
  p.proname as function_name,
  has_function_privilege(
    'authenticated',
    p.oid,
    'EXECUTE'
  ) as authenticated_can_execute
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'get_customer_schedule_reference_data',
    'get_customer_schedule_management_state',
    'create_customer_schedule_management_draft',
    'save_customer_schedule_draft',
    'compare_customer_schedule_draft',
    'publish_customer_schedule_draft',
    'cancel_customer_schedule_draft',
    'restore_customer_schedule_management_draft'
  )
order by p.proname;

-- All draft, publication, child and audit records created by this validation
-- are discarded here.
rollback;
