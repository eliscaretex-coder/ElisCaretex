create or replace function public.terminal_correct_sorting_trolley_intake(
  p_sorting_trolley_intake_id uuid,
  p_customer_id uuid,
  p_scheduled_for_date date,
  p_product_codes text[],
  p_contents_status text,
  p_operator_staff_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_intake public.sorting_trolley_intakes%rowtype;
  v_shift public.shifts%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_revision integer;
  v_actor_staff_id uuid := public.current_staff_id();
begin
  perform public.require_production_terminal('SORTING');

  if p_operator_staff_id is null then
    raise exception using errcode='22023', message='Select the Sorting staff member responsible for this trolley receipt.';
  end if;

  select *
  into v_intake
  from public.sorting_trolley_intakes
  where sorting_trolley_intake_id=p_sorting_trolley_intake_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Trolley intake record was not found.';
  end if;

  select *
  into v_shift
  from public.shifts
  where shift_id=v_intake.shift_id
    and active=true
    and deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(
      coalesce(public.get_sorting_staff_work_context_v2(v_shift.shift_code)->'staff','[]'::jsonb)
    ) staff_row
    where staff_row.value->>'staff_id'=p_operator_staff_id::text
  ) then
    raise exception using errcode='22023', message='Selected staff member is not active in Sorting for this shift.';
  end if;

  v_result := public.correct_sorting_trolley_intake(
    p_sorting_trolley_intake_id,
    p_customer_id,
    p_scheduled_for_date,
    p_product_codes,
    p_contents_status,
    p_reason
  );

  select to_jsonb(sti) || jsonb_build_object(
    'products',coalesce((
      select jsonb_agg(to_jsonb(stip) order by stip.product_code)
      from public.sorting_trolley_intake_products stip
      where stip.sorting_trolley_intake_id=sti.sorting_trolley_intake_id
    ),'[]'::jsonb)
  )
  into v_before
  from public.sorting_trolley_intakes sti
  where sti.sorting_trolley_intake_id=p_sorting_trolley_intake_id;

  if (v_before->>'operator_staff_id') is distinct from p_operator_staff_id::text then
    update public.sorting_trolley_intakes
    set operator_staff_id=p_operator_staff_id,
        correction_reason=p_reason,
        corrected_at=now(),
        corrected_by_auth_user_id=auth.uid(),
        revision_no=revision_no+1
    where sorting_trolley_intake_id=p_sorting_trolley_intake_id
    returning revision_no into v_revision;

    select to_jsonb(sti) || jsonb_build_object(
      'products',coalesce((
        select jsonb_agg(to_jsonb(stip) order by stip.product_code)
        from public.sorting_trolley_intake_products stip
        where stip.sorting_trolley_intake_id=sti.sorting_trolley_intake_id
      ),'[]'::jsonb)
    )
    into v_after
    from public.sorting_trolley_intakes sti
    where sti.sorting_trolley_intake_id=p_sorting_trolley_intake_id;

    insert into public.sorting_trolley_intake_revisions(
      sorting_trolley_intake_id,revision_no,action_type,reason,before_data,after_data,
      changed_by_auth_user_id,changed_by_staff_id
    )
    values(
      p_sorting_trolley_intake_id,v_revision,'CORRECTED',p_reason,v_before,v_after,
      auth.uid(),v_actor_staff_id
    );

    return jsonb_build_object('status','corrected','revision_no',v_revision,'sorting_trolley_intake_id',p_sorting_trolley_intake_id);
  end if;

  return v_result;
end;
$$;

revoke all on function public.terminal_correct_sorting_trolley_intake(uuid,uuid,date,text[],text,uuid,text) from public,anon,authenticated;
grant execute on function public.terminal_correct_sorting_trolley_intake(uuid,uuid,date,text[],text,uuid,text) to authenticated;
