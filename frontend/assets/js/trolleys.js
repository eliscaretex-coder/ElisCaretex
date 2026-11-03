"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;

  const elements = {
    asOfDate: document.getElementById("trolleyAsOfDate"),
    signOut: document.getElementById("trolleySignOutButton"),
    pageMessage: document.getElementById("trolleyPageMessage"),
    tabs: document.getElementById("trolleyTabs"),
    main: document.getElementById("trolleyMainPanel"),
    recordModal: document.getElementById("trolleyRecordModal"),
    recordBackdrop: document.getElementById("trolleyRecordBackdrop"),
    recordClose: document.getElementById("trolleyRecordClose"),
    recordCloseSecondary: document.getElementById("trolleyRecordCloseSecondary"),
    recordTitle: document.getElementById("trolleyRecordTitle"),
    recordSubtitle: document.getElementById("trolleyRecordSubtitle"),
    recordBody: document.getElementById("trolleyRecordBody"),
    reviewModal: document.getElementById("trolleyReviewModal"),
    reviewBackdrop: document.getElementById("trolleyReviewBackdrop"),
    reviewClose: document.getElementById("trolleyReviewClose"),
    reviewCancel: document.getElementById("trolleyReviewCancel"),
    reviewForm: document.getElementById("trolleyReviewForm"),
    reviewStayId: document.getElementById("trolleyReviewStayId"),
    reviewAction: document.getElementById("trolleyReviewAction"),
    reviewTitle: document.getElementById("trolleyReviewTitle"),
    reviewSubtitle: document.getElementById("trolleyReviewSubtitle"),
    reviewSummary: document.getElementById("trolleyReviewSummary"),
    reviewNotes: document.getElementById("trolleyReviewNotes"),
    reviewRequiredMarker: document.getElementById("trolleyReviewRequiredMarker"),
    reviewMessage: document.getElementById("trolleyReviewMessage"),
    reviewConfirm: document.getElementById("trolleyReviewConfirm")
  };

  const trolleyTabIds = ["locations", "master", "types"];
  const initialTab = String(location.hash || "").replace("#", "");

  const state = {
    activeTab: trolleyTabIds.includes(initialTab) ? initialTab : "locations",
    capabilities: {},
    trolleyTypes: [],
    warningDays: 14,
    overdueDays: 30,
    locationSearch: "",
    locationFilter: "ALL",
    locationSort: "ATTENTION",
    locationAttentionOnly: false,
    locationData: null,
    masterSearch: "",
    masterFilter: "ALL",
    typeMasterItems: [],
    typeSelectedId: "",
    typeEditing: false,
    masterAction: "",
    queueItems: [],
    busy: false
  };

  function localDateValue(date = new Date()) {
    const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
    return local.toISOString().slice(0, 10);
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function formatDate(value) {
    if (!value) return "—";
    const parsed = new Date(`${String(value).slice(0, 10)}T12:00:00`);
    return new Intl.DateTimeFormat("en-IE", {
      day: "2-digit",
      month: "short",
      year: "numeric"
    }).format(parsed);
  }

  function formatDateTime(value) {
    if (!value) return "—";
    return new Intl.DateTimeFormat("en-IE", {
      day: "2-digit",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit"
    }).format(new Date(value));
  }

  function titleCaseCode(value) {
    return String(value || "")
      .toLowerCase()
      .split("_")
      .map((part) => part ? part[0].toUpperCase() + part.slice(1) : "")
      .join(" ");
  }

  function safeRouteColor(value) {
    const color = String(value || "").trim();
    return /^#[0-9a-f]{6}$/i.test(color) ? color : "";
  }

  function routeTextColor(value) {
    const color = safeRouteColor(value);
    if (!color) return "#0f172a";
    const n = Number.parseInt(color.slice(1), 16);
    const r = (n >> 16) & 255;
    const g = (n >> 8) & 255;
    const b = n & 255;
    return ((r * 299 + g * 587 + b * 114) / 1000) > 150 ? "#172033" : "#ffffff";
  }

  function routeBadge(routeName, routeCode, routeColor) {
    const label = routeName || (routeCode ? `Route ${routeCode}` : "Route not recorded");
    const color = safeRouteColor(routeColor);
    if (!color) return `<span class="trolleys-route-badge neutral" title="Current Route master context">${escapeHtml(label)}</span>`;
    return `<span class="trolleys-route-badge" title="Current Route master colour · may change with Route master data" style="background:${color};color:${routeTextColor(color)}">${escapeHtml(label)}</span>`;
  }

  function setPageMessage(text = "", type = "") {
    elements.pageMessage.textContent = text;
    elements.pageMessage.className = "trolleys-page-message";
    if (type) elements.pageMessage.classList.add(type);
  }

  function setInlineMessage(element, text = "", type = "") {
    if (!element) return;
    element.textContent = text;
    element.className = "trolleys-inline-message";
    if (type) element.classList.add(type);
  }

  function friendlyError(error) {
    const message = String(error?.message || "The operation could not be completed.");
    const known = [
      "Trolley code already exists.",
      "Trolley code is required.",
      "Trolley not found.",
      "A reason is required.",
      "Review notes are required to resolve an exception.",
      "A trolley with an open customer assignment cannot be marked out of service.",
      "A trolley with an open customer assignment cannot be retired.",
      "Only an out-of-service trolley can be returned to service.",
      "Trolley is already out of service.",
      "Trolley is already retired.",
      "A retired trolley cannot be changed.",
      "Trolley type code already exists.",
      "Trolley type display code already exists.",
      "Trolley type was not found.",
      "Trolley type name is required and must be 120 characters or fewer.",
      "Enter both trolley footprint length and width, or leave both empty.",
      "Trolley footprint length must be greater than zero.",
      "Trolley footprint width must be greater than zero.",
      "Trolley tare weight must be greater than zero.",
      "Your active role does not allow Trolley Type Master changes."
    ];
    return known.find((item) => message.includes(item)) || message;
  }

  async function rpc(name, args = {}) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function statusBadge(status) {
    const normalized = String(status || "UNKNOWN").toLowerCase().replaceAll("_", "-");
    return `<span class="trolleys-status ${escapeHtml(normalized)}">${escapeHtml(titleCaseCode(status))}</span>`;
  }

  function attentionBadge(attention) {
    if (!attention || attention === "NORMAL") {
      return '<span class="trolleys-muted">—</span>';
    }
    const normalized = String(attention).toLowerCase();
    return `<span class="trolleys-attention ${escapeHtml(normalized)}">${escapeHtml(titleCaseCode(attention))}</span>`;
  }

  function reviewStatusBadge(status) {
    const normalized = String(status || "PENDING").toLowerCase().replaceAll("_", "-");
    return `<span class="trolleys-review-status ${escapeHtml(normalized)}">${escapeHtml(titleCaseCode(status))}</span>`;
  }

  function kpi(value, label, tone = "") {
    return `
      <article class="trolleys-kpi ${escapeHtml(tone)}">
        <strong>${Number(value || 0)}</strong>
        <span>${escapeHtml(label)}</span>
      </article>
    `;
  }

  function renderLoading(label = "Loading...") {
    elements.main.innerHTML = `
      <div class="trolleys-loading">
        <span class="trolleys-spinner" aria-hidden="true"></span>
        <p>${escapeHtml(label)}</p>
      </div>
    `;
  }

  function trolleyTypeOptions(selectedId = "") {
    return state.trolleyTypes.map((type) => {
      const selected = type.trolley_type_id === selectedId ? " selected" : "";
      return `<option value="${escapeHtml(type.trolley_type_id)}"${selected}>${escapeHtml(type.trolley_type_name)} · ${escapeHtml(type.display_code)}</option>`;
    }).join("");
  }

  async function refreshReferenceData() {
    const reference = await rpc("get_trolley_reference_data");
    state.capabilities = reference?.capabilities || {};
    state.trolleyTypes = Array.isArray(reference?.trolley_types) ? reference.trolley_types : [];
    state.warningDays = Number(reference?.warning_days || 14);
    state.overdueDays = Number(reference?.overdue_days || 30);
    return reference;
  }

  function optionalNumber(value) {
    const text = String(value ?? "").trim();
    if (!text) return null;
    const number = Number(text);
    return Number.isFinite(number) ? number : null;
  }

  function formatNumber(value, digits = 1) {
    if (value == null || value === "") return "—";
    const number = Number(value);
    if (!Number.isFinite(number)) return "—";
    return new Intl.NumberFormat("en-IE", { maximumFractionDigits: digits }).format(number);
  }

  function trolleyFootprintArea(lengthCm, widthCm) {
    const length = Number(lengthCm);
    const width = Number(widthCm);
    if (!(length > 0) || !(width > 0)) return null;
    return (length * width) / 10000;
  }

  function availableTabs() {
    const tabs = [
      { id: "locations", label: "Locations" },
      { id: "master", label: "Trolley Master" },
      { id: "types", label: "Trolley Types" }
    ];


    return tabs;
  }

  function renderTabs() {
    const tabs = availableTabs();
    if (!tabs.some((tab) => tab.id === state.activeTab)) state.activeTab = "locations";

    elements.tabs.innerHTML = tabs.map((tab) => `
      <button
        class="trolleys-tab${tab.id === state.activeTab ? " active" : ""}"
        type="button"
        data-tab="${escapeHtml(tab.id)}"
        aria-current="${tab.id === state.activeTab ? "page" : "false"}"
      >${escapeHtml(tab.label)}</button>
    `).join("");
  }

  function trackingStateMeta(trolley, current) {
    const status = String(trolley?.status || "UNKNOWN").toUpperCase();
    if (status === "IN_PRODUCTION" && current) {
      return {
        tone: "prepared",
        label: "Prepared at Elis Laundry",
        location: "Elis Laundry",
        detail: current.customer_name
          ? `Prepared for ${current.customer_name} · planned delivery ${formatDate(current.planned_delivery_on)}`
          : `Prepared for delivery ${formatDate(current.planned_delivery_on)}`,
        days: null,
        daysLabel: "not yet at customer"
      };
    }
    if (status === "AT_CUSTOMER" && current) {
      const days = current.days_out == null ? null : Number(current.days_out);
      return {
        tone: days != null && days >= state.overdueDays ? "overdue" : days != null && days >= state.warningDays ? "warning" : "customer",
        label: "At customer",
        location: current.customer_name || "Customer",
        detail: `Custody since ${formatDate(current.sent_on)}${current.production_area_code ? ` · from ${titleCaseCode(current.production_area_code)}` : ""}`,
        days,
        daysLabel: "days at customer"
      };
    }
    if (status === "AVAILABLE") {
      return { tone: "laundry", label: "At Elis Laundry", location: "Elis Laundry", detail: "Available for production", days: null, daysLabel: "at laundry" };
    }
    if (status === "LOCATION_UNCONFIRMED") {
      return { tone: "unconfirmed", label: "Location unconfirmed", location: "Unknown", detail: "No confirmed current custody yet", days: null, daysLabel: "unknown" };
    }
    if (status === "OUT_OF_SERVICE") {
      return { tone: "service", label: "Out of service", location: "Elis Laundry", detail: "Not available for production", days: null, daysLabel: "service hold" };
    }
    if (status === "RETIRED") {
      return { tone: "retired", label: "Retired", location: "Retired", detail: "Historical record only", days: null, daysLabel: "retired" };
    }
    return { tone: "unconfirmed", label: titleCaseCode(status), location: "—", detail: "Current location is not available", days: null, daysLabel: "—" };
  }

  function trackingEventIcon(eventType) {
    const type = String(eventType || "").toUpperCase();
    if (type.includes("ARRIVED") || type.includes("RECEIVED")) return "↩";
    if (type.includes("ASSIGNED") || type.includes("SENT")) return "→";
    if (type.includes("SERVICE")) return "⚙";
    if (type.includes("REVIEW")) return "!";
    return "•";
  }

  function trackingTimeline(events) {
    if (!events.length) return '<div class="trolleys-empty">No trolley events recorded yet.</div>';
    return `<div class="trolleys-tracking-timeline">${events.map((event) => `
      <article class="trolleys-tracking-event">
        <span class="trolleys-tracking-event-icon">${escapeHtml(trackingEventIcon(event.event_type))}</span>
        <div class="trolleys-tracking-event-copy">
          <div><strong>${escapeHtml(titleCaseCode(event.event_type))}</strong><time>${formatDateTime(event.created_at)}</time></div>
          <p>${escapeHtml(event.customer_name || "Elis Laundry / no customer")}${event.business_date ? ` · Business date ${formatDate(event.business_date)}` : ""}</p>
          <small>${escapeHtml(event.performed_by || "System")}${event.source_application ? ` · ${escapeHtml(event.source_application)}` : ""}</small>
          ${event.reason ? `<span>${escapeHtml(event.reason)}</span>` : ""}
        </div>
      </article>
    `).join("")}</div>`;
  }

  function trackingStayHistory(history) {
    if (!history.length) return '<div class="trolleys-empty">No customer stays recorded yet.</div>';
    return `<div class="trolleys-tracking-stays">${history.map((stay) => {
      const open = !stay.received_on;
      return `<article class="trolleys-tracking-stay${open ? " open" : ""}">
        <div>
          <strong>${escapeHtml(stay.outbound_customer_name || stay.received_customer_name || "Outbound record missing")}</strong>
          <span>${open ? "Current stay" : "Completed stay"}${stay.exception_type ? ` · Historical note: ${escapeHtml(titleCaseCode(stay.exception_type))}` : ""}</span>
          ${stay.route_display_name || stay.route_code ? routeBadge(stay.route_display_name, stay.route_code, stay.route_color) : ""}
        </div>
        <div><span>Production</span><strong>${formatDate(stay.production_business_date)}${stay.production_area_code ? ` · ${escapeHtml(titleCaseCode(stay.production_area_code))}` : ""}</strong></div>
        <div><span>Customer custody</span><strong>${formatDate(stay.sent_on)} → ${formatDate(stay.received_on)}</strong></div>
        <div><span>Days out</span><strong>${stay.days_out == null ? "Unknown" : `${Number(stay.days_out)} days`}</strong></div>
      </article>`;
    }).join("")}</div>`;
  }

  function trackingResultHtml(data) {
    const trolley = data?.trolley || {};
    const current = data?.current_stay || null;
    const history = Array.isArray(data?.history) ? data.history : [];
    const events = Array.isArray(data?.events) ? data.events : [];
    const meta = trackingStateMeta(trolley, current);
    const daysText = meta.days == null ? "—" : Number(meta.days);
    const routeColor = safeRouteColor(current?.route_color);
    const routeStyle = routeColor ? ` style="--customer-route-color:${routeColor}"` : "";

    return `
      <section class="trolleys-tracking-result ${escapeHtml(meta.tone)}"${routeStyle}>
        <header class="trolleys-tracking-result-head">
          <div>
            <span class="trolleys-tracking-label">TROLLEY</span>
            <h2>${escapeHtml(trolley.trolley_code || state.trackingCode || "—")}</h2>
            <p>${escapeHtml(trolley.trolley_type_name || "Unknown type")} · ${escapeHtml(trolley.trolley_type_display_code || trolley.trolley_type_code || "—")}</p>
          </div>
          <div class="trolleys-tracking-current-status">
            <span>${escapeHtml(meta.label)}</span>
            <strong>${escapeHtml(meta.location)}</strong>
            ${current?.customer_name ? routeBadge(current.route_display_name, current.route_code, current.route_color) : ""}
            <small>${escapeHtml(meta.detail)}</small>
          </div>
          <div class="trolleys-tracking-days">
            <strong>${escapeHtml(daysText)}</strong>
            <span>${escapeHtml(meta.daysLabel)}</span>
          </div>
        </header>

        <div class="trolleys-tracking-facts">
          <div><span>Master status</span>${statusBadge(trolley.status)}</div>
          <div><span>Registered</span><strong>${formatDate(trolley.registered_on)}</strong></div>
          <div><span>Current customer</span><strong>${escapeHtml(current?.customer_name || "—")}</strong>${current?.customer_name ? routeBadge(current.route_display_name, current.route_code, current.route_color) : ""}</div>
          <div><span>Production date</span><strong>${formatDate(current?.production_business_date)}</strong></div>
          <div><span>Planned delivery</span><strong>${formatDate(current?.planned_delivery_on)}</strong></div>
          <div><span>Custody source</span><strong>${escapeHtml(titleCaseCode(current?.custody_start_source || "—"))}</strong></div>
        </div>

        ${current?.notes ? `<p class="trolleys-tracking-note">${escapeHtml(current.notes)}</p>` : ""}
      </section>

      <div class="trolleys-tracking-columns">
        <section class="trolleys-card">
          <header class="trolleys-card-header"><div><p class="trolleys-section-eyebrow">Movement trace</p><h2>Event history</h2><p>Newest event first. Reception, production assignment and service changes remain visible.</p></div></header>
          <div class="trolleys-card-body">${trackingTimeline(events)}</div>
        </section>
        <section class="trolleys-card">
          <header class="trolleys-card-header"><div><p class="trolleys-section-eyebrow">Customer custody</p><h2>Stay history</h2><p>Each outbound/return cycle remains preserved. Missing outbound or customer mismatch remains visible as historical evidence only.</p></div></header>
          <div class="trolleys-card-body">${trackingStayHistory(history)}</div>
        </section>
      </div>
    `;
  }

  async function trackTrolley(code, { focusAfter = true } = {}) {
    const normalized = String(code || "").trim().toUpperCase().replace(/\s+/g, "");
    const result = document.getElementById("trolleyTrackingResult");
    const input = document.getElementById("trolleyTrackingInput");
    const message = document.getElementById("trolleyTrackingMessage");

    if (!/^T\d{1,10}T$/.test(normalized)) {
      if (message) {
        message.textContent = "Scan or enter a trolley code such as T123T.";
        message.className = "trolleys-inline-message error";
      }
      if (input) input.focus();
      return;
    }

    state.trackingCode = normalized;
    if (input) input.value = normalized;
    if (message) {
      message.textContent = `Checking ${normalized}…`;
      message.className = "trolleys-inline-message";
    }
    if (result) result.innerHTML = '<div class="trolleys-loading"><span class="trolleys-spinner" aria-hidden="true"></span><p>Loading trolley trace...</p></div>';

    try {
      const data = await rpc("get_trolley_record", { p_trolley_code: normalized });
      state.trackingRecord = data;
      state.trackingRecent = [normalized, ...state.trackingRecent.filter((item) => item !== normalized)].slice(0, 6);
      if (message) {
        message.textContent = "Trolley trace loaded from the physical lifecycle history.";
        message.className = "trolleys-inline-message success";
      }
      if (result) result.innerHTML = trackingResultHtml(data);
      const recent = document.getElementById("trolleyTrackingRecent");
      if (recent) recent.innerHTML = trackingRecentHtml();
    } catch (error) {
      console.error("Trolley tracking failed:", error);
      state.trackingRecord = null;
      if (message) {
        message.textContent = friendlyError(error);
        message.className = "trolleys-inline-message error";
      }
      if (result) result.innerHTML = `<div class="trolleys-empty">${escapeHtml(friendlyError(error))}</div>`;
    } finally {
      if (focusAfter && input) {
        input.focus();
        input.select();
      }
    }
  }

  function trackingRecentHtml() {
    if (!state.trackingRecent.length) return '<span class="trolleys-muted">No trolley scanned in this session yet.</span>';
    return state.trackingRecent.map((code) => `<button type="button" class="trolleys-tracking-recent-chip" data-track-code="${escapeHtml(code)}">${escapeHtml(code)}</button>`).join("");
  }

  async function renderTracking() {
    elements.asOfDate.textContent = formatDate(localDateValue());
    elements.main.innerHTML = `
      <section class="trolleys-tracking-workspace">
        <section class="trolleys-card trolleys-tracking-scanner-card">
          <header class="trolleys-card-header">
            <div>
              <p class="trolleys-section-eyebrow">Physical trolley tracking</p>
              <h2>Scan a trolley</h2>
              <p>Use the same trolley barcode used at Reception. This screen reads the lifecycle only; it does not receive or move the trolley.</p>
            </div>
            <span class="trolleys-tracking-listening"><i></i> Scanner listening</span>
          </header>
          <form id="trolleyTrackingForm" class="trolleys-tracking-form">
            <label for="trolleyTrackingInput">Trolley code</label>
            <div class="trolleys-tracking-input-row">
              <input id="trolleyTrackingInput" type="text" inputmode="text" autocomplete="off" maxlength="12" placeholder="T_____T" value="${escapeHtml(state.trackingCode)}">
              <button class="trolleys-primary-button" type="submit">Track trolley</button>
              <button id="trolleyTrackingClear" class="trolleys-secondary-button" type="button">Clear</button>
            </div>
            <p id="trolleyTrackingMessage" class="trolleys-inline-message" aria-live="polite"></p>
            <div class="trolleys-tracking-recent"><span>Recent:</span><div id="trolleyTrackingRecent">${trackingRecentHtml()}</div></div>
          </form>
        </section>
        <div id="trolleyTrackingResult">${state.trackingRecord ? trackingResultHtml(state.trackingRecord) : '<div class="trolleys-tracking-empty"><strong>Ready to scan</strong><span>Scan or type a trolley code to see current location, customer days and complete movement history.</span></div>'}</div>
      </section>
    `;
    setTimeout(() => document.getElementById("trolleyTrackingInput")?.focus(), 50);
  }

  function daysLabel(value, locationType) {
    if (value == null) return locationType === "LOCATION_UNCONFIRMED" ? "Unknown" : "—";
    const days = Number(value);
    return `${days} ${days === 1 ? "day" : "days"}`;
  }

  // ---- Visual helpers (sizes, day tones, fleet bar) ----

  function sizeTone(code) {
    const value = String(code || "").toUpperCase();
    if (value === "S" || value === "SMALL") return "s";
    if (value === "M" || value === "MEDIUM") return "m";
    if (value === "L" || value === "LARGE") return "l";
    return "x";
  }

  function sizeBadge(item) {
    const code = item.trolley_type_display_code || item.display_code || item.trolley_type_code || "—";
    const tone = sizeTone(item.trolley_type_display_code || item.trolley_type_code || item.display_code);
    return `<span class="tv-size tv-size-${tone}" title="${escapeHtml(item.trolley_type_name || code)}">${escapeHtml(code)}</span>`;
  }

  function dayTone(days) {
    if (days == null) return "none";
    const value = Number(days);
    if (value >= state.overdueDays) return "danger";
    if (value >= state.warningDays) return "warning";
    return "ok";
  }

  function daysPill(days, suffix = "d") {
    if (days == null) return '<span class="tv-days none">?</span>';
    const value = Number(days);
    return `<span class="tv-days ${dayTone(value)}" title="${value} ${value === 1 ? "day" : "days"} at this location">${value}${suffix}</span>`;
  }

  function sizeBreakdown(trolleys) {
    const counts = new Map();
    trolleys.forEach((item) => {
      const code = item.trolley_type_display_code || item.trolley_type_code || "?";
      const entry = counts.get(code) || { code, tone: sizeTone(code), name: item.trolley_type_name || code, count: 0 };
      entry.count += 1;
      counts.set(code, entry);
    });
    const order = { s: 1, m: 2, l: 3, x: 4 };
    return [...counts.values()]
      .sort((a, b) => order[a.tone] - order[b.tone] || a.code.localeCompare(b.code))
      .map((entry) => `<span class="tv-size-count tv-size-${entry.tone}" title="${escapeHtml(entry.name)}"><b>${escapeHtml(entry.code)}</b>${entry.count}</span>`)
      .join("");
  }

  function fleetBar(segments, total) {
    const sum = total || segments.reduce((acc, item) => acc + Number(item.value || 0), 0) || 1;
    const visible = segments.filter((item) => Number(item.value || 0) > 0);
    return `
      <div class="tv-fleet-bar" role="img" aria-label="${escapeHtml(segments.map((item) => `${item.label}: ${Number(item.value || 0)}`).join(", "))}">
        ${visible.map((item) => `<span class="tv-seg tv-st-${escapeHtml(item.tone)}" style="flex-grow:${Number(item.value)}" title="${escapeHtml(item.label)}: ${Number(item.value)}"></span>`).join("")}
      </div>
      <ul class="tv-legend">
        ${segments.map((item) => `
          <li${item.filter ? ` data-tv-filter="${escapeHtml(item.filter)}" tabindex="0" role="button"` : ""}>
            <i class="tv-dot tv-st-${escapeHtml(item.tone)}"></i>
            <span>${escapeHtml(item.label)}</span>
            <strong>${Number(item.value || 0)}</strong>
            <small>${Math.round((Number(item.value || 0) / sum) * 100)}%</small>
          </li>`).join("")}
      </ul>
    `;
  }

  function alertTile(value, label, hint, tone, attrs = "") {
    const count = Number(value || 0);
    return `
      <button type="button" class="tv-alert ${count ? escapeHtml(tone) : "quiet"}" ${attrs}>
        <strong>${count}</strong>
        <span>${escapeHtml(label)}</span>
        <small>${escapeHtml(hint)}</small>
      </button>
    `;
  }

  function sizeMixPanel(allTrolleys) {
    const map = new Map();
    allTrolleys.forEach(({ item, where }) => {
      const code = item.trolley_type_display_code || item.trolley_type_code || "?";
      const entry = map.get(code) || { code, tone: sizeTone(code), name: item.trolley_type_name || code, laundry: 0, customer: 0, unknown: 0 };
      entry[where] += 1;
      map.set(code, entry);
    });
    const order = { s: 1, m: 2, l: 3, x: 4 };
    const rows = [...map.values()].sort((a, b) => order[a.tone] - order[b.tone]);
    if (!rows.length) return "";
    const max = Math.max(...rows.map((row) => row.laundry + row.customer + row.unknown), 1);
    return `
      <section class="tv-panel tv-size-mix">
        <header><h3>Trolleys by size</h3><p>Where each size is right now</p></header>
        ${rows.map((row) => {
          const total = row.laundry + row.customer + row.unknown;
          const pct = (value) => `${(value / max) * 100}%`;
          return `
          <div class="tv-size-row">
            <span class="tv-size tv-size-${row.tone} lg" title="${escapeHtml(row.name)}">${escapeHtml(row.code)}</span>
            <div class="tv-size-row-body">
              <div class="tv-size-row-head"><strong>${escapeHtml(row.name)}</strong><span>${total}</span></div>
              <div class="tv-mini-bar">
                <span class="tv-st-laundry" style="width:${pct(row.laundry)}" title="At Elis Laundry: ${row.laundry}"></span>
                <span class="tv-st-customer" style="width:${pct(row.customer)}" title="At customers: ${row.customer}"></span>
                <span class="tv-st-unconfirmed" style="width:${pct(row.unknown)}" title="Unconfirmed: ${row.unknown}"></span>
              </div>
              <small>${row.laundry} at laundry · ${row.customer} at customers${row.unknown ? ` · ${row.unknown} unconfirmed` : ""}</small>
            </div>
          </div>`;
        }).join("")}
      </section>
    `;
  }

  function trolleyTile(item, locationType) {
    const prepared = item.location_status === "PREPARED_FOR_DELIVERY";
    const days = item.days_at_location == null ? null : Number(item.days_at_location);
    let meta = "";
    if (prepared) {
      meta = `<small class="tv-tile-meta">→ ${escapeHtml(item.customer_name || "delivery")} · ${escapeHtml(formatDate(item.planned_delivery_on))}</small>`;
    } else if (locationType === "CUSTOMER") {
      meta = `<small class="tv-tile-meta">since ${escapeHtml(formatDate(item.location_since))}</small>`;
    } else if (locationType === "ELIS_LAUNDRY") {
      meta = `<small class="tv-tile-meta">at laundry${days != null ? ` · ${days}d` : ""}</small>`;
    } else {
      meta = '<small class="tv-tile-meta">location not confirmed</small>';
    }
    const tone = locationType === "CUSTOMER" ? dayTone(days) : "none";
    return `
      <button class="tv-tile tone-${tone}" type="button" data-open-trolley="${escapeHtml(item.trolley_code)}" title="Open ${escapeHtml(item.trolley_code)}">
        ${sizeBadge(item)}
        <span class="tv-tile-copy"><strong>${escapeHtml(item.trolley_code)}</strong>${meta}</span>
        ${locationType === "CUSTOMER" ? daysPill(days) : ""}
      </button>
    `;
  }

  function routeChip(item) {
    if (!item) return "";
    const label = item.route_display_name || (item.route_code ? `Route ${item.route_code}` : "");
    if (!label) return "";
    const color = safeRouteColor(item.route_color);
    return color
      ? `<span class="tv-route" style="background:${color};color:${routeTextColor(color)}">${escapeHtml(label)}</span>`
      : `<span class="tv-route neutral">${escapeHtml(label)}</span>`;
  }

  function laundryCard(group, openAll) {
    const items = Array.isArray(group.trolleys) ? group.trolleys : [];
    const prepared = items.filter((item) => item.location_status === "PREPARED_FOR_DELIVERY");
    const available = items.filter((item) => item.location_status !== "PREPARED_FOR_DELIVERY");
    const lane = (title, tone, list, hint) => `
      <div class="tv-lane">
        <div class="tv-lane-head"><i class="tv-dot tv-st-${tone}"></i><strong>${escapeHtml(title)}</strong><span>${list.length}</span><div class="tv-size-counts">${sizeBreakdown(list)}</div></div>
        ${list.length ? `<div class="tv-tiles">${list.map((item) => trolleyTile(item, "ELIS_LAUNDRY")).join("")}</div>` : `<p class="tv-muted">${escapeHtml(hint)}</p>`}
      </div>`;
    return `
      <details class="tv-loc tv-loc-laundry"${openAll ? " open" : ""}>
        <summary>
          <span class="tv-loc-icon laundry" aria-hidden="true">E</span>
          <div class="tv-loc-title">
            <h3>${escapeHtml(group.location_name || "Elis Laundry")}</h3>
            <div class="tv-loc-sub">
              <span class="tv-pill tv-st-available-soft"><i class="tv-dot tv-st-available"></i>${available.length} available</span>
              <span class="tv-pill tv-st-prepared-soft"><i class="tv-dot tv-st-prepared"></i>${prepared.length} prepared for delivery</span>
            </div>
          </div>
          <div class="tv-size-counts">${sizeBreakdown(items)}</div>
          <div class="tv-loc-count"><strong>${Number(group.trolley_count || items.length)}</strong><span>trolleys</span></div>
          <span class="tv-chevron" aria-hidden="true"></span>
        </summary>
        <div class="tv-loc-body tv-lanes">
          ${lane("Prepared for delivery", "prepared", prepared, "Nothing prepared right now.")}
          ${lane("Available at laundry", "available", available, "No available trolleys.")}
        </div>
      </details>
    `;
  }

  function customerCard(group, openAll) {
    const items = Array.isArray(group.trolleys) ? group.trolleys : [];
    const routeItem = items.find((item) => safeRouteColor(item.route_color)) || items.find((item) => item.route_display_name || item.route_code) || null;
    const routeColor = safeRouteColor(routeItem?.route_color);
    const longest = group.longest_days == null
      ? items.reduce((max, item) => Math.max(max, Number(item.days_at_location || 0)), 0)
      : Number(group.longest_days);
    const tone = group.overdue_count ? "danger" : group.warning_count ? "warning" : "ok";
    const fill = Math.min(100, Math.round((longest / Math.max(state.overdueDays, 1)) * 100));
    const sorted = [...items].sort((a, b) => Number(b.days_at_location || 0) - Number(a.days_at_location || 0));
    const showReview = Boolean(state.capabilities.can_view_trolley_exceptions) && Number(group.review_required_count || 0) > 0;
    return `
      <details class="tv-loc tv-cust tone-${tone}"${openAll ? " open" : ""}${routeColor ? ` style="--route:${routeColor}"` : ""}>
        <summary>
          <div class="tv-cust-top">
            ${routeChip(routeItem)}
            ${group.overdue_count ? `<span class="tv-flag danger">${Number(group.overdue_count)} overdue</span>` : ""}
            ${group.warning_count ? `<span class="tv-flag warning">${Number(group.warning_count)} warning</span>` : ""}
            ${showReview ? `<span class="tv-flag review">${Number(group.review_required_count)} review</span>` : ""}
          </div>
          <div class="tv-cust-main">
            <div class="tv-cust-name">
              <h3 title="${escapeHtml(group.location_name || "")}">${escapeHtml(group.location_name || "Unknown customer")}</h3>
              <small>${escapeHtml(group.location_code || "")}</small>
            </div>
            <div class="tv-loc-count"><strong>${Number(group.trolley_count || items.length)}</strong><span>${Number(group.trolley_count || items.length) === 1 ? "trolley" : "trolleys"}</span></div>
          </div>
          <div class="tv-size-counts">${sizeBreakdown(items)}</div>
          <div class="tv-stay">
            <div class="tv-stay-label"><span>Longest stay</span><strong class="tv-text-${tone}">${escapeHtml(daysLabel(longest, "CUSTOMER"))}</strong></div>
            <div class="tv-stay-bar"><span class="tone-${tone}" style="width:${fill}%"></span><i style="left:${Math.min(100, Math.round((state.warningDays / Math.max(state.overdueDays, 1)) * 100))}%"></i></div>
          </div>
          <span class="tv-cust-open">Show trolleys</span>
        </summary>
        <div class="tv-loc-body">
          <div class="tv-tiles">${sorted.map((item) => trolleyTile(item, "CUSTOMER")).join("")}</div>
        </div>
      </details>
    `;
  }

  function unconfirmedCard(group, openAll) {
    const items = Array.isArray(group.trolleys) ? group.trolleys : [];
    return `
      <details class="tv-loc tv-loc-unconfirmed"${openAll ? " open" : ""}>
        <summary>
          <span class="tv-loc-icon unconfirmed" aria-hidden="true">?</span>
          <div class="tv-loc-title">
            <h3>Location unconfirmed</h3>
            <p>The first production assignment or Sorting confirmation will establish where these trolleys are.</p>
          </div>
          <div class="tv-size-counts">${sizeBreakdown(items)}</div>
          <div class="tv-loc-count"><strong>${Number(group.trolley_count || items.length)}</strong><span>trolleys</span></div>
          <span class="tv-chevron" aria-hidden="true"></span>
        </summary>
        <div class="tv-loc-body"><div class="tv-tiles">${items.map((item) => trolleyTile(item, "LOCATION_UNCONFIRMED")).join("")}</div></div>
      </details>
    `;
  }

  function sortCustomerGroups(groups) {
    const list = [...groups];
    const days = (group) => Number(group.longest_days || 0);
    if (state.locationSort === "COUNT") list.sort((a, b) => Number(b.trolley_count || 0) - Number(a.trolley_count || 0) || days(b) - days(a));
    else if (state.locationSort === "DAYS") list.sort((a, b) => days(b) - days(a));
    else if (state.locationSort === "NAME") list.sort((a, b) => String(a.location_name || "").localeCompare(String(b.location_name || "")));
    else list.sort((a, b) => Number(b.overdue_count || 0) - Number(a.overdue_count || 0) || Number(b.warning_count || 0) - Number(a.warning_count || 0) || days(b) - days(a));
    return list;
  }

  function paintLocations() {
    const data = state.locationData || {};
    const summary = data.summary || {};
    const groups = Array.isArray(data.groups) ? data.groups : [];
    const laundry = groups.filter((group) => group.location_type === "ELIS_LAUNDRY");
    const unconfirmed = groups.filter((group) => group.location_type === "LOCATION_UNCONFIRMED");
    let customers = groups.filter((group) => group.location_type === "CUSTOMER");
    if (state.locationAttentionOnly) customers = customers.filter((group) => Number(group.overdue_count || 0) + Number(group.warning_count || 0) > 0);
    customers = sortCustomerGroups(customers);
    const searching = Boolean(state.locationSearch);

    const allTrolleys = [];
    groups.forEach((group) => (group.trolleys || []).forEach((item) => allTrolleys.push({
      item,
      where: group.location_type === "CUSTOMER" ? "customer" : group.location_type === "ELIS_LAUNDRY" ? "laundry" : "unknown"
    })));

    const preparedCount = Number(summary.prepared_for_delivery || 0);
    const availableCount = Math.max(0, Number(summary.at_laundry || 0) - preparedCount);
    const operational = Number(summary.operational_trolleys || 0)
      || (Number(summary.at_laundry || 0) + Number(summary.at_customers || 0) + Number(summary.location_unconfirmed || 0));

    const filterChip = (value, label, count) => `
      <button type="button" class="tv-chip${state.locationFilter === value ? " active" : ""}" data-location-filter="${value}">${escapeHtml(label)}${count == null ? "" : ` <span>${Number(count)}</span>`}</button>`;

    elements.main.innerHTML = `
      <section class="tv-page">
        <div class="tv-overview">
          <section class="tv-panel tv-fleet">
            <header>
              <div><h3>Where the fleet is now</h3><p>Operational trolleys by current custody</p></div>
              <div class="tv-total"><strong>${operational}</strong><span>operational</span></div>
            </header>
            ${fleetBar([
              { label: "Available at laundry", value: availableCount, tone: "available", filter: "ELIS_LAUNDRY" },
              { label: "Prepared for delivery", value: preparedCount, tone: "prepared", filter: "ELIS_LAUNDRY" },
              { label: "At customers", value: summary.at_customers, tone: "customer", filter: "CUSTOMERS" },
              { label: "Location unconfirmed", value: summary.location_unconfirmed, tone: "unconfirmed", filter: "LOCATION_UNCONFIRMED" }
            ], operational)}
            <p class="tv-foot">${Number(summary.customer_locations || 0)} customers are holding trolleys${Number(summary.out_of_service || 0) ? ` · ${Number(summary.out_of_service)} out of service (not counted)` : ""}</p>
          </section>
          ${sizeMixPanel(allTrolleys)}
        </div>

        <div class="tv-alerts">
          ${alertTile(summary.overdue, "Overdue", `${state.overdueDays}+ days at customer`, "danger", 'data-location-attention="1"')}
          ${alertTile(summary.warning, "Warning", `${state.warningDays}+ days at customer`, "warning", 'data-location-attention="1"')}
          ${alertTile(summary.location_unconfirmed, "Unconfirmed", "location not yet known", "neutral", 'data-location-filter="LOCATION_UNCONFIRMED"')}
          ${alertTile(summary.out_of_service, "Out of service", "see Trolley Master", "service", 'data-tab="master"')}
        </div>

        <section class="tv-panel tv-locations">
          <header class="tv-toolbar">
            <div class="tv-chips" role="group" aria-label="Location filter">
              ${filterChip("ALL", "All")}
              ${filterChip("ELIS_LAUNDRY", "Elis Laundry", summary.at_laundry)}
              ${filterChip("CUSTOMERS", "Customers", summary.customer_locations)}
              ${filterChip("LOCATION_UNCONFIRMED", "Unconfirmed", summary.location_unconfirmed)}
            </div>
            <form id="trolleyLocationFilterForm" class="tv-search">
              <input id="trolleyLocationSearch" type="search" placeholder="Search trolley or customer" value="${escapeHtml(state.locationSearch)}" aria-label="Search trolley or customer">
              <button class="trolleys-primary-button" type="submit">Search</button>
              <button id="trolleyLocationsReload" class="trolleys-secondary-button" type="button" title="Reload">Reload</button>
            </form>
          </header>

          ${laundry.map((group) => laundryCard(group, searching)).join("")}

          ${state.locationFilter === "ELIS_LAUNDRY" || state.locationFilter === "LOCATION_UNCONFIRMED" ? "" : `
            <div class="tv-section-head">
              <div><h3>Customers holding trolleys</h3><p>${customers.length} ${customers.length === 1 ? "customer" : "customers"} · click a card to see its trolleys</p></div>
              <div class="tv-section-tools">
                <label class="tv-toggle"><input id="trolleyLocationAttention" type="checkbox"${state.locationAttentionOnly ? " checked" : ""}> Only overdue / warning</label>
                <select id="trolleyLocationSort" aria-label="Sort customers">
                  ${[["ATTENTION", "Needs attention first"], ["COUNT", "Most trolleys"], ["DAYS", "Longest stay"], ["NAME", "Name A–Z"]]
                    .map(([value, label]) => `<option value="${value}"${state.locationSort === value ? " selected" : ""}>${label}</option>`).join("")}
                </select>
              </div>
            </div>
            ${customers.length ? `<div class="tv-cust-grid">${customers.map((group) => customerCard(group, searching)).join("")}</div>` : '<div class="trolleys-empty">No customers match the selected filters.</div>'}
          `}

          ${unconfirmed.map((group) => unconfirmedCard(group, searching)).join("")}

          ${groups.length ? "" : '<div class="trolleys-empty">No trolley locations match the selected filters.</div>'}

          <details class="tv-help">
            <summary>How this page works</summary>
            <p>This page is a consultation view. Finish and Mop Production assign trolleys in their own applications, and Sorting confirms returned trolleys in the Sorting workflow. Delivery remains an explicit next-day inference until Distribution scanning is available. Day colours: green under ${state.warningDays} days, amber from ${state.warningDays} days, red from ${state.overdueDays} days.</p>
          </details>
        </section>
      </section>
    `;
  }

  async function renderLocations() {
    renderLoading("Loading current trolley locations...");

    try {
      const data = await rpc("get_trolley_location_overview", {
        p_search: state.locationSearch || null,
        p_location_filter: state.locationFilter
      });
      state.locationData = data || {};
      elements.asOfDate.textContent = formatDate(data?.generated_on || localDateValue());
      paintLocations();
    } catch (error) {
      console.error("Failed to load trolley locations:", error);
      elements.main.innerHTML = `<div class="trolleys-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  function typeStatusPill(type) {
    return `<span class="trolleys-type-master-status ${type.active ? "active" : "inactive"}">${type.active ? "Active" : "Inactive"}</span>`;
  }

  function typeSchedulePill(type) {
    return type.allowed_in_customer_schedule
      ? '<span class="trolleys-type-master-schedule allowed">Customer Schedule</span>'
      : '<span class="trolleys-type-master-schedule physical-only">Physical master only</span>';
  }

  function typeMasterCard(type) {
    const selected = state.typeSelectedId === type.trolley_type_id;
    const footprint = type.footprint_area_m2 == null ? null : Number(type.footprint_area_m2);
    return `
      <button class="trolleys-type-master-card${selected ? " selected" : ""}" type="button" data-select-trolley-type="${escapeHtml(type.trolley_type_id)}">
        <span class="trolleys-type-master-code">${escapeHtml(type.display_code || type.trolley_type_code)}</span>
        <span class="trolleys-type-master-card-copy">
          <strong>${escapeHtml(type.trolley_type_name)}</strong>
          <small>${escapeHtml(type.trolley_type_code)} · ${escapeHtml(titleCaseCode(type.trolley_category))}</small>
          <em>${type.footprint_length_cm && type.footprint_width_cm ? `${formatNumber(type.footprint_length_cm)} × ${formatNumber(type.footprint_width_cm)} cm · ${formatNumber(footprint, 3)} m²` : "Dimensions not set"}${type.tare_weight_kg ? ` · ${formatNumber(type.tare_weight_kg)} kg tare` : " · tare not set"}</em>
        </span>
        <span class="trolleys-type-master-card-state">${typeStatusPill(type)}</span>
      </button>
    `;
  }

  function trolleyTypeReadOnlyDetails(type) {
    if (!type) return '<div class="trolleys-empty">Select a trolley type to view its master data.</div>';
    const area = trolleyFootprintArea(type.footprint_length_cm, type.footprint_width_cm);
    return `
      <div class="trolleys-type-master-detail-head">
        <div>
          <p class="trolleys-section-eyebrow">${escapeHtml(type.trolley_type_code)}</p>
          <h2>${escapeHtml(type.trolley_type_name)}</h2>
          <div class="trolleys-badge-row">${typeStatusPill(type)}${typeSchedulePill(type)}</div>
        </div>
        <span class="trolleys-type-master-big-code">${escapeHtml(type.display_code || type.trolley_type_code)}</span>
      </div>
      <div class="trolleys-type-master-metrics">
        <div><span>Footprint</span><strong>${type.footprint_length_cm && type.footprint_width_cm ? `${formatNumber(type.footprint_length_cm)} × ${formatNumber(type.footprint_width_cm)} cm` : "Not set"}</strong><small>${area == null ? "Area unavailable" : `${formatNumber(area, 3)} m² floor area`}</small></div>
        <div><span>Tare weight</span><strong>${type.tare_weight_kg == null ? "Not set" : `${formatNumber(type.tare_weight_kg)} kg`}</strong><small>Empty trolley</small></div>
        <div><span>Physical trolleys</span><strong>${Number(type.physical_trolley_count || 0)}</strong><small>${Number(type.active_physical_trolley_count || 0)} active</small></div>
        <div><span>Schedule use</span><strong>${Number(type.active_schedule_requirement_count || 0)}</strong><small>active requirements</small></div>
      </div>
      ${type.notes ? `<div class="trolleys-type-master-notes"><strong>Notes</strong><p>${escapeHtml(type.notes)}</p></div>` : ""}
      <div class="trolleys-type-master-governance">
        <strong>Master governance</strong>
        <span>Technical code is immutable after creation. Customer Schedule eligibility is governed separately from physical type creation.</span>
      </div>
      ${state.capabilities.can_manage_trolley_types || state.capabilities.can_manage_trolley_master ? `
        <div class="trolleys-form-actions trolleys-detail-actions">
          <button id="trolleyTypeEdit" class="trolleys-primary-button" type="button">Edit this type</button>
        </div>` : ""}
    `;
  }

  function trolleyTypeEditor(type, isNew = false) {
    const canManage = Boolean(state.capabilities.can_manage_trolley_types || state.capabilities.can_manage_trolley_master);
    if (!canManage) return trolleyTypeReadOnlyDetails(type);

    const code = isNew ? "" : type?.trolley_type_code || "";
    const displayCode = isNew ? "" : type?.display_code || "";
    const name = isNew ? "" : type?.trolley_type_name || "";
    const category = isNew ? "STANDARD" : type?.trolley_category || "STANDARD";
    const length = isNew ? "" : type?.footprint_length_cm ?? "";
    const width = isNew ? "" : type?.footprint_width_cm ?? "";
    const tare = isNew ? "" : type?.tare_weight_kg ?? "";
    const sortOrder = isNew ? 100 : Number(type?.sort_order || 0);
    const notes = isNew ? "" : type?.notes || "";
    const active = isNew ? true : Boolean(type?.active);
    const area = trolleyFootprintArea(length, width);
    const activeTrolleys = Number(type?.active_physical_trolley_count || 0);
    const activeRequirements = Number(type?.active_schedule_requirement_count || 0);
    const deactivationLocked = !isNew && active && (activeTrolleys > 0 || activeRequirements > 0);

    return `
      <form id="trolleyTypeMasterForm" class="trolleys-type-master-form">
        <input id="trolleyTypeMasterId" type="hidden" value="${escapeHtml(isNew ? "" : type?.trolley_type_id || "")}">
        <div class="trolleys-type-master-detail-head">
          <div>
            <p class="trolleys-section-eyebrow">${isNew ? "New physical type" : escapeHtml(code)}</p>
            <h2>${isNew ? "Create Trolley Type" : escapeHtml(name)}</h2>
            <p>${isNew ? "New types are physical master data only until Customer Schedule use is separately approved." : "Update physical dimensions, tare weight and display details without changing the technical identity."}</p>
          </div>
          ${!isNew ? `<span class="trolleys-type-master-big-code">${escapeHtml(displayCode || code)}</span>` : ""}
        </div>

        <div class="trolleys-form-grid trolleys-form">
          <label class="trolleys-field">
            <span>Technical code *</span>
            <input id="trolleyTypeCode" type="text" maxlength="40" value="${escapeHtml(code)}" ${isNew ? "required" : "readonly"} autocomplete="off">
            <small>${isNew ? "Uppercase letters, numbers or underscores." : "Immutable after creation."}</small>
          </label>
          <label class="trolleys-field">
            <span>Display code *</span>
            <input id="trolleyTypeDisplayCode" type="text" maxlength="20" value="${escapeHtml(displayCode)}" required autocomplete="off">
            <small>Short label shown on operational screens.</small>
          </label>
          <label class="trolleys-field wide">
            <span>Type name *</span>
            <input id="trolleyTypeName" type="text" maxlength="120" value="${escapeHtml(name)}" required>
          </label>
          <label class="trolleys-field">
            <span>Category *</span>
            <select id="trolleyTypeCategory" required>
              <option value="STANDARD"${category === "STANDARD" ? " selected" : ""}>Standard</option>
              <option value="SPECIAL"${category === "SPECIAL" ? " selected" : ""}>Special</option>
            </select>
          </label>
          <label class="trolleys-field">
            <span>Sort order *</span>
            <input id="trolleyTypeSortOrder" type="number" min="0" step="1" value="${escapeHtml(sortOrder)}" required>
          </label>
          <div class="trolleys-type-dimension-group wide">
            <div class="trolleys-type-dimension-title"><strong>Physical footprint</strong><span>Enter both dimensions or leave both empty.</span></div>
            <label class="trolleys-field">
              <span>Length (cm)</span>
              <input id="trolleyTypeLength" type="number" min="0.01" step="0.01" value="${escapeHtml(length)}">
            </label>
            <label class="trolleys-field">
              <span>Width (cm)</span>
              <input id="trolleyTypeWidth" type="number" min="0.01" step="0.01" value="${escapeHtml(width)}">
            </label>
            <div id="trolleyTypeFootprintPreview" class="trolleys-type-footprint-preview">
              <span>Derived floor area</span><strong>${area == null ? "—" : `${formatNumber(area, 3)} m²`}</strong>
            </div>
          </div>
          <label class="trolleys-field wide">
            <span>Tare weight — empty trolley (kg)</span>
            <input id="trolleyTypeTare" type="number" min="0.01" step="0.01" value="${escapeHtml(tare)}">
          </label>
          <label class="trolleys-field wide">
            <span>Notes</span>
            <textarea id="trolleyTypeNotes" rows="4" maxlength="1500">${escapeHtml(notes)}</textarea>
          </label>
          <label class="trolleys-type-active-toggle wide${deactivationLocked ? " locked" : ""}">
            <input id="trolleyTypeActive" type="checkbox"${active ? " checked" : ""}${deactivationLocked ? " disabled" : ""}>
            <span><strong>Active type</strong><small>${deactivationLocked ? `Cannot deactivate: ${activeTrolleys} active physical trolley(s), ${activeRequirements} active schedule requirement(s).` : "Inactive types remain in history and cannot be used to register new physical trolleys."}</small></span>
          </label>
          <div class="trolleys-type-master-governance wide">
            <strong>Customer Schedule</strong>
            <span>${isNew ? "New type will be created as Not allowed in Customer Schedule. Schedule eligibility is a separate governed decision." : type?.allowed_in_customer_schedule ? "Allowed in Customer Schedule by the existing governed master rule." : "Not allowed in Customer Schedule. Editing this physical type does not change that rule."}</span>
          </div>
          <p id="trolleyTypeMasterMessage" class="trolleys-inline-message wide" aria-live="polite"></p>
          <div class="trolleys-form-actions wide">
            <button id="trolleyTypeCancel" class="trolleys-secondary-button" type="button">Cancel</button>
            <button class="trolleys-primary-button" type="submit">${isNew ? "Create type" : "Save changes"}</button>
          </div>
        </div>
      </form>
    `;
  }

  async function renderTrolleyTypes() {
    renderLoading("Loading Trolley Type Master...");
    try {
      const data = await rpc("get_trolley_type_master");
      state.typeMasterItems = Array.isArray(data?.items) ? data.items : [];
      const canManage = Boolean(data?.can_manage || state.capabilities.can_manage_trolley_types || state.capabilities.can_manage_trolley_master);
      if (state.typeSelectedId !== "__NEW__" && !state.typeMasterItems.some((item) => item.trolley_type_id === state.typeSelectedId)) {
        state.typeSelectedId = state.typeMasterItems[0]?.trolley_type_id || "";
      }
      if (state.typeSelectedId === "__NEW__" && !canManage) state.typeSelectedId = state.typeMasterItems[0]?.trolley_type_id || "";
      const selected = state.typeMasterItems.find((item) => item.trolley_type_id === state.typeSelectedId) || null;
      const isNew = state.typeSelectedId === "__NEW__";
      const activeCount = state.typeMasterItems.filter((item) => item.active).length;
      const measuredCount = state.typeMasterItems.filter((item) => item.footprint_length_cm && item.footprint_width_cm && item.tare_weight_kg).length;

      elements.main.innerHTML = `
        <section class="trolleys-dashboard">
          <div class="trolleys-kpi-grid trolleys-type-kpis">
            ${kpi(state.typeMasterItems.length, "Trolley types")}
            ${kpi(activeCount, "Active types")}
            ${kpi(measuredCount, "Dimensions + tare complete", measuredCount < activeCount ? "warning" : "")}
            ${kpi(state.typeMasterItems.reduce((sum,item)=>sum+Number(item.physical_trolley_count||0),0), "Physical trolleys")}
          </div>
          <section class="trolleys-type-master-layout">
            <article class="trolleys-card trolleys-type-master-catalogue">
              <header class="trolleys-card-header">
                <div>
                  <p class="trolleys-section-eyebrow">Physical master</p>
                  <h2>Trolley Types</h2>
                  <p>Dimensions and empty weight used by Tracker Route load calculations.</p>
                </div>
                <div class="trolleys-action-row">
                  <button id="trolleyTypeReload" class="trolleys-secondary-button" type="button">Reload</button>
                  ${canManage ? '<button id="trolleyTypeNew" class="trolleys-primary-button" type="button">New Type</button>' : ""}
                </div>
              </header>
              <div class="trolleys-type-master-list">
                ${state.typeMasterItems.length ? state.typeMasterItems.map(typeMasterCard).join("") : '<div class="trolleys-empty">No trolley types are registered.</div>'}
              </div>
            </article>
            <article class="trolleys-card trolleys-type-master-editor">
              <div class="trolleys-card-body">
                ${state.typeEditing || isNew ? trolleyTypeEditor(selected, isNew) : trolleyTypeReadOnlyDetails(selected)}
              </div>
            </article>
          </section>
        </section>
      `;
    } catch (error) {
      console.error("Failed to load Trolley Type Master:", error);
      elements.main.innerHTML = `<div class="trolleys-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  async function submitTrolleyTypeMaster(form) {
    if (state.busy) return;
    const message = document.getElementById("trolleyTypeMasterMessage");
    const submit = form.querySelector('button[type="submit"]');
    const id = document.getElementById("trolleyTypeMasterId")?.value || "";
    const length = optionalNumber(document.getElementById("trolleyTypeLength")?.value);
    const width = optionalNumber(document.getElementById("trolleyTypeWidth")?.value);
    const tare = optionalNumber(document.getElementById("trolleyTypeTare")?.value);
    if ((length == null) !== (width == null)) {
      setInlineMessage(message, "Enter both trolley footprint length and width, or leave both empty.", "error");
      return;
    }

    state.busy = true;
    submit.disabled = true;
    setInlineMessage(message, id ? "Saving Trolley Type..." : "Creating Trolley Type...");
    try {
      const common = {
        p_display_code: document.getElementById("trolleyTypeDisplayCode").value.trim(),
        p_trolley_type_name: document.getElementById("trolleyTypeName").value.trim(),
        p_trolley_category: document.getElementById("trolleyTypeCategory").value,
        p_footprint_length_cm: length,
        p_footprint_width_cm: width,
        p_tare_weight_kg: tare,
        p_sort_order: Number(document.getElementById("trolleyTypeSortOrder").value || 0),
        p_notes: document.getElementById("trolleyTypeNotes").value.trim() || null,
        p_active: Boolean(document.getElementById("trolleyTypeActive")?.checked)
      };
      const result = id
        ? await rpc("update_trolley_type_master", { p_trolley_type_id: id, ...common })
        : await rpc("create_trolley_type_master", {
            p_trolley_type_code: document.getElementById("trolleyTypeCode").value.trim(),
            ...common
          });
      state.typeSelectedId = result?.trolley_type_id || id;
      state.typeEditing = false;
      await refreshReferenceData();
      setPageMessage(result?.message || "Trolley Type saved.", "success");
      await renderTrolleyTypes();
    } catch (error) {
      console.error("Trolley Type save failed:", error);
      setInlineMessage(message, friendlyError(error), "error");
    } finally {
      state.busy = false;
      if (submit?.isConnected) submit.disabled = false;
    }
  }

  function masterLocation(item) {
    if (item.status === "AT_CUSTOMER" && item.current_customer_name) {
      return `<strong>${escapeHtml(item.current_customer_name)}</strong><br><span class="trolleys-muted">${escapeHtml(item.current_customer_code || "")}</span>`;
    }
    if (item.status === "AVAILABLE" || item.status === "IN_PRODUCTION") {
      return `<strong>Elis Laundry</strong>${item.status === "IN_PRODUCTION" ? `<br><span class="trolleys-muted">Prepared for ${escapeHtml(item.current_customer_name || "delivery")}</span>` : ""}`;
    }
    if (item.status === "LOCATION_UNCONFIRMED") return "Location unconfirmed";
    if (item.status === "OUT_OF_SERVICE") return "See service status";
    if (item.status === "RETIRED") return "Retired from operation";
    return "—";
  }

  const MASTER_STATUS_TONE = {
    AVAILABLE: "available",
    IN_PRODUCTION: "prepared",
    AT_CUSTOMER: "customer",
    LOCATION_UNCONFIRMED: "unconfirmed",
    OUT_OF_SERVICE: "service",
    RETIRED: "retired"
  };

  const MASTER_STATUS_LABEL = {
    AVAILABLE: "Available",
    IN_PRODUCTION: "Prepared",
    AT_CUSTOMER: "At customer",
    LOCATION_UNCONFIRMED: "Unconfirmed",
    OUT_OF_SERVICE: "Out of service",
    RETIRED: "Retired"
  };

  function masterStatusBadge(status) {
    const key = String(status || "").toUpperCase();
    const tone = MASTER_STATUS_TONE[key] || "unconfirmed";
    return `<span class="tv-status tv-st-${tone}-soft"><i class="tv-dot tv-st-${tone}"></i>${escapeHtml(MASTER_STATUS_LABEL[key] || titleCaseCode(status))}</span>`;
  }

  function masterRow(item) {
    const tone = MASTER_STATUS_TONE[String(item.status || "").toUpperCase()] || "unconfirmed";
    const attention = item.attention_status && item.attention_status !== "NORMAL"
      ? `<span class="tv-flag ${item.attention_status === "OVERDUE" ? "danger" : "warning"}">${escapeHtml(titleCaseCode(item.attention_status))}</span>`
      : "";
    return `
      <tr class="tv-row tv-row-${tone}">
        <td data-label="Trolley"><button type="button" class="tv-code" data-open-trolley="${escapeHtml(item.trolley_code)}">${sizeBadge(item)}<span>${escapeHtml(item.trolley_code)}</span></button></td>
        <td data-label="Status">${masterStatusBadge(item.status)} ${attention}</td>
        <td data-label="Location">${masterLocation(item)}</td>
        <td data-label="Days out">${item.days_out == null ? '<span class="tv-muted">—</span>' : daysPill(item.days_out, " d")}</td>
        <td data-label="Last event">${item.last_event_type ? `${escapeHtml(titleCaseCode(item.last_event_type))}<br><span class="tv-muted">${formatDate(item.last_event_business_date)}</span>` : '<span class="tv-muted">—</span>'}</td>
        <td data-label="Registered" class="tv-col-registered">${formatDate(item.registered_on)}</td>
      </tr>
    `;
  }

  function managementForms() {
    if (!state.capabilities.can_manage_trolley_master) return "";

    return `
      <section class="trolleys-card trolleys-master-command-bar">
        <div>
          <p class="trolleys-section-eyebrow">Master actions</p>
          <h2>Physical trolley administration</h2>
          <p>Open an action only when you need to change the master record.</p>
        </div>
        <div class="trolleys-action-row">
          <button id="trolleyOpenRegister" class="trolleys-primary-button" type="button">+ Register trolley</button>
          <button id="trolleyOpenService" class="trolleys-secondary-button" type="button">Service or retirement</button>
        </div>
      </section>
      <section class="trolleys-two-column trolleys-master-actions">
        <article class="trolleys-card"${state.masterAction === "register" ? "" : " hidden"}>
          <header class="trolleys-card-header">
            <div>
              <p class="trolleys-section-eyebrow">Trolley Master</p>
              <h2>Register physical trolley</h2>
              <p>Add a new physical trolley identity. This does not assign it to a customer.</p>
            </div>
          </header>
          <form id="trolleyRegisterForm" class="trolleys-form-grid trolleys-form">
            <label class="trolleys-field">
              <span>Trolley code *</span>
              <input id="registerTrolleyCode" type="text" maxlength="80" required autocomplete="off">
            </label>
            <label class="trolleys-field">
              <span>Registered on *</span>
              <input id="registerTrolleyDate" type="date" value="${escapeHtml(localDateValue())}" required>
            </label>
            <label class="trolleys-field wide">
              <span>Trolley type *</span>
              <select id="registerTrolleyType" required>
                <option value="">Select trolley type</option>
                ${trolleyTypeOptions()}
              </select>
            </label>
            <label class="trolleys-field wide">
              <span>Notes</span>
              <textarea id="registerTrolleyNotes" rows="4" maxlength="1500"></textarea>
            </label>
            <p id="registerTrolleyMessage" class="trolleys-inline-message wide" aria-live="polite"></p>
            <div class="trolleys-form-actions">
              <button class="trolleys-secondary-button" data-close-master-action type="button">Cancel</button>
              <button class="trolleys-primary-button" type="submit">Register trolley</button>
            </div>
          </form>
        </article>

        <article class="trolleys-card"${state.masterAction === "service" ? "" : " hidden"}>
          <header class="trolleys-card-header">
            <div>
              <p class="trolleys-section-eyebrow">Controlled status</p>
              <h2>Service or retirement</h2>
              <p>Retirement removes a trolley from operation but preserves its complete history.</p>
            </div>
          </header>
          <form id="trolleyServiceForm" class="trolleys-form-grid trolleys-form">
            <label class="trolleys-field wide">
              <span>Trolley code *</span>
              <input id="serviceTrolleyCode" type="text" maxlength="80" required autocomplete="off">
            </label>
            <label class="trolleys-field wide">
              <span>Action *</span>
              <select id="serviceTrolleyAction" required>
                <option value="MARK_OUT_OF_SERVICE">Mark out of service</option>
                <option value="RETURN_TO_SERVICE">Return to service</option>
                <option value="RETIRE_TROLLEY">Retire trolley</option>
              </select>
            </label>
            <label class="trolleys-field wide">
              <span>Reason *</span>
              <textarea id="serviceTrolleyReason" rows="4" maxlength="1500" required></textarea>
            </label>
            <p id="serviceTrolleyMessage" class="trolleys-inline-message wide" aria-live="polite"></p>
            <div class="trolleys-form-actions">
              <button class="trolleys-secondary-button" data-close-master-action type="button">Cancel</button>
              <button class="trolleys-primary-button" type="submit">Confirm status change</button>
            </div>
          </form>
        </article>
      </section>
    `;
  }

  function trolleySizeSummary(types) {
    const rows = types
      .filter((type) => Number(type.physical_trolley_count || 0) > 0)
      .sort((a, b) => Number(a.sort_order || 0) - Number(b.sort_order || 0));
    if (!rows.length) return '<div class="trolleys-empty">No physical trolley quantities are available by type.</div>';
    const total = rows.reduce((sum, type) => sum + Number(type.physical_trolley_count || 0), 0) || 1;
    return `<div class="tv-type-cards">${rows.map((type) => {
      const count = Number(type.physical_trolley_count || 0);
      const tone = sizeTone(type.display_code || type.trolley_type_code);
      return `
      <article class="tv-type-card tv-size-${tone}-card">
        <span class="tv-size tv-size-${tone} lg">${escapeHtml(type.display_code || type.trolley_type_code)}</span>
        <div>
          <strong>${count}</strong>
          <span>${escapeHtml(type.trolley_type_name)}</span>
          <small>${Number(type.active_physical_trolley_count || 0)} active · ${Math.round((count / total) * 100)}% of fleet</small>
        </div>
      </article>`;
    }).join("")}</div>`;
  }

  async function renderMaster() {
    renderLoading("Loading Trolley Master...");

    try {
      const [data, typeData] = await Promise.all([
        rpc("get_trolley_dashboard", {
          p_search: state.masterSearch || null,
          p_filter: state.masterFilter
        }),
        rpc("get_trolley_type_master")
      ]);
      const summary = data?.summary || {};
      const items = Array.isArray(data?.items) ? data.items : [];
      const typeItems = Array.isArray(typeData?.items) ? typeData.items : [];

      elements.main.innerHTML = `
        <section class="trolleys-dashboard">
          ${managementForms()}

          <div class="tv-overview">
            <section class="tv-panel tv-fleet">
              <header>
                <div><h3>Fleet status</h3><p>Active trolleys by master status · click to filter</p></div>
                <div class="tv-total"><strong>${Number(summary.total_active || 0)}</strong><span>active</span></div>
              </header>
              ${fleetBar([
                { label: "Available at laundry", value: summary.available, tone: "available", filter: "AVAILABLE" },
                { label: "Prepared in production", value: summary.in_production, tone: "prepared", filter: "IN_PRODUCTION" },
                { label: "At customers", value: summary.at_customer, tone: "customer", filter: "AT_CUSTOMER" },
                { label: "Location unconfirmed", value: summary.location_unconfirmed, tone: "unconfirmed", filter: "LOCATION_UNCONFIRMED" },
                { label: "Out of service", value: summary.out_of_service, tone: "service", filter: "OUT_OF_SERVICE" }
              ], Number(summary.total_active || 0))}
              ${Number(summary.review_required || 0) ? `<p class="tv-foot">${Number(summary.review_required)} trolleys carry historical review notes (kept as history only).</p>` : ""}
            </section>
            <section class="tv-panel">
              <header><div><h3>Trolleys by size</h3><p>Registered physical trolleys per type</p></div></header>
              ${trolleySizeSummary(typeItems)}
            </section>
          </div>

          <div class="tv-alerts">
            ${alertTile(summary.overdue, "Overdue", `${state.overdueDays}+ days at customer`, "danger", 'data-master-filter="ATTENTION"')}
            ${alertTile(summary.warning, "Warning", `${state.warningDays}+ days at customer`, "warning", 'data-master-filter="ATTENTION"')}
            ${alertTile(summary.location_unconfirmed, "Unconfirmed", "location not yet known", "neutral", 'data-master-filter="LOCATION_UNCONFIRMED"')}
            ${alertTile(summary.out_of_service, "Out of service", "not available for production", "service", 'data-master-filter="OUT_OF_SERVICE"')}
          </div>

          <section class="trolleys-card">
            <header class="trolleys-card-header">
              <div>
                <p class="trolleys-section-eyebrow">Registry</p>
                <h2>Physical Trolley Master</h2>
                <p>Complete physical registry. Customer assignment is recorded in Finish/Mop, not on this page.</p>
              </div>
              <form id="trolleyMasterFilterForm" class="tv-search">
                <input id="trolleyMasterSearch" type="search" placeholder="Search trolley or customer" value="${escapeHtml(state.masterSearch)}" aria-label="Search trolley or customer">
                <button class="trolleys-primary-button" type="submit">Search</button>
                <button id="trolleyMasterReload" class="trolleys-secondary-button" type="button">Reload</button>
              </form>
            </header>
            <div class="tv-chips tv-chips-bar" role="group" aria-label="Status filter">
              ${[
                ["ALL", "All"],
                ["AVAILABLE", "Available"],
                ["IN_PRODUCTION", "Prepared"],
                ["AT_CUSTOMER", "At customer"],
                ["ATTENTION", "Warning / overdue"],
                ["LOCATION_UNCONFIRMED", "Unconfirmed"],
                ["OUT_OF_SERVICE", "Out of service"],
                ["RETIRED", "Retired"]
              ].map(([value, label]) => `<button type="button" class="tv-chip${state.masterFilter === value ? " active" : ""}" data-master-filter="${value}">${label}</button>`).join("")}
              <span class="tv-chip-count">${items.length} ${items.length === 1 ? "trolley" : "trolleys"}</span>
            </div>
            <div class="trolleys-table-wrap">
              ${items.length ? `
                <table class="trolleys-table tv-table">
                  <thead><tr>
                    <th>Trolley</th><th>Status</th><th>Current location</th>
                    <th>Days out</th><th>Last event</th><th class="tv-col-registered">Registered</th>
                  </tr></thead>
                  <tbody>${items.map(masterRow).join("")}</tbody>
                </table>
              ` : '<div class="trolleys-empty">No trolleys match the selected filters.</div>'}
            </div>
          </section>
        </section>
      `;
    } catch (error) {
      console.error("Failed to load Trolley Master:", error);
      elements.main.innerHTML = `<div class="trolleys-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  function renderReviewCard(item) {
    const canAct = Boolean(state.capabilities.can_review_trolley_exceptions);
    const outbound = item.outbound_customer_name
      ? `${item.outbound_customer_name} · ${item.outbound_customer_code || ""}`
      : "No outbound customer recorded";
    const received = item.received_customer_name
      ? `${item.received_customer_name} · ${item.received_customer_code || ""}`
      : "—";

    return `
      <article class="trolleys-review-card">
        <div class="trolleys-review-card-header">
          <div>
            <h3>${escapeHtml(item.trolley_code)}</h3>
            <p>Needs review · ${escapeHtml(titleCaseCode(item.exception_type))}</p>
          </div>
          ${reviewStatusBadge(item.review_status)}
        </div>
        <div class="trolleys-review-detail-grid">
          <div class="trolleys-detail"><span>Outbound customer</span><strong>${escapeHtml(outbound)}</strong></div>
          <div class="trolleys-detail"><span>Received from</span><strong>${escapeHtml(received)}</strong></div>
          <div class="trolleys-detail"><span>Dates</span><strong>${formatDate(item.sent_on)} → ${formatDate(item.received_on)}</strong></div>
        </div>
        ${item.notes ? `<p><strong>Operator notes:</strong> ${escapeHtml(item.notes)}</p>` : ""}
        ${canAct ? `
          <div class="trolleys-action-row" style="margin-top: 14px;">
            ${item.review_status === "PENDING" ? `<button class="trolleys-small-button" type="button" data-review-action="START_REVIEW" data-stay-id="${escapeHtml(item.stay_id)}">Start review</button>` : ""}
            <button class="trolleys-small-button primary" type="button" data-review-action="RESOLVE_AS_RECORDED" data-stay-id="${escapeHtml(item.stay_id)}">Confirm recorded evidence</button>
          </div>
        ` : ""}
      </article>
    `;
  }

  async function renderExceptions() {
    renderLoading("Loading trolley data review...");
    try {
      const data = await rpc("get_trolley_reconciliation_queue");
      state.queueItems = Array.isArray(data?.items) ? data.items : [];
      elements.main.innerHTML = `
        <section class="trolleys-card">
          <header class="trolleys-card-header">
            <div>
              <p class="trolleys-section-eyebrow">Evidence reconciliation</p>
              <h2>Trolley data needing review</h2>
              <p>These are not system errors. They are cases where the physical trolley evidence is incomplete or conflicts with the recorded lifecycle.</p>
            </div>
            <button id="trolleyReviewReload" class="trolleys-secondary-button" type="button">Reload</button>
          </header>
          <div class="trolleys-card-body">
            <div class="trolleys-review-explainer"><strong>Why can a trolley appear here?</strong><span><b>Missing outbound record</b>: the trolley returned but no prior send record exists. <b>Customer mismatch</b>: the customer confirmed at return differs from the open stay. Review preserves the evidence; it does not invent dates or silently rewrite history.</span></div>
            ${state.queueItems.length ? `<div class="trolleys-review-list">${state.queueItems.map(renderReviewCard).join("")}</div>` : '<div class="trolleys-empty">There are no trolley records waiting for review.</div>'}
          </div>
        </section>
      `;
    } catch (error) {
      console.error("Failed to load trolley data review:", error);
      elements.main.innerHTML = `<div class="trolleys-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  async function renderActiveTab() {
    renderTabs();
    setPageMessage("");
    if (location.hash !== `#${state.activeTab}`) history.replaceState(null, "", `#${state.activeTab}`);
    if (state.activeTab === "locations") await renderLocations();
    else if (state.activeTab === "master") await renderMaster();
    else if (state.activeTab === "types") await renderTrolleyTypes();
  }

  async function switchTrolleyTab(tabId) {
    if (state.busy) return;
    const next = trolleyTabIds.includes(tabId) ? tabId : "locations";
    if (next === state.activeTab) return;
    state.activeTab = next;
    await renderActiveTab();
  }

  async function submitRegister(form) {
    if (state.busy) return;
    const message = document.getElementById("registerTrolleyMessage");
    const submit = form.querySelector('button[type="submit"]');
    state.busy = true;
    submit.disabled = true;
    setInlineMessage(message, "Registering trolley...");

    try {
      const result = await rpc("register_physical_trolley", {
        p_trolley_code: document.getElementById("registerTrolleyCode").value.trim(),
        p_trolley_type_id: document.getElementById("registerTrolleyType").value,
        p_registered_on: document.getElementById("registerTrolleyDate").value,
        p_notes: document.getElementById("registerTrolleyNotes").value.trim() || null,
        p_source_application: "TROLLEY_MASTER_UI"
      });
      form.reset();
      state.masterAction = "";
      setPageMessage(`Trolley ${result?.trolley_code || ""} registered.`, "success");
      await renderMaster();
    } catch (error) {
      console.error("Trolley registration failed:", error);
      setInlineMessage(message, friendlyError(error), "error");
    } finally {
      state.busy = false;
      submit.disabled = false;
    }
  }

  async function submitServiceStatus(form) {
    if (state.busy) return;
    const message = document.getElementById("serviceTrolleyMessage");
    const submit = form.querySelector('button[type="submit"]');
    const code = document.getElementById("serviceTrolleyCode").value.trim();
    const action = document.getElementById("serviceTrolleyAction").value;
    const reason = document.getElementById("serviceTrolleyReason").value.trim();

    if (action === "RETIRE_TROLLEY") {
      const confirmed = window.confirm(`Retire trolley ${code}? It will be removed from operation, but its history will be preserved.`);
      if (!confirmed) return;
    }

    state.busy = true;
    submit.disabled = true;
    setInlineMessage(message, "Saving status change...");

    try {
      const result = await rpc("set_trolley_service_status", {
        p_trolley_code: code,
        p_action: action,
        p_reason: reason,
        p_source_application: "TROLLEY_MASTER_UI"
      });
      form.reset();
      state.masterAction = "";
      setPageMessage(`Trolley ${result?.trolley_code || code} is now ${titleCaseCode(result?.status)}.`, "success");
      await renderMaster();
    } catch (error) {
      console.error("Trolley status change failed:", error);
      setInlineMessage(message, friendlyError(error), "error");
    } finally {
      state.busy = false;
      submit.disabled = false;
    }
  }

  function closeRecordModal() {
    elements.recordModal.classList.add("hidden");
    elements.recordBody.replaceChildren();
  }

  async function openTrolleyRecord(code) {
    elements.recordTitle.textContent = code;
    elements.recordSubtitle.textContent = "Loading complete trolley history...";
    elements.recordBody.innerHTML = '<div class="trolleys-loading"><span class="trolleys-spinner" aria-hidden="true"></span></div>';
    elements.recordModal.classList.remove("hidden");

    try {
      const data = await rpc("get_trolley_record", { p_trolley_code: code });
      const trolley = data?.trolley || {};
      const current = data?.current_stay;
      const history = Array.isArray(data?.history) ? data.history : [];
      const events = Array.isArray(data?.events) ? data.events : [];

      elements.recordTitle.textContent = trolley.trolley_code || code;
      elements.recordSubtitle.innerHTML = `${escapeHtml(trolley.trolley_type_name || "Unknown type")} · ${statusBadge(trolley.status)}`;
      elements.recordBody.innerHTML = `
        <section class="trolleys-record-section">
          <h3>Master record</h3>
          <div class="trolleys-detail-grid">
            <div class="trolleys-detail"><span>Type</span><strong>${escapeHtml(trolley.trolley_type_display_code || trolley.trolley_type_code || "—")}</strong></div>
            <div class="trolleys-detail"><span>Registered</span><strong>${formatDate(trolley.registered_on)}</strong></div>
            <div class="trolleys-detail"><span>Status</span><strong>${escapeHtml(titleCaseCode(trolley.status))}</strong></div>
            <div class="trolleys-detail"><span>Retired</span><strong>${formatDate(trolley.retired_on)}</strong></div>
          </div>
          ${trolley.notes ? `<p class="trolleys-record-notes">${escapeHtml(trolley.notes)}</p>` : ""}
        </section>

        <section class="trolleys-record-section">
          <h3>Current location</h3>
          ${current ? `
            <div class="trolleys-detail-grid">
              <div class="trolleys-detail"><span>Customer</span><strong>${escapeHtml(current.customer_name || "—")}</strong>${routeBadge(current.route_display_name, current.route_code, current.route_color)}</div>
              <div class="trolleys-detail"><span>Processed</span><strong>${formatDate(current.production_business_date)} · ${escapeHtml(titleCaseCode(current.production_area_code))}</strong></div>
              <div class="trolleys-detail"><span>Custody start</span><strong>${formatDate(current.sent_on)}</strong></div>
              <div class="trolleys-detail"><span>Customer days</span><strong>${current.days_out == null ? "—" : Number(current.days_out)}</strong></div>
            </div>
          ` : `<div class="trolleys-empty">No open customer stay. See Locations for the current laundry/unconfirmed state.</div>`}
        </section>

        <section class="trolleys-record-section">
          <h3>Customer stay history</h3>
          ${history.length ? `<div class="trolleys-history-list">${history.map((item) => `
            <article class="trolleys-history-item">
              <strong>${escapeHtml(item.outbound_customer_name || item.received_customer_name || "Missing outbound record")}</strong>
              <span>${item.production_business_date ? `Processed ${formatDate(item.production_business_date)} · ${escapeHtml(titleCaseCode(item.production_area_code))}` : "No production record"}</span>
              <span>Custody ${formatDate(item.sent_on)} → Sorting ${formatDate(item.received_on)} · ${item.days_out == null ? "unknown customer days" : `${Number(item.days_out)} customer days`}</span>
              ${item.exception_type ? `<span><strong>Historical custody note:</strong> ${escapeHtml(titleCaseCode(item.exception_type))}</span>` : ""}
              ${item.route_display_name || item.route_code ? routeBadge(item.route_display_name, item.route_code, item.route_color) : ""}
              ${item.notes ? `<span>${escapeHtml(item.notes)}</span>` : ""}
            </article>
          `).join("")}</div>` : '<div class="trolleys-empty">No customer stays recorded.</div>'}
        </section>

        <section class="trolleys-record-section">
          <h3>Event history</h3>
          ${events.length ? `<div class="trolleys-history-list">${events.map((event) => `
            <article class="trolleys-history-item">
              <strong>${escapeHtml(titleCaseCode(event.event_type))}</strong>
              <span>${formatDate(event.business_date)} · ${escapeHtml(event.customer_name || "No customer")} · ${escapeHtml(event.performed_by || "System")}</span>
              ${event.reason ? `<span>${escapeHtml(event.reason)}</span>` : ""}
              <span>${formatDateTime(event.created_at)}</span>
            </article>
          `).join("")}</div>` : '<div class="trolleys-empty">No events recorded.</div>'}
        </section>
      `;
    } catch (error) {
      console.error("Failed to load trolley record:", error);
      elements.recordSubtitle.textContent = "Record unavailable";
      elements.recordBody.innerHTML = `<div class="trolleys-empty">${escapeHtml(friendlyError(error))}</div>`;
    }
  }

  function closeReviewModal() {
    elements.reviewModal.classList.add("hidden");
    elements.reviewForm.reset();
    setInlineMessage(elements.reviewMessage, "");
  }

  function openReviewModal(stayId, action) {
    const item = state.queueItems.find((entry) => entry.stay_id === stayId);
    if (!item) {
      setPageMessage("The selected trolley review item is no longer available. Reload the queue.", "error");
      return;
    }

    elements.reviewStayId.value = stayId;
    elements.reviewAction.value = action;
    elements.reviewTitle.textContent = action === "START_REVIEW" ? "Start trolley data review" : "Confirm recorded evidence";
    elements.reviewSubtitle.textContent = `${item.trolley_code} · ${titleCaseCode(item.exception_type)}`;
    elements.reviewRequiredMarker.classList.toggle("hidden", action !== "RESOLVE_AS_RECORDED");
    elements.reviewNotes.required = action === "RESOLVE_AS_RECORDED";
    elements.reviewSummary.innerHTML = `
      <div class="trolleys-review-detail-grid">
        <div class="trolleys-detail"><span>Outbound</span><strong>${escapeHtml(item.outbound_customer_name || "Missing record")}</strong></div>
        <div class="trolleys-detail"><span>Received from</span><strong>${escapeHtml(item.received_customer_name || "—")}</strong></div>
        <div class="trolleys-detail"><span>Dates</span><strong>${formatDate(item.sent_on)} → ${formatDate(item.received_on)}</strong></div>
      </div>
    `;
    elements.reviewConfirm.textContent = action === "START_REVIEW" ? "Start review" : "Confirm evidence";
    elements.reviewModal.classList.remove("hidden");
    elements.reviewNotes.focus();
  }

  async function submitReview() {
    if (state.busy) return;
    const action = elements.reviewAction.value;
    const notes = elements.reviewNotes.value.trim();
    if (action === "RESOLVE_AS_RECORDED" && !notes) {
      setInlineMessage(elements.reviewMessage, "Review notes are required.", "error");
      return;
    }

    state.busy = true;
    elements.reviewConfirm.disabled = true;
    setInlineMessage(elements.reviewMessage, "Saving review...");

    try {
      await rpc("review_trolley_exception", {
        p_stay_id: elements.reviewStayId.value,
        p_action: action,
        p_notes: notes || null,
        p_source_application: "TROLLEY_CONSULTATION_UI"
      });
      closeReviewModal();
      setPageMessage(action === "START_REVIEW" ? "Trolley data review started." : "Recorded trolley evidence confirmed.", "success");
      await renderExceptions();
    } catch (error) {
      console.error("Trolley exception review failed:", error);
      setInlineMessage(elements.reviewMessage, friendlyError(error), "error");
    } finally {
      state.busy = false;
      elements.reviewConfirm.disabled = false;
    }
  }

  elements.tabs.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-tab]");
    if (!button || state.busy) return;
    await switchTrolleyTab(button.dataset.tab);
  });
  window.addEventListener("hashchange", () => switchTrolleyTab(String(location.hash || "").replace("#", "")));

  elements.main.addEventListener("click", async (event) => {
    const locationFilterButton = event.target.closest("[data-location-filter]");
    if (locationFilterButton && !state.busy) {
      state.locationFilter = locationFilterButton.dataset.locationFilter || "ALL";
      if (state.activeTab !== "locations") { state.activeTab = "locations"; renderTabs(); }
      await renderLocations();
      return;
    }

    const fleetLegend = event.target.closest("[data-tv-filter]");
    if (fleetLegend && !state.busy) {
      if (state.activeTab === "locations") {
        state.locationFilter = fleetLegend.dataset.tvFilter;
        await renderLocations();
      } else if (state.activeTab === "master") {
        state.masterFilter = fleetLegend.dataset.tvFilter;
        await renderMaster();
      }
      return;
    }

    if (event.target.closest("[data-location-attention]")) {
      state.locationAttentionOnly = true;
      if (state.locationFilter === "ELIS_LAUNDRY" || state.locationFilter === "LOCATION_UNCONFIRMED") {
        state.locationFilter = "ALL";
        await renderLocations();
      } else {
        paintLocations();
      }
      document.querySelector(".tv-section-head")?.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }

    const masterChip = event.target.closest("[data-master-filter]");
    if (masterChip && !state.busy) {
      state.masterFilter = masterChip.dataset.masterFilter || "ALL";
      await renderMaster();
      return;
    }

    const tabLink = event.target.closest("[data-tab]");
    if (tabLink) {
      await switchTrolleyTab(tabLink.dataset.tab);
      return;
    }

    const typeCard = event.target.closest("[data-select-trolley-type]");
    if (typeCard) {
      state.typeSelectedId = typeCard.dataset.selectTrolleyType;
      state.typeEditing = false;
      await renderTrolleyTypes();
      return;
    }

    if (event.target.closest("#trolleyTypeNew")) {
      state.typeSelectedId = "__NEW__";
      state.typeEditing = true;
      await renderTrolleyTypes();
      return;
    }

    if (event.target.closest("#trolleyTypeEdit")) {
      state.typeEditing = true;
      await renderTrolleyTypes();
      return;
    }

    if (event.target.closest("#trolleyTypeCancel")) {
      const currentId = document.getElementById("trolleyTypeMasterId")?.value || "";
      state.typeSelectedId = currentId || state.typeMasterItems[0]?.trolley_type_id || "";
      state.typeEditing = false;
      await renderTrolleyTypes();
      return;
    }

    if (event.target.closest("#trolleyOpenRegister")) {
      state.masterAction = "register";
      await renderMaster();
      document.getElementById("registerTrolleyCode")?.focus();
      return;
    }

    if (event.target.closest("#trolleyOpenService")) {
      state.masterAction = "service";
      await renderMaster();
      document.getElementById("serviceTrolleyCode")?.focus();
      return;
    }

    if (event.target.closest("[data-close-master-action]")) {
      state.masterAction = "";
      await renderMaster();
      return;
    }

    if (event.target.closest("#trolleyTypeReload")) {
      await refreshReferenceData();
      await renderTrolleyTypes();
      return;
    }

    const recordButton = event.target.closest("[data-open-trolley]");
    if (recordButton) {
      await openTrolleyRecord(recordButton.dataset.openTrolley);
      return;
    }

    const reviewButton = event.target.closest("[data-review-action]");
    if (reviewButton) {
      openReviewModal(reviewButton.dataset.stayId, reviewButton.dataset.reviewAction);
      return;
    }

    if (event.target.closest("#trolleyLocationsReload")) await renderLocations();
    else if (event.target.closest("#trolleyMasterReload")) await renderMaster();
    else if (event.target.closest("#trolleyReviewReload")) await renderExceptions();
  });

  elements.main.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (event.target.id === "trolleyLocationFilterForm") {
      state.locationSearch = document.getElementById("trolleyLocationSearch").value.trim();
      await renderLocations();
    } else if (event.target.id === "trolleyMasterFilterForm") {
      state.masterSearch = document.getElementById("trolleyMasterSearch").value.trim();
      await renderMaster();
    } else if (event.target.id === "trolleyRegisterForm") {
      await submitRegister(event.target);
    } else if (event.target.id === "trolleyServiceForm") {
      await submitServiceStatus(event.target);
    } else if (event.target.id === "trolleyTypeMasterForm") {
      await submitTrolleyTypeMaster(event.target);
    }
  });

  elements.main.addEventListener("change", (event) => {
    if (event.target.id === "trolleyLocationSort") {
      state.locationSort = event.target.value;
      paintLocations();
    } else if (event.target.id === "trolleyLocationAttention") {
      state.locationAttentionOnly = event.target.checked;
      paintLocations();
    }
  });

  elements.main.addEventListener("keydown", (event) => {
    if ((event.key === "Enter" || event.key === " ") && event.target.matches?.("[data-tv-filter]")) {
      event.preventDefault();
      event.target.click();
    }
  });

  elements.main.addEventListener("input", (event) => {
    if (!event.target.closest("#trolleyTypeMasterForm")) return;
    if (!["trolleyTypeLength", "trolleyTypeWidth"].includes(event.target.id)) return;
    const preview = document.getElementById("trolleyTypeFootprintPreview");
    if (!preview) return;
    const area = trolleyFootprintArea(
      document.getElementById("trolleyTypeLength")?.value,
      document.getElementById("trolleyTypeWidth")?.value
    );
    preview.innerHTML = `<span>Derived floor area</span><strong>${area == null ? "—" : `${formatNumber(area, 3)} m²`}</strong>`;
  });

  elements.signOut.addEventListener("click", async () => {
    elements.signOut.disabled = true;
    try {
      await client.auth.signOut();
      window.location.href = "../index.html";
    } catch (error) {
      console.error("Sign-out failed:", error);
      setPageMessage("The session could not be closed.", "error");
      elements.signOut.disabled = false;
    }
  });

  [elements.recordBackdrop, elements.recordClose, elements.recordCloseSecondary]
    .forEach((element) => element.addEventListener("click", closeRecordModal));

  [elements.reviewBackdrop, elements.reviewClose, elements.reviewCancel]
    .forEach((element) => element.addEventListener("click", closeReviewModal));

  elements.reviewForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    await submitReview();
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    if (!elements.reviewModal.classList.contains("hidden")) closeReviewModal();
    else if (!elements.recordModal.classList.contains("hidden")) closeRecordModal();
  });

  if (window.ELIS_SUPABASE_ERROR || !client) {
    elements.main.innerHTML = `<div class="trolleys-empty">${escapeHtml(window.ELIS_SUPABASE_ERROR || "Supabase could not be initialized.")}</div>`;
    return;
  }

  elements.asOfDate.textContent = formatDate(localDateValue());

  try {
    const { data: { session }, error: sessionError } = await client.auth.getSession();
    if (sessionError) throw sessionError;
    if (!session?.user) {
      window.location.href = "../index.html";
      return;
    }

    await refreshReferenceData();

    if (!state.capabilities.can_view_trolleys) {
      throw new Error("Your active role does not allow access to Physical Trolleys.");
    }

    await renderActiveTab();
  } catch (error) {
    console.error("Failed to initialize trolley consultation:", error);
    setPageMessage(friendlyError(error), "error");
    elements.tabs.replaceChildren();
    elements.main.innerHTML = `<div class="trolleys-empty">${escapeHtml(friendlyError(error))}</div>`;
  }
});
