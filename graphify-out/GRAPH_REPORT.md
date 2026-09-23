# Graph Report - laundry-platform-v2  (2026-08-26)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 2228 nodes · 4332 edges · 250 communities (226 shown, 24 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 35 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Community 0
- Community 1
- Community 2
- Community 3
- Community 4
- Community 5
- Community 6
- Community 7
- Community 8
- Community 9
- Community 10
- Community 11
- Community 12
- Community 13
- Community 14
- Community 15
- Community 16
- Community 17
- Community 18
- Community 19
- Community 20
- Community 21
- Community 22
- Community 23
- Community 24
- Community 25
- Community 26
- Community 27
- Community 28
- Community 29
- Community 30
- Community 31
- Community 32
- Community 33
- Community 34
- Community 35
- Community 36
- Community 37
- Community 38
- Community 39
- Community 40
- Community 41
- Community 42
- Community 43
- Community 44
- Community 45
- Community 46
- Community 47
- Community 48
- Community 49
- Community 50
- Community 52
- Community 53
- Community 54
- Community 55
- Community 56
- Community 57
- Community 58
- Community 59
- Community 60
- Community 62
- Community 63
- Community 64
- Community 65
- Community 66
- Community 67
- Community 68
- Community 69
- Community 70
- Community 71
- Community 72
- Community 73
- Community 74
- Community 75
- Community 76
- Community 77
- Community 78
- Community 79
- Community 80
- Community 81
- Community 82
- Community 83
- Community 84
- Community 85
- Community 86
- Community 87
- Community 88
- Community 89
- Community 90
- Community 92
- Community 93
- Community 95
- Community 96
- Community 98
- Community 100
- Community 101
- Community 104
- Community 106
- Community 109
- Community 133
- Community 140
- Community 143
- Community 144
- Community 145
- Community 146
- Community 147
- Community 148
- Community 149
- Community 150
- Community 151
- Community 152
- Community 153
- Community 154
- Community 155
- Community 156

## God Nodes (most connected - your core abstractions)
1. `escapeHtml()` - 57 edges
2. `setMessage()` - 40 edges
3. `rpc()` - 35 edges
4. `escapeHtml()` - 32 edges
5. `friendly()` - 30 edges
6. `escapeHtml()` - 30 edges
7. `loadRoster()` - 28 edges
8. `rpc()` - 23 edges
9. `renderScheduleManagementState()` - 21 edges
10. `formatDate()` - 20 edges

## Surprising Connections (you probably didn't know these)
- `processedCell()` --indirect_call--> `titleCode()`  [INFERRED]
  frontend/assets/js/production-tracker.js → frontend/assets/js/sorting.js

## Import Cycles
- None detected.

## Communities (250 total, 24 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.06
Nodes (77): actualValue(), addManualStop(), applyRosterEntry(), complianceForVehicle(), deliveryWindow(), driverAssignedOnDay(), driverCompliance(), driverOnLeave() (+69 more)

### Community 1 - "Community 1"
Cohesion: 0.09
Nodes (60): addLine(), addTrolleyFromInput(), authenticate(), calculateTableMetrics(), canEditEntry(), closeProductionDialog(), closeStaffDialog(), closeTrolleyDialog() (+52 more)

### Community 2 - "Community 2"
Cohesion: 0.13
Nodes (56): attentionBadge(), availableTabs(), closeReviewModal(), daysLabel(), escapeHtml(), formatDate(), formatDateTime(), formatNumber() (+48 more)

### Community 3 - "Community 3"
Cohesion: 0.07
Nodes (47): closeMopAbsDialog(), closeMopCancelDialog(), collectMopLines(), findTrackerMopBatch(), hasWashDraft(), mopFormHasQuantity(), mopPhotoStoragePath(), mopVariantCodeFromName() (+39 more)

### Community 4 - "Community 4"
Cohesion: 0.09
Nodes (49): absCell(), allTrolleys(), badge(), batchCell(), cardDates(), compareTuple(), dayStat(), firstIncomplete() (+41 more)

### Community 5 - "Community 5"
Cohesion: 0.09
Nodes (48): addDays(), applyLeaveDateRules(), buildCard(), buildDayCell(), closeLeaveForm(), compactStation(), currentMondayIso(), dayList() (+40 more)

