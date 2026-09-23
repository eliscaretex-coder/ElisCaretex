-- ElisCaretex V2
-- Migration 042: governed Trolley Type Master management
-- Date: 2026-08-12
-- Purpose:
--   - expose trolley type dimensions/tare/reference usage through governed RPCs;
--   - allow ADMIN/MANAGER to create and edit physical trolley types;
--   - keep technical type codes immutable after creation;
--   - keep new types out of Customer Schedule by default;
--   - prevent deactivation while a type is still used by active physical trolleys
--     or active schedule requirements;
--   - preserve private source-table boundaries.

create or replace function public.require_trolley_type_master_write_access()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null
     or public.current_staff_id() is null
     or not public.has_any_role(array['ADMIN','MANAGER']) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow Trolley Type Master changes.';
  end if;
end;
$$;

revoke all on function public.require_trolley_type_master_write_access() from public, anon, authenticated;

create or replace function public.get_trolley_lifecycle_capabilities()
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select jsonb_build_object(
    'can_view_trolleys', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
        'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
        'FINISH_OPERATOR', 'MOP_OPERATOR'
      ]
    ),
    'can_assign_trolleys_from_production', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR', 'MOP_OPERATOR']
    ),
    'can_assign_finish_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR']
    ),
    'can_assign_mop_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'MOP_OPERATOR']
    ),
    'can_view_distribution_handoff', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'DISTRIBUTION_OPERATOR', 'AUDITOR']
    ),
    'can_dispatch_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR']
    ),
    'can_receive_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']
    ),
    'can_confirm_sorting_arrival', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']
    ),
    'can_view_trolley_exceptions', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR']
    ),
    'can_review_trolley_exceptions', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR']
    ),
    'can_manage_trolley_master', public.has_any_role(
      array['ADMIN', 'MANAGER']
    ),
    'can_manage_trolley_types', public.has_any_role(
      array['ADMIN', 'MANAGER']
    )
  );
$$;

revoke all on function public.get_trolley_lifecycle_capabilities() from public, anon;
grant execute on function public.get_trolley_lifecycle_capabilities() to authenticated;

create or replace function public.get_trolley_reference_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_warning_days integer;
  v_overdue_days integer;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  select coalesce((value_json #>> '{}')::integer, 14)
  into v_warning_days
  from public.app_config
  where config_key = 'trolley_warning_days';

  select coalesce((value_json #>> '{}')::integer, 30)
  into v_overdue_days
  from public.app_config
  where config_key = 'trolley_overdue_days';

  return jsonb_build_object(
    'capabilities', public.get_trolley_lifecycle_capabilities(),
    'warning_days', coalesce(v_warning_days, 14),
    'overdue_days', coalesce(v_overdue_days, 30),
    'delivery_tracking_mode', 'PRODUCTION_NEXT_DAY_INFERENCE',
    'customers', case
      when public.has_any_role(array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']) then
        coalesce(
          (
            select jsonb_agg(
              jsonb_build_object(
                'customer_id', c.customer_id,
                'customer_code', c.customer_code,
                'customer_name', c.customer_name
              ) order by lower(c.customer_name), c.customer_code
            )
            from public.customers c
            where c.active = true
              and c.deleted_at is null
          ),
          '[]'::jsonb
        )
      else '[]'::jsonb
    end,
    'trolley_types', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'trolley_type_id', tt.trolley_type_id,
            'trolley_type_code', tt.trolley_type_code,
            'trolley_type_name', tt.trolley_type_name,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'trolley_category', tt.trolley_category,
            'footprint_length_cm', tt.footprint_length_cm,
            'footprint_width_cm', tt.footprint_width_cm,
            'footprint_area_m2', case
              when tt.footprint_length_cm is not null and tt.footprint_width_cm is not null
                then round((tt.footprint_length_cm * tt.footprint_width_cm / 10000.0)::numeric, 3)
              else null
            end,
            'tare_weight_kg', tt.tare_weight_kg,
            'allowed_in_customer_schedule', tt.allowed_in_customer_schedule
          ) order by tt.sort_order, tt.trolley_type_code
        )
        from public.trolley_types tt
        where tt.active = true
          and tt.deleted_at is null
      ),
      '[]'::jsonb
    )
  );
end;
$$;

revoke all on function public.get_trolley_reference_data() from public, anon;
grant execute on function public.get_trolley_reference_data() to authenticated;

create or replace function public.get_trolley_type_master()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_items jsonb := '[]'::jsonb;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'trolley_type_id', tt.trolley_type_id,
      'trolley_type_code', tt.trolley_type_code,
      'trolley_type_name', tt.trolley_type_name,
      'display_code', coalesce(tt.display_code, tt.trolley_type_code),
      'trolley_category', tt.trolley_category,
      'allowed_in_customer_schedule', tt.allowed_in_customer_schedule,
      'sort_order', tt.sort_order,
      'active', tt.active,
      'footprint_length_cm', tt.footprint_length_cm,
      'footprint_width_cm', tt.footprint_width_cm,
      'footprint_area_m2', case
        when tt.footprint_length_cm is not null and tt.footprint_width_cm is not null
          then round((tt.footprint_length_cm * tt.footprint_width_cm / 10000.0)::numeric, 3)
        else null
      end,
      'tare_weight_kg', tt.tare_weight_kg,
      'notes', nullif(coalesce(tt.metadata->>'trolley_type_notes',''),''),
      'physical_trolley_count', coalesce(usage.physical_trolley_count,0),
      'active_physical_trolley_count', coalesce(usage.active_physical_trolley_count,0),
      'schedule_requirement_count', coalesce(req.schedule_requirement_count,0),
      'active_schedule_requirement_count', coalesce(req.active_schedule_requirement_count,0),
      'created_at', tt.created_at,
      'updated_at', tt.updated_at
    )
    order by tt.sort_order, coalesce(tt.display_code,tt.trolley_type_code), tt.trolley_type_code
  ), '[]'::jsonb)
  into v_items
  from public.trolley_types tt
  left join lateral (
    select
      count(*)::integer as physical_trolley_count,
      count(*) filter(
        where t.active=true and t.deleted_at is null and t.status<>'RETIRED'
      )::integer as active_physical_trolley_count
    from public.trolleys t
    where t.trolley_type_id=tt.trolley_type_id
      and t.deleted_at is null
  ) usage on true
  left join lateral (
    select
      count(*)::integer as schedule_requirement_count,
      count(*) filter(where r.active=true)::integer as active_schedule_requirement_count
    from public.customer_schedule_trolley_requirements r
    where r.trolley_type_id=tt.trolley_type_id
  ) req on true
  where tt.deleted_at is null;

  return jsonb_build_object(
    'items', v_items,
    'can_manage', public.has_any_role(array['ADMIN','MANAGER']),
    'schedule_type_governance', 'NEW_TYPES_NOT_ALLOWED_BY_DEFAULT',
    'technical_code_contract', 'IMMUTABLE_AFTER_CREATE',
    'source', 'TROLLEY_TYPE_MASTER'
  );
