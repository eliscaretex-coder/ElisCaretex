-- Customer subunits and trolley plates.
--
-- Some customers (mostly MOP) have subunits: secondary names inside the customer,
-- for example BLOOMFIELD has D/BROOK, S/BROOK, KILAKEE, LAUREL, PERSON and
-- OWENDOHER. Each trolley of a delivery day carries a plate with the customer name
-- and, when it has one, the subunit name(s). Two subunits may share one trolley,
-- two trolleys may carry the same subunit, and a trolley may have no subunit.
--
-- 1. customer_subunits: the fixed list of subunits per customer, kept in Customer
--    Master. Subunits are never deleted, only deactivated, because published
--    schedules keep pointing at them.
-- 2. customer_schedule_trolley_plates: one optional plate per planned trolley
--    (plate 1..quantity of a trolley requirement row) with the subunits on it and
--    an on-screen instruction for the staff. Plates live in the versioned Customer
--    Schedule, so they can differ per production day and every change goes through
--    draft, reason and publish like the trolley quantities. A trolley without a
--    plate row shows only the customer name.
-- 3. Read and save RPCs for Customer Master, the schedule snapshot/save/copy
--    functions extended with plates, and a read RPC for Finish and MOP Production.
-- 4. Customer Master change history lists subunit changes (before -> after).
--
-- The five replaced functions (four schedule functions and the change history)
-- are the live definitions, checked by hash on 2026-10-29, with only the plate and
-- subunit additions.

-- 1. Tables -------------------------------------------------------------------

create table public.customer_subunits (
  subunit_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(customer_id),
  subunit_name text not null
    constraint customer_subunits_name_check
    check (subunit_name = btrim(subunit_name) and char_length(subunit_name) between 1 and 80),
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create index customer_subunits_customer_idx
  on public.customer_subunits(customer_id, sort_order);
create unique index customer_subunits_active_name_uidx
  on public.customer_subunits(customer_id, lower(subunit_name))
  where active;

create table public.customer_schedule_trolley_plates (
  plate_id uuid primary key default gen_random_uuid(),
  schedule_trolley_requirement_id uuid not null
    references public.customer_schedule_trolley_requirements(schedule_trolley_requirement_id)
    on delete cascade,
  plate_number integer not null
    constraint customer_schedule_trolley_plates_number_check check (plate_number between 1 and 100),
  subunit_ids uuid[] not null default '{}'::uuid[],
  instructions text
    constraint customer_schedule_trolley_plates_instructions_check
    check (instructions is null or char_length(instructions) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  constraint customer_schedule_trolley_plates_number_uniq
    unique (schedule_trolley_requirement_id, plate_number)
);

alter table public.customer_subunits enable row level security;
alter table public.customer_schedule_trolley_plates enable row level security;
revoke all on public.customer_subunits, public.customer_schedule_trolley_plates
  from public, anon, authenticated;

-- Plates follow the same rule as the other schedule children: only a DRAFT
-- revision may change. A cascade from a deleted draft trolley row is allowed.
create or replace function public.require_draft_schedule_plate_parent()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_requirement_id uuid;
  v_status text;
begin
  v_requirement_id := case when tg_op = 'DELETE'
    then old.schedule_trolley_requirement_id
    else new.schedule_trolley_requirement_id end;

  select v.status
  into v_status
  from public.customer_schedule_trolley_requirements r
  join public.customer_schedule_days d on d.schedule_day_id = r.schedule_day_id
  join public.customer_schedule_versions v on v.schedule_version_id = d.schedule_version_id
  where r.schedule_trolley_requirement_id = v_requirement_id;

  if not found and tg_op = 'DELETE' then
    return old;
  end if;

  if v_status is distinct from 'DRAFT' then
    raise exception 'Only DRAFT schedule revisions may be edited.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.require_draft_schedule_plate_parent() from public, anon, authenticated;

create trigger customer_schedule_trolley_plates_require_draft
  before insert or update or delete on public.customer_schedule_trolley_plates
  for each row execute function public.require_draft_schedule_plate_parent();

-- 2. Internal: plates of one trolley row as JSON -------------------------------

create or replace function public.customer_schedule_trolley_plates_json(
  p_schedule_trolley_requirement_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'plate_number', pl.plate_number,
      'subunit_ids', to_jsonb(pl.subunit_ids),
      'subunit_names', coalesce((
        select jsonb_agg(su.subunit_name order by s.ordinal)
        from unnest(pl.subunit_ids) with ordinality as s(subunit_id, ordinal)
        join public.customer_subunits su on su.subunit_id = s.subunit_id
      ), '[]'::jsonb),
      'instructions', pl.instructions
    )
    order by pl.plate_number
  ), '[]'::jsonb)
  from public.customer_schedule_trolley_plates pl
  where pl.schedule_trolley_requirement_id = p_schedule_trolley_requirement_id;
$$;

revoke all on function public.customer_schedule_trolley_plates_json(uuid) from public, anon, authenticated;

-- 3. Customer Master: read and save the subunits -------------------------------

create or replace function public.customer_subunits_json(p_customer_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'subunit_id', su.subunit_id,
      'subunit_name', su.subunit_name,
      'sort_order', su.sort_order
    )
    order by su.sort_order, lower(su.subunit_name)
  ), '[]'::jsonb)
  from public.customer_subunits su
  where su.customer_id = p_customer_id
    and su.active = true;
$$;

revoke all on function public.customer_subunits_json(uuid) from public, anon, authenticated;