### Community 6 - "Community 6"
Cohesion: 0.08
Nodes (37): public.require_draft_schedule_parent, public.set_updated_at_and_row_version, public.validate_schedule_product_variant, public.validate_schedule_trolley_requirement, public.validate_schedule_trolley_requirement_product, customer_schedule_days_require_draft, customer_schedule_product_variants_require_draft, customer_schedule_product_variants_validate (+29 more)

### Community 7 - "Community 7"
Cohesion: 0.06
Nodes (39): public.guard_sorting_new_activity_against_no_work, public.guard_sorting_whole_shift_no_work_after_new_activity, public.assign_trolley_to_customer_from_production(), public.get_sorting_mop_production_context(), public.guard_sorting_whole_shift_no_work_after_new_activity(), public.record_sorting_non_trolley_arrival(), public.sorting_mop_production_batches, public.sorting_mop_production_lines (+31 more)

### Community 8 - "Community 8"
Cohesion: 0.07
Nodes (30): distribution_driver_absences_set_updated_at, distribution_drivers_set_updated_at, distribution_route_run_stops_set_updated_at, distribution_route_runs_set_updated_at, fleet_vehicle_defects_set_updated_at, fleet_vehicle_maintenance_set_updated_at, fleet_vehicles_set_updated_at, public.distribution_driver_absences (+22 more)

### Community 9 - "Community 9"
Cohesion: 0.13
Nodes (44): accountActions(), accountAdmin(), accountModuleChips(), accountModules(), accountRoleChips(), accountStaffOptions(), applyAccountType(), assignmentText() (+36 more)

### Community 10 - "Community 10"
Cohesion: 0.09
Nodes (43): buildHistoryChangeItems(), comparisonDaySide(), comparisonMetric(), dayInputField(), dayTextareaField(), distributionTimeLabel(), draftDocumentForRpc(), draftDocumentFromSnapshot() (+35 more)

### Community 11 - "Community 11"
Cohesion: 0.14
Nodes (43): addManualStaff(), cancelManualStaff(), cancelWashRecord(), changeSortingWorkMode(), closeMopCorrectionDialog(), collectMopCorrectionLines(), commitConfirmedWash(), enforceMopReconciliation() (+35 more)

### Community 12 - "Community 12"
Cohesion: 0.10
Nodes (33): availableStaffPool(), capacityDayCell(), capacityPanelHtml(), capacitySimulationPercent(), closeStaffPicker(), countsAsPlannedDay(), countsForFinishCapacity(), edgeFunctionErrorDetails() (+25 more)

### Community 13 - "Community 13"
Cohesion: 0.09
Nodes (35): clearWashSearch(), fmtTime(), minutesToLabel(), mopActiveAbs(), mopCorrectionCurrentLineMap(), mopTraceLineMarkup(), openMopAbsDialog(), openMopCancelDialog() (+27 more)

### Community 14 - "Community 14"
Cohesion: 0.14
Nodes (34): bindCustomerMasterControls(), currentStudioSnapshot(), daySelectField(), editableField(), emptyHtml(), escapeHtml(), formatDate(), formatNumber() (+26 more)

### Community 15 - "Community 15"
Cohesion: 0.19
Nodes (30): addSelectedStaffToRoster(), adjustEntriesToVisibleDays(), applyQuickStatus(), baseAssignmentForDailyEdit(), baseAssignmentForDisplaySection(), closeQuickStatusMenu(), copyPreviousWeek(), defaultDisplaySection() (+22 more)

### Community 16 - "Community 16"
Cohesion: 0.10
Nodes (18): public.protect_published_production_roster_entries, production_roster_entries_immutable, production_roster_entries_set_updated_at, production_roster_versions_set_updated_at, public.production_roster_entries, public.production_roster_events, public.production_roster_versions, public.production_roster_view_links (+10 more)

### Community 17 - "Community 17"
Cohesion: 0.14
Nodes (29): addBankHoliday(), createStaffLink(), decideLeaveRequest(), discardDraft(), formatDate(), formatDateTime(), friendlyError(), groupStaffHistoryHtml() (+21 more)

### Community 18 - "Community 18"
Cohesion: 0.11
Nodes (21): public.sorting_wash_customer_flow_link_trigger, public.sorting_wash_run_flow_event_trigger, public.append_production_flow_event(), public.ensure_production_flow_item(), public.link_sorting_wash_customer_to_production_flow(), public.production_flow_events, public.production_flow_external_batches, public.production_flow_items (+13 more)

