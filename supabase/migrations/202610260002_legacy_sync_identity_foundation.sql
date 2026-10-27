-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610260002_legacy_sync_identity_foundation
--
-- Legacy synchronization identity layer (PREPARED, not applied).
-- Additive only: does not touch integration.legacy_inbox, staging objects,
-- operational tables, Finish triggers or historical rows.
--
-- Reviewed version of the package "ElisCaretex_Legacy_Sync_DB_Foundation".
-- Changes from that draft:
--   * renamed from 202610260001 (already used by
--     202610260001_distribution_driver_infringements.sql);
--   * wrapped in one transaction;
--   * links carry source_line_key so one legacy Finish entry can link to
--     several KG/UNIT lines;
--   * record versions and links are insert-only (trigger);
--   * review items: decision fields are required once decided, and only
--     OPEN rows can change.
--
-- No client grants and no import function. A later reviewed migration adds
-- the SECURITY DEFINER importer and the controlled Finish trigger change.
-- =====================================================================

begin;

create schema if not exists integration;

create table if not exists integration.legacy_sync_runs (
  sync_run_id uuid primary key default gen_random_uuid(),
  source_system text not null,
  mode text not null check (mode in ('DRY_RUN','COMMIT')),
  date_from date,
  date_to date,
  requested_by text,
  status text not null default 'CREATED'
    check (status in ('CREATED','RUNNING','COMPLETED','FAILED','CANCELLED')),
  summary jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  constraint legacy_sync_runs_date_range
    check (date_from is null or date_to is null or date_from <= date_to)
);

create table if not exists integration.legacy_sync_record_versions (
  legacy_record_version_id bigint generated always as identity primary key,
  source_system text not null,
  source_table text not null,
  source_record_id text not null,
  source_fingerprint text not null,
  source_updated_at timestamptz,
  payload jsonb not null,
  first_seen_run uuid references integration.legacy_sync_runs(sync_run_id) on delete restrict,
  loaded_at timestamptz not null default now(),
  constraint legacy_sync_record_versions_uq
    unique (source_system, source_table, source_record_id, source_fingerprint)
);

create table if not exists integration.legacy_sync_record_links (
  link_id uuid primary key default gen_random_uuid(),
  source_system text not null,
  source_table text not null,
  source_record_id text not null,
  source_line_key text not null default '',
  link_role text not null
    check (link_role in ('CUSTOMER','WASH_ITEM_TO_FLOW','FINISH_ENTRY_TO_ENTRY','FINISH_ENTRY_TO_LINE')),
  target_table text not null,
  target_id uuid not null,
  source_fingerprint text not null,
  sync_run_id uuid references integration.legacy_sync_runs(sync_run_id) on delete restrict,
  link_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint legacy_sync_record_links_source_uq
    unique (source_system, source_table, source_record_id, link_role, source_line_key),
  constraint legacy_sync_record_links_target_role_check check (
    (link_role='CUSTOMER' and target_table='public.customers') or
    (link_role='WASH_ITEM_TO_FLOW' and target_table='public.production_flow_items') or
    (link_role='FINISH_ENTRY_TO_ENTRY' and target_table='public.finish_production_entries') or
    (link_role='FINISH_ENTRY_TO_LINE' and target_table='public.finish_production_lines')
  ),
  constraint legacy_sync_record_links_line_key_check check (
    (link_role='FINISH_ENTRY_TO_LINE' and length(trim(source_line_key)) > 0)
    or (link_role<>'FINISH_ENTRY_TO_LINE' and source_line_key='')
  )
);

create index if not exists legacy_sync_record_links_target_idx
  on integration.legacy_sync_record_links (target_table, target_id);

