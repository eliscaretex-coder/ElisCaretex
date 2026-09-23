-- =====================================================================
-- ElisCaretex V2
-- Seed: 202608040004_legacy_staff_import.sql
-- Purpose:
--   Import the 99 legacy staff records from CentralDB User.
-- Rules confirmed by the project owner:
--   - empty training fields import as false;
--   - missing JoinedAt and DeactivatedAt remain null;
--   - COVER capabilities do not replace the primary role;
--   - only TEAM_LEADER, SORTING_AREA and SUPERVISOR are imported as COVER.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.operational_roles') is null
     or to_regclass('public.staff_cover_capabilities') is null
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public'
         and table_name = 'staff_members'
         and column_name = 'legacy_user_id'
     ) then
    raise exception 'Staff Master migration 202608040004 must be applied before this import.';
  end if;

  if exists (
    select 1 from public.app_config
    where config_key = 'legacy_staff_import_20260804_v1'
  ) then
    raise exception 'Legacy staff import is already installed.';
  end if;

  if exists (
    select 1 from public.staff_members
    where legacy_user_id between 1 and 99
  ) then
    raise exception 'Legacy staff IDs already exist. Review the current database before importing.';
  end if;
end;
$$;

with source (
  legacy_user_id,
  employee_code,
  display_name,
  shift_code,
  primary_role_code,
  area_code,
  station_code,
  roster_eligible,
  active,
  deactivated_on,
  joined_on,
  fire_training,
  first_aid_training,
  eod_capable,
  import_review_required,
  import_review_notes
) as (
  values
    (1, 'LEG-001', 'Bruna Del Bello', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-02-16', null::date, false, false, false, false, null),
    (2, 'LEG-002', 'Barbara Balentic', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (3, 'LEG-003', 'Flavia Josephina', 'MORNING', 'TEAM_LEADER', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (4, 'LEG-004', 'Kevin Dsouza', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-03-25', null::date, false, false, false, false, null),
    (5, 'LEG-005', 'Paola Cortez Galvis', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (6, 'LEG-006', 'Rosada Pearl Fernandes', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2025-11-13', null::date, false, false, false, false, null),
    (7, 'LEG-007', 'Camila Del Bello', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2025-12-20', null::date, false, false, false, false, null),
    (8, 'LEG-008', 'Adriano Lima', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-05-08', null::date, false, false, false, false, null),
    (9, 'LEG-009', 'Viorica Closca', 'MORNING', 'LABEL', 'FINISH', 'FINISH_LABEL', true, true, null::date, null::date, false, false, false, false, null),
    (10, 'LEG-010', 'Tamara Bastos', 'MORNING', 'SUPERVISOR', null, null, false, false, date '2026-04-02', null::date, false, false, false, false, null),
    (11, 'LEG-011', 'Claudia Fofono', 'MORNING', 'TEAM_LEADER', 'FINISH', 'FINISH_TABLE_1', false, false, date '2025-11-20', null::date, false, false, false, false, null),
    (12, 'LEG-012', 'Luiz Teodoro Barbosa Silva', 'MORNING', 'SUPERVISOR', null, null, true, true, null::date, null::date, false, false, false, false, null),
    (13, 'LEG-013', 'Caetano Pereira', 'MORNING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', false, false, date '2026-04-16', null::date, false, false, false, false, null),
    (14, 'LEG-014', 'Julio Vas', 'MORNING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', true, true, null::date, null::date, false, false, false, false, null),
    (15, 'LEG-015', 'Belen Vas', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (16, 'LEG-016', 'Franky Gomes', 'MORNING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', true, true, null::date, null::date, false, false, false, false, null),
    (17, 'LEG-017', 'Nevio da Gama', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2025-10-02', null::date, false, false, false, false, null),
    (18, 'LEG-018', 'Anthony Alister Perreira', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-04-21', null::date, false, false, false, false, null),
    (19, 'LEG-019', 'Flavy Colaco', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (20, 'LEG-020', 'Emma Fernandes', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (21, 'LEG-021', 'Relvis Fernandes', 'EVENING', 'SUPPORT_ROLE', null, null, false, false, date '2025-01-16', null::date, false, false, false, false, null),
    (22, 'LEG-022', 'Rahma Mohamed', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (23, 'LEG-023', 'Bendita Fernandes', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (24, 'LEG-024', 'Banut Lena', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-02-14', null::date, false, false, false, true, 'Legacy COVER value ''Label'' is outside the confirmed COVER roles and was not imported.'),
    (25, 'LEG-025', 'Ana Maria Marc', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (26, 'LEG-026', 'Vesley Julio M. Fernandes', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (27, 'LEG-027', 'Elvira Rebello', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (28, 'LEG-028', 'Adrian Banut', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (29, 'LEG-029', 'Lodovico', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (30, 'LEG-030', 'Patrick Fernandes', 'EVENING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', true, true, null::date, null::date, false, false, false, false, null),
    (31, 'LEG-031', 'Manuela Espinel', 'MORNING', 'CLEANER', null, null, false, false, date '2026-07-25', null::date, false, false, false, false, null),
    (32, 'LEG-032', 'Richard Cardoso', 'EVENING', 'SUPPORT_ROLE', null, null, false, false, date '2026-01-16', null::date, false, false, true, false, null),
    (33, 'LEG-033', 'Iris Zamperlini', 'EVENING', 'SUPERVISOR', null, null, false, false, date '2026-06-19', null::date, false, false, false, false, null),
    (34, 'LEG-034', 'Vitoria Eduarda', 'EVENING', 'TEAM_LEADER', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-05-08', null::date, false, false, false, false, null),
    (35, 'LEG-035', 'Ronaldo da Silva', 'EVENING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', true, true, null::date, null::date, false, false, false, false, null),
    (36, 'LEG-036', 'Savio Keegan Dias', 'EVENING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', false, false, date '2025-10-02', null::date, false, false, false, false, null),
    (37, 'LEG-037', 'Agostinho', 'EVENING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', true, true, null::date, null::date, false, false, false, false, null),
    (38, 'LEG-038', 'Joyce Soares', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (39, 'LEG-039', 'Derrick', 'MORNING', 'SUPPORT_ROLE', null, null, false, false, date '2025-09-27', null::date, false, false, false, false, null),
    (40, 'LEG-040', 'Velinda Josephina', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2025-11-11', date '2024-11-17', false, false, false, false, null),
    (41, 'LEG-041', 'Cristina iliescu', 'MORNING', 'TEAM_LEADER', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (42, 'LEG-042', 'Savio Carmo', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (43, 'LEG-043', 'IIIia', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (44, 'LEG-044', 'Vasyl', 'EVENING', 'TEAM_LEADER', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (45, 'LEG-045', 'Gregory Fernandes', 'EVENING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', false, false, date '2026-04-09', null::date, false, false, true, false, null),
    (46, 'LEG-046', 'Taina Furlaneto', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (47, 'LEG-047', 'Tatiana Furlaneto', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (48, 'LEG-048', 'Vanda Oliveira', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2025-12-01', null::date, false, false, false, false, null),
    (49, 'LEG-049', 'Sandeep Surendran', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-06-04', null::date, false, false, false, false, null),
    (50, 'LEG-050', 'Magaly Magana', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2025-12-10', null::date, false, false, false, false, null),
    (51, 'LEG-051', 'Florinda Mamani', 'EVENING', 'SUPPORT_ROLE', null, null, false, false, date '2025-12-12', null::date, false, false, false, false, null),
    (52, 'LEG-052', 'Vinesh', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-02-26', null::date, false, false, false, false, null),
    (53, 'LEG-053', 'Andriya', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-03-06', null::date, false, false, false, false, null),
    (54, 'LEG-054', 'Amarnath', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-06-25', null::date, false, false, false, false, null),
    (55, 'LEG-055', 'Menino Ribeiro', 'MORNING', 'TEAM_LEADER', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-01-30', null::date, true, true, false, false, null),
    (56, 'LEG-056', 'Maria Fernanda Rodriguez', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, false, date '2026-05-09', null::date, false, false, false, true, 'Legacy Active = No and Roster = Yes; values were preserved for review.'),
    (57, 'LEG-057', 'Mothusiotsile Kgosi', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, true, false, false, false, null),
    (58, 'LEG-058', 'Dima', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-07-10', null::date, false, false, false, false, null),
    (59, 'LEG-059', 'Tallaght A', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, null::date, null::date, false, false, false, false, null),
    (60, 'LEG-060', 'Tallaght B', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, null::date, null::date, false, false, false, false, null),
    (61, 'LEG-061', 'Tallaght C', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, null::date, null::date, false, false, false, false, null),
    (62, 'LEG-062', 'Tallaght D', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, null::date, null::date, false, false, false, false, null),
    (63, 'LEG-063', 'Renata', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-03-06', null::date, false, false, false, false, null),
    (64, 'LEG-064', 'Jorge Coca', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (65, 'LEG-065', 'Anergha Putanpura', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (66, 'LEG-066', 'Vishal', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-07-25', null::date, false, false, false, false, null),
    (67, 'LEG-067', 'Yogesh', 'MORNING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', false, false, date '2026-07-25', null::date, false, false, false, false, null),
    (68, 'LEG-068', 'Robert Fernandes', 'EVENING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', true, true, null::date, date '2024-11-18', true, true, false, false, null),
    (69, 'LEG-069', 'Lubna Altalla', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (70, 'LEG-070', 'Perry Ighovo', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-02-05', null::date, false, false, false, false, null),
    (71, 'LEG-071', 'Assil Ksiksi', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-02-05', null::date, false, false, false, false, null),
    (72, 'LEG-072', 'Anglo', 'MORNING', 'SORTING_AREA', 'SORTING', 'SORTING_MAIN', false, false, date '2026-02-05', null::date, false, false, false, false, null),
    (73, 'LEG-073', 'Richard Fernandes', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (74, 'LEG-074', 'Dylan Hughes', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-04-18', null::date, false, false, false, false, null),
    (75, 'LEG-075', 'Lena Banut', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, true, false, null),
    (76, 'LEG-076', 'Alycia', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-02-16', null::date, false, false, false, false, null),
    (77, 'LEG-077', 'Roisin', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-02-16', null::date, false, false, false, false, null),
    (78, 'LEG-078', 'Menino', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-05-08', null::date, false, false, false, false, null),
    (79, 'LEG-079', 'Elifa Dacruz', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-03-23', null::date, false, false, false, false, null),
    (80, 'LEG-080', 'Nathalia Zabini', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-03-18', null::date, false, false, false, false, null),
    (81, 'LEG-081', 'Vifon Fernandes', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', true, true, null::date, null::date, false, false, false, false, null),
    (82, 'LEG-082', 'Lesley', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-05-07', null::date, false, false, false, false, null),
    (83, 'LEG-083', 'Andryia', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-04-16', null::date, false, false, false, false, null),
    (84, 'LEG-084', 'Leslie Costa', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-04-01', null::date, false, false, false, false, null),
    (85, 'LEG-085', 'Jinesh Thomas', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-04-30', null::date, false, false, false, false, null),
    (86, 'LEG-086', 'Kevin', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, null::date, false, false, false, false, null),
    (87, 'LEG-087', 'Quang', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-05-08', null::date, false, false, false, false, null),
    (88, 'LEG-088', 'Alan', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-04-22', null::date, false, false, false, false, null),
    (89, 'LEG-089', 'Fernanda Rodriguez', 'EVENING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', true, true, null::date, null::date, false, false, false, false, null),
    (90, 'LEG-090', 'Angelo Pottery Rd', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-05-16', null::date, false, false, false, false, null),
    (91, 'LEG-091', 'Charlie Pottery Rd', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-05-16', null::date, false, false, true, false, null),
    (92, 'LEG-092', 'Jaqueline Cerretti', 'EVENING', 'TEAM_LEADER', 'FINISH', 'FINISH_TABLE_2', false, true, null::date, null::date, false, false, false, true, 'Legacy Active = Yes and Roster = No; values were preserved for review.'),
    (93, 'LEG-093', 'Hope', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_3', false, false, date '2026-06-25', null::date, false, false, false, false, null),
    (94, 'LEG-094', 'Cherise', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-05-29', null::date, false, false, false, false, null),
    (95, 'LEG-095', 'Ken', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-05-20', null::date, false, false, false, false, null),
    (96, 'LEG-096', 'Velanko', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', false, false, date '2026-06-04', null::date, false, false, false, false, null),
    (97, 'LEG-097', 'Jhenniffer', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_1', false, false, date '2026-07-30', null::date, false, false, false, false, null),
    (98, 'LEG-098', 'Vladimir', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, date '2026-06-15', false, false, false, false, null),
    (99, 'LEG-099', 'Sarai', 'MORNING', 'GENERAL_OPERATIVE', 'FINISH', 'FINISH_TABLE_2', true, true, null::date, date '2026-08-03', false, false, false, false, null)
)
insert into public.staff_members (
  legacy_user_id,
  employee_code,
  display_name,
  active,
  roster_eligible,
  default_shift_id,
  primary_operational_role_id,
  default_area_id,
  default_station_id,
  fire_training,
  first_aid_training,
  eod_capable,
  joined_on,
  deactivated_on,
  deactivation_reason,
  import_review_required,
  import_review_notes,
  row_version,
  notes
)
select
  src.legacy_user_id,
  src.employee_code,
  src.display_name,
  src.active,
  src.roster_eligible,
  sh.shift_id,
  opr.operational_role_id,
  a.area_id,
  st.station_id,
  src.fire_training,
  src.first_aid_training,
  src.eod_capable,
  src.joined_on,
  src.deactivated_on,
  case when src.active = false and src.deactivated_on is not null
    then 'Imported legacy deactivation date.'
    else null
  end,
  src.import_review_required,
  src.import_review_notes,
  1,
  'Imported from CentralDB User on 2026-08-04.'
from source src
join public.shifts sh
  on sh.shift_code = src.shift_code
 and sh.active = true
 and sh.deleted_at is null
join public.operational_roles opr
  on opr.role_code = src.primary_role_code
 and opr.active = true
 and opr.deleted_at is null
left join public.areas a
  on a.area_code = src.area_code
 and a.active = true
 and a.deleted_at is null
left join public.stations st
  on st.station_code = src.station_code
 and st.active = true
 and st.deleted_at is null;

with source_cover (legacy_user_id, cover_role_code) as (
  values
    (2, 'TEAM_LEADER'),
    (3, 'TEAM_LEADER'),
    (5, 'TEAM_LEADER'),
    (11, 'SUPERVISOR'),
    (15, 'SORTING_AREA'),
    (15, 'TEAM_LEADER'),
    (18, 'SORTING_AREA'),
    (18, 'TEAM_LEADER'),
    (21, 'SORTING_AREA'),
    (21, 'TEAM_LEADER'),
    (22, 'TEAM_LEADER'),
    (28, 'SUPERVISOR'),
    (28, 'TEAM_LEADER'),
    (32, 'SUPERVISOR'),
    (34, 'SUPERVISOR'),
    (38, 'TEAM_LEADER'),
    (42, 'TEAM_LEADER'),
    (46, 'SUPERVISOR'),
    (46, 'TEAM_LEADER'),
    (56, 'SUPERVISOR'),
    (56, 'TEAM_LEADER'),
    (66, 'SORTING_AREA'),
    (89, 'SUPERVISOR'),
    (89, 'TEAM_LEADER')
)
insert into public.staff_cover_capabilities (
  staff_id,
  operational_role_id,
  effective_from,
  active
)
select
  sm.staff_id,
  opr.operational_role_id,
  date '2026-08-04',
  true
from source_cover src
join public.staff_members sm
  on sm.legacy_user_id = src.legacy_user_id
join public.operational_roles opr
  on opr.role_code = src.cover_role_code
 and opr.allow_as_cover = true
 and opr.active = true
 and opr.deleted_at is null;

insert into public.app_config (
  config_key,
  value_json,
  description,
  updated_at
)
values (
  'legacy_staff_import_20260804_v1',
  jsonb_build_object(
    'imported_on', current_date,
    'source', 'CentralDB (1)(5).xlsx / User',
    'records', 99,
    'active', 40,
    'inactive', 59,
    'roster_eligible', 40,
    'morning_shift', 58,
    'evening_shift', 41,
    'review_required', 3,
    'empty_training_values_imported_as_no', true,
    'missing_dates_preserved_as_null', true
  ),
  'Authoritative marker for the initial legacy Staff Master import.',
  now()
);

insert into public.audit_log (
  action,
  entity_table,
  entity_id,
  new_data,
  reason,
  source_application
)
values (
  'IMPORT_LEGACY_STAFF_MASTER',
  'staff_members',
  'LEGACY_STAFF_IMPORT_20260804_V1',
  jsonb_build_object(
    'records', 99,
    'active', 40,
    'inactive', 59,
    'cover_capabilities', 24,
    'review_required', 3
  ),
  'Initial governed import from CentralDB User.',
  'DATABASE_SEED'
);

select jsonb_build_object(
  'status', 'IMPORT_COMPLETE',
  'test', '202608040004_legacy_staff_import',
  'staff_records', (
    select count(*) from public.staff_members where legacy_user_id between 1 and 99
  ),
  'active', (
    select count(*) from public.staff_members where legacy_user_id between 1 and 99 and active = true
  ),
  'inactive', (
    select count(*) from public.staff_members where legacy_user_id between 1 and 99 and active = false
  ),
  'roster_eligible', (
    select count(*) from public.staff_members where legacy_user_id between 1 and 99 and roster_eligible = true
  ),
  'cover_capabilities', (
    select count(*)
    from public.staff_cover_capabilities scc
    join public.staff_members sm on sm.staff_id = scc.staff_id
    where sm.legacy_user_id between 1 and 99
      and scc.active = true
      and scc.deleted_at is null
  ),
  'review_required', (
    select count(*) from public.staff_members
    where legacy_user_id between 1 and 99 and import_review_required = true
  )
) as result;

commit;