end;
$$;

revoke all on function public.get_trolley_type_master() from public, anon;
grant execute on function public.get_trolley_type_master() to authenticated;

create or replace function public.create_trolley_type_master(
  p_trolley_type_code text,
  p_display_code text,
  p_trolley_type_name text,
  p_trolley_category text default 'STANDARD',
  p_footprint_length_cm numeric default null,
  p_footprint_width_cm numeric default null,
  p_tare_weight_kg numeric default null,
  p_sort_order integer default 100,
  p_notes text default null,
  p_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_code text := upper(trim(coalesce(p_trolley_type_code,'')));
  v_display text := upper(trim(coalesce(p_display_code,'')));
  v_name text := nullif(trim(coalesce(p_trolley_type_name,'')),'');
  v_category text := upper(trim(coalesce(p_trolley_category,'STANDARD')));
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_row public.trolley_types%rowtype;
  v_actor_staff_id uuid := public.current_staff_id();
begin
  perform public.require_trolley_type_master_write_access();

  if v_code='' or v_code !~ '^[A-Z0-9][A-Z0-9_]{0,39}$' then
    raise exception using errcode='22023', message='Trolley type code must use 1-40 uppercase letters, numbers or underscores.';
  end if;
  if v_name is null or length(v_name)>120 then
    raise exception using errcode='22023', message='Trolley type name is required and must be 120 characters or fewer.';
  end if;
  if exists(select 1 from public.trolley_types tt where tt.trolley_type_code=v_code) then
    raise exception using errcode='23505', message='Trolley type code already exists.';
  end if;
  if v_display='' then v_display:=v_code; end if;
  if length(v_display)>20 or v_display !~ '^[A-Z0-9][A-Z0-9_-]{0,19}$' then
    raise exception using errcode='22023', message='Display code must use 1-20 uppercase letters, numbers, underscores or hyphens.';
  end if;
  if v_category not in ('STANDARD','SPECIAL') then
    raise exception using errcode='22023', message='Trolley category must be STANDARD or SPECIAL.';
  end if;
  if exists(
    select 1 from public.trolley_types tt
    where tt.deleted_at is null and upper(coalesce(tt.display_code,tt.trolley_type_code))=v_display
  ) then
    raise exception using errcode='23505', message='Trolley type display code already exists.';
  end if;
  if (p_footprint_length_cm is null) <> (p_footprint_width_cm is null) then
    raise exception using errcode='22023', message='Enter both trolley footprint length and width, or leave both empty.';
  end if;
  if p_footprint_length_cm is not null and p_footprint_length_cm<=0 then
    raise exception using errcode='22023', message='Trolley footprint length must be greater than zero.';
  end if;
  if p_footprint_width_cm is not null and p_footprint_width_cm<=0 then
    raise exception using errcode='22023', message='Trolley footprint width must be greater than zero.';
  end if;
  if p_tare_weight_kg is not null and p_tare_weight_kg<=0 then
    raise exception using errcode='22023', message='Trolley tare weight must be greater than zero.';
  end if;
  if coalesce(p_sort_order,0)<0 then
    raise exception using errcode='22023', message='Sort order cannot be negative.';
  end if;
  if v_notes is not null and length(v_notes)>1500 then
    raise exception using errcode='22023', message='Trolley type notes must be 1500 characters or fewer.';
  end if;

  insert into public.trolley_types(
    trolley_type_code,trolley_type_name,active,display_code,trolley_category,
    allowed_in_customer_schedule,sort_order,metadata,
    footprint_length_cm,footprint_width_cm,tare_weight_kg
  ) values (
    v_code,v_name,coalesce(p_active,true),v_display,v_category,
    false,coalesce(p_sort_order,100),
    jsonb_build_object('source','TROLLEY_TYPE_MASTER_UI') ||
      case when v_notes is null then '{}'::jsonb else jsonb_build_object('trolley_type_notes',v_notes) end,
    p_footprint_length_cm,p_footprint_width_cm,p_tare_weight_kg
  )
  returning * into v_row;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    new_data,reason,source_application
  ) values (
    auth.uid(),v_actor_staff_id,'CREATE_TROLLEY_TYPE_MASTER','trolley_types',v_row.trolley_type_id::text,
    to_jsonb(v_row),v_notes,'TROLLEY_TYPE_MASTER_UI'
  );

  return jsonb_build_object(
    'status','success',
    'trolley_type_id',v_row.trolley_type_id,
    'trolley_type_code',v_row.trolley_type_code,
    'allowed_in_customer_schedule',v_row.allowed_in_customer_schedule,
    'message',format('Trolley type %s created. Customer Schedule use remains disabled until separately governed.',v_row.trolley_type_code)
  );
