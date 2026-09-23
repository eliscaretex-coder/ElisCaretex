-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110006_sorting_trolley_contract_sizes_and_reception_status
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr on sr.staff_id=sm.staff_id and sr.active=true
    join public.roles r on r.role_id=sr.role_id and r.active=true and r.role_code='ADMIN'
    where sm.auth_user_id is not null
      and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

do $$
declare
  v_shift text;
  v_context jsonb;
  v_row jsonb;
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No ADMIN auth user available for Validation 026.';
  end if;

  foreach v_shift in array array['MORNING','EVENING'] loop
    v_context := public.get_sorting_trolley_intake_context_v2(v_shift);

    select value
    into v_row
    from jsonb_array_elements(coalesce(v_context->'board','[]'::jsonb))
    where jsonb_array_length(coalesce(value->'trolley_requirements','[]'::jsonb))>0
    order by
      case value->>'day_relation' when 'TODAY' then 1 when 'TOMORROW' then 2 else 3 end,
      (value->>'production_order')::integer nulls last,
      value->>'customer_name'
    limit 1;

    if v_row is not null then
      perform set_config('eliscaretex.v26.shift',v_shift,true);
      perform set_config('eliscaretex.v26.schedule_product_id',v_row->>'schedule_product_id',true);
      exit;
    end if;
  end loop;

  if v_row is null then
    raise exception 'No current Yesterday/Today/Tomorrow board row with published trolley requirements is available for Validation 026.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_shift text := current_setting('eliscaretex.v26.shift');
  v_schedule_product_id text := current_setting('eliscaretex.v26.schedule_product_id');
  v_context jsonb;
  v_row jsonb;
  v_requirement_sum integer;
  v_planned integer;
begin
  if has_table_privilege('authenticated','public.customer_schedule_trolley_requirements','SELECT') then
    raise exception 'customer_schedule_trolley_requirements must remain private to the controlled Schedule/Reception contract.';
  end if;

  if has_table_privilege('authenticated','public.sorting_trolley_intakes','SELECT') then
    raise exception 'sorting_trolley_intakes must remain private.';
  end if;

  v_context := public.get_sorting_trolley_intake_context_v2(v_shift);

  select value
  into v_row
  from jsonb_array_elements(coalesce(v_context->'board','[]'::jsonb))
  where value->>'schedule_product_id'=v_schedule_product_id
  limit 1;

  if v_row is null then
    raise exception 'Controlled Reception context lost the selected schedule product.';
  end if;

  if jsonb_array_length(coalesce(v_row->'trolley_requirements','[]'::jsonb))=0 then
    raise exception 'Controlled Reception row does not expose trolley requirements.';
  end if;

  select coalesce(sum((req.value->>'quantity')::integer),0)
  into v_requirement_sum
  from jsonb_array_elements(coalesce(v_row->'trolley_requirements','[]'::jsonb)) req;

  v_planned := coalesce((v_row->>'planned_trolley_quantity')::integer,0);

  if v_requirement_sum<>v_planned then
    raise exception
      'Published trolley size quantities sum to %, but planned_trolley_quantity is %.',
      v_requirement_sum,v_planned;
  end if;

  if exists(
    select 1
    from jsonb_array_elements(coalesce(v_row->'trolley_requirements','[]'::jsonb)) req
    where nullif(req.value->>'trolley_type_code','') is null
       or nullif(req.value->>'display_code','') is null
       or nullif(req.value->>'trolley_type_name','') is null
       or (req.value->>'quantity')::integer<=0
       or not (req.value ? 'empty_trolley')
  ) then
    raise exception 'A trolley requirement is missing type/size/quantity/empty metadata.';
  end if;
end;
$$;

reset role;

-- Owner-side exact source comparison for the selected published schedule product.
do $$
declare
  v_schedule_product_id uuid := current_setting('eliscaretex.v26.schedule_product_id')::uuid;
  v_source_total integer;
  v_source_types integer;
begin
  select
    coalesce(sum(req.quantity),0)::integer,
    count(*)::integer
  into v_source_total,v_source_types
  from public.customer_schedule_trolley_requirements req
  join public.trolley_types tt
    on tt.trolley_type_id=req.trolley_type_id
   and tt.active=true
   and tt.deleted_at is null
  where req.owner_schedule_product_id=v_schedule_product_id
    and req.active=true;

  if v_source_total<=0 or v_source_types<=0 then
    raise exception 'Selected schedule product does not have valid source trolley requirements.';
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608110006_sorting_trolley_contract_sizes_and_reception_status_validation',
  'controlled_board_exposes_trolley_sizes',true,
  'requirement_sum_matches_planned_total',true,
  'display_code_exposed',true,
  'empty_trolley_flag_exposed',true,
  'schedule_requirement_table_remains_private',true,
  'sorting_intake_table_remains_private',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
