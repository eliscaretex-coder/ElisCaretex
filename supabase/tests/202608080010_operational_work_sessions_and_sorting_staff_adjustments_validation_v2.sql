-- Snapshot 56 validation was superseded after Development showed that
-- production_roster_entries.planned_start_time/planned_end_time are optional.
--
-- Apply migration 202608080011 and run:
--   202608080011_sorting_staff_work_profile_time_resolution_validation.sql
--
-- The 011 validation covers the 010 work-session security/write path plus the
-- authoritative Production Roster work-profile time resolution.
select jsonb_build_object(
  'status', 'SUPERSEDED',
  'replacement', '202608080011_sorting_staff_work_profile_time_resolution_validation.sql'
) as validation_note;
