"use strict";

const ROSTER_VIEW = {
  token: "",
  authenticated: false,
  data: null,
  shiftCode: "MORNING",
  shiftData: null,
  currentWeek: null,
  nextWeek: null,
  showingNext: false,
  search: "",
};

const PLANNED_STATUSES = new Set(["WORKING", "QUALITY_ANALYSIS", "TRAINING"]);
const SECTION_ORDER = ["SUPERVISOR", "SORTING_AREA", "LABEL", "FINISH_TABLE_1", "FINISH_TABLE_2", "FINISH_TABLE_3", "FINISH_OTHER", "CLEANER", "SUPPORT_ROLE"];
const SECTION_META = {
  SUPERVISOR: { label: "Supervisor", icon: "♛", className: "supervisor" },
  SORTING_AREA: { label: "Sorting Area", icon: "↻", className: "sorting" },
  LABEL: { label: "Label", icon: "▣", className: "label" },
  FINISH_TABLE_1: { label: "Table 1", icon: "①", className: "table" },
  FINISH_TABLE_2: { label: "Table 2", icon: "②", className: "table" },
  FINISH_TABLE_3: { label: "Table 3", icon: "③", className: "table" },
  FINISH_OTHER: { label: "Finish Area", icon: "◇", className: "finish" },
  CLEANER: { label: "Cleaner", icon: "✦", className: "cleaner" },
  SUPPORT_ROLE: { label: "Support Role", icon: "●", className: "support" },
};
const STATUS_META = {
  WORKING: { label: "Work", className: "working" },
  COVER: { label: "Cover", className: "cover" },
  OFF: { label: "Off", className: "off" },
  SICK: { label: "Sick", className: "sick" },
  HOLIDAY: { label: "Hol", className: "holiday" },
  TRAINING: { label: "Train", className: "training" },
  QUALITY_ANALYSIS: { label: "QA", className: "quality" },
};
const SCHEDULES = {
  MORNING: [
    { days: "Monday to Wednesday", hours: ["06:00–15:00", "07:00–16:00"], breakMinutes: 45 },
    { days: "Thursday and Friday", hours: ["06:00–14:00", "07:00–15:00"], breakMinutes: 45 },
    { days: "Saturday / Bank Holiday (Monday)", hours: ["07:00–15:00"], breakMinutes: 45 },
  ],
  EVENING: [
    { days: "Monday to Wednesday", hours: ["15:00–23:20"], breakMinutes: 30 },
    { days: "Thursday and Friday", hours: ["14:00–23:20"], breakMinutes: 45 },
    { days: "Saturday / Bank Holiday (Monday)", hours: ["15:00–22:30"], breakMinutes: 30 },
  ],
};

const nodes = {};

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[char]));
}

