"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const el = {
    date: $("distributionDate"), today: $("distributionTodayButton"), refresh: $("distributionRefreshButton"), message: $("distributionMessage"),
    kpis: $("distributionKpis"), tabs: $("distributionTabs"), panel: $("distributionPanel"),
    runDialog: $("distributionRunDialog"), runForm: $("distributionRunForm"), runTitle: $("distributionRunTitle"), runSubtitle: $("distributionRunSubtitle"), runId: $("distributionRunId"), runRouteId: $("distributionRunRouteId"), runVersion: $("distributionRunVersion"), runPrimary: $("distributionRunPrimaryDriver"), runSupport: $("distributionRunSupportDriver"), runVehicle: $("distributionRunVehicle"), runStatus: $("distributionRunStatus"), runNotes: $("distributionRunNotes"), runMessage: $("distributionRunMessage"),
    stopDialog: $("distributionStopDialog"), stopTitle: $("distributionStopTitle"), stopSubtitle: $("distributionStopSubtitle"), stopList: $("distributionStopList"), stopMessage: $("distributionStopMessage"), addStop: $("distributionAddStopButton"), manualForm: $("distributionManualStopForm"), manualKind: $("distributionManualStopKind"), manualName: $("distributionManualStopName"), manualEircode: $("distributionManualStopEircode"), manualKg: $("distributionManualStopKg"), manualInstructions: $("distributionManualStopInstructions"), manualSave: $("distributionManualStopSave"),
    masterDialog: $("distributionMasterDialog"), masterForm: $("distributionMasterForm"), masterEyebrow: $("distributionMasterEyebrow"), masterTitle: $("distributionMasterTitle"), masterFields: $("distributionMasterFields"), masterMessage: $("distributionMasterMessage"),
    rosterDialog: $("distributionRosterEntryDialog"), rosterForm: $("distributionRosterEntryForm"), rosterTitle: $("distributionRosterEntryTitle"), rosterSubtitle: $("distributionRosterEntrySubtitle"), rosterRouteId: $("distributionRosterEntryRouteId"), rosterDate: $("distributionRosterEntryDate"), rosterDriverId: $("distributionRosterEntryDriverId"), rosterRoute: $("distributionRosterEntryRoute"), rosterStatus: $("distributionRosterEntryStatus"), rosterPrimary: $("distributionRosterEntryPrimary"), rosterSupport: $("distributionRosterEntrySupport"), rosterVehicle: $("distributionRosterEntryVehicle"), rosterNote: $("distributionRosterEntryNote"), rosterMessage: $("distributionRosterEntryMessage"), rosterCurrent: $("distributionRosterCurrent"), rosterDayTag: $("distributionRosterDayTag"), rosterRouteButtons: $("distributionRosterRouteButtons"), rosterTakenSection: $("distributionRosterTakenSection"), rosterTakenButtons: $("distributionRosterTakenButtons"), rosterVehicleButtons: $("distributionRosterVehicleButtons"), rosterConfirm: $("distributionRosterConfirm")
  };
  const distributionTabIds = ["board", "customers", "roster", "actuals", "drivers", "fleet", "routes", "history"];
  const initialTab = String(location.hash || "").replace("#", "");
  const state = { data: null, activeTab: distributionTabIds.includes(initialTab) ? initialTab : "board", routeDetail: null, master: null, roster: null, rosterWeek: "", rosterDirty: false, rosterEditing: null, pendingRouteId: "", pendingVehicleId: "", history: null, actuals: null, actualsWeek: "", routeCustomersCollapsed: new Set(), routeCustomersWeekly: null, routeCustomersDay: "", routeCustomersRoute: "", routeCustomersSearch: "" };
  const esc = (value) => String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");
  const isoToday = () => new Date().toISOString().slice(0, 10);
  const localDate = (value) => String(value || "").slice(0, 10);
  const validColor = (value) => /^#[0-9a-f]{6}$/i.test(String(value || "")) ? String(value) : "#7c91a6";
  const routeTextColor = (value) => {
    const hex = validColor(value).slice(1);
    const [r, g, b] = [0, 2, 4].map((index) => parseInt(hex.slice(index, index + 2), 16) / 255).map((channel) => channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4);
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.56 ? "#172033" : "#ffffff";
  };
  const titleCase = (value) => String(value || "").toLowerCase().split("_").map((part) => part ? part[0].toUpperCase() + part.slice(1) : "").join(" ");
  const fmtDate = (value) => value ? new Intl.DateTimeFormat("en-IE", { weekday: "short", day: "2-digit", month: "short" }).format(new Date(`${localDate(value)}T12:00:00`)) : "Not set";
  const fmtShortDate = (value) => value ? new Intl.DateTimeFormat("en-IE", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(`${localDate(value)}T12:00:00`)) : "Not set";
  const fmtNumber = (value, digits = 0) => new Intl.NumberFormat("en-IE", { maximumFractionDigits: digits }).format(Number(value || 0));
  const isSunday = (value) => new Date(`${localDate(value)}T12:00:00`).getDay() === 0;
  const caps = () => state.data?.capabilities || {};
  const rpc = async (name, args = {}) => { const { data, error } = await client.rpc(name, args); if (error) throw error; return data; };
  const setMessage = (message = "", kind = "") => { el.message.textContent = message; el.message.className = `distribution-message ${kind}`; };
  const setInline = (node, message = "") => { node.textContent = message; };
  const close = (dialog) => { if (dialog?.open) dialog.close(); };
  const activeStops = () => Array.isArray(state.data?.reference_stops) ? state.data.reference_stops : [];
  const runs = () => Array.isArray(state.data?.runs) ? state.data.runs : [];
  const routes = () => Array.isArray(state.data?.routes) ? state.data.routes : [];
  const drivers = () => Array.isArray(state.data?.drivers) ? state.data.drivers : [];
  const vehicles = () => Array.isArray(state.data?.vehicles) ? state.data.vehicles : [];
  const rosterEntries = () => Array.isArray(state.roster?.entries) ? state.roster.entries : [];
  const rosterRoutes = () => Array.isArray(state.roster?.routes) ? state.roster.routes : [];
  const rosterDrivers = () => Array.isArray(state.roster?.drivers) ? state.roster.drivers : [];
  const rosterVehicles = () => Array.isArray(state.roster?.vehicles) ? state.roster.vehicles : [];
  const nonWorkingStatuses = new Set(["OFF", "HOLIDAY", "TRAINING", "ABSENT", "SICK"]);
  const rosterStatusLabel = (status) => ({ PLANNED: "Working", OFF: "Off", HOLIDAY: "Hols", TRAINING: "Training", ABSENT: "Absent", SICK: "Sick" }[String(status || "PLANNED")] || titleCase(status));

  function nextOperatingDate(value = isoToday()) {
    const date = new Date(`${value}T12:00:00`);
    if (date.getDay() !== 0) return value;
    date.setDate(date.getDate() + 1);
    return date.toISOString().slice(0, 10);
  }

  function mondayFor(value = isoToday()) {
    const date = new Date(`${localDate(value)}T12:00:00`);
    const offset = (date.getDay() + 6) % 7;
    date.setDate(date.getDate() - offset);
    return date.toISOString().slice(0, 10);
  }

  function weekInputValue(weekStart) {
    const date = new Date(`${localDate(weekStart)}T12:00:00`);
    const thursday = new Date(date); thursday.setDate(thursday.getDate() + 3);
    const firstThursday = new Date(thursday.getFullYear(), 0, 4);
    firstThursday.setDate(firstThursday.getDate() + ((4 - firstThursday.getDay() + 7) % 7));
    const week = 1 + Math.round((thursday - firstThursday) / 604800000);
    return `${thursday.getFullYear()}-W${String(week).padStart(2, "0")}`;
  }

  function weekStartFromInput(value) {
    const match = /^(\d{4})-W(\d{2})$/.exec(String(value || ""));
    if (!match) return mondayFor();
    const jan4 = new Date(`${match[1]}-01-04T12:00:00`);
    const weekOneMonday = new Date(jan4); weekOneMonday.setDate(jan4.getDate() - ((jan4.getDay() + 6) % 7));
    weekOneMonday.setDate(weekOneMonday.getDate() + (Number(match[2]) - 1) * 7);
    return weekOneMonday.toISOString().slice(0, 10);
  }

  function rosterDays() {
    const start = state.roster?.week_start || state.rosterWeek || mondayFor(state.data?.business_date || isoToday());
    return Array.from({ length: 7 }, (_, index) => {
      const date = new Date(`${localDate(start)}T12:00:00`); date.setDate(date.getDate() + index);
      return date.toISOString().slice(0, 10);
    });
  }

  function statusPill(status) {
    const normalized = String(status || "DRAFT").toLowerCase();
    return `<span class="distribution-status ${esc(normalized)}">${esc(titleCase(status || "DRAFT"))}</span>`;
  }

  function renderKpis() {
    const stops = activeStops();
    const activeRuns = runs().filter((run) => !["CANCELLED", "COMPLETED"].includes(String(run.run_status)));
    const assigned = new Set(activeRuns.map((run) => String(run.route_id)));
    const pendingRoutes = new Set(stops.filter((stop) => !assigned.has(String(stop.route_id))).map((stop) => String(stop.route_id))).size;
    const handoff = state.data?.trolley_handoff?.summary || {};
    const fleet = state.data?.fleet_summary || {};
    const items = [
      [stops.length, "Scheduled stops", ""],
      [activeRuns.length, "Active routes", ""],
      [pendingRoutes, "Routes to plan", pendingRoutes ? "attention" : ""],
      [handoff.trolley_count || 0, "Trolleys prepared", ""],
      [(fleet.open_defects || 0) + (fleet.compliance_due || 0), "Fleet attention", (fleet.open_defects || fleet.compliance_due) ? "risk" : ""]
    ];
    el.kpis.innerHTML = items.map(([value, label, cls]) => `<article class="${cls}"><strong>${esc(fmtNumber(value))}</strong><span>${esc(label)}</span></article>`).join("");
  }

  function renderTabs() {
    const tabs = [
      ["board", "Daily board"], ["customers", "Route customers"], ["roster", "Weekly roster"], ["actuals", "Actuals"], ["drivers", "Drivers"], ["fleet", "Fleet"], ["routes", "Routes"], ["history", "History"]
    ];
    el.tabs.innerHTML = tabs.map(([id, label]) => `<button class="distribution-tab ${state.activeTab === id ? "active" : ""}" data-tab="${id}" type="button">${label}</button>`).join("");
  }

  function routeData() {
    const byId = new Map();
    routes().filter((route) => route.active).forEach((route) => byId.set(String(route.route_id), { ...route, stops: [], run: null }));
    activeStops().forEach((stop) => {
      const key = String(stop.route_id || "");
      if (!byId.has(key)) byId.set(key, { route_id: stop.route_id, route_code: stop.route_code || "UNASSIGNED", display_name: stop.route_display_name || "Route not assigned", route_color: stop.route_color, stops: [], run: null });
      byId.get(key).stops.push(stop);
    });
    runs().forEach((run) => {
      const key = String(run.route_id);
      if (!byId.has(key)) byId.set(key, { route_id: run.route_id, route_code: run.route_code, display_name: run.route_display_name, route_color: run.route_color, stops: [], run });
      else byId.get(key).run = run;
    });
    return [...byId.values()].filter((route) => route.stops.length || route.run).sort((a, b) => String(a.route_code || "").localeCompare(String(b.route_code || "")));
  }

  function handoffCount(routeId) {
    const row = (state.data?.trolley_handoff?.routes || []).find((route) => String(route.route_id) === String(routeId));
    return Number(row?.trolley_count || 0);
  }

  function renderBoard() {
    const list = routeData();
    if (!list.length) {
      el.panel.innerHTML = `<div class="distribution-empty">No scheduled Distribution stops exist for ${esc(fmtShortDate(state.data?.business_date))}.</div>`;
      return;
    }
    const canPlan = Boolean(caps().can_plan_runs);
    el.panel.innerHTML = `<div class="distribution-toolbar"><div><h2>Daily route board</h2><p>Published customer schedules are the source. Route runs hold the operational assignment for this day.</p></div><span>${esc(fmtDate(state.data?.business_date))}</span></div><div class="distribution-route-grid">${list.map((route) => {
      const run = route.run;
      const kg = route.stops.reduce((sum, stop) => sum + Number(stop.estimated_kg || 0), 0);
      const stopUnits = route.stops.reduce((sum, stop) => sum + Number(stop.stop_units || 0), 0);
      const trolley = handoffCount(route.route_id);
      const colour = validColor(route.route_color);
      return `<article class="distribution-route-card" style="--route-color:${colour}"><div class="distribution-route-card-head"><span class="distribution-route-code">${esc(route.route_code || "R")}</span><div class="distribution-route-title"><h3>${esc(route.display_name || route.route_code || "Route")}</h3><p>${run ? `Run ${esc(titleCase(run.run_status))}` : "Not yet planned"}</p></div>${statusPill(run?.run_status || "UNPLANNED")}</div><div class="distribution-route-metrics"><span><b>${fmtNumber(route.stops.length)}</b> scheduled stops</span><span><b>${fmtNumber(kg)} kg</b> expected load</span><span><b>${fmtNumber(trolley)}</b> trolleys prepared</span></div><div class="distribution-route-assignment"><div>Driver<strong>${esc(run?.primary_driver_name || "Not assigned")}</strong></div><div>Vehicle<strong>${esc(run?.vehicle_registration || "Not assigned")}</strong></div></div><div class="distribution-card-actions">${canPlan ? `<button class="distribution-button primary" type="button" data-route-plan="${esc(route.route_id)}">${run ? "Edit route" : "Plan route"}</button>` : ""}${run ? `<button class="distribution-button secondary" type="button" data-route-stops="${esc(run.run_id)}">Stops ${fmtNumber(run.completed_stop_count)}/${fmtNumber(run.stop_count)}</button>` : ""}${run && canPlan && ["READY", "DRAFT"].includes(run.run_status) ? `<button class="distribution-button secondary" type="button" data-route-status="DISPATCHED" data-run-id="${esc(run.run_id)}">Dispatch</button>` : ""}${run && canPlan && ["DISPATCHED", "IN_PROGRESS"].includes(run.run_status) ? `<button class="distribution-button secondary" type="button" data-route-status="COMPLETED" data-run-id="${esc(run.run_id)}">Complete</button>` : ""}</div></article>`;
    }).join("")}</div>`;
  }

  function routeCustomerKey(group) {
    return `${group.deliveryWeekday}::${group.routeId || group.routeCode || "UNASSIGNED"}`;
  }

  function deliveryWindow(stop) {
    const start = String(stop.delivery_window_start || "").slice(0, 5);
    const end = String(stop.delivery_window_end || "").slice(0, 5);
    return start && end ? `${start} - ${end}` : start || end || "Not set";
  }

  function routeCustomerInstructions(stop) {
    return [stop.day_alert, stop.distribution_instructions].filter(Boolean).join(" - ") || "No instructions";
  }

  function routeCustomerGroups(items) {
    const groups = new Map();
    items.forEach((item) => {
      const routeId = String(item.default_route_id || "");
      const routeCode = String(item.default_route_code || "UNASSIGNED");
      const deliveryWeekday = Number(item.delivery_weekday || 0);
      const key = `${deliveryWeekday}::${routeId || routeCode}`;
      if (!groups.has(key)) groups.set(key, { deliveryWeekday, deliveryDay: item.delivery_day || "Delivery day", routeId, routeCode, routeName: item.default_route_display_name || routeCode, routeColor: validColor(item.default_route_color), items: [] });
      groups.get(key).items.push(item);
    });
    return [...groups.values()].map((group) => ({ ...group, items: group.items.sort((left, right) => Number(left.delivery_order || 999999) - Number(right.delivery_order || 999999) || String(left.customer_name || "").localeCompare(String(right.customer_name || "")) ) })).sort((left, right) => left.deliveryWeekday - right.deliveryWeekday || String(left.routeCode).localeCompare(String(right.routeCode), undefined, { numeric: true }));
  }

  function routeCustomerRouteOptions(items) {
    const options = new Map();
    items.forEach((item) => {
      const value = String(item.default_route_id || item.default_route_code || "UNASSIGNED");
      if (!options.has(value)) options.set(value, { value, code: item.default_route_code || "UNASSIGNED", name: item.default_route_display_name || "Unassigned route" });
    });
    return [...options.values()].sort((left, right) => String(left.code).localeCompare(String(right.code), undefined, { numeric: true }));
  }

  function renderRouteCustomers() {
    const sourceItems = Array.isArray(state.routeCustomersWeekly?.items) ? state.routeCustomersWeekly.items : [];
    if (!state.routeCustomersWeekly) {
      el.panel.innerHTML = `<div class="distribution-loading">Loading the published delivery schedule...</div>`;
      return;
    }
    const routeOptions = routeCustomerRouteOptions(sourceItems);
    if (state.routeCustomersRoute && !routeOptions.some((route) => route.value === state.routeCustomersRoute)) state.routeCustomersRoute = "";
    const search = state.routeCustomersSearch.toLowerCase();
    const items = sourceItems.filter((item) => {
      const routeValue = String(item.default_route_id || item.default_route_code || "UNASSIGNED");
      if (state.routeCustomersDay && String(item.delivery_weekday) !== state.routeCustomersDay) return false;
      if (state.routeCustomersRoute && routeValue !== state.routeCustomersRoute) return false;
      return !search || [item.customer_name, item.customer_code, item.default_route_code, item.default_route_display_name, item.eircode].some((value) => String(value || "").toLowerCase().includes(search));
    });
    const groups = routeCustomerGroups(items);
    const customerTotal = items.length;
    const trolleyTotal = items.reduce((total, item) => total + Number(item.planned_trolley_total || 0), 0);
    const kgTotal = items.reduce((total, item) => total + Number(item.distribution_estimated_kg || 0), 0);
    const cards = groups.map((group) => {
      const key = routeCustomerKey(group);
      const collapsed = state.routeCustomersCollapsed.has(key);
      const routeKg = group.items.reduce((sum, item) => sum + Number(item.distribution_estimated_kg || 0), 0);
      const routeTrolleys = group.items.reduce((sum, item) => sum + Number(item.planned_trolley_total || 0), 0);
      const rows = group.items.map((item, index) => {
        const products = Array.isArray(item.scheduled_products) ? item.scheduled_products.join(", ") : String(item.scheduled_products || "");
        const order = item.delivery_order ?? index + 1;
        return `<tr><td><span class="distribution-route-customer-order">${esc(order)}</span></td><td><strong>${esc(item.customer_name || "Customer")}</strong><small>${esc(item.customer_code || "")}</small></td><td>${esc(deliveryWindow(item))}</td><td>${esc(products || "Not set")}</td><td>${esc(item.eircode || "Not set")}</td><td>${esc(fmtNumber(item.distribution_estimated_kg, 1))} kg</td><td>${esc(fmtNumber(item.distribution_stop_count))}</td><td><strong>${esc(fmtNumber(item.planned_trolley_total))}</strong><small>${esc(item.trolley_summary || "")}</small></td><td>${esc(routeCustomerInstructions(item))}</td></tr>`;
      }).join("");
      const colour = group.routeColor;
      return `<article class="distribution-route-customers-card" style="--route-color:${colour};--route-text:${routeTextColor(colour)}"><button class="distribution-route-customers-head" type="button" data-route-customers-toggle="${esc(key)}" aria-expanded="${String(!collapsed)}"><span class="distribution-route-code">${esc(group.routeCode)}</span><span class="distribution-route-customers-title"><strong>${esc(group.routeName)}</strong><small>Route ${esc(group.routeCode)} - ${esc(group.deliveryDay)}</small></span><span class="distribution-route-customers-metrics"><span><b>${esc(fmtNumber(group.items.length))}</b> stops</span><span><b>${esc(fmtNumber(routeKg, 1))}</b> kg</span><span><b>${esc(fmtNumber(routeTrolleys))}</b> trolleys</span></span><span class="distribution-route-customers-chevron" aria-hidden="true">${collapsed ? "+" : "-"}</span></button><div class="distribution-route-customers-body" ${collapsed ? "hidden" : ""}><div class="distribution-table-wrap"><table class="distribution-table distribution-route-customers-table"><thead><tr><th>#</th><th>Customer / delivery stop</th><th>Delivery window</th><th>Products</th><th>Eircode</th><th>Expected kg</th><th>Stops</th><th>Trolleys</th><th>Instructions</th></tr></thead><tbody>${rows}</tbody></table></div></div></article>`;
    }).join("");
    el.panel.innerHTML = `<div class="distribution-toolbar distribution-route-customers-toolbar"><div><h2>Route customers</h2><p>Published Schedule Planner deliveries, grouped by day and route in the defined delivery order.</p></div><div class="distribution-card-actions"><button class="distribution-button secondary" type="button" data-route-customers-action="expand">Expand all</button><button class="distribution-button secondary" type="button" data-route-customers-action="collapse">Collapse all</button></div></div><div class="distribution-route-customers-filters"><label><span>Delivery day</span><select data-route-customers-day><option value="">All days</option>${[[1, "Monday"], [2, "Tuesday"], [3, "Wednesday"], [4, "Thursday"], [5, "Friday"], [6, "Saturday"]].map(([value, label]) => `<option value="${value}" ${state.routeCustomersDay === String(value) ? "selected" : ""}>${label}</option>`).join("")}</select></label><label><span>Route</span><select data-route-customers-route><option value="">All routes</option>${routeOptions.map((route) => `<option value="${esc(route.value)}" ${state.routeCustomersRoute === route.value ? "selected" : ""}>${esc(`${route.code} - ${route.name}`)}</option>`).join("")}</select></label><label class="distribution-route-customers-search"><span>Search</span><input data-route-customers-search type="search" value="${esc(state.routeCustomersSearch)}" placeholder="Customer, route or Eircode"></label></div><section class="distribution-route-customers-summary"><span><b>${esc(fmtNumber(groups.length))}</b> route/day groups</span><span><b>${esc(fmtNumber(customerTotal))}</b> customers</span><span><b>${esc(fmtNumber(kgTotal, 1))}</b> expected kg</span><span><b>${esc(fmtNumber(trolleyTotal))}</b> planned trolleys</span></section>${groups.length ? `<div class="distribution-route-customers-list">${cards}</div>` : `<div class="distribution-empty">No scheduled deliveries match these filters.</div>`}`;
  }

  function manageButton(label, action, enabled = true) { return enabled ? `<button class="distribution-button secondary" type="button" data-master-action="${action}">${label}</button>` : ""; }
  function driverCompliance(driver) {
    const dates = [driver.licence_expires_on, driver.cpc_expires_on].filter(Boolean).map((value) => new Date(`${localDate(value)}T12:00:00`));
    const soon = dates.some((date) => date <= new Date(Date.now() + 30 * 86400000));
    const expired = dates.some((date) => date < new Date(`${isoToday()}T12:00:00`));
    return expired ? ["Expired document", "danger"] : soon ? ["Document due", "warn"] : ["Documents OK", ""];
  }

  function renderDrivers() {
    const canManage = Boolean(caps().can_manage_drivers);
    const list = drivers();
    el.panel.innerHTML = `<div class="distribution-toolbar"><div><h2>Drivers</h2><p>Licence and CPC dates are visible before assigning a route.</p></div>${manageButton("Add driver", "new-driver", canManage)}</div>${list.length ? `<div class="distribution-master-list">${list.map((driver) => { const [label, cls] = driverCompliance(driver); return `<article class="distribution-master-row"><div class="distribution-master-main"><span class="distribution-master-mark" style="--mark:#0f8b8d"></span><div><strong>${esc(driver.display_name)}</strong><small>${esc(driver.driver_code)}${driver.phone ? ` · ${esc(driver.phone)}` : ""}</small></div></div><div class="distribution-master-meta"><strong>${esc(titleCase(driver.availability_status))}</strong><span>${esc(titleCase(driver.employment_status))}</span></div><div class="distribution-master-meta"><strong>${esc(driver.licence_expires_on ? `Licence ${fmtShortDate(driver.licence_expires_on)}` : "Licence date not set")}</strong><span>${esc(driver.cpc_expires_on ? `CPC ${fmtShortDate(driver.cpc_expires_on)}` : "CPC date not set")}</span></div><span class="distribution-compliance ${cls}">${esc(label)}</span><div class="distribution-card-actions">${manageButton("Edit", `edit-driver:${driver.driver_id}`, canManage)}${manageButton("Leave", `leave-driver:${driver.driver_id}`, canManage)}</div></article>`; }).join("")}</div>` : `<div class="distribution-empty">No drivers have been added yet.</div>`}`;
  }

  function complianceForVehicle(vehicle) {
    const dates = [vehicle.road_tax_expires_on, vehicle.insurance_expires_on, vehicle.test_expires_on, vehicle.service_due_on].filter(Boolean).map((value) => new Date(`${localDate(value)}T12:00:00`));
    const today = new Date(`${isoToday()}T12:00:00`);
    if (dates.some((date) => date < today)) return ["Compliance expired", "danger"];
    if (dates.some((date) => date <= new Date(Date.now() + 30 * 86400000))) return ["Compliance due", "warn"];
    return ["Compliance OK", ""];
  }

  function renderFleet() {
    const canManage = Boolean(caps().can_manage_fleet);
    const fleet = vehicles(); const defects = state.data?.fleet_defects || []; const maintenance = state.data?.fleet_maintenance || [];
    const list = fleet.length ? `<div class="distribution-master-list">${fleet.map((vehicle) => { const [label, cls] = complianceForVehicle(vehicle); return `<article class="distribution-master-row"><div class="distribution-master-main"><span class="distribution-master-mark" style="--mark:${vehicle.operational_status === "AVAILABLE" ? "#0f8b8d" : "#d97706"}"></span><div><strong>${esc(vehicle.registration_number)}</strong><small>${esc(vehicle.display_name || titleCase(vehicle.vehicle_type))}</small></div></div><div class="distribution-master-meta"><strong>${esc(titleCase(vehicle.operational_status))}</strong><span>${fmtNumber(vehicle.capacity_kg)} kg capacity</span></div><div class="distribution-master-meta"><strong>${esc(vehicle.capacity_trolleys ?? "—")} trolleys</strong><span>${esc(titleCase(vehicle.vehicle_type))}</span></div><span class="distribution-compliance ${cls}">${esc(label)}</span><div class="distribution-card-actions">${manageButton("Edit", `edit-vehicle:${vehicle.vehicle_id}`, canManage)}${manageButton("Defect", `defect-vehicle:${vehicle.vehicle_id}`, canManage)}${manageButton("Maintenance", `maintenance-vehicle:${vehicle.vehicle_id}`, canManage)}</div></article>`; }).join("")}</div>` : `<div class="distribution-empty">No vehicles have been added yet.</div>`;
    el.panel.innerHTML = `<div class="distribution-toolbar"><div><h2>Fleet</h2><p>Vehicle availability, compliance and maintenance are checked before dispatch.</p></div>${manageButton("Add vehicle", "new-vehicle", canManage)}</div>${list}<div class="distribution-toolbar" style="margin-top:18px"><div><h2>Open fleet items</h2><p>Current defects and scheduled maintenance.</p></div></div>${renderFleetItems(defects, maintenance)}`;
  }

  function renderFleetItems(defects, maintenance) {
    if (!defects.length && !maintenance.length) return `<div class="distribution-empty">No open fleet defects or planned maintenance.</div>`;
    const rows = [...defects.map((item) => ({ type: "Defect", item, title: item.defect_category, detail: item.description, status: item.defect_status, date: item.reported_on })), ...maintenance.map((item) => ({ type: "Maintenance", item, title: item.maintenance_type, detail: item.supplier_name || item.notes || "No supplier recorded", status: item.maintenance_status, date: item.starts_on }))];
    return `<div class="distribution-table-wrap"><table class="distribution-table"><thead><tr><th>Vehicle</th><th>Item</th><th>Detail</th><th>Status</th><th>Date</th></tr></thead><tbody>${rows.map((row) => `<tr><td><strong>${esc(row.item.registration_number)}</strong></td><td>${esc(row.type)} · ${esc(row.title)}</td><td>${esc(row.detail)}</td><td>${statusPill(row.status)}</td><td>${esc(fmtShortDate(row.date))}</td></tr>`).join("")}</tbody></table></div>`;
  }

  function renderRoutes() {
    const canManage = Boolean(caps().can_manage_routes);
    const list = routes();
    el.panel.innerHTML = `<div class="distribution-toolbar"><div><h2>Route master</h2><p>Standard routes feed Customer Schedule defaults and daily Distribution runs.</p></div>${manageButton("Add route", "new-route", canManage)}</div>${list.length ? `<div class="distribution-master-list">${list.map((route) => `<article class="distribution-master-row"><div class="distribution-master-main"><span class="distribution-master-mark" style="--mark:${validColor(route.route_color)}"></span><div><strong>${esc(route.display_name)}</strong><small>${esc(route.route_code)} · ${esc(titleCase(route.route_kind))}</small></div></div><div class="distribution-master-meta"><strong>${route.allow_as_default ? "Customer default" : "Operational only"}</strong><span>Order ${esc(route.sort_order)}</span></div><div class="distribution-master-meta"><strong>${route.active ? "Active" : "Inactive"}</strong><span>${esc(route.notes || "No notes")}</span></div><span class="distribution-compliance">${route.active ? "Available" : "Disabled"}</span><div class="distribution-card-actions">${manageButton("Edit", `edit-route:${route.route_id}`, canManage)}</div></article>`).join("")}</div>` : `<div class="distribution-empty">No routes are available.</div>`}`;
  }

  function renderHistory() {
    if (!state.history) { el.panel.innerHTML = `<div class="distribution-loading">Loading Distribution history...</div>`; return; }
    const events = Array.isArray(state.history.events) ? state.history.events : [];
    const rosters = Array.isArray(state.history.roster_versions) ? state.history.roster_versions : [];
    const eventRows = events.map((event) => `<tr><td>${esc(fmtShortDate(event.event_at || event.created_at))}</td><td><strong>${esc(titleCase(event.event_type || event.activity_type || "Event"))}</strong><span>${esc(event.source || "Distribution")}</span></td><td>${esc(event.summary || event.route_display_name || event.roster_status || "Recorded change")}</td><td>${esc(event.recorded_by_name || event.recorded_by || "")}</td></tr>`).join("");
    const rosterRows = rosters.map((version) => `<tr><td>${esc(fmtShortDate(version.created_at))}</td><td><strong>Roster v${esc(version.version_number)}</strong><span>${esc(titleCase(version.roster_status))}</span></td><td>${esc(version.week_start)}${version.published_at ? ` · Published ${fmtShortDate(version.published_at)}` : ""}</td><td>${esc(version.created_by || "")}</td></tr>`).join("");
    el.panel.innerHTML = `<div class="distribution-toolbar"><div><h2>Distribution history</h2><p>Roster versions, saves, publication and daily route execution events.</p></div><button class="distribution-button secondary" type="button" data-history-refresh>Refresh</button></div><div class="distribution-table-wrap"><table class="distribution-table"><thead><tr><th>Date</th><th>Event</th><th>Detail</th><th>By</th></tr></thead><tbody>${eventRows || rosterRows || `<tr><td colspan="4">No Distribution history has been recorded yet.</td></tr>`}${eventRows && rosterRows ? rosterRows : ""}</tbody></table></div>`;
  }

  function actualValue(value) {
    return value === null || value === undefined ? "" : value;
  }

  function renderActuals() {
    if (!state.actuals) { el.panel.innerHTML = `<div class="distribution-loading">Loading weekly actuals...</div>`; return; }
    const canManage = Boolean(state.actuals.can_manage);
    const week = state.actuals.week_start;
    const range = `${fmtShortDate(state.actuals.week_start)} - ${fmtShortDate(state.actuals.week_end)}`;
    const driversRows = (state.actuals.drivers || []).map((driver) => {
      const variance = Number(actualValue(driver.actual_hours) || 0) - Number(driver.planned_hours || 0);
      return `<tr><td><strong>${esc(driver.display_name)}</strong><span>${esc(driver.driver_code || "")}</span></td><td>${fmtNumber(driver.planned_hours, 1)}</td><td><input type="number" min="0" step="0.25" value="${esc(actualValue(driver.actual_hours))}" data-actual-driver="${esc(driver.driver_id)}" data-planned-hours="${esc(driver.planned_hours || 0)}" ${canManage ? "" : "disabled"}></td><td class="${variance < 0 ? "attention" : "ok"}">${driver.actual_hours === null || driver.actual_hours === undefined ? "-" : fmtNumber(variance, 1)}</td></tr>`;
    }).join("");
    const vehicleRows = (state.actuals.vehicles || []).map((vehicle) => {
      const variance = Number(actualValue(vehicle.actual_km) || 0) - Number(vehicle.planned_km || 0);
      return `<tr><td><strong>${esc(vehicle.registration_number)}</strong><span>${esc(vehicle.display_name || titleCase(vehicle.vehicle_type))}</span></td><td>${fmtNumber(vehicle.planned_km, 1)}</td><td><input type="number" min="0" step="0.1" value="${esc(actualValue(vehicle.actual_km))}" data-actual-vehicle="${esc(vehicle.vehicle_id)}" data-planned-km="${esc(vehicle.planned_km || 0)}" ${canManage ? "" : "disabled"}></td><td><input type="number" min="0" step="0.1" value="${esc(actualValue(vehicle.odometer_km))}" data-actual-odometer="${esc(vehicle.vehicle_id)}" ${canManage ? "" : "disabled"}></td><td class="${variance < 0 ? "attention" : "ok"}">${vehicle.actual_km === null || vehicle.actual_km === undefined ? "-" : fmtNumber(variance, 1)}</td></tr>`;
    }).join("");
    el.panel.innerHTML = `<section class="distribution-actuals"><div class="distribution-toolbar"><div><h2>Weekly actuals</h2><p>Record actual driver hours, vehicle KM and odometer readings for history.</p></div><div class="distribution-header-actions"><button class="distribution-button secondary" type="button" data-actuals-week-shift="-1">Previous week</button><label class="distribution-week-field"><span>ISO Week</span><input id="distributionActualsWeek" type="week" value="${esc(weekInputValue(week))}"></label><button class="distribution-button secondary" type="button" data-actuals-week-shift="1">Next week</button>${canManage ? `<button class="distribution-button primary" type="button" data-actuals-save>Save actuals</button>` : ""}</div></div><div class="distribution-roster-status"><div><strong>${esc(range)}</strong><span>Planned values come from the Distribution Weekly Roster route KM/hours.</span></div></div><div class="distribution-actuals-grid"><section><h3>Driver hours</h3><div class="distribution-table-wrap"><table class="distribution-table distribution-actuals-table"><thead><tr><th>Driver</th><th>Planned hrs</th><th>Actual hrs</th><th>Variance</th></tr></thead><tbody>${driversRows || `<tr><td colspan="4">No active drivers found.</td></tr>`}</tbody></table></div></section><section><h3>Vehicle mileage</h3><div class="distribution-table-wrap"><table class="distribution-table distribution-actuals-table"><thead><tr><th>Vehicle</th><th>Planned KM</th><th>Actual KM</th><th>Odometer</th><th>Variance</th></tr></thead><tbody>${vehicleRows || `<tr><td colspan="5">No active vehicles found.</td></tr>`}</tbody></table></div></section></div></section>`;
  }

  function rosterEntry(routeId, workDate) {
    return rosterEntries().find((entry) => String(entry.route_id) === String(routeId) && localDate(entry.work_date) === localDate(workDate));
  }

  function shortName(value) {
    const names = String(value || "").trim().split(/\s+/).filter(Boolean);
    return names.length > 1 ? `${names[0]} ${names[names.length - 1][0]}.` : names[0] || "";
  }

  function renderRosterLegacy() {
    if (!state.roster) { el.panel.innerHTML = `<div class="distribution-loading">Loading weekly Distribution roster...</div>`; return; }
    const document = state.roster.document;
    const editable = Boolean(state.roster.can_manage) && !state.roster.is_past && (!document || document.roster_status === "DRAFT");
    const status = document?.roster_status || "NOT_STARTED";
    const days = rosterDays();
    const range = `${fmtDate(days[0])} - ${fmtDate(days[days.length - 1])}`;
    const dayButton = (route, day) => {
      const entry = rosterEntry(route.route_id, day); const off = entry?.assignment_status === "OFF";
      const assigned = entry?.assignment_status === "PLANNED" && entry?.primary_driver_id;
      const stateClass = off ? "off" : assigned ? "working" : "cover";
      const label = off ? "OFF" : assigned ? "RUN" : "+";
      const detail = off ? "Off route" : assigned ? `${shortName(entry.primary_driver_name_snapshot)}${entry.vehicle_registration_snapshot ? ` · ${entry.vehicle_registration_snapshot}` : ""}` : "Assign";
      const action = off ? `${route.display_name}, ${fmtDate(day)}: off route` : assigned ? `${route.display_name}, ${fmtDate(day)}: ${entry.primary_driver_name_snapshot}, ${entry.vehicle_registration_snapshot || "vehicle pending"}` : `${route.display_name}, ${fmtDate(day)}: create assignment`;
      return `<div class="roster-day-cell"><button class="roster-day-button ${stateClass}" type="button" data-roster-route="${esc(route.route_id)}" data-roster-date="${esc(day)}" aria-label="${esc(action)}" title="${esc(action)}" ${editable ? "" : "disabled"}><span>${esc(label)}</span><small>${esc(detail)}</small><i aria-hidden="true">⌄</i></button></div>`;
    };
    const assignedForDay = (day) => rosterEntries().filter((entry) => localDate(entry.work_date) === day && entry.assignment_status === "PLANNED" && entry.primary_driver_id).length;
    const routeRows = rosterRoutes().map((route) => {
      const planned = rosterEntries().filter((entry) => String(entry.route_id) === String(route.route_id) && entry.assignment_status === "PLANNED" && entry.primary_driver_id);
      const crew = planned.length ? `${planned.length} planned day${planned.length === 1 ? "" : "s"}` : "No assignments";
      return `<div class="roster-row distribution-roster-row"><div class="roster-cell roster-who"><span class="distribution-roster-route-dot" style="--route-color:${validColor(route.route_color)}"></span><strong>${esc(route.display_name)}</strong><small>${esc(route.route_code)}</small></div><div class="roster-cell roster-assignment"><div class="roster-week-assignment-summary"><strong>${esc(crew)}</strong><span>${esc(route.route_code)} route</span></div></div><div class="roster-row-days" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">${days.map((day) => dayButton(route, day)).join("")}</div></div>`;
    }).join("");
    el.panel.innerHTML = `<section class="distribution-roster-production"><section class="roster-card roster-toolbar"><div class="roster-toolbar-top"><div class="roster-toolbar-controls"><label class="roster-field roster-week-field"><span>ISO Week</span><input id="distributionRosterWeek" type="week" value="${esc(weekInputValue(state.roster.week_start))}"></label><div class="roster-field distribution-roster-range"><span>Roster period</span><strong>${esc(range)}</strong></div></div><div class="roster-toolbar-actions"><button class="roster-button" type="button" data-roster-week-shift="-1">Previous week</button><button class="roster-button" type="button" data-roster-week-shift="1">Next week</button><span class="roster-toolbar-separator"></span>${editable ? `<button class="roster-button" type="button" data-roster-save ${state.rosterDirty ? "" : "disabled"}>Save</button>${document ? `<button class="roster-button publish" type="button" data-roster-publish>Publish</button>` : ""}` : ""}</div></div><div class="roster-context-banner ${state.roster.is_past ? "past" : document?.roster_status === "PUBLISHED" ? "current" : "future"}"><strong>${esc(status === "NOT_STARTED" ? "New Distribution roster" : titleCase(status))}</strong> · ${esc(state.roster.is_past ? "This week is read only." : document?.roster_status === "PUBLISHED" ? "Published roster is locked." : "Create the weekly fleet and driver plan, then publish it to Daily board.")}</div><div class="roster-note-row"><label class="roster-field roster-note-field"><span>Weekly note</span><input id="distributionRosterNote" type="text" maxlength="1500" value="${esc(document?.roster_note || "")}" placeholder="Optional planning note"></label><div class="roster-document-status"><strong>${esc(status === "NOT_STARTED" ? "Not saved" : titleCase(status))}</strong><span>${document ? `Version ${esc(document.version_number)}` : "Draft is created when saved"}</span></div></div><div class="roster-legend-wrap"><div class="roster-legend"><span><i class="working"></i>Assigned route</span><span><i class="cover"></i>Unassigned</span><span><i class="off"></i>Off route</span><span class="distribution-roster-rule">Truck/other: one route per day · Van: two routes per day</span></div></div></section><section class="roster-card roster-grid-card"><div class="roster-grid-scroll"><div class="roster-grid"><div class="roster-grid-header"><div>Route</div><div>Weekly plan</div><div class="roster-day-grid" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">${days.map((day) => `<div class="roster-day-header"><strong>${esc(fmtDate(day).split(",")[0])}</strong><span>${esc(fmtDate(day).slice(-6))}</span></div>`).join("")}</div></div>${routeRows || `<div class="roster-empty">Add active standard routes before creating a roster.</div>`}<div class="roster-total-row"><div class="roster-cell">Assigned routes</div><div class="roster-cell">Ready to publish</div><div class="roster-row-days" style="grid-template-columns:repeat(${days.length},minmax(var(--day-min),1fr))">${days.map((day) => `<div class="roster-day-cell"><span class="roster-total-value">${assignedForDay(day)}</span></div>`).join("")}</div></div></div></div></section></section>`;
  }

  function rosterMetric(routeId, workDate) {
    return (state.roster?.route_day_metrics || []).find((item) => String(item.route_id) === String(routeId) && localDate(item.work_date) === localDate(workDate)) || {};
  }

  function rosterDailyMetric(workDate) {
    return (state.roster?.daily_metrics || []).find((item) => localDate(item.work_date) === localDate(workDate)) || {};
  }

  function driverRosterEntry(driverId, workDate) {
    return rosterEntries().find((entry) => localDate(entry.work_date) === localDate(workDate) && (String(entry.primary_driver_id) === String(driverId) || String(entry.support_driver_id) === String(driverId)));
  }

  function sameRosterCell(entry, driverId, workDate) {
    return localDate(entry.work_date) === localDate(workDate) && (String(entry.primary_driver_id) === String(driverId) || String(entry.support_driver_id) === String(driverId));
  }

  function isCurrentRosterEntry(entry) {
    const edit = state.rosterEditing || {};
    if (!entry || !edit.driverId || !edit.workDate) return false;
    if (entry.distribution_roster_entry_id && edit.entryId) return String(entry.distribution_roster_entry_id) === String(edit.entryId);
    return sameRosterCell(entry, edit.driverId, edit.workDate);
  }

  function routeAllowedForDay(route, workDate) {
    if (!route) return false;
    if (["COLLECTION", "AD_HOC", "SUPPORT"].includes(String(route.route_kind || "").toUpperCase())) return true;
    const metrics = rosterMetric(route.route_id, workDate);
    return !state.roster?.route_day_metrics || Number(metrics.stops || 0) > 0;
  }

  function routeAssignedOnDay(routeId, workDate) {
    return rosterEntries().some((entry) => entry.assignment_status === "PLANNED" && String(entry.route_id) === String(routeId) && localDate(entry.work_date) === localDate(workDate) && !isCurrentRosterEntry(entry));
  }

  function vehicleAssignedOnDay(vehicleId, workDate) {
    return rosterEntries().some((entry) => entry.assignment_status === "PLANNED" && String(entry.vehicle_id) === String(vehicleId) && localDate(entry.work_date) === localDate(workDate) && !isCurrentRosterEntry(entry));
  }

  function vehicleUsageForDay(vehicleId, workDate) {
    if (!vehicleId) return [];
    return rosterEntries().filter((entry) => entry.assignment_status === "PLANNED" && String(entry.vehicle_id) === String(vehicleId) && localDate(entry.work_date) === localDate(workDate) && !isCurrentRosterEntry(entry));
  }

  function vehicleDailyLimit(vehicle) {
    return String(vehicle?.vehicle_type || "").toUpperCase() === "VAN" ? 2 : 1;
  }

  function vehicleSecondTurn(vehicleId, workDate) {
    const vehicle = rosterVehicles().find((item) => String(item.vehicle_id) === String(vehicleId));
    return Boolean(vehicle && vehicleDailyLimit(vehicle) > 1 && vehicleUsageForDay(vehicleId, workDate).length === 1);
  }

  function driverAssignedOnDay(driverId, workDate) {
    return rosterEntries().some((entry) => localDate(entry.work_date) === localDate(workDate) && !isCurrentRosterEntry(entry) && (String(entry.primary_driver_id) === String(driverId) || String(entry.support_driver_id) === String(driverId)));
  }

  function requiredRoutesFor(workDate) {
    const saved = state.roster?.required_routes?.[localDate(workDate)];
    return saved === undefined || saved === null || saved === "" ? Number(rosterDailyMetric(workDate).scheduled_routes || 0) : Number(saved || 0);
  }

  function renderRoster() {
    if (!state.roster) { el.panel.innerHTML = `<div class="distribution-loading">Loading weekly Distribution roster...</div>`; return; }
    const documentData = state.roster.document;
    const editable = Boolean(state.roster.can_manage) && !state.roster.is_past && (!documentData || documentData.roster_status === "DRAFT");
    const days = rosterDays();
    const status = documentData?.roster_status || "NOT_STARTED";
    const range = `${fmtDate(days[0])} - ${fmtDate(days[days.length - 1])}`;
    const driverRows = rosterDrivers();
    const primaryEntries = (day) => rosterEntries().filter((entry) => localDate(entry.work_date) === localDate(day) && entry.assignment_status === "PLANNED" && entry.primary_driver_id);
    const activeAssignment = (driver, day) => {
      if (driverOnLeave(driver.driver_id, day)) return { kind: "leave", label: "Hols", detail: "Approved leave" };
      const entry = driverRosterEntry(driver.driver_id, day);
      if (!entry || isSunday(day)) return { kind: "off", label: "Off", detail: "Off route" };
      if (nonWorkingStatuses.has(entry.assignment_status)) return { kind: String(entry.assignment_status).toLowerCase(), label: rosterStatusLabel(entry.assignment_status), detail: "No route" };
      const route = rosterRoutes().find((item) => String(item.route_id) === String(entry.route_id)) || entry;
      const secondTurn = entry.vehicle_id && vehicleSecondTurn(entry.vehicle_id, day);
      const vehicle = entry.vehicle_registration_snapshot ? `${entry.vehicle_registration_snapshot}${secondTurn ? " 2T" : ""}` : "Vehicle pending";
      const color = validColor(route.route_color || entry.route_color_snapshot);
      return { kind: "route", label: route.route_code || "Route", detail: `${String(entry.support_driver_id) === String(driver.driver_id) ? "Support - " : ""}${vehicle}`, color, textColor: routeTextColor(color) };
    };
    const dayCell = (driver, day) => {
      const assignment = activeAssignment(driver, day);
      const action = `${driver.display_name}, ${fmtDate(day)}: ${assignment.label}`;
      return `<td class="distribution-driver-day ${assignment.kind === "leave" ? "leave" : ""}"><button class="distribution-driver-day-button ${assignment.kind}" type="button" data-roster-driver="${esc(driver.driver_id)}" data-roster-date="${esc(day)}" title="${esc(action)}" ${!editable || isSunday(day) || assignment.kind === "leave" ? "disabled" : ""} ${assignment.color ? `style="--distribution-route-color:${assignment.color};--distribution-route-text:${assignment.textColor}"` : ""}><strong>${esc(assignment.label)}</strong><small>${esc(assignment.detail)}</small></button></td>`;
    };
    const driverTotals = (driver) => {
      const assigned = rosterEntries().filter((entry) => String(entry.primary_driver_id) === String(driver.driver_id));
      const totals = assigned.reduce((sum, entry) => {
        if (entry.assignment_status === "TRAINING") { sum.days += 1; sum.hours += 8; return sum; }
        if (entry.assignment_status !== "PLANNED") return sum;
        const metric = rosterMetric(entry.route_id, entry.work_date);
        sum.days += 1; sum.hours += Number(metric.hours || 0); sum.km += Number(metric.km || 0); sum.stops += Number(metric.stops || 0); return sum;
      }, { days: 0, hours: 0, km: 0, stops: 0 });
      return { days: assigned.length, ...totals };
    };
    const licence = (driver) => Array.isArray(driver.licence_categories) ? driver.licence_categories.join(", ") : (driver.licence_categories || driver.licence_category || "-");
    const rows = driverRows.map((driver, index) => {
      const totals = driverTotals(driver);
      return `<tr><td class="distribution-row-number">${index + 1}</td><td class="distribution-licence">${esc(licence(driver))}</td><th scope="row" class="distribution-driver-name">${esc(driver.display_name)}</th>${days.map((day) => dayCell(driver, day)).join("")}<td>${fmtNumber(totals.days)}</td><td>${fmtNumber(totals.hours, 1)}</td><td>${fmtNumber(totals.km)}</td><td>${fmtNumber(totals.stops)}</td></tr>`;
    }).join("");
    const plannedByDay = days.map((day) => primaryEntries(day).length);
    const overall = days.reduce((sum, day) => { const entries = primaryEntries(day); sum.days += entries.length; entries.forEach((entry) => { const metric = rosterMetric(entry.route_id, day); sum.hours += Number(metric.hours || 0); sum.km += Number(metric.km || 0); sum.stops += Number(metric.stops || 0); }); return sum; }, { days: 0, hours: 0, km: 0, stops: 0 });
    const requirementFields = days.map((day) => `<label><span>${esc(fmtDate(day).split(",")[0])}</span><input type="number" min="0" step="1" value="${esc(requiredRoutesFor(day))}" data-required-routes-date="${esc(day)}" ${!editable || isSunday(day) ? "disabled" : ""}></label>`).join("");
    el.panel.innerHTML = `<section class="distribution-driver-roster"><div class="roster-card roster-toolbar"><div class="roster-toolbar-top"><div class="roster-toolbar-controls"><label class="roster-field roster-week-field"><span>ISO Week</span><input id="distributionRosterWeek" type="week" value="${esc(weekInputValue(state.roster.week_start))}"></label><div class="roster-field distribution-roster-range"><span>Roster period</span><strong>${esc(range)}</strong></div></div><div class="roster-toolbar-actions"><button class="roster-button" type="button" data-roster-week-shift="-1">Previous week</button><button class="roster-button" type="button" data-roster-week-shift="1">Next week</button>${editable ? `<button class="roster-button" type="button" data-roster-save ${state.rosterDirty ? "" : "disabled"}>Save</button>${documentData ? `<button class="roster-button publish" type="button" data-roster-publish>Publish</button>` : ""}` : ""}</div></div><div class="roster-note-row"><label class="roster-field roster-note-field"><span>Weekly note</span><input id="distributionRosterNote" type="text" maxlength="1500" value="${esc(documentData?.roster_note || "")}" placeholder="Optional planning note"></label><div class="roster-document-status"><strong>${esc(status === "NOT_STARTED" ? "Not saved" : titleCase(status))}</strong><span>${documentData ? `Version ${esc(documentData.version_number)}` : "Draft is created when saved"}</span></div></div></div><div class="distribution-required-routes"><strong>Required:</strong><div>${requirementFields}</div></div><div class="distribution-driver-roster-table-wrap"><table class="distribution-driver-roster-table"><thead><tr><th>#</th><th>Lic</th><th>Driver</th>${days.map((day) => `<th><span>${esc(fmtDate(day).split(",")[0])}</span><small>${esc(localDate(day).slice(8, 10))}/${esc(localDate(day).slice(5, 7))}</small></th>`).join("")}<th>Days</th><th>Hrs</th><th>KM</th><th>Stops</th></tr></thead><tbody>${rows || `<tr><td colspan="14" class="distribution-roster-empty">Add active drivers before creating a roster.</td></tr>`}</tbody><tfoot><tr><th colspan="3">Routes planned</th>${plannedByDay.map((value) => `<td>${fmtNumber(value)}</td>`).join("")}<td>${fmtNumber(overall.days)}</td><td>${fmtNumber(overall.hours, 1)}</td><td>${fmtNumber(overall.km)}</td><td>${fmtNumber(overall.stops)}</td></tr><tr><th colspan="3">Required routes</th>${days.map((day) => `<td>${fmtNumber(requiredRoutesFor(day))}</td>`).join("")}<td colspan="4"></td></tr><tr><th colspan="3">Daily check</th>${days.map((day, index) => `<td class="${plannedByDay[index] === requiredRoutesFor(day) ? "ok" : "attention"}">${plannedByDay[index] === requiredRoutesFor(day) ? "OK" : "!!"}</td>`).join("")}<td colspan="4"></td></tr></tfoot></table></div></section>`;
  }

  function render() { renderKpis(); renderTabs(); if (state.activeTab === "customers") renderRouteCustomers(); else if (state.activeTab === "roster") renderRoster(); else if (state.activeTab === "actuals") renderActuals(); else if (state.activeTab === "drivers") renderDrivers(); else if (state.activeTab === "fleet") renderFleet(); else if (state.activeTab === "routes") renderRoutes(); else if (state.activeTab === "history") renderHistory(); else renderBoard(); }

  async function load(date = el.date.value || nextOperatingDate()) {
    const value = nextOperatingDate(date);
    if (value !== date) setMessage("Sunday is not an operating day. Showing Monday instead."); else setMessage("");
    el.date.value = value; el.refresh.disabled = true; el.panel.style.opacity = ".55";
    try {
      const data = await rpc("get_distribution_operations_dashboard", { p_business_date: value });
      if (data?.schema_version !== "DISTRIBUTION_OPERATIONS_V1") throw new Error("Distribution backend is out of date. Apply the Distribution Operations migration.");
      if (!data?.capabilities?.can_view_distribution_operations) throw new Error("Your active role does not allow access to Distribution.");
      state.data = data; render();
      if (state.activeTab === "customers") await loadRouteCustomers();
    } catch (error) {
      console.error(error); setMessage(error.message || "Distribution could not be loaded."); el.panel.innerHTML = `<div class="distribution-empty">${esc(error.message || "Distribution is unavailable.")}</div>`;
    } finally { el.refresh.disabled = false; el.panel.style.opacity = "1"; }
  }

  async function loadRoster(weekStart = state.rosterWeek || mondayFor(state.data?.business_date || isoToday())) {
    const value = mondayFor(weekStart);
    state.rosterWeek = value;
    if (state.activeTab === "roster") { el.panel.style.opacity = ".55"; renderRoster(); }
    try {
      state.roster = await rpc("get_distribution_roster_week", { p_week_start: value, p_roster_version_id: null });
      state.rosterDirty = false;
      if (state.activeTab === "roster") render();
    } catch (error) {
      console.error(error); setMessage(error.message || "Distribution roster could not be loaded.");
      if (state.activeTab === "roster") el.panel.innerHTML = `<div class="distribution-empty">${esc(error.message || "Distribution roster is unavailable.")}</div>`;
    } finally { if (state.activeTab === "roster") el.panel.style.opacity = "1"; }
  }

  async function loadRouteCustomers() {
    try {
      state.routeCustomersWeekly = await rpc("get_distribution_weekly_planner", { p_effective_date: el.date.value, p_delivery_weekday: null, p_search: null });
      if (state.activeTab === "customers") renderRouteCustomers();
    } catch (error) {
      console.error(error);
      state.routeCustomersWeekly = null;
      setMessage(error.message || "Route operating days could not be loaded.");
      if (state.activeTab === "customers") renderRouteCustomers();
    }
  }

  async function loadHistory() {
    el.panel.style.opacity = ".55"; renderHistory();
    try {
      state.history = await rpc("get_distribution_activity_history", { p_from: null, p_to: null, p_limit: 250 });
      render();
    } catch (error) {
      console.error(error);
      setMessage(error.message || "Distribution history could not be loaded.");
      el.panel.innerHTML = `<div class="distribution-empty">${esc(error.message || "Distribution history is unavailable. Apply the Distribution history migration.")}</div>`;
    } finally { el.panel.style.opacity = "1"; }
  }

  async function loadActuals(weekStart = state.actualsWeek || state.rosterWeek || mondayFor(state.data?.business_date || isoToday())) {
    const value = mondayFor(weekStart);
    state.actualsWeek = value;
    if (state.activeTab === "actuals") { el.panel.style.opacity = ".55"; renderActuals(); }
    try {
      state.actuals = await rpc("get_distribution_actuals_week", { p_week_start: value });
      if (state.activeTab === "actuals") render();
    } catch (error) {
      console.error(error); setMessage(error.message || "Distribution actuals could not be loaded.");
      if (state.activeTab === "actuals") el.panel.innerHTML = `<div class="distribution-empty">${esc(error.message || "Distribution actuals are unavailable. Apply the Distribution actuals migration.")}</div>`;
    } finally { if (state.activeTab === "actuals") el.panel.style.opacity = "1"; }
  }

  function optionList(items, selected, label, disabled) { return `<option value="">Not assigned</option>${items.map((item) => `<option value="${esc(item.id)}" ${String(item.id) === String(selected || "") ? "selected" : ""} ${item.disabled ? "disabled" : ""}>${esc(label(item))}</option>`).join("")}`; }
  function openRun(routeId) {
    const route = routeData().find((item) => String(item.route_id) === String(routeId)); if (!route) return;
    const run = route.run || {}; const unavailableDriver = (driver) => driver.employment_status !== "ACTIVE" || driver.availability_status !== "AVAILABLE";
    el.runTitle.textContent = route.display_name || route.route_code; el.runSubtitle.textContent = `${route.stops.length} scheduled stop${route.stops.length === 1 ? "" : "s"} · ${fmtDate(state.data.business_date)}`;
    el.runId.value = run.run_id || ""; el.runRouteId.value = route.route_id; el.runVersion.value = run.row_version || ""; el.runStatus.value = run.run_status === "READY" ? "READY" : "DRAFT"; el.runNotes.value = run.dispatch_notes || "";
    el.runPrimary.innerHTML = optionList(drivers().map((driver) => ({ id: driver.driver_id, ...driver, disabled: unavailableDriver(driver) })), run.primary_driver_id, (driver) => `${driver.display_name} · ${driver.driver_code}`);
    el.runSupport.innerHTML = optionList(drivers().map((driver) => ({ id: driver.driver_id, ...driver, disabled: unavailableDriver(driver) })), run.support_driver_id, (driver) => `${driver.display_name} · ${driver.driver_code}`);
    el.runVehicle.innerHTML = optionList(vehicles().map((vehicle) => ({ id: vehicle.vehicle_id, ...vehicle, disabled: !vehicle.active || vehicle.operational_status !== "AVAILABLE" })), run.vehicle_id, (vehicle) => `${vehicle.registration_number}${vehicle.display_name ? ` · ${vehicle.display_name}` : ""}`);
    setInline(el.runMessage, ""); el.runDialog.showModal();
  }

  async function saveRun() {
    const payload = { run_id: el.runId.value || null, business_date: el.date.value, route_id: el.runRouteId.value, primary_driver_id: el.runPrimary.value || null, support_driver_id: el.runSupport.value || null, vehicle_id: el.runVehicle.value || null, run_status: el.runStatus.value, dispatch_notes: el.runNotes.value, row_version: el.runVersion.value || null };
    const button = $("distributionRunSave"); button.disabled = true; setInline(el.runMessage, "");
    try { await rpc("save_distribution_route_run", { p_run: payload }); close(el.runDialog); setMessage("Route execution saved.", "success"); await load(el.date.value); }
    catch (error) { setInline(el.runMessage, error.message || "Route could not be saved."); } finally { button.disabled = false; }
  }

  async function openStops(runId) {
    try {
      state.routeDetail = await rpc("get_distribution_route_run_detail", { p_run_id: runId });
      const run = runs().find((item) => String(item.run_id) === String(runId));
      el.stopTitle.textContent = run?.route_display_name || "Route stops"; el.stopSubtitle.textContent = `${fmtDate(state.routeDetail.business_date)} · ${titleCase(state.routeDetail.run_status)}`; setInline(el.stopMessage, "");
      renderStopList(); el.manualForm.classList.add("hidden"); el.addStop.hidden = !caps().can_plan_runs || !["DRAFT", "READY"].includes(state.routeDetail.run_status); el.stopDialog.showModal();
    } catch (error) { setMessage(error.message || "Route stops could not be loaded."); }
  }

  function renderStopList() {
    const editable = Boolean(caps().can_record_stop_outcomes);
    const statuses = ["PLANNED", "LOADED", "OUT_FOR_DELIVERY", "DELIVERED", "SKIPPED", "COLLECTION_COMPLETED"];
    const stops = state.routeDetail?.stops || [];
    el.stopList.innerHTML = stops.length ? stops.map((stop) => `<article class="distribution-stop-row"><span class="distribution-stop-order">${esc(stop.stop_order)}</span><div><strong>${esc(stop.customer_name_snapshot)}</strong><span>${esc(stop.eircode_snapshot || "No Eircode")}${stop.planned_trolley_total ? ` · ${esc(stop.planned_trolley_total)} trolleys` : ""}</span></div><div class="distribution-stop-detail">${esc(stop.distribution_instructions || stop.planned_trolley_summary || "No delivery instructions")}</div>${editable ? `<select data-stop-status="${esc(stop.run_stop_id)}">${statuses.map((status) => `<option value="${status}" ${status === stop.stop_status ? "selected" : ""}>${titleCase(status)}</option>`).join("")}</select>` : statusPill(stop.stop_status)}</article>`).join("") : `<div class="distribution-empty">No stops in this route.</div>`;
  }

  async function updateStopStatus(stopId, status) {
    try { state.routeDetail = await rpc("set_distribution_stop_status", { p_run_stop_id: stopId, p_status: status, p_notes: null }); renderStopList(); await load(el.date.value); }
    catch (error) { setInline(el.stopMessage, error.message || "Stop status could not be updated."); }
  }

  async function addManualStop() {
    if (!state.routeDetail) return; el.manualSave.disabled = true; setInline(el.stopMessage, "");
    try {
      state.routeDetail = await rpc("save_distribution_manual_stop", { p_stop: { run_id: state.routeDetail.run_id, stop_kind: el.manualKind.value, customer_name: el.manualName.value, eircode: el.manualEircode.value, estimated_kg: el.manualKg.value || null, distribution_instructions: el.manualInstructions.value } });
      el.manualName.value = ""; el.manualEircode.value = ""; el.manualKg.value = ""; el.manualInstructions.value = ""; el.manualForm.classList.add("hidden"); renderStopList(); await load(el.date.value);
    } catch (error) { setInline(el.stopMessage, error.message || "Operational stop could not be added."); } finally { el.manualSave.disabled = false; }
  }

  function field(key, label, type = "text", value = "", options = null, wide = false) {
    const control = type === "select" ? `<select data-master-key="${key}">${options.map(([id, text]) => `<option value="${esc(id)}" ${String(id) === String(value ?? "") ? "selected" : ""}>${esc(text)}</option>`).join("")}</select>` : type === "textarea" ? `<textarea data-master-key="${key}" rows="3">${esc(value)}</textarea>` : `<input data-master-key="${key}" type="${type}" value="${esc(value)}">`;
    return `<label class="${wide ? "wide" : ""}"><span>${esc(label)}</span>${control}</label>`;
  }

  function openMaster(kind, item = {}) {
    state.master = { kind, item }; setInline(el.masterMessage, ""); const title = { driver: "Driver", vehicle: "Vehicle", route: "Route", absence: "Driver leave", maintenance: "Vehicle maintenance", defect: "Vehicle defect" }[kind];
    el.masterEyebrow.textContent = kind === "route" ? "Route master" : kind === "vehicle" || kind === "maintenance" || kind === "defect" ? "Fleet" : "Driver management"; el.masterTitle.textContent = item[`${kind}_id`] ? `Edit ${title}` : `Add ${title}`;
    if (kind === "driver") el.masterFields.innerHTML = field("driver_id", "", "hidden", item.driver_id || "") + field("driver_code", "Driver code", "text", item.driver_code || "") + field("display_name", "Full name", "text", item.display_name || "") + field("phone", "Phone", "text", item.phone || "") + field("email", "Email", "email", item.email || "") + field("licence_number", "Licence number", "text", item.licence_number || "") + field("licence_expires_on", "Licence expiry", "date", localDate(item.licence_expires_on)) + field("cpc_expires_on", "CPC expiry", "date", localDate(item.cpc_expires_on)) + field("employment_status", "Employment", "select", item.employment_status || "ACTIVE", [["ACTIVE","Active"],["INACTIVE","Inactive"],["SUSPENDED","Suspended"]]) + field("availability_status", "Availability", "select", item.availability_status || "AVAILABLE", [["AVAILABLE","Available"],["LEAVE","Leave"],["UNAVAILABLE","Unavailable"]]) + field("notes", "Notes", "textarea", item.notes || "", null, true);
    if (kind === "vehicle") el.masterFields.innerHTML = field("vehicle_id", "", "hidden", item.vehicle_id || "") + field("registration_number", "Registration", "text", item.registration_number || "") + field("display_name", "Vehicle name", "text", item.display_name || "") + field("vehicle_type", "Type", "select", item.vehicle_type || "TRUCK", [["TRUCK","Truck"],["VAN","Van"],["OTHER","Other"]]) + field("operational_status", "Operational status", "select", item.operational_status || "AVAILABLE", [["AVAILABLE","Available"],["MAINTENANCE","Maintenance"],["OUT_OF_SERVICE","Out of service"]]) + field("capacity_kg", "Capacity KG", "number", item.capacity_kg || "") + field("capacity_trolleys", "Trolley capacity", "number", item.capacity_trolleys || "") + field("odometer_km", "Odometer KM", "number", item.odometer_km || "") + field("road_tax_expires_on", "Road tax expiry", "date", localDate(item.road_tax_expires_on)) + field("insurance_expires_on", "Insurance expiry", "date", localDate(item.insurance_expires_on)) + field("test_expires_on", "Test expiry", "date", localDate(item.test_expires_on)) + field("service_due_on", "Service due", "date", localDate(item.service_due_on)) + field("notes", "Notes", "textarea", item.notes || "", null, true);
    if (kind === "route") el.masterFields.innerHTML = field("route_id", "", "hidden", item.route_id || "") + field("route_code", "Route code", "text", item.route_code || "") + field("display_name", "Display name", "text", item.display_name || "") + field("route_color", "Route colour", "color", item.route_color || "#0f8b8d") + field("route_kind", "Route type", "select", item.route_kind || "STANDARD", [["STANDARD","Standard"],["COLLECTION","Collection"],["AD_HOC","Ad hoc"],["SUPPORT","Support"]]) + field("sort_order", "Display order", "number", item.sort_order || 0) + field("default_km", "Planned KM", "number", item.default_km || 0) + field("default_hours", "Planned hours", "number", item.default_hours || 0) + field("notes", "Notes", "textarea", item.notes || "", null, true);
    if (kind === "absence") el.masterFields.innerHTML = field("driver_id", "Driver", "select", item.driver_id || "", drivers().map((driver) => [driver.driver_id, `${driver.display_name} · ${driver.driver_code}`])) + field("absence_type", "Type", "select", "LEAVE", [["LEAVE","Leave"],["DAY_OFF","Day off"],["OTHER","Other"]]) + field("starts_on", "Start date", "date", localDate(state.data?.business_date)) + field("ends_on", "End date", "date", localDate(state.data?.business_date)) + field("notes", "Notes", "textarea", "", null, true);
    if (kind === "maintenance") el.masterFields.innerHTML = field("vehicle_id", "Vehicle", "select", item.vehicle_id || "", vehicles().map((vehicle) => [vehicle.vehicle_id, vehicle.registration_number])) + field("maintenance_type", "Maintenance type", "text", "") + field("maintenance_status", "Status", "select", "PLANNED", [["PLANNED","Planned"],["IN_PROGRESS","In progress"],["COMPLETED","Completed"]]) + field("starts_on", "Start date", "date", localDate(state.data?.business_date)) + field("ends_on", "End date", "date", "") + field("supplier_name", "Supplier", "text", "") + field("cost_amount", "Cost", "number", "") + field("notes", "Notes", "textarea", "", null, true);
    if (kind === "defect") el.masterFields.innerHTML = field("vehicle_id", "Vehicle", "select", item.vehicle_id || "", vehicles().map((vehicle) => [vehicle.vehicle_id, vehicle.registration_number])) + field("severity", "Severity", "select", "MEDIUM", [["LOW","Low"],["MEDIUM","Medium"],["HIGH","High"],["CRITICAL","Critical"]]) + field("defect_category", "Category", "text", "") + field("description", "Description", "textarea", "", null, true);
    el.masterDialog.showModal();
  }

  function masterValues() { const value = {}; el.masterFields.querySelectorAll("[data-master-key]").forEach((input) => { value[input.dataset.masterKey] = input.value || null; }); return value; }
  async function saveMaster() {
    const { kind } = state.master || {}; const value = masterValues(); const procedures = { driver: "save_distribution_driver", vehicle: "save_fleet_vehicle", route: "save_distribution_route", absence: "save_distribution_driver_absence", maintenance: "save_fleet_vehicle_maintenance", defect: "save_fleet_vehicle_defect" }; const params = { driver: "p_driver", vehicle: "p_vehicle", route: "p_route", absence: "p_absence", maintenance: "p_maintenance", defect: "p_defect" };
    if (!procedures[kind]) return; const button = $("distributionMasterSave"); button.disabled = true; setInline(el.masterMessage, "");
    try { await rpc(procedures[kind], { [params[kind]]: value }); close(el.masterDialog); setMessage(`${titleCase(kind)} saved.`, "success"); await load(el.date.value); }
    catch (error) { setInline(el.masterMessage, error.message || "Record could not be saved."); } finally { button.disabled = false; }
  }

  function driverOnLeave(driverId, workDate) {
    return (state.roster?.absences || []).some((absence) => String(absence.driver_id) === String(driverId) && localDate(absence.starts_on) <= localDate(workDate) && localDate(absence.ends_on) >= localDate(workDate));
  }

  function syncRosterEntryControls() {
    el.rosterNote.disabled = el.rosterStatus.value === "CLEAR";
  }

  function rosterCellPreview(entry, driverId, workDate) {
    if (!entry) return `<span class="distribution-roster-preview empty">-</span>`;
    if (nonWorkingStatuses.has(entry.assignment_status)) return `<span class="distribution-roster-preview ${esc(String(entry.assignment_status).toLowerCase())}">${esc(rosterStatusLabel(entry.assignment_status))}</span>`;
    const route = rosterRoutes().find((item) => String(item.route_id) === String(entry.route_id)) || entry;
    const vehicle = entry.vehicle_registration_snapshot || "";
    const secondTurn = entry.vehicle_id && vehicleSecondTurn(entry.vehicle_id, workDate);
    const color = validColor(route.route_color || entry.route_color_snapshot);
    return `<span class="distribution-roster-preview route" style="--route-color:${color};--route-text:${routeTextColor(color)}"><strong>${esc(route.route_code || entry.route_code_snapshot || "Route")}</strong><small>${esc(vehicle)}${secondTurn ? ` <b>2T</b>` : ""}</small></span>`;
  }

  function renderRosterRoutePicker(workDate) {
    const routeRows = rosterRoutes().filter((route) => routeAllowedForDay(route, workDate));
    const available = routeRows.filter((route) => !routeAssignedOnDay(route.route_id, workDate));
    const taken = routeRows.filter((route) => routeAssignedOnDay(route.route_id, workDate));
    const routeButton = (route, disabled = false) => {
      const selected = String(state.pendingRouteId) === String(route.route_id);
      const color = validColor(route.route_color);
      return `<button class="distribution-roster-route-option ${selected ? "selected" : ""} ${disabled ? "taken" : ""}" type="button" data-roster-pending-route="${esc(route.route_id)}" style="--route-color:${color};--route-text:${routeTextColor(color)}" ${disabled ? "disabled" : ""}><strong>${esc(route.route_code || "Route")}</strong><span>${esc(route.display_name || route.route_code || "Route")}</span>${disabled ? `<small>assigned</small>` : String(route.route_kind || "").toUpperCase() !== "STANDARD" ? `<small>${esc(titleCase(route.route_kind))}</small>` : ""}</button>`;
    };
    el.rosterRouteButtons.innerHTML = available.length ? available.map((route) => routeButton(route)).join("") : `<div class="distribution-roster-empty-options">${routeRows.length ? "All routes for this day are already assigned." : "No routes configured for this day."}</div>`;
    el.rosterTakenButtons.innerHTML = taken.map((route) => routeButton(route, true)).join("");
    el.rosterTakenSection.classList.toggle("hidden", !taken.length);
  }

  function renderRosterVehiclePicker(workDate) {
    const vehicleButton = (vehicle) => {
      const usage = vehicleUsageForDay(vehicle.vehicle_id, workDate);
      const limit = vehicleDailyLimit(vehicle);
      const unavailable = !vehicle.active || vehicle.operational_status !== "AVAILABLE";
      const capacityHit = usage.length >= limit;
      const secondTurn = !unavailable && !capacityHit && limit > 1 && usage.length === 1;
      const [complianceLabel, complianceClass] = complianceForVehicle(vehicle);
      const warn = !unavailable && !capacityHit && complianceClass;
      const blocked = unavailable || capacityHit;
      const selected = String(state.pendingVehicleId) === String(vehicle.vehicle_id);
      const status = unavailable ? titleCase(vehicle.operational_status || "Unavailable") : capacityHit ? "Already assigned" : secondTurn ? "Second turn" : warn ? complianceLabel : titleCase(vehicle.vehicle_type || "Vehicle");
      return `<button class="distribution-roster-vehicle-option ${selected ? "selected" : ""} ${blocked ? "blocked" : ""} ${warn ? "warn" : ""} ${secondTurn ? "second-turn" : ""}" type="button" data-roster-pending-vehicle="${esc(vehicle.vehicle_id)}" ${blocked ? "disabled" : ""}><strong>${esc(vehicle.registration_number)}</strong><span>${esc(vehicle.display_name || titleCase(vehicle.vehicle_type || "Vehicle"))}</span><small>${esc(status)}${secondTurn ? ` <b>2T</b>` : ""}</small></button>`;
    };
    el.rosterVehicleButtons.innerHTML = rosterVehicles().length ? rosterVehicles().map(vehicleButton).join("") : `<div class="distribution-roster-empty-options">No vehicles registered.</div>`;
  }

  function updateRosterConfirm() {
    const route = rosterRoutes().find((item) => String(item.route_id) === String(state.pendingRouteId));
    const vehicle = rosterVehicles().find((item) => String(item.vehicle_id) === String(state.pendingVehicleId));
    if (!route) { el.rosterConfirm.disabled = true; el.rosterConfirm.textContent = "Select a route above"; return; }
    if (!vehicle) { el.rosterConfirm.disabled = true; el.rosterConfirm.textContent = "Select a vehicle above"; return; }
    const turn = vehicleSecondTurn(vehicle.vehicle_id, el.rosterDate.value) ? " - 2T" : "";
    el.rosterConfirm.disabled = false;
    el.rosterConfirm.textContent = `Assign: ${route.display_name || route.route_code} - ${vehicle.registration_number}${turn}`;
  }

  function selectPendingRoute(routeId) {
    state.pendingRouteId = routeId || "";
    el.rosterRoute.value = state.pendingRouteId;
    renderRosterRoutePicker(el.rosterDate.value);
    updateRosterConfirm();
  }

  function selectPendingVehicle(vehicleId) {
    state.pendingVehicleId = String(state.pendingVehicleId) === String(vehicleId) ? "" : vehicleId || "";
    el.rosterVehicle.value = state.pendingVehicleId;
    renderRosterVehiclePicker(el.rosterDate.value);
    updateRosterConfirm();
  }

  function openRosterEntryLegacy(routeId, workDate) {
    const route = rosterRoutes().find((item) => String(item.route_id) === String(routeId)); if (!route) return;
    const entry = rosterEntry(routeId, workDate) || {};
    const unavailableDriver = (driver) => driver.availability_status !== "AVAILABLE" || driverOnLeave(driver.driver_id, workDate);
    el.rosterTitle.textContent = `${route.route_code} - ${route.display_name}`;
    el.rosterSubtitle.textContent = fmtDate(workDate);
    el.rosterRouteId.value = route.route_id; el.rosterDate.value = workDate; el.rosterRoute.innerHTML = optionList(rosterRoutes().map((item) => ({ id: item.route_id, ...item })), route.route_id, (item) => `${item.route_code} - ${item.display_name}`);
    el.rosterStatus.value = entry.assignment_status || "PLANNED";
    el.rosterPrimary.innerHTML = optionList(rosterDrivers().map((driver) => ({ id: driver.driver_id, ...driver, disabled: unavailableDriver(driver) })), entry.primary_driver_id, (driver) => `${driver.display_name} - ${driver.driver_code}`);
    el.rosterSupport.innerHTML = optionList(rosterDrivers().map((driver) => ({ id: driver.driver_id, ...driver, disabled: unavailableDriver(driver) })), entry.support_driver_id, (driver) => `${driver.display_name} - ${driver.driver_code}`);
    el.rosterVehicle.innerHTML = optionList(rosterVehicles().map((vehicle) => ({ id: vehicle.vehicle_id, ...vehicle, disabled: !vehicle.active || vehicle.operational_status !== "AVAILABLE" })), entry.vehicle_id, (vehicle) => `${vehicle.registration_number}${vehicle.display_name ? ` - ${vehicle.display_name}` : ""}`);
    el.rosterNote.value = entry.entry_note || ""; setInline(el.rosterMessage, ""); syncRosterEntryControls(); el.rosterDialog.showModal();
  }

  function openRosterEntryForDriver(driverId, workDate) {
    const driver = rosterDrivers().find((item) => String(item.driver_id) === String(driverId)); if (!driver || isSunday(workDate)) return;
    if (driverOnLeave(driverId, workDate)) { setMessage(`${driver.display_name} has approved leave on ${fmtDate(workDate)}.`, ""); return; }
    const entry = driverRosterEntry(driverId, workDate) || {};
    state.rosterEditing = { driverId, workDate, entryId: entry.distribution_roster_entry_id || null };
    state.pendingRouteId = entry.assignment_status === "PLANNED" ? entry.route_id || "" : "";
    state.pendingVehicleId = entry.assignment_status === "PLANNED" ? entry.vehicle_id || "" : "";
    el.rosterTitle.textContent = driver.display_name;
    el.rosterSubtitle.textContent = fmtDate(workDate);
    el.rosterRouteId.value = entry.route_id || ""; el.rosterDate.value = workDate; el.rosterDriverId.value = driverId;
    el.rosterStatus.value = entry.assignment_status || "PLANNED";
    el.rosterPrimary.innerHTML = optionList([{ id: driver.driver_id, ...driver }], driver.driver_id, (item) => `${item.display_name} - ${item.driver_code}`);
    el.rosterSupport.innerHTML = optionList([], "", () => "");
    el.rosterRoute.value = state.pendingRouteId; el.rosterVehicle.value = state.pendingVehicleId;
    el.rosterCurrent.innerHTML = rosterCellPreview(entry, driverId, workDate);
    el.rosterDayTag.textContent = fmtDate(workDate);
    renderRosterRoutePicker(workDate); renderRosterVehiclePicker(workDate); updateRosterConfirm();
    el.rosterNote.value = entry.entry_note || ""; setInline(el.rosterMessage, ""); syncRosterEntryControls(); el.rosterDialog.showModal();
  }

  function applyRosterEntry() {
    const routeId = state.pendingRouteId || el.rosterRoute.value; const workDate = el.rosterDate.value; const driverId = el.rosterDriverId.value || el.rosterPrimary.value;
    const route = rosterRoutes().find((item) => String(item.route_id) === String(routeId));
    const status = el.rosterStatus.value;
    if (status === "CLEAR") {
      state.roster.entries = rosterEntries().filter((entry) => !sameRosterCell(entry, driverId, workDate));
      state.rosterDirty = true; close(el.rosterDialog); render(); return;
    }
    if (driverAssignedOnDay(driverId, workDate)) { setInline(el.rosterMessage, "This driver is already assigned on this day."); return; }
    if (status === "PLANNED" && !route) { setInline(el.rosterMessage, "Working requires a Route."); return; }
    if (status === "PLANNED" && routeAssignedOnDay(routeId, workDate)) { setInline(el.rosterMessage, "This Route is already assigned on this day."); return; }
    if (status === "PLANNED" && !state.pendingVehicleId) { setInline(el.rosterMessage, "Working requires a Vehicle."); return; }
    const primary = rosterDrivers().find((item) => String(item.driver_id) === String(driverId));
    const vehicle = rosterVehicles().find((item) => String(item.vehicle_id) === String(state.pendingVehicleId));
    if (status === "PLANNED" && (!vehicle?.active || vehicle.operational_status !== "AVAILABLE")) { setInline(el.rosterMessage, "This Vehicle is not available."); return; }
    if (status === "PLANNED" && vehicleUsageForDay(vehicle.vehicle_id, workDate).length >= vehicleDailyLimit(vehicle)) { setInline(el.rosterMessage, "This Vehicle has reached its daily limit."); return; }
    const value = {
      ...(driverRosterEntry(driverId, workDate) || {}), route_id: status === "PLANNED" ? routeId : null, work_date: workDate, assignment_status: status,
      primary_driver_id: driverId || null,
      support_driver_id: null,
      vehicle_id: status === "PLANNED" ? state.pendingVehicleId || null : null,
      route_code_snapshot: route?.route_code || null, route_name_snapshot: route?.display_name || null, route_color_snapshot: route?.route_color || null,
      primary_driver_name_snapshot: primary?.display_name || null,
      support_driver_name_snapshot: null,
      vehicle_registration_snapshot: status === "PLANNED" ? vehicle?.registration_number || null : null,
      vehicle_name_snapshot: status === "PLANNED" ? vehicle?.display_name || null : null,
      entry_note: el.rosterNote.value || null
    };
    const index = rosterEntries().findIndex((entry) => sameRosterCell(entry, driverId, workDate));
    if (index >= 0) state.roster.entries.splice(index, 1, value); else state.roster.entries.push(value);
    state.rosterDirty = true; close(el.rosterDialog); render();
  }

  function rosterPayload() {
    const document = state.roster?.document || {};
    return {
      distribution_roster_version_id: document.distribution_roster_version_id || null,
      week_start: state.roster.week_start,
      row_version: document.row_version || null,
      roster_note: document?.roster_note ?? state.roster?.roster_note ?? null,
      required_routes: state.roster?.required_routes || {},
      entries: rosterEntries().map((entry) => ({ work_date: localDate(entry.work_date), route_id: entry.route_id, assignment_status: entry.assignment_status, primary_driver_id: entry.primary_driver_id || null, support_driver_id: entry.support_driver_id || null, vehicle_id: entry.vehicle_id || null, entry_note: entry.entry_note || null }))
    };
  }

  async function saveRoster() {
    const button = el.panel.querySelector("[data-roster-save]"); if (button) button.disabled = true;
    try {
      state.roster = await rpc("save_distribution_roster_week", { p_roster: rosterPayload() }); state.rosterDirty = false;
      setMessage("Distribution roster draft saved.", "success"); render(); return true;
    } catch (error) {
      console.error(error);
      setMessage(`${error.message || "Distribution roster could not be saved."} If this mentions status, route_id or a missing RPC, apply the updated Distribution roster migration first.`);
      return false;
    }
    finally { if (button && button.isConnected) button.disabled = false; }
  }

  async function publishRoster() {
    if (state.rosterDirty || !state.roster?.document) { const saved = await saveRoster(); if (!saved) return; }
    const document = state.roster.document;
    try {
      state.roster = await rpc("publish_distribution_roster_week", { p_roster_version_id: document.distribution_roster_version_id, p_expected_row_version: document.row_version });
      state.rosterDirty = false; setMessage("Distribution roster published and daily runs are ready.", "success"); await load(el.date.value); render();
    } catch (error) { setMessage(error.message || "Distribution roster could not be published."); }
  }

  async function setRunStatus(runId, status) {
    try { await rpc("set_distribution_route_run_status", { p_run_id: runId, p_status: status, p_notes: null }); setMessage(`Route marked ${titleCase(status)}.`, "success"); await load(el.date.value); }
    catch (error) { setMessage(error.message || "Route status could not be updated."); }
  }

  async function saveActuals() {
    const button = el.panel.querySelector("[data-actuals-save]"); if (button) button.disabled = true;
    const driverById = new Map((state.actuals?.drivers || []).map((driver) => [String(driver.driver_id), driver]));
    const vehicleById = new Map((state.actuals?.vehicles || []).map((vehicle) => [String(vehicle.vehicle_id), vehicle]));
    const driverActuals = [...el.panel.querySelectorAll("[data-actual-driver]")].map((input) => ({ driver_id: input.dataset.actualDriver, planned_hours: input.dataset.plannedHours || 0, actual_hours: input.value === "" ? null : input.value, notes: driverById.get(String(input.dataset.actualDriver))?.notes || null })).filter((item) => item.actual_hours !== null);
    const vehicleInputs = new Map([...el.panel.querySelectorAll("[data-actual-vehicle]")].map((input) => [String(input.dataset.actualVehicle), input]));
    const vehicleMileage = [...vehicleInputs.entries()].map(([vehicleId, input]) => {
      const odometer = el.panel.querySelector(`[data-actual-odometer="${CSS.escape(vehicleId)}"]`);
      return { vehicle_id: vehicleId, planned_km: input.dataset.plannedKm || 0, actual_km: input.value === "" ? null : input.value, odometer_km: odometer?.value || null, notes: vehicleById.get(vehicleId)?.notes || null };
    }).filter((item) => item.actual_km !== null || item.odometer_km !== null);
    try {
      state.actuals = await rpc("save_distribution_actuals_week", { p_week_start: state.actuals.week_start, p_driver_actuals: driverActuals, p_vehicle_mileage: vehicleMileage });
      setMessage("Distribution actuals saved to history.", "success"); render();
    } catch (error) {
      console.error(error); setMessage(error.message || "Distribution actuals could not be saved.");
    } finally { if (button && button.isConnected) button.disabled = false; }
  }

  async function switchDistributionTab(tabId) { const next = distributionTabIds.includes(tabId) ? tabId : "board"; if (next === state.activeTab) return; state.activeTab = next; if (location.hash !== `#${state.activeTab}`) history.replaceState(null, "", `#${state.activeTab}`); if (state.activeTab === "customers") { render(); await loadRouteCustomers(); } else if (state.activeTab === "roster") await loadRoster(); else if (state.activeTab === "actuals") await loadActuals(); else if (state.activeTab === "history") await loadHistory(); else render(); }
  el.tabs.addEventListener("click", async (event) => { const button = event.target.closest("[data-tab]"); if (!button) return; await switchDistributionTab(button.dataset.tab); });
  window.addEventListener("hashchange", () => switchDistributionTab(String(location.hash || "").replace("#", "")));
  el.panel.addEventListener("click", (event) => { const routeCustomersToggle = event.target.closest("[data-route-customers-toggle]"); const routeCustomersAction = event.target.closest("[data-route-customers-action]"); const rosterDriver = event.target.closest("[data-roster-driver]"); const rosterCell = event.target.closest("[data-roster-route]"); const rosterSave = event.target.closest("[data-roster-save]"); const rosterPublish = event.target.closest("[data-roster-publish]"); const rosterShift = event.target.closest("[data-roster-week-shift]"); const actualsSave = event.target.closest("[data-actuals-save]"); const actualsShift = event.target.closest("[data-actuals-week-shift]"); const historyRefresh = event.target.closest("[data-history-refresh]"); const plan = event.target.closest("[data-route-plan]"); const stops = event.target.closest("[data-route-stops]"); const status = event.target.closest("[data-route-status]"); const master = event.target.closest("[data-master-action]"); if (routeCustomersToggle) { const key = routeCustomersToggle.dataset.routeCustomersToggle; if (state.routeCustomersCollapsed.has(key)) state.routeCustomersCollapsed.delete(key); else state.routeCustomersCollapsed.add(key); renderRouteCustomers(); } else if (routeCustomersAction) { if (routeCustomersAction.dataset.routeCustomersAction === "expand") state.routeCustomersCollapsed.clear(); else routeCustomerGroups(state.routeCustomersWeekly?.items || []).forEach((group) => state.routeCustomersCollapsed.add(routeCustomerKey(group))); renderRouteCustomers(); } else if (rosterDriver) openRosterEntryForDriver(rosterDriver.dataset.rosterDriver, rosterDriver.dataset.rosterDate); else if (rosterCell) openRosterEntryLegacy(rosterCell.dataset.rosterRoute, rosterCell.dataset.rosterDate); else if (rosterSave) saveRoster(); else if (rosterPublish) publishRoster(); else if (rosterShift) { const date = new Date(`${state.roster.week_start}T12:00:00`); date.setDate(date.getDate() + Number(rosterShift.dataset.rosterWeekShift) * 7); loadRoster(date.toISOString().slice(0, 10)); } else if (actualsSave) saveActuals(); else if (actualsShift) { const date = new Date(`${state.actuals.week_start}T12:00:00`); date.setDate(date.getDate() + Number(actualsShift.dataset.actualsWeekShift) * 7); loadActuals(date.toISOString().slice(0, 10)); } else if (historyRefresh) loadHistory(); else if (plan) openRun(plan.dataset.routePlan); else if (stops) openStops(stops.dataset.routeStops); else if (status) setRunStatus(status.dataset.runId, status.dataset.routeStatus); else if (master) { const [action, id] = master.dataset.masterAction.split(":"); if (action === "new-driver") openMaster("driver"); if (action === "new-vehicle") openMaster("vehicle"); if (action === "new-route") openMaster("route"); if (action === "edit-driver") openMaster("driver", drivers().find((item) => String(item.driver_id) === id)); if (action === "edit-vehicle") openMaster("vehicle", vehicles().find((item) => String(item.vehicle_id) === id)); if (action === "edit-route") openMaster("route", routes().find((item) => String(item.route_id) === id)); if (action === "leave-driver") openMaster("absence", { driver_id: id }); if (action === "maintenance-vehicle") openMaster("maintenance", { vehicle_id: id }); if (action === "defect-vehicle") openMaster("defect", { vehicle_id: id }); } });
  el.runForm.addEventListener("submit", (event) => { event.preventDefault(); saveRun(); }); el.masterForm.addEventListener("submit", (event) => { event.preventDefault(); saveMaster(); }); el.rosterForm.addEventListener("submit", (event) => { event.preventDefault(); applyRosterEntry(); }); el.rosterStatus.addEventListener("change", syncRosterEntryControls);
  el.rosterDialog.addEventListener("click", (event) => {
    const route = event.target.closest("[data-roster-pending-route]");
    const vehicle = event.target.closest("[data-roster-pending-vehicle]");
    const quick = event.target.closest("[data-roster-quick-status]");
    if (route) { selectPendingRoute(route.dataset.rosterPendingRoute); return; }
    if (vehicle) { selectPendingVehicle(vehicle.dataset.rosterPendingVehicle); return; }
    if (event.target.closest("#distributionRosterConfirm")) { el.rosterStatus.value = "PLANNED"; applyRosterEntry(); return; }
    if (quick) { el.rosterStatus.value = quick.dataset.rosterQuickStatus; applyRosterEntry(); }
  });
  el.stopList.addEventListener("change", (event) => { const select = event.target.closest("[data-stop-status]"); if (select) updateStopStatus(select.dataset.stopStatus, select.value); });
  el.addStop.addEventListener("click", () => el.manualForm.classList.toggle("hidden")); el.manualSave.addEventListener("click", addManualStop);
  el.panel.addEventListener("change", (event) => { const routeCustomersDay = event.target.closest("[data-route-customers-day]"); const routeCustomersRoute = event.target.closest("[data-route-customers-route]"); const routeCustomersSearch = event.target.closest("[data-route-customers-search]"); const week = event.target.closest("#distributionRosterWeek"); const actualsWeek = event.target.closest("#distributionActualsWeek"); const required = event.target.closest("[data-required-routes-date]"); if (routeCustomersDay || routeCustomersRoute || routeCustomersSearch) { if (routeCustomersDay) state.routeCustomersDay = routeCustomersDay.value; if (routeCustomersRoute) state.routeCustomersRoute = routeCustomersRoute.value; if (routeCustomersSearch) state.routeCustomersSearch = routeCustomersSearch.value.trim(); renderRouteCustomers(); } else if (week) loadRoster(weekStartFromInput(week.value)); else if (actualsWeek) loadActuals(weekStartFromInput(actualsWeek.value)); else if (required && state.roster) renderRoster(); });
  el.panel.addEventListener("input", (event) => { const note = event.target.closest("#distributionRosterNote"); const required = event.target.closest("[data-required-routes-date]"); if (!state.roster || (!note && !required)) return; if (note) { if (state.roster.document) state.roster.document.roster_note = note.value; else state.roster.roster_note = note.value; } if (required) { state.roster.required_routes = { ...(state.roster.required_routes || {}), [required.dataset.requiredRoutesDate]: Math.max(0, Number(required.value || 0)) }; } state.rosterDirty = true; const save = el.panel.querySelector("[data-roster-save]"); if (save) save.disabled = false; });
  document.addEventListener("click", (event) => { const closeButton = event.target.closest("[data-close-dialog]"); if (closeButton) close($(closeButton.dataset.closeDialog)); });
  el.date.addEventListener("change", () => load(el.date.value)); el.today.addEventListener("click", () => load(nextOperatingDate())); el.refresh.addEventListener("click", () => load(el.date.value));
  if (window.ELIS_SUPABASE_ERROR || !client) { setMessage(window.ELIS_SUPABASE_ERROR || "Supabase could not be initialized."); return; }
  try { const { data: { session }, error } = await client.auth.getSession(); if (error) throw error; if (!session?.user) { window.location.href = "../index.html"; return; } const requestedTab = state.activeTab; state.activeTab = "board"; await load(nextOperatingDate()); await switchDistributionTab(requestedTab); }
  catch (error) { console.error(error); setMessage(error.message || "Distribution could not be initialized."); }
});