create or replace function public.get_customer_subunits(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active authenticated account is required.';
  end if;

  if not public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'You do not have permission to view customers.';
  end if;

  if not exists (select 1 from public.customers c where c.customer_id = p_customer_id and c.deleted_at is null) then
    raise exception using errcode = 'P0002', message = 'Customer was not found.';
  end if;

  return jsonb_build_object(
    'customer_id', p_customer_id,
    'subunits', public.customer_subunits_json(p_customer_id)
  );
end;
$$;

revoke all on function public.get_customer_subunits(uuid) from public, anon;
grant execute on function public.get_customer_subunits(uuid) to authenticated;

-- p_subunits is the complete ordered list: [{subunit_id (optional), subunit_name}].
-- Rows with an id keep their identity (a rename shows everywhere); rows without an
-- id are new; active subunits missing from the list are deactivated.
create or replace function public.save_customer_subunits(
  p_customer_id uuid,
  p_subunits jsonb,
  p_change_reason text,
  p_source_application text default 'CUSTOMER_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_item jsonb;
  v_id uuid;
  v_name text;
  v_order integer := 0;
  v_names text[] := array[]::text[];
  v_kept uuid[] := array[]::uuid[];
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active authenticated account is required.';
  end if;

  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'You do not have permission to change customers.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason is required to change the subunits.';
  end if;

  if p_subunits is null or jsonb_typeof(p_subunits) <> 'array' then
    raise exception using errcode = '22023', message = 'The subunits must be a list.';
  end if;

  if jsonb_array_length(p_subunits) > 50 then
    raise exception using errcode = '22023', message = 'A customer cannot have more than 50 subunits.';
  end if;

  perform 1
  from public.customers c
  where c.customer_id = p_customer_id
    and c.active = true
    and c.deleted_at is null
  for update;

  if not found then
    raise exception using errcode = '55000', message = 'The customer is inactive or does not exist.';
  end if;

  -- Validate the whole list before changing anything.
  for v_item in select value from jsonb_array_elements(p_subunits)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception using errcode = '22023', message = 'Every subunit must be a JSON object.';
    end if;

    v_name := regexp_replace(trim(coalesce(v_item ->> 'subunit_name', '')), '\s+', ' ', 'g');

    if v_name = '' then
      raise exception using errcode = '22023', message = 'A subunit name is empty.';
    end if;

    if char_length(v_name) > 80 then
      raise exception using errcode = '22023', message = format('Subunit name "%s" is longer than 80 characters.', left(v_name, 30));
    end if;

    if lower(v_name) = any(v_names) then
      raise exception using errcode = '22023', message = format('Subunit "%s" appears more than once.', v_name);
    end if;

    v_names := array_append(v_names, lower(v_name));

    if nullif(trim(coalesce(v_item ->> 'subunit_id', '')), '') is not null then
      begin
        v_id := (v_item ->> 'subunit_id')::uuid;
      exception when others then
        raise exception using errcode = '22023', message = 'A subunit reference is invalid.';
      end;

      if not exists (
        select 1 from public.customer_subunits su
        where su.subunit_id = v_id and su.customer_id = p_customer_id and su.active
      ) then
        raise exception using errcode = '22023', message = format('Subunit "%s" does not belong to this customer. Reload and try again.', v_name);
      end if;

      if v_id = any(v_kept) then
        raise exception using errcode = '22023', message = 'The same subunit was submitted twice.';
      end if;

      v_kept := array_append(v_kept, v_id);
    end if;
  end loop;

  v_old := public.customer_subunits_json(p_customer_id);

  -- Deactivate first so a removed name can be reused by a new row.
  update public.customer_subunits
  set active = false, updated_at = now(), updated_by = auth.uid()
  where customer_id = p_customer_id
    and active
    and not (subunit_id = any(v_kept));

  for v_item in select value from jsonb_array_elements(p_subunits)
  loop
    v_order := v_order + 1;
    v_name := regexp_replace(trim(v_item ->> 'subunit_name'), '\s+', ' ', 'g');

    if nullif(trim(coalesce(v_item ->> 'subunit_id', '')), '') is not null then
      update public.customer_subunits
      set subunit_name = v_name, sort_order = v_order, updated_at = now(), updated_by = auth.uid()
      where subunit_id = (v_item ->> 'subunit_id')::uuid
        and (subunit_name is distinct from v_name or sort_order is distinct from v_order);
    else
      insert into public.customer_subunits (customer_id, subunit_name, sort_order, created_by, updated_by)
      values (p_customer_id, v_name, v_order, auth.uid(), auth.uid());
    end if;
  end loop;

  v_new := public.customer_subunits_json(p_customer_id);

  if v_new is distinct from v_old then
    insert into public.audit_log (
      actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
      old_data, new_data, reason, source_application
    )
    values (
      auth.uid(), public.current_staff_id(), 'SAVE_CUSTOMER_SUBUNITS', 'customers', p_customer_id::text,
      jsonb_build_object('subunits', (select coalesce(jsonb_agg(x -> 'subunit_name'), '[]'::jsonb) from jsonb_array_elements(v_old) x)),
      jsonb_build_object('subunits', (select coalesce(jsonb_agg(x -> 'subunit_name'), '[]'::jsonb) from jsonb_array_elements(v_new) x)),
      trim(p_change_reason), coalesce(nullif(trim(p_source_application), ''), 'CUSTOMER_MASTER_UI')
    );
  end if;

  return jsonb_build_object(
    'customer_id', p_customer_id,
    'changed', v_new is distinct from v_old,
    'subunits', v_new
  );
end;
$$;

revoke all on function public.save_customer_subunits(uuid, jsonb, text, text) from public, anon;
grant execute on function public.save_customer_subunits(uuid, jsonb, text, text) to authenticated;

-- 4. Schedule snapshot: every trolley row lists its plates ---------------

create or replace function public.build_customer_schedule_version_snapshot(
  p_schedule_version_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'schedule_version_id', v.schedule_version_id,
    'customer_id', v.customer_id,
    'customer_code', c.customer_code,
    'customer_name', c.customer_name,
    'version_number', v.version_number,
    'status', v.status,
    'effective_from', v.effective_from,
    'effective_until', v.effective_until,
    'based_on_version_id', v.based_on_version_id,
    'source_code', v.source_code,
    'change_reason', v.change_reason,
    'general_instructions', v.general_instructions,
    'created_at', v.created_at,
    'updated_at', v.updated_at,
    'published_at', v.published_at,
    'superseded_at', v.superseded_at,
    'cancelled_at', v.cancelled_at,
    'row_version', v.row_version,
    'days', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'schedule_day_id', d.schedule_day_id,
            'production_weekday', d.production_weekday,
            'production_day', public.weekday_name(d.production_weekday),
            'delivery_weekday', d.delivery_weekday,
            'delivery_day', case
              when d.delivery_weekday is null then null
              else public.weekday_name(d.delivery_weekday)
            end,
            'default_route_id', d.default_route_id,
            'default_route', case
              when r.route_id is null then null
              else jsonb_build_object(
                'route_id', r.route_id,
                'route_code', r.route_code,
                'display_name', r.display_name,
                'route_color', r.route_color,
                'route_kind', r.route_kind
              )
            end,
            'delivery_window_start', d.delivery_window_start,
            'delivery_window_end', d.delivery_window_end,
            'delivery_order', d.delivery_order,
            'day_alert', d.day_alert,
            'distribution_instructions', d.distribution_instructions,
            'active', d.active,
            'row_version', d.row_version,
            'products', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'schedule_product_id', p.schedule_product_id,
                    'product_type_id', p.product_type_id,
                    'product_code', pt.product_code,
                    'display_name', pt.display_name,
                    'production_order', p.production_order,
                    'expected_kg', p.expected_kg,
                    'expected_units', p.expected_units,
                    'production_instructions', p.production_instructions,
                    'active', p.active,
                    'row_version', p.row_version,
                    'variant_codes', coalesce(
                      (
                        select jsonb_agg(
                          pv.variant_code
                          order by pv.sort_order, pv.variant_code
                        )
                        from public.customer_schedule_product_variants spv
                        join public.product_variants pv
                          on pv.product_variant_id = spv.product_variant_id
                        where spv.schedule_product_id = p.schedule_product_id
                      ),
                      '[]'::jsonb
                    ),
                    'variants', coalesce(
                      (
                        select jsonb_agg(
                          jsonb_build_object(
                            'product_variant_id', pv.product_variant_id,
                            'variant_code', pv.variant_code,
                            'display_name', pv.display_name
                          )
                          order by pv.sort_order, pv.variant_code
                        )
                        from public.customer_schedule_product_variants spv
                        join public.product_variants pv
                          on pv.product_variant_id = spv.product_variant_id
                        where spv.schedule_product_id = p.schedule_product_id
                      ),
                      '[]'::jsonb
                    )
                  )
                  order by pt.sort_order, p.production_order nulls last,
                           pt.product_code
                )
                from public.customer_schedule_products p
                join public.product_types pt
                  on pt.product_type_id = p.product_type_id
                where p.schedule_day_id = d.schedule_day_id
                  and p.active = true
              ),
              '[]'::jsonb
            ),
            'trolley_requirements', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'schedule_trolley_requirement_id',
                      req.schedule_trolley_requirement_id,
                    'trolley_type_id', req.trolley_type_id,
                    'trolley_type_code', tt.trolley_type_code,
                    'trolley_type_name', tt.trolley_type_name,
                    'display_code', coalesce(
                      tt.display_code,
                      tt.trolley_type_code
                    ),
                    'owner_product_code', owner_pt.product_code,
                    'quantity', req.quantity,
                    'empty_trolley', req.empty_trolley,
                    'notes', req.notes,
                    'active', req.active,
                    'row_version', req.row_version,
                    'serves_product_codes', coalesce(
                      (
                        select jsonb_agg(
                          served_pt.product_code
                          order by served_pt.sort_order,
                                   served_pt.product_code
                        )
                        from public.customer_schedule_trolley_requirement_products map
                        join public.customer_schedule_products served_product
                          on served_product.schedule_product_id =
                             map.schedule_product_id
                        join public.product_types served_pt
                          on served_pt.product_type_id =
                             served_product.product_type_id
                        where map.schedule_trolley_requirement_id =
                          req.schedule_trolley_requirement_id
                      ),
                      '[]'::jsonb
                    ),
                    'plates', public.customer_schedule_trolley_plates_json(
                      req.schedule_trolley_requirement_id
                    )
                  )
                  order by tt.sort_order,
                           owner_pt.sort_order,
                           req.created_at,
                           req.schedule_trolley_requirement_id
                )
                from public.customer_schedule_trolley_requirements req
                join public.trolley_types tt
                  on tt.trolley_type_id = req.trolley_type_id
                join public.customer_schedule_products owner_product
                  on owner_product.schedule_product_id =
                     req.owner_schedule_product_id
                join public.product_types owner_pt
                  on owner_pt.product_type_id = owner_product.product_type_id
                where req.schedule_day_id = d.schedule_day_id
                  and req.active = true
              ),
              '[]'::jsonb
            )
          )
          order by d.production_weekday
        )
        from public.customer_schedule_days d
        left join public.distribution_routes r
          on r.route_id = d.default_route_id
        where d.schedule_version_id = v.schedule_version_id
          and d.active = true
      ),
      '[]'::jsonb
    )
  )
  into v_result
  from public.customer_schedule_versions v
  join public.customers c
    on c.customer_id = v.customer_id
  where v.schedule_version_id = p_schedule_version_id
    and c.deleted_at is null;

  return v_result;