function localIsoDate(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function currentMondayIso() {
  const date = new Date();
  date.setHours(0, 0, 0, 0);
  const day = date.getDay() || 7;
  date.setDate(date.getDate() - day + 1);
  return localIsoDate(date);
}

function nextMondayIso() {
  const date = new Date();
  date.setHours(0, 0, 0, 0);
  const day = date.getDay() || 7;
  date.setDate(date.getDate() + (8 - day));
  return localIsoDate(date);
}

function addDays(iso, amount) {
  const date = new Date(`${iso}T12:00:00`);
  date.setDate(date.getDate() + amount);
  return localIsoDate(date);
}

function formatShortDate(iso) {
  return new Intl.DateTimeFormat("en-IE", { day: "2-digit", month: "short" }).format(new Date(`${iso}T12:00:00`));
}

function formatPublished(value) {
  if (!value) return "";
  return new Intl.DateTimeFormat("en-IE", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function weekLabel(week) { return `${formatShortDate(week.week_start)} – ${formatShortDate(week.week_end)}`; }

function dayList(week) {
  const count = week.include_sunday ? 7 : 6;
  return Array.from({ length: count }, (_, index) => {
    const iso = addDays(week.week_start, index);
    const date = new Date(`${iso}T12:00:00`);
    return {
      iso,
      dow: new Intl.DateTimeFormat("en-IE", { weekday: "short" }).format(date),
      date: new Intl.DateTimeFormat("en-IE", { day: "2-digit" }).format(date),
    };
  });
}

function effectiveStatus(entry) { return entry?.assignment_type === "COVER" ? "COVER" : (entry?.day_status || "OFF"); }
function isPlanned(entry) { return entry?.assignment_type === "COVER" || PLANNED_STATUSES.has(entry?.day_status); }

function initials(name) {
  return String(name || "").trim().split(/\s+/).slice(0, 2).map((part) => part.charAt(0)).join("").toUpperCase();
}

function compactStation(entry, useDefault = false) {
  const code = String(useDefault ? entry.staff_default_station_code : entry.station_code || "").toUpperCase();
  const name = String(useDefault ? entry.staff_default_station_name : entry.station_name || "");
  const match = `${code} ${name}`.match(/TABLE[_\s-]*(\d+)/i);
  if (match) return `T${match[1]}`;
  return name || code.replaceAll("_", " ");
}

function fullStationLabel(entry) {
  const code = String(entry?.station_code || "").toUpperCase();
  const name = String(entry?.station_name || "");
  const match = `${code} ${name}`.match(/TABLE[_\s-]*(\d+)/i);
  if (match) return `Table ${match[1]}`;
  return name || code.replaceAll("_", " ");
}

function sameAssignmentLabel(left, right) {
  const normalize = (value) => String(value || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  return Boolean(normalize(left) && normalize(left) === normalize(right));
}

function roleMeta(code, name) {
  const normalized = String(code || "").toUpperCase();
  const label = name || normalized.replaceAll("_", " ");
  if (normalized === "TEAM_LEADER") return { label: "Team Leader", className: "team-leader" };
  if (normalized === "SUPERVISOR") return { label: "Supervisor", className: "supervisor" };
  if (normalized === "SORTING_AREA") return { label: "Sorting Area", className: "sorting" };
  if (normalized === "LABEL") return { label: "Label", className: "label" };
  if (normalized === "CLEANER") return { label: "Cleaner", className: "cleaner" };
  if (normalized === "GENERAL_OPERATIVE") return { label: "General Operative", className: "general" };
  if (normalized === "SUPPORT_ROLE") return { label: "Support Role", className: "support" };
  return { label: label || "Assigned", className: "other" };
}

function inferSection(entry) {
  const explicit = String(entry.display_section_code || "").toUpperCase();
  if (SECTION_META[explicit]) return explicit;
  const role = String(entry.staff_primary_role_code || "").toUpperCase();
  if (["SUPERVISOR", "SORTING_AREA", "LABEL", "CLEANER", "SUPPORT_ROLE"].includes(role)) return role;
  const table = compactStation(entry, true).match(/^T([123])$/);
  return table ? `FINISH_TABLE_${table[1]}` : "FINISH_OTHER";
}

function groupPeople(week) {
  const people = new Map();
  (week.entries || []).forEach((entry) => {
    if (!people.has(entry.staff_id)) {
      people.set(entry.staff_id, {
        staffId: entry.staff_id,
        name: entry.display_name || "Staff member",
        section: inferSection(entry),
        primaryRoleCode: entry.staff_primary_role_code,
        primaryRoleName: entry.staff_primary_role_name,
        defaultStationCode: entry.staff_default_station_code,
        defaultStationName: entry.staff_default_station_name,
        defaultShiftCode: entry.staff_default_shift_code,
        defaultShiftName: entry.staff_default_shift_name,
        rosterShiftCode: entry.roster_shift_code,
        rosterShiftName: entry.roster_shift_name,
        fireTraining: entry.fire_training === true,
        firstAidTraining: entry.first_aid_training === true,
        eodCapable: entry.eod_capable === true,
        entries: new Map(),
      });
    }
    people.get(entry.staff_id).entries.set(entry.work_date, entry);
  });
  return [...people.values()];
}

function trainingBadges(person) {
  const badges = [];
  if (person.fireTraining) badges.push('<span class="rv-cap-badge fire" title="Fire training" aria-label="Fire training"><svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M13.5 2.2c.7 3.1-.5 4.5-1.8 5.8-1 1-1.8 1.9-1.5 3.5.7-.5 1.3-1.2 1.7-2.1 2.7 1.8 4.1 4.2 4.1 6.6A4 4 0 0 1 12 20a4 4 0 0 1-4-4c0-2.3 1.2-4.2 3.2-6.1-.1 2 .7 3.1 1.8 3.7-.4-2.1.5-3.4 1.6-4.8 1.2-1.5 2.4-3.2-1.1-6.6Z"/></svg></span>');
  if (person.firstAidTraining) badges.push('<span class="rv-cap-badge first-aid" title="First Aid training" aria-label="First Aid training"><svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M8.4 5.6a4 4 0 0 1 5.7 0l4.3 4.3a4 4 0 0 1 0 5.7l-2.8 2.8a4 4 0 0 1-5.7 0l-4.3-4.3a4 4 0 0 1 0-5.7l2.8-2.8Zm2.2 2.1-1.4 1.4 2.1 2.1-2.1 2.1 1.4 1.4 2.1-2.1 2.1 2.1 1.4-1.4-2.1-2.1 2.1-2.1-1.4-1.4-2.1 2.1-2.1-2.1Z"/></svg></span>');
  if (person.eodCapable) badges.push('<span class="rv-cap-badge eod" title="EOD capable">EOD</span>');
  return badges.length ? `<span class="rv-cap-badges">${badges.join("")}</span>` : "";
}

function roleBadge(person) {
  const role = roleMeta(person.primaryRoleCode, person.primaryRoleName);
  return `<span class="rv-role-badge ${role.className}">${escapeHtml(role.label)}</span>`;
}

function shiftOverrideBadge(person) {
  const from = String(person.defaultShiftCode || "").toUpperCase();
  const to = String(person.rosterShiftCode || ROSTER_VIEW.shiftCode).toUpperCase();
  if (!from || !to || from === to) return "";
  const fromName = person.defaultShiftName || from.replaceAll("_", " ");
  const toName = person.rosterShiftName || to.replaceAll("_", " ");
  return `<span class="rv-shift-override">${escapeHtml(fromName)} → ${escapeHtml(toName)}</span>`;
}

function buildDayCell(person, day) {
  const entry = person.entries.get(day.iso) || null;
  const statusCode = effectiveStatus(entry);
  const status = STATUS_META[statusCode] || STATUS_META.OFF;
  const todayClass = day.iso === localIsoDate() ? " today" : "";
  let details = "";

  if (entry && !["OFF", "SICK", "HOLIDAY", "TRAINING"].includes(statusCode)) {
    const role = roleMeta(entry.operational_role_code, entry.operational_role_name);
    const station = compactStation(entry);
    const fullStation = fullStationLabel(entry);
    const roleCode = String(entry.operational_role_code || "").toUpperCase();
    const sortingWorkMode = String(entry.sorting_work_mode || "").toUpperCase();
    const defaultStation = compactStation({ staff_default_station_code: person.defaultStationCode, staff_default_station_name: person.defaultStationName }, true);
    const showRole = statusCode === "COVER" || statusCode === "QUALITY_ANALYSIS" || !["GENERAL_OPERATIVE", ""].includes(roleCode);
    const teamLeaderCover = statusCode === "COVER" && roleCode === "TEAM_LEADER";
    const roleLabel = teamLeaderCover && fullStation ? `${role.label} · ${fullStation}` : role.label;

    if (showRole) {
      const coverEmphasis = statusCode === "COVER" && ["TEAM_LEADER", "SUPERVISOR"].includes(roleCode);
      details += `<div class="rv-day-role ${role.className}${coverEmphasis ? " cover-emphasis" : ""}" title="${escapeHtml(roleLabel)}">${escapeHtml(roleLabel)}</div>`;
    }

    const duplicateAssignment = showRole && sameAssignmentLabel(role.label, fullStation || station);
    if (station && !teamLeaderCover && !duplicateAssignment) {
      details += `<div class="rv-day-table${defaultStation && station !== defaultStation ? " different" : ""}">${escapeHtml(station)}</div>`;
    }
    if (sortingWorkMode === "MOP") {
      details += '<div class="rv-sorting-mode mop">MOP</div>';
    }
  }

  return `<div class="rv-day${todayClass}"><div class="rv-day-head"><span class="rv-day-dow">${escapeHtml(day.dow)}</span><span class="rv-day-date">${escapeHtml(day.date)}</span></div><div class="rv-day-body"><div class="rv-status ${status.className}">${escapeHtml(status.label)}</div>${details}</div></div>`;
}

function buildCard(person, days) {
  const plannedDays = days.reduce((total, day) => total + (isPlanned(person.entries.get(day.iso)) ? 1 : 0), 0);
  const isTeamLeader = String(person.primaryRoleCode || "").toUpperCase() === "TEAM_LEADER";
  const defaultStation = compactStation({ staff_default_station_code: person.defaultStationCode, staff_default_station_name: person.defaultStationName }, true);
  return `<article class="rv-card${isTeamLeader ? " is-team-leader" : ""}" data-name="${escapeHtml(person.name.toLowerCase())}"><header class="rv-card-head"><div class="rv-avatar${ROSTER_VIEW.shiftCode === "EVENING" ? " evening" : ""}">${escapeHtml(initials(person.name))}</div><div class="rv-card-info"><div class="rv-card-name-line"><strong class="rv-card-name">${escapeHtml(person.name)}</strong>${trainingBadges(person)}</div><div class="rv-default-row">${roleBadge(person)}${defaultStation ? `<span class="rv-table-badge">${escapeHtml(defaultStation)}</span>` : ""}${shiftOverrideBadge(person)}</div></div><span class="rv-workdays" title="Planned days this week">${plannedDays}d</span></header><div class="rv-days-grid" style="grid-template-columns:repeat(${days.length},minmax(0,1fr))">${days.map((day) => buildDayCell(person, day)).join("")}</div></article>`;
}

function renderSchedule() {
  const schedule = SCHEDULES[ROSTER_VIEW.shiftCode] || SCHEDULES.MORNING;
  nodes.schedule.hidden = false;
  nodes.scheduleDot.classList.toggle("evening", ROSTER_VIEW.shiftCode === "EVENING");
  nodes.scheduleBody.innerHTML = schedule.map((group) => `<div class="rv-sched-group"><div class="rv-sched-days">${escapeHtml(group.days)}</div><div class="rv-sched-hours">${group.hours.map((hours) => `<span class="rv-sched-hour">${escapeHtml(hours)}</span>`).join("")}<span class="rv-sched-break">Break ${Math.floor(group.breakMinutes / 60)}:${String(group.breakMinutes % 60).padStart(2, "0")}</span></div></div>`).join("");
}

function renderNextBar() {
  if (!ROSTER_VIEW.nextWeek) { nodes.nextBar.classList.remove("show"); return; }
  nodes.nextWeekLabel.textContent = weekLabel(ROSTER_VIEW.nextWeek);
  nodes.nextButton.textContent = ROSTER_VIEW.showingNext ? "Back to current week" : "Preview";
  nodes.nextButton.classList.toggle("back", ROSTER_VIEW.showingNext);
  nodes.nextBar.classList.add("show");
}

function renderTodayBanner(week, people, days) {
  const today = localIsoDate();
  const day = days.find((item) => item.iso === today);
  if (!day || ROSTER_VIEW.showingNext) { nodes.todayBanner.classList.add("hidden"); return; }
  const planned = people.reduce((total, person) => total + (isPlanned(person.entries.get(today)) ? 1 : 0), 0);
  nodes.todayText.textContent = `Today: ${day.dow} — ${planned} staff planned`;
  nodes.todayBanner.classList.toggle("evening", ROSTER_VIEW.shiftCode === "EVENING");
  nodes.todayBanner.classList.remove("hidden");
}

function renderShiftTabs() {
  nodes.shiftTabs.querySelectorAll("[data-rv-shift]").forEach((button) => {
    const active = button.dataset.rvShift === ROSTER_VIEW.shiftCode;
    button.classList.toggle("active", active);
    button.disabled = !(ROSTER_VIEW.data?.shifts || []).some((shift) => String(shift.shift_code).toUpperCase() === button.dataset.rvShift);
  });
}

function render() {
  const week = ROSTER_VIEW.showingNext ? ROSTER_VIEW.nextWeek : ROSTER_VIEW.currentWeek;
  document.body.classList.toggle("next-week-mode", ROSTER_VIEW.showingNext);
  nodes.header.className = `rv-header ${ROSTER_VIEW.showingNext ? "preview" : (ROSTER_VIEW.shiftCode === "EVENING" ? "evening" : "morning")}`;
  renderShiftTabs();
  renderNextBar();

  if (!week) {
    nodes.weekLabel.textContent = `${ROSTER_VIEW.shiftData?.shift_name || ROSTER_VIEW.shiftCode} roster`;
    nodes.pubInfo.textContent = "No current published roster";
    nodes.todayBanner.classList.add("hidden");
    nodes.main.innerHTML = '<div class="rv-empty"><strong>No published roster</strong><span>No current roster has been published for this shift. Use the next-week preview when available.</span></div>';
    return;
  }

  const days = dayList(week);
  const query = ROSTER_VIEW.search.trim().toLowerCase();
  const allPeople = groupPeople(week);
  const people = allPeople.filter((person) => !query || person.name.toLowerCase().includes(query));
  const plannedSlots = allPeople.reduce((total, person) => total + days.reduce((sum, day) => sum + (isPlanned(person.entries.get(day.iso)) ? 1 : 0), 0), 0);
  const unavailablePeople = allPeople.filter((person) => days.some((day) => ["SICK", "HOLIDAY"].includes(person.entries.get(day.iso)?.day_status))).length;

  nodes.weekLabel.textContent = `${ROSTER_VIEW.showingNext ? "NEXT WEEK" : "Week"}: ${weekLabel(week)}`;
  nodes.pubInfo.textContent = ROSTER_VIEW.showingNext ? "Future published week preview" : `Published ${formatPublished(week.published_at)} · Version ${Number(week.version_number || 0)}`;
  renderTodayBanner(week, allPeople, days);

  const sectionMap = new Map(SECTION_ORDER.map((section) => [section, []]));
  people.forEach((person) => {
    const section = SECTION_META[person.section] ? person.section : "SUPPORT_ROLE";
    sectionMap.get(section).push(person);
  });

  let html = '<div class="rv-content">';
  html += `<div class="rv-summary"><div class="rv-summary-card"><div class="rv-summary-number">${allPeople.length}</div><div class="rv-summary-label">Staff</div></div><div class="rv-summary-card"><div class="rv-summary-number">${plannedSlots}</div><div class="rv-summary-label">Planned slots</div></div><div class="rv-summary-card"><div class="rv-summary-number">${unavailablePeople}</div><div class="rv-summary-label">Sick / Holiday</div></div></div>`;
  if (week.week_note) html += `<div class="rv-week-note">${escapeHtml(week.week_note)}</div>`;

  SECTION_ORDER.forEach((section) => {
    const sectionPeople = sectionMap.get(section) || [];
    if (!sectionPeople.length) return;
    const meta = SECTION_META[section];
    sectionPeople.sort((a, b) => {
      const aLeader = String(a.primaryRoleCode || "").toUpperCase() === "TEAM_LEADER" ? 0 : 1;
      const bLeader = String(b.primaryRoleCode || "").toUpperCase() === "TEAM_LEADER" ? 0 : 1;
      return aLeader - bLeader || a.name.localeCompare(b.name);
    });
    html += `<section class="rv-sector"><header class="rv-sector-head ${meta.className}"><span class="rv-sector-icon">${meta.icon}</span><span class="rv-sector-title">${escapeHtml(meta.label)}</span><span class="rv-sector-count">${sectionPeople.length}</span></header>${sectionPeople.map((person) => buildCard(person, days)).join("")}</section>`;
  });

  if (!people.length) html += '<div class="rv-empty"><strong>No staff found</strong><span>Try another name.</span></div>';
  html += "</div>";
  nodes.main.innerHTML = html;
}

function selectShift(shiftCode) {
  const code = String(shiftCode || "MORNING").toUpperCase();
  const shift = (ROSTER_VIEW.data?.shifts || []).find((item) => String(item.shift_code).toUpperCase() === code);
  if (!shift) return;
  ROSTER_VIEW.shiftCode = code;
  ROSTER_VIEW.shiftData = shift;
  ROSTER_VIEW.showingNext = false;
  const weeks = [...(shift.weeks || [])].sort((a, b) => String(a.week_start).localeCompare(String(b.week_start)));
  const currentMonday = currentMondayIso();
  ROSTER_VIEW.currentWeek = weeks.find((week) => week.week_start === currentMonday) || null;
  ROSTER_VIEW.nextWeek = weeks.find((week) => week.week_start > currentMonday) || null;
  const theme = document.querySelector('meta[name="theme-color"]');
  if (theme) theme.content = code === "EVENING" ? "#6d28d9" : "#1e40af";
  renderSchedule();
  render();
}

async function portalRpc(name, args = {}) {
  if (!window.elisSupabase) throw new Error("The roster service is not available.");
  const { data, error } = await window.elisSupabase.rpc(name, args);
  if (error) throw error;
  return data;
}

async function loadRoster() {
  const token = new URLSearchParams(window.location.search).get("t") || "";
  if (token) {
    ROSTER_VIEW.token = token;
    ROSTER_VIEW.data = await portalRpc("get_published_production_roster_portal", { p_token: token });
  } else {
    const { data } = await window.elisSupabase.auth.getSession();
    if (!data.session) { window.location.replace("../index.html"); return; }
    ROSTER_VIEW.authenticated = true;
    ROSTER_VIEW.data = await portalRpc("get_my_account_roster_portal");
    document.querySelector("h1").textContent = "My Roster";
    nodes.search.closest(".rv-search-wrap").hidden = true;
  }
  const shifts = ROSTER_VIEW.data?.shifts || [];
  const first = shifts.find((shift) => String(shift.shift_code).toUpperCase() === "MORNING") || shifts[0];
  if (!first) throw new Error("No Production Roster shifts are available.");
  selectShift(first.shift_code);
}

function portalStaffOptions() {
  const people = new Map();
  if (ROSTER_VIEW.authenticated && ROSTER_VIEW.data?.staff?.staff_id) {
    people.set(ROSTER_VIEW.data.staff.staff_id, ROSTER_VIEW.data.staff.display_name || "Staff member");
  }
  (ROSTER_VIEW.data?.shifts || []).forEach((shift) => (shift.weeks || []).forEach((week) => (week.entries || []).forEach((entry) => {
    if (entry.staff_id && !people.has(entry.staff_id)) people.set(entry.staff_id, entry.display_name || "Staff member");
  })));
  return [...people.entries()].map(([staffId, name]) => ({ staffId, name })).sort((a, b) => a.name.localeCompare(b.name));
}

function setLeaveMessage(text = "", kind = "") {
  nodes.leaveMessage.textContent = text;
  nodes.leaveMessage.className = `rv-leave-msg${kind ? ` ${kind}` : ""}`;
}

let portalToastTimer = null;
function showPortalToast(message, kind = "ok") {
  if (!nodes.toast) return;
  nodes.toast.textContent = message;
  nodes.toast.className = `rv-toast show ${kind}`;
  clearTimeout(portalToastTimer);
  portalToastTimer = setTimeout(() => { nodes.toast.className = "rv-toast"; }, 5200);
}

function updateLeaveType() {
  const holiday = nodes.leaveType.value === "HOLIDAY";
  nodes.leaveEndField.hidden = !holiday;
  nodes.leaveStartLabel.textContent = holiday ? "Start date" : "Date";
  if (!holiday) nodes.leaveEnd.value = nodes.leaveStart.value;
}

function applyLeaveDateRules() {
  const today = new Date();
  const isoDay = today.getDay() || 7;
  const nextMonday = nextMondayIso();
  const minimum = isoDay > 4 ? addDays(nextMonday, 7) : nextMonday;
  nodes.leaveStart.min = minimum;
  nodes.leaveEnd.min = nodes.leaveStart.value || minimum;
  nodes.leaveRule.textContent = isoDay > 4
    ? "Requests for next week are closed after Thursday. You can request dates from the following week onward."
    : "Requests can be submitted for next week or later. Requests for next week close after Thursday.";
}

async function loadMyLeaveRequests() {
  const staffId = nodes.leaveStaff.value;
  if (!staffId) { nodes.myLeaveRequests.innerHTML = ""; return; }
  try {
    const list = ROSTER_VIEW.authenticated
      ? await portalRpc("get_my_account_leave_requests")
      : await portalRpc("get_my_production_roster_leave_requests", { p_token: ROSTER_VIEW.token, p_staff_id: staffId });
    if (!Array.isArray(list) || !list.length) { nodes.myLeaveRequests.innerHTML = ""; return; }
    const oneMonthAgo = new Date();
    oneMonthAgo.setMonth(oneMonthAgo.getMonth() - 1);
    const recent = list.filter((item) => {
      const submitted = new Date(item?.submitted_at || 0);
      return !Number.isNaN(submitted.getTime()) && submitted >= oneMonthAgo;
    }).slice(0, 3);
    if (!recent.length) { nodes.myLeaveRequests.innerHTML = ""; return; }
    nodes.myLeaveRequests.innerHTML = `<div class="rv-mine-title">RECENT REQUESTS · LAST MONTH</div>${recent.map((item) => {
      const type = item.request_type === "HOLIDAY" ? "Holiday" : "Day Off";
      const range = item.end_date && item.end_date !== item.start_date ? `${item.start_date} – ${item.end_date}` : item.start_date;
      const workflow = String(item.workflow_status || item.status || "PENDING").toUpperCase();
      const workflowLabel = workflow === "AWAITING_GENERAL_MANAGER" ? "Awaiting General Manager" : workflow === "GENERAL_MANAGER_EMAIL_FAILED" ? "GM email pending" : workflow.charAt(0) + workflow.slice(1).toLowerCase();
      const badgeClass = workflow === "AWAITING_GENERAL_MANAGER" ? "awaiting_general_manager" : workflow === "GENERAL_MANAGER_EMAIL_FAILED" ? "gm_email_failed" : String(item.status || "PENDING").toLowerCase();
      return `<div class="rv-mine-item"><span>${escapeHtml(type)} · ${escapeHtml(range)}</span><span class="rv-mine-badge ${badgeClass}">${escapeHtml(workflowLabel)}</span></div>`;
    }).join("")}`;
  } catch (error) {
    nodes.myLeaveRequests.innerHTML = "";
  }
}

async function openLeaveForm() {
  const people = portalStaffOptions();
  nodes.leaveStaff.innerHTML = '<option value="">Select your name…</option>' + people.map((person) => `<option value="${escapeHtml(person.staffId)}">${escapeHtml(person.name)}</option>`).join("");
  if (ROSTER_VIEW.authenticated && people.length === 1) {
    nodes.leaveStaff.value = people[0].staffId;
    nodes.leaveStaff.disabled = true;
    await loadMyLeaveRequests();
  } else nodes.leaveStaff.disabled = false;
  nodes.leaveType.value = "DAY_OFF";
  nodes.leaveStart.value = "";
  nodes.leaveEnd.value = "";
  nodes.leaveReason.value = "";
  nodes.myLeaveRequests.innerHTML = "";
  setLeaveMessage();
  updateLeaveType();
  applyLeaveDateRules();
  nodes.leaveOverlay.classList.add("show");
  nodes.leaveOverlay.setAttribute("aria-hidden", "false");
}

function closeLeaveForm() {
  nodes.leaveOverlay.classList.remove("show");
  nodes.leaveOverlay.setAttribute("aria-hidden", "true");
}

async function submitLeaveRequest() {
  const staffId = nodes.leaveStaff.value;
  const requestType = nodes.leaveType.value;
  const start = nodes.leaveStart.value;
  const end = requestType === "HOLIDAY" ? nodes.leaveEnd.value : start;
  const reason = nodes.leaveReason.value.trim();
  if (!staffId) { setLeaveMessage("Please select your name.", "err"); return; }
  if (!start) { setLeaveMessage("Please choose a date.", "err"); return; }
  if (requestType === "HOLIDAY" && !end) { setLeaveMessage("Please choose an end date.", "err"); return; }
  if (end < start) { setLeaveMessage("End date is before start date.", "err"); return; }
  const nextMonday = nextMondayIso();
  const isoDay = new Date().getDay() || 7;
  if (start < nextMonday) { setLeaveMessage("Requests can only be submitted for next week or later.", "err"); return; }
  if (isoDay > 4 && start < addDays(nextMonday, 7)) { setLeaveMessage("Requests for next week are closed after Thursday. Please choose a later date.", "err"); return; }

  nodes.leaveSubmit.disabled = true;
  setLeaveMessage("Submitting request…");
  try {
    const result = await portalRpc(ROSTER_VIEW.authenticated ? "submit_my_account_leave_request" : "submit_production_roster_leave_request", {
      ...(ROSTER_VIEW.authenticated ? {} : { p_token: ROSTER_VIEW.token, p_staff_id: staffId }),
      p_request_type: requestType,
      p_start_date: start,
      p_end_date: end || null,
      p_reason: reason || null,
    });
    const successMessage = result?.requires_general_manager
      ? `Request sent. Holidays longer than ${Number(result.general_manager_threshold_days || 20)} days require General Manager approval.`
      : "Request sent successfully. A manager will review it.";
    nodes.leaveReason.value = "";
    closeLeaveForm();
    showPortalToast(successMessage, "ok");
  } catch (error) {
    setLeaveMessage(error?.message || "Could not submit the request.", "err");
  } finally {
    nodes.leaveSubmit.disabled = false;
  }
}

function showError(error) {
  nodes.main.innerHTML = `<div class="rv-message error">${escapeHtml(error?.message || "The published roster could not be loaded.")}</div>`;
  nodes.todayBanner.classList.add("hidden");
  nodes.nextBar.classList.remove("show");
  nodes.schedule.hidden = true;
}

document.addEventListener("DOMContentLoaded", async () => {
  nodes.header = document.getElementById("rvHeader");
  nodes.toast = document.getElementById("rvToast");
  nodes.weekLabel = document.getElementById("rvWeekLabel");
  nodes.pubInfo = document.getElementById("rvPubInfo");
  nodes.shiftTabs = document.getElementById("rvShiftTabs");
  nodes.search = document.getElementById("rvSearch");
  nodes.schedule = document.getElementById("rvSchedule");
  nodes.scheduleToggle = document.getElementById("rvScheduleToggle");
  nodes.scheduleBody = document.getElementById("rvScheduleBody");
  nodes.scheduleDot = document.getElementById("rvScheduleDot");
  nodes.todayBanner = document.getElementById("rvTodayBanner");
  nodes.todayText = document.getElementById("rvTodayText");
  nodes.nextBar = document.getElementById("rvNextBar");
  nodes.nextWeekLabel = document.getElementById("rvNextWeekLabel");
  nodes.nextButton = document.getElementById("rvNextButton");
  nodes.main = document.getElementById("rvMain");
  nodes.leaveButton = document.getElementById("rvLeaveButton");
  nodes.leaveOverlay = document.getElementById("rvLeaveOverlay");
  nodes.leaveClose = document.getElementById("rvLeaveClose");
  nodes.leaveCancel = document.getElementById("rvLeaveCancel");
  nodes.leaveSubmit = document.getElementById("rvLeaveSubmit");
  nodes.leaveRule = document.getElementById("rvLeaveRule");
  nodes.leaveStaff = document.getElementById("rvLeaveStaff");
  nodes.leaveType = document.getElementById("rvLeaveType");
  nodes.leaveStart = document.getElementById("rvLeaveStart");
  nodes.leaveStartLabel = document.getElementById("rvLeaveStartLabel");
  nodes.leaveEndField = document.getElementById("rvLeaveEndField");
  nodes.leaveEnd = document.getElementById("rvLeaveEnd");
  nodes.leaveReason = document.getElementById("rvLeaveReason");
  nodes.leaveMessage = document.getElementById("rvLeaveMessage");
  nodes.myLeaveRequests = document.getElementById("rvMyLeaveRequests");

  nodes.search.addEventListener("input", () => { ROSTER_VIEW.search = nodes.search.value; render(); });
  nodes.scheduleToggle.addEventListener("click", () => {
    const expanded = nodes.scheduleToggle.getAttribute("aria-expanded") === "true";
    nodes.scheduleToggle.setAttribute("aria-expanded", String(!expanded));
  });
  nodes.nextButton.addEventListener("click", () => {
    if (!ROSTER_VIEW.nextWeek) return;
    ROSTER_VIEW.showingNext = !ROSTER_VIEW.showingNext;
    render();
    window.scrollTo({ top: 0, behavior: "smooth" });
  });
  nodes.shiftTabs.addEventListener("click", (event) => {
    const button = event.target.closest("[data-rv-shift]");
    if (button && !button.disabled) selectShift(button.dataset.rvShift);
  });
  nodes.leaveButton.addEventListener("click", openLeaveForm);
  nodes.leaveClose.addEventListener("click", closeLeaveForm);
  nodes.leaveCancel.addEventListener("click", closeLeaveForm);
  nodes.leaveOverlay.addEventListener("click", (event) => { if (event.target === nodes.leaveOverlay) closeLeaveForm(); });
  nodes.leaveType.addEventListener("change", updateLeaveType);
  nodes.leaveStart.addEventListener("change", () => { if (nodes.leaveType.value === "DAY_OFF") nodes.leaveEnd.value = nodes.leaveStart.value; nodes.leaveEnd.min = nodes.leaveStart.value || nextMondayIso(); });
  nodes.leaveStaff.addEventListener("change", loadMyLeaveRequests);
  nodes.leaveSubmit.addEventListener("click", submitLeaveRequest);
  document.addEventListener("keydown", (event) => { if (event.key === "Escape" && nodes.leaveOverlay.classList.contains("show")) closeLeaveForm(); });

  try { await loadRoster(); } catch (error) { showError(error); }
});