### Community 19 - "Community 19"
Cohesion: 0.10
Nodes (17): anon, authenticated, operational_roles_set_updated_at, public.get_staff_directory(), public.get_staff_master_reference_data(), public.operational_roles, public.require_staff_master_read_role(), public.staff_cover_capabilities (+9 more)

### Community 20 - "Community 20"
Cohesion: 0.08
Nodes (16): exception, message, public.build_customer_schedule_version_snapshot(), public.get_customer_schedule_reference_data(), public.customer_product_services, public.customer_schedule_days, public.customer_schedule_product_variants, public.customer_schedule_products (+8 more)

### Community 21 - "Community 21"
Cohesion: 0.09
Nodes (27): addMopTrolley(), chooseMopReconciliation(), continueMopLateEntry(), ensureMopTrolleyReportUi(), fullDayDate(), mopDraftWarning(), mopModelRows(), mopQueueTrolleyRequirement() (+19 more)

### Community 22 - "Community 22"
Cohesion: 0.11
Nodes (36): assignmentLabel(), clientSaveIssue(), crossShiftStaffIssues(), dayCell(), displaySection(), displaySectionControl(), displaySectionOptions(), escapeHtml() (+28 more)

### Community 23 - "Community 23"
Cohesion: 0.10
Nodes (12): public.get_sorting_manual_staff_candidates(), public.get_sorting_washing_context_v3(), public.operational_shift_clock_context(), public.save_sorting_wash_run(), board_rows, public.app_config, public.customer_schedule_days, public.customer_schedule_products (+4 more)

### Community 24 - "Community 24"
Cohesion: 0.09
Nodes (19): public.get_sorting_trolley_intake_context_v2(), public.sorting_trolley_intake_products, public.sorting_trolley_intakes, auth.users, board, public, public.customer_schedule_days, public.customer_schedule_products (+11 more)

### Community 25 - "Community 25"
Cohesion: 0.15
Nodes (25): applyPlannerDrop(), availableMainTabs(), beginScheduleEdit(), bindScheduleToolbar(), canUseScheduleService(), confirmDeactivate(), discardScheduleChanges(), ensureScheduleService() (+17 more)

### Community 26 - "Community 26"
Cohesion: 0.10
Nodes (19): public.distribution_roster_entries, public.record_distribution_master_event, distribution_driver_absences_master_event, distribution_drivers_master_event, distribution_routes_master_event, fleet_vehicle_defects_master_event, fleet_vehicle_maintenance_master_event, fleet_vehicles_master_event (+11 more)

### Community 27 - "Community 27"
Cohesion: 0.10
Nodes (18): distribution_daily_plans_set_updated_at, distribution_daily_stops_set_updated_at, public.distribution_daily_plans, public.distribution_daily_source_stops(), public.distribution_daily_stops, auth, auth.users, public (+10 more)

### Community 28 - "Community 28"
Cohesion: 0.09
Nodes (7): public.production_roster_leave_request_events, public.protect_production_roster_leave_request_events, public.get_production_roster_leave_requests(), public.production_roster_leave_gm_reviews, public.submit_production_roster_leave_request(), public.production_roster_leave_requests, trg_protect_production_roster_leave_request_events

### Community 29 - "Community 29"
Cohesion: 0.10
Nodes (14): public.get_customer_directory(), public.get_customer_weekly_schedule(), day_payload, public.customer_product_services, public.customer_schedule_days, public.customer_schedule_product_variants, public.customer_schedule_products, public.customer_schedule_trolley_requirement_products (+6 more)

### Community 30 - "Community 30"
Cohesion: 0.15
Nodes (22): bindPlannerReorderControls(), bindPlannerScrollControls(), buildCustomerPrintDocument(), buildDay(), canManageCustomerSchedules(), clearPlannerDropMarkers(), customerPrintGeneratedAt(), customerPrintListVersion() (+14 more)

### Community 31 - "Community 31"
Cohesion: 0.12
Nodes (12): public.assign_trolley_to_customer_from_production(), public.get_trolley_dashboard(), public.get_trolley_reference_data(), public.customer_schedule_days, public.customer_schedule_products, public.customer_schedule_versions, public.customers, public.product_types (+4 more)