end;
$$;

-- 5. Comparable snapshot: a plate-only change counts as a change ---------

create or replace function public.build_customer_schedule_comparable_snapshot(
  p_schedule_version_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_full jsonb;
  v_result jsonb;
begin
  v_full := public.build_customer_schedule_version_snapshot(
    p_schedule_version_id
  );

  if v_full is null then
    return null;
  end if;

  select jsonb_build_object(
    'effective_from', v_full -> 'effective_from',
    'effective_until', v_full -> 'effective_until',
    'general_instructions', v_full -> 'general_instructions',
    'days', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'production_weekday', day_row -> 'production_weekday',
            'delivery_weekday', day_row -> 'delivery_weekday',
            'default_route_id', day_row -> 'default_route_id',
            'delivery_window_start', day_row -> 'delivery_window_start',
            'delivery_window_end', day_row -> 'delivery_window_end',
            'delivery_order', day_row -> 'delivery_order',
            'day_alert', day_row -> 'day_alert',
            'distribution_instructions',
              day_row -> 'distribution_instructions',
            'products', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'product_code', product_row -> 'product_code',
                    'production_order', product_row -> 'production_order',
                    'expected_kg', product_row -> 'expected_kg',
                    'expected_units', product_row -> 'expected_units',
                    'production_instructions',
                      product_row -> 'production_instructions',
                    'variant_codes', product_row -> 'variant_codes'
                  )
                  order by product_row ->> 'product_code'
                )
                from jsonb_array_elements(
                  coalesce(day_row -> 'products', '[]'::jsonb)
                ) as product_items(product_row)
              ),
              '[]'::jsonb
            ),
            'trolley_requirements', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'trolley_type_code',
                      requirement_row -> 'trolley_type_code',
                    'owner_product_code',
                      requirement_row -> 'owner_product_code',
                    'quantity', requirement_row -> 'quantity',
                    'empty_trolley',
                      requirement_row -> 'empty_trolley',
                    'notes', requirement_row -> 'notes',
                    'serves_product_codes',
                      requirement_row -> 'serves_product_codes',
                    'plates', coalesce(
                      (
                        select jsonb_agg(
                          jsonb_build_object(
                            'plate_number', plate_row -> 'plate_number',
                            'subunit_ids', plate_row -> 'subunit_ids',
                            'instructions', plate_row -> 'instructions'
                          )
                          order by (plate_row ->> 'plate_number')::integer
                        )
                        from jsonb_array_elements(
                          coalesce(requirement_row -> 'plates', '[]'::jsonb)
                        ) as plate_items(plate_row)
                      ),
                      '[]'::jsonb
                    )
                  )
                  order by requirement_row ->> 'trolley_type_code',
                           requirement_row ->> 'owner_product_code',
                           requirement_row ->> 'quantity',
                           requirement_row ->> 'notes'
                )
                from jsonb_array_elements(
                  coalesce(
                    day_row -> 'trolley_requirements',
                    '[]'::jsonb
                  )
                ) as requirement_items(requirement_row)
              ),
              '[]'::jsonb
            )
          )
          order by (day_row ->> 'production_weekday')::integer
        )
        from jsonb_array_elements(
          coalesce(v_full -> 'days', '[]'::jsonb)
        ) as day_items(day_row)
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
end;
$$;

-- 6. Save draft: validate and store the plates ---------------------------

