"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const elements = {
    message: $("rosterPageMessage"), grid: $("rosterGridCard"), week: $("rosterWeekInput"),
    sunday: $("rosterSundaySelect"), shift: $("rosterShiftSelect"), search: $("rosterSearchInput"),
    note: $("rosterWeekNote"), context: $("rosterContextBanner"), readOnly: $("rosterReadOnlyBanner"),
    documentStatus: $("rosterDocumentStatus"), save: $("rosterSaveButton"), publish: $("rosterPublishButton"),
    discard: $("rosterDiscardButton"), copy: $("rosterCopyButton"), nextWeek: $("rosterNextWeekButton"), history: $("rosterHistoryButton"),
    addStaff: $("rosterAddStaffButton"), staffLink: $("rosterStaffLinkButton"), print: $("rosterPrintButton"), signOut: $("rosterSignOutButton"),
    printMeta: $("rosterPrintMeta"), printFooter: $("rosterPrintFooter"), printFooterMeta: $("rosterPrintFooterMeta"), leaveRequests: $("rosterLeaveRequestsButton"), leaveRequestsCount: $("rosterLeaveRequestsCount"),
    leavePlanningBanner: $("rosterLeavePlanningBanner"), leavePlanningTitle: $("rosterLeavePlanningTitle"), leavePlanningText: $("rosterLeavePlanningText"), leavePlanningReview: $("rosterLeavePlanningReview"),
    legendToggle: $("rosterLegendToggle"), legend: $("rosterLegend"),
    quickMenu: $("rosterQuickStatusMenu"), quickTitle: $("rosterQuickStatusTitle"),
    quickSubtitle: $("rosterQuickStatusSubtitle"), quickOptions: $("rosterQuickStatusOptions"),
    quickClose: $("rosterQuickStatusClose"), quickDetails: $("rosterQuickStatusDetails"),
    dayModal: $("rosterDayModal"), dayForm: $("rosterDayForm"), dayTitle: $("rosterDayModalTitle"),
    daySubtitle: $("rosterDayModalSubtitle"), dayStatus: $("rosterDayStatus"), dayStatusButtons: $("rosterDayStatusButtons"),
    assignmentType: $("rosterAssignmentType"), role: $("rosterDayRole"), area: $("rosterDayArea"), station: $("rosterDayStation"), dayNote: $("rosterDayNote"),
    dayMessage: $("rosterDayMessage"), assignmentTypeField: $("rosterAssignmentTypeField"), roleField: $("rosterRoleField"),
    coverRoleField: $("rosterCoverRoleField"), coverRoleButtons: $("rosterCoverRoleButtons"), coverRoleHelp: $("rosterCoverRoleHelp"),
    areaField: $("rosterAreaField"), stationField: $("rosterStationField"), sortingWorkModeField: $("rosterSortingWorkModeField"), sortingWorkMode: $("rosterSortingWorkMode"), sortingWorkModeButtons: $("rosterSortingWorkModeButtons"),
    historyModal: $("rosterHistoryModal"), historyTitle: $("rosterHistoryTitle"), historyContent: $("rosterHistoryContent"),
    linkModal: $("rosterLinkModal"), createLink: $("rosterCreateLinkButton"), linkResult: $("rosterLinkResult"),
    linkInput: $("rosterLinkInput"), copyLink: $("rosterCopyLinkButton"), linkMessage: $("rosterLinkMessage"),
    leaveRequestsModal: $("rosterLeaveRequestsModal"), leaveRequestsList: $("rosterLeaveRequestsList"), leaveRequestsMessage: $("rosterLeaveRequestsMessage"),
    leaveSummary: $("rosterLeaveSummary"), leaveTabs: $("rosterLeaveTabs"), leaveHistorySearch: $("rosterLeaveHistorySearch"), leaveHistorySearchInput: $("rosterLeaveHistorySearchInput"),
    leaveCalendar: $("rosterLeaveCalendar"), leaveCalendarMonth: $("rosterLeaveCalendarMonth"), leaveCalendarShift: $("rosterLeaveCalendarShift"), leaveCalendarPrevious: $("rosterLeaveCalendarPrevious"), leaveCalendarNext: $("rosterLeaveCalendarNext"), leaveCalendarSummary: $("rosterLeaveCalendarSummary"), leaveCalendarGrid: $("rosterLeaveCalendarGrid"),
    settingsButton: $("rosterSettingsButton"), settingsModal: $("rosterSettingsModal"), settingsTabs: $("rosterSettingsTabs"), settingsTargets: $("rosterSettingsTargets"), settingsHours: $("rosterSettingsHours"), settingsLeave: $("rosterSettingsLeave"),
    targetSettingsList: $("rosterTargetSettingsList"), workingHoursSettings: $("rosterWorkingHoursSettings"), bankHolidayDate: $("rosterBankHolidayDate"), bankHolidayLabel: $("rosterBankHolidayLabel"), bankHolidayAdd: $("rosterBankHolidayAdd"), bankHolidayList: $("rosterBankHolidayList"), settingsMessage: $("rosterSettingsMessage"),
    leaveGmEmail: $("rosterLeaveGmEmail"), leaveGmThreshold: $("rosterLeaveGmThreshold"), leaveSettingsSave: $("rosterLeaveSettingsSave"),
    staffPickerModal: $("rosterStaffPickerModal"), staffPickerTitle: $("rosterStaffPickerTitle"), staffPickerSubtitle: $("rosterStaffPickerSubtitle"),
    staffPickerSearch: $("rosterStaffPickerSearch"), staffPickerList: $("rosterStaffPickerList"), staffPickerSelection: $("rosterStaffPickerSelection"),
    staffPickerSelected: $("rosterStaffPickerSelected"), staffPickerDays: $("rosterStaffPickerDays"), staffPickerAllDays: $("rosterStaffPickerAllDays"),
    staffPickerClearDays: $("rosterStaffPickerClearDays"), staffPickerCancelSelection: $("rosterStaffPickerCancelSelection"), staffPickerAdd: $("rosterStaffPickerAdd"),
    staffPickerIncludeOtherShift: $("rosterStaffPickerIncludeOtherShift"), staffPickerOverrideWarning: $("rosterStaffPickerOverrideWarning"),
    staffPickerOverrideConfirm: $("rosterStaffPickerOverrideConfirm"), staffPickerMessage: $("rosterStaffPickerMessage")
  };

  const STATUS = {
    WORKING: { label: "Working", abbr: "W", cls: "working" },
    COVER: { label: "Cover", abbr: "C", cls: "cover" },
    OFF: { label: "Off", abbr: "O", cls: "off" },
    SICK: { label: "Sick", abbr: "S", cls: "sick" },
    HOLIDAY: { label: "Holiday", abbr: "H", cls: "holiday" },
    TRAINING: { label: "Training", abbr: "T", cls: "training" },
    QUALITY_ANALYSIS: { label: "Quality Analysis", abbr: "QA", cls: "quality" }
  };
  const STATUS_ORDER = ["WORKING", "COVER", "OFF", "SICK", "HOLIDAY", "TRAINING", "QUALITY_ANALYSIS"];
  const STATUS_SHORTCUTS = { W: "WORKING", C: "COVER", O: "OFF", S: "SICK", H: "HOLIDAY", T: "TRAINING", Q: "QUALITY_ANALYSIS" };
  const GROUPS = ["SUPERVISOR", "SORTING_AREA", "LABEL", "GENERAL_OPERATIVE", "CLEANER", "SUPPORT_ROLE"];
  const GROUP_META = {
    SUPERVISOR: { label: "Supervisor", subtitle: "Production oversight", abbr: "SP", cls: "supervisor" },
    SORTING_AREA: { label: "Sorting Area", subtitle: "Sorting and washing preparation", abbr: "SA", cls: "sorting" },
    LABEL: { label: "Label", subtitle: "Label production", abbr: "LB", cls: "label" },
    GENERAL_OPERATIVE: { label: "Finish Area", subtitle: "General Operative table teams", abbr: "FA", cls: "finish" },
    CLEANER: { label: "Cleaner", subtitle: "Cleaning support", abbr: "CL", cls: "cleaner" },
    SUPPORT_ROLE: { label: "Support Role", subtitle: "Additional production support", abbr: "SR", cls: "support" }
  };
  const COVER_ROLE_META = {
    TEAM_LEADER: { label: "Team Leader", abbr: "TL", hint: "Lead a production table or area" },
    SORTING_AREA: { label: "Sorting Area", abbr: "SA", hint: "Cover the Sorting Area function" },
    SUPERVISOR: { label: "Supervisor", abbr: "SP", hint: "Cover production supervision" }
  };
  const DISPLAY_SECTIONS = [
    { code: "SUPERVISOR", label: "Supervisor", group: "SUPERVISOR" },
    { code: "SORTING_AREA", label: "Sorting Area", group: "SORTING_AREA" },
    { code: "LABEL", label: "Label", group: "LABEL" },
    { code: "FINISH_TABLE_1", label: "Table 1", group: "GENERAL_OPERATIVE", table: "Table 1" },
    { code: "FINISH_TABLE_2", label: "Table 2", group: "GENERAL_OPERATIVE", table: "Table 2" },
    { code: "FINISH_TABLE_3", label: "Table 3", group: "GENERAL_OPERATIVE", table: "Table 3" },
    { code: "FINISH_OTHER", label: "Finish Area · Other", group: "GENERAL_OPERATIVE", table: "Other" },
    { code: "CLEANER", label: "Cleaner", group: "CLEANER" },
    { code: "SUPPORT_ROLE", label: "Support Role", group: "SUPPORT_ROLE" }
  ];

  const state = {
    reference: null, data: null, staff: [], staffPool: [], entries: new Map(), layouts: new Map(), leaveLocks: new Map(), leavePending: new Map(), leaveDashboard: null, leaveScope: "ACTION", leaveSettingsValue: null,
    accessProfile: null, canEditRoster: false, canApproveLeave: false, canManageRoster: false, leaveCalendarData: null,
    operationalSettings: null, settingsBundle: null, settingsTab: "TARGETS", leaveRevision: "", leaveHistorySearchTimer: null, capacityCollapsed: false, capacitySimulationPercent: 100, dirty: false,
    editingKey: "", quickKey: "", staffPickerSelectedId: "", historyVersionId: null, loading: false,
    loadedWeekStart: "", loadedShiftCode: "", suspiciousShiftDraft: null, shiftIntegrity: null
  };
  try { state.capacityCollapsed = window.localStorage.getItem("eliscaretex.roster.capacity.collapsed") === "1"; } catch (_) {}

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[char]));
  }

  function setMessage(text = "", type = "") {
    elements.message.textContent = text;
    elements.message.className = "roster-page-message" + (type ? ` ${type}` : "");
  }

  function friendlyError(error) {
    const text = error?.message || String(error || "Unexpected error.");
    if (text.includes("40001")) return "This roster changed in another session. Reload before continuing.";
    return text;
  }

  async function rpc(name, args = {}) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function canAccountAction(moduleCode,action) {
    const grant=(state.accessProfile?.permissions||[]).find((item)=>item.module_code===moduleCode);
    if (!grant) return false;
    if (action==="VIEW") return grant.can_view||grant.can_create||grant.can_edit||grant.can_approve||grant.can_manage;
    if (action==="CREATE") return grant.can_create||grant.can_manage;
    if (action==="EDIT") return grant.can_edit||grant.can_manage;
    if (action==="APPROVE") return grant.can_approve||grant.can_manage;
    return action==="MANAGE"&&grant.can_manage;
  }

  function dateIso(date) {
    return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate())).toISOString().slice(0, 10);
  }

  function addDays(iso, days) {
    const date = new Date(`${iso}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + days);
    return dateIso(date);
  }

  function dublinTodayIso() {
    const parts = new Intl.DateTimeFormat("en-IE", {
      timeZone: "Europe/Dublin", year: "numeric", month: "2-digit", day: "2-digit"
    }).formatToParts(new Date());
    const values = Object.fromEntries(parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
    return `${values.year}-${values.month}-${values.day}`;
  }

  function isoWeekday(isoDate) {
    const day = new Date(`${isoDate}T00:00:00Z`).getUTCDay();
    return day === 0 ? 7 : day;
  }

  function currentMonday() {
    const today = dublinTodayIso();
    const utc = new Date(`${today}T00:00:00Z`);
    const day = utc.getUTCDay() || 7;
    utc.setUTCDate(utc.getUTCDate() - day + 1);
    return dateIso(utc);
  }

  function isoWeekValue(isoDate) {
    const date = new Date(`${isoDate}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + 4 - (date.getUTCDay() || 7));
    const yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1));
    const week = Math.ceil((((date - yearStart) / 86400000) + 1) / 7);
    return `${date.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
  }

  function mondayFromWeekValue(value) {
    const match = String(value || "").match(/^(\d{4})-W(\d{2})$/);
    if (!match) return currentMonday();
    const year = Number(match[1]);
    const week = Number(match[2]);
    const jan4 = new Date(Date.UTC(year, 0, 4));
    const jan4Day = jan4.getUTCDay() || 7;
    const monday = new Date(jan4);
    monday.setUTCDate(jan4.getUTCDate() - jan4Day + 1 + (week - 1) * 7);
    return dateIso(monday);
  }

  function formatDate(iso, options = {}) {
    if (!iso) return "—";
    return new Intl.DateTimeFormat("en-IE", { day: "2-digit", month: "short", year: options.year === false ? undefined : "numeric", timeZone: "UTC" }).format(new Date(`${String(iso).slice(0, 10)}T00:00:00Z`));
  }

  function formatDateTime(value) {
    if (!value) return "—";
    return new Intl.DateTimeFormat("en-IE", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
  }

  function visibleDays() {
    const count = elements.sunday.value === "1" ? 7 : 6;
    return Array.from({ length: count }, (_, index) => addDays(mondayFromWeekValue(elements.week.value), index));
  }

  function entryKey(staffId, workDate) { return `${staffId}|${workDate}`; }
  function virtualStatus(entry) { return entry.assignment_type === "COVER" ? "COVER" : entry.day_status; }

  function staffAvailableOnDate(staff, workDate) {
    const joinedOn = String(staff?.joined_on || "");
    const deactivatedOn = String(staff?.deactivated_on || "");
    return (!joinedOn || workDate >= joinedOn) && (!deactivatedOn || workDate <= deactivatedOn);
  }

  function staffUnavailableLabel(staff, workDate) {
    const joinedOn = String(staff?.joined_on || "");
    const deactivatedOn = String(staff?.deactivated_on || "");
    if (joinedOn && workDate < joinedOn) return `Not joined · ${formatDate(joinedOn, { year: false })}`;
    if (deactivatedOn && workDate > deactivatedOn) return `Left · ${formatDate(deactivatedOn, { year: false })}`;
    return "Unavailable";
  }

  function isSortingWorkingEntry(entry) {
    return Boolean(entry && entry.day_status === "WORKING" && (String(entry.area_code || "").toUpperCase() === "SORTING" || String(entry.operational_role_code || "").toUpperCase() === "SORTING_AREA"));
  }

  function normalizedSortingWorkMode(entry) {
    if (!isSortingWorkingEntry(entry)) return null;
    const mode = String(entry.sorting_work_mode || "").toUpperCase();
    if (mode === "MOP") return "MOP";
    if (mode === "CLOTHES") return "CLOTHES";
    return null;
  }

  function defaultEntry(staff, workDate) {
    const available = staffAvailableOnDate(staff, workDate);
    return {
      staff_id: staff.staff_id, work_date: workDate, day_status: available ? "WORKING" : "OFF", assignment_type: "BASE",
      operational_role_code: available ? (staff.primary_role_code || "GENERAL_OPERATIVE") : null,
      area_code: available ? (staff.default_area_code || "FINISH") : null,
      station_code: available ? (staff.default_station_code || null) : null,
      planned_start_time: available ? (state.data?.shift?.start_time || null) : null,
      planned_end_time: available ? (state.data?.shift?.end_time || null) : null,
      sorting_work_mode: available && String(staff.default_area_code || "").toUpperCase() === "SORTING" ? "CLOTHES" : null,
      notes: null
    };
  }

  function defaultDisplaySection(staff) {
    if (DISPLAY_SECTIONS.some((item) => item.code === staff?.display_section_code)) return staff.display_section_code;
    const roleCode = staff?.primary_role_code || "SUPPORT_ROLE";
    if (["SUPERVISOR", "SORTING_AREA", "LABEL", "CLEANER", "SUPPORT_ROLE"].includes(roleCode)) return roleCode;
    const stationCode = String(staff?.default_station_code || "");
    if (["FINISH_TABLE_1", "FINISH_TABLE_2", "FINISH_TABLE_3"].includes(stationCode)) return stationCode;
    return "FINISH_OTHER";
  }

  function baseAssignmentForDisplaySection(staff, sectionCode, entry = {}) {
    const code = String(sectionCode || defaultDisplaySection(staff) || "").toUpperCase();
    const requestedRole = String(entry?.operational_role_code || staff?.primary_role_code || "").toUpperCase();
    if (code === "SORTING_AREA") return { operational_role_code: "SORTING_AREA", area_code: "SORTING", station_code: "SORTING_MAIN" };
    if (code === "LABEL") return { operational_role_code: "LABEL", area_code: "FINISH", station_code: "FINISH_LABEL" };
    if (code === "SUPERVISOR") return { operational_role_code: "SUPERVISOR", area_code: "FINISH", station_code: null };
    if (code === "CLEANER") return { operational_role_code: "CLEANER", area_code: "FINISH", station_code: null };
    if (["FINISH_TABLE_1", "FINISH_TABLE_2", "FINISH_TABLE_3"].includes(code)) {
      return {
        operational_role_code: requestedRole === "TEAM_LEADER" || staff?.primary_role_code === "TEAM_LEADER" ? "TEAM_LEADER" : "GENERAL_OPERATIVE",
        area_code: "FINISH",
        station_code: code
      };
    }
    if (code === "FINISH_OTHER") {
      return {
        operational_role_code: requestedRole === "TEAM_LEADER" || staff?.primary_role_code === "TEAM_LEADER" ? "TEAM_LEADER" : "GENERAL_OPERATIVE",
        area_code: "FINISH",
        station_code: null
      };
    }
    return {
      operational_role_code: entry?.operational_role_code || staff?.primary_role_code || "GENERAL_OPERATIVE",
      area_code: entry?.area_code || staff?.default_area_code || "FINISH",
      station_code: entry?.station_code ?? staff?.default_station_code ?? null
    };
  }

  function supportsMixedDailyAssignments(staff) {
    return displaySection(staff)?.code === "SUPPORT_ROLE";
  }

  function supportsTableDailyOverride(staff) {
    return ["FINISH_TABLE_1", "FINISH_TABLE_2", "FINISH_TABLE_3"].includes(displaySection(staff)?.code);
  }

  function isFinishTableStation(code) {
    return ["FINISH_TABLE_1", "FINISH_TABLE_2", "FINISH_TABLE_3"].includes(String(code || "").toUpperCase());
  }

  function finishTableAbbr(code) {
    const stationCode = String(code || "").toUpperCase();
    if (stationCode === "FINISH_TABLE_1") return "T1";
    if (stationCode === "FINISH_TABLE_2") return "T2";
    if (stationCode === "FINISH_TABLE_3") return "T3";
    return "";
  }

  function baseAssignmentForDailyEdit(staff, entry = {}, resetDailyOverrides = false) {
    const sectionCode = String(state.layouts.get(staff.staff_id) || defaultDisplaySection(staff) || "").toUpperCase();
    const expected = baseAssignmentForDisplaySection(staff, sectionCode, entry);
    if (!resetDailyOverrides && isFinishTableStation(sectionCode) && isFinishTableStation(entry?.station_code)) {
      return { ...expected, station_code: String(entry.station_code).toUpperCase() };
    }
    return expected;
  }

  function syncBaseAssignmentsForStaff(staff, sectionCode = state.layouts.get(staff.staff_id), options = {}) {
    const code = String(sectionCode || defaultDisplaySection(staff) || "").toUpperCase();
    if (code === "SUPPORT_ROLE") return 0;
    const resetDailyOverrides = options.resetDailyOverrides === true;
    let changed = 0;
    visibleDays().forEach((day) => {
      const key = entryKey(staff.staff_id, day);
      const entry = state.entries.get(key);
      if (!entry || entry.assignment_type === "COVER" || !["WORKING", "QUALITY_ANALYSIS"].includes(entry.day_status)) return;
      const expected = baseAssignmentForDailyEdit(staff, entry, resetDailyOverrides);
      if (
        entry.operational_role_code !== expected.operational_role_code
        || entry.area_code !== expected.area_code
        || (entry.station_code || null) !== (expected.station_code || null)
      ) {
        const next = { ...entry, ...expected };
        next.sorting_work_mode = normalizedSortingWorkMode(next);
        state.entries.set(key, next);
        changed += 1;
      }
    });
    return changed;
  }

  function syncAllBaseAssignmentsToSections() {
    return state.staff.reduce((total, staff) => total + syncBaseAssignmentsForStaff(staff), 0);
  }

  function rebuildLayouts(serverEntries = []) {
    state.layouts = new Map();
    const entryLayout = new Map();
    serverEntries.forEach((entry) => {
      if (entry.display_section_code && !entryLayout.has(entry.staff_id)) entryLayout.set(entry.staff_id, entry.display_section_code);
    });
    state.staff.forEach((staff) => {
      const selected = staff.display_section_code || entryLayout.get(staff.staff_id) || defaultDisplaySection(staff);
      state.layouts.set(staff.staff_id, DISPLAY_SECTIONS.some((item) => item.code === selected) ? selected : defaultDisplaySection(staff));
    });
  }

  function rebuildEntries() {
    state.entries = new Map();
    const days = visibleDays();
    const serverEntries = Array.isArray(state.data?.entries) ? state.data.entries : [];
    rebuildLayouts(serverEntries);
    serverEntries.forEach((entry) => {
      const next = { ...entry };
      next.sorting_work_mode = isSortingWorkingEntry(next)
        ? (String(entry.sorting_work_mode || "").toUpperCase() || null)
        : null;
      state.entries.set(entryKey(entry.staff_id, entry.work_date), next);
    });
    state.staff.forEach((staff) => days.forEach((day) => {
      const key = entryKey(staff.staff_id, day);
      if (!state.entries.has(key)) state.entries.set(key, defaultEntry(staff, day));
    }));
  }

  function reconcileStaffMasterAvailability() {
    if (!isEditable() || isHistorical()) return { removed: [], adjustedDays: 0 };
    const days = visibleDays();
    const firstDay = days[0] || "";
    const lastDay = days[days.length - 1] || "";
    const removed = [];
    let adjustedDays = 0;

    const kept = [];
    state.staff.forEach((staff) => {
      const joinedOn = String(staff.joined_on || "");
      const deactivatedOn = String(staff.deactivated_on || "");
      const entirelyOutside = (deactivatedOn && deactivatedOn < firstDay) || (joinedOn && joinedOn > lastDay);
      const masterUnavailableWithoutDates = staff.currently_eligible === false && !joinedOn && !deactivatedOn && (staff.master_active === false || staff.master_roster_eligible === false || staff.master_production_staff === false);
      if (entirelyOutside || masterUnavailableWithoutDates) {
        removed.push(staff);
        state.layouts.delete(staff.staff_id);
        [...state.entries.keys()].filter((key) => key.startsWith(`${staff.staff_id}|`)).forEach((key) => state.entries.delete(key));
        return;
      }

      days.forEach((day) => {
        if (staffAvailableOnDate(staff, day)) return;
        const key = entryKey(staff.staff_id, day);
        const entry = state.entries.get(key);
        if (!entry) return;
        if (entry.day_status !== "OFF" || entry.assignment_type !== "BASE" || entry.operational_role_code || entry.area_code || entry.station_code || entry.sorting_work_mode) {
          state.entries.set(key, { ...entry, day_status: "OFF", assignment_type: "BASE", operational_role_code: null, area_code: null, station_code: null, sorting_work_mode: null, planned_start_time: null, planned_end_time: null });
          adjustedDays += 1;
        }
      });
      kept.push(staff);
    });
    state.staff = kept;
    return { removed, adjustedDays };
  }

  function includeJoinedStaffInEditableRoster() {
    if (!isEditable() || isHistorical()) return 0;
    const days = visibleDays();
    const lastVisibleDay = days[days.length - 1] || "";
    const currentShift = String(state.data?.shift?.shift_code || "");
    const included = new Set(state.staff.map((staff) => staff.staff_id));
    const joiners = state.staffPool.filter((staff) =>
      staff.currently_eligible !== false
      && !included.has(staff.staff_id)
      && staff.default_shift_code === currentShift
      && staff.joined_on
      && staff.joined_on <= lastVisibleDay
    );

    joiners.forEach((staff) => {
      const includedStaff = { ...staff, included_in_roster: true, auto_added_from_joined_on: true, shift_override_authorized: false, shift_override_source: null };
      state.staff.push(includedStaff);
      const sectionCode = defaultDisplaySection(includedStaff);
      state.layouts.set(includedStaff.staff_id, sectionCode);
      days.forEach((day) => {
        const entry = defaultEntry(includedStaff, day);
        if (entry.day_status === "WORKING") Object.assign(entry, baseAssignmentForDisplaySection(includedStaff, sectionCode, entry));
        state.entries.set(entryKey(includedStaff.staff_id, day), entry);
      });
    });

    return joiners.length;
  }

  function adjustEntriesToVisibleDays() {
    const days = new Set(visibleDays());
    const next = new Map();
    state.staff.forEach((staff) => days.forEach((day) => {
      const key = entryKey(staff.staff_id, day);
      next.set(key, state.entries.get(key) || defaultEntry(staff, day));
    }));
    state.entries = next;
  }

  function isHistorical() {
    return Boolean(state.historyVersionId) || Boolean(state.data?.document?.is_historical);
  }

  function isEditable() {
    return Boolean(state.data?.can_manage) && !state.data?.is_past && !isHistorical();
  }

  function selectedRosterContext() {
    return {
      weekStart: mondayFromWeekValue(elements.week.value),
      shiftCode: String(elements.shift.value || "").toUpperCase()
    };
  }

  function loadedRosterContextMatchesControls() {
    const selected = selectedRosterContext();
    return Boolean(
      state.loadedWeekStart
      && state.loadedShiftCode
      && state.loadedWeekStart === selected.weekStart
      && state.loadedShiftCode === selected.shiftCode
      && String(state.data?.shift?.shift_code || "").toUpperCase() === selected.shiftCode
    );
  }

  function restoreLoadedRosterContextControls() {
    if (state.loadedWeekStart) elements.week.value = isoWeekValue(state.loadedWeekStart);
    if (state.loadedShiftCode) elements.shift.value = state.loadedShiftCode;
  }

  function suspiciousShiftDraftSummary() {
    const document = state.data?.document;
    const shiftCode = String(state.data?.shift?.shift_code || "").toUpperCase();
    if (!document || document.status !== "DRAFT" || !shiftCode || state.staff.length < 5) return null;

    const staffWithDefaultShift = state.staff.filter((staff) => staff.default_shift_code);
    const sameShiftCount = staffWithDefaultShift.filter((staff) => staff.default_shift_code === shiftCode).length;
    const crossShiftCount = staffWithDefaultShift.filter((staff) => staff.default_shift_code !== shiftCode).length;

    if (sameShiftCount === 0 && crossShiftCount >= 5 && crossShiftCount === staffWithDefaultShift.length) {
      return {
        shiftCode,
        shiftName: state.data?.shift?.shift_name || shiftCode,
        staffCount: state.staff.length,
        crossShiftCount
      };
    }
    return null;
  }

  function setDirty(flag) {
    state.dirty = Boolean(flag);
    document.title = `${state.dirty ? "* " : ""}Production Roster | ElisCaretex`;
    renderControls();
  }

  function leaveLockKey(staffId, workDate) { return `${staffId}|${workDate}`; }

  function approvedLeaveStatus(requestType) {
    return String(requestType || "").toUpperCase() === "HOLIDAY" ? "HOLIDAY" : "OFF";
  }

  function applyApprovedLeaveOverlay(items = []) {
    state.leaveLocks = new Map();
    if (isHistorical()) return false;
    const staffIds = new Set(state.staff.map((staff) => staff.staff_id));
    const visible = new Set(visibleDays());
    let changed = false;
    (Array.isArray(items) ? items : []).forEach((item) => {
      if (!staffIds.has(item.staff_id) || !visible.has(item.work_date)) return;
      const key = leaveLockKey(item.staff_id, item.work_date);
      state.leaveLocks.set(key, item);
      const staff = state.staff.find((candidate) => candidate.staff_id === item.staff_id);
      const entry = state.entries.get(key) || defaultEntry(staff, item.work_date);
      const desired = approvedLeaveStatus(item.request_type);
      if (entry.day_status !== desired || entry.assignment_type !== "BASE" || entry.operational_role_code || entry.area_code || entry.station_code || entry.planned_start_time || entry.planned_end_time) {
        changed = true;
        state.entries.set(key, {
          ...entry,
          day_status: desired,
          assignment_type: "BASE",
          operational_role_code: null,
          area_code: null,
          station_code: null,
          planned_start_time: null,
          planned_end_time: null,
        });
      }
    });
    return changed;
  }

  async function refreshApprovedLeaveOverlay() {
    if (!state.data || isHistorical()) return false;
    try {
      const items = await rpc("get_production_roster_approved_leave", {
        p_week_start: mondayFromWeekValue(elements.week.value),
        p_shift_code: elements.shift.value,
      });
      const changed = applyApprovedLeaveOverlay(items);
      if (changed) setDirty(true);
      renderLeavePlanningBanner();
      renderGrid();
      return changed;
    } catch (error) {
      console.warn("Approved leave overlay could not be refreshed.", error);
      return false;
    }
  }

  function applyPendingLeaveOverlay(items = []) {
    state.leavePending = new Map();
    if (isHistorical()) { renderLeavePlanningBanner(); return; }
    const staffIds = new Set(state.staff.map((staff) => staff.staff_id));
    const visible = new Set(visibleDays());
    (Array.isArray(items) ? items : []).forEach((item) => {
      if (!staffIds.has(item.staff_id) || !visible.has(item.work_date)) return;
      state.leavePending.set(leaveLockKey(item.staff_id, item.work_date), item);
    });
    renderLeavePlanningBanner();
  }

  function pendingLeaveRequestIds() {
    return new Set([...state.leavePending.values()].map((item) => item.leave_request_id).filter(Boolean));
  }

  function renderLeavePlanningBanner() {
    if (!elements.leavePlanningBanner) return;
    const requestIds = pendingLeaveRequestIds();
    const count = requestIds.size;
    const show = Boolean(state.data?.can_manage) && !isHistorical() && count > 0;
    elements.leavePlanningBanner.classList.toggle("hidden", !show);
    if (!show) return;
    const gmCount = new Set([...state.leavePending.values()].filter((item) => item.requires_general_manager).map((item) => item.leave_request_id)).size;
    elements.leavePlanningTitle.textContent = `${count} unresolved leave ${count === 1 ? "request affects" : "requests affect"} this roster week`;
    elements.leavePlanningText.textContent = `${gmCount ? `${gmCount} require${gmCount === 1 ? "s" : ""} General Manager approval. ` : ""}Requested dates are marked REQ/GM in the planner but remain editable until a decision is approved.`;
  }

  async function refreshPendingLeaveOverlay() {
    if (!state.data?.can_manage || isHistorical()) { applyPendingLeaveOverlay([]); return []; }
    try {
      const items = await rpc("get_production_roster_pending_leave", {
        p_week_start: mondayFromWeekValue(elements.week.value),
        p_shift_code: elements.shift.value,
      });
      applyPendingLeaveOverlay(items);
      renderGrid();
      return Array.isArray(items) ? items : [];
    } catch (error) {
      console.warn("Pending leave overlay could not be refreshed.", error);
      return [];
    }
  }

  function preparePrintHeader() {
    if (!elements.printMeta || !state.data) return;
    const start = mondayFromWeekValue(elements.week.value);
    const end = addDays(start, elements.sunday.value === "1" ? 6 : 5);
    const rosterDocument = state.data?.document || null;
    const printedAt = formatDateTime(new Date());

    elements.printMeta.textContent = `${formatDate(start)} – ${formatDate(end)} · ${state.data.shift?.shift_name || elements.shift.value}`;

    if (!elements.printFooterMeta) return;
    if (!rosterDocument) {
      elements.printFooterMeta.textContent = `UNSAVED ROSTER — NOT PUBLISHED · Printed ${printedAt}`;
      return;
    }

    const version = Number(rosterDocument.version_number || 0);
    if (rosterDocument.published_at && ["PUBLISHED", "SUPERSEDED"].includes(String(rosterDocument.status || "").toUpperCase())) {
      const copyType = String(rosterDocument.status || "").toUpperCase() === "SUPERSEDED" ? "Historical published copy" : "Published copy";
      elements.printFooterMeta.textContent = `${copyType} · Version ${version} · Published ${formatDateTime(rosterDocument.published_at)} · Printed ${printedAt}`;
      return;
    }

    elements.printFooterMeta.textContent = `DRAFT — NOT PUBLISHED · Version ${version} · Saved ${formatDateTime(rosterDocument.saved_at)} · Printed ${printedAt}`;
  }

  function beginPrint() {
    preparePrintHeader();
    document.documentElement.style.setProperty("--print-days", String(visibleDays().length));
    document.body.classList.add("roster-print-fit");
    document.body.style.zoom = "";
    requestAnimationFrame(() => {
      const headerHeight = document.getElementById("rosterPrintHeader")?.scrollHeight || 0;
      const footerHeight = elements.printFooter?.scrollHeight || 0;
      const gridHeight = elements.grid?.scrollHeight || 0;
      const printableHeightPx = (297 - 12) * (96 / 25.4);
      const total = headerHeight + gridHeight + footerHeight + 20;
      let zoom = total > 0 ? (printableHeightPx - 12) / total : 0.92;
      zoom = Math.min(0.92, Math.max(0.50, zoom));
      document.body.style.zoom = String(zoom);
      setTimeout(() => window.print(), 0);
    });
  }

  function endPrint() {
    document.body.classList.remove("roster-print-fit");
    document.body.style.zoom = "";
    document.documentElement.style.removeProperty("--print-days");
  }

  async function refreshLeaveRequestBadge() {
    if (!state.data?.can_manage || !elements.leaveRequests) return;
    try {
      const dashboard = await rpc("get_production_roster_leave_dashboard", {
        p_week_start: mondayFromWeekValue(elements.week.value),
        p_shift_code: null,
        p_scope: "ACTION"
      });
      state.leaveDashboard = dashboard || null;
      const count = Number(dashboard?.summary?.action_count || 0);
      elements.leaveRequestsCount.textContent = String(count);
      elements.leaveRequestsCount.classList.toggle("hidden", count === 0);
      elements.leaveRequests.classList.toggle("has-requests", count > 0);
    } catch (error) {
      console.warn("Leave request action count could not be loaded.", error);
    }
  }

  function isNewUnsavedFutureRoster() {
    if (!isEditable() || isHistorical() || state.data?.document) return false;
    return mondayFromWeekValue(elements.week.value) > currentMonday();
  }

  function canOpenNextWeekFromCurrentWeek(todayIso = dublinTodayIso()) {
    if (!state.data?.can_manage || isHistorical()) return false;
    if (mondayFromWeekValue(elements.week.value) !== currentMonday()) return false;
    return isoWeekday(todayIso) >= 2;
  }

  function renderControls() {
    const editable = isEditable();
    document.querySelectorAll(".roster-manage-only").forEach((node) => node.classList.toggle("hidden", !state.data?.can_manage));
    elements.week.disabled = state.loading;
    elements.shift.disabled = state.loading;
    const hasUnverifiedCrossShift = crossShiftStaffIssues().length > 0;
    elements.save.disabled = !editable || !state.dirty || state.loading || Boolean(state.suspiciousShiftDraft) || hasUnverifiedCrossShift;
    elements.publish.disabled = !editable || state.loading || Boolean(state.suspiciousShiftDraft) || hasUnverifiedCrossShift || (state.data?.document?.status === "PUBLISHED" && !state.dirty);
    const showCreateFromPrevious = isNewUnsavedFutureRoster();
    const showCreateNextWeek = canOpenNextWeekFromCurrentWeek();
    elements.copy.classList.toggle("hidden", !showCreateFromPrevious);
    elements.copy.disabled = !showCreateFromPrevious || state.loading;
    elements.nextWeek.classList.toggle("hidden", !showCreateNextWeek);
    elements.nextWeek.disabled = !showCreateNextWeek || state.loading;
    elements.addStaff.disabled = !editable || state.loading;
    elements.note.disabled = !editable;
    elements.sunday.disabled = !editable && Boolean(state.data?.document);
    elements.discard.classList.toggle("hidden", !(editable && state.data?.document?.status === "DRAFT"));

    const rosterDocument = state.data?.document;
    elements.documentStatus.innerHTML = rosterDocument
      ? `<strong>${escapeHtml(rosterDocument.status)} · Version ${Number(rosterDocument.version_number)}</strong>${rosterDocument.published_at ? `Published ${escapeHtml(formatDateTime(rosterDocument.published_at))}` : `Saved ${escapeHtml(formatDateTime(rosterDocument.saved_at))}`}${state.dirty ? '<span class="roster-unsaved"> · Unsaved changes</span>' : ""}`
      : `<strong>New roster</strong>Not saved yet${state.dirty ? '<span class="roster-unsaved"> · Unsaved changes</span>' : ""}`;

    elements.readOnly.classList.toggle("hidden", editable);
    if (!editable) {
      elements.readOnly.textContent = state.data?.is_past ? "This week has already passed and is locked (read-only)." : isHistorical() ? "You are viewing a historical roster version." : "You have read-only access to this roster.";
    }
  }

  function renderContext() {
    const selected = mondayFromWeekValue(elements.week.value);
    const current = currentMonday();
    const diff = Math.round((new Date(`${selected}T00:00:00Z`) - new Date(`${current}T00:00:00Z`)) / 604800000);
    let cls = "future", label = `${diff} weeks ahead`;
    if (diff < 0) { cls = "past"; label = "Past week"; }
    else if (diff === 0) { cls = "current"; label = "Current week"; }
    else if (diff === 1) { cls = "next"; label = "Next week"; }
    elements.context.className = `roster-context-banner ${cls}`;
    elements.context.textContent = `${label} · ${formatDate(selected)} – ${formatDate(addDays(selected, Number(elements.sunday.value) ? 6 : 5))}`;
  }

  function displaySection(staff) {
    const code = state.layouts.get(staff.staff_id) || defaultDisplaySection(staff);
    return DISPLAY_SECTIONS.find((item) => item.code === code) || DISPLAY_SECTIONS.find((item) => item.code === defaultDisplaySection(staff));
  }

  function roleGroup(staff) {
    return displaySection(staff)?.group || "SUPPORT_ROLE";
  }

  function stationTable(staff) {
    return displaySection(staff)?.table || "Other";
  }

  function displaySectionOptions(selectedCode) {
    const areaOptions = DISPLAY_SECTIONS.filter((item) => !item.code.startsWith("FINISH_")).map((item) => `<option value="${escapeHtml(item.code)}"${selectedCode === item.code ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("");
    const tableOptions = DISPLAY_SECTIONS.filter((item) => item.code.startsWith("FINISH_")).map((item) => `<option value="${escapeHtml(item.code)}"${selectedCode === item.code ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("");
    return `<optgroup label="Production areas">${areaOptions}</optgroup><optgroup label="Finish Area">${tableOptions}</optgroup>`;
  }

  function displaySectionControl(staff) {
    const section = displaySection(staff);
    const label = section?.label || "Support Role";
    if (!isEditable()) return `<div class="roster-display-section-readonly"><small>Row shown in</small><strong>${escapeHtml(label)}</strong></div>`;
    return `<label class="roster-display-section-control"><span>Show row in</span><select data-display-section-staff="${escapeHtml(staff.staff_id)}" aria-label="Choose where ${escapeHtml(staff.display_name)} appears in this weekly roster">${displaySectionOptions(section?.code)}</select></label><span class="roster-display-section-print">Row: ${escapeHtml(label)}</span>`;
  }

  function assignmentLabel(entry, staff) {
    const role = (state.reference.operational_roles || []).find((item) => item.role_code === entry?.operational_role_code)?.role_name || staff.primary_role_name || "—";
    const station = (state.reference.stations || []).find((item) => item.station_code === entry?.station_code)?.station_name || staff.default_station_name;
    const area = (state.reference.areas || []).find((item) => item.area_code === entry?.area_code)?.area_name || staff.default_area_name;
    return { role, location: station || area || "—" };
  }

  function trainingBadges(staff) {
    const badges = [];
    if (staff.eod_capable) {
      badges.push('<span class="roster-training-badge eod" title="EOD trained" aria-label="EOD trained">EOD</span>');
    }
    if (staff.first_aid_training) {
      badges.push('<span class="roster-training-badge icon first-aid" title="First Aid trained" aria-label="First Aid trained"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9.5 4.5h5v5h5v5h-5v5h-5v-5h-5v-5h5z"/></svg></span>');
    }
    if (staff.fire_training) {
      badges.push('<span class="roster-training-badge icon fire" title="Fire trained" aria-label="Fire trained"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M13.2 2.5c.6 3-1 4.5-2.5 6.1-1.3 1.4-2.5 2.8-2.2 5 .8-1 1.8-1.8 3.2-2.5-.2 2.4 1 3.2 2.1 4.1 1 .8 1.8 1.6 1.7 3.2 1.6-1.2 2.5-3 2.5-5 0-4.1-2.1-7.7-4.8-10.9zM11.8 21c-2.9 0-5.3-2.2-5.3-5 0-1.4.5-2.7 1.5-3.8.2 2.7 1.8 4.4 3.8 5.2-.3-1.6.4-2.7 1.2-3.7 1.4 1.2 2.2 2.7 2.2 4.2 0 1.7-1.5 3.1-3.4 3.1z"/></svg></span>');
    }
    return badges.length
      ? `<div class="roster-training-badges" aria-label="Training qualifications">${badges.join("")}</div>`
      : "";
  }

  function countsAsPlannedDay(entry) {
    if (!entry) return false;
    return ["WORKING", "COVER", "QUALITY_ANALYSIS", "TRAINING"].includes(virtualStatus(entry));
  }

  function weeklyWorkload(staff, days) {
    return days.reduce((total, day) => total + (countsAsPlannedDay(state.entries.get(entryKey(staff.staff_id, day))) ? 1 : 0), 0);
  }

  function isTeamLeaderForWeek(staff, days) {
    if (staff.primary_role_code === "TEAM_LEADER") return true;
    return days.some((day) => {
      const entry = state.entries.get(entryKey(staff.staff_id, day));
      return entry && countsAsPlannedDay(entry) && entry.operational_role_code === "TEAM_LEADER";
    });
  }

  function teamLeaderBadge(staff, days) {
    if (!isTeamLeaderForWeek(staff, days)) return "";
    const temporary = staff.primary_role_code !== "TEAM_LEADER";
    return `<span class="roster-team-leader-badge${temporary ? " temporary" : ""}" title="${temporary ? "Planned as Team Leader during this week" : "Primary operational role: Team Leader"}">TL · ${temporary ? "Team Leader this week" : "Team Leader"}</span>`;
  }

  function workloadBadge(staff, days) {
    const count = weeklyWorkload(staff, days);
    return `<span class="roster-workload-badge" title="Working, Cover, Quality Analysis and Training days"><strong>${count}</strong> ${count === 1 ? "day" : "days"}</span>`;
  }

  function isShiftOverride(staff) {
    return Boolean(staff?.default_shift_code && state.data?.shift?.shift_code && staff.default_shift_code !== state.data.shift.shift_code);
  }

  function shiftOverrideAuthorised(staff) {
    return !isShiftOverride(staff) || staff?.shift_override_authorized === true;
  }

  function shiftOverrideBadge(staff) {
    if (!isShiftOverride(staff)) return "";
    const from = staff.default_shift_name || staff.default_shift_code;
    const to = state.data?.shift?.shift_name || state.data?.shift?.shift_code;
    const verified = shiftOverrideAuthorised(staff);
    const cls = verified ? "roster-shift-override-badge" : "roster-shift-override-badge unverified";
    const title = verified
      ? `Confirmed temporary roster assignment. Staff Master remains ${from}.`
      : `Unverified cross-shift assignment. Remove and re-add explicitly if this temporary assignment is required.`;
    const prefix = verified ? "" : "Unverified · ";
    return `<span class="${cls}" title="${escapeHtml(title)}">${escapeHtml(prefix + from)} → ${escapeHtml(to)}</span>`;
  }

  function shiftOverrideControl(staff) {
    if (!isShiftOverride(staff) || !isEditable()) return "";
    const action = shiftOverrideAuthorised(staff) ? "Remove" : "Remove unverified";
    return `<button class="roster-remove-shift-override" type="button" data-remove-shift-override="${escapeHtml(staff.staff_id)}" title="Remove this temporary shift assignment">${action} from ${escapeHtml(state.data.shift.shift_name)}</button>`;
  }

  function crossShiftStaffIssues() {
    return state.staff.filter((staff) => isShiftOverride(staff) && !shiftOverrideAuthorised(staff));
  }

  function dayCell(staff, day) {
    const entry = state.entries.get(entryKey(staff.staff_id, day)) || defaultEntry(staff, day);
    const statusCode = virtualStatus(entry);
    const status = STATUS[statusCode] || STATUS.WORKING;
    const assignment = assignmentLabel(entry, staff);
    const section = displaySection(staff);
    const sectionCode = String(section?.code || "");
    const dailyDetail = isFinishTableStation(sectionCode)
      ? assignment.location
      : sectionCode && sectionCode !== "SUPPORT_ROLE"
        ? section.label
        : assignment.location;
    const coverTable = entry.operational_role_code === "TEAM_LEADER"
      ? finishTableAbbr(entry.station_code)
      : "";
    const coverDetail = entry.operational_role_code === "TEAM_LEADER"
      ? (coverTable ? `TL - ${coverTable}` : "TL")
      : assignment.role;
    const sortingMode = isSortingWorkingEntry(entry) ? normalizedSortingWorkMode(entry) : null;
    const detail = statusCode === "COVER"
      ? (sortingMode ? sortingMode : coverDetail)
      : ["WORKING", "QUALITY_ANALYSIS"].includes(statusCode)
        ? (sortingMode ? sortingMode : dailyDetail)
        : "";
    const leaveRequest = state.leaveLocks.get(leaveLockKey(staff.staff_id, day));
    const pendingRequest = leaveRequest ? null : state.leavePending.get(leaveLockKey(staff.staff_id, day));
    const pendingLabel = pendingRequest?.requires_general_manager ? "GM" : "REQ";
    const actionLabel = leaveRequest
      ? `${staff.display_name}, ${formatDate(day)}, approved ${String(leaveRequest.request_type || "leave").replaceAll("_", " ").toLowerCase()}. Locked.`
      : pendingRequest
        ? `${staff.display_name}, ${formatDate(day)}, ${status.label}. Pending ${String(pendingRequest.request_type || "leave").replaceAll("_", " ").toLowerCase()} request. The cell remains editable until a decision is approved.`
        : `${staff.display_name}, ${formatDate(day)}, ${status.label}. Click to change status.`;
    const interaction = isEditable() && !leaveRequest ? ' aria-haspopup="dialog" aria-controls="rosterQuickStatusMenu" aria-expanded="false"' : " disabled";
    const dailyTableOverride = entry.assignment_type !== "COVER"
      && ["WORKING", "QUALITY_ANALYSIS"].includes(statusCode)
      && isFinishTableStation(sectionCode)
      && isFinishTableStation(entry.station_code)
      && String(entry.station_code).toUpperCase() !== sectionCode;
    const detailClass = dailyTableOverride ? ' class="roster-table-override"' : "";
    const detailTitle = dailyTableOverride
      ? `${detail} — daily Table differs from ${section.label}`
      : detail;
    const sortingClass = sortingMode ? ` sorting-${sortingMode.toLowerCase()}` : "";
    return `<div class="roster-day-cell${leaveRequest ? " approved-leave" : pendingRequest ? " pending-leave-request" : ""}"><button class="roster-day-button ${status.cls}${sortingClass}${leaveRequest ? " leave-locked" : pendingRequest ? " leave-requested" : ""}" type="button" data-edit-day="${escapeHtml(staff.staff_id)}|${escapeHtml(day)}" aria-label="${escapeHtml(actionLabel)}" title="${escapeHtml(actionLabel)}"${interaction}><span>${status.abbr}</span>${leaveRequest ? '<b class="roster-leave-lock" aria-hidden="true">🔒</b>' : pendingRequest ? `<em class="roster-leave-request-flag${pendingRequest.requires_general_manager ? " gm" : ""}" aria-hidden="true">${pendingLabel}</em>` : ""}${detail ? `<small${detailClass} title="${escapeHtml(detailTitle)}">${escapeHtml(detail)}</small>` : ""}<i aria-hidden="true">⌄</i></button></div>`;
  }

  function weeklyAssignmentSummary(staff, days) {
    const assignments = days.map((day) => state.entries.get(entryKey(staff.staff_id, day)))
      .filter((entry) => entry && ["WORKING", "QUALITY_ANALYSIS"].includes(entry.day_status))
      .map((entry) => assignmentLabel(entry, staff));
    if (!assignments.length) return { role: staff.primary_role_name || "No working days", location: "No working location this week" };
    const roles = [...new Set(assignments.map((item) => item.role).filter(Boolean))];
    const locations = [...new Set(assignments.map((item) => item.location).filter(Boolean))];
    return {
      role: roles.length === 1 ? roles[0] : "Mixed daily roles",
      location: locations.length === 1 ? locations[0] : `Mixed: ${locations.join(" · ")}`
    };
  }

  function staffRow(staff, days) {
    const assignment = weeklyAssignmentSummary(staff, days);
    const teamLeader = isTeamLeaderForWeek(staff, days);
    return `<div class="roster-row${teamLeader ? " is-team-leader" : ""}${isShiftOverride(staff) ? " is-shift-override" : ""}" data-name="${escapeHtml(staff.display_name.toLowerCase())}">
      <div class="roster-cell roster-who">
        <div class="roster-name-line"><strong>${escapeHtml(staff.display_name)}</strong><div class="roster-name-badges">${teamLeaderBadge(staff, days)}${trainingBadges(staff)}</div></div>
        <div class="roster-person-meta">${workloadBadge(staff, days)}${shiftOverrideBadge(staff)}</div>
      </div>
      <div class="roster-cell roster-assignment"><div class="roster-week-assignment-summary"><strong>${escapeHtml(assignment.role)}</strong><span title="${escapeHtml(assignment.location)}">${escapeHtml(assignment.location)}</span></div>${displaySectionControl(staff)}${shiftOverrideControl(staff)}</div>
      <div class="roster-row-days" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">${days.map((day) => dayCell(staff, day)).join("")}</div>
    </div>`;
  }

  function sectionHeaderHtml(groupCode, staffCount) {
    const meta = GROUP_META[groupCode] || { label: groupCode, subtitle: "Production area", abbr: "AR", cls: "support" };
    return `<div class="roster-section-title">
      <div class="roster-section-heading"><span class="roster-section-mark">${escapeHtml(meta.abbr)}</span><span><strong>${escapeHtml(meta.label)}</strong><small>${escapeHtml(meta.subtitle)}</small></span></div>
      <div class="roster-section-assignment-label">Daily assignment · row section</div>
      <div class="roster-section-count"><strong>${Number(staffCount)}</strong><span>${Number(staffCount) === 1 ? "staff member" : "staff members"}</span></div>
    </div>`;
  }

  function tableSubtitleHtml(table, rows, days) {
    const tableCode = table === "Table 1" ? "T1" : table === "Table 2" ? "T2" : table === "Table 3" ? "T3" : "OT";
    const tableClass = table.toLowerCase().replace(/\s+/g, "-");
    const teamLeaders = rows.filter((staff) => isTeamLeaderForWeek(staff, days)).length;
    return `<div class="roster-section-subtitle ${escapeHtml(tableClass)}">
      <div class="roster-table-heading"><span>${escapeHtml(tableCode)}</span><strong>${escapeHtml(table)}</strong><small>${rows.length} ${rows.length === 1 ? "staff member" : "staff members"}${teamLeaders ? ` · ${teamLeaders} Team Leader${teamLeaders === 1 ? "" : "s"}` : ""}</small></div>
      <div>Finish Area</div><div></div>
    </div>`;
  }

  function sortingMopForDay(day) {
    const sorting = state.staff
      .map((staff) => ({ staff, entry: state.entries.get(entryKey(staff.staff_id, day)) }))
      .filter((item) => isSortingWorkingEntry(item.entry));
    const mop = sorting.filter((item) => normalizedSortingWorkMode(item.entry) === "MOP");
    const nullModes = sorting.filter((item) => normalizedSortingWorkMode(item.entry) === null);
    const noDedicated = sorting.length > 0 && nullModes.length === sorting.length;
    const dedicated = mop.length === 1 && nullModes.length === 0;
    return {
      sorting,
      mop,
      nullModes,
      noDedicated,
      dedicated,
      selected: dedicated ? mop[0].staff : null
    };
  }

  function sortingMopIssue() {
    for (const day of visibleDays()) {
      const info = sortingMopForDay(day);
      if (!info.sorting.length) continue;
      if (!info.dedicated && !info.noDedicated) {
        return `Choose the MOP coverage for Sorting on ${formatDate(day)}: select one dedicated MOP staff member or choose No dedicated MOP.`;
      }
    }
    return "";
  }

  function setSortingMopDecision(day, value) {
    const info = sortingMopForDay(day);
    if (!info.sorting.length) return;

    if (value === "NO_DEDICATED_MOP") {
      info.sorting.forEach(({ staff, entry }) => {
        state.entries.set(entryKey(staff.staff_id, day), { ...entry, sorting_work_mode: null });
      });
      setDirty(true);
      renderGrid();
      setMessage(`${formatDate(day)} · Sorting: No dedicated MOP selected.`, "success");
      return;
    }

    const selected = info.sorting.find(({ staff }) => staff.staff_id === value);
    if (!selected) return;

    info.sorting.forEach(({ staff, entry }) => {
      state.entries.set(entryKey(staff.staff_id, day), {
        ...entry,
        sorting_work_mode: staff.staff_id === value ? "MOP" : "CLOTHES"
      });
    });
    setDirty(true);
    renderGrid();
    setMessage(`${formatDate(day)} · ${selected.staff.display_name} selected as dedicated MOP.`, "success");
  }

  function sortingMopSummaryHtml(days) {
    return `<div class="roster-mop-summary-row">
      <div class="roster-cell roster-mop-summary-title">
        <strong>MOP coverage</strong>
        <span>Decision required each Working day</span>
      </div>
      <div class="roster-cell roster-mop-summary-help">Choose a dedicated MOP person or No dedicated MOP</div>
      <div class="roster-row-days" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">
        ${days.map((day) => {
          const info = sortingMopForDay(day);
          if (!info.sorting.length) return '<div class="roster-mop-summary-day none">—</div>';
          if (!isEditable()) {
            if (info.selected) return `<div class="roster-mop-summary-day ok"><strong>MOP</strong><span>${escapeHtml(info.selected.display_name)}</span></div>`;
            if (info.noDedicated) return '<div class="roster-mop-summary-day shared"><strong>SHARED</strong><span>No dedicated MOP</span></div>';
            return '<div class="roster-mop-summary-day missing"><strong>UNSET</strong><span>MOP decision</span></div>';
          }
          const current = info.selected ? info.selected.staff_id : info.noDedicated ? "NO_DEDICATED_MOP" : "";
          return `<div class="roster-mop-summary-day ${info.selected ? "ok" : info.noDedicated ? "shared" : "missing"}">
            <select data-sorting-mop-decision="${escapeHtml(day)}" aria-label="Sorting MOP coverage for ${escapeHtml(formatDate(day))}">
              <option value=""${current === "" ? " selected" : ""}>Choose…</option>
              <option value="NO_DEDICATED_MOP"${current === "NO_DEDICATED_MOP" ? " selected" : ""}>No dedicated MOP</option>
              ${info.sorting.map(({ staff }) => `<option value="${escapeHtml(staff.staff_id)}"${current === staff.staff_id ? " selected" : ""}>MOP · ${escapeHtml(staff.display_name)}</option>`).join("")}
            </select>
          </div>`;
        }).join("")}
      </div>
    </div>`;
  }

  function sectionHtml(groupCode, staffRows, days) {
    if (!staffRows.length) return "";
    const meta = GROUP_META[groupCode] || GROUP_META.SUPPORT_ROLE;
    if (groupCode !== "GENERAL_OPERATIVE") {
      const rows = [...staffRows].sort((a, b) => a.display_name.localeCompare(b.display_name));
      const mopSummary = groupCode === "SORTING_AREA" ? sortingMopSummaryHtml(days) : "";
      return `<section class="roster-section roster-section-${escapeHtml(meta.cls)}">${sectionHeaderHtml(groupCode, rows.length)}${mopSummary}${rows.map((staff) => staffRow(staff, days)).join("")}</section>`;
    }
    const tables = ["Table 1", "Table 2", "Table 3", "Other"];
    return `<section class="roster-section roster-section-${escapeHtml(meta.cls)}">${sectionHeaderHtml(groupCode, staffRows.length)}${tables.map((table) => {
      const rows = staffRows.filter((staff) => stationTable(staff) === table).sort((a, b) => {
        const ar = isTeamLeaderForWeek(a, days) ? 0 : 1;
        const br = isTeamLeaderForWeek(b, days) ? 0 : 1;
        return ar - br || a.display_name.localeCompare(b.display_name);
      });
      return rows.length ? `${tableSubtitleHtml(table, rows, days)}${rows.map((staff) => staffRow(staff, days)).join("")}` : "";
    }).join("")}</section>`;
  }

  function finishTarget() {
    const targets = Array.isArray(state.operationalSettings?.targets) ? state.operationalSettings.targets : [];
    return targets.find((target) => target.target_code === "FINISH_TABLE_KG_PER_STAFF_HOUR") || null;
  }

  function isConfiguredBankHoliday(workDate) {
    return (state.operationalSettings?.bank_holidays || []).some((item) => item.work_date === workDate && item.use_saturday_profile !== false);
  }

  function workProfileForDay(workDate) {
    const profiles = Array.isArray(state.operationalSettings?.work_profiles) ? state.operationalSettings.work_profiles : [];
    const shiftCode = String(state.data?.shift?.shift_code || elements.shift.value || "").toUpperCase();
    const isoDay = new Date(`${workDate}T00:00:00Z`).getUTCDay() || 7;
    if (isoDay === 1 && isConfiguredBankHoliday(workDate)) {
      return profiles.find((profile) => profile.shift_code === shiftCode && profile.applies_to_bank_holiday) || null;
    }
    return profiles.find((profile) => profile.shift_code === shiftCode && Array.isArray(profile.iso_days) && profile.iso_days.map(Number).includes(isoDay)) || null;
  }

  function countsForFinishCapacity(entry, stationCode) {
    if (!entry || entry.day_status !== "WORKING" || entry.station_code !== stationCode) return false;
    if (entry.assignment_type === "COVER" && entry.operational_role_code === "SUPERVISOR") return false;
    return true;
  }

  function capacitySimulationPercent() {
    const value = Math.round(Number(state.capacitySimulationPercent || 100));
    return Math.max(50, Math.min(120, Number.isFinite(value) ? value : 100));
  }

  function finishCapacityForDay(workDate, stationCode = null) {
    const target = finishTarget();
    const profile = workProfileForDay(workDate);
    if (!target || !profile) return { staff: 0, baseKg: 0, kg: 0, netMinutes: 0, profile: null, target: Number(target?.target_value || 0), simulationPercent: capacitySimulationPercent() };
    const stationCodes = stationCode ? [stationCode] : ["FINISH_TABLE_1", "FINISH_TABLE_2", "FINISH_TABLE_3"];
    let staffCount = 0;
    state.staff.forEach((staff) => {
      const entry = state.entries.get(entryKey(staff.staff_id, workDate));
      if (stationCodes.some((code) => countsForFinishCapacity(entry, code))) staffCount += 1;
    });
    const targetValue = Number(target.target_value || 0);
    const netMinutes = Number(profile.net_minutes || 0);
    const simulationPercent = capacitySimulationPercent();
    const baseKg = staffCount * targetValue * (netMinutes / 60);
    return {
      staff: staffCount,
      baseKg,
      kg: baseKg * (simulationPercent / 100),
      netMinutes,
      profile,
      target: targetValue,
      simulationPercent,
    };
  }

  function formatCapacityKg(value) {
    return new Intl.NumberFormat("en-IE", { maximumFractionDigits: 0 }).format(Math.round(Number(value || 0)));
  }

  function formatNetHours(minutes) {
    const hours = Number(minutes || 0) / 60;
    return Number.isInteger(hours) ? `${hours}h` : `${hours.toFixed(2).replace(/0$/, "")}h`;
  }

  function capacityDayCell(workDate, stationCode = null) {
    const value = finishCapacityForDay(workDate, stationCode);
    if (!value.profile) return `<div class="roster-capacity-day is-unavailable"><strong>—</strong><span>No work profile</span></div>`;
    const bank = isConfiguredBankHoliday(workDate);
    const percent = value.simulationPercent;
    const formula = `${value.staff} staff × ${value.target.toFixed(1)} kg/hr × ${percent}% × ${formatNetHours(value.netMinutes)} = ${formatCapacityKg(value.kg)} kg. 100% target capacity: ${formatCapacityKg(value.baseKg)} kg.`;
    const meta = `${percent === 100 ? "" : `${percent}% · `}${value.staff} staff · ${formatNetHours(value.netMinutes)}${bank ? " · BH" : ""}`;
    return `<div class="roster-capacity-day${bank ? " is-bank-holiday" : ""}" data-capacity-day data-base-kg="${value.baseKg.toFixed(6)}" data-capacity-staff="${value.staff}" data-capacity-net-minutes="${value.netMinutes}" data-capacity-target="${value.target.toFixed(6)}" data-capacity-bank="${bank ? "1" : "0"}" title="${escapeHtml(formula)}"><strong data-capacity-kg>${formatCapacityKg(value.kg)} kg</strong><span data-capacity-meta>${escapeHtml(meta)}</span></div>`;
  }

  function updateCapacitySimulationDom() {
    const target = finishTarget();
    if (!target) return;
    const percent = capacitySimulationPercent();
    state.capacitySimulationPercent = percent;
    document.querySelectorAll("[data-capacity-simulation-range], [data-capacity-simulation-input]").forEach((input) => { input.value = String(percent); });
    document.querySelectorAll("[data-capacity-simulation-percent]").forEach((node) => { node.textContent = `${percent}%`; });
    document.querySelectorAll("[data-capacity-effective-target]").forEach((node) => { node.textContent = `${(Number(target.target_value || 0) * percent / 100).toFixed(2)} kg / staff hr`; });
    document.querySelectorAll("[data-capacity-day]").forEach((cell) => {
      const baseKg = Number(cell.dataset.baseKg || 0);
      const staff = Number(cell.dataset.capacityStaff || 0);
      const netMinutes = Number(cell.dataset.capacityNetMinutes || 0);
      const targetValue = Number(cell.dataset.capacityTarget || target.target_value || 0);
      const bank = cell.dataset.capacityBank === "1";
      const scenarioKg = baseKg * percent / 100;
      const kgNode = cell.querySelector("[data-capacity-kg]");
      const metaNode = cell.querySelector("[data-capacity-meta]");
      if (kgNode) kgNode.textContent = `${formatCapacityKg(scenarioKg)} kg`;
      if (metaNode) metaNode.textContent = `${percent === 100 ? "" : `${percent}% · `}${staff} staff · ${formatNetHours(netMinutes)}${bank ? " · BH" : ""}`;
      cell.title = `${staff} staff × ${targetValue.toFixed(1)} kg/hr × ${percent}% × ${formatNetHours(netMinutes)} = ${formatCapacityKg(scenarioKg)} kg. 100% target capacity: ${formatCapacityKg(baseKg)} kg.`;
    });
  }

  function capacityPanelHtml(days) {
    const target = finishTarget();
    if (!target) return "";
    const percent = capacitySimulationPercent();
    const effectiveTarget = Number(target.target_value || 0) * percent / 100;
    const rows = [
      ["FINISH_TABLE_1", "T1", "Table 1"],
      ["FINISH_TABLE_2", "T2", "Table 2"],
      ["FINISH_TABLE_3", "T3", "Table 3"],
    ];
    const body = state.capacityCollapsed ? "" : rows.map(([code, short, label]) => `<div class="roster-capacity-row"><div class="roster-capacity-name"><span>${short}</span><strong>${label}</strong></div><div class="roster-capacity-rule">Scenario capacity</div><div class="roster-row-days" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">${days.map((day) => capacityDayCell(day, code)).join("")}</div></div>`).join("") + `<div class="roster-capacity-row is-total"><div class="roster-capacity-name"><span>Σ</span><strong>Finish total</strong></div><div class="roster-capacity-rule">Tables 1 + 2 + 3</div><div class="roster-row-days" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">${days.map((day) => capacityDayCell(day)).join("")}</div></div>`;
    return `<section class="roster-capacity-block"><div class="roster-capacity-header"><div class="roster-capacity-heading"><strong>Finish capacity</strong><span>What-if simulation only. The official production target is never changed here.</span></div><div class="roster-capacity-target"><small>Official target</small><strong>${Number(target.target_value).toFixed(1)} kg / staff hr</strong></div><div class="roster-capacity-simulation"><div class="roster-capacity-simulation-top"><span><small>Simulation</small><strong data-capacity-simulation-percent>${percent}%</strong></span><span class="roster-capacity-effective" data-capacity-effective-target>${effectiveTarget.toFixed(2)} kg / staff hr</span></div><div class="roster-capacity-simulation-controls"><input type="range" min="50" max="120" step="1" value="${percent}" data-capacity-simulation-range aria-label="Finish capacity simulation percentage"><label><input type="number" min="50" max="120" step="1" value="${percent}" data-capacity-simulation-input aria-label="Finish capacity simulation percentage"><span>%</span></label><button type="button" data-capacity-simulation-reset title="Reset simulation to 100 percent">100%</button></div></div><button class="roster-capacity-toggle" type="button" data-capacity-toggle aria-expanded="${String(!state.capacityCollapsed)}">${state.capacityCollapsed ? "Show" : "Hide"}</button></div>${body}</section>`;
  }

  function renderGrid() {
    if (!state.data) return;
    const days = visibleDays();
    const query = elements.search.value.trim().toLowerCase();
    const visibleStaff = state.staff.filter((staff) => !query || staff.display_name.toLowerCase().includes(query) || String(staff.employee_code || "").toLowerCase().includes(query));
    if (!visibleStaff.length) {
      elements.grid.innerHTML = '<div class="roster-empty">No production staff match this view.</div>';
      renderControls(); return;
    }
    const grouped = Object.fromEntries(GROUPS.map((group) => [group, []]));
    visibleStaff.forEach((staff) => (grouped[roleGroup(staff)] ||= []).push(staff));
    const totals = days.map((day) => visibleStaff.filter((staff) => {
      const entry = state.entries.get(entryKey(staff.staff_id, day));
      return countsAsPlannedDay(entry);
    }).length);
    elements.grid.innerHTML = `<div class="roster-grid-scroll"><div class="roster-grid">
      <div class="roster-grid-header"><div></div><div>Assignment / row</div><div class="roster-day-grid" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">${days.map((day) => `<div class="roster-day-header"><strong>${new Intl.DateTimeFormat("en-IE", { weekday: "short", timeZone: "UTC" }).format(new Date(`${day}T00:00:00Z`))}</strong><span>${formatDate(day, { year: false })}</span></div>`).join("")}</div></div>
      ${GROUPS.map((group) => sectionHtml(group, grouped[group] || [], days)).join("")}
      <div class="roster-total-row"><div class="roster-cell">Planned per day</div><div class="roster-cell">W · C · QA · T</div><div class="roster-row-days" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">${totals.map((total) => `<div class="roster-day-cell"><span class="roster-total-value">${total}</span></div>`).join("")}</div></div>
      ${capacityPanelHtml(days)}
    </div></div>`;
    renderControls();
  }

  function availableStaffPool() {
    const included = new Set(state.staff.map((staff) => staff.staff_id));
    return state.staffPool.filter((staff) => staff.currently_eligible !== false && !included.has(staff.staff_id));
  }

  function staffPickerCandidateHtml(staff) {
    const override = staff.default_shift_code !== state.data?.shift?.shift_code;
    const shiftLabel = staff.default_shift_name || staff.default_shift_code || "No default shift";
    return `<button class="roster-staff-picker-option${override ? " shift-override" : ""}" type="button" data-select-staff-pool="${escapeHtml(staff.staff_id)}">
      <span class="roster-staff-picker-option-main"><strong>${escapeHtml(staff.display_name)}</strong><small>${escapeHtml(staff.primary_role_name || "Production staff")} · ${escapeHtml(shiftLabel)}</small></span>
      <div class="roster-staff-picker-option-badges">${trainingBadges(staff)}${override ? `<span class="roster-picker-shift-badge">${escapeHtml(shiftLabel)} → ${escapeHtml(state.data.shift.shift_name)}</span>` : ""}</div>
      <span class="roster-staff-picker-option-action">Choose days</span>
    </button>`;
  }

  function renderStaffPickerList() {
    const query = elements.staffPickerSearch.value.trim().toLowerCase();
    const currentShift = String(state.data?.shift?.shift_code || "");
    const includeOtherShift = Boolean(elements.staffPickerIncludeOtherShift?.checked);
    const candidates = availableStaffPool()
      .filter((staff) => includeOtherShift || !staff.default_shift_code || staff.default_shift_code === currentShift)
      .filter((staff) => !query
        || staff.display_name.toLowerCase().includes(query)
        || String(staff.employee_code || "").toLowerCase().includes(query)
        || String(staff.default_shift_name || "").toLowerCase().includes(query));
    elements.staffPickerList.innerHTML = candidates.length
      ? candidates.map(staffPickerCandidateHtml).join("")
      : '<div class="roster-empty roster-staff-picker-empty">No eligible staff are available to add.</div>';
  }

  function renderStaffPickerSelection(staff) {
    const days = visibleDays();
    const from = staff.default_shift_name || staff.default_shift_code || "No default shift";
    const to = state.data?.shift?.shift_name || state.data?.shift?.shift_code || "selected shift";
    state.staffPickerSelectedId = staff.staff_id;
    elements.staffPickerList.classList.add("hidden");
    elements.staffPickerSelection.classList.remove("hidden");
    const joinedText = staff.joined_on ? ` · Joined ${formatDate(staff.joined_on)}` : "";
    elements.staffPickerSelected.innerHTML = `<div><strong>${escapeHtml(staff.display_name)}</strong><span>${escapeHtml(staff.primary_role_name || "Production staff")}${escapeHtml(joinedText)}</span></div><div class="roster-staff-picker-selected-badges">${trainingBadges(staff)}<span class="roster-picker-shift-badge${staff.default_shift_code === state.data.shift.shift_code ? " same-shift" : ""}">${escapeHtml(from)} → ${escapeHtml(to)}</span></div>`;
    elements.staffPickerDays.innerHTML = days.map((day) => {
      const available = staffAvailableOnDate(staff, day);
      return `<label class="roster-staff-picker-day${available ? "" : " is-disabled"}"><input type="checkbox" value="${escapeHtml(day)}"${available ? " checked" : " disabled"}><span><strong>${new Intl.DateTimeFormat("en-IE", { weekday: "short", timeZone: "UTC" }).format(new Date(`${day}T00:00:00Z`))}</strong><small>${available ? formatDate(day, { year: false }) : escapeHtml(staffUnavailableLabel(staff, day))}</small></span></label>`;
    }).join("");
    const override = staff.default_shift_code && staff.default_shift_code !== state.data.shift.shift_code;
    elements.staffPickerOverrideWarning.classList.toggle("hidden", !override);
    elements.staffPickerOverrideConfirm.checked = !override;
    elements.staffPickerAdd.disabled = override;
    elements.staffPickerMessage.textContent = override
      ? "This is a temporary shift override. Confirm that you reviewed the other shift before adding."
      : "";
  }

  function resetStaffPickerSelection() {
    state.staffPickerSelectedId = "";
    elements.staffPickerSelection.classList.add("hidden");
    elements.staffPickerList.classList.remove("hidden");
    elements.staffPickerOverrideWarning.classList.add("hidden");
    elements.staffPickerOverrideConfirm.checked = false;
    elements.staffPickerAdd.disabled = false;
    elements.staffPickerMessage.textContent = "";
    renderStaffPickerList();
  }

  function openStaffPicker() {
    if (!isEditable()) return;
    state.staffPickerSelectedId = "";
    elements.staffPickerSearch.value = "";
    elements.staffPickerIncludeOtherShift.checked = false;
    elements.staffPickerOverrideWarning.classList.add("hidden");
    elements.staffPickerOverrideConfirm.checked = false;
    elements.staffPickerAdd.disabled = false;
    elements.staffPickerTitle.textContent = `Add staff to ${state.data.shift.shift_name}`;
    elements.staffPickerSubtitle.textContent = "Same-shift staff are shown by default. Use Temporary shift override only when you intentionally move selected days from the other shift.";
    elements.staffPickerSelection.classList.add("hidden");
    elements.staffPickerList.classList.remove("hidden");
    elements.staffPickerMessage.textContent = "";
    renderStaffPickerList();
    elements.staffPickerModal.classList.remove("hidden");
    elements.staffPickerSearch.focus();
  }

  function closeStaffPicker() {
    elements.staffPickerModal.classList.add("hidden");
    state.staffPickerSelectedId = "";
  }

  function addSelectedStaffToRoster() {
    if (!isEditable() || !state.staffPickerSelectedId) return;
    const staff = state.staffPool.find((item) => item.staff_id === state.staffPickerSelectedId);
    if (!staff || state.staff.some((item) => item.staff_id === staff.staff_id)) return;
    const override = Boolean(staff.default_shift_code && staff.default_shift_code !== state.data.shift.shift_code);
    if (override && !elements.staffPickerOverrideConfirm.checked) {
      elements.staffPickerMessage.textContent = "Confirm that you reviewed the other shift before adding this temporary assignment.";
      return;
    }
    const selectedDays = new Set(
      [...elements.staffPickerDays.querySelectorAll('input[type="checkbox"]:checked:not(:disabled)')]
        .map((input) => input.value)
        .filter((day) => staffAvailableOnDate(staff, day))
    );
    if (!selectedDays.size) {
      elements.staffPickerMessage.textContent = "Select at least one day for this shift.";
      return;
    }

    const includedStaff = { ...staff, included_in_roster: true, shift_override_authorized: override, shift_override_source: override ? "EXPLICIT_UI" : null };
    state.staff.push(includedStaff);
    state.layouts.set(includedStaff.staff_id, defaultDisplaySection(includedStaff));
    visibleDays().forEach((day) => {
      const entry = defaultEntry(includedStaff, day);
      if (!selectedDays.has(day)) {
        entry.day_status = "OFF";
        entry.assignment_type = "BASE";
        entry.operational_role_code = null;
        entry.area_code = null;
        entry.station_code = null;
      }
      state.entries.set(entryKey(includedStaff.staff_id, day), entry);
    });
    setDirty(true);
    closeStaffPicker();
    renderGrid();
    const overrideText = isShiftOverride(includedStaff) ? ` Temporary ${includedStaff.default_shift_name || includedStaff.default_shift_code} → ${state.data.shift.shift_name} assignment.` : "";
    setMessage(`${includedStaff.display_name} added for ${selectedDays.size} ${selectedDays.size === 1 ? "day" : "days"}.${overrideText}`, "success");
  }

  function removeShiftOverride(staffId) {
    if (!isEditable()) return;
    const staff = state.staff.find((item) => item.staff_id === staffId);
    if (!staff || !isShiftOverride(staff)) return;
    if (!window.confirm(`Remove ${staff.display_name} from the ${state.data.shift.shift_name} roster? Staff Master will not be changed.`)) return;
    state.staff = state.staff.filter((item) => item.staff_id !== staffId);
    state.layouts.delete(staffId);
    [...state.entries.keys()].filter((key) => key.startsWith(`${staffId}|`)).forEach((key) => state.entries.delete(key));
    setDirty(true);
    renderGrid();
    setMessage(`${staff.display_name} removed from this temporary shift roster.`, "success");
  }

  async function loadRoster(options = {}) {
    if (state.dirty && !options.force && !window.confirm("Discard unsaved roster changes?")) {
      restoreLoadedRosterContextControls();
      renderContext();
      renderControls();
      return false;
    }

    const requested = selectedRosterContext();
    state.loading = true;
    state.historyVersionId = options.versionId || null;
    state.suspiciousShiftDraft = null;
    renderControls();
    setMessage();
    elements.grid.innerHTML = '<div class="roster-loading"><span></span><p>Loading Production Roster…</p></div>';

    try {
      const weekStart = requested.weekStart;
      const shiftCode = requested.shiftCode;
      const [data, poolData, operationalSettings] = await Promise.all([
        rpc("get_production_roster_week", { p_week_start: weekStart, p_shift_code: shiftCode, p_roster_version_id: state.historyVersionId }),
        rpc("get_production_roster_staff_pool", { p_week_start: weekStart, p_shift_code: shiftCode, p_roster_version_id: state.historyVersionId }),
        rpc("get_production_roster_operational_settings", { p_from_date: weekStart, p_to_date: addDays(weekStart, 6) })
      ]);
      state.data = data || {};
      if ((state.accessProfile?.permissions||[]).length) state.data.can_manage=state.canEditRoster;
      state.operationalSettings = operationalSettings || { targets: [], work_profiles: [], bank_holidays: [] };
      const [approvedLeave, pendingLeave] = (!state.historyVersionId && state.data.can_manage)
        ? await Promise.all([
          rpc("get_production_roster_approved_leave", { p_week_start: weekStart, p_shift_code: shiftCode }),
          rpc("get_production_roster_pending_leave", { p_week_start: weekStart, p_shift_code: shiftCode })
        ])
        : [[], []];
      state.staffPool = Array.isArray(poolData?.staff) ? poolData.staff : [];
      const poolById = new Map(state.staffPool.map((staff) => [staff.staff_id, staff]));
      state.staff = (Array.isArray(data.staff) ? data.staff : []).map((staff) => {
        const poolStaff = poolById.get(staff.staff_id);
        return poolStaff ? {
          ...staff,
          default_shift_code: poolStaff.default_shift_code,
          default_shift_name: poolStaff.default_shift_name,
          shift_override_authorized: staff.shift_override_authorized === true,
          shift_override_source: staff.shift_override_source || null,
          cover_role_codes: poolStaff.cover_role_codes || staff.cover_role_codes || [],
          joined_on: poolStaff.joined_on || staff.joined_on || null,
          deactivated_on: poolStaff.deactivated_on || null,
          currently_eligible: poolStaff.currently_eligible,
          master_active: poolStaff.master_active,
          master_roster_eligible: poolStaff.master_roster_eligible,
          master_production_staff: poolStaff.master_production_staff
        } : staff;
      });

      state.loadedWeekStart = weekStart;
      state.loadedShiftCode = shiftCode;
      elements.week.value = isoWeekValue(weekStart);
      elements.shift.value = shiftCode;
      state.suspiciousShiftDraft = suspiciousShiftDraftSummary();

      elements.sunday.value = data.document?.include_sunday ? "1" : "0";
      elements.note.value = data.document?.week_note || "";
      rebuildEntries();
      const employmentRepair = reconcileStaffMasterAvailability();
      const joinedStaffAdded = includeJoinedStaffInEditableRoster();
      const assignmentRepairs = isEditable() ? syncAllBaseAssignmentsToSections() : 0;
      const approvedLeaveChanged = applyApprovedLeaveOverlay(approvedLeave);
      applyPendingLeaveOverlay(pendingLeave);
      setDirty(approvedLeaveChanged || assignmentRepairs > 0 || joinedStaffAdded > 0 || employmentRepair.removed.length > 0 || employmentRepair.adjustedDays > 0); renderContext(); renderGrid();
      const unverifiedCrossShift = crossShiftStaffIssues();
      if (state.suspiciousShiftDraft) {
        const warning = state.suspiciousShiftDraft;
        setMessage(
          `Safety block: this saved ${warning.shiftName} draft contains ${warning.crossShiftCount} staff from another default shift and no ${warning.shiftName} default-shift staff. Save and Publish are blocked. Use Discard Draft to return to the last published ${warning.shiftName} roster, or review the draft before taking any recovery action.`,
          "error"
        );
      } else if (unverifiedCrossShift.length) {
        const names = unverifiedCrossShift.slice(0, 5).map((staff) => staff.display_name).join(", ");
        setMessage(
          `Shift integrity review: ${unverifiedCrossShift.length} ${unverifiedCrossShift.length === 1 ? "staff member is" : "staff members are"} in this ${state.data.shift.shift_name} roster but Staff Master assigns them to the other shift: ${names}${unverifiedCrossShift.length > 5 ? "…" : ""}. They are not confirmed temporary overrides. Remove them, or re-add explicitly through Add staff → Temporary shift override before the next Save/Publish.`,
          "error"
        );
      } else if (employmentRepair.removed.length > 0 && isEditable()) {
        const names = employmentRepair.removed.map((staff) => staff.display_name).join(", ");
        setMessage(`${employmentRepair.removed.length} staff member${employmentRepair.removed.length === 1 ? "" : "s"} removed from this planner because Staff Master employment dates do not overlap the visible week: ${names}. Published history was not changed. Save a new roster version to make the correction official.`, "error");
      } else if (employmentRepair.adjustedDays > 0 && isEditable()) {
        setMessage(`${employmentRepair.adjustedDays} roster day${employmentRepair.adjustedDays === 1 ? "" : "s"} changed to Off because they fall outside Staff Master employment dates. Review and Save.`, "error");
      } else if (approvedLeaveChanged && isEditable()) {
        setMessage("Approved Holiday / Day Off requests were applied to this planner. Save and publish the new roster version when ready.", "success");
      } else if (joinedStaffAdded > 0 && isEditable()) {
        setMessage(`${joinedStaffAdded} newly joined staff member${joinedStaffAdded === 1 ? "" : "s"} added to the planner from the Staff Master Joined date. Review and Save the roster.`, "success");
      } else if (assignmentRepairs > 0 && isEditable()) {
        setMessage(`${assignmentRepairs} daily base assignment${assignmentRepairs === 1 ? "" : "s"} were aligned with their weekly roster section. Review and Save the roster.`, "success");
      }
      if (state.data.can_manage) await refreshLeaveRequestBadge();
      return true;
    } catch (error) {
      console.error(error);
      restoreLoadedRosterContextControls();
      elements.grid.innerHTML = `<div class="roster-empty">${escapeHtml(friendlyError(error))}</div>`;
      setMessage(friendlyError(error), "error");
      return false;
    } finally {
      state.loading = false;
      renderControls();
    }
  }

  function statusButtonHtml(code, selectedCode, compact = false, disabled = false) {
    const meta = STATUS[code];
    const selected = selectedCode === code;
    const wideClass = compact && code === "QUALITY_ANALYSIS" ? " roster-status-option-wide" : "";
    const disabledHint = disabled && code === "COVER" ? ' title="This staff member has no authorised COVER roles"' : "";
    return `<button class="roster-status-option ${meta.cls}${selected ? " selected" : ""}${wideClass}" type="button" role="radio" aria-checked="${selected}" data-status-choice="${code}"${disabled ? ' disabled aria-disabled="true"' : ""}${disabledHint}><span>${meta.abbr}</span><strong>${escapeHtml(meta.label)}</strong>${compact ? "" : `<small>${code === "COVER" ? "Choose an authorised cover role" : code === "WORKING" ? "Normal planned assignment" : code === "QUALITY_ANALYSIS" ? "Working in quality analysis" : "No work location required"}</small>`}</button>`;
  }

  function renderDetailedStatusButtons() {
    const [staffId] = state.editingKey.split("|");
    const staff = state.staff.find((item) => item.staff_id === staffId);
    elements.dayStatusButtons.innerHTML = STATUS_ORDER.map((code) => statusButtonHtml(code, elements.dayStatus.value, false, code === "COVER" && !(staff?.cover_role_codes || []).length)).join("");
  }

  function populateDayModal(staff, entry, statusOverride = "") {
    const statusCode = statusOverride || virtualStatus(entry);
    elements.dayStatus.innerHTML = STATUS_ORDER.map((code) => `<option value="${code}"${statusCode === code ? " selected" : ""}>${escapeHtml(STATUS[code].label)}</option>`).join("");
    elements.assignmentType.value = statusCode === "COVER" ? "COVER" : "BASE";
    elements.dayNote.value = entry.notes || "";
    renderDetailedStatusButtons();
    populateDayFields(staff, entry);
  }

  function renderCoverRoleChoices(staff, selectedRole = "") {
    const roleCodes = staff.cover_role_codes || [];
    elements.coverRoleButtons.innerHTML = roleCodes.map((code) => {
      const referenceRole = (state.reference.operational_roles || []).find((item) => item.role_code === code);
      const meta = COVER_ROLE_META[code] || { label: referenceRole?.role_name || code, abbr: code.slice(0, 2), hint: "Authorised COVER function" };
      const selected = selectedRole === code;
      return `<button class="roster-cover-role-option${selected ? " selected" : ""}" type="button" role="radio" aria-checked="${selected}" data-cover-role="${escapeHtml(code)}"><span>${escapeHtml(meta.abbr)}</span><strong>${escapeHtml(referenceRole?.role_name || meta.label)}</strong><small>${escapeHtml(meta.hint)}</small></button>`;
    }).join("");
    elements.coverRoleHelp.textContent = roleCodes.length > 1
      ? "Select the COVER function for this day. Only Staff Master authorised functions are shown."
      : "This is the only COVER function authorised for this staff member.";
  }

  function renderSortingWorkModeField(entry = {}) {
    const statusCode = elements.dayStatus.value;
    const working = ["WORKING", "COVER"].includes(statusCode);
    const sorting = working && (String(elements.area.value || entry.area_code || "").toUpperCase() === "SORTING" || String(elements.role.value || entry.operational_role_code || "").toUpperCase() === "SORTING_AREA");
    elements.sortingWorkModeField.classList.toggle("hidden", !sorting);
    if (!sorting) return;
    elements.sortingWorkMode.value = normalizedSortingWorkMode(entry) || "CLOTHES";
    [...elements.sortingWorkModeButtons.querySelectorAll("[data-sorting-work-mode]")].forEach((button) => {
      const selected = button.dataset.sortingWorkMode === elements.sortingWorkMode.value;
      button.classList.toggle("selected", selected);
      button.setAttribute("aria-checked", String(selected));
    });
  }

  function setModalSortingWorkMode(mode) {
    const value = mode === "MOP" ? "MOP" : "CLOTHES";
    elements.sortingWorkMode.value = value;
    [...elements.sortingWorkModeButtons.querySelectorAll("[data-sorting-work-mode]")].forEach((button) => {
      const selected = button.dataset.sortingWorkMode === value;
      button.classList.toggle("selected", selected);
      button.setAttribute("aria-checked", String(selected));
    });
  }

  function populateDayFields(staff, entry = {}) {
    const statusCode = elements.dayStatus.value;
    const working = ["WORKING", "COVER", "QUALITY_ANALYSIS"].includes(statusCode);
    elements.sortingWorkModeField.classList.add("hidden");
    const cover = statusCode === "COVER";
    elements.assignmentType.value = cover ? "COVER" : "BASE";
    elements.assignmentTypeField.classList.add("hidden");
    const mixedBase = working && !cover && supportsMixedDailyAssignments(staff);
    const tableOverride = working && !cover && supportsTableDailyOverride(staff);
    elements.coverRoleField.classList.toggle("hidden", !cover);
    elements.roleField.classList.toggle("hidden", !mixedBase);
    elements.areaField.classList.toggle("hidden", !working || (!cover && !mixedBase));
    elements.stationField.classList.toggle("hidden", !working || (!cover && !mixedBase && !tableOverride));
    if (!working) {
      elements.coverRoleButtons.innerHTML = "";
      return;
    }

    if (tableOverride) {
      const base = baseAssignmentForDailyEdit(staff, entry);
      const role = (state.reference.operational_roles || []).find((item) => item.role_code === base.operational_role_code);
      const area = (state.reference.areas || []).find((item) => item.area_code === "FINISH");
      elements.role.innerHTML = `<option value="${escapeHtml(base.operational_role_code)}" selected>${escapeHtml(role?.role_name || base.operational_role_code)}</option>`;
      elements.area.innerHTML = `<option value="FINISH" selected>${escapeHtml(area?.area_name || "Finish Area")}</option>`;
      populateStations(base.station_code, { finishTablesOnly: true });
      renderSortingWorkModeField(entry);
      return;
    }

    const roleCodes = cover ? (staff.cover_role_codes || []) : (state.reference.operational_roles || []).map((item) => item.role_code);
    let selectedRole = cover ? (entry.assignment_type === "COVER" ? entry.operational_role_code : roleCodes[0]) : (entry.operational_role_code || staff.primary_role_code);
    if (!roleCodes.includes(selectedRole)) selectedRole = roleCodes[0] || "";
    elements.role.innerHTML = roleCodes.map((code) => {
      const role = state.reference.operational_roles.find((item) => item.role_code === code);
      return `<option value="${escapeHtml(code)}"${selectedRole === code ? " selected" : ""}>${escapeHtml(role?.role_name || code)}</option>`;
    }).join("");
    if (cover) renderCoverRoleChoices(staff, selectedRole);
    const selectedArea = entry.area_code || staff.default_area_code || "FINISH";
    elements.area.innerHTML = (state.reference.areas || []).map((area) => `<option value="${escapeHtml(area.area_code)}"${selectedArea === area.area_code ? " selected" : ""}>${escapeHtml(area.area_name)}</option>`).join("");
    populateStations(entry.station_code || staff.default_station_code || "");
    renderSortingWorkModeField(entry);
  }

  function populateStations(selected = "", options = {}) {
    const area = (state.reference.areas || []).find((item) => item.area_code === elements.area.value);
    let stations = (state.reference.stations || []).filter((item) => !area || item.area_id === area.area_id);
    if (options.finishTablesOnly) stations = stations.filter((item) => isFinishTableStation(item.station_code));
    elements.station.innerHTML = `${options.finishTablesOnly ? "" : '<option value="">No station</option>'}${stations.map((station) => `<option value="${escapeHtml(station.station_code)}"${selected === station.station_code ? " selected" : ""}>${escapeHtml(station.station_name)}</option>`).join("")}`;
  }

  function closeQuickStatusMenu() {
    elements.quickMenu.classList.add("hidden");
    state.quickKey = "";
    document.querySelectorAll("[data-edit-day][aria-expanded='true']").forEach((button) => button.setAttribute("aria-expanded", "false"));
  }

  function positionQuickStatusMenu(anchor) {
    const margin = 10;
    const rect = anchor.getBoundingClientRect();
    const menuRect = elements.quickMenu.getBoundingClientRect();
    let left = rect.left + (rect.width / 2) - (menuRect.width / 2);
    left = Math.max(margin, Math.min(left, window.innerWidth - menuRect.width - margin));
    let top = rect.bottom + 8;
    if (top + menuRect.height > window.innerHeight - margin) top = rect.top - menuRect.height - 8;
    top = Math.max(margin, top);
    elements.quickMenu.style.left = `${Math.round(left)}px`;
    elements.quickMenu.style.top = `${Math.round(top)}px`;
  }

  function openQuickStatusMenu(staffId, workDate, anchor) {
    if (!isEditable()) return;
    closeQuickStatusMenu();
    const staff = state.staff.find((item) => item.staff_id === staffId);
    const entry = state.entries.get(entryKey(staffId, workDate));
    if (!staff || !entry) return;
    state.quickKey = entryKey(staffId, workDate);
    elements.quickTitle.textContent = staff.display_name;
    elements.quickSubtitle.textContent = formatDate(workDate);
    const currentStatus = virtualStatus(entry);
    elements.quickOptions.innerHTML = STATUS_ORDER.map((code) => statusButtonHtml(code, currentStatus, true, code === "COVER" && !(staff.cover_role_codes || []).length)).join("");
    elements.quickMenu.classList.remove("hidden");
    anchor.setAttribute("aria-expanded", "true");
    positionQuickStatusMenu(anchor);
    const selectedButton = elements.quickOptions.querySelector(".selected");
    selectedButton?.focus({ preventScroll: true });
  }

  function applyQuickStatus(statusCode) {
    if (!state.quickKey || !STATUS[statusCode]) return;
    const [staffId, workDate] = state.quickKey.split("|");
    const staff = state.staff.find((item) => item.staff_id === staffId);
    const previous = state.entries.get(state.quickKey);
    if (!staff || !previous) return;

    if (virtualStatus(previous) === statusCode) {
      closeQuickStatusMenu();
      return;
    }

    if (statusCode === "COVER") {
      if (!(staff.cover_role_codes || []).length) {
        setMessage(`${staff.display_name} has no authorised COVER roles in Staff Master.`, "error");
        return;
      }
      closeQuickStatusMenu();
      openDayEditor(staffId, workDate, "COVER");
      return;
    }

    const next = { ...previous, day_status: statusCode, assignment_type: "BASE" };
    if (["WORKING", "QUALITY_ANALYSIS"].includes(statusCode)) {
      if (!supportsMixedDailyAssignments(staff)) {
        Object.assign(next, baseAssignmentForDailyEdit(staff, previous));
      } else {
        const fallback = defaultEntry(staff, workDate);
        const previousWasCover = previous.assignment_type === "COVER";
        next.operational_role_code = previousWasCover ? fallback.operational_role_code : (previous.operational_role_code || fallback.operational_role_code);
        next.area_code = previousWasCover ? fallback.area_code : (previous.area_code || fallback.area_code);
        next.station_code = previousWasCover ? fallback.station_code : (previous.station_code ?? fallback.station_code);
      }
    } else {
      next.operational_role_code = null;
      next.area_code = null;
      next.station_code = null;
    }

    next.sorting_work_mode = normalizedSortingWorkMode(next);
    state.entries.set(state.quickKey, next);
    setDirty(true);
    closeQuickStatusMenu();
    renderGrid();
    setMessage(`${staff.display_name} · ${formatDate(workDate)} changed to ${STATUS[statusCode].label}.`, "success");
  }

  function openDayEditor(staffId, workDate, statusOverride = "") {
    if (!isEditable()) return;
    closeQuickStatusMenu();
    const staff = state.staff.find((item) => item.staff_id === staffId);
    const entry = state.entries.get(entryKey(staffId, workDate));
    if (!staff || !entry) return;
    state.editingKey = entryKey(staffId, workDate);
    elements.dayTitle.textContent = staff.display_name;
    elements.daySubtitle.textContent = formatDate(workDate);
    elements.dayMessage.textContent = "";
    populateDayModal(staff, entry, statusOverride);
    elements.dayModal.classList.remove("hidden");
  }

  function closeDayModal() { elements.dayModal.classList.add("hidden"); state.editingKey = ""; }
  function closeHistory() { elements.historyModal.classList.add("hidden"); }
  function closeLink() { elements.linkModal.classList.add("hidden"); }

  function normalizedSaveTime(value) {
    const text = String(value || "").trim();
    return text ? text.slice(0, 5) : null;
  }

  function normalizedRosterEntriesForSave(entries = []) {
    return entries.map((entry) => ({
      staff_id: String(entry.staff_id || ""),
      work_date: String(entry.work_date || ""),
      day_status: String(entry.day_status || ""),
      assignment_type: String(entry.assignment_type || "BASE"),
      operational_role_code: entry.operational_role_code || null,
      area_code: entry.area_code || null,
      station_code: entry.station_code || null,
      display_section_code: entry.display_section_code || null,
      sorting_work_mode: entry.sorting_work_mode || null,
      planned_start_time: normalizedSaveTime(entry.planned_start_time),
      planned_end_time: normalizedSaveTime(entry.planned_end_time),
      shift_override_confirmed: entry.shift_override_confirmed === true,
      notes: String(entry.notes || "").trim() || null,
    })).sort((a, b) => `${a.staff_id}|${a.work_date}`.localeCompare(`${b.staff_id}|${b.work_date}`));
  }

  function rosterEntriesFingerprint(entries = []) {
    return JSON.stringify(normalizedRosterEntriesForSave(entries));
  }

  function clientSaveIssue() {
    const unverified = crossShiftStaffIssues();
    if (unverified.length) {
      const names = unverified.slice(0, 4).map((staff) => staff.display_name).join(", ");
      const suffix = unverified.length > 4 ? ` +${unverified.length - 4} more` : "";
      return `${names}${suffix} ${unverified.length === 1 ? "is" : "are"} in the other Staff Master shift without an explicit temporary shift override. Remove the row and re-add it through Add staff → Temporary shift override if required.`;
    }
    const mopIssue = sortingMopIssue();
    if (mopIssue) return mopIssue;
    for (const entry of state.entries.values()) {
      if (entry.assignment_type !== "COVER") continue;
      const staff = state.staff.find((item) => item.staff_id === entry.staff_id);
      if (!staff || !(staff.cover_role_codes || []).includes(entry.operational_role_code)) {
        return `${staff?.display_name || "A staff member"} has a COVER assignment that is no longer authorised in Staff Master.`;
      }
    }
    return "";
  }

  function serializeEntries() {
    const staffById = new Map(state.staff.map((staff) => [staff.staff_id, staff]));
    return [...state.entries.values()].map((entry) => {
      const staff = staffById.get(entry.staff_id);
      return {
        staff_id: entry.staff_id, work_date: entry.work_date, day_status: entry.day_status,
        assignment_type: entry.assignment_type, operational_role_code: entry.operational_role_code || null,
        area_code: entry.area_code || null, station_code: entry.station_code || null,
        display_section_code: state.layouts.get(entry.staff_id) || null,
        sorting_work_mode: isSortingWorkingEntry(entry) ? (entry.sorting_work_mode || null) : null,
        planned_start_time: entry.planned_start_time || null, planned_end_time: entry.planned_end_time || null,
        shift_override_confirmed: Boolean(staff && isShiftOverride(staff) && shiftOverrideAuthorised(staff)),
        notes: entry.notes || null
      };
    });
  }

  async function saveRoster(reasonOverride = "") {
    if (!isEditable()) return null;

    if (!loadedRosterContextMatchesControls()) {
      setMessage("Save blocked: the selected week/shift does not match the roster currently loaded on screen. Reload the selected roster before saving.", "error");
      await loadRoster({ force: true });
      return null;
    }

    if (state.suspiciousShiftDraft) {
      setMessage("Save blocked: this draft failed the shift-context safety check. Use Discard Draft to recover the last published roster or review the draft first.", "error");
      return null;
    }

    const consistencyRepairs = syncAllBaseAssignmentsToSections();
    if (consistencyRepairs > 0) {
      setDirty(true);
      renderGrid();
    }

    const saveIssue = clientSaveIssue();
    if (saveIssue) {
      setMessage(`Cannot save yet. ${saveIssue}`, "error");
      return null;
    }

    const reason = reasonOverride || window.prompt("Reason for this roster update:", "Update weekly production roster");
    if (!reason) return null;

    const payload = serializeEntries();
    const expectedFingerprint = rosterEntriesFingerprint(payload);
    const expectedSunday = elements.sunday.value === "1";
    const expectedNote = elements.note.value.trim() || null;
    const wasDirty = state.dirty;

    state.loading = true; renderControls(); setMessage("Saving Production Roster…");
    try {
      const result = await rpc("save_production_roster_week", {
        p_week_start: mondayFromWeekValue(elements.week.value), p_shift_code: elements.shift.value,
        p_include_sunday: expectedSunday, p_week_note: expectedNote,
        p_entries: payload, p_base_row_version: state.data.document?.status === "DRAFT" ? state.data.document.row_version : null,
        p_change_reason: reason, p_source_application: "PRODUCTION_ROSTER_UI"
      });

      await loadRoster({ force: true });

      const reloadedFingerprint = rosterEntriesFingerprint(serializeEntries());
      const reloadedSunday = elements.sunday.value === "1";
      const reloadedNote = elements.note.value.trim() || null;
      const verified = expectedFingerprint === reloadedFingerprint
        && expectedSunday === reloadedSunday
        && expectedNote === reloadedNote;

      if (!verified) {
        setDirty(true);
        setMessage("The roster save returned successfully, but the reloaded data does not exactly match what was submitted. Do not publish yet; review the highlighted unsaved state.", "error");
        return null;
      }

      setDirty(false);
      setMessage(`Roster version ${result.version_number} saved and verified.`, "success");
      return result;
    } catch (error) {
      console.error(error);
      if (wasDirty || consistencyRepairs > 0) setDirty(true);
      setMessage(`Save failed — NOTHING was saved. Your changes are still unsaved on this screen. ${friendlyError(error)}`, "error");
      return null;
    } finally {
      state.loading = false;
      renderControls();
    }
  }

  async function publishRoster() {
    if (!isEditable()) return;
    if (!loadedRosterContextMatchesControls()) {
      setMessage("Publish blocked: the selected week/shift does not match the roster currently loaded on screen. Reload before publishing.", "error");
      return;
    }
    if (state.suspiciousShiftDraft) {
      setMessage("Publish blocked: this draft failed the shift-context safety check. Discard or review it before publication.", "error");
      return;
    }
    await refreshPendingLeaveOverlay();
    const unresolved = pendingLeaveRequestIds().size;
    if (unresolved > 0 && !window.confirm(`${unresolved} unresolved Holiday / Day Off ${unresolved === 1 ? "request affects" : "requests affect"} staff in this roster week. Publish anyway? Select Cancel to review the requests first.`)) {
      await openLeaveRequests("ACTION", "Review the unresolved requests affecting this roster week before publishing when possible.");
      return;
    }
    if (state.dirty || state.data.document?.status !== "DRAFT") {
      const saved = await saveRoster("Prepare Production Roster for publication");
      if (!saved) return;
    }
    const doc = state.data.document;
    if (!doc || doc.status !== "DRAFT") return;
    if (!window.confirm(`Publish ${state.data.shift.shift_name} roster version ${doc.version_number}? Published history cannot be edited.`)) return;
    state.loading = true; renderControls();
    try {
      const result = await rpc("publish_production_roster_week", {
        p_roster_version_id: doc.roster_version_id, p_base_row_version: doc.row_version,
        p_reason: "Confirmed Production Roster publication", p_source_application: "PRODUCTION_ROSTER_UI"
      });
      setMessage(`Roster version ${result.version_number} published.`, "success"); await loadRoster({ force: true });
    } catch (error) { setMessage(friendlyError(error), "error"); }
    finally { state.loading = false; renderControls(); }
  }

  async function discardDraft() {
    const doc = state.data?.document;
    if (!doc || doc.status !== "DRAFT") return;
    const reason = window.prompt("Reason for discarding this saved draft:", "Discard roster changes");
    if (!reason) return;
    try {
      await rpc("cancel_production_roster_draft", { p_roster_version_id: doc.roster_version_id, p_base_row_version: doc.row_version, p_reason: reason });
      setMessage("Draft discarded. Published history was preserved.", "success"); await loadRoster({ force: true });
    } catch (error) { setMessage(friendlyError(error), "error"); }
  }

  async function openHistory() {
    elements.historyModal.classList.remove("hidden"); elements.historyTitle.textContent = `${state.data.shift.shift_name} · ${formatDate(mondayFromWeekValue(elements.week.value))}`;
    elements.historyContent.innerHTML = '<div class="roster-loading"><span></span><p>Loading history…</p></div>';
    try {
      const result = await rpc("get_production_roster_history", { p_week_start: mondayFromWeekValue(elements.week.value), p_shift_code: elements.shift.value });
      const versions = result.versions || [];
      elements.historyContent.innerHTML = `${state.historyVersionId ? '<button class="roster-button" type="button" data-open-current-roster>Return to current roster</button>' : ""}${versions.length ? versions.map((version) => `<div class="roster-history-row"><div><span class="roster-status-chip ${String(version.status).toLowerCase()}">${escapeHtml(version.status)}</span></div><div><strong>Version ${Number(version.version_number)}</strong><span>${Number(version.staff_count)} staff · ${Number(version.entry_count)} entries · ${escapeHtml(formatDateTime(version.published_at || version.saved_at || version.created_at))}</span>${version.week_note ? `<span>${escapeHtml(version.week_note)}</span>` : ""}</div><button class="roster-button" type="button" data-open-roster-version="${escapeHtml(version.roster_version_id)}">Open</button></div>`).join("") : '<div class="roster-empty">No saved versions for this shift and week.</div>'}`;
    } catch (error) { elements.historyContent.innerHTML = `<div class="roster-empty">${escapeHtml(friendlyError(error))}</div>`; }
  }

  async function createNextWeek() {
    if (!canOpenNextWeekFromCurrentWeek()) {
      setMessage("Create next week is available from Tuesday while viewing the current week.", "error");
      renderControls();
      return;
    }

    const nextWeek = addDays(currentMonday(), 7);
    elements.week.value = isoWeekValue(nextWeek);
    state.historyVersionId = null;
    const loaded = await loadRoster();
    if (!loaded) return;

    const shiftName = state.data?.shift?.shift_name || state.loadedShiftCode || "selected shift";
    if (state.data?.document) {
      setMessage(`Next week's ${shiftName} roster already exists. Opened version ${Number(state.data.document.version_number)} (${state.data.document.status}).`, "success");
    } else {
      setMessage(`New ${shiftName} roster opened for ${formatDate(nextWeek)}. Use Create from previous week if you want last week's published plan as the starting point, or edit the Staff Master defaults shown here and Save when ready.`, "success");
    }
    renderControls();
  }

  async function copyPreviousWeek() {
    if (!isNewUnsavedFutureRoster()) {
      setMessage("Create from previous week is available only while creating a new future roster before its first Save.", "error");
      renderControls();
      return;
    }
    if (state.dirty && !window.confirm("Replace the current unsaved new-week plan with the previous published week?")) return;
    const previousWeek = addDays(mondayFromWeekValue(elements.week.value), -7);
    try {
      const history = await rpc("get_production_roster_history", { p_week_start: previousWeek, p_shift_code: elements.shift.value });
      const published = (history.versions || []).find((version) => version.status === "PUBLISHED") || (history.versions || []).find((version) => version.status === "SUPERSEDED");
      if (!published) throw new Error("No previous published roster was found for this shift.");
      const [previous, previousPool] = await Promise.all([
        rpc("get_production_roster_week", { p_week_start: previousWeek, p_shift_code: elements.shift.value, p_roster_version_id: published.roster_version_id }),
        rpc("get_production_roster_staff_pool", { p_week_start: previousWeek, p_shift_code: elements.shift.value, p_roster_version_id: published.roster_version_id })
      ]);
      const previousPoolById = new Map((previousPool.staff || []).map((staff) => [staff.staff_id, staff]));
      const currentShift = String(state.data?.shift?.shift_code || "");
      const mergedStaff = new Map(
        state.staff
          .filter((staff) => !staff.default_shift_code || staff.default_shift_code === currentShift)
          .map((staff) => [staff.staff_id, { ...staff, shift_override_authorized: false, shift_override_source: null }])
      );
      (previous.staff || []).forEach((staff) => {
        const poolStaff = previousPoolById.get(staff.staff_id);
        if (!poolStaff || poolStaff.currently_eligible === false || poolStaff.default_shift_code !== currentShift) return;
        mergedStaff.set(staff.staff_id, {
          ...staff,
          default_shift_code: poolStaff.default_shift_code,
          default_shift_name: poolStaff.default_shift_name,
          shift_override_authorized: false,
          shift_override_source: null,
          cover_role_codes: poolStaff.cover_role_codes || staff.cover_role_codes || []
        });
      });
      state.staff = [...mergedStaff.values()];
      const previousMap = new Map((previous.entries || []).map((entry) => [entryKey(entry.staff_id, entry.work_date), entry]));
      const previousLayouts = new Map((previous.staff || []).map((staff) => [staff.staff_id, staff.display_section_code || defaultDisplaySection(staff)]));
      const currentDays = visibleDays(); state.entries = new Map();
      state.staff.forEach((staff) => {
        state.layouts.set(staff.staff_id, previousLayouts.get(staff.staff_id) || defaultDisplaySection(staff));
        currentDays.forEach((day, index) => {
          const prior = previousMap.get(entryKey(staff.staff_id, addDays(previousWeek, index)));
          state.entries.set(entryKey(staff.staff_id, day), prior ? { ...prior, roster_entry_id: null, work_date: day } : defaultEntry(staff, day));
        });
      });
      elements.note.value = previous.week_note || ""; setDirty(true); renderGrid(); renderControls(); setMessage("New week created from the previous published roster for the same default shift. Review the plan, then Save. Temporary cross-shift assignments were not copied; re-add them explicitly if needed.", "success");
    } catch (error) { setMessage(friendlyError(error), "error"); }
  }

  async function createStaffLink() {
    elements.createLink.disabled = true; elements.linkMessage.textContent = "Loading the fixed staff link…";
    try {
      const result = await rpc("get_or_create_production_roster_staff_portal_link");
      const url = new URL("./roster-view.html", window.location.href); url.searchParams.set("t", result.token);
      elements.linkInput.value = url.toString(); elements.linkResult.classList.remove("hidden"); elements.linkMessage.textContent = "Fixed Morning + Evening staff link ready. This URL stays the same when new rosters are published.";
    } catch (error) { elements.linkMessage.textContent = friendlyError(error); }
    finally { elements.createLink.disabled = false; }
  }

  function leaveRequestRange(request) {
    const start = formatDate(request.start_date);
    const end = formatDate(request.end_date);
    return request.end_date && request.end_date !== request.start_date ? `${start} – ${end}` : start;
  }

  function leaveAttentionMeta(request) {
    const code = String(request.attention_state || request.status || "").toUpperCase();
    const map = {
      STARTS_TODAY: { label: "Starts today", cls: "overdue" },
      DECISION_OVERDUE: { label: "Decision overdue", cls: "overdue" },
      GM_SEND_FAILED: { label: "GM email failed", cls: "overdue" },
      GM_SENDING: { label: "GM email sending", cls: "gm" },
      AWAITING_GM: { label: "Awaiting GM", cls: "gm" },
      SELECTED_ROSTER_WEEK: { label: "This roster week", cls: "plan" },
      PLAN_THIS_WEEK: { label: "Plan this week", cls: "plan" },
      UPCOMING: { label: "Upcoming", cls: "upcoming" },
      APPROVED: { label: "Approved", cls: "approved" },
      REJECTED: { label: "Rejected", cls: "rejected" },
      EXPIRED: { label: "Expired", cls: "expired" },
      CANCELLED: { label: "Cancelled", cls: "expired" },
    };
    return map[code] || { label: code.replaceAll("_", " ") || "Pending", cls: "plan" };
  }

  function renderLeaveSummary(summary = {}) {
    if (!elements.leaveSummary) return;
    const cards = [
      [Number(summary.action_count || 0), "Need action", "attention"],
      [Number(summary.selected_week_pending_count || 0), "Selected week", "attention"],
      [Number(summary.awaiting_gm_count || 0), "Awaiting GM", "gm"],
      [Number(summary.upcoming_count || 0), "Upcoming", ""],
      [Number(summary.history_count || 0), "History", ""],
    ];
    elements.leaveSummary.innerHTML = cards.map(([value, label, cls]) => `<div class="roster-leave-summary-card${cls ? ` ${cls}` : ""}"><strong>${value}</strong><span>${escapeHtml(label)}</span></div>`).join("");
  }

  function setLeaveScopeActive(scope) {
    state.leaveScope = scope;
    elements.leaveTabs?.querySelectorAll("[data-leave-scope]").forEach((button) => button.classList.toggle("active", button.dataset.leaveScope === scope));
  }

  function leaveRequestCard(request) {
    const meta = leaveAttentionMeta(request);
    const requestType = String(request.request_type || "").toUpperCase();
    const gmRequired = Boolean(request.requires_general_manager);
    const gmState = String(request.gm_state || "").toUpperCase();
    const status = String(request.status || "PENDING").toUpperCase();
    const historical = status !== "PENDING";
    const cardClass = meta.cls === "overdue" ? " is-overdue" : meta.cls === "gm" ? " is-awaiting-gm" : meta.label === "This roster week" ? " is-selected-week" : historical ? " is-history" : "";
    const threshold = Number(request.general_manager_threshold_days || 20);
    const duration = Number(request.duration_days || 1);
    const due = request.decision_due_date ? `Decision target: ${formatDate(request.decision_due_date)}` : "";
    const gmBadge = gmRequired ? `<span class="roster-leave-gm-badge">GM &gt; ${threshold} days</span>` : "";
    const decisionInfo = historical
      ? `<small>${request.reviewed_at ? `Decided ${escapeHtml(formatDateTime(request.reviewed_at))}` : "Closed"}${request.decision_source ? ` · ${escapeHtml(String(request.decision_source).replaceAll("_", " "))}` : ""}${request.decision_actor ? ` · ${escapeHtml(request.decision_actor)}` : ""}</small>`
      : `<small>Submitted ${escapeHtml(formatDateTime(request.submitted_at))}</small>`;

    let actions = "";
    if (status === "PENDING" && state.canApproveLeave) {
      if (gmRequired) {
        if (gmState === "AWAITING_GM") {
          actions = `<button class="roster-button" type="button" data-leave-history-toggle="${escapeHtml(request.leave_request_id)}">History</button>`;
        } else if (gmState === "SENDING") {
          const sendingAge = request.gm_updated_at ? Date.now() - new Date(request.gm_updated_at).getTime() : 0;
          const canRetry = sendingAge > 120000;
          actions = `${canRetry ? `<button class="roster-button gm" type="button" data-leave-send-gm="${escapeHtml(request.leave_request_id)}">Retry GM email</button>` : '<button class="roster-button gm" type="button" disabled>Sending…</button>'}<button class="roster-button roster-leave-history-toggle" type="button" data-leave-history-toggle="${escapeHtml(request.leave_request_id)}">History</button>`;
        } else {
          const gmLabel = gmState === "SEND_FAILED" ? "Retry GM email" : "Send to General Manager";
          actions = `<button class="roster-button" type="button" data-leave-decision="REJECTED" data-leave-request-id="${escapeHtml(request.leave_request_id)}">Reject</button><button class="roster-button gm" type="button" data-leave-send-gm="${escapeHtml(request.leave_request_id)}">${gmLabel}</button><button class="roster-button roster-leave-history-toggle" type="button" data-leave-history-toggle="${escapeHtml(request.leave_request_id)}">History</button>`;
        }
      } else {
        actions = `<button class="roster-button" type="button" data-leave-decision="REJECTED" data-leave-request-id="${escapeHtml(request.leave_request_id)}">Reject</button><button class="roster-button primary" type="button" data-leave-decision="APPROVED" data-leave-request-id="${escapeHtml(request.leave_request_id)}">Approve</button><button class="roster-button roster-leave-history-toggle" type="button" data-leave-history-toggle="${escapeHtml(request.leave_request_id)}">History</button>`;
      }
    } else {
      actions = `<button class="roster-button roster-leave-history-toggle" type="button" data-leave-history-toggle="${escapeHtml(request.leave_request_id)}">View history</button>`;
    }

    return `<article class="roster-leave-request${cardClass}" data-leave-request="${escapeHtml(request.leave_request_id)}">
      <div class="roster-leave-request-main">
        <div class="roster-leave-request-heading"><strong>${escapeHtml(request.display_name)}</strong><span class="roster-leave-type ${requestType.toLowerCase()}">${escapeHtml(requestType.replaceAll("_", " "))}</span><span class="roster-leave-state ${meta.cls}">${escapeHtml(meta.label)}</span>${gmBadge}</div>
        <span>${escapeHtml(leaveRequestRange(request))} · ${duration} ${duration === 1 ? "day" : "days"}${request.default_shift_name ? ` · ${escapeHtml(request.default_shift_name)}` : ""}</span>
        ${due && status === "PENDING" ? `<span class="roster-leave-due">${escapeHtml(due)}</span>` : ""}
        ${request.gm_sent_to && status === "PENDING" ? `<span>General Manager: ${escapeHtml(request.gm_sent_to)}${request.gm_expires_at ? ` · Link expires ${escapeHtml(formatDateTime(request.gm_expires_at))}` : ""}</span>` : ""}
        ${request.reason ? `<p>${escapeHtml(request.reason)}</p>` : ""}${decisionInfo}
      </div>
      <div class="roster-leave-request-actions">${actions}</div>
      <div id="rosterLeaveHistory-${escapeHtml(request.leave_request_id)}" class="roster-leave-history hidden"></div>
    </article>`;
  }

  function groupStaffHistoryHtml(result) {
    const staffRows = Array.isArray(result?.staff) ? result.staff : [];
    const requests = Array.isArray(result?.requests) ? result.requests : [];
    if (!requests.length) return '<div class="roster-empty">No requests found for this staff search.</div>';
    const summaryById = new Map(staffRows.map((item) => [item.staff_id, item]));
    const grouped = new Map();
    requests.forEach((request) => {
      const key = request.staff_id || request.display_name;
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key).push(request);
    });
    return [...grouped.entries()].map(([staffId, items]) => {
      const info = summaryById.get(staffId) || { display_name: items[0]?.display_name, total_requests: items.length };
      const stats = [
        `${Number(info.total_requests || items.length)} total`,
        `${Number(info.approved_count || 0)} approved`,
        `${Number(info.rejected_count || 0)} rejected`,
        Number(info.pending_count || 0) ? `${Number(info.pending_count)} pending` : "",
        Number(info.expired_count || 0) ? `${Number(info.expired_count)} expired` : "",
      ].filter(Boolean).join(" · ");
      return `<section class="roster-staff-history-group"><header><div><strong>${escapeHtml(info.display_name || items[0]?.display_name || "Staff")}</strong><span>${escapeHtml(stats)}</span></div><small>Last request ${escapeHtml(formatDateTime(info.last_request_at || items[0]?.submitted_at))}</small></header>${items.map(leaveRequestCard).join("")}</section>`;
    }).join("");
  }

  async function loadStaffLeaveHistory(searchText) {
    const query = String(searchText || "").trim();
    if (query && query.length < 2) {
      elements.leaveRequestsList.innerHTML = '<div class="roster-empty">Type at least 2 characters to search staff history.</div>';
      return;
    }
    elements.leaveRequestsList.innerHTML = '<div class="roster-loading"><span></span><p>Loading staff history…</p></div>';
    try {
      const result = await rpc("search_production_roster_staff_leave_history", { p_staff_search: query || null, p_limit: 250 });
      elements.leaveRequestsList.innerHTML = groupStaffHistoryHtml(result);
    } catch (error) {
      elements.leaveRequestsList.innerHTML = `<div class="roster-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  function leaveCalendarMonthValue(date = new Date()) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, "0");
    return `${year}-${month}`;
  }

  function shiftLeaveCalendarMonth(offset) {
    const current = elements.leaveCalendarMonth.value || leaveCalendarMonthValue();
    const [year, month] = current.split("-").map(Number);
    elements.leaveCalendarMonth.value = leaveCalendarMonthValue(new Date(year, month - 1 + offset, 1));
    loadLeaveCapacityCalendar();
  }

  function leaveNamesHtml(items, status) {
    const filtered = (Array.isArray(items) ? items : []).filter((item) => item.status === status);
    if (!filtered.length) return "";
    const label = status === "APPROVED" ? "Away" : "Requested";
    return `<div class="roster-calendar-leave ${status.toLowerCase()}"><b>${filtered.length} ${label}</b><span>${filtered.slice(0, 3).map((item) => escapeHtml(item.display_name)).join(", ")}${filtered.length > 3 ? ` +${filtered.length - 3}` : ""}</span></div>`;
  }

  function renderLeaveCapacityCalendar(result) {
    state.leaveCalendarData = result || {};
    const days = Array.isArray(result?.days) ? result.days : [];
    const summary = result?.summary || {};
    const month = elements.leaveCalendarMonth.value;
    const exactCoverage = Number(summary.exact_kg_coverage_percent || 0);
    elements.leaveCalendarSummary.innerHTML = `
      <div><strong>${Number(summary.approved_staff_days || 0)}</strong><span>Approved staff-days</span></div>
      <div><strong>${Number(summary.pending_staff_days || 0)}</strong><span>Pending staff-days</span></div>
      <div><strong>${Number(summary.estimated_kg || 0).toLocaleString(undefined, { maximumFractionDigits: 0 })} kg</strong><span>Scheduled estimate</span></div>
      <div class="${exactCoverage < 80 ? "warning" : ""}"><strong>${exactCoverage.toFixed(0)}%</strong><span>Exact KG coverage</span></div>`;
    const headers = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((label) => `<div class="roster-calendar-weekday">${label}</div>`).join("");
    const cells = days.map((day) => {
      const inMonth = String(day.work_date || "").startsWith(month);
      const demand = Number(day.estimated_kg || 0);
      const customers = Number(day.customer_count || 0);
      const approved = Number(day.approved_count || 0);
      const available = Math.max(0, Number(day.eligible_staff || 0) - approved);
      const coverage = Number(day.exact_kg_coverage_percent || 0);
      const pressure = demand > 0 && available > 0 ? Math.round(demand / available) : 0;
      return `<article class="roster-calendar-day${inMonth ? "" : " outside"}${approved ? " has-approved" : ""}" title="${escapeHtml(`${customers} scheduled customers · ${available} staff after approved leave`)}">
        <header><strong>${Number(String(day.work_date).slice(-2))}</strong><span>${available}/${Number(day.eligible_staff || 0)} staff</span></header>
        <div class="roster-calendar-demand"><b>${demand ? `${Math.round(demand).toLocaleString()} kg` : "KG missing"}</b><span>${customers} customers · ${coverage.toFixed(0)}% exact${pressure ? ` · ${pressure} kg/staff` : ""}</span></div>
        ${leaveNamesHtml(day.leave, "APPROVED")}${leaveNamesHtml(day.leave, "PENDING")}
      </article>`;
    }).join("");
    elements.leaveCalendarGrid.innerHTML = headers + cells;
  }

  async function loadLeaveCapacityCalendar() {
    if (!elements.leaveCalendarMonth.value) elements.leaveCalendarMonth.value = leaveCalendarMonthValue();
    elements.leaveCalendarGrid.innerHTML = '<div class="roster-loading"><span></span><p>Building capacity calendar…</p></div>';
    try {
      const result = await rpc("get_production_roster_capacity_calendar", {
        p_month: `${elements.leaveCalendarMonth.value}-01`,
        p_shift_code: elements.leaveCalendarShift.value || null
      });
      renderLeaveCapacityCalendar(result);
    } catch (error) {
      elements.leaveCalendarGrid.innerHTML = `<div class="roster-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  async function openLeaveRequests(scope = state.leaveScope || "ACTION", message = "") {
    elements.leaveRequestsModal.classList.remove("hidden");
    setLeaveScopeActive(scope);
    elements.leaveRequestsMessage.textContent = message;
    const calendarMode = scope === "CALENDAR";
    elements.leaveCalendar.classList.toggle("hidden", !calendarMode);
    elements.leaveSummary.classList.toggle("hidden", calendarMode);
    elements.leaveRequestsList.classList.toggle("hidden", calendarMode);
    elements.leaveRequestsMessage.classList.toggle("hidden", calendarMode);
    if (calendarMode) {
      elements.leaveHistorySearch.classList.add("hidden");
      if (!elements.leaveCalendarMonth.value) {
        elements.leaveCalendarMonth.value = leaveCalendarMonthValue();
        elements.leaveCalendarShift.value = elements.shift.value || "";
      }
      await loadLeaveCapacityCalendar();
      return;
    }
    const historyMode = scope === "HISTORY";
    elements.leaveHistorySearch?.classList.toggle("hidden", !historyMode);
    if (historyMode && elements.leaveHistorySearchInput?.value.trim()) {
      await loadStaffLeaveHistory(elements.leaveHistorySearchInput.value);
      return;
    }
    elements.leaveRequestsList.innerHTML = '<div class="roster-loading"><span></span><p>Loading requests…</p></div>';
    try {
      const dashboard = await rpc("get_production_roster_leave_dashboard", {
        p_week_start: mondayFromWeekValue(elements.week.value),
        p_shift_code: null,
        p_scope: scope
      });
      state.leaveDashboard = dashboard || null;
      renderLeaveSummary(dashboard?.summary || {});
      const count = Number(dashboard?.summary?.action_count || 0);
      elements.leaveRequestsCount.textContent = String(count);
      elements.leaveRequestsCount.classList.toggle("hidden", count === 0);
      elements.leaveRequests.classList.toggle("has-requests", count > 0);
      const requests = Array.isArray(dashboard?.requests) ? dashboard.requests : [];
      const empty = scope === "HISTORY" ? "No decided or expired requests yet. Search a staff name above to include their full request history." : scope === "UPCOMING" ? "No future requests waiting for a later planning week." : scope === "AWAITING_GM" ? "No requests are currently in the General Manager workflow." : "No leave requests need action right now.";
      elements.leaveRequestsList.innerHTML = requests.length ? requests.map(leaveRequestCard).join("") : `<div class="roster-empty">${empty}</div>`;
      if (dashboard?.settings) state.leaveSettingsValue = dashboard.settings;
    } catch (error) {
      elements.leaveRequestsList.innerHTML = `<div class="roster-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  function targetUnitLabel(unitCode) {
    const map = { KG_PER_STAFF_HOUR: "kg / staff hr", UNITS_PER_KG: "units / kg" };
    return map[unitCode] || String(unitCode || "").replaceAll("_", " ").toLowerCase();
  }

  function renderTargetSettings(settings) {
    const targets = Array.isArray(settings?.targets) ? settings.targets : [];
    elements.targetSettingsList.innerHTML = targets.length ? targets.map((target) => {
      const provisional = target.target_code === "SORTING_MOP_KG_PER_STAFF_HOUR";
      return `<article class="roster-target-setting${provisional ? " provisional" : ""}">
        <div>
          <strong>${escapeHtml(target.target_name)}${provisional ? ' <em class="roster-target-provisional">Provisional</em>' : ""}</strong>
          <span>${escapeHtml(target.description || target.target_code)}</span>
        </div>
        <label>
          <input type="number" min="0.001" step="0.1" value="${Number(target.target_value)}" data-target-input="${escapeHtml(target.target_code)}">
          <span>${escapeHtml(targetUnitLabel(target.unit_code))}</span>
        </label>
        <button class="roster-button primary" type="button" data-save-target="${escapeHtml(target.target_code)}">Save</button>
      </article>`;
    }).join("") : '<div class="roster-empty">No production targets configured.</div>';
  }

  function renderWorkingHoursSettings(settings) {
    const profiles = Array.isArray(settings?.work_profiles) ? settings.work_profiles : [];
    const grouped = ["MORNING", "EVENING"].map((shiftCode) => {
      const rows = profiles.filter((profile) => profile.shift_code === shiftCode);
      if (!rows.length) return "";
      const title = shiftCode === "MORNING" ? "Morning Shift" : "Evening Shift";
      return `<section class="roster-hours-group"><h3>${title}</h3>${rows.map((profile) => `<div class="roster-hours-row"><div><strong>${escapeHtml(profile.profile_name)}</strong><span>${escapeHtml(profile.schedule_label)}</span></div><div><small>Break</small><strong>${Number(profile.break_minutes)} min</strong></div><div><small>Net productive</small><strong>${escapeHtml(formatNetHours(profile.net_minutes))}</strong></div></div>`).join("")}</section>`;
    }).join("");
    elements.workingHoursSettings.innerHTML = grouped || '<div class="roster-empty">No working-hour profiles configured.</div>';
  }

  function renderBankHolidaySettings(settings) {
    const holidays = Array.isArray(settings?.bank_holidays) ? settings.bank_holidays : [];
    elements.bankHolidayList.innerHTML = holidays.length ? holidays.map((item) => `<div class="roster-bank-holiday-item"><div><strong>${escapeHtml(formatDate(item.work_date))}</strong><span>${escapeHtml(item.label || "Bank Holiday")} · Saturday hours profile</span></div><button class="roster-button" type="button" data-remove-bank-holiday="${escapeHtml(item.work_date)}">Remove</button></div>`).join("") : '<div class="roster-settings-empty">No Bank Holiday Mondays configured in this date range.</div>';
  }

  async function loadOperationalSettingsBundle() {
    const selected = mondayFromWeekValue(elements.week.value);
    const from = addDays(selected, -370);
    const to = addDays(selected, 800);
    const settings = await rpc("get_production_roster_operational_settings", { p_from_date: from, p_to_date: to });
    state.settingsBundle = settings || { targets: [], work_profiles: [], bank_holidays: [] };
    state.operationalSettings = state.settingsBundle;
    renderTargetSettings(state.settingsBundle);
    renderWorkingHoursSettings(state.settingsBundle);
    renderBankHolidaySettings(state.settingsBundle);
    renderGrid();
    return state.settingsBundle;
  }

  async function loadLeaveSettings() {
    try {
      const settings = await rpc("get_production_roster_leave_governance_settings");
      state.leaveSettingsValue = settings || {};
      elements.leaveGmEmail.value = settings?.general_manager_email || "";
      elements.leaveGmThreshold.value = Number(settings?.general_manager_threshold_days || 20);
    } catch (error) {
      elements.settingsMessage.textContent = friendlyError(error);
    }
  }

  function setSettingsTab(tab) {
    state.settingsTab = ["TARGETS", "HOURS", "LEAVE"].includes(tab) ? tab : "TARGETS";
    elements.settingsTabs.querySelectorAll("[data-settings-tab]").forEach((button) => button.classList.toggle("active", button.dataset.settingsTab === state.settingsTab));
    elements.settingsTargets.classList.toggle("hidden", state.settingsTab !== "TARGETS");
    elements.settingsHours.classList.toggle("hidden", state.settingsTab !== "HOURS");
    elements.settingsLeave.classList.toggle("hidden", state.settingsTab !== "LEAVE");
  }

  async function openSettings(tab = state.settingsTab || "TARGETS") {
    elements.settingsModal.classList.remove("hidden");
    elements.settingsMessage.textContent = "Loading settings…";
    setSettingsTab(tab);
    try {
      await Promise.all([loadOperationalSettingsBundle(), loadLeaveSettings()]);
      elements.settingsMessage.textContent = "";
    } catch (error) {
      elements.settingsMessage.textContent = friendlyError(error);
    }
  }

  async function saveProductionTarget(targetCode) {
    const input = elements.targetSettingsList.querySelector(`[data-target-input="${CSS.escape(targetCode)}"]`);
    const value = Number(input?.value || 0);
    if (!Number.isFinite(value) || value <= 0) { elements.settingsMessage.textContent = "Enter a target value greater than zero."; return; }
    elements.settingsMessage.textContent = "Saving production target…";
    try {
      const result = await rpc("save_production_roster_target", { p_target_code: targetCode, p_target_value: value });
      await loadOperationalSettingsBundle();
      elements.settingsMessage.textContent = `${result.target_name || targetCode} saved at ${Number(result.target_value)} ${targetUnitLabel(result.unit_code)}.`;
    } catch (error) {
      elements.settingsMessage.textContent = friendlyError(error);
    }
  }

  async function addBankHoliday() {
    const workDate = elements.bankHolidayDate.value;
    const label = elements.bankHolidayLabel.value.trim() || "Bank Holiday";
    if (!workDate) { elements.settingsMessage.textContent = "Choose the Bank Holiday Monday date."; return; }
    const isoDay = new Date(`${workDate}T00:00:00Z`).getUTCDay() || 7;
    if (isoDay !== 1) { elements.settingsMessage.textContent = "The current Bank Holiday capacity rule applies to Monday dates only."; return; }
    elements.settingsMessage.textContent = "Saving Bank Holiday…";
    try {
      await rpc("save_production_roster_bank_holiday", { p_work_date: workDate, p_label: label });
      elements.bankHolidayDate.value = "";
      elements.bankHolidayLabel.value = "";
      await loadOperationalSettingsBundle();
      elements.settingsMessage.textContent = `${formatDate(workDate)} will use the Saturday working-hours profile.`;
    } catch (error) {
      elements.settingsMessage.textContent = friendlyError(error);
    }
  }

  async function removeBankHoliday(workDate) {
    if (!window.confirm(`Remove ${formatDate(workDate)} from the Bank Holiday capacity calendar?`)) return;
    try {
      await rpc("remove_production_roster_bank_holiday", { p_work_date: workDate });
      await loadOperationalSettingsBundle();
      elements.settingsMessage.textContent = `${formatDate(workDate)} removed from the Bank Holiday capacity calendar.`;
    } catch (error) {
      elements.settingsMessage.textContent = friendlyError(error);
    }
  }

  async function saveLeaveSettings() {
    const threshold = Number(elements.leaveGmThreshold.value || 20);
    const email = elements.leaveGmEmail.value.trim();
    if (!Number.isInteger(threshold) || threshold < 1 || threshold > 120) { elements.settingsMessage.textContent = "Enter a threshold between 1 and 120 days."; return; }
    elements.leaveSettingsSave.disabled = true;
    elements.settingsMessage.textContent = "Saving leave governance settings…";
    try {
      const settings = await rpc("save_production_roster_leave_governance_settings", {
        p_general_manager_threshold_days: threshold,
        p_general_manager_email: email,
        p_general_manager_token_ttl_hours: Number(state.leaveSettingsValue?.general_manager_token_ttl_hours || 168)
      });
      state.leaveSettingsValue = settings;
      elements.settingsMessage.textContent = `Leave settings saved. Holidays longer than ${Number(settings.general_manager_threshold_days)} days require General Manager approval.`;
    } catch (error) {
      elements.settingsMessage.textContent = friendlyError(error);
    } finally {
      elements.leaveSettingsSave.disabled = false;
    }
  }

  async function decideLeaveRequest(requestId, decision) {
    const action = decision === "APPROVED" ? "approve" : "reject";
    if (!window.confirm(`${action.charAt(0).toUpperCase() + action.slice(1)} this staff request?`)) return;
    const reviewNote = window.prompt("Review note (optional):", "");
    try {
      await rpc("decide_production_roster_leave_request", { p_leave_request_id: requestId, p_decision: decision, p_review_note: reviewNote || null });
      const resultMessage = decision === "APPROVED" ? "Request approved. Approved dates are protected in the planner until the updated roster is saved and published." : "Request rejected and moved to History.";
      await Promise.all([refreshLeaveRequestBadge(), refreshApprovedLeaveOverlay(), refreshPendingLeaveOverlay()]);
      await openLeaveRequests(state.leaveScope === "HISTORY" ? "HISTORY" : "ACTION", resultMessage);
    } catch (error) {
      elements.leaveRequestsMessage.textContent = friendlyError(error);
    }
  }

  async function edgeFunctionErrorDetails(error) {
    const fallback = error?.message || String(error || "Edge Function request failed.");
    const response = error?.context;
    if (!response || typeof response.json !== "function") return fallback;
    try {
      const readable = typeof response.clone === "function" ? response.clone() : response;
      const payload = await readable.json();
      const stage = String(payload?.stage || "").trim();
      const message = String(payload?.error || payload?.message || "").trim();
      if (stage && message) return `${stage}: ${message}`;
      if (message) return message;
    } catch (_) {
      // Keep the SDK error as a fallback when the response is not JSON.
    }
    return fallback;
  }

  async function sendLeaveRequestToGeneralManager(requestId) {
    if (!window.confirm("Send this Holiday request to the configured General Manager for an Approve / Reject decision?")) return;
    elements.leaveRequestsMessage.textContent = "Sending secure General Manager review email…";
    try {
      const reviewUrl = new URL("./roster-gm-review.html", window.location.href);
      reviewUrl.search = "";
      const { data, error } = await client.functions.invoke("production-roster-leave-email", {
        body: { leave_request_id: requestId, review_base_url: reviewUrl.toString() }
      });
      if (error) throw error;
      if (!data?.ok) throw new Error(data?.error || "The email could not be sent.");
      await Promise.all([refreshLeaveRequestBadge(), refreshPendingLeaveOverlay()]);
      await openLeaveRequests("AWAITING_GM", `Holiday request sent to ${data.sent_to}.`);
    } catch (error) {
      const message = await edgeFunctionErrorDetails(error);
      elements.leaveRequestsMessage.textContent = message;
      await openLeaveRequests("ACTION", message);
    }
  }

  async function toggleLeaveHistory(requestId) {
    const target = document.getElementById(`rosterLeaveHistory-${requestId}`);
    if (!target) return;
    if (!target.classList.contains("hidden")) { target.classList.add("hidden"); return; }
    target.classList.remove("hidden");
    target.innerHTML = '<div class="roster-loading"><span></span><p>Loading history…</p></div>';
    try {
      const history = await rpc("get_production_roster_leave_request_history", { p_leave_request_id: requestId });
      const rows = Array.isArray(history) ? history : [];
      target.innerHTML = rows.length ? `<div class="roster-leave-history-list">${rows.map((item) => `<div class="roster-leave-history-item"><time>${escapeHtml(formatDateTime(item.occurred_at))}</time><div><strong>${escapeHtml(String(item.event_type || "EVENT").replaceAll("_", " "))}</strong><span>${escapeHtml([item.actor_label, item.to_status, item.note].filter(Boolean).join(" · ") || "Recorded")}</span></div></div>`).join("")}</div>` : '<div class="roster-empty">No history events found.</div>';
    } catch (error) {
      target.innerHTML = `<div class="roster-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  async function initialize() {
    try {
      const { data: sessionData } = await client.auth.getSession();
      if (!sessionData.session) { window.location.replace("../index.html"); return; }
      const [reference,accessProfile]=await Promise.all([rpc("get_production_roster_reference_data"),rpc("get_current_account_access")]);
      state.reference = reference;
      state.accessProfile=accessProfile||{};
      state.canEditRoster=canAccountAction("PRODUCTION_ROSTER","EDIT");
      state.canApproveLeave=canAccountAction("PRODUCTION_ROSTER","APPROVE");
      state.canManageRoster=canAccountAction("PRODUCTION_ROSTER","MANAGE");
      const leaveSettingsTab=elements.settingsTabs.querySelector('[data-settings-tab="LEAVE"]');
      if (leaveSettingsTab) leaveSettingsTab.classList.toggle("hidden",!state.canManageRoster);
      elements.leaveSettingsSave.classList.toggle("hidden",!state.canManageRoster);
      elements.shift.innerHTML = (state.reference.shifts || []).map((shift) => `<option value="${escapeHtml(shift.shift_code)}">${escapeHtml(shift.shift_name)}</option>`).join("");
      elements.week.value = isoWeekValue(currentMonday());
      await loadRoster({ force: true });
      await refreshLeaveRequestBadge();
      try { state.leaveRevision = await rpc("get_production_roster_leave_revision"); } catch (_) { state.leaveRevision = ""; }
      const launch = new URLSearchParams(window.location.search);
      if (launch.get("panel") === "leave" && state.data?.can_manage) {
        const requestedScope = String(launch.get("scope") || "ACTION").toUpperCase();
        const allowedScopes = new Set(["ACTION", "UPCOMING", "AWAITING_GM", "CALENDAR", "HISTORY"]);
        await openLeaveRequests(allowedScopes.has(requestedScope) ? requestedScope : "ACTION", "Opened from your notifications.");
        launch.delete("panel");
        launch.delete("scope");
        const cleanUrl = `${window.location.pathname}${launch.toString() ? `?${launch}` : ""}${window.location.hash}`;
        window.history.replaceState({}, "", cleanUrl);
      }
    } catch (error) { elements.grid.innerHTML = `<div class="roster-empty">${escapeHtml(friendlyError(error))}</div>`; setMessage(friendlyError(error), "error"); }
  }

  elements.dayForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const [staffId, workDate] = state.editingKey.split("|");
    const staff = state.staff.find((item) => item.staff_id === staffId);
    const previous = state.entries.get(state.editingKey);
    if (!staff || !previous) return;
    const statusCode = elements.dayStatus.value;
    const working = ["WORKING", "COVER", "QUALITY_ANALYSIS"].includes(statusCode);
    const cover = statusCode === "COVER";
    if (cover && !elements.role.value) { elements.dayMessage.textContent = "Select an authorised COVER type."; return; }
    if (cover && !(staff.cover_role_codes || []).includes(elements.role.value)) { elements.dayMessage.textContent = "The selected COVER type is not authorised for this staff member."; return; }
    const next = { ...previous, day_status: cover ? "WORKING" : statusCode, assignment_type: cover ? "COVER" : "BASE", notes: elements.dayNote.value.trim() || null };
    if (working) {
      if (!cover && supportsTableDailyOverride(staff)) {
        const base = baseAssignmentForDailyEdit(staff, previous);
        const selectedTable = elements.station.value;
        if (!isFinishTableStation(selectedTable)) { elements.dayMessage.textContent = "Select Table 1, Table 2 or Table 3."; return; }
        Object.assign(next, base, { station_code: selectedTable });
      } else if (!cover && !supportsMixedDailyAssignments(staff)) {
        Object.assign(next, baseAssignmentForDailyEdit(staff, previous));
      } else {
        next.operational_role_code = elements.role.value;
        next.area_code = elements.area.value;
        next.station_code = elements.station.value || null;
      }
    } else { next.operational_role_code = null; next.area_code = null; next.station_code = null; }
    if (isSortingWorkingEntry(next)) {
      const dayDecisionBeforeSave = sortingMopForDay(workDate);
      const selectedMode = elements.sortingWorkModeField.classList.contains("hidden")
        ? (normalizedSortingWorkMode(next) || "CLOTHES")
        : elements.sortingWorkMode.value;
      next.sorting_work_mode = dayDecisionBeforeSave.noDedicated && selectedMode === "CLOTHES"
        ? null
        : selectedMode;
      if (next.sorting_work_mode === "MOP") {
        state.entries.forEach((other, key) => {
          if (key === state.editingKey || other.work_date !== workDate || !isSortingWorkingEntry(other)) return;
          state.entries.set(key, { ...other, sorting_work_mode: "CLOTHES" });
        });
      }
    } else {
      next.sorting_work_mode = null;
    }
    state.entries.set(state.editingKey, next); setDirty(true); closeDayModal(); renderGrid();
  });

  elements.dayStatus.addEventListener("change", () => {
    const [staffId] = state.editingKey.split("|"); const staff = state.staff.find((item) => item.staff_id === staffId); const entry = state.entries.get(state.editingKey);
    renderDetailedStatusButtons();
    if (staff && entry) populateDayFields(staff, entry);
  });
  elements.dayStatusButtons.addEventListener("click", (event) => {
    const button = event.target.closest("[data-status-choice]");
    if (!button) return;
    elements.dayStatus.value = button.dataset.statusChoice;
    elements.dayStatus.dispatchEvent(new Event("change"));
  });
  elements.coverRoleButtons.addEventListener("click", (event) => {
    const button = event.target.closest("[data-cover-role]");
    if (!button || !state.editingKey) return;
    const [staffId] = state.editingKey.split("|");
    const staff = state.staff.find((item) => item.staff_id === staffId);
    if (!staff || !(staff.cover_role_codes || []).includes(button.dataset.coverRole)) return;
    elements.role.value = button.dataset.coverRole;
    renderCoverRoleChoices(staff, elements.role.value);
    const entry = state.entries.get(state.editingKey);
    if (entry) renderSortingWorkModeField(entry);
  });
  elements.sortingWorkModeButtons.addEventListener("click", (event) => {
    const button = event.target.closest("[data-sorting-work-mode]");
    if (!button) return;
    setModalSortingWorkMode(button.dataset.sortingWorkMode);
  });
  elements.area.addEventListener("change", () => { populateStations(""); const entry = state.entries.get(state.editingKey); if (entry) renderSortingWorkModeField(entry); });
  elements.role.addEventListener("change", () => { const entry = state.entries.get(state.editingKey); if (entry) renderSortingWorkModeField(entry); });
  elements.week.addEventListener("change", () => { state.historyVersionId = null; loadRoster(); });
  elements.shift.addEventListener("change", () => { state.historyVersionId = null; loadRoster(); });
  elements.sunday.addEventListener("change", () => {
    if (!state.data) return;
    adjustEntriesToVisibleDays();
    const joinedStaffAdded = includeJoinedStaffInEditableRoster();
    setDirty(true);
    renderContext();
    renderGrid();
    if (joinedStaffAdded > 0) setMessage(`${joinedStaffAdded} newly joined staff member${joinedStaffAdded === 1 ? "" : "s"} became available in the visible week.`, "success");
  });
  elements.search.addEventListener("input", renderGrid);
  elements.note.addEventListener("input", () => setDirty(true));
  elements.save.addEventListener("click", () => saveRoster());
  elements.publish.addEventListener("click", publishRoster);
  elements.discard.addEventListener("click", discardDraft);
  elements.history.addEventListener("click", openHistory);
  elements.nextWeek.addEventListener("click", createNextWeek);
  elements.copy.addEventListener("click", copyPreviousWeek);
  elements.addStaff.addEventListener("click", openStaffPicker);
  elements.staffPickerSearch.addEventListener("input", renderStaffPickerList);
  elements.staffPickerIncludeOtherShift.addEventListener("change", () => {
    resetStaffPickerSelection();
    renderStaffPickerList();
  });
  elements.staffPickerOverrideConfirm.addEventListener("change", () => {
    const staff = state.staffPool.find((item) => item.staff_id === state.staffPickerSelectedId);
    const override = Boolean(staff?.default_shift_code && staff.default_shift_code !== state.data?.shift?.shift_code);
    elements.staffPickerAdd.disabled = override && !elements.staffPickerOverrideConfirm.checked;
    elements.staffPickerMessage.textContent = override && !elements.staffPickerOverrideConfirm.checked
      ? "Confirm that you reviewed the other shift before adding this temporary assignment."
      : "";
  });
  elements.staffPickerAllDays.addEventListener("click", () => elements.staffPickerDays.querySelectorAll('input[type="checkbox"]:not(:disabled)').forEach((input) => { input.checked = true; }));
  elements.staffPickerClearDays.addEventListener("click", () => elements.staffPickerDays.querySelectorAll('input[type="checkbox"]').forEach((input) => { input.checked = false; }));
  elements.staffPickerCancelSelection.addEventListener("click", resetStaffPickerSelection);
  elements.staffPickerAdd.addEventListener("click", addSelectedStaffToRoster);
  elements.staffLink.addEventListener("click", async () => { elements.linkModal.classList.remove("hidden"); elements.linkResult.classList.add("hidden"); elements.linkMessage.textContent = ""; await createStaffLink(); });
  elements.createLink.addEventListener("click", createStaffLink);
  elements.leaveRequests.addEventListener("click", () => openLeaveRequests("ACTION"));
  elements.settingsButton.addEventListener("click", () => openSettings("TARGETS"));
  elements.leavePlanningReview.addEventListener("click", () => openLeaveRequests("ACTION", "These unresolved requests overlap the roster week currently on screen."));
  elements.leaveTabs.addEventListener("click", (event) => { const button = event.target.closest("[data-leave-scope]"); if (button) openLeaveRequests(button.dataset.leaveScope); });
  elements.leaveCalendarMonth.addEventListener("change", loadLeaveCapacityCalendar);
  elements.leaveCalendarShift.addEventListener("change", loadLeaveCapacityCalendar);
  elements.leaveCalendarPrevious.addEventListener("click", () => shiftLeaveCalendarMonth(-1));
  elements.leaveCalendarNext.addEventListener("click", () => shiftLeaveCalendarMonth(1));
  elements.leaveHistorySearchInput.addEventListener("input", () => {
    clearTimeout(state.leaveHistorySearchTimer);
    state.leaveHistorySearchTimer = setTimeout(() => { if (state.leaveScope === "HISTORY") openLeaveRequests("HISTORY"); }, 280);
  });
  elements.settingsTabs.addEventListener("click", (event) => { const button = event.target.closest("[data-settings-tab]"); if (button) setSettingsTab(button.dataset.settingsTab); });
  elements.leaveSettingsSave.addEventListener("click", () => { if (state.canManageRoster) saveLeaveSettings(); });
  elements.bankHolidayAdd.addEventListener("click", addBankHoliday);
  elements.copyLink.addEventListener("click", async () => { await navigator.clipboard.writeText(elements.linkInput.value); elements.linkMessage.textContent = "Link copied."; });
  elements.quickClose.addEventListener("click", closeQuickStatusMenu);
  elements.quickDetails.addEventListener("click", () => {
    if (!state.quickKey) return;
    const [staffId, workDate] = state.quickKey.split("|");
    openDayEditor(staffId, workDate);
  });
  elements.print.addEventListener("click", beginPrint);
  window.addEventListener("beforeprint", preparePrintHeader);
  window.addEventListener("afterprint", endPrint);
  elements.legendToggle.addEventListener("click", () => { const expanded = elements.legendToggle.getAttribute("aria-expanded") === "true"; elements.legendToggle.setAttribute("aria-expanded", String(!expanded)); elements.legend.classList.toggle("hidden", expanded); });
  elements.signOut.addEventListener("click", async () => { await client.auth.signOut(); window.location.replace("../index.html"); });

  document.addEventListener("input", (event) => {
    const simulation = event.target.closest("[data-capacity-simulation-range], [data-capacity-simulation-input]");
    if (!simulation || simulation.value === "") return;
    const requested = Math.round(Number(simulation.value));
    state.capacitySimulationPercent = Math.max(50, Math.min(120, Number.isFinite(requested) ? requested : 100));
    updateCapacitySimulationDom();
  });

  document.addEventListener("change", (event) => {
    const mopDecision = event.target.closest("[data-sorting-mop-decision]");
    if (mopDecision && isEditable()) {
      setSortingMopDecision(mopDecision.dataset.sortingMopDecision, mopDecision.value);
      return;
    }
    const selector = event.target.closest("[data-display-section-staff]");
    if (!selector || !isEditable()) return;
    const staff = state.staff.find((item) => item.staff_id === selector.dataset.displaySectionStaff);
    const section = DISPLAY_SECTIONS.find((item) => item.code === selector.value);
    if (!staff || !section) return;
    state.layouts.set(staff.staff_id, section.code);
    const changedAssignments = syncBaseAssignmentsForStaff(staff, section.code, { resetDailyOverrides: true });
    setDirty(true);
    renderGrid();
    if (section.code === "SUPPORT_ROLE") {
      setMessage(`${staff.display_name} moved to Support Role. Daily Working assignments can now be mixed between authorised production locations.`, "success");
    } else if (isFinishTableStation(section.code)) {
      setMessage(`${staff.display_name} moved to ${section.label}. ${changedAssignments} Working/QA day assignment${changedAssignments === 1 ? "" : "s"} reset to this table. Individual days can still be moved to Table 1, Table 2 or Table 3.`, "success");
    } else {
      setMessage(`${staff.display_name} moved to ${section.label}. ${changedAssignments} Working/QA day assignment${changedAssignments === 1 ? "" : "s"} aligned with this weekly role.`, "success");
    }
  });

  document.addEventListener("click", (event) => {
    const pickerCandidate = event.target.closest("[data-select-staff-pool]");
    if (pickerCandidate) {
      const staff = state.staffPool.find((item) => item.staff_id === pickerCandidate.dataset.selectStaffPool);
      if (staff) renderStaffPickerSelection(staff);
      return;
    }
    const removeOverride = event.target.closest("[data-remove-shift-override]");
    if (removeOverride) {
      removeShiftOverride(removeOverride.dataset.removeShiftOverride);
      return;
    }
    const day = event.target.closest("[data-edit-day]");
    if (day) {
      const [staffId, workDate] = day.dataset.editDay.split("|");
      openQuickStatusMenu(staffId, workDate, day);
      return;
    }
    const quickStatus = event.target.closest("#rosterQuickStatusOptions [data-status-choice]");
    if (quickStatus) { applyQuickStatus(quickStatus.dataset.statusChoice); return; }
    if (!elements.quickMenu.classList.contains("hidden") && !event.target.closest("#rosterQuickStatusMenu")) closeQuickStatusMenu();
    if (event.target.closest("[data-roster-close-modal]")) closeDayModal();
    if (event.target.closest("[data-roster-close-staff-picker]")) closeStaffPicker();
    if (event.target.closest("[data-roster-close-history]")) closeHistory();
    if (event.target.closest("[data-roster-close-link]")) closeLink();
    if (event.target.closest("[data-roster-close-leave-requests]")) elements.leaveRequestsModal.classList.add("hidden");
    if (event.target.closest("[data-roster-close-settings]")) elements.settingsModal.classList.add("hidden");
    const capacitySimulationReset = event.target.closest("[data-capacity-simulation-reset]");
    if (capacitySimulationReset) {
      state.capacitySimulationPercent = 100;
      updateCapacitySimulationDom();
      return;
    }
    const capacityToggle = event.target.closest("[data-capacity-toggle]");
    if (capacityToggle) {
      state.capacityCollapsed = !state.capacityCollapsed;
      try { window.localStorage.setItem("eliscaretex.roster.capacity.collapsed", state.capacityCollapsed ? "1" : "0"); } catch (_) {}
      renderGrid();
      return;
    }
    const saveTarget = event.target.closest("[data-save-target]");
    if (saveTarget) { saveProductionTarget(saveTarget.dataset.saveTarget); return; }
    const removeBankHolidayButton = event.target.closest("[data-remove-bank-holiday]");
    if (removeBankHolidayButton) { removeBankHoliday(removeBankHolidayButton.dataset.removeBankHoliday); return; }
    const leaveDecision = event.target.closest("[data-leave-decision]");
    if (leaveDecision && state.canApproveLeave) { decideLeaveRequest(leaveDecision.dataset.leaveRequestId, leaveDecision.dataset.leaveDecision); return; }
    const leaveSendGm = event.target.closest("[data-leave-send-gm]");
    if (leaveSendGm && state.canApproveLeave) { sendLeaveRequestToGeneralManager(leaveSendGm.dataset.leaveSendGm); return; }
    const leaveHistory = event.target.closest("[data-leave-history-toggle]");
    if (leaveHistory) { toggleLeaveHistory(leaveHistory.dataset.leaveHistoryToggle); return; }
    const versionButton = event.target.closest("[data-open-roster-version]"); if (versionButton) { closeHistory(); loadRoster({ force: true, versionId: versionButton.dataset.openRosterVersion }); }
    if (event.target.closest("[data-open-current-roster]")) { closeHistory(); state.historyVersionId = null; loadRoster({ force: true }); }
  });

  async function refreshLeaveWorkflow() {
    if (document.hidden || state.loading || !state.data?.can_manage || isHistorical()) return;
    await refreshLeaveRequestBadge();
    await refreshPendingLeaveOverlay();
    await refreshApprovedLeaveOverlay();
  }

  async function pollLeaveRevision(force = false) {
    if (document.hidden || state.loading || !state.data?.can_manage || isHistorical()) return;
    try {
      const revision = await rpc("get_production_roster_leave_revision");
      if (!state.leaveRevision) { state.leaveRevision = revision || "0"; if (!force) return; }
      if (!force && revision === state.leaveRevision) return;
      state.leaveRevision = revision || state.leaveRevision;
      await refreshLeaveWorkflow();
      const modalOpen = !elements.leaveRequestsModal.classList.contains("hidden");
      const searchFocused = document.activeElement === elements.leaveHistorySearchInput;
      if (modalOpen && !searchFocused) await openLeaveRequests(state.leaveScope, "Leave requests updated automatically.");
    } catch (error) {
      console.warn("Leave request revision check failed.", error);
    }
  }
  setInterval(() => pollLeaveRevision(false), 20000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) pollLeaveRevision(true); });

  window.addEventListener("beforeunload", (event) => { if (state.dirty) { event.preventDefault(); event.returnValue = ""; } });
  window.addEventListener("resize", closeQuickStatusMenu);
  document.addEventListener("scroll", closeQuickStatusMenu, true);
  document.addEventListener("keydown", (event) => {
    if (!elements.quickMenu.classList.contains("hidden")) {
      if (event.key === "Escape") { event.preventDefault(); closeQuickStatusMenu(); return; }
      if (event.key.toLowerCase() === "e") {
        event.preventDefault();
        elements.quickDetails.click();
        return;
      }
      const statusCode = STATUS_SHORTCUTS[event.key.toUpperCase()];
      if (statusCode) { event.preventDefault(); applyQuickStatus(statusCode); return; }
    }
    if (event.key === "Escape" && !elements.settingsModal.classList.contains("hidden")) { elements.settingsModal.classList.add("hidden"); return; }
    if (event.key === "Escape" && !elements.leaveRequestsModal.classList.contains("hidden")) { elements.leaveRequestsModal.classList.add("hidden"); return; }
    if (event.key === "Escape" && !elements.staffPickerModal.classList.contains("hidden")) { closeStaffPicker(); return; }
    if (event.key === "Escape" && !elements.dayModal.classList.contains("hidden")) { closeDayModal(); return; }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") { event.preventDefault(); if (isEditable()) saveRoster(); }
  });

  initialize();
});