### Community 32 - "Community 32"
Cohesion: 0.15
Nodes (15): public.assign_finish_trolley_to_flow(), public.finish_assert_entry_open(), public.finish_production_entries, public.finish_production_lines, public.finish_production_trolleys, public.finish_validate_lines(), public.require_finish_production_access(), auth.users (+7 more)

### Community 33 - "Community 33"
Cohesion: 0.16
Nodes (21): confirmCustomerHtml(), correctionKeepsLegacySelection(), customerScheduleConfirmMeta(), estimatedCustomerWeightAllocations(), fmtDate(), openCustomerDialog(), openWashConfirmation(), renderCustomerOptions() (+13 more)

### Community 34 - "Community 34"
Cohesion: 0.21
Nodes (20): addDraftTrolleyRequirement(), bindScheduleManagementEditor(), dayDocumentByElement(), defaultProductCodeForNewDay(), errorMessage(), handleStudioAction(), markStudioDirty(), newDraftProduct() (+12 more)

### Community 35 - "Community 35"
Cohesion: 0.12
Nodes (15): public.get_sorting_staff_work_context_v2(), public.get_sorting_washing_context_v2(), public.sorting_daily_staff_modes, auth, auth.users, board_rows, public, public.customer_schedule_days (+7 more)

### Community 36 - "Community 36"
Cohesion: 0.15
Nodes (14): distribution_roster_entries_set_updated_at, distribution_roster_versions_set_updated_at, public.distribution_roster_entries, public.distribution_roster_events, public.distribution_roster_versions, public.get_distribution_roster_week(), auth, auth.users (+6 more)

### Community 37 - "Community 37"
Cohesion: 0.23
Nodes (18): activeRoleCodes(), activeRoles(), createModuleIcon(), createOperationalModuleCard(), createOperationalNavItem(), initials(), loadAuthenticatedProfile(), renderAdministrativeRoles() (+10 more)

### Community 38 - "Community 38"
Cohesion: 0.18
Nodes (19): autoCustomerChangeReason(), customerFormChangedFields(), customerFormSnapshot(), customerFormSnapshotKey(), customerFormValidationMessage(), establishCustomerFormBaseline(), openCustomerForm(), parseOptionalNumber() (+11 more)

### Community 39 - "Community 39"
Cohesion: 0.17
Nodes (19): chooseDefaultTrolleyProducts(), initTrolleyDraft(), openNoTrolleyArrival(), renderTrolleyResult(), renderTrolleyStaffBar(), selectTrolleyStaff(), setTrolleyCustomer(), trolleyDateButtons() (+11 more)

### Community 40 - "Community 40"
Cohesion: 0.15
Nodes (16): public.distribution_master_events, distribution_driver_weekly_actuals_set_updated_at, distribution_vehicle_weekly_mileage_set_updated_at, public.distribution_driver_weekly_actuals, public.distribution_vehicle_weekly_mileage, public.get_distribution_actuals_week(), auth, auth.users (+8 more)

### Community 41 - "Community 41"
Cohesion: 0.22
Nodes (18): addDays(), beginPrint(), canOpenNextWeekFromCurrentWeek(), createNextWeek(), currentMonday(), dateIso(), dublinTodayIso(), initialize() (+10 more)

### Community 42 - "Community 42"
Cohesion: 0.19
Nodes (18): cancelNewMopType(), clearMopTypePreviewUrl(), closeMopTypes(), confirmDiscardMopTypeChanges(), loadMopTypes(), mopTypeCatalogRows(), mopTypeFilteredRows(), mopTypePhotoMarkup() (+10 more)

### Community 43 - "Community 43"
Cohesion: 0.14
Nodes (14): public.protect_production_roster_shift_overrides, production_roster_shift_overrides_immutable, public.get_production_roster_week(), public.production_roster_draft_recovery_snapshots, public.production_roster_shift_overrides, public.protect_production_roster_shift_overrides(), public, public.production_roster_entries (+6 more)

### Community 44 - "Community 44"
Cohesion: 0.16
Nodes (13): public.sorting_guard_absent_mop_mode, public.sorting_guard_absent_wash_operator, public.set_sorting_staff_attendance(), public.sorting_daily_staff_attendance, public.sorting_guard_absent_mop_mode(), public.sorting_guard_absent_wash_operator(), sorting_daily_staff_modes_absent_mop_guard, sorting_wash_runs_absent_operator_guard (+5 more)