end;
$$;

revoke all on function public.create_trolley_type_master(text,text,text,text,numeric,numeric,numeric,integer,text,boolean) from public, anon;
grant execute on function public.create_trolley_type_master(text,text,text,text,numeric,numeric,numeric,integer,text,boolean) to authenticated;

create or replace function public.update_trolley_type_master(
  p_trolley_type_id uuid,
  p_display_code text,
  p_trolley_type_name text,
  p_trolley_category text,
  p_footprint_length_cm numeric,
  p_footprint_width_cm numeric,
  p_tare_weight_kg numeric,
  p_sort_order integer,
  p_notes text,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_old public.trolley_types%rowtype;
  v_new public.trolley_types%rowtype;
  v_display text := upper(trim(coalesce(p_display_code,'')));
  v_name text := nullif(trim(coalesce(p_trolley_type_name,'')),'');
  v_category text := upper(trim(coalesce(p_trolley_category,'')));
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_actor_staff_id uuid := public.current_staff_id();
  v_active_trolleys integer := 0;
  v_active_requirements integer := 0;
begin
  perform public.require_trolley_type_master_write_access();

  if p_trolley_type_id is null then
    raise exception using errcode='22023', message='Trolley type is required.';
  end if;

  select * into v_old
  from public.trolley_types tt
  where tt.trolley_type_id=p_trolley_type_id
    and tt.deleted_at is null
  for update;

  if not found then
    raise exception using errcode='P0002', message='Trolley type was not found.';
  end if;

  if v_name is null or length(v_name)>120 then
    raise exception using errcode='22023', message='Trolley type name is required and must be 120 characters or fewer.';
  end if;
  if v_display='' then v_display:=v_old.trolley_type_code; end if;
  if length(v_display)>20 or v_display !~ '^[A-Z0-9][A-Z0-9_-]{0,19}$' then
    raise exception using errcode='22023', message='Display code must use 1-20 uppercase letters, numbers, underscores or hyphens.';
  end if;
  if v_category not in ('STANDARD','SPECIAL') then
    raise exception using errcode='22023', message='Trolley category must be STANDARD or SPECIAL.';
  end if;
  if exists(
    select 1 from public.trolley_types tt
    where tt.deleted_at is null
      and tt.trolley_type_id<>v_old.trolley_type_id
      and upper(coalesce(tt.display_code,tt.trolley_type_code))=v_display
  ) then
    raise exception using errcode='23505', message='Trolley type display code already exists.';
  end if;
  if (p_footprint_length_cm is null) <> (p_footprint_width_cm is null) then
    raise exception using errcode='22023', message='Enter both trolley footprint length and width, or leave both empty.';
  end if;
  if p_footprint_length_cm is not null and p_footprint_length_cm<=0 then
    raise exception using errcode='22023', message='Trolley footprint length must be greater than zero.';
  end if;
  if p_footprint_width_cm is not null and p_footprint_width_cm<=0 then
    raise exception using errcode='22023', message='Trolley footprint width must be greater than zero.';
  end if;
  if p_tare_weight_kg is not null and p_tare_weight_kg<=0 then
    raise exception using errcode='22023', message='Trolley tare weight must be greater than zero.';
  end if;
  if coalesce(p_sort_order,0)<0 then
    raise exception using errcode='22023', message='Sort order cannot be negative.';
  end if;
  if v_notes is not null and length(v_notes)>1500 then
    raise exception using errcode='22023', message='Trolley type notes must be 1500 characters or fewer.';
  end if;

  if v_old.active=true and coalesce(p_active,v_old.active)=false then
    select count(*)::integer into v_active_trolleys
    from public.trolleys t
    where t.trolley_type_id=v_old.trolley_type_id
      and t.deleted_at is null
      and t.active=true
      and t.status<>'RETIRED';

    select count(*)::integer into v_active_requirements
    from public.customer_schedule_trolley_requirements r
    where r.trolley_type_id=v_old.trolley_type_id
      and r.active=true;

    if v_active_trolleys>0 then
      raise exception using
        errcode='22023',
        message=format('Trolley type %s cannot be deactivated while %s active physical trolley(s) still use it.',v_old.trolley_type_code,v_active_trolleys);
    end if;
    if v_active_requirements>0 then
      raise exception using
        errcode='22023',
        message=format('Trolley type %s cannot be deactivated while %s active Customer Schedule requirement(s) still use it.',v_old.trolley_type_code,v_active_requirements);
    end if;
  end if;

  update public.trolley_types tt
  set trolley_type_name=v_name,
      display_code=v_display,
      trolley_category=v_category,
      footprint_length_cm=p_footprint_length_cm,
      footprint_width_cm=p_footprint_width_cm,
      tare_weight_kg=p_tare_weight_kg,
      sort_order=coalesce(p_sort_order,0),
      active=coalesce(p_active,v_old.active),
      metadata=(coalesce(tt.metadata,'{}'::jsonb)-'trolley_type_notes')
        || jsonb_build_object('last_master_update_source','TROLLEY_TYPE_MASTER_UI')
        || case when v_notes is null then '{}'::jsonb else jsonb_build_object('trolley_type_notes',v_notes) end,
      updated_at=now()
  where tt.trolley_type_id=v_old.trolley_type_id
  returning * into v_new;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    old_data,new_data,reason,source_application
  ) values (
    auth.uid(),v_actor_staff_id,'UPDATE_TROLLEY_TYPE_MASTER','trolley_types',v_new.trolley_type_id::text,
    to_jsonb(v_old),to_jsonb(v_new),v_notes,'TROLLEY_TYPE_MASTER_UI'
  );

  return jsonb_build_object(
    'status','success',
    'trolley_type_id',v_new.trolley_type_id,
    'trolley_type_code',v_new.trolley_type_code,
    'active',v_new.active,
    'allowed_in_customer_schedule',v_new.allowed_in_customer_schedule,
    'message',format('Trolley type %s updated.',v_new.trolley_type_code)
  );
end;
$$;

revoke all on function public.update_trolley_type_master(uuid,text,text,text,numeric,numeric,numeric,integer,text,boolean) from public, anon;
grant execute on function public.update_trolley_type_master(uuid,text,text,text,numeric,numeric,numeric,integer,text,boolean) to authenticated;

comment on function public.get_trolley_type_master() is
  'Governed read model for Trolley Type Master. Source trolley_types remains private.';
comment on function public.create_trolley_type_master(text,text,text,text,numeric,numeric,numeric,integer,text,boolean) is
  'ADMIN/MANAGER Trolley Type Master create. New types are never enabled for Customer Schedule automatically.';
comment on function public.update_trolley_type_master(uuid,text,text,text,numeric,numeric,numeric,integer,text,boolean) is
  'ADMIN/MANAGER Trolley Type Master update. Technical trolley_type_code remains immutable.';