create or replace function public.save_customer_schedule_draft(
  p_schedule_version_id uuid,
  p_expected_row_version integer,
  p_draft jsonb,
  p_change_reason text,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version public.customer_schedule_versions%rowtype;
  v_effective_from date;
  v_effective_until date;
  v_old_snapshot jsonb;
  v_new_snapshot jsonb;
  v_day jsonb;
  v_product jsonb;
  v_requirement jsonb;
  v_variant_code text;
  v_served_code text;
  v_weekday smallint;
  v_delivery_weekday smallint;
  v_route_id uuid;
  v_delivery_window_start time;
  v_delivery_window_end time;
  v_delivery_order integer;
  v_day_id uuid;
  v_product_id uuid;
  v_product_type_id uuid;
  v_variant_id uuid;
  v_requirement_id uuid;
  v_trolley_type_id uuid;
  v_owner_product_id uuid;
  v_served_product_id uuid;
  v_product_code text;
  v_owner_product_code text;
  v_trolley_type_code text;
  v_quantity integer;
  v_empty_trolley boolean;
  v_seen_weekdays smallint[] := array[]::smallint[];
  v_seen_product_codes text[];
  v_seen_variant_codes text[];
  v_seen_served_codes text[];
  v_product_map jsonb;
  v_product_count integer;
  v_day_count integer;
  v_plate jsonb;
  v_plate_number integer;
  v_seen_plate_numbers integer[];
  v_subunit_text text;
  v_subunit_id uuid;
  v_seen_subunit_ids uuid[];
begin
  perform public.require_customer_schedule_edit_role();

  if nullif(trim(p_change_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'A reason is required to save schedule changes.';
  end if;

  if p_expected_row_version is null then
    raise exception using
      errcode = '22023',
      message = 'The expected draft row version is required.';
  end if;

  if p_draft is null or jsonb_typeof(p_draft) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'The draft payload must be a JSON object.';
  end if;

  if jsonb_typeof(coalesce(p_draft -> 'days', 'null'::jsonb))
     is distinct from 'array' then
    raise exception using
      errcode = '22023',
      message = 'The draft payload must contain a days array.';
  end if;

  select *
  into v_version
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Schedule draft not found.';
  end if;

  if v_version.status <> 'DRAFT' then
    raise exception using
      errcode = '55000',
      message = 'Only a DRAFT schedule revision can be saved.';
  end if;

  if v_version.row_version <> p_expected_row_version then
    raise exception using
      errcode = '40001',
      message = 'The schedule draft was changed by another user.',
      detail = format(
        'Expected row_version %s but current row_version is %s.',
        p_expected_row_version,
        v_version.row_version
      ),
      hint = 'Reload the draft before applying your changes again.';
  end if;

  if not exists (
    select 1
    from public.customers c
    where c.customer_id = v_version.customer_id
      and c.active = true
      and c.deleted_at is null
  ) then
    raise exception using
      errcode = '55000',
      message = 'The customer is inactive or does not exist.';
  end if;

  begin
    v_effective_from := nullif(
      trim(p_draft ->> 'effective_from'),
      ''
    )::date;
  exception when others then
    raise exception using
      errcode = '22023',
      message = 'The draft effective_from value is invalid.';
  end;

  if v_effective_from is null then
    raise exception using
      errcode = '22023',
      message = 'The draft effective date is required.';
  end if;

  if v_effective_from < public.current_business_date() then
    raise exception using
      errcode = '22023',
      message = 'The draft effective date cannot be before the current business date.';
  end if;

  begin
    v_effective_until := nullif(
      trim(p_draft ->> 'effective_until'),
      ''
    )::date;
  exception when others then
    raise exception using
      errcode = '22023',
      message = 'The draft effective_until value is invalid.';
  end;

  if v_effective_until is not null
     and v_effective_until < v_effective_from then
    raise exception using
      errcode = '22023',
      message = 'The schedule end date cannot be before its effective date.';
  end if;

  v_day_count := jsonb_array_length(p_draft -> 'days');

  if v_day_count = 0 then
    raise exception using
      errcode = '22023',
      message = 'The schedule must contain at least one production day.';
  end if;

  if v_day_count > 7 then
    raise exception using
      errcode = '22023',
      message = 'The weekly schedule cannot contain more than seven days.';
  end if;

  -- Validate the entire submitted document before deleting the current draft
  -- children. Any error aborts the transaction and leaves the draft unchanged.
  for v_day in
    select value
    from jsonb_array_elements(p_draft -> 'days')
  loop
    if jsonb_typeof(v_day) <> 'object' then
      raise exception using
        errcode = '22023',
        message = 'Every days item must be a JSON object.';
    end if;

    begin
      v_weekday := nullif(
        trim(v_day ->> 'production_weekday'),
        ''
      )::smallint;
    exception when others then
      raise exception using
        errcode = '22023',
        message = 'A production_weekday value is invalid.';
    end;

    if v_weekday is null or v_weekday not between 1 and 7 then
      raise exception using
        errcode = '22023',
        message = 'production_weekday must be between 1 and 7.';
    end if;

    if v_weekday = any(v_seen_weekdays) then
      raise exception using
        errcode = '22023',
        message = format(
          'Production weekday %s appears more than once.',
          v_weekday
        );
    end if;

    v_seen_weekdays := array_append(v_seen_weekdays, v_weekday);

    if jsonb_typeof(coalesce(v_day -> 'products', 'null'::jsonb))
       is distinct from 'array' then
      raise exception using
        errcode = '22023',
        message = format(
          'The products value for %s must be an array.',
          public.weekday_name(v_weekday)
        );
    end if;

    v_product_count := jsonb_array_length(v_day -> 'products');

    if v_product_count = 0 then
      raise exception using
        errcode = '22023',
        message = format(
          '%s must contain at least one product.',
          public.weekday_name(v_weekday)
        );
    end if;

    v_seen_product_codes := array[]::text[];

    for v_product in
      select value
      from jsonb_array_elements(v_day -> 'products')
    loop
      v_product_code := upper(trim(coalesce(
        v_product ->> 'product_code',
        ''
      )));

      if v_product_code = '' then
        raise exception using
          errcode = '22023',
          message = format(
            'A product code is missing for %s.',
            public.weekday_name(v_weekday)
          );
      end if;

      if v_product_code = any(v_seen_product_codes) then
        raise exception using
          errcode = '22023',
          message = format(
            'Product %s appears more than once on %s.',
            v_product_code,
            public.weekday_name(v_weekday)
          );
      end if;

      v_seen_product_codes := array_append(
        v_seen_product_codes,
        v_product_code
      );

      if not exists (
        select 1
        from public.customer_product_services service
        join public.product_types pt
          on pt.product_type_id = service.product_type_id
        where service.customer_id = v_version.customer_id
          and service.active = true
          and service.deleted_at is null
          and service.effective_from <= v_effective_from
          and (
            service.effective_until is null
            or service.effective_until >= v_effective_from
          )
          and pt.product_code = v_product_code
          and pt.active = true
          and pt.deleted_at is null
          and coalesce(
            (pt.metadata ->> 'schedule_enabled')::boolean,
            true
          )
      ) then
        raise exception using
          errcode = '22023',
          message = format(
            'Product %s is not enabled for this customer on %s.',
            v_product_code,
            v_effective_from
          );
      end if;

      if jsonb_typeof(
           coalesce(v_product -> 'variant_codes', '[]'::jsonb)
         ) <> 'array' then
        raise exception using
          errcode = '22023',
          message = format(
            'variant_codes for %s must be an array.',
            v_product_code
          );
      end if;

      v_seen_variant_codes := array[]::text[];

      for v_variant_code in
        select upper(trim(value))
        from jsonb_array_elements_text(
          coalesce(v_product -> 'variant_codes', '[]'::jsonb)
        )
      loop
        if v_variant_code = '' then
          raise exception using
            errcode = '22023',
            message = format(
              'An empty product variant was submitted for %s.',
              v_product_code
            );
        end if;

        if v_variant_code = any(v_seen_variant_codes) then
          raise exception using
            errcode = '22023',
            message = format(
              'Variant %s appears more than once for %s.',
              v_variant_code,
              v_product_code
            );
        end if;

        v_seen_variant_codes := array_append(
          v_seen_variant_codes,
          v_variant_code
        );

        if not exists (
          select 1
          from public.product_variants pv
          join public.product_types pt
            on pt.product_type_id = pv.product_type_id
          where pt.product_code = v_product_code
            and pv.variant_code = v_variant_code
            and pv.active = true
            and pv.deleted_at is null
        ) then
          raise exception using
            errcode = '22023',
            message = format(
              'Variant %s is not active for product %s.',
              v_variant_code,
              v_product_code
            );
        end if;
      end loop;
    end loop;

    if jsonb_typeof(
         coalesce(v_day -> 'trolley_requirements', '[]'::jsonb)
       ) <> 'array' then
      raise exception using
        errcode = '22023',
        message = format(
          'The trolley requirements value for %s must be an array.',
          public.weekday_name(v_weekday)
        );
    end if;

    for v_requirement in
      select value
      from jsonb_array_elements(
        coalesce(v_day -> 'trolley_requirements', '[]'::jsonb)
      )
    loop
      v_trolley_type_code := upper(trim(coalesce(
        v_requirement ->> 'trolley_type_code',
        ''
      )));
      v_owner_product_code := upper(trim(coalesce(
        v_requirement ->> 'owner_product_code',
        ''
      )));

      if not exists (
        select 1
        from public.trolley_types tt
        where tt.trolley_type_code = v_trolley_type_code
          and tt.active = true
          and tt.deleted_at is null
          and tt.allowed_in_customer_schedule = true
      ) then
        raise exception using
          errcode = '22023',
          message = format(
            'Trolley type %s is not allowed in Customer Schedules.',
            coalesce(nullif(v_trolley_type_code, ''), '[missing]')
          );
      end if;

      if not (v_owner_product_code = any(v_seen_product_codes)) then
        raise exception using
          errcode = '22023',
          message = format(
            'Trolley owner product %s is not scheduled on %s.',
            coalesce(nullif(v_owner_product_code, ''), '[missing]'),
            public.weekday_name(v_weekday)
          );
      end if;

      begin
        v_quantity := nullif(
          trim(v_requirement ->> 'quantity'),
          ''
        )::integer;
      exception when others then
        raise exception using
          errcode = '22023',
          message = 'A trolley quantity value is invalid.';
      end;

      if v_quantity is null or v_quantity <= 0 then
        raise exception using
          errcode = '22023',
          message = 'Every trolley requirement quantity must be greater than zero.';
      end if;

      if jsonb_typeof(
           coalesce(
             v_requirement -> 'serves_product_codes',
             'null'::jsonb
           )
         ) is distinct from 'array' then
        raise exception using
          errcode = '22023',
          message = 'serves_product_codes must be an array.';
      end if;

      if jsonb_array_length(
           v_requirement -> 'serves_product_codes'
         ) = 0 then
        raise exception using
          errcode = '22023',
          message = 'Every trolley requirement must serve at least one product.';
      end if;

      v_seen_served_codes := array[]::text[];

      for v_served_code in
        select upper(trim(value))
        from jsonb_array_elements_text(
          v_requirement -> 'serves_product_codes'
        )
      loop
        if not (v_served_code = any(v_seen_product_codes)) then
          raise exception using
            errcode = '22023',
            message = format(
              'Trolley served product %s is not scheduled on %s.',
              v_served_code,
              public.weekday_name(v_weekday)
            );
        end if;

        if v_served_code = any(v_seen_served_codes) then
          raise exception using
            errcode = '22023',
            message = format(
              'Trolley served product %s appears more than once.',
              v_served_code
            );
        end if;

        v_seen_served_codes := array_append(
          v_seen_served_codes,
          v_served_code
        );
      end loop;

      if not (v_owner_product_code = any(v_seen_served_codes)) then
        raise exception using
          errcode = '22023',
          message = 'The trolley owner product must also be included in serves_product_codes.';
      end if;

      -- Trolley plates: optional subunit names and instruction per trolley.
      if jsonb_typeof(
           coalesce(v_requirement -> 'plates', '[]'::jsonb)
         ) <> 'array' then
        raise exception using
          errcode = '22023',
          message = 'Trolley plates must be an array.';
      end if;

      v_seen_plate_numbers := array[]::integer[];

      for v_plate in
        select value
        from jsonb_array_elements(
          coalesce(v_requirement -> 'plates', '[]'::jsonb)
        )
      loop
        if jsonb_typeof(v_plate) <> 'object' then
          raise exception using
            errcode = '22023',
            message = 'Every trolley plate must be a JSON object.';
        end if;

        begin
          v_plate_number := nullif(
            trim(v_plate ->> 'plate_number'),
            ''
          )::integer;
        exception when others then
          raise exception using
            errcode = '22023',
            message = 'A trolley plate number is invalid.';
        end;

        if v_plate_number is null
           or v_plate_number < 1
           or v_plate_number > v_quantity then
          raise exception using
            errcode = '22023',
            message = format(
              'Trolley plate %s does not exist: only %s %s trolley(s) are planned on %s.',
              coalesce(v_plate_number::text, '[missing]'),
              v_quantity,
              v_trolley_type_code,
              public.weekday_name(v_weekday)
            );
        end if;

        if v_plate_number = any(v_seen_plate_numbers) then
          raise exception using
            errcode = '22023',
            message = format(
              'Trolley plate %s appears more than once on %s.',
              v_plate_number,
              public.weekday_name(v_weekday)
            );
        end if;

        v_seen_plate_numbers := array_append(
          v_seen_plate_numbers,
          v_plate_number
        );

        if jsonb_typeof(
             coalesce(v_plate -> 'subunit_ids', '[]'::jsonb)
           ) <> 'array' then
          raise exception using
            errcode = '22023',
            message = 'Trolley plate subunits must be an array.';
        end if;

        v_seen_subunit_ids := array[]::uuid[];

        for v_subunit_text in
          select value
          from jsonb_array_elements_text(
            coalesce(v_plate -> 'subunit_ids', '[]'::jsonb)
          )
        loop
          begin
            v_subunit_id := v_subunit_text::uuid;
          exception when others then
            raise exception using
              errcode = '22023',
              message = 'A trolley plate subunit reference is invalid.';
          end;

          if v_subunit_id = any(v_seen_subunit_ids) then
            raise exception using
              errcode = '22023',
              message = 'The same subunit appears twice on one trolley plate.';
          end if;

          if not exists (
            select 1
            from public.customer_subunits su
            where su.subunit_id = v_subunit_id
              and su.customer_id = v_version.customer_id
              and su.active = true
          ) then
            raise exception using
              errcode = '22023',
              message = format(
                'A subunit on %s trolley plate %s is not an active subunit of this customer. Check the subunits in Customer Master.',
                public.weekday_name(v_weekday),
                v_plate_number
              );
          end if;

          v_seen_subunit_ids := array_append(
            v_seen_subunit_ids,
            v_subunit_id
          );
        end loop;

        if char_length(coalesce(v_plate ->> 'instructions', '')) > 500 then
          raise exception using
            errcode = '22023',
            message = 'A trolley plate instruction cannot be longer than 500 characters.';
        end if;
      end loop;
    end loop;

    begin
      v_delivery_weekday := nullif(
        trim(v_day ->> 'delivery_weekday'),
        ''
      )::smallint;
    exception when others then
      raise exception using
        errcode = '22023',
        message = format(
          'The delivery weekday for %s is invalid.',
          public.weekday_name(v_weekday)
        );
    end;

    if v_delivery_weekday is not null
       and v_delivery_weekday not between 1 and 7 then
      raise exception using
        errcode = '22023',
        message = 'delivery_weekday must be between 1 and 7.';
    end if;

    begin
      v_route_id := nullif(
        trim(v_day ->> 'default_route_id'),
        ''
      )::uuid;
    exception when others then
      raise exception using
        errcode = '22023',
        message = format(
          'The default route for %s is invalid.',
          public.weekday_name(v_weekday)
        );
    end;

    if v_route_id is not null
       and not exists (
         select 1
         from public.distribution_routes r
         where r.route_id = v_route_id
           and r.active = true
           and r.deleted_at is null
           and r.allow_as_default = true
       ) then
      raise exception using
        errcode = '22023',
        message = format(
          'The selected default route for %s is inactive or unavailable.',
          public.weekday_name(v_weekday)
        );
    end if;

    begin
      v_delivery_window_start := nullif(
        trim(v_day ->> 'delivery_window_start'),
        ''
      )::time;
      v_delivery_window_end := nullif(
        trim(v_day ->> 'delivery_window_end'),
        ''
      )::time;
      v_delivery_order := nullif(
        trim(v_day ->> 'delivery_order'),
        ''
      )::integer;
    exception when others then
      raise exception using
        errcode = '22023',
        message = format(
          'A delivery planning value for %s is invalid.',
          public.weekday_name(v_weekday)
        );
    end;

    if v_delivery_window_start is not null
       and v_delivery_window_end is not null
       and v_delivery_window_end <= v_delivery_window_start then
      raise exception using
        errcode = '22023',
        message = format(
          'The delivery window for %s must end after it starts.',
          public.weekday_name(v_weekday)
        );
    end if;

    if v_delivery_order is not null and v_delivery_order <= 0 then
      raise exception using
        errcode = '22023',
        message = 'delivery_order must be greater than zero.';
    end if;
  end loop;

  v_old_snapshot := public.build_customer_schedule_version_snapshot(
    p_schedule_version_id
  );

  -- Delete only the mutable DRAFT child records, in dependency order.
  delete from public.customer_schedule_trolley_plates plate
  where plate.schedule_trolley_requirement_id in (
    select req.schedule_trolley_requirement_id
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_trolley_requirement_products map
  where map.schedule_trolley_requirement_id in (
    select req.schedule_trolley_requirement_id
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_trolley_requirements req
  where req.schedule_day_id in (
    select d.schedule_day_id
    from public.customer_schedule_days d
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_product_variants spv
  where spv.schedule_product_id in (
    select p.schedule_product_id
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_products p
  where p.schedule_day_id in (
    select d.schedule_day_id
    from public.customer_schedule_days d
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_days d
  where d.schedule_version_id = p_schedule_version_id;

  -- Insert the validated replacement document.
  for v_day in
    select value
    from jsonb_array_elements(p_draft -> 'days')
    order by (value ->> 'production_weekday')::integer
  loop
    v_weekday := (v_day ->> 'production_weekday')::smallint;
    v_delivery_weekday := nullif(
      trim(v_day ->> 'delivery_weekday'),
      ''
    )::smallint;
    v_route_id := nullif(
      trim(v_day ->> 'default_route_id'),
      ''
    )::uuid;
    v_delivery_window_start := nullif(
      trim(v_day ->> 'delivery_window_start'),
      ''
    )::time;
    v_delivery_window_end := nullif(
      trim(v_day ->> 'delivery_window_end'),
      ''
    )::time;
    v_delivery_order := nullif(
      trim(v_day ->> 'delivery_order'),
      ''
    )::integer;

    insert into public.customer_schedule_days (
      schedule_version_id,
      production_weekday,
      delivery_weekday,
      default_route_id,
      delivery_window_start,
      delivery_window_end,
      delivery_order,
      day_alert,
      distribution_instructions,
      active,
      metadata,
      created_by,
      updated_by
    )
    values (
      p_schedule_version_id,
      v_weekday,
      v_delivery_weekday,
      v_route_id,
      v_delivery_window_start,
      v_delivery_window_end,
      v_delivery_order,
      nullif(trim(v_day ->> 'day_alert'), ''),
      nullif(trim(v_day ->> 'distribution_instructions'), ''),
      true,
      '{}'::jsonb,
      auth.uid(),
      auth.uid()
    )
    returning schedule_day_id into v_day_id;

    v_product_map := '{}'::jsonb;

    for v_product in
      select value
      from jsonb_array_elements(v_day -> 'products')
    loop
      v_product_code := upper(trim(v_product ->> 'product_code'));

      select pt.product_type_id
      into v_product_type_id
      from public.product_types pt
      where pt.product_code = v_product_code
        and pt.active = true
        and pt.deleted_at is null;

      insert into public.customer_schedule_products (
        schedule_day_id,
        product_type_id,
        production_order,
        expected_kg,
        expected_units,
        production_instructions,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        v_day_id,
        v_product_type_id,
        nullif(trim(v_product ->> 'production_order'), '')::integer,
        nullif(trim(v_product ->> 'expected_kg'), '')::numeric,
        nullif(trim(v_product ->> 'expected_units'), '')::integer,
        nullif(trim(v_product ->> 'production_instructions'), ''),
        true,
        '{}'::jsonb,
        auth.uid(),
        auth.uid()
      )
      returning schedule_product_id into v_product_id;

      v_product_map := jsonb_set(
        v_product_map,
        array[v_product_code],
        to_jsonb(v_product_id::text),
        true
      );

      for v_variant_code in
        select upper(trim(value))
        from jsonb_array_elements_text(
          coalesce(v_product -> 'variant_codes', '[]'::jsonb)
        )
      loop
        select pv.product_variant_id
        into v_variant_id
        from public.product_variants pv
        where pv.product_type_id = v_product_type_id
          and pv.variant_code = v_variant_code
          and pv.active = true
          and pv.deleted_at is null;

        insert into public.customer_schedule_product_variants (
          schedule_product_id,
          product_variant_id,
          created_by
        )
        values (
          v_product_id,
          v_variant_id,
          auth.uid()
        );
      end loop;
    end loop;

    for v_requirement in
      select value
      from jsonb_array_elements(
        coalesce(v_day -> 'trolley_requirements', '[]'::jsonb)
      )
    loop
      v_trolley_type_code := upper(trim(
        v_requirement ->> 'trolley_type_code'
      ));
      v_owner_product_code := upper(trim(
        v_requirement ->> 'owner_product_code'
      ));
      v_quantity := (v_requirement ->> 'quantity')::integer;
      v_empty_trolley := coalesce(
        (v_requirement ->> 'empty_trolley')::boolean,
        false
      );

      select tt.trolley_type_id
      into v_trolley_type_id
      from public.trolley_types tt
      where tt.trolley_type_code = v_trolley_type_code
        and tt.active = true
        and tt.deleted_at is null
        and tt.allowed_in_customer_schedule = true;

      v_owner_product_id := (
        v_product_map ->> v_owner_product_code
      )::uuid;

      insert into public.customer_schedule_trolley_requirements (
        schedule_day_id,
        trolley_type_id,
        owner_schedule_product_id,
        quantity,
        empty_trolley,
        notes,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        v_day_id,
        v_trolley_type_id,
        v_owner_product_id,
        v_quantity,
        v_empty_trolley,
        nullif(trim(v_requirement ->> 'notes'), ''),
        true,
        '{}'::jsonb,
        auth.uid(),
        auth.uid()
      )
      returning schedule_trolley_requirement_id
      into v_requirement_id;

      -- A plate without subunits and without an instruction shows only the
      -- customer name, so it is not stored.
      insert into public.customer_schedule_trolley_plates (
        schedule_trolley_requirement_id,
        plate_number,
        subunit_ids,
        instructions,
        created_by
      )
      select
        v_requirement_id,
        (plate_row ->> 'plate_number')::integer,
        array(
          select subunit_item.value::uuid
          from jsonb_array_elements_text(
            coalesce(plate_row -> 'subunit_ids', '[]'::jsonb)
          ) with ordinality as subunit_item(value, ordinal)
          order by subunit_item.ordinal
        ),
        nullif(trim(plate_row ->> 'instructions'), ''),
        auth.uid()
      from jsonb_array_elements(
        coalesce(v_requirement -> 'plates', '[]'::jsonb)
      ) as plate_items(plate_row)
      where jsonb_array_length(coalesce(plate_row -> 'subunit_ids', '[]'::jsonb)) > 0
         or nullif(trim(plate_row ->> 'instructions'), '') is not null;

      for v_served_code in
        select upper(trim(value))
        from jsonb_array_elements_text(
          v_requirement -> 'serves_product_codes'
        )
      loop
        v_served_product_id := (
          v_product_map ->> v_served_code
        )::uuid;

        insert into public.customer_schedule_trolley_requirement_products (
          schedule_trolley_requirement_id,
          schedule_product_id,
          created_by
        )
        values (
          v_requirement_id,
          v_served_product_id,
          auth.uid()
        );
      end loop;
    end loop;
  end loop;

  update public.customer_schedule_versions
  set
    effective_from = v_effective_from,
    effective_until = v_effective_until,
    general_instructions = nullif(
      trim(p_draft ->> 'general_instructions'),
      ''
    ),
    change_reason = trim(p_change_reason),
    updated_by = auth.uid()
  where schedule_version_id = p_schedule_version_id;

  v_new_snapshot := public.build_customer_schedule_version_snapshot(
    p_schedule_version_id
  );

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'SAVE_CUSTOMER_SCHEDULE_DRAFT',
    'customer_schedule_versions',
    p_schedule_version_id::text,
    v_old_snapshot,
    v_new_snapshot,
    trim(p_change_reason),
    p_source_application
  );

  return v_new_snapshot;
end;
$$;

-- 7. New draft copies the plates of its base version ---------------------

create or replace function public.create_customer_schedule_draft(p_customer_id uuid, p_effective_from date, p_based_on_version_id uuid DEFAULT NULL::uuid, p_change_reason text DEFAULT NULL::text, p_source_application text DEFAULT 'CUSTOMER_SCHEDULE_MANAGEMENT'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_base_version_id uuid;
  v_new_version_id uuid;
  v_new_version_number integer;
  v_new_day_id uuid;
  v_new_product_id uuid;
  v_new_requirement_id uuid;
  v_day_map jsonb := '{}'::jsonb;
  v_product_map jsonb := '{}'::jsonb;
  v_old_day record;
  v_old_product record;
  v_old_requirement record;
  v_old_mapping record;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for schedule draft creation.';
  end if;

  if p_effective_from is null then
    raise exception 'The proposed effective date is required.';
  end if;

  if not exists (
    select 1
    from public.customers
    where customer_id = p_customer_id
      and active = true
      and deleted_at is null
  ) then
    raise exception 'Customer is not active or does not exist.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_versions
    where customer_id = p_customer_id
      and status = 'DRAFT'
  ) then
    raise exception 'This customer already has an open schedule draft.';
  end if;

  v_base_version_id := p_based_on_version_id;

  if v_base_version_id is not null then
    if not exists (
      select 1
      from public.customer_schedule_versions
      where schedule_version_id = v_base_version_id
        and customer_id = p_customer_id
        and status in ('PUBLISHED', 'SUPERSEDED', 'CANCELLED')
    ) then
      raise exception 'The selected base schedule does not belong to this customer or cannot be copied.';
    end if;
  else
    select schedule_version_id
    into v_base_version_id
    from public.customer_schedule_versions
    where customer_id = p_customer_id
      and status = 'PUBLISHED'
      and effective_from <= p_effective_from
    order by effective_from desc, version_number desc
    limit 1;
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_new_version_number
  from public.customer_schedule_versions
  where customer_id = p_customer_id;

  insert into public.customer_schedule_versions (
    customer_id,
    version_number,
    status,
    effective_from,
    based_on_version_id,
    source_code,
    change_reason,
    created_by,
    updated_by
  )
  values (
    p_customer_id,
    v_new_version_number,
    'DRAFT',
    p_effective_from,
    v_base_version_id,
    'MANUAL',
    nullif(trim(p_change_reason), ''),
    auth.uid(),
    auth.uid()
  )
  returning schedule_version_id into v_new_version_id;

  if v_base_version_id is not null then
    for v_old_day in
      select *
      from public.customer_schedule_days
      where schedule_version_id = v_base_version_id
        and active = true
      order by production_weekday
    loop
      insert into public.customer_schedule_days (
        schedule_version_id,
        production_weekday,
        delivery_weekday,
        default_route_id,
        delivery_window_start,
        delivery_window_end,
        delivery_order,
        day_alert,
        distribution_instructions,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        v_new_version_id,
        v_old_day.production_weekday,
        v_old_day.delivery_weekday,
        v_old_day.default_route_id,
        v_old_day.delivery_window_start,
        v_old_day.delivery_window_end,
        v_old_day.delivery_order,
        v_old_day.day_alert,
        v_old_day.distribution_instructions,
        v_old_day.active,
        v_old_day.metadata,
        auth.uid(),
        auth.uid()
      )
      returning schedule_day_id into v_new_day_id;

      v_day_map := jsonb_set(
        v_day_map,
        array[v_old_day.schedule_day_id::text],
        to_jsonb(v_new_day_id::text),
        true
      );

      for v_old_product in
        select *
        from public.customer_schedule_products
        where schedule_day_id = v_old_day.schedule_day_id
          and active = true
        order by production_order nulls last, created_at
      loop
        insert into public.customer_schedule_products (
          schedule_day_id,
          product_type_id,
          production_order,
          expected_kg,
          expected_units,
          production_instructions,
          active,
          metadata,
          created_by,
          updated_by
        )
        values (
          v_new_day_id,
          v_old_product.product_type_id,
          v_old_product.production_order,
          v_old_product.expected_kg,
          v_old_product.expected_units,
          v_old_product.production_instructions,
          v_old_product.active,
          v_old_product.metadata,
          auth.uid(),
          auth.uid()
        )
        returning schedule_product_id into v_new_product_id;

        v_product_map := jsonb_set(
          v_product_map,
          array[v_old_product.schedule_product_id::text],
          to_jsonb(v_new_product_id::text),
          true
        );

        insert into public.customer_schedule_product_variants (
          schedule_product_id,
          product_variant_id,
          created_by
        )
        select
          v_new_product_id,
          old_variant.product_variant_id,
          auth.uid()
        from public.customer_schedule_product_variants old_variant
        where old_variant.schedule_product_id = v_old_product.schedule_product_id;
      end loop;
    end loop;

    for v_old_requirement in
      select *
      from public.customer_schedule_trolley_requirements
      where schedule_day_id in (
        select schedule_day_id
        from public.customer_schedule_days
        where schedule_version_id = v_base_version_id
      )
        and active = true
      order by created_at
    loop
      insert into public.customer_schedule_trolley_requirements (
        schedule_day_id,
        trolley_type_id,
        owner_schedule_product_id,
        quantity,
        empty_trolley,
        notes,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        (v_day_map ->> v_old_requirement.schedule_day_id::text)::uuid,
        v_old_requirement.trolley_type_id,
        (v_product_map ->> v_old_requirement.owner_schedule_product_id::text)::uuid,
        v_old_requirement.quantity,
        v_old_requirement.empty_trolley,
        v_old_requirement.notes,
        v_old_requirement.active,
        v_old_requirement.metadata,
        auth.uid(),
        auth.uid()
      )
      returning schedule_trolley_requirement_id into v_new_requirement_id;

      -- Copy the trolley plates; subunits removed from Customer Master are dropped.
      insert into public.customer_schedule_trolley_plates (
        schedule_trolley_requirement_id,
        plate_number,
        subunit_ids,
        instructions,
        created_by
      )
      select
        v_new_requirement_id,
        old_plate.plate_number,
        array(
          select su.subunit_id
          from unnest(old_plate.subunit_ids) with ordinality as old_subunit(subunit_id, ordinal)
          join public.customer_subunits su
            on su.subunit_id = old_subunit.subunit_id
           and su.active = true
          order by old_subunit.ordinal
        ),
        old_plate.instructions,
        auth.uid()
      from public.customer_schedule_trolley_plates old_plate
      where old_plate.schedule_trolley_requirement_id =
          v_old_requirement.schedule_trolley_requirement_id
        and old_plate.plate_number <= v_old_requirement.quantity;

      for v_old_mapping in
        select schedule_product_id
        from public.customer_schedule_trolley_requirement_products
        where schedule_trolley_requirement_id =
          v_old_requirement.schedule_trolley_requirement_id
      loop
        insert into public.customer_schedule_trolley_requirement_products (
          schedule_trolley_requirement_id,
          schedule_product_id,
          created_by
        )
        values (
          v_new_requirement_id,
          (v_product_map ->> v_old_mapping.schedule_product_id::text)::uuid,
          auth.uid()
        );
      end loop;
    end loop;
  end if;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'CREATE_CUSTOMER_SCHEDULE_DRAFT',
    'customer_schedule_versions',
    v_new_version_id::text,
    jsonb_build_object(
      'customer_id', p_customer_id,
      'version_number', v_new_version_number,
      'effective_from', p_effective_from,
      'based_on_version_id', v_base_version_id
    ),
    nullif(trim(p_change_reason), ''),
    p_source_application
  );

  return v_new_version_id;
end;
$function$;

-- 8. Customer Master change history shows subunit changes ---------------

create or replace function public.get_customer_master_change_history(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_customer public.customers%rowtype;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'Permission denied for customer history.';
  end if;

  select * into v_customer
  from public.customers
  where customer_id = p_customer_id and deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Customer not found.';
  end if;

  return jsonb_build_object(
    'customer_id', v_customer.customer_id,
    'customer_code', v_customer.customer_code,
    'customer_name', v_customer.customer_name,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'audit_id', a.audit_id,
        'occurred_at', a.occurred_at,
        'action', a.action,
        'actor_name', coalesce(
          public.production_roster_actor_name(a.actor_auth_user_id, a.actor_staff_id),
          case
            when a.source_application like 'LEGACY_SYNC%' then 'Legacy sync (Apps Script)'
            when a.source_application like 'APPS_SCRIPT%' then 'Apps Script import'
            when a.source_application like 'migration%' then 'System migration'
          end
        ),
        'reason', a.reason,
        'source_application', a.source_application,
        'changes', coalesce((
          select jsonb_agg(jsonb_build_object(
            'field', f.field_key,
            'label', f.label,
            'before', a.old_data -> f.field_key,
            'after', a.new_data -> f.field_key
          ) order by f.sort_order)
          from (values
            ('customer_code', 'Customer code', 1),
            ('customer_name', 'Customer name', 2),
            ('eircode', 'Eircode', 3),
            ('distribution_estimated_kg', 'Estimated KG', 4),
            ('distribution_stop_count', 'Stops', 5),
            ('notes', 'General notes', 6),
            ('operational_alert', 'Operational alert', 7),
            ('product_services', 'Services', 8),
            ('active', 'Active', 9),
            ('deactivation_reason', 'Deactivation reason', 10),
            ('subunits', 'Subunits', 11)
          ) as f(field_key, label, sort_order)
          where a.old_data ? f.field_key
            and a.new_data ? f.field_key
            and a.old_data -> f.field_key is distinct from a.new_data -> f.field_key
        ), '[]'::jsonb)
      ) order by a.occurred_at desc, a.audit_id)
      from (
        select *
        from public.audit_log l
        where l.entity_table = 'customers'
          and l.entity_id = p_customer_id::text
        order by l.occurred_at desc
        limit 200
      ) a
    ), '[]'::jsonb)
  );
end;
$$;

-- 9. Finish and MOP Production: the trolleys of one production item ------------
--
-- One row per planned trolley of the schedule product behind the production item,
-- including shared trolleys owned by another product (MOP carried in a Clothes
-- trolley). A trolley without a plate row shows the customer name only.

create or replace function public.get_production_flow_trolley_plates(
  p_production_flow_item_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_item public.production_flow_items%rowtype;
  v_trolleys jsonb;
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active account or registered production computer is required.';
  end if;

  if not (
    public.account_module_allowed(array['FINISH'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR'])
    or public.account_module_allowed(array['MOP'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR','MOP_OPERATOR'])
    or public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR'])
  ) then
    raise exception using errcode = '42501', message = 'Your role cannot see the trolley plates.';
  end if;

  select * into v_item
  from public.production_flow_items
  where production_flow_item_id = p_production_flow_item_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'Production item was not found.';
  end if;

  with req as (
    select
      r.schedule_trolley_requirement_id,
      r.quantity,
      r.empty_trolley,
      r.notes,
      tt.trolley_type_code,
      coalesce(tt.display_code, tt.trolley_type_code) as display_code,
      tt.trolley_type_name,
      tt.sort_order as trolley_sort,
      owner_pt.product_code as owner_product_code,
      r.created_at,
      coalesce((
        select array_agg(served_pt.product_code order by served_pt.sort_order, served_pt.product_code)
        from public.customer_schedule_trolley_requirement_products map
        join public.customer_schedule_products served on served.schedule_product_id = map.schedule_product_id
        join public.product_types served_pt on served_pt.product_type_id = served.product_type_id
        where map.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
      ), array[]::text[]) as serves_product_codes
    from public.customer_schedule_trolley_requirements r
    join public.trolley_types tt on tt.trolley_type_id = r.trolley_type_id
    join public.customer_schedule_products owner_product on owner_product.schedule_product_id = r.owner_schedule_product_id
    join public.product_types owner_pt on owner_pt.product_type_id = owner_product.product_type_id
    where r.active = true
      and v_item.source_schedule_product_id is not null
      and (
        r.owner_schedule_product_id = v_item.source_schedule_product_id
        or exists (
          select 1 from public.customer_schedule_trolley_requirement_products map
          where map.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
            and map.schedule_product_id = v_item.source_schedule_product_id
        )
      )
  ), expanded as (
    select req.*, n.plate_number, pl.subunit_ids, pl.instructions
    from req
    cross join lateral generate_series(1, req.quantity) as n(plate_number)
    left join public.customer_schedule_trolley_plates pl
      on pl.schedule_trolley_requirement_id = req.schedule_trolley_requirement_id
     and pl.plate_number = n.plate_number
  ), named as (
    select e.*,
      coalesce((
        select array_agg(su.subunit_name order by s.ordinal)
        from unnest(e.subunit_ids) with ordinality as s(subunit_id, ordinal)
        join public.customer_subunits su on su.subunit_id = s.subunit_id
      ), array[]::text[]) as subunit_names
    from expanded e
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'schedule_trolley_requirement_id', n.schedule_trolley_requirement_id,
      'trolley_type_code', n.trolley_type_code,
      'display_code', n.display_code,
      'trolley_type_name', n.trolley_type_name,
      'owner_product_code', n.owner_product_code,
      'serves_product_codes', to_jsonb(n.serves_product_codes),
      'shared_with_other_product', cardinality(n.serves_product_codes) > 1
        or n.owner_product_code is distinct from v_item.product_code,
      'empty_trolley', n.empty_trolley,
      'row_notes', n.notes,
      'plate_number', n.plate_number,
      'row_quantity', n.quantity,
      'subunit_names', to_jsonb(n.subunit_names),
      'subunit_label', nullif(array_to_string(n.subunit_names, ' & '), ''),
      'instructions', n.instructions
    )
    order by n.trolley_sort, n.owner_product_code, n.created_at, n.schedule_trolley_requirement_id, n.plate_number
  ), '[]'::jsonb)
  into v_trolleys
  from named n;

  return jsonb_build_object(
    'production_flow_item_id', v_item.production_flow_item_id,
    'customer_id', v_item.customer_id,
    'customer_code', v_item.customer_code_snapshot,
    'customer_name', coalesce((select c.customer_name from public.customers c where c.customer_id = v_item.customer_id), v_item.customer_name_snapshot),
    'product_code', v_item.product_code,
    'scheduled_for_date', v_item.scheduled_for_date,
    'trolley_count', jsonb_array_length(v_trolleys),
    'trolleys', v_trolleys
  );
end;
$$;

revoke all on function public.get_production_flow_trolley_plates(uuid) from public, anon;
grant execute on function public.get_production_flow_trolley_plates(uuid) to authenticated;

comment on table public.customer_subunits is
  'Subunits (secondary names) of a customer, kept in Customer Master and printed on trolley plates. Deactivated, never deleted.';
comment on table public.customer_schedule_trolley_plates is
  'Optional plate per planned trolley of a Customer Schedule trolley row: subunits on the trolley and an on-screen instruction for the staff.';
comment on function public.save_customer_subunits(uuid, jsonb, text, text) is
  'Customer Master: replaces the ordered subunit list of a customer (CUSTOMERS:EDIT). Audited.';
comment on function public.get_production_flow_trolley_plates(uuid) is
  'Finish / MOP Production: one row per planned trolley of a production item with its subunits and instruction.';
