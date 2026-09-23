-- =====================================================================
-- ElisCaretex V2
-- Validation:
-- 202608030003_customer_schedule_history_readability_validation.sql
--
-- Covered:
--   - protected history RPC privileges;
--   - readable history response separates original revision changes from restore impact;
--   - comparison between an old revision and the current published list;
--   - restore creates a new protected revision without rewriting history;
--   - restored content is compared against the current published revision;
--   - all temporary revisions and audit rows are rolled back.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Resolve one active ADMIN and a safe customer with a current schedule
-- ---------------------------------------------------------------------

select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
)
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (sr.effective_until is null or sr.effective_until >= current_date)
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
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
end;
$$;

select set_config(
  'eliscaretex.validation.schedule_history_setup',
  coalesce(
    (
      select jsonb_build_object(
        'customer_id', c.customer_id,
        'base_version_id', v.schedule_version_id,
        'base_version_number', v.version_number
      )::text
      from public.customer_schedule_versions v
      join public.customers c
        on c.customer_id = v.customer_id
      where v.status = 'PUBLISHED'
        and public.current_business_date() >= v.effective_from
        and (
          v.effective_until is null
          or public.current_business_date() <= v.effective_until
        )
        and c.active = true
        and c.deleted_at is null
        and exists (
          select 1
          from public.customer_schedule_days d
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        )
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
      order by c.customer_name, v.version_number desc
      limit 1
    ),
    ''
  ),
  true
);

do $$
declare
  v_setup jsonb := nullif(
    current_setting('eliscaretex.validation.schedule_history_setup', true),
    ''
  )::jsonb;
begin
  if v_setup is null
     or nullif(v_setup ->> 'customer_id', '') is null
     or nullif(v_setup ->> 'base_version_id', '') is null then
    raise exception
      'No safe active customer with a current published schedule was found.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Privileges and schema boundary
-- ---------------------------------------------------------------------