create table if not exists integration.legacy_sync_review_items (
  review_id uuid primary key default gen_random_uuid(),
  source_system text not null,
  source_table text not null,
  source_record_id text not null,
  reason_code text not null,
  raw jsonb not null default '{}'::jsonb,
  status text not null default 'OPEN'
    check (status in ('OPEN','APPROVED','REJECTED','SUPERSEDED')),
  decision jsonb,
  decided_by text,
  decided_at timestamptz,
  sync_run_id uuid references integration.legacy_sync_runs(sync_run_id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint legacy_sync_review_items_decision_check check (
    (status='OPEN' and decided_at is null and decided_by is null)
    or (status in ('APPROVED','REJECTED') and decided_at is not null
        and nullif(trim(coalesce(decided_by,'')),'') is not null and decision is not null)
    or (status='SUPERSEDED' and decided_at is not null)
  )
);

create unique index if not exists legacy_sync_review_open_uidx
  on integration.legacy_sync_review_items (source_system, source_table, source_record_id, reason_code)
  where status='OPEN';
create index if not exists legacy_sync_review_status_idx
  on integration.legacy_sync_review_items (status, created_at);

-- ---------------------------------------------------------------------
-- Provenance is insert-only. A changed legacy record becomes a new
-- record version plus a review item; existing links are never rewritten.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_block_mutation()
returns trigger
language plpgsql
set search_path = integration, pg_temp
as $$
begin
  raise exception using
    errcode='55000',
    message=format('%s is insert-only. Record a new version or a review item instead.', tg_table_name);
end;
$$;

create or replace function integration.legacy_sync_review_guard()
returns trigger
language plpgsql
set search_path = integration, pg_temp
as $$
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000', message='Review items cannot be deleted.';
  end if;
  if old.status<>'OPEN' then
    raise exception using errcode='55000', message='A decided review item cannot be changed.';
  end if;
  if (new.source_system, new.source_table, new.source_record_id, new.reason_code, new.raw, new.created_at)
     is distinct from
     (old.source_system, old.source_table, old.source_record_id, old.reason_code, old.raw, old.created_at) then
    raise exception using errcode='55000', message='Only the decision fields of a review item can change.';
  end if;
  return new;
end;
$$;

drop trigger if exists legacy_sync_record_versions_insert_only on integration.legacy_sync_record_versions;
create trigger legacy_sync_record_versions_insert_only
  before update or delete on integration.legacy_sync_record_versions
  for each row execute function integration.legacy_sync_block_mutation();

drop trigger if exists legacy_sync_record_links_insert_only on integration.legacy_sync_record_links;
create trigger legacy_sync_record_links_insert_only
  before update or delete on integration.legacy_sync_record_links
  for each row execute function integration.legacy_sync_block_mutation();

drop trigger if exists legacy_sync_review_items_guard on integration.legacy_sync_review_items;
create trigger legacy_sync_review_items_guard
  before update or delete on integration.legacy_sync_review_items
  for each row execute function integration.legacy_sync_review_guard();

-- ---------------------------------------------------------------------
-- Private: RLS on, no policies, no client grants.
-- ---------------------------------------------------------------------
alter table integration.legacy_sync_runs enable row level security;
alter table integration.legacy_sync_record_versions enable row level security;
alter table integration.legacy_sync_record_links enable row level security;
alter table integration.legacy_sync_review_items enable row level security;

revoke all on integration.legacy_sync_runs from public, anon, authenticated;
revoke all on integration.legacy_sync_record_versions from public, anon, authenticated;
revoke all on integration.legacy_sync_record_links from public, anon, authenticated;
revoke all on integration.legacy_sync_review_items from public, anon, authenticated;
revoke all on sequence integration.legacy_sync_record_versions_legacy_record_version_id_seq
  from public, anon, authenticated;
revoke all on function integration.legacy_sync_block_mutation() from public, anon, authenticated;
revoke all on function integration.legacy_sync_review_guard() from public, anon, authenticated;

comment on table integration.legacy_sync_runs is
  'One manual or scheduled legacy sync run (DRY_RUN or COMMIT) with its date range and summary.';
comment on table integration.legacy_sync_record_versions is
  'Insert-only copy of each distinct version (fingerprint) of a legacy source record.';
comment on table integration.legacy_sync_record_links is
  'Insert-only legacy-to-V2 identity map. Targets are polymorphic: the importer must verify target existence and customer/flow consistency.';
comment on table integration.legacy_sync_review_items is
  'Legacy records held for an explicit decision. Only OPEN items can change, and only their decision fields.';

commit;