### Community 45 - "Community 45"
Cohesion: 0.12
Nodes (4): public.get_trolley_reference_data(), public.customers, public.trolley_customer_stays, public.trolleys

### Community 46 - "Community 46"
Cohesion: 0.14
Nodes (7): public.production_station_device_context(), public.production_station_devices, public.terminal_correct_finish_production_v1(), auth.users, public.areas, public.finish_production_entries, public.stations

### Community 47 - "Community 47"
Cohesion: 0.25
Nodes (11): bindDistributionControls(), bindScheduleCustomerButtons(), buildDistributionGroups(), distributionGroupKey(), distributionMetricHtml(), distributionRouteLabel(), distributionRouteOptions(), distributionRouteValue() (+3 more)

### Community 48 - "Community 48"
Cohesion: 0.17
Nodes (15): closeModal(), closeScheduleActionDialog(), confirmScheduleAction(), ensureOperationalReportDialog(), formatDateTime(), loadOperationalReports(), openDeactivateModal(), openModal() (+7 more)

### Community 49 - "Community 49"
Cohesion: 0.24
Nodes (15): beginEditWash(), clearWash(), operatorStaff(), prefillTypeForOperator(), recentWashById(), renderCapacity(), renderEditState(), renderReference() (+7 more)

### Community 50 - "Community 50"
Cohesion: 0.13
Nodes (12): public.get_customer_weekly_schedule(), day_payload, public.customer_schedule_days, public.customer_schedule_product_variants, public.customer_schedule_products, public.customer_schedule_trolley_requirement_products, public.customer_schedule_trolley_requirements, public.customer_schedule_versions (+4 more)

### Community 52 - "Community 52"
Cohesion: 0.13
Nodes (7): public.operational_data_reports, public.customer_schedule_days, public.customer_schedule_products, public.customer_schedule_versions, public.customers, public.production_flow_items, public.staff_members

### Community 53 - "Community 53"
Cohesion: 0.14
Nodes (4): public.production_flow_external_batch_context_trigger, production_flow_external_batch_context_before_write, public.production_flow_external_batch_context_trigger(), public.production_flow_items

### Community 54 - "Community 54"
Cohesion: 0.14
Nodes (6): public.sorting_non_trolley_arrivals, public.get_sorting_mop_type_catalog(), public.sorting_assert_wash_reception_gate_v2(), public.sorting_trolley_intake_products, public.sorting_trolley_intakes, v_reason

### Community 55 - "Community 55"
Cohesion: 0.18
Nodes (11): public.sorting_wash_run_customers, public.sorting_wash_runs, public.sorting_washers, auth.users, public, public.customer_schedule_days, public.customer_schedule_products, public.customer_schedule_versions (+3 more)

### Community 56 - "Community 56"
Cohesion: 0.35
Nodes (12): batchHtml(), load(), moveDate(), num(), percent(), render(), renderEntries(), renderMatrix() (+4 more)

### Community 57 - "Community 57"
Cohesion: 0.28
Nodes (13): loadTracker(), loadTrackerHistory(), openTrackerHistory(), preloadTrackerDayStats(), renderTrackerDayCards(), trackerBaseToday(), trackerCardDates(), trackerDayStat() (+5 more)

### Community 58 - "Community 58"
Cohesion: 0.26
Nodes (10): prepared, staging.legacy_customer_master, staging.legacy_customer_schedule, staging.legacy_customer_status_override, staging.legacy_mop_variant_mapping, staging.legacy_route_mapping, staging.v_legacy_customer_review, staging.v_legacy_mop_variant_review (+2 more)

### Community 59 - "Community 59"
Cohesion: 0.15
Nodes (4): public.get_or_create_production_roster_staff_portal_link(), public.production_roster_staff_portal_links, auth.users, public.production_roster_leave_requests

### Community 60 - "Community 60"
Cohesion: 0.18
Nodes (9): public.get_sorting_customer_board_v3(), public.sorting_assert_wash_scan_gate(), board_rows, public.customer_schedule_trolley_requirements, public.sorting_trolley_intake_products, public.sorting_trolley_intakes, public.sorting_wash_run_customers, public.sorting_wash_runs (+1 more)