do $$
begin
  if not has_function_privilege(
       'authenticated',
       'public.get_customer_schedule_history(uuid,uuid,date,integer)',
       'EXECUTE'
     ) then
    raise exception 'History RPC is not executable by authenticated users.';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.build_customer_schedule_version_comparison(uuid,uuid)',
       'EXECUTE'
     ) then
    raise exception 'Internal comparison helper is directly executable.';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.restore_customer_schedule_management_draft(uuid,date,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Internal restore preparation RPC is directly executable.';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.restore_customer_schedule_version_as_update(uuid,date,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Controlled one-click restore RPC is not executable.';
  end if;

  -- information_schema.columns only exposes columns that the current role
  -- can access. The validation is intentionally running as `authenticated`,
  -- which must not have direct table privileges, so information_schema can
  -- hide a valid column and produce a false failure. pg_catalog is used here
  -- to verify the physical schema without weakening table permissions.
  if not exists (
    select 1
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c
      on c.oid = a.attrelid
    join pg_catalog.pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'customer_schedule_versions'
      and a.attname = 'restored_from_version_id'
      and a.attnum > 0
      and not a.attisdropped
  ) then
    raise exception 'Restore lineage column is missing.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Publish one temporary replacement revision
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.schedule_history_draft',
  public.create_customer_schedule_management_draft(
    p_customer_id => (
      current_setting('eliscaretex.validation.schedule_history_setup')::jsonb
        ->> 'customer_id'
    )::uuid,
    p_effective_from => public.current_business_date(),
    p_based_on_version_id => (
      current_setting('eliscaretex.validation.schedule_history_setup')::jsonb
        ->> 'base_version_id'
    )::uuid,
    p_change_reason => 'Validate Customer Schedule history publication.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

select set_config(
  'eliscaretex.validation.schedule_history_saved',
  public.save_customer_schedule_draft_with_auto_orders(
    p_schedule_version_id => (
      current_setting('eliscaretex.validation.schedule_history_draft')::jsonb
        ->> 'schedule_version_id'
    )::uuid,
    p_expected_row_version => (
      current_setting('eliscaretex.validation.schedule_history_draft')::jsonb
        -> 'draft' ->> 'row_version'
    )::integer,
    p_draft => jsonb_set(
      current_setting('eliscaretex.validation.schedule_history_draft')::jsonb
        -> 'draft',
      '{general_instructions}',
      to_jsonb('Temporary history validation update.'::text),
      true
    ),
    p_change_reason => 'Validate Customer Schedule history comparison.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

select set_config(
  'eliscaretex.validation.schedule_history_published',
  public.publish_customer_schedule_draft_with_order_normalization(
    p_schedule_version_id => (
      current_setting('eliscaretex.validation.schedule_history_saved')::jsonb
        ->> 'schedule_version_id'
    )::uuid,
    p_expected_row_version => (
      current_setting('eliscaretex.validation.schedule_history_saved')::jsonb
        ->> 'row_version'
    )::integer,
    p_change_reason => 'Publish temporary revision for history validation.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
declare
  v_setup jsonb := current_setting(
    'eliscaretex.validation.schedule_history_setup'
  )::jsonb;
  v_published jsonb := current_setting(
    'eliscaretex.validation.schedule_history_published'
  )::jsonb;
  v_new_version_id uuid := (
    v_published -> 'published_schedule' ->> 'schedule_version_id'
  )::uuid;
  v_new_version_number integer := (
    v_published -> 'published_schedule' ->> 'version_number'
  )::integer;
begin
  if v_new_version_id is null then
    raise exception 'Temporary replacement revision was not published.';
  end if;

  if v_new_version_number <= (v_setup ->> 'base_version_number')::integer then
    raise exception 'Published history revision number did not increase.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Read history and compare the old revision with the new current list
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.schedule_history_result',
  public.get_customer_schedule_history(
    p_customer_id => (
      current_setting('eliscaretex.validation.schedule_history_setup')::jsonb
        ->> 'customer_id'
    )::uuid,
    p_selected_version_id => (
      current_setting('eliscaretex.validation.schedule_history_setup')::jsonb
        ->> 'base_version_id'
    )::uuid,
    p_effective_date => public.current_business_date(),
    p_limit => 50
  )::text,
  true
);

do $$
declare
  v_history jsonb := current_setting(
    'eliscaretex.validation.schedule_history_result'
  )::jsonb;
  v_base_version_id uuid := (
    current_setting('eliscaretex.validation.schedule_history_setup')::jsonb
      ->> 'base_version_id'
  )::uuid;
  v_current_version_id uuid := (
    current_setting('eliscaretex.validation.schedule_history_published')::jsonb
      -> 'published_schedule' ->> 'schedule_version_id'
  )::uuid;
begin
  if v_history ->> 'selected_version_id' <> v_base_version_id::text then
    raise exception 'History did not return the requested selected revision.';
  end if;

  if v_history ->> 'current_version_id' <> v_current_version_id::text then
    raise exception 'History did not identify the temporary published revision as current.';
  end if;

  if jsonb_array_length(coalesce(v_history -> 'versions', '[]'::jsonb)) < 2 then
    raise exception 'History returned fewer than two revisions.';
  end if;

  if not (v_history ? 'change_comparison') then
    raise exception 'Readable history response is missing change_comparison.';
  end if;

  if not (v_history ? 'restore_comparison') then
    raise exception 'Readable history response is missing restore_comparison.';
  end if;

  if v_history -> 'change_comparison' ->> 'after_version_id'
     <> v_base_version_id::text then
    raise exception 'Revision change comparison does not end at the selected revision.';
  end if;

  if v_history -> 'restore_comparison' ->> 'before_version_id'
     <> v_current_version_id::text
     or v_history -> 'restore_comparison' ->> 'after_version_id'
     <> v_base_version_id::text then
    raise exception 'Restore impact is not comparing current to selected revision.';
  end if;

  if coalesce((v_history -> 'restore_comparison' ->> 'has_changes')::boolean, false)
     is not true then
    raise exception 'Restore impact did not detect the temporary change.';
  end if;

  if v_history -> 'comparison' is distinct from v_history -> 'restore_comparison' then
    raise exception 'Legacy comparison alias no longer matches restore_comparison.';
  end if;

  if coalesce((v_history -> 'permissions' ->> 'can_restore_version')::boolean, false)
     is not true then
    raise exception 'ADMIN restore permission was not returned.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Restore the old revision as a new protected working revision
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.schedule_history_restore',
  public.restore_customer_schedule_version_as_update(
    p_source_version_id => (
      current_setting('eliscaretex.validation.schedule_history_setup')::jsonb
        ->> 'base_version_id'
    )::uuid,
    p_effective_from => public.current_business_date(),
    p_reason => 'Validate protected historical restore.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

reset role;

do $$
declare
  v_restore jsonb := current_setting(
    'eliscaretex.validation.schedule_history_restore'
  )::jsonb;
  v_base_version_id uuid := (
    current_setting('eliscaretex.validation.schedule_history_setup')::jsonb
      ->> 'base_version_id'
  )::uuid;
  v_current_version_id uuid := (
    current_setting('eliscaretex.validation.schedule_history_published')::jsonb
      -> 'published_schedule' ->> 'schedule_version_id'
  )::uuid;
  v_restored_version_id uuid := (
    v_restore -> 'published_schedule' ->> 'schedule_version_id'
  )::uuid;
  v_record public.customer_schedule_versions%rowtype;
begin
  select *
  into v_record
  from public.customer_schedule_versions
  where schedule_version_id = v_restored_version_id;

  if not found then
    raise exception 'Restored working revision was not created.';
  end if;

  if v_record.status <> 'PUBLISHED' then
    raise exception 'Restored revision was not published as a new protected update.';
  end if;

  if v_record.restored_from_version_id <> v_base_version_id then
    raise exception 'Restore source lineage was not preserved.';
  end if;

  if v_record.based_on_version_id <> v_current_version_id then
    raise exception 'Restored revision is not compared against the current published revision.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_versions
    where customer_id = v_record.customer_id
      and status = 'DRAFT'
  ) then
    raise exception 'One-click restore left an open working revision.';
  end if;

  if coalesce((v_restore -> 'comparison' ->> 'has_changes')::boolean, false)
     is not true then
    raise exception 'Restore comparison did not detect changes against current.';
  end if;

  if not exists (
    select 1
    from public.customer_schedule_versions
    where schedule_version_id = v_base_version_id
      and status = 'SUPERSEDED'
  ) then
    raise exception 'The historical source revision was modified or lost.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608030003_customer_schedule_history_readability_validation',
  'history_read_model', true,
  'revision_change_summary', true,
  'restore_impact_summary', true,
  'safe_restore', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