### Community 62 - "Community 62"
Cohesion: 0.29
Nodes (10): base64UrlFromUtf8(), buildMimeMessage(), cleanHeaderValue(), corsHeaders, encodedHeader(), getGmailAccessToken(), json(), logFailure() (+2 more)

### Community 63 - "Community 63"
Cohesion: 0.27
Nodes (8): createNavItem(), dublinDateKey(), renderNavigation(), resolveHref(), roleIsEffective(), setSidebarExpanded(), setSidebarHover(), updateSidebarState()

### Community 64 - "Community 64"
Cohesion: 0.33
Nodes (11): applyApprovedLeaveOverlay(), applyPendingLeaveOverlay(), approvedLeaveStatus(), isHistorical(), leaveLockKey(), pendingLeaveRequestIds(), pollLeaveRevision(), refreshApprovedLeaveOverlay() (+3 more)

### Community 65 - "Community 65"
Cohesion: 0.18
Nodes (10): public.account_access_profiles, public.account_roles, public.get_admin_account_access_directory(), auth.users, public.areas, public.production_station_devices, public.roles, public.staff_members (+2 more)

### Community 66 - "Community 66"
Cohesion: 0.22
Nodes (5): public.get_production_roster_operational_settings(), public.production_roster_calendar_exceptions, public.production_roster_work_profiles, public.production_targets, auth.users

### Community 67 - "Community 67"
Cohesion: 0.18
Nodes (10): public.get_sorting_trolley_intake_context_v2(), board, public.production_flow_items, public.sorting_trolley_intake_products, public.sorting_trolley_intakes, public.sorting_wash_run_customers, public.sorting_wash_runs, public.trolley_types (+2 more)

### Community 68 - "Community 68"
Cohesion: 0.18
Nodes (5): public.get_sorting_staff_no_work_options(), public.areas, public.shifts, public.sorting_trolley_intakes, public.work_sessions

### Community 69 - "Community 69"
Cohesion: 0.24
Nodes (10): clearTrolleyScanBuffer(), handleTrolleyScannerKey(), paintTrolleyScanBuffer(), receptionDialogOpen(), receptionRowState(), receptionTypingTarget(), renderTrolleySidebar(), resetTrolleyScan() (+2 more)

### Community 70 - "Community 70"
Cohesion: 0.31
Nodes (9): staging.legacy_customer_master, staging.legacy_customer_schedule, staging.legacy_customer_status_override, staging.legacy_mop_variant_mapping, staging.legacy_route_mapping, staging.legacy_trolley_override, staging.v_legacy_effective_trolley_review, staging.v_legacy_import_blockers (+1 more)

### Community 72 - "Community 72"
Cohesion: 0.20
Nodes (3): public.v_trolley_customer_history, public.v_trolley_reconciliation_queue, public.v_trolleys_at_customers

### Community 73 - "Community 73"
Cohesion: 0.20
Nodes (3): public.get_staff_directory(), public.operational_roles, public.staff_cover_capabilities

### Community 74 - "Community 74"
Cohesion: 0.20
Nodes (6): public.get_sorting_washing_context_v3(), public.customer_schedule_days, public.customer_schedule_products, public.distribution_routes, public.sorting_wash_run_customers, public.sorting_wash_runs

### Community 75 - "Community 75"
Cohesion: 0.20
Nodes (6): public.require_production_flow_abs_batch_write_access(), public.production_flow_external_batches, public.sorting_mop_production_lines, public.sorting_mop_production_trolleys, public.staff_members, trace_rows

### Community 76 - "Community 76"
Cohesion: 0.20
Nodes (7): public.get_production_tracker_v1(), public.customer_schedule_days, public.customers, public.distribution_routes, public.staff_members, public.trolley_customer_stays, public.trolley_events

### Community 77 - "Community 77"
Cohesion: 0.42
Nodes (9): public.account_access_profiles, public.account_roles, public.get_current_account_access(), public.has_any_role(), auth.users, public.production_station_devices, public.roles, public.staff_members (+1 more)

### Community 80 - "Community 80"
Cohesion: 0.25
Nodes (7): public.production_roster_assert_operational_rules(), public.save_production_roster_week(), public.production_roster_entries, public.production_roster_versions, public.shifts, public.sorting_daily_staff_modes, public.staff_members

### Community 81 - "Community 81"
Cohesion: 0.22
Nodes (7): public.get_sorting_staff_dashboard_context(), public.sorting_shift_auto_absence_context(), public.app_config, public.production_targets, public.shifts, public.sorting_daily_staff_attendance, public.sorting_wash_runs

### Community 82 - "Community 82"
Cohesion: 0.25
Nodes (5): public.finish_assert_processing_staff(), public.finish_processing_staff_available(), public.shifts, public.staff_members, public.stations

### Community 83 - "Community 83"
Cohesion: 0.22
Nodes (8): public.get_admin_account_access_directory(), auth.users, public.areas, public.production_station_devices, public.roles, public.staff_members, public.staff_roles, public.stations

### Community 84 - "Community 84"
Cohesion: 0.22
Nodes (8): public.get_admin_account_access_directory(), auth.users, public.areas, public.production_station_devices, public.roles, public.staff_members, public.staff_roles, public.stations

### Community 85 - "Community 85"
Cohesion: 0.50
Nodes (7): navigationAccess(), operationalContext(), operationalModules(), primaryOperationalModule(), primaryRole(), resolveShell(), uniqueRoleCodes()

### Community 86 - "Community 86"
Cohesion: 0.29
Nodes (7): public.production_roster_leave_gm_reviews, public.get_my_production_roster_leave_requests(), public.production_roster_autopublish_runs, public.run_production_roster_sunday_autopublish(), public.production_roster_leave_requests, public.roster_periods, public.shifts

### Community 87 - "Community 87"
Cohesion: 0.52
Nodes (6): decide(), formatDate(), lockActions(), render(), rpc(), setMessage()

### Community 88 - "Community 88"
Cohesion: 0.48
Nodes (6): createModuleLink(), currentModuleId(), dublinDateKey(), moduleHref(), render(), roleIsEffective()

### Community 92 - "Community 92"
Cohesion: 0.29
Nodes (4): public.get_sorting_staff_work_context_v2(), public.production_roster_entries, public.shifts, public.sorting_daily_staff_modes

### Community 93 - "Community 93"
Cohesion: 0.29
Nodes (6): public.get_sorting_mop_recent_trace(), public.production_flow_external_batches, public.sorting_mop_production_lines, public.sorting_mop_production_trolleys, public.staff_members, trace_rows

### Community 95 - "Community 95"
Cohesion: 0.29
Nodes (5): public.finish_processing_staff_available(), public.areas, public.production_roster_entries, public.production_roster_versions, public.staff_members

### Community 98 - "Community 98"
Cohesion: 0.40
Nodes (5): public.production_roster_autopublish_state, public.run_production_roster_sunday_autopublish(), public.production_roster_versions, public.roster_periods, public.shifts

### Community 100 - "Community 100"
Cohesion: 0.33
Nodes (3): public.production_roster_break_minutes_for(), public.production_roster_calendar_exceptions, public.production_roster_work_profiles

### Community 101 - "Community 101"
Cohesion: 0.33
Nodes (3): public.production_roster_work_profile_context(), public.production_roster_calendar_exceptions, public.production_roster_work_profiles

### Community 104 - "Community 104"
Cohesion: 0.40
Nodes (4): cleanup_flow_ids, cleanup_mop_ids, cleanup_stays, cleanup_trolleys

## Knowledge Gaps
- **19 isolated node(s):** `cleanup_flow_ids`, `cleanup_mop_ids`, `cleanup_stays`, `cleanup_trolleys`, `customer_master_test_state` (+14 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **24 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `titleCode()` connect `Community 13` to `Community 11`, `Community 3`, `Community 4`?**
  _High betweenness centrality (0.004) - this node is a cross-community bridge._
- **Why does `processedCell()` connect `Community 4` to `Community 13`?**
  _High betweenness centrality (0.004) - this node is a cross-community bridge._
- **What connects `cleanup_flow_ids`, `cleanup_mop_ids`, `cleanup_stays` to the rest of the system?**
  _19 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.06227106227106227 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.09421402969790067 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.12885662431941924 - nodes in this community are weakly interconnected._
- **Should `Community 3` be split into smaller, more focused modules?**
  _Cohesion score 0.07127882599580712 - nodes in this community are weakly interconnected._