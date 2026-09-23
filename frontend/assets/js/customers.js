"use strict";

document.addEventListener("DOMContentLoaded", () => {
  const client = window.elisSupabase;

  const mainTabs = document.getElementById("customersMainTabs");
  const mainPanel = document.getElementById("customersMainPanel");
  const pageMessage = document.getElementById("customersPageMessage");
  const effectiveDateInput = document.getElementById("customersEffectiveDate");
  const signOutButton = document.getElementById("customersSignOutButton");
  const toast = document.getElementById("customersToast");

  const scheduleModal = document.getElementById("scheduleDetailModal");
  const scheduleBackdrop = document.getElementById("scheduleDetailBackdrop");
  const scheduleClose = document.getElementById("scheduleDetailClose");
  const scheduleCode = document.getElementById("scheduleDetailCode");
  const scheduleTitle = document.getElementById("scheduleDetailTitle");
  const scheduleBadges = document.getElementById("scheduleDetailBadges");
  const scheduleBody = document.getElementById("scheduleDetailBody");
  const scheduleCloseSecondary = document.getElementById("scheduleDetailCloseSecondary");

  const scheduleActionModal = document.getElementById("scheduleActionModal");
  const scheduleActionBackdrop = document.getElementById("scheduleActionBackdrop");
  const scheduleActionClose = document.getElementById("scheduleActionClose");
  const scheduleActionTitle = document.getElementById("scheduleActionTitle");
  const scheduleActionDescription = document.getElementById("scheduleActionDescription");
  const scheduleActionAlert = document.getElementById("scheduleActionAlert");
  const scheduleActionEffectiveField = document.getElementById("scheduleActionEffectiveField");
  const scheduleActionEffectiveFrom = document.getElementById("scheduleActionEffectiveFrom");
  const scheduleActionReasonField = document.getElementById("scheduleActionReasonField");
  const scheduleActionReason = document.getElementById("scheduleActionReason");
  const scheduleActionReview = document.getElementById("scheduleActionReview");
  const scheduleActionCancel = document.getElementById("scheduleActionCancel");
  const scheduleActionConfirm = document.getElementById("scheduleActionConfirm");
  const scheduleActionCard = scheduleActionModal.querySelector(".customers-schedule-action-modal");

  const formModal = document.getElementById("customerFormModal");
  const formBackdrop = document.getElementById("customerFormBackdrop");
  const formClose = document.getElementById("customerFormClose");
  const formCancel = document.getElementById("customerFormCancel");
  const form = document.getElementById("customerMasterForm");
  const formTitle = document.getElementById("customerFormTitle");
  const formSubtitle = document.getElementById("customerFormSubtitle");
  const formAlert = document.getElementById("customerFormAlert");
  const formCode = document.getElementById("customerFormCode");
  const formName = document.getElementById("customerFormName");
  const formEircode = document.getElementById("customerFormEircode");
  const formServices = document.getElementById("customerFormServices");
  const formEstimatedKg = document.getElementById("customerFormEstimatedKg");
  const formStops = document.getElementById("customerFormStops");
  const formNotes = document.getElementById("customerFormNotes");
  const formOperationalAlert = document.getElementById("customerFormAlertText");
  const formReason = document.getElementById("customerFormReason");
  const formReasonLabel = document.getElementById("customerFormReasonLabel");
  const formSave = document.getElementById("customerFormSave");
  const formStatus = document.getElementById("customerFormStatus");
  const formStatusText = document.getElementById("customerFormStatusText");
  const formServiceImpact = document.getElementById("customerFormServiceImpact");
  const formNextStepSection = document.getElementById("customerFormNextStepSection");
  const formOpenSchedule = document.getElementById("customerFormOpenSchedule");
  const formOpenScheduleTitle = document.getElementById("customerFormOpenScheduleTitle");
  const formOpenScheduleHelp = document.getElementById("customerFormOpenScheduleHelp");
  const formAuditDetails = document.getElementById("customerFormAuditDetails");
  const formSaveHint = document.getElementById("customerFormSaveHint");

  const deactivateModal = document.getElementById("customerDeactivateModal");
  const deactivateBackdrop = document.getElementById("customerDeactivateBackdrop");
  const deactivateClose = document.getElementById("customerDeactivateClose");
  const deactivateCancel = document.getElementById("customerDeactivateCancel");
  const deactivateConfirm = document.getElementById("customerDeactivateConfirm");
  const deactivateName = document.getElementById("customerDeactivateName");
  const deactivateReason = document.getElementById("customerDeactivateReason");
  const deactivateAlert = document.getElementById("customerDeactivateAlert");

  const DAYS = [
    { number: 1, name: "Monday", className: "customers-day-mon" },
    { number: 2, name: "Tuesday", className: "customers-day-tue" },
    { number: 3, name: "Wednesday", className: "customers-day-wed" },
    { number: 4, name: "Thursday", className: "customers-day-thu" },
    { number: 5, name: "Friday", className: "customers-day-fri" },
    { number: 6, name: "Saturday", className: "customers-day-sat" },
    { number: 7, name: "Sunday", className: "customers-day-sun" }
  ];

  const state = {
    capabilities: null,
    referenceData: null,
    mainView: "schedule",
    requestId: 0,
    schedule: {
      service: "clothes",
      view: "planner",
      search: "",
      items: [],
      reordering: false,
      drag: null
    },
    master: {
      status: "ACTIVE",
      service: "ALL",
      search: ""
    },
    distribution: {
      search: "",
      weekday: "",
      route: "",
      items: [],
      payload: null,
      expandedGroups: new Set()
    },
    reports: {
      status: "PENDING",
      items: [],
      summary: null,
      selected: null,
      saving: false
    },
    form: {
      mode: "create",
      customerId: null,
      record: null,
      baseline: null,
      dirty: false,
      loading: false,
      saving: false
    },
    deactivate: {
      customerId: null,
      customerName: ""
    },
    studio: {
      customerId: null,
      customerCode: "",
      customerName: "",
      management: null,
      draftDocument: null,
      dirty: false,
      comparison: null,
      actionHandler: null,
      selectedVersionId: null,
      view: "schedule",
      history: null,
      readOnlyPayload: null,
      readOnlyDistributionPayload: null
    }
  };

  let searchTimer = null;
  let toastTimer = null;

  function requestedInitialView() {
    const parameters = new URLSearchParams(window.location.search);
    const view = String(parameters.get("view") || "").trim().toLowerCase();
    const service = String(parameters.get("service") || "").trim().toLowerCase();

    return {
      view: ["schedule", "master", "reports"].includes(view) ? view : "",
      service: ["clothes", "mop"].includes(service) ? service : "",
      legacyDistribution: view === "distribution"
    };
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function normalizeJson(value) {
    if (typeof value !== "string") {
      return value;
    }

    try {
      return JSON.parse(value);
    } catch {
      return value;
    }
  }

  function errorMessage(error) {
    return error?.message || error?.details || error?.hint || String(error || "Unknown error");
  }

  async function rpc(functionName, parameters = {}) {
    const { data, error } = await client.rpc(functionName, parameters);

    if (error) {
      throw error;
    }

    return normalizeJson(data);
  }

  function setPageMessage(message = "", type = "") {
    pageMessage.textContent = message;
    pageMessage.className = "customers-page-message";

    if (type) {
      pageMessage.classList.add(type);
    }
  }

  function showToast(message) {
    toast.textContent = message;
    toast.classList.add("show");

    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      toast.classList.remove("show");
    }, 2600);
  }

  function loadingHtml(message = "Loading...") {
    return `
      <div class="customers-loading">
        <span class="customers-spinner" aria-hidden="true"></span>
        <p>${escapeHtml(message)}</p>
      </div>
    `;
  }

  function emptyHtml(title, description = "") {
    return `
      <div class="customers-empty">
        <strong>${escapeHtml(title)}</strong>
        ${description ? `<p>${escapeHtml(description)}</p>` : ""}
      </div>
    `;
  }

  function formatDate(value) {
    if (!value) {
      return "—";
    }

    const parts = String(value).slice(0, 10).split("-");

    if (parts.length !== 3) {
      return String(value);
    }

    return `${parts[2]}/${parts[1]}/${parts[0]}`;
  }

  function formatDateTime(value) {
    if (!value) {
      return "—";
    }

    const parsed = new Date(value);

    if (Number.isNaN(parsed.getTime())) {
      return String(value);
    }

    return new Intl.DateTimeFormat("en-IE", {
      dateStyle: "medium",
      timeStyle: "short"
    }).format(parsed);
  }

  function formatNumber(value, fallback = "—") {
    if (value === null || value === undefined || value === "") {
      return fallback;
    }

    const number = Number(value);

    if (!Number.isFinite(number)) {
      return String(value);
    }

    return new Intl.NumberFormat("en-IE").format(number);
  }

  function dayClassByNumber(value) {
    return DAYS.find((day) => day.number === Number(value))?.className || "";
  }

  function normalizeRouteColor(value) {
    const color = String(value || "").trim();
    return /^#[0-9a-f]{6}$/i.test(color) ? color.toUpperCase() : null;
  }

  function mixRouteColorWithWhite(value, whiteRatio = 0.82) {
    const color = normalizeRouteColor(value);

    if (!color) {
      return "#F8FAFC";
    }

    const ratio = Math.min(1, Math.max(0, Number(whiteRatio)));
    const red = Number.parseInt(color.slice(1, 3), 16);
    const green = Number.parseInt(color.slice(3, 5), 16);
    const blue = Number.parseInt(color.slice(5, 7), 16);
    const mix = (channel) => Math.round(channel * (1 - ratio) + 255 * ratio);

    return `rgb(${mix(red)}, ${mix(green)}, ${mix(blue)})`;
  }

  function routeCssVariables(value) {
    const color = normalizeRouteColor(value);

    if (!color) {
      return "";
    }

    return `--customers-route-color:${color};--customers-route-tint:${mixRouteColorWithWhite(color)};`;
  }

  function routeDotHtml(value, label = "Route colour") {
    const color = normalizeRouteColor(value);

    if (!color) {
      return '<span class="customers-route-dot no-route" title="No route colour"></span>';
    }

    return `<span class="customers-route-dot" style="--customers-route-color:${color}" title="${escapeHtml(label)}: ${color}"></span>`;
  }

  function weekdayLabel(value) {
    const day = DAYS.find((item) => item.number === Number(value));
    return day?.name || "Not set";
  }

  function nextDistributionWeekday(productionWeekday) {
    const weekday = Number(productionWeekday);

    if (!Number.isInteger(weekday) || weekday < 1 || weekday > 7) {
      return "";
    }

    return weekday >= 6 ? 1 : weekday + 1;
  }

  function readonlyField(label, value, options = {}) {
    const displayValue = value === null || value === undefined || value === "" ? "Not set" : value;
    const wideClass = options.wide ? " customers-studio-field-wide" : "";
    const multiline = Boolean(options.multiline);

    return `
      <label class="customers-studio-field${wideClass}">
        <span>${escapeHtml(label)}</span>
        ${
          multiline
            ? `<textarea rows="2" readonly tabindex="-1">${escapeHtml(displayValue)}</textarea>`
            : `<input type="text" value="${escapeHtml(displayValue)}" readonly tabindex="-1">`
        }
      </label>
    `;
  }

  function serviceBadges(services) {
    const values = Array.isArray(services) ? services : [];

    if (values.length === 0) {
      return '<span class="customers-muted">No active service</span>';
    }

    return values
      .map((service) => {
        const mopClass = service === "MOP" ? " mop" : "";
        return `<span class="customers-service-badge${mopClass}">${escapeHtml(service)}</span>`;
      })
      .join("");
  }

  function statusBadge(value) {
    if (typeof value === "boolean") {
      return value
        ? '<span class="customers-status-badge active">Active</span>'
        : '<span class="customers-status-badge inactive">Inactive</span>';
    }

    const status = String(value || "UNKNOWN").toUpperCase();
    return `<span class="customers-status-badge ${escapeHtml(status.toLowerCase())}">${escapeHtml(status)}</span>`;
  }

  function openModal(element) {
    element.classList.remove("hidden");
    document.body.classList.add("customers-modal-open");
  }

  function closeModal(element) {
    element.classList.add("hidden");

    if (
      scheduleModal.classList.contains("hidden") &&
      formModal.classList.contains("hidden") &&
      deactivateModal.classList.contains("hidden") &&
      scheduleActionModal.classList.contains("hidden")
    ) {
      document.body.classList.remove("customers-modal-open");
    }
  }

  function availableMainTabs() {
    const tabs = [];

    if (
      state.capabilities?.can_view_clothes_planner ||
      state.capabilities?.can_view_mop_planner
    ) {
      tabs.push({ id: "schedule", label: "Schedule Planner" });
    }

    if (state.capabilities?.can_view_customer_directory) {
      tabs.push({ id: "master", label: "Customer Master" });
    }

    if (state.capabilities?.can_view_operational_reports) {
      const count = Number(state.capabilities?.pending_operational_report_count || 0);
      tabs.push({ id: "reports", label: count > 0 ? `Operational Reports (${count})` : "Operational Reports" });
    }

    return tabs;
  }

  function renderMainTabs() {
    mainTabs.innerHTML = availableMainTabs()
      .map(
        (tab) => `
          <button
            class="customers-tab-button${state.mainView === tab.id ? " active" : ""}"
            type="button"
            data-main-view="${escapeHtml(tab.id)}"
          >
            ${escapeHtml(tab.label)}
          </button>
        `
      )
      .join("");

    mainTabs.querySelectorAll("[data-main-view]").forEach((button) => {
      button.addEventListener("click", async () => {
        const nextView = button.dataset.mainView;

        state.mainView = nextView;
        const nextUrl = new URL(window.location.href);
        nextUrl.searchParams.set("view", nextView);
        if (nextView !== "schedule") {
          nextUrl.searchParams.delete("service");
        } else {
          nextUrl.searchParams.set("service", state.schedule.service);
        }
        window.history.replaceState(null, "", nextUrl);
        renderMainTabs();
        await loadMainView();
      });
    });
  }

  async function loadMainView() {
    const requestId = ++state.requestId;
    setPageMessage("");

    try {
      if (state.mainView === "schedule") {
        await loadSchedulePlanner(requestId);
      } else if (state.mainView === "master") {
        await loadCustomerMaster(requestId);
      } else if (state.mainView === "reports") {
        await loadOperationalReports(requestId);
      }
    } catch (error) {
      if (requestId !== state.requestId) {
        return;
      }

      console.error("Customer module load failed:", error);
      setPageMessage(errorMessage(error), "error");
      mainPanel.innerHTML = emptyHtml(
        "This view could not be loaded.",
        "Check the browser console and Supabase RPC permissions."
      );
    }
  }

  function reportRequirementText(snapshot){
    const reqs=Array.isArray(snapshot?.requirements)?snapshot.requirements:[];
    if(!reqs.length)return 'No trolley required';
    return reqs.map(r=>`${Number(r.quantity||0)}× ${escapeHtml(r.display_code||r.trolley_type_name||r.trolley_type_code||'Trolley')}`).join(' · ');
  }

  function reportObservedText(snapshot){
    const items=Array.isArray(snapshot?.trolleys)?snapshot.trolleys:[];
    if(!items.length)return 'No trolley scanned when reported';
    return items.map(t=>`${escapeHtml(t.trolley_code||'—')}${t.display_code?` (${escapeHtml(t.display_code)})`:''}`).join(' · ');
  }

  function ensureOperationalReportDialog(){
    if(document.getElementById('operationalReportReviewDialog'))return;
    document.body.insertAdjacentHTML('beforeend',`<div id="operationalReportReviewDialog" class="customers-modal hidden" role="dialog" aria-modal="true"><button id="operationalReportReviewBackdrop" class="customers-modal-backdrop" type="button" aria-label="Close report review"></button><section class="customers-modal-card customers-operational-report-modal"><header class="customers-modal-header"><div><p class="customers-modal-code">Operational Report</p><h2 id="operationalReportReviewTitle">Review trolley plan report</h2><p class="customers-modal-subtitle">The report never edits the published schedule automatically.</p></div><button id="operationalReportReviewClose" class="customers-icon-button" type="button">×</button></header><div id="operationalReportReviewBody" class="customers-modal-body"></div><label class="customers-form-field customers-form-field-wide"><span>Review notes</span><textarea id="operationalReportReviewNotes" rows="3" maxlength="1000" placeholder="Record what was checked and what action was taken."></textarea></label><p id="operationalReportReviewMessage" class="customers-form-alert hidden"></p><footer class="customers-modal-footer"><button id="operationalReportReject" class="customers-secondary-button" type="button">Reject report</button><button id="operationalReportResolved" class="customers-primary-button" type="button">Mark resolved</button></footer></section></div>`);
    const modal=document.getElementById('operationalReportReviewDialog');
    const close=()=>{if(!state.reports.saving)closeModal(modal);};
    document.getElementById('operationalReportReviewBackdrop').addEventListener('click',close);
    document.getElementById('operationalReportReviewClose').addEventListener('click',close);
    document.getElementById('operationalReportReject').addEventListener('click',()=>reviewOperationalReport('REJECTED'));
    document.getElementById('operationalReportResolved').addEventListener('click',()=>reviewOperationalReport('RESOLVED'));
  }

  function openOperationalReport(item){
    ensureOperationalReportDialog();state.reports.selected=item;
    const modal=document.getElementById('operationalReportReviewDialog');
    document.getElementById('operationalReportReviewTitle').textContent=`${item.customer_name} · ${item.product_code}`;
    document.getElementById('operationalReportReviewBody').innerHTML=`<div class="customers-operational-report-comparison"><article><span>Published plan when reported</span><strong>${reportRequirementText(item.planned_snapshot)}</strong></article><article class="reported"><span>Operator says it should be</span><strong>${reportRequirementText(item.reported_snapshot)}</strong></article></div><div class="customers-operational-report-facts"><div><span>Business date</span><strong>${formatDate(item.business_date)}</strong></div><div><span>Source</span><strong>${escapeHtml(item.source_area_code)}</strong></div><div><span>Reported by</span><strong>${escapeHtml(item.reported_by||'—')}</strong></div><div><span>Scanned evidence</span><strong>${reportObservedText(item.observed_snapshot)}</strong></div></div><div class="customers-operational-report-reason"><span>Operator reason</span><strong>${escapeHtml(item.reason)}</strong></div>`;
    document.getElementById('operationalReportReviewNotes').value='';
    const msg=document.getElementById('operationalReportReviewMessage');msg.textContent='';msg.classList.add('hidden');
    openModal(modal);
  }

  async function reviewOperationalReport(action){
    const item=state.reports.selected;if(!item||state.reports.saving)return;
    const notes=document.getElementById('operationalReportReviewNotes').value.trim(),msg=document.getElementById('operationalReportReviewMessage');
    if(!notes){msg.textContent='Review notes are required.';msg.classList.remove('hidden');return;}
    state.reports.saving=true;document.getElementById('operationalReportReject').disabled=true;document.getElementById('operationalReportResolved').disabled=true;
    try{
      const result=await rpc('review_operational_schedule_report',{p_operational_report_id:item.operational_report_id,p_action:action,p_notes:notes});
      showToast(result?.message||'Operational report updated.');closeModal(document.getElementById('operationalReportReviewDialog'));
      state.capabilities.pending_operational_report_count=Math.max(0,Number(state.capabilities.pending_operational_report_count||0)-1);renderMainTabs();await loadOperationalReports(state.requestId);
    }catch(error){msg.textContent=errorMessage(error);msg.classList.remove('hidden');}
    finally{state.reports.saving=false;document.getElementById('operationalReportReject').disabled=false;document.getElementById('operationalReportResolved').disabled=false;}
  }

  function renderOperationalReportCard(item){
    const pending=item.status==='PENDING';
    return `<article class="customers-operational-report-card ${escapeHtml(item.status.toLowerCase())}"><header><div><span class="customers-status-badge ${escapeHtml(item.status.toLowerCase())}">${escapeHtml(item.status)}</span><h3>${escapeHtml(item.customer_name)}</h3><p>${escapeHtml(item.product_code)} · ${formatDate(item.business_date)} · ${escapeHtml(item.source_area_code)}</p></div><time>${formatDateTime(item.reported_at)}</time></header><div class="customers-operational-report-comparison"><article><span>Published</span><strong>${reportRequirementText(item.planned_snapshot)}</strong></article><article class="reported"><span>Reported</span><strong>${reportRequirementText(item.reported_snapshot)}</strong></article></div><p class="customers-operational-report-note"><strong>${escapeHtml(item.reported_by||'Operator')}:</strong> ${escapeHtml(item.reason)}</p><div class="customers-operational-report-evidence"><span>Scanned: ${reportObservedText(item.observed_snapshot)}</span></div>${pending?`<footer><button type="button" class="customers-primary-button" data-review-operational-report="${escapeHtml(item.operational_report_id)}">Review report</button></footer>`:`<footer class="customers-operational-report-reviewed"><span>${escapeHtml(item.reviewed_by||'Reviewer')} · ${formatDateTime(item.reviewed_at)}</span><strong>${escapeHtml(item.review_notes||'')}</strong></footer>`}</article>`;
  }

  async function loadOperationalReports(requestId){
    mainPanel.innerHTML=loadingHtml('Loading operational reports...');
    const data=await rpc('get_operational_schedule_reports',{p_status:state.reports.status});
    if(requestId!==state.requestId)return;
    state.reports.items=Array.isArray(data?.items)?data.items:[];state.reports.summary=data?.summary||{};
    mainPanel.innerHTML=`<section class="customers-section"><header class="customers-section-header customers-operational-report-header"><div><p class="customers-section-eyebrow">Production → Customer Schedule</p><h2>Operational Reports</h2><p>Production staff can question incorrect planned trolley quantities/types. Review here, then make any official change through the versioned Customer Schedule.</p></div><div class="customers-operational-report-kpis"><span><b>${Number(state.reports.summary.pending||0)}</b> Pending</span><span><b>${Number(state.reports.summary.resolved||0)}</b> Resolved</span><span><b>${Number(state.reports.summary.rejected||0)}</b> Rejected</span></div></header><div class="customers-toolbar"><select id="operationalReportsStatus"><option value="PENDING"${state.reports.status==='PENDING'?' selected':''}>Pending</option><option value="RESOLVED"${state.reports.status==='RESOLVED'?' selected':''}>Resolved</option><option value="REJECTED"${state.reports.status==='REJECTED'?' selected':''}>Rejected</option><option value="ALL"${state.reports.status==='ALL'?' selected':''}>All reports</option></select><button id="operationalReportsReload" class="customers-secondary-button" type="button">Reload</button></div><div class="customers-operational-report-list">${state.reports.items.length?state.reports.items.map(renderOperationalReportCard).join(''):emptyHtml('No operational reports in this view.','Production reports will appear here when operators question published trolley requirements.')}</div></section>`;
    document.getElementById('operationalReportsStatus')?.addEventListener('change',async e=>{state.reports.status=e.target.value;await loadOperationalReports(state.requestId);});
    document.getElementById('operationalReportsReload')?.addEventListener('click',()=>loadOperationalReports(state.requestId));
    mainPanel.querySelectorAll('[data-review-operational-report]').forEach(b=>b.addEventListener('click',()=>{const item=state.reports.items.find(x=>x.operational_report_id===b.dataset.reviewOperationalReport);if(item)openOperationalReport(item);}));
  }

  function canUseScheduleService(service) {
    return service === "clothes"
      ? Boolean(state.capabilities?.can_view_clothes_planner)
      : Boolean(state.capabilities?.can_view_mop_planner);
  }

  function ensureScheduleService() {
    if (canUseScheduleService(state.schedule.service)) {
      return;
    }

    state.schedule.service = state.capabilities?.can_view_clothes_planner
      ? "clothes"
      : "mop";
  }

  async function loadSchedulePlanner(requestId) {
    ensureScheduleService();

    mainPanel.innerHTML = loadingHtml("Loading weekly schedule...");

    const functionName =
      state.schedule.service === "mop"
        ? "get_mop_weekly_planner"
        : "get_clothes_weekly_planner";

    const payload = await rpc(functionName, {
      p_effective_date: effectiveDateInput.value,
      p_production_weekday: null,
      p_search: state.schedule.search || null
    });

    if (requestId !== state.requestId) {
      return;
    }

    state.schedule.items = Array.isArray(payload?.items) ? payload.items : [];
    renderSchedulePlanner(payload);
  }

  function renderSchedulePlanner(payload) {
    const label = state.schedule.service === "mop" ? "MOP" : "Clothes";

    mainPanel.innerHTML = `
      <div class="customers-panel-title">
        <div>
          <h2>Customer Weekly Planner</h2>
          <p>
            ${escapeHtml(label)} schedule effective on
            ${escapeHtml(formatDate(payload?.effective_date || effectiveDateInput.value))}.
            Click a customer to view all production days.
          </p>
        </div>
        <span class="customers-count-badge">
          ${escapeHtml(formatNumber(payload?.total_count, "0"))} schedule rows
        </span>
      </div>

      <div class="customers-toolbar customers-planner-toolbar">
        <label class="customers-toolbar-group customers-schedule-date-field" for="scheduleEffectiveDate">
          <span class="customers-toolbar-label">Schedule date</span>
          <input
            id="scheduleEffectiveDate"
            class="customers-select"
            type="date"
            value="${escapeHtml(effectiveDateInput.value)}"
          >
        </label>

        ${
          state.capabilities?.can_edit_customers
            ? `
              <button id="scheduleAddCustomerButton" class="customers-primary-button" type="button">
                <span aria-hidden="true">＋</span> Add Customer
              </button>
            `
            : ""
        }

        <button id="scheduleRefreshButton" class="customers-secondary-button" type="button">
          <span aria-hidden="true">↻</span> Reload
        </button>

        <label class="customers-toolbar-group grow customers-search-group">
          <span class="customers-toolbar-label">Search</span>
          <input
            id="scheduleSearchInput"
            class="customers-search"
            type="search"
            value="${escapeHtml(state.schedule.search)}"
            placeholder="Filter by customer name or code"
            autocomplete="off"
          >
        </label>

        <div class="customers-toolbar-group customers-toolbar-inline-group">
          <span class="customers-toolbar-label">List</span>
          <div class="customers-toggle">
            ${
              state.capabilities?.can_view_clothes_planner
                ? `
                  <button
                    class="customers-toggle-button${state.schedule.service === "clothes" ? " active" : ""}"
                    type="button"
                    data-schedule-service="clothes"
                  >
                    Clothes
                  </button>
                `
                : ""
            }
            ${
              state.capabilities?.can_view_mop_planner
                ? `
                  <button
                    class="customers-toggle-button${state.schedule.service === "mop" ? " active" : ""}"
                    type="button"
                    data-schedule-service="mop"
                  >
                    MOP
                  </button>
                `
                : ""
            }
          </div>
        </div>

        <div class="customers-toolbar-group customers-toolbar-inline-group">
          <span class="customers-toolbar-label">View</span>
          <div class="customers-toggle">
            <button
              class="customers-toggle-button${state.schedule.view === "planner" ? " active" : ""}"
              type="button"
              data-schedule-view="planner"
            >
              Planner
            </button>
            <button
              class="customers-toggle-button${state.schedule.view === "list" ? " active" : ""}"
              type="button"
              data-schedule-view="list"
            >
              List
            </button>
          </div>
        </div>

        <button id="schedulePrintButton" class="customers-print-button" type="button">
          <span aria-hidden="true">▣</span> Print
        </button>
      </div>

      <div id="scheduleDisplay"></div>
    `;

    renderScheduleDisplay();
    bindScheduleToolbar();
  }

  function renderScheduleDisplay() {
    const display = document.getElementById("scheduleDisplay");

    if (!display) {
      return;
    }

    if (state.schedule.items.length === 0) {
      display.innerHTML = emptyHtml(
        "No schedule rows match this search.",
        "Try another customer name."
      );
      return;
    }

    display.innerHTML =
      state.schedule.view === "planner"
        ? renderPlannerTable()
        : renderScheduleList();

    bindScheduleCustomerButtons(display);
    bindPlannerScrollControls(display);
    bindPlannerReorderControls(display);
  }

  function groupedScheduleItems() {
    const grouped = new Map(DAYS.map((day) => [day.number, []]));

    state.schedule.items.forEach((item) => {
      const dayNumber = Number(item.production_weekday);

      if (grouped.has(dayNumber)) {
        grouped.get(dayNumber).push(item);
      }
    });

    DAYS.forEach((day) => {
      grouped.get(day.number).sort((left, right) => {
        const leftOrder = Number(left.production_order ?? Number.MAX_SAFE_INTEGER);
        const rightOrder = Number(right.production_order ?? Number.MAX_SAFE_INTEGER);

        if (leftOrder !== rightOrder) {
          return leftOrder - rightOrder;
        }

        return String(left.customer_name).localeCompare(String(right.customer_name));
      });
    });

    return grouped;
  }

  function printContrastColor(value) {
    const color = normalizeRouteColor(value);

    if (!color) {
      return "#0F172A";
    }

    const red = Number.parseInt(color.slice(1, 3), 16);
    const green = Number.parseInt(color.slice(3, 5), 16);
    const blue = Number.parseInt(color.slice(5, 7), 16);
    const luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255;

    return luminance > 0.55 ? "#0F172A" : "#FFFFFF";
  }

  function printTrolleyValue(item) {
    const summary = String(item?.trolley_summary || "").trim();

    if (summary) {
      return summary;
    }

    const total = Number(item?.planned_trolley_total);
    return Number.isFinite(total) && total > 0 ? String(total) : "";
  }

  // [EDIT 2026-08-03 — Customer Planner list version]
  // Build a deterministic identifier from the data that is actually visible in
  // the printed planner. The code stays the same for identical list content and
  // changes when a published schedule, order, customer name, route colour or
  // trolley plan changes. This makes printed copies easy to compare without
  // introducing a new database field or weakening schedule revision control.
  function customerPrintListVersion(items, service, effectiveDateValue) {
    const normalizedItems = (Array.isArray(items) ? items : [])
      .map((item) => ({
        schedule_version_id: String(item?.schedule_version_id || ""),
        version_number: Number(item?.version_number || 0),
        customer_id: String(item?.customer_id || ""),
        customer_name: String(item?.customer_name || ""),
        production_weekday: Number(item?.production_weekday || 0),
        production_order: Number(item?.production_order || 0),
        route_visual_color: normalizeRouteColor(item?.route_visual_color) || "",
        trolley_summary: String(item?.trolley_summary || ""),
        planned_trolley_total: Number(item?.planned_trolley_total || 0)
      }))
      .sort((left, right) =>
        left.production_weekday - right.production_weekday ||
        left.production_order - right.production_order ||
        left.customer_id.localeCompare(right.customer_id) ||
        left.customer_name.localeCompare(right.customer_name)
      );

    const source = JSON.stringify({
      service: service === "mop" ? "MOP" : "CLOTHES",
      effective_date: String(effectiveDateValue || ""),
      items: normalizedItems
    });
    let hash = 2166136261;

    for (let index = 0; index < source.length; index += 1) {
      hash ^= source.charCodeAt(index);
      hash = Math.imul(hash, 16777619) >>> 0;
    }

    const serviceCode = service === "mop" ? "MOP" : "CLO";
    const dateCode = String(effectiveDateValue || "")
      .replace(/[^0-9]/g, "")
      .slice(0, 8) || "NO-DATE";
    const hashCode = hash.toString(36).toUpperCase().padStart(7, "0");

    return `${serviceCode}-${dateCode}-${hashCode}`;
  }

  function customerPrintGeneratedAt() {
    try {
      return new Intl.DateTimeFormat("en-IE", {
        day: "2-digit",
        month: "short",
        year: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false
      }).format(new Date());
    } catch {
      return new Date().toISOString().slice(0, 16).replace("T", " ");
    }
  }

  function buildCustomerPrintDocument(items, service, effectiveDateValue) {
    const printDays = DAYS.filter((day) => day.number >= 1 && day.number <= 6);
    const grouped = new Map(printDays.map((day) => [day.number, []]));

    (Array.isArray(items) ? items : []).forEach((item) => {
      const dayNumber = Number(item?.production_weekday);

      if (grouped.has(dayNumber)) {
        grouped.get(dayNumber).push(item);
      }
    });

    printDays.forEach((day) => {
      grouped.get(day.number).sort((left, right) => {
        const leftOrder = Number(left?.production_order);
        const rightOrder = Number(right?.production_order);
        const safeLeftOrder = Number.isFinite(leftOrder) && leftOrder > 0
          ? leftOrder
          : Number.MAX_SAFE_INTEGER;
        const safeRightOrder = Number.isFinite(rightOrder) && rightOrder > 0
          ? rightOrder
          : Number.MAX_SAFE_INTEGER;

        if (safeLeftOrder !== safeRightOrder) {
          return safeLeftOrder - safeRightOrder;
        }

        return String(left?.customer_name || "").localeCompare(
          String(right?.customer_name || "")
        );
      });
    });

    const pagePairs = [
      [1, 2],
      [3, 4],
      [5, 6]
    ];
    const fontSizePt = 6.3;
    const headerFontSizePt = 9;
    const pagePaddingMm = 3;
    const headerHeightMm = 5.5;
    const footerHeightMm = 4;
    const globalMaxRows = Math.max(
      1,
      ...printDays.map((day) => grouped.get(day.number).length)
    );
    const rowHeightMm =
      (297 - pagePaddingMm * 2 - headerHeightMm - footerHeightMm - 6) / globalMaxRows;
    const serviceLabel = service === "mop" ? "MOP" : "Clothes";
    const effectiveDate = formatDate(effectiveDateValue);
    const listVersion = customerPrintListVersion(items, service, effectiveDateValue);
    const generatedAt = customerPrintGeneratedAt();

    function buildDay(dayNumber) {
      const day = printDays.find((item) => item.number === dayNumber);
      const rows = grouped.get(dayNumber) || [];
      const rowsHtml = rows
        .map((item) => {
          const background = normalizeRouteColor(item.route_visual_color) || "#F1F5F9";
          const foreground = printContrastColor(background);
          const orderNumber = Number(item.production_order);
          const orderText = Number.isFinite(orderNumber) && orderNumber > 0
            ? String(orderNumber)
            : "!";
          const trolleyText = printTrolleyValue(item);

          return `
            <tr>
              <td class="customer-row" style="height:${rowHeightMm}mm;background:${background};color:${foreground};font-size:${fontSizePt}pt;line-height:${rowHeightMm}mm;">
                <span class="customer-order" style="height:${rowHeightMm}mm;line-height:${rowHeightMm}mm;color:${foreground};font-size:${fontSizePt * 0.82}pt;">${escapeHtml(orderText)}</span>
                <span class="customer-name" style="height:${rowHeightMm}mm;line-height:${rowHeightMm}mm;">${escapeHtml(item.customer_name)}</span>
                <span class="customer-trolley" style="height:${rowHeightMm}mm;line-height:${rowHeightMm}mm;color:${foreground};font-size:${fontSizePt * 0.82}pt;">${escapeHtml(trolleyText)}</span>
              </td>
            </tr>
          `;
        })
        .join("");

      return `
        <td class="day-column">
          <table class="day-table">
            <thead>
              <tr>
                <th style="height:${headerHeightMm}mm;font-size:${headerFontSizePt}pt;">
                  ${escapeHtml(day?.name || "Day")}
                  <span class="day-count">(${rows.length})</span>
                </th>
              </tr>
            </thead>
            <tbody>${rowsHtml}</tbody>
          </table>
        </td>
      `;
    }

    const pagesHtml = pagePairs
      .map(
        (pair, index) => `
          <section class="print-page${index === pagePairs.length - 1 ? " last" : ""}">
            <table class="page-table">
              <tbody>
                <tr>
                  ${buildDay(pair[0])}
                  <td class="page-gap"></td>
                  ${buildDay(pair[1])}
                </tr>
              </tbody>
            </table>
            <footer class="print-version-footer">
              List version ${escapeHtml(listVersion)} · Effective ${escapeHtml(effectiveDate)} · Generated ${escapeHtml(generatedAt)}
            </footer>
          </section>
        `
      )
      .join("");

    return `<!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>${escapeHtml(serviceLabel)} Customer Planner - ${escapeHtml(effectiveDate)}</title>
          <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            html, body { min-height: 100%; }
            body {
              font-family: "Segoe UI", Arial, sans-serif;
              -webkit-print-color-adjust: exact;
              print-color-adjust: exact;
            }
            .print-toolbar {
              display: flex;
              align-items: center;
              gap: 10px;
              padding: 8px 14px;
              background: #1E293B;
              color: #FFFFFF;
              font-size: 12px;
            }
            .print-toolbar strong { font-weight: 800; }
            .print-toolbar-meta { color: #CBD5E1; }
            .print-toolbar-actions {
              display: flex;
              gap: 8px;
              margin-left: auto;
            }
            .print-toolbar button {
              height: 30px;
              padding: 0 14px;
              border: 0;
              border-radius: 6px;
              cursor: pointer;
              font: inherit;
              font-weight: 800;
            }
            .print-action { background: #0EA5A6; color: #FFFFFF; }
            .close-action { background: #475569; color: #FFFFFF; }
            .print-page {
              position: relative;
              width: 210mm;
              height: 297mm;
              padding: 4mm 4mm 8mm;
              overflow: hidden;
              background: #FFFFFF;
            }
            .page-table {
              width: 100%;
              height: 100%;
              border-collapse: collapse;
              table-layout: fixed;
            }
            .day-column { width: 48%; vertical-align: top; }
            .page-gap { width: 4%; }
            .day-table {
              width: 100%;
              border-collapse: collapse;
              table-layout: fixed;
            }
            .day-table th {
              padding: 0 1.5mm;
              background: #111827;
              color: #FFFFFF;
              text-align: left;
              text-transform: uppercase;
              font-weight: 900;
            }
            .day-count { font-size: 10px; opacity: 0.7; }
            .customer-row {
              position: relative;
              overflow: hidden;
              padding: 0 1mm;
              white-space: nowrap;
              font-weight: 800;
            }
            .customer-order {
              position: absolute;
              top: 0;
              left: 1.2mm;
              width: 8mm;
              text-align: left;
              font-weight: 800;
              opacity: 0.78;
            }
            .customer-name {
              display: block;
              width: 100%;
              overflow: hidden;
              padding: 0 18mm 0 10mm;
              text-align: center;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .customer-trolley {
              position: absolute;
              top: 0;
              right: 1.2mm;
              width: 16mm;
              overflow: hidden;
              text-align: right;
              text-overflow: ellipsis;
              white-space: nowrap;
              font-weight: 900;
            }
            .print-version-footer {
              position: absolute;
              left: 4mm;
              right: auto;
              bottom: 2.2mm;
              width: 98mm;
              max-width: 98mm;
              overflow: hidden;
              color: #64748B;
              font-size: 5.4pt;
              font-weight: 600;
              letter-spacing: 0.02em;
              text-align: left;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            @media screen {
              body { background: #E2E8F0; }
              .print-page {
                margin: 12px auto;
                box-shadow: 0 4px 20px rgba(0, 0, 0, 0.2);
              }
            }
            @media print {
              @page { size: A4 portrait; margin: 0; }
              .print-toolbar { display: none !important; }
              .print-page {
                margin: 0;
                break-after: page;
                page-break-after: always;
              }
              .print-page.last {
                break-after: auto;
                page-break-after: auto;
              }
            }
          </style>
        </head>
        <body>
          <div class="print-toolbar">
            <strong>${escapeHtml(serviceLabel)} Customer Planner</strong>
            <span class="print-toolbar-meta">Effective date ${escapeHtml(effectiveDate)} · 6 days · 3 A4 pages · production order left · trolley plan right</span>
            <div class="print-toolbar-actions">
              <button id="customerPrintAction" class="print-action" type="button">Print</button>
              <button id="customerPrintClose" class="close-action" type="button">Close</button>
            </div>
          </div>
          ${pagesHtml}
          <script>
            document.getElementById("customerPrintAction").addEventListener("click", function () { window.print(); });
            document.getElementById("customerPrintClose").addEventListener("click", function () { window.close(); });
          <\/script>
        </body>
      </html>`;
  }

  async function printSchedulePlanner() {
    const printWindow = window.open(
      "",
      "_blank",
      "width=900,height=1000,scrollbars=yes"
    );

    if (!printWindow) {
      window.alert("Please allow pop-ups for this site to print the Customer Planner.");
      return;
    }

    printWindow.document.open();
    printWindow.document.write(`<!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Preparing Customer Planner</title>
          <style>
            body { margin: 0; font-family: "Segoe UI", Arial, sans-serif; background: #F1F5F9; color: #0F172A; }
            main { min-height: 100vh; display: grid; place-items: center; padding: 24px; text-align: center; }
            strong { display: block; margin-bottom: 6px; font-size: 18px; }
            span { color: #64748B; }
          </style>
        </head>
        <body><main><div><strong>Preparing Customer Planner...</strong><span>Loading the complete weekly schedule.</span></div></main></body>
      </html>`);
    printWindow.document.close();

    const printButton = document.getElementById("schedulePrintButton");
    const originalButtonHtml = printButton?.innerHTML || "Print";

    if (printButton) {
      printButton.disabled = true;
      printButton.textContent = "Preparing...";
    }

    const printService = state.schedule.service;
    const printEffectiveDate = effectiveDateInput.value;

    try {
      const functionName =
        printService === "mop"
          ? "get_mop_weekly_planner"
          : "get_clothes_weekly_planner";
      const payload = await rpc(functionName, {
        p_effective_date: printEffectiveDate,
        p_production_weekday: null,
        p_search: null
      });
      const printItems = Array.isArray(payload?.items) ? payload.items : [];

      if (printItems.length === 0) {
        throw new Error("No schedule rows are available to print.");
      }

      printWindow.document.open();
      printWindow.document.write(
        buildCustomerPrintDocument(printItems, printService, printEffectiveDate)
      );
      printWindow.document.close();
      printWindow.focus();
    } catch (error) {
      console.error("Customer Planner print failed:", error);
      showToast(errorMessage(error));

      if (!printWindow.closed) {
        printWindow.document.open();
        printWindow.document.write(`<!doctype html>
          <html lang="en">
            <head>
              <meta charset="utf-8">
              <title>Customer Planner Print Error</title>
              <style>
                body { margin: 0; font-family: "Segoe UI", Arial, sans-serif; background: #F8FAFC; color: #0F172A; }
                main { max-width: 620px; margin: 80px auto; padding: 24px; }
                div { padding: 18px; border: 1px solid #FECACA; border-radius: 12px; background: #FEF2F2; color: #991B1B; }
                button { margin-top: 16px; height: 36px; padding: 0 16px; border: 0; border-radius: 8px; background: #475569; color: #FFFFFF; cursor: pointer; font-weight: 800; }
              </style>
            </head>
            <body>
              <main>
                <div><strong>The Customer Planner could not be prepared.</strong><p>${escapeHtml(errorMessage(error))}</p></div>
                <button id="customerPrintErrorClose" type="button">Close</button>
              </main>
              <script>document.getElementById("customerPrintErrorClose").addEventListener("click", function () { window.close(); });<\/script>
            </body>
          </html>`);
        printWindow.document.close();
      }
    } finally {
      if (printButton?.isConnected) {
        printButton.disabled = false;
        printButton.innerHTML = originalButtonHtml;
      }
    }
  }

  function plannerReorderAvailability() {
    const businessDate = String(
      state.capabilities?.business_date || new Date().toISOString().slice(0, 10)
    );
    const effectiveDate = String(effectiveDateInput.value || businessDate);

    if (!canManageCustomerSchedules()) {
      return { allowed: false, message: "Production order is permission controlled." };
    }

    if (state.schedule.search) {
      return { allowed: false, message: "Clear the search box to change production order." };
    }

    if (effectiveDate < businessDate) {
      return { allowed: false, message: "Historical production order is read only." };
    }

    if (state.schedule.reordering) {
      return { allowed: false, message: "Saving the new production order..." };
    }

    return {
      allowed: true,
      message: "Drag the handle beside a customer to change production order. The complete day saves automatically."
    };
  }

  function plannerOrderText(value) {
    const order = Number(value);
    return Number.isInteger(order) && order > 0 ? String(order) : "!";
  }

  function renderPlannerTable() {
    const grouped = groupedScheduleItems();
    const activeDays = DAYS.filter((day) => grouped.get(day.number).length > 0);
    const maxRows = Math.max(...activeDays.map((day) => grouped.get(day.number).length));
    const reorderAvailability = plannerReorderAvailability();

    let headerDays = "";
    let headerColumns = "";

    activeDays.forEach((day) => {
      headerDays += `
        <th colspan="2" class="customers-day-heading ${day.className}">
          ${escapeHtml(day.name)}
        </th>
      `;

      headerColumns += `
        <th class="customers-day-subheading ${day.className}">Customer</th>
        <th class="customers-day-subheading ${day.className}">
          ${state.schedule.service === "mop" ? "Trolley" : "Clothes"}
        </th>
      `;
    });

    let rows = "";

    for (let rowIndex = 0; rowIndex < maxRows; rowIndex += 1) {
      rows += "<tr>";

      activeDays.forEach((day) => {
        const item = grouped.get(day.number)[rowIndex];

        if (!item) {
          rows += '<td class="customers-planner-empty" colspan="2"></td>';
          return;
        }

        const titleParts = [];
        const routeColor = normalizeRouteColor(item.route_visual_color);
        const routeStyle = routeCssVariables(routeColor);

        if (state.schedule.service === "mop" && Array.isArray(item.mop_products)) {
          titleParts.push(item.mop_products.join(", "));
        }

        const instructions =
          state.schedule.service === "mop"
            ? item.mop_instructions
            : item.finish_instructions;

        if (instructions) {
          titleParts.push(instructions);
        }

        if (routeColor) {
          titleParts.push(`Route colour ${routeColor}`);
        }

        const orderText = plannerOrderText(item.production_order);
        const missingOrder = orderText === "!";

        rows += `
          <td
            class="customers-planner-name-cell customers-route-cell"
            style="${routeStyle}"
            data-planner-drop-day="${day.number}"
            data-planner-drop-customer-id="${escapeHtml(item.customer_id)}"
          >
            <div class="customers-planner-customer-shell">
              ${
                reorderAvailability.allowed
                  ? `<button
                      class="customers-planner-drag-handle"
                      type="button"
                      draggable="true"
                      data-planner-drag-handle
                      data-production-weekday="${day.number}"
                      data-customer-id="${escapeHtml(item.customer_id)}"
                      aria-label="Move ${escapeHtml(item.customer_name)} in ${escapeHtml(day.name)} production order"
                      title="Drag to change production order"
                    ><span aria-hidden="true">⋮⋮</span></button>`
                  : ""
              }
              <button
                class="customers-planner-customer"
                type="button"
                data-open-schedule
                data-customer-id="${escapeHtml(item.customer_id)}"
                data-customer-code="${escapeHtml(item.customer_code)}"
                data-customer-name="${escapeHtml(item.customer_name)}"
                title="${escapeHtml(titleParts.join(" — ") || "View customer schedule")}" 
              >
                <span class="customers-order-badge${missingOrder ? " is-missing" : ""}" title="${missingOrder ? "Production order is not assigned yet. Drag this customer to save its position." : `Production order ${orderText}`}">${escapeHtml(orderText)}</span>
                ${routeDotHtml(routeColor)}
                <span class="customers-planner-customer-name">${escapeHtml(item.customer_name)}</span>
                ${
                  item.operational_alert
                    ? `<span class="customers-planner-alert" title="${escapeHtml(item.operational_alert)}" aria-label="Operational alert">!</span>`
                    : ""
                }
              </button>
            </div>
          </td>
          <td class="customers-planner-value-cell customers-route-cell" style="${routeStyle}" title="${escapeHtml(item.trolley_summary || "No planned trolley")}">
            ${escapeHtml(item.trolley_summary || "—")}
          </td>
        `;
      });

      rows += "</tr>";
    }

    return `
      <div class="customers-route-legend${reorderAvailability.allowed ? " can-reorder" : ""}">
        <span>${routeDotHtml("#0EA5A6", "Example")}</span>
        <span>Customer shading follows the default route colour. ${escapeHtml(reorderAvailability.message)}</span>
      </div>
      <div class="customers-planner-outer">
        <button
          class="customers-scroll-arrow customers-scroll-arrow-left"
          type="button"
          data-planner-scroll="left"
          aria-label="Scroll planner left"
        >‹</button>
        <div class="customers-planner-wrap">
          <table class="customers-planner-table">
            <thead>
              <tr>${headerDays}</tr>
              <tr>${headerColumns}</tr>
            </thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
        <button
          class="customers-scroll-arrow customers-scroll-arrow-right"
          type="button"
          data-planner-scroll="right"
          aria-label="Scroll planner right"
        >›</button>
      </div>
    `;
  }

  function renderScheduleList() {
    return `
      <div class="customers-planner-list-scroll">
        <table class="customers-list-table">
          <thead>
            <tr>
              <th>Day</th>
              <th>Order</th>
              <th>Customer</th>
              ${state.schedule.service === "mop" ? "<th>MOP products</th>" : ""}
              <th>Trolleys</th>
              <th>Instructions</th>
              <th>Alert</th>
            </tr>
          </thead>
          <tbody>
            ${state.schedule.items
              .map((item) => {
                const instructions =
                  state.schedule.service === "mop"
                    ? item.mop_instructions
                    : item.finish_instructions;
                const routeColor = normalizeRouteColor(item.route_visual_color);

                return `
                  <tr class="customers-list-row customers-route-list-row" style="${routeCssVariables(routeColor)}">
                    <td>${escapeHtml(item.production_day)}</td>
                    <td>${escapeHtml(plannerOrderText(item.production_order))}</td>
                    <td>
                      <button
                        class="customers-planner-customer"
                        type="button"
                        data-open-schedule
                        data-customer-id="${escapeHtml(item.customer_id)}"
                        data-customer-code="${escapeHtml(item.customer_code)}"
                        data-customer-name="${escapeHtml(item.customer_name)}"
                      >
                        ${routeDotHtml(routeColor)}
                        <span class="customers-planner-customer-name">${escapeHtml(item.customer_name)}</span>
                      </button>
                    </td>
                    ${
                      state.schedule.service === "mop"
                        ? `<td>${escapeHtml((item.mop_products || []).join(", ") || "—")}</td>`
                        : ""
                    }
                    <td>${escapeHtml(item.trolley_summary || "—")}</td>
                    <td>${escapeHtml(instructions || "—")}</td>
                    <td>
                      ${
                        item.operational_alert
                          ? `<span class="customers-alert-text">${escapeHtml(item.operational_alert)}</span>`
                          : "—"
                      }
                    </td>
                  </tr>
                `;
              })
              .join("")}
          </tbody>
        </table>
      </div>
    `;
  }

  function bindScheduleToolbar() {
    document.querySelectorAll("[data-schedule-service]").forEach((button) => {
      button.addEventListener("click", () => {
        state.schedule.service = button.dataset.scheduleService;
        loadMainView();
      });
    });

    document.querySelectorAll("[data-schedule-view]").forEach((button) => {
      button.addEventListener("click", () => {
        state.schedule.view = button.dataset.scheduleView;
        renderSchedulePlanner({
          effective_date: effectiveDateInput.value,
          total_count: state.schedule.items.length
        });
      });
    });

    const searchInput = document.getElementById("scheduleSearchInput");
    const scheduleEffectiveDate = document.getElementById("scheduleEffectiveDate");
    const refreshButton = document.getElementById("scheduleRefreshButton");
    const addButton = document.getElementById("scheduleAddCustomerButton");
    const printButton = document.getElementById("schedulePrintButton");

    searchInput?.addEventListener("input", () => {
      state.schedule.search = searchInput.value.trim();

      clearTimeout(searchTimer);
      searchTimer = setTimeout(loadMainView, 320);
    });

    scheduleEffectiveDate?.addEventListener("change", async () => {
      effectiveDateInput.value = scheduleEffectiveDate.value ||
        state.capabilities?.business_date ||
        new Date().toISOString().slice(0, 10);
      await loadMainView();
    });

    refreshButton?.addEventListener("click", loadMainView);
    addButton?.addEventListener("click", () => openCustomerForm("create"));
    printButton?.addEventListener("click", printSchedulePlanner);
  }

  function bindScheduleCustomerButtons(container) {
    container.querySelectorAll("[data-open-schedule]").forEach((button) => {
      button.addEventListener("click", () => {
        openScheduleDetails(
          button.dataset.customerId,
          button.dataset.customerCode,
          button.dataset.customerName
        );
      });
    });
  }

  function plannerItemsForDay(weekday) {
    return state.schedule.items
      .filter((item) => Number(item.production_weekday) === Number(weekday))
      .slice()
      .sort((left, right) => {
        const leftOrder = Number(left.production_order);
        const rightOrder = Number(right.production_order);
        const safeLeft = Number.isInteger(leftOrder) && leftOrder > 0
          ? leftOrder
          : Number.MAX_SAFE_INTEGER;
        const safeRight = Number.isInteger(rightOrder) && rightOrder > 0
          ? rightOrder
          : Number.MAX_SAFE_INTEGER;

        if (safeLeft !== safeRight) {
          return safeLeft - safeRight;
        }

        return String(left.customer_name || "").localeCompare(
          String(right.customer_name || "")
        );
      });
  }

  function clearPlannerDropMarkers(container) {
    container.querySelectorAll(".is-drop-before, .is-drop-after").forEach((cell) => {
      cell.classList.remove("is-drop-before", "is-drop-after");
    });
  }

  function bindPlannerReorderControls(container) {
    if (!plannerReorderAvailability().allowed) {
      return;
    }

    const handles = container.querySelectorAll("[data-planner-drag-handle]");
    const targets = container.querySelectorAll("[data-planner-drop-day]");

    handles.forEach((handle) => {
      handle.addEventListener("dragstart", (event) => {
        if (state.schedule.reordering) {
          event.preventDefault();
          return;
        }

        state.schedule.drag = {
          customerId: handle.dataset.customerId,
          weekday: Number(handle.dataset.productionWeekday)
        };
        handle.closest(".customers-planner-name-cell")?.classList.add("is-dragging");
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", handle.dataset.customerId || "");
      });

      handle.addEventListener("dragend", () => {
        container.querySelectorAll(".is-dragging").forEach((cell) => {
          cell.classList.remove("is-dragging");
        });
        clearPlannerDropMarkers(container);
        state.schedule.drag = null;
      });
    });

    targets.forEach((target) => {
      target.addEventListener("dragover", (event) => {
        const drag = state.schedule.drag;
        const targetWeekday = Number(target.dataset.plannerDropDay);

        if (!drag || drag.weekday !== targetWeekday) {
          return;
        }

        event.preventDefault();
        event.dataTransfer.dropEffect = "move";
        clearPlannerDropMarkers(container);
        const rect = target.getBoundingClientRect();
        const after = event.clientY > rect.top + rect.height / 2;
        target.classList.add(after ? "is-drop-after" : "is-drop-before");
      });

      target.addEventListener("dragleave", (event) => {
        if (!target.contains(event.relatedTarget)) {
          target.classList.remove("is-drop-before", "is-drop-after");
        }
      });

      target.addEventListener("drop", (event) => {
        const drag = state.schedule.drag;
        const targetWeekday = Number(target.dataset.plannerDropDay);

        if (!drag || drag.weekday !== targetWeekday) {
          return;
        }

        event.preventDefault();
        const rect = target.getBoundingClientRect();
        const insertAfter = event.clientY > rect.top + rect.height / 2;
        const targetCustomerId = target.dataset.plannerDropCustomerId;
        clearPlannerDropMarkers(container);
        applyPlannerDrop(drag.weekday, drag.customerId, targetCustomerId, insertAfter);
      });
    });
  }

  async function applyPlannerDrop(weekday, sourceCustomerId, targetCustomerId, insertAfter) {
    const dayItems = plannerItemsForDay(weekday);
    const sourceIndex = dayItems.findIndex(
      (item) => String(item.customer_id) === String(sourceCustomerId)
    );

    if (sourceIndex < 0) {
      return;
    }

    const [movedItem] = dayItems.splice(sourceIndex, 1);
    let targetIndex;

    if (String(targetCustomerId) === String(sourceCustomerId)) {
      targetIndex = sourceIndex;
    } else {
      targetIndex = dayItems.findIndex(
        (item) => String(item.customer_id) === String(targetCustomerId)
      );

      if (targetIndex < 0) {
        targetIndex = dayItems.length;
      } else if (insertAfter) {
        targetIndex += 1;
      }
    }

    targetIndex = Math.max(0, Math.min(targetIndex, dayItems.length));
    dayItems.splice(targetIndex, 0, movedItem);

    const needsSave = dayItems.some(
      (item, index) => Number(item.production_order) !== index + 1
    );

    if (!needsSave) {
      return;
    }

    const previousItems = state.schedule.items.map((item) => ({ ...item }));
    const reorderedByCustomer = new Map(
      dayItems.map((item, index) => [
        String(item.customer_id),
        { ...item, production_order: index + 1 }
      ])
    );

    state.schedule.items = state.schedule.items.map((item) => {
      if (Number(item.production_weekday) !== Number(weekday)) {
        return item;
      }

      return reorderedByCustomer.get(String(item.customer_id)) || item;
    });
    state.schedule.reordering = true;
    renderScheduleDisplay();
    showToast(`Saving ${weekdayLabel(weekday)} production order...`);

    try {
      const payload = await rpc("reorder_customer_planner_day", {
        p_product_code: state.schedule.service === "mop" ? "MOP" : "CLOTHES",
        p_production_weekday: Number(weekday),
        p_effective_date: effectiveDateInput.value,
        p_items: dayItems.map((item) => ({
          customer_id: item.customer_id,
          schedule_version_id: item.schedule_version_id
        })),
        p_change_reason: `Customer Planner drag-and-drop reorder for ${weekdayLabel(weekday)} ${state.schedule.service === "mop" ? "MOP" : "Clothes"}.`,
        p_source_application: "CUSTOMER_PLANNER_UI"
      });

      state.schedule.items = Array.isArray(payload?.items) ? payload.items : state.schedule.items;
      showToast(`${weekdayLabel(weekday)} production order saved.`);
    } catch (error) {
      console.error("Customer Planner reorder failed:", error);
      state.schedule.items = previousItems;
      showToast(errorMessage(error));
      await loadMainView();
      return;
    } finally {
      state.schedule.reordering = false;
      renderScheduleDisplay();
    }
  }

  function bindPlannerScrollControls(container) {
    const outer = container.querySelector(".customers-planner-outer");
    const scroller = container.querySelector(".customers-planner-wrap");

    if (!outer || !scroller) {
      return;
    }

    const update = () => {
      const maxScroll = Math.max(0, scroller.scrollWidth - scroller.clientWidth);
      const canScrollLeft = scroller.scrollLeft > 4;
      const canScrollRight = scroller.scrollLeft < maxScroll - 4;

      outer.classList.toggle("can-scroll-left", canScrollLeft);
      outer.classList.toggle("can-scroll-right", canScrollRight);
    };

    outer.querySelectorAll("[data-planner-scroll]").forEach((button) => {
      button.addEventListener("click", () => {
        const direction = button.dataset.plannerScroll === "left" ? -1 : 1;
        scroller.scrollBy({ left: direction * Math.max(260, scroller.clientWidth * 0.72), behavior: "smooth" });
      });
    });

    scroller.addEventListener("scroll", update, { passive: true });

    if (typeof ResizeObserver === "function") {
      const observer = new ResizeObserver(update);
      observer.observe(scroller);
      scroller._customersResizeObserver = observer;
    }

    requestAnimationFrame(update);
  }

  async function openScheduleDetails(customerId, customerCode, customerName) {
    state.studio.customerId = customerId;
    state.studio.customerCode = customerCode || "";
    state.studio.customerName = customerName || "";
    state.studio.management = null;
    state.studio.draftDocument = null;
    state.studio.dirty = false;
    state.studio.comparison = null;
    state.studio.selectedVersionId = null;
    state.studio.view = "schedule";
    state.studio.history = null;
    state.studio.readOnlyPayload = null;
    state.studio.readOnlyDistributionPayload = null;

    scheduleCode.textContent = customerCode || "";
    scheduleTitle.textContent = customerName || "Customer Studio";
    scheduleBadges.replaceChildren();
    scheduleBody.innerHTML = loadingHtml("Loading all production days...");
    openModal(scheduleModal);

    try {
      if (canManageCustomerSchedules()) {
        const management = await loadScheduleManagementState(customerId);
        renderScheduleManagementState(management);
        return;
      }

      const schedulePromise = rpc("get_customer_weekly_schedule", {
        p_customer_id: customerId,
        p_effective_date: effectiveDateInput.value
      });

      const distributionPromise = state.capabilities?.can_view_distribution
        ? rpc("get_customer_distribution_overview", {
            p_customer_id: customerId,
            p_effective_date: effectiveDateInput.value
          }).catch((error) => {
            console.warn("Distribution detail was not loaded:", error);
            return null;
          })
        : Promise.resolve(null);

      const [payload, distributionPayload] = await Promise.all([
        schedulePromise,
        distributionPromise
      ]);

      renderScheduleDetails(payload, distributionPayload);
    } catch (error) {
      console.error("Schedule detail load failed:", error);
      scheduleBody.innerHTML = emptyHtml(
        "The customer schedule could not be loaded.",
        errorMessage(error)
      );
    }
  }

  function renderScheduleDetails(payload, distributionPayload = null) {
    state.studio.view = "schedule";
    state.studio.readOnlyPayload = payload || null;
    state.studio.readOnlyDistributionPayload = distributionPayload || null;
    scheduleCode.textContent = payload?.customer_code || "";
    scheduleTitle.textContent = payload?.customer_name || "Customer Studio";
    scheduleBadges.innerHTML = serviceBadges(payload?.visible_product_codes);

    const version = payload?.schedule_version;
    const activeDays = Array.isArray(payload?.days) ? payload.days : [];

    if (!version) {
      scheduleBody.innerHTML = `${renderStudioViewTabs("schedule")}${emptyHtml(
        "No published production schedule is effective on this date.",
        `Effective date: ${formatDate(payload?.effective_date || effectiveDateInput.value)}`
      )}`;
      bindScheduleManagementEditor();
      return;
    }

    const activeDayMap = new Map(
      activeDays.map((day) => [Number(day.production_weekday), day])
    );
    const distributionDayMap = new Map(
      (Array.isArray(distributionPayload?.days) ? distributionPayload.days : [])
        .map((day) => [Number(day.production_weekday), day])
    );
    const weekDays = DAYS.filter(
      (day) => day.number <= 6 || activeDayMap.has(day.number)
    );
    const productRowCount = activeDays.reduce(
      (total, day) => total + (Array.isArray(day.products) ? day.products.length : 0),
      0
    );
    const trolleyTotal = activeDays.reduce(
      (total, day) => total + Number(day.visible_trolley_total || 0),
      0
    );

    scheduleBody.innerHTML = `
      ${renderStudioViewTabs("schedule")}
      <section class="customers-studio-hero">
        <div class="customers-studio-identity">
          <div class="customers-studio-name-line">
            <span class="customers-studio-customer-dot" aria-hidden="true"></span>
            <strong>${escapeHtml(payload?.customer_name || "Customer")}</strong>
          </div>
          <p>
            Production days: ${escapeHtml(activeDays.map((day) => day.production_day.slice(0, 3)).join(" · ") || "None")}.
            The weekly controls are read-only for your role. Published schedule history remains protected.
          </p>
        </div>

        <div class="customers-studio-kpis">
          ${studioKpi(activeDays.length, "Days")}
          ${studioKpi(productRowCount, "Product rows")}
          ${studioKpi(trolleyTotal, "Trolleys")}
        </div>
      </section>

      <div class="customers-protected-callout">
        <strong>Published Revision ${escapeHtml(version.version_number)}</strong>
        <span>
          This screen is a visual preview. Authorized users can edit through a protected revision,
          confirm the changes and update the live planner without overwriting history.
        </span>
      </div>

      <div class="customers-studio-version-strip">
        ${summaryItem("Revision", `Revision ${version.version_number}`)}
        ${summaryItem("Status", version.status)}
        ${summaryItem("Effective from", formatDate(version.effective_from))}
        ${summaryItem("Source", version.source_code)}
      </div>

      <section class="customers-studio-week-board" aria-label="Weekly customer schedule preview">
        ${weekDays
          .map((dayDefinition) =>
            renderStudioDayCard(
              dayDefinition,
              activeDayMap.get(dayDefinition.number),
              distributionDayMap.get(dayDefinition.number)
            )
          )
          .join("")}
      </section>

      <section class="customers-studio-global-section">
        <div class="customers-studio-section-heading">
          <div>
            <h3>Customer and revision information</h3>
            <p>Global fields are separate from the day-by-day schedule.</p>
          </div>
          <span class="customers-readonly-badge">Read only</span>
        </div>

        <div class="customers-studio-global-grid">
          ${readonlyField("Customer", payload?.customer_name)}
          ${readonlyField("Customer code", payload?.customer_code)}
          ${readonlyField("Services", (payload?.visible_product_codes || []).join(", ") || "None")}
          ${readonlyField("Effective date", formatDate(payload?.effective_date))}
          ${readonlyField("Operational alert", payload?.operational_alert, { wide: true, multiline: true })}
          ${readonlyField("Revision instructions", version.general_instructions, { wide: true, multiline: true })}
        </div>
      </section>
    `;

    bindScheduleManagementEditor();
  }

  function studioKpi(value, label) {
    return `
      <div class="customers-studio-kpi">
        <b>${escapeHtml(formatNumber(value, "0"))}</b>
        <span>${escapeHtml(label)}</span>
      </div>
    `;
  }

  function summaryItem(label, value) {
    return `
      <div class="customers-summary-item">
        <span>${escapeHtml(label)}</span>
        <strong>${escapeHtml(value ?? "—")}</strong>
      </div>
    `;
  }

  function renderStudioDayCard(dayDefinition, day = null, distributionDay = null) {
    const isActive = Boolean(day);
    const products = Array.isArray(day?.products) ? day.products : [];
    const routeColor = normalizeRouteColor(
      distributionDay?.default_route_color || day?.route_visual_color
    );
    const routeLabel = state.capabilities?.can_view_distribution
      ? distributionDay?.default_route_display_name ||
        distributionDay?.default_route_code ||
        "No default route"
      : routeColor
        ? "Route colour available"
        : "Route details permission controlled";
    const routeCode = state.capabilities?.can_view_distribution
      ? distributionDay?.default_route_code || "Not set"
      : "Permission controlled";
    const deliveryDay = state.capabilities?.can_view_distribution
      ? distributionDay?.delivery_day || "Not set"
      : "Permission controlled";

    return `
      <article
        class="customers-studio-day-card${isActive ? "" : " is-off"}"
        style="${routeCssVariables(routeColor)}"
      >
        <header class="customers-studio-day-header ${dayDefinition.className}">
          <label class="customers-studio-day-toggle" title="Schedule editing is permission controlled">
            <input type="checkbox" ${isActive ? "checked" : ""} disabled>
            <span>${escapeHtml(dayDefinition.name.slice(0, 3))}</span>
          </label>
          <span class="customers-studio-day-status">${isActive ? "ON LIST" : "OFF"}</span>
        </header>

        ${
          isActive
            ? `
              <div class="customers-studio-day-body">
                <div class="customers-studio-route-row">
                  ${routeDotHtml(routeColor, routeLabel)}
                  <div>
                    <strong>${escapeHtml(routeLabel)}</strong>
                    <span>${escapeHtml(routeColor || "No route colour")}</span>
                  </div>
                </div>

                ${products.map(renderStudioProduct).join("")}

                <div class="customers-studio-day-fields">
                  ${readonlyField("Route", routeCode)}
                  ${readonlyField("Delivery day", deliveryDay)}
                  ${readonlyField("Day alert", day.day_alert, { wide: true, multiline: true })}
                </div>
              </div>
            `
            : `
              <div class="customers-studio-day-off-body">
                <span>Not scheduled</span>
                <small>Authorized schedule editing can add this day.</small>
              </div>
            `
        }
      </article>
    `;
  }

  function renderStudioProduct(product) {
    const variants = Array.isArray(product.product_variants)
      ? product.product_variants
      : [];
    const quantityParts = [];

    if (product.expected_kg !== null && product.expected_kg !== undefined) {
      quantityParts.push(`${formatNumber(product.expected_kg)} kg`);
    }

    if (product.expected_units !== null && product.expected_units !== undefined) {
      quantityParts.push(`${formatNumber(product.expected_units)} units`);
    }

    return `
      <section class="customers-studio-product">
        <div class="customers-studio-product-heading">
          <strong>${escapeHtml(product.product_name || product.product_code)}</strong>
          <span>Order ${escapeHtml(product.production_order ?? "—")}</span>
        </div>
        <div class="customers-studio-product-fields">
          ${readonlyField("Quantity plan", quantityParts.join(" · ") || "Not set")}
          ${readonlyField("Trolley", product.trolley_summary || "No planned trolley")}
          ${
            variants.length
              ? readonlyField("Products", variants.join(", "), { wide: true })
              : ""
          }
          ${readonlyField("Instructions", product.production_instructions, { wide: true, multiline: true })}
        </div>
      </section>
    `;
  }

  function canManageCustomerSchedules() {
    return Boolean(
      state.capabilities?.can_edit_schedules &&
      state.capabilities?.can_create_schedule_draft &&
      state.capabilities?.can_save_schedule_draft
    );
  }

  function emptyToNull(value) {
    const normalized = String(value ?? "").trim();
    return normalized === "" ? null : normalized;
  }

  function draftDocumentFromSnapshot(snapshot) {
    if (!snapshot) {
      return null;
    }

    return {
      effective_from: String(snapshot.effective_from || ""),
      effective_until: String(snapshot.effective_until || ""),
      general_instructions: String(snapshot.general_instructions || ""),
      days: (Array.isArray(snapshot.days) ? snapshot.days : [])
        .map((day) => ({
          production_weekday: Number(day.production_weekday),
          delivery_weekday: nextDistributionWeekday(day.production_weekday),
          default_route_id: String(day.default_route_id || ""),
          delivery_window_start: String(day.delivery_window_start || "").slice(0, 5),
          delivery_window_end: String(day.delivery_window_end || "").slice(0, 5),
          delivery_order: day.delivery_order ?? "",
          day_alert: String(day.day_alert || ""),
          distribution_instructions: String(day.distribution_instructions || ""),
          products: (Array.isArray(day.products) ? day.products : []).map((product) => ({
            product_code: String(product.product_code || "").toUpperCase(),
            production_order: product.production_order ?? "",
            expected_kg: product.expected_kg ?? "",
            expected_units: product.expected_units ?? "",
            production_instructions: String(product.production_instructions || ""),
            variant_codes: (Array.isArray(product.variant_codes) ? product.variant_codes : [])
              .map((code) => String(code).toUpperCase())
          })),
          trolley_requirements: (Array.isArray(day.trolley_requirements)
            ? day.trolley_requirements
            : []
          ).map((requirement) => ({
            trolley_type_code: String(requirement.trolley_type_code || "").toUpperCase(),
            owner_product_code: String(requirement.owner_product_code || "").toUpperCase(),
            quantity: requirement.quantity ?? 1,
            empty_trolley: Boolean(requirement.empty_trolley),
            notes: String(requirement.notes || ""),
            serves_product_codes: (Array.isArray(requirement.serves_product_codes)
              ? requirement.serves_product_codes
              : []
            ).map((code) => String(code).toUpperCase())
          }))
        }))
        .sort((left, right) => left.production_weekday - right.production_weekday)
    };
  }

  function draftDocumentForRpc(documentValue) {
    return {
      effective_from: emptyToNull(documentValue?.effective_from),
      effective_until: emptyToNull(documentValue?.effective_until),
      general_instructions: emptyToNull(documentValue?.general_instructions),
      days: (Array.isArray(documentValue?.days) ? documentValue.days : [])
        .map((day) => ({
          production_weekday: Number(day.production_weekday),
          delivery_weekday: nextDistributionWeekday(day.production_weekday),
          default_route_id: emptyToNull(day.default_route_id),
          delivery_window_start: emptyToNull(day.delivery_window_start),
          delivery_window_end: emptyToNull(day.delivery_window_end),
          delivery_order: emptyToNull(day.delivery_order),
          day_alert: emptyToNull(day.day_alert),
          distribution_instructions: emptyToNull(day.distribution_instructions),
          products: (Array.isArray(day.products) ? day.products : []).map((product) => ({
            product_code: String(product.product_code || "").toUpperCase(),
            production_order: emptyToNull(product.production_order),
            expected_kg: emptyToNull(product.expected_kg),
            expected_units: emptyToNull(product.expected_units),
            production_instructions: emptyToNull(product.production_instructions),
            variant_codes: (Array.isArray(product.variant_codes) ? product.variant_codes : [])
              .map((code) => String(code).toUpperCase())
          })),
          trolley_requirements: (Array.isArray(day.trolley_requirements)
            ? day.trolley_requirements
            : []
          ).map((requirement) => ({
            trolley_type_code: String(requirement.trolley_type_code || "").toUpperCase(),
            owner_product_code: String(requirement.owner_product_code || "").toUpperCase(),
            quantity: emptyToNull(requirement.quantity),
            empty_trolley: Boolean(requirement.empty_trolley),
            notes: emptyToNull(requirement.notes),
            serves_product_codes: (Array.isArray(requirement.serves_product_codes)
              ? requirement.serves_product_codes
              : []
            ).map((code) => String(code).toUpperCase())
          }))
        }))
        .sort((left, right) => left.production_weekday - right.production_weekday)
    };
  }

  async function loadScheduleManagementState(customerId, selectedVersionId = null) {
    const management = await rpc("get_customer_schedule_management_state", {
      p_customer_id: customerId,
      p_selected_version_id: selectedVersionId,
      p_effective_date: effectiveDateInput.value
    });

    state.studio.management = management;
    state.studio.view = "schedule";
    state.studio.selectedVersionId = selectedVersionId;
    state.studio.customerId = management?.customer?.customer_id || customerId;
    state.studio.customerCode = management?.customer?.customer_code || state.studio.customerCode;
    state.studio.customerName = management?.customer?.customer_name || state.studio.customerName;
    state.studio.draftDocument = management?.draft_schedule
      ? draftDocumentFromSnapshot(management.draft_schedule)
      : null;
    state.studio.dirty = false;
    state.studio.comparison = null;

    return management;
  }

  function currentStudioSnapshot() {
    const management = state.studio.management;

    if (!management) {
      return null;
    }

    return management.draft_schedule || management.selected_schedule || management.published_schedule;
  }

  function renderScheduleManagementState(management = state.studio.management) {
    state.studio.management = management;

    const customer = management?.customer || {};
    const references = management?.reference_data || {};
    const productTypes = Array.isArray(references.product_types) ? references.product_types : [];
    const snapshot = currentStudioSnapshot();
    const draft = management?.draft_schedule || null;
    const published = draft
      ? management?.published_schedule || null
      : snapshot?.status === "PUBLISHED"
        ? snapshot
        : management?.published_schedule || null;
    const visibleStatus = draft
      ? (state.studio.dirty ? "Unsaved changes" : "Saved changes")
      : snapshot?.status;

    scheduleCode.textContent = customer.customer_code || state.studio.customerCode || "";
    scheduleTitle.textContent = customer.customer_name || state.studio.customerName || "Customer Studio";
    scheduleBadges.innerHTML = serviceBadges(productTypes.map((product) => product.product_code));

    if (!snapshot) {
      scheduleBody.innerHTML = renderEmptyScheduleManagement(customer, management);
      bindScheduleManagementEditor();
      return;
    }

    const activeDocument = draft ? state.studio.draftDocument : null;
    const days = draft
      ? (Array.isArray(activeDocument?.days) ? activeDocument.days : [])
      : (Array.isArray(snapshot.days) ? snapshot.days : []);
    const productCount = days.reduce(
      (total, day) => total + (Array.isArray(day.products) ? day.products.length : 0),
      0
    );
    const trolleyQuantity = days.reduce(
      (total, day) => total + (Array.isArray(day.trolley_requirements)
        ? day.trolley_requirements.reduce(
            (sum, requirement) => sum + (Number(requirement.quantity) || 0),
            0
          )
        : 0),
      0
    );

    scheduleBody.innerHTML = `
      ${renderStudioViewTabs("schedule")}
      <div id="customersStudioAlert" class="customers-form-alert customers-studio-alert hidden" aria-live="polite"></div>

      <section class="customers-studio-hero">
        <div class="customers-studio-identity">
          <div class="customers-studio-name-line">
            <span class="customers-studio-customer-dot" aria-hidden="true"></span>
            <strong>${escapeHtml(customer.customer_name || "Customer")}</strong>
            ${draft ? '<span class="customers-draft-badge">Editing</span>' : '<span class="customers-published-badge">Published</span>'}
          </div>
          <p>
            ${
              draft
                ? `You are editing a protected copy of Revision ${escapeHtml(draft.version_number)}. Click Save Changes to review and confirm the update.`
                : `Published Revision ${escapeHtml(snapshot.version_number)} is protected. Click Edit Schedule to make a safe update.`
            }
          </p>
        </div>

        <div class="customers-studio-kpis">
          ${studioKpi(days.length, "Days")}
          ${studioKpi(productCount, "Products")}
          ${studioKpi(trolleyQuantity, "Trolleys")}
        </div>
      </section>

      ${renderScheduleManagementToolbar(draft, published, management)}

      <div class="customers-studio-version-strip">
        ${summaryItem("Revision", `Revision ${snapshot.version_number}`)}
        ${summaryItem("Status", visibleStatus)}
        ${summaryItem("Effective from", formatDate(snapshot.effective_from))}
        ${summaryItem("Row version", snapshot.row_version)}
      </div>

      ${
        draft
          ? renderDraftGlobalFields(activeDocument)
          : renderPublishedGlobalFields(customer, snapshot)
      }

      <section class="customers-studio-week-board${draft ? " is-editing" : ""}" aria-label="Weekly customer schedule">
        ${
          draft
            ? DAYS.map((dayDefinition) => renderDraftDayCard(dayDefinition)).join("")
            : DAYS.filter((dayDefinition) =>
                dayDefinition.number <= 6 || days.some((day) => Number(day.production_weekday) === dayDefinition.number)
              )
                .map((dayDefinition) =>
                  renderManagementPublishedDayCard(
                    dayDefinition,
                    days.find((day) => Number(day.production_weekday) === dayDefinition.number)
                  )
                )
                .join("")
        }
      </section>

    `;

    bindScheduleManagementEditor();
  }


  function renderStudioViewTabs(activeView = "schedule") {
    if (!state.capabilities?.can_view_schedule_history) {
      return "";
    }

    const hasPending = Boolean(state.studio.management?.draft_schedule);

    return `
      <nav class="customers-studio-view-tabs" aria-label="Customer schedule views">
        <button
          class="${activeView === "schedule" ? "active" : ""}"
          type="button"
          data-studio-view="schedule"
        >
          Current Schedule
        </button>
        <button
          class="${activeView === "history" ? "active" : ""}"
          type="button"
          data-studio-view="history"
        >
          Version History
          ${hasPending ? '<span class="customers-history-pending-dot" title="Saved changes are waiting for confirmation"></span>' : ""}
        </button>
      </nav>
    `;
  }

  async function loadScheduleHistory(selectedVersionId = null) {
    if (!state.capabilities?.can_view_schedule_history) {
      showToast("Your role cannot view schedule history.");
      return;
    }

    state.studio.view = "history";
    scheduleBody.innerHTML = `${renderStudioViewTabs("history")}${loadingHtml("Loading schedule history...")}`;
    bindScheduleManagementEditor();

    const history = await rpc("get_customer_schedule_history", {
      p_customer_id: state.studio.customerId,
      p_selected_version_id: selectedVersionId,
      p_effective_date: effectiveDateInput.value,
      p_limit: 50
    });

    state.studio.history = history;
    state.studio.selectedVersionId = history?.selected_version_id || selectedVersionId;
    renderScheduleHistory(history);
  }

  function returnToCurrentSchedule() {
    state.studio.view = "schedule";

    if (state.studio.management) {
      renderScheduleManagementState();
      return;
    }

    if (state.studio.readOnlyPayload) {
      renderScheduleDetails(
        state.studio.readOnlyPayload,
        state.studio.readOnlyDistributionPayload
      );
      return;
    }

    openScheduleDetails(
      state.studio.customerId,
      state.studio.customerCode,
      state.studio.customerName
    );
  }

  function historyDisplayStatus(version) {
    const value = String(version?.display_status || version?.status || "").toUpperCase();
    const labels = {
      CURRENT: "Current",
      PREVIOUS: "Previous",
      PENDING: "Pending changes",
      DISCARDED: "Discarded",
      PUBLISHED: "Published"
    };
    return labels[value] || value || "Unknown";
  }

  function historyStatusClass(version) {
    const value = String(version?.display_status || version?.status || "").toLowerCase();
    return value.replace(/[^a-z0-9_-]/g, "-");
  }

  function historyValue(value, fallback = "Not set") {
    if (value === null || value === undefined || value === "") {
      return fallback;
    }
    return String(value);
  }

  function historyShortText(value, fallback = "Not set", limit = 120) {
    const text = historyValue(value, fallback).replace(/\s+/g, " ").trim();
    return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
  }

  function historyComparable(value) {
    if (Array.isArray(value)) {
      return value.map((item) => String(item)).sort();
    }
    return value === undefined ? null : value;
  }

  function historyValuesEqual(before, after) {
    return JSON.stringify(historyComparable(before)) === JSON.stringify(historyComparable(after));
  }

  function historyProductLabel(productCode) {
    const reference = productReferenceByCode(productCode);
    return reference?.display_name || productCode || "Product";
  }

  function historyRouteLabel(routeId) {
    const route = routeReferenceById(routeId);
    return route?.display_name || route?.route_code || (routeId ? "Unknown route" : "Not set");
  }

  function historyTrolleyTypeLabel(typeCode) {
    const trolleyTypes = Array.isArray(state.studio.management?.reference_data?.trolley_types)
      ? state.studio.management.reference_data.trolley_types
      : [];
    const reference = trolleyTypes.find((item) => item.trolley_type_code === typeCode);
    return reference?.trolley_type_name || reference?.display_code || typeCode || "Trolley";
  }

  function historyProductMap(day) {
    return new Map(
      (Array.isArray(day?.products) ? day.products : []).map((product) => [product.product_code, product])
    );
  }

  function historyTrolleyKey(requirement) {
    const serves = Array.isArray(requirement?.serves_product_codes)
      ? requirement.serves_product_codes.map((value) => String(value)).sort().join("+")
      : "";
    return [
      requirement?.trolley_type_code || "",
      requirement?.owner_product_code || "",
      serves
    ].join("|");
  }

  function historyTrolleyMap(day) {
    const result = new Map();
    (Array.isArray(day?.trolley_requirements) ? day.trolley_requirements : []).forEach((requirement, index) => {
      let key = historyTrolleyKey(requirement);
      if (result.has(key)) {
        key = `${key}|${index}`;
      }
      result.set(key, requirement);
    });
    return result;
  }

  function historyDayProducts(day) {
    const products = Array.isArray(day?.products) ? day.products : [];
    return products.map((product) => historyProductLabel(product.product_code)).join(" + ") || "No products";
  }

  function historyDayTrolleyQuantity(day) {
    return (Array.isArray(day?.trolley_requirements) ? day.trolley_requirements : [])
      .reduce((total, requirement) => total + (Number(requirement.quantity) || 0), 0);
  }

  function historyDayOverview(day) {
    if (!day) {
      return "Not scheduled";
    }
    return [
      `Products: ${historyDayProducts(day)}`,
      `Route: ${historyRouteLabel(day.default_route_id)}`,
      `Trolleys: ${historyDayTrolleyQuantity(day)}`
    ].join(" · ");
  }

  function historyChangeItem(type, title, detail = "", dayName = "") {
    return { type, title, detail, dayName };
  }

  function buildHistoryChangeItems(comparison) {
    if (!comparison?.has_changes) {
      return [];
    }

    const items = [];
    const before = comparison?.before || {};
    const after = comparison?.after || {};

    if (comparison.effective_period_changed) {
      const beforePeriod = before.effective_from
        ? `${formatDate(before.effective_from)}${before.effective_until ? ` to ${formatDate(before.effective_until)}` : " onward"}`
        : "No previous schedule";
      const afterPeriod = after.effective_from
        ? `${formatDate(after.effective_from)}${after.effective_until ? ` to ${formatDate(after.effective_until)}` : " onward"}`
        : "No schedule";
      items.push(historyChangeItem("changed", "Effective period changed", `${beforePeriod} → ${afterPeriod}`));
    }

    if (comparison.general_instructions_changed) {
      items.push(historyChangeItem(
        "changed",
        "General instructions changed",
        `Before: ${historyShortText(before.general_instructions)} · After: ${historyShortText(after.general_instructions)}`
      ));
    }

    const beforeDays = new Map(
      (Array.isArray(before.days) ? before.days : []).map((day) => [Number(day.production_weekday), day])
    );
    const afterDays = new Map(
      (Array.isArray(after.days) ? after.days : []).map((day) => [Number(day.production_weekday), day])
    );
    const changedWeekdays = Array.isArray(comparison.changed_weekdays) ? comparison.changed_weekdays : [];

    changedWeekdays.forEach((change) => {
      const weekday = Number(change.weekday);
      const dayName = change.day_name || weekdayLabel(weekday);
      const beforeDay = beforeDays.get(weekday) || null;
      const afterDay = afterDays.get(weekday) || null;

      if (!beforeDay && afterDay) {
        items.push(historyChangeItem("added", `${dayName} added to the weekly schedule`, historyDayOverview(afterDay), dayName));
        return;
      }

      if (beforeDay && !afterDay) {
        items.push(historyChangeItem("removed", `${dayName} removed from the weekly schedule`, historyDayOverview(beforeDay), dayName));
        return;
      }

      if (!beforeDay || !afterDay) {
        return;
      }

      const dayStartCount = items.length;

      if (!historyValuesEqual(beforeDay.default_route_id, afterDay.default_route_id)) {
        items.push(historyChangeItem(
          "changed",
          `${dayName} route changed`,
          `${historyRouteLabel(beforeDay.default_route_id)} → ${historyRouteLabel(afterDay.default_route_id)}`,
          dayName
        ));
      }

      if (!historyValuesEqual(beforeDay.delivery_weekday, afterDay.delivery_weekday)) {
        items.push(historyChangeItem(
          "changed",
          `${dayName} delivery day changed`,
          `${weekdayLabel(beforeDay.delivery_weekday)} → ${weekdayLabel(afterDay.delivery_weekday)}`,
          dayName
        ));
      }

      const beforeWindow = `${historyValue(beforeDay.delivery_window_start)}–${historyValue(beforeDay.delivery_window_end)}`;
      const afterWindow = `${historyValue(afterDay.delivery_window_start)}–${historyValue(afterDay.delivery_window_end)}`;
      if (beforeWindow !== afterWindow) {
        items.push(historyChangeItem("changed", `${dayName} delivery window changed`, `${beforeWindow} → ${afterWindow}`, dayName));
      }

      if (!historyValuesEqual(beforeDay.delivery_order, afterDay.delivery_order)) {
        items.push(historyChangeItem(
          "changed",
          `${dayName} delivery order changed`,
          `${historyValue(beforeDay.delivery_order)} → ${historyValue(afterDay.delivery_order)}`,
          dayName
        ));
      }

      if (!historyValuesEqual(beforeDay.day_alert, afterDay.day_alert)) {
        items.push(historyChangeItem(
          "changed",
          `${dayName} alert changed`,
          `Before: ${historyShortText(beforeDay.day_alert)} · After: ${historyShortText(afterDay.day_alert)}`,
          dayName
        ));
      }

      if (!historyValuesEqual(beforeDay.distribution_instructions, afterDay.distribution_instructions)) {
        items.push(historyChangeItem(
          "changed",
          `${dayName} distribution instructions changed`,
          `Before: ${historyShortText(beforeDay.distribution_instructions)} · After: ${historyShortText(afterDay.distribution_instructions)}`,
          dayName
        ));
      }

      const beforeProducts = historyProductMap(beforeDay);
      const afterProducts = historyProductMap(afterDay);
      const productCodes = new Set([...beforeProducts.keys(), ...afterProducts.keys()]);

      productCodes.forEach((productCode) => {
        const beforeProduct = beforeProducts.get(productCode) || null;
        const afterProduct = afterProducts.get(productCode) || null;
        const productLabel = historyProductLabel(productCode);

        if (!beforeProduct && afterProduct) {
          items.push(historyChangeItem(
            "added",
            `${productLabel} added on ${dayName}`,
            `Production order ${historyValue(afterProduct.production_order, "Auto")}`,
            dayName
          ));
          return;
        }

        if (beforeProduct && !afterProduct) {
          items.push(historyChangeItem(
            "removed",
            `${productLabel} removed from ${dayName}`,
            `Previous production order ${historyValue(beforeProduct.production_order, "Not set")}`,
            dayName
          ));
          return;
        }

        if (!beforeProduct || !afterProduct) {
          return;
        }

        if (!historyValuesEqual(beforeProduct.production_order, afterProduct.production_order)) {
          items.push(historyChangeItem(
            "changed",
            `${productLabel} production order changed on ${dayName}`,
            `${historyValue(beforeProduct.production_order)} → ${historyValue(afterProduct.production_order)}`,
            dayName
          ));
        }

        if (!historyValuesEqual(beforeProduct.expected_kg, afterProduct.expected_kg)) {
          items.push(historyChangeItem(
            "changed",
            `${productLabel} expected kg changed on ${dayName}`,
            `${historyValue(beforeProduct.expected_kg)} kg → ${historyValue(afterProduct.expected_kg)} kg`,
            dayName
          ));
        }

        if (!historyValuesEqual(beforeProduct.expected_units, afterProduct.expected_units)) {
          items.push(historyChangeItem(
            "changed",
            `${productLabel} expected units changed on ${dayName}`,
            `${historyValue(beforeProduct.expected_units)} → ${historyValue(afterProduct.expected_units)}`,
            dayName
          ));
        }

        if (!historyValuesEqual(beforeProduct.variant_codes, afterProduct.variant_codes)) {
          const beforeVariants = Array.isArray(beforeProduct.variant_codes) ? beforeProduct.variant_codes.join(", ") : "";
          const afterVariants = Array.isArray(afterProduct.variant_codes) ? afterProduct.variant_codes.join(", ") : "";
          items.push(historyChangeItem(
            "changed",
            `${productLabel} variants changed on ${dayName}`,
            `${beforeVariants || "None"} → ${afterVariants || "None"}`,
            dayName
          ));
        }

        if (!historyValuesEqual(beforeProduct.production_instructions, afterProduct.production_instructions)) {
          items.push(historyChangeItem(
            "changed",
            `${productLabel} instructions changed on ${dayName}`,
            `Before: ${historyShortText(beforeProduct.production_instructions)} · After: ${historyShortText(afterProduct.production_instructions)}`,
            dayName
          ));
        }
      });

      const beforeTrolleys = historyTrolleyMap(beforeDay);
      const afterTrolleys = historyTrolleyMap(afterDay);
      const trolleyKeys = new Set([...beforeTrolleys.keys(), ...afterTrolleys.keys()]);

      trolleyKeys.forEach((key) => {
        const beforeRequirement = beforeTrolleys.get(key) || null;
        const afterRequirement = afterTrolleys.get(key) || null;
        const reference = afterRequirement || beforeRequirement || {};
        const trolleyLabel = historyTrolleyTypeLabel(reference.trolley_type_code);
        const serves = Array.isArray(reference.serves_product_codes) && reference.serves_product_codes.length
          ? reference.serves_product_codes.map(historyProductLabel).join(" + ")
          : historyProductLabel(reference.owner_product_code);

        if (!beforeRequirement && afterRequirement) {
          items.push(historyChangeItem(
            "added",
            `${afterRequirement.quantity || 0} × ${trolleyLabel} trolley added on ${dayName}`,
            `Serves ${serves}${afterRequirement.empty_trolley ? " · Empty trolley" : ""}`,
            dayName
          ));
          return;
        }

        if (beforeRequirement && !afterRequirement) {
          items.push(historyChangeItem(
            "removed",
            `${beforeRequirement.quantity || 0} × ${trolleyLabel} trolley removed from ${dayName}`,
            `Served ${serves}${beforeRequirement.empty_trolley ? " · Empty trolley" : ""}`,
            dayName
          ));
          return;
        }

        if (!beforeRequirement || !afterRequirement) {
          return;
        }

        if (!historyValuesEqual(beforeRequirement.quantity, afterRequirement.quantity)) {
          items.push(historyChangeItem(
            "changed",
            `${trolleyLabel} trolley quantity changed on ${dayName}`,
            `${historyValue(beforeRequirement.quantity)} → ${historyValue(afterRequirement.quantity)} · Serves ${serves}`,
            dayName
          ));
        }

        if (!historyValuesEqual(beforeRequirement.empty_trolley, afterRequirement.empty_trolley)) {
          items.push(historyChangeItem(
            "changed",
            `${trolleyLabel} trolley empty status changed on ${dayName}`,
            `${beforeRequirement.empty_trolley ? "Empty" : "Loaded"} → ${afterRequirement.empty_trolley ? "Empty" : "Loaded"}`,
            dayName
          ));
        }

        if (!historyValuesEqual(beforeRequirement.notes, afterRequirement.notes)) {
          items.push(historyChangeItem(
            "changed",
            `${trolleyLabel} trolley notes changed on ${dayName}`,
            `Before: ${historyShortText(beforeRequirement.notes)} · After: ${historyShortText(afterRequirement.notes)}`,
            dayName
          ));
        }
      });

      if (items.length === dayStartCount) {
        items.push(historyChangeItem("changed", `${dayName} schedule details changed`, "Open the technical details below to review the complete before-and-after values.", dayName));
      }
    });

    return items;
  }

  function renderHistoryChangeSummary(comparison, options = {}) {
    const items = buildHistoryChangeItems(comparison);
    const title = options.title || "Clear change summary";
    const subtitle = options.subtitle || "The list below describes the actual operational changes.";
    const showTechnical = options.showTechnical !== false;
    const affectedDays = [...new Set(items.map((item) => item.dayName).filter(Boolean))];

    if (!comparison?.has_changes || items.length === 0) {
      return `
        <div class="customers-history-no-change">
          <strong>No operational changes</strong>
          <span>This revision has the same normalized schedule content as the comparison version.</span>
        </div>
      `;
    }

    return `
      <div class="customers-history-clear-summary">
        <div class="customers-history-clear-heading">
          <div>
            <strong>${escapeHtml(title)}</strong>
            <span>${escapeHtml(subtitle)}</span>
          </div>
          <div class="customers-history-clear-count">
            <b>${escapeHtml(items.length)}</b>
            <span>${items.length === 1 ? "change" : "changes"}${affectedDays.length ? ` · ${affectedDays.length} ${affectedDays.length === 1 ? "day" : "days"}` : ""}</span>
          </div>
        </div>
        <div class="customers-history-change-list">
          ${items.map((item) => `
            <article class="customers-history-change-item ${escapeHtml(item.type)}">
              <span class="customers-history-change-icon" aria-hidden="true">${item.type === "added" ? "+" : item.type === "removed" ? "−" : "↔"}</span>
              <div>
                <strong>${escapeHtml(item.title)}</strong>
                ${item.detail ? `<span>${escapeHtml(item.detail)}</span>` : ""}
              </div>
            </article>
          `).join("")}
        </div>
        ${showTechnical ? `
          <details class="customers-history-technical-details">
            <summary>Show full before-and-after details</summary>
            <div class="customers-history-technical-body">
              ${renderTechnicalComparison(comparison)}
            </div>
          </details>
        ` : ""}
      </div>
    `;
  }

  function renderTechnicalComparison(comparison) {
    const changedWeekdays = Array.isArray(comparison?.changed_weekdays) ? comparison.changed_weekdays : [];
    const before = comparison?.summary?.before || {};
    const after = comparison?.summary?.after || {};

    return `
      <div class="customers-studio-comparison-summary">
        ${comparisonMetric("Days", before.days, after.days)}
        ${comparisonMetric("Products", before.products, after.products)}
        ${comparisonMetric("Trolley rows", before.trolley_requirements, after.trolley_requirements)}
        ${comparisonMetric("Trolley quantity", before.trolley_quantity, after.trolley_quantity)}
      </div>
      <div class="customers-studio-change-flags">
        ${comparison.effective_period_changed ? '<span>Effective period changed</span>' : ""}
        ${comparison.general_instructions_changed ? '<span>General instructions changed</span>' : ""}
        ${changedWeekdays.length
          ? changedWeekdays.map((day) => `<span>${escapeHtml(day.day_name)} · ${escapeHtml(day.change_type)}</span>`).join("")
          : '<span class="unchanged">No weekday changes</span>'}
      </div>
      ${changedWeekdays.length
        ? `<div class="customers-studio-comparison-days">${changedWeekdays.map((change) => renderComparisonDay(change, comparison)).join("")}</div>`
        : ""}
    `;
  }

  function renderScheduleHistory(history = state.studio.history) {
    state.studio.view = "history";

    const customer = history?.customer || {};
    const versions = Array.isArray(history?.versions) ? history.versions : [];
    const selected = history?.selected_schedule || null;
    const selectedMeta = versions.find(
      (version) => version.schedule_version_id === history?.selected_version_id
    ) || versions[0] || null;
    const currentId = history?.current_version_id || null;
    const selectedIsCurrent = Boolean(
      selectedMeta && selectedMeta.schedule_version_id === currentId
    );
    const canRestore = Boolean(
      history?.permissions?.can_restore_version &&
      selectedMeta &&
      !selectedIsCurrent &&
      ["PUBLISHED", "SUPERSEDED", "CANCELLED"].includes(String(selectedMeta.status || "").toUpperCase())
    );
    const days = Array.isArray(selected?.days) ? selected.days : [];
    const productCount = days.reduce(
      (total, day) => total + (Array.isArray(day.products) ? day.products.length : 0),
      0
    );
    const trolleyQuantity = days.reduce(
      (total, day) => total + (Array.isArray(day.trolley_requirements)
        ? day.trolley_requirements.reduce((sum, item) => sum + (Number(item.quantity) || 0), 0)
        : 0),
      0
    );

    scheduleCode.textContent = customer.customer_code || state.studio.customerCode || "";
    scheduleTitle.textContent = customer.customer_name || state.studio.customerName || "Customer Schedule";

    scheduleBody.innerHTML = `
      ${renderStudioViewTabs("history")}
      <div id="customersStudioAlert" class="customers-form-alert customers-studio-alert hidden" aria-live="polite"></div>

      <section class="customers-history-hero">
        <div>
          <span class="customers-modal-code">Protected schedule history</span>
          <h3>${escapeHtml(customer.customer_name || "Customer")}</h3>
          <p>Each update is preserved as a separate revision. Previous revisions can be viewed or restored as a new update.</p>
        </div>
        <div class="customers-studio-kpis">
          ${studioKpi(versions.length, "Versions")}
          ${studioKpi(days.length, "Selected days")}
          ${studioKpi(productCount, "Products")}
        </div>
      </section>

      ${history?.open_working_revision_id
        ? `
          <div class="customers-warning-callout customers-history-warning">
            <strong>Saved schedule changes are waiting for confirmation.</strong>
            <span>Finish or discard the current changes before restoring a previous version.</span>
          </div>
        `
        : ""}

      ${versions.length
        ? `
          <section class="customers-history-layout">
            <aside class="customers-history-list" aria-label="Schedule versions">
              <div class="customers-history-list-heading">
                <strong>Versions</strong>
                <span>${escapeHtml(versions.length)} shown</span>
              </div>
              ${versions.map((version) => renderHistoryVersionButton(version, history?.selected_version_id)).join("")}
            </aside>

            <div class="customers-history-detail">
              ${selected && selectedMeta
                ? renderHistorySelectedVersion(selected, selectedMeta, history, {
                    canRestore,
                    selectedIsCurrent,
                    trolleyQuantity
                  })
                : emptyHtml("No schedule revision is available.")}
            </div>
          </section>
        `
        : emptyHtml("No schedule history exists for this customer.", "Create and publish a schedule to start the history.")}
    `;

    bindScheduleManagementEditor();
  }

  function renderHistoryVersionButton(version, selectedVersionId) {
    const selected = version.schedule_version_id === selectedVersionId;
    const timestamp = version.published_at || version.cancelled_at || version.updated_at || version.created_at;

    return `
      <button
        class="customers-history-version${selected ? " selected" : ""}"
        type="button"
        data-history-version-id="${escapeHtml(version.schedule_version_id)}"
      >
        <span class="customers-history-version-topline">
          <strong>Revision ${escapeHtml(version.version_number)}</strong>
          <span class="customers-history-status ${escapeHtml(historyStatusClass(version))}">${escapeHtml(historyDisplayStatus(version))}</span>
        </span>
        <span class="customers-history-reason">${escapeHtml(version.change_reason || "No reason recorded")}</span>
        <span class="customers-history-period">
          ${escapeHtml(formatDate(version.effective_from))}
          ${version.effective_until ? ` – ${escapeHtml(formatDate(version.effective_until))}` : " onward"}
        </span>
        <span class="customers-history-meta">
          ${escapeHtml(version.changed_by_name || "System")} · ${escapeHtml(formatDateTime(timestamp))}
        </span>
        <span class="customers-history-counts">
          ${escapeHtml(version.day_count || 0)} days · ${escapeHtml(version.product_count || 0)} products · ${escapeHtml(version.trolley_quantity || 0)} trolleys
        </span>
      </button>
    `;
  }

  function renderHistorySelectedVersion(snapshot, version, history, options) {
    const days = Array.isArray(snapshot?.days) ? snapshot.days : [];
    const hasReadableComparison = Object.prototype.hasOwnProperty.call(history || {}, "change_comparison");
    const changeComparison = hasReadableComparison ? history?.change_comparison : null;
    const restoreComparison = history?.restore_comparison || history?.comparison || null;
    const restoreReason = version.change_reason || "No change reason recorded.";
    const versions = Array.isArray(history?.versions) ? history.versions : [];
    const baseVersion = versions.find((item) => item.schedule_version_id === history?.change_base_version_id) || null;
    const changeSubtitle = baseVersion
      ? `Compared with Revision ${baseVersion.version_number}, which was the protected base for this update.`
      : "This was the first schedule revision, so all scheduled items are shown as additions.";

    return `
      <section class="customers-history-detail-header">
        <div>
          <div class="customers-history-title-row">
            <h3>Revision ${escapeHtml(version.version_number)}</h3>
            <span class="customers-history-status ${escapeHtml(historyStatusClass(version))}">${escapeHtml(historyDisplayStatus(version))}</span>
          </div>
          <p>${escapeHtml(restoreReason)}</p>
        </div>
        <div class="customers-history-actions">
          ${options.selectedIsCurrent
            ? '<span class="customers-readonly-badge">Current list</span>'
            : `
              <button
                class="customers-primary-button"
                type="button"
                data-history-restore
                ${options.canRestore ? "" : "disabled"}
                title="${history?.open_working_revision_id ? "Finish the current saved changes first" : "Restore this revision as a new protected update"}"
              >
                Restore as New Update
              </button>
            `}
        </div>
      </section>

      <div class="customers-studio-version-strip customers-history-version-strip">
        ${summaryItem("Status", historyDisplayStatus(version))}
        ${summaryItem("Effective from", formatDate(version.effective_from))}
        ${summaryItem("Effective until", formatDate(version.effective_until))}
        ${summaryItem("Changed by", version.changed_by_name || "System")}
      </div>

      <section class="customers-history-comparison customers-history-readable-comparison">
        <div class="customers-history-section-heading">
          <div>
            <span class="customers-modal-code">Revision ${escapeHtml(version.version_number)}</span>
            <h3>What changed in this revision</h3>
          </div>
        </div>
        ${changeComparison
          ? renderHistoryChangeSummary(changeComparison, {
              title: `Revision ${version.version_number} change summary`,
              subtitle: changeSubtitle
            })
          : restoreComparison
            ? renderHistoryChangeSummary(restoreComparison, {
                title: "Difference from the current list",
                subtitle: "Apply Migration 202608030003 to separate the original revision change from today's restore impact."
              })
            : `
              <div class="customers-history-no-change">
                <strong>Current revision details</strong>
                <span>The original revision comparison is not available in this response.</span>
              </div>
            `}
      </section>

      ${!options.selectedIsCurrent && restoreComparison
        ? `
          <details class="customers-history-restore-impact">
            <summary>
              <span>
                <strong>Restore impact compared with the current list</strong>
                <small>Open this only when deciding whether to restore Revision ${escapeHtml(version.version_number)}.</small>
              </span>
              <b>Review impact</b>
            </summary>
            <div class="customers-history-restore-impact-body">
              ${renderHistoryChangeSummary(restoreComparison, {
                title: "Changes that restoration would apply today",
                subtitle: "This compares the current live schedule with the selected historical revision."
              })}
            </div>
          </details>
        `
        : ""}

      <section class="customers-history-section">
        <div class="customers-history-section-heading">
          <div>
            <span class="customers-modal-code">Selected revision</span>
            <h3>Weekly schedule</h3>
          </div>
          <span>${escapeHtml(days.length)} active days · ${escapeHtml(options.trolleyQuantity)} trolleys</span>
        </div>
        <div class="customers-studio-week-board customers-history-week-board">
          ${DAYS.filter((definition) =>
              definition.number <= 6 || days.some((day) => Number(day.production_weekday) === definition.number)
            )
            .map((definition) =>
              renderHistoryDayCard(
                definition,
                days.find((day) => Number(day.production_weekday) === definition.number)
              )
            )
            .join("")}
        </div>
      </section>
    `;
  }

  function renderHistoryDayCard(dayDefinition, day) {
    if (!day) {
      return `
        <article class="customers-studio-day-card is-off">
          <header class="customers-studio-day-header ${escapeHtml(dayDefinition.className)}">
            <strong>${escapeHtml(dayDefinition.name)}</strong>
            <span>Off</span>
          </header>
        </article>
      `;
    }

    const route = day.default_route || null;
    const products = Array.isArray(day.products) ? day.products : [];
    const requirements = Array.isArray(day.trolley_requirements) ? day.trolley_requirements : [];
    const routeColor = normalizeRouteColor(route?.route_color);

    return `
      <article class="customers-studio-day-card">
        <header class="customers-studio-day-header ${escapeHtml(dayDefinition.className)}">
          <strong>${escapeHtml(dayDefinition.name)}</strong>
          <span>Active</span>
        </header>
        <div class="customers-history-day-body">
          <div class="customers-history-route-line">
            <span class="customers-route-dot" style="--route-color:${escapeHtml(routeColor || "#cbd5e1")}"></span>
            <strong>${escapeHtml(route?.display_name || route?.route_code || "No default route")}</strong>
          </div>
          <p><b>Products:</b> ${escapeHtml(products.map((product) => `${product.product_code} #${product.production_order ?? "—"}`).join(" · ") || "None")}</p>
          <p><b>Delivery:</b> ${escapeHtml(day.delivery_day || weekdayLabel(day.delivery_weekday) || "Not set")}</p>
          <p><b>Trolleys:</b> ${escapeHtml(requirements.reduce((sum, item) => sum + (Number(item.quantity) || 0), 0))}</p>
          ${day.day_alert ? `<p class="customers-history-day-alert">${escapeHtml(day.day_alert)}</p>` : ""}
        </div>
      </article>
    `;
  }

  function openRestoreHistoryDialog() {
    const history = state.studio.history;
    const version = (Array.isArray(history?.versions) ? history.versions : [])
      .find((item) => item.schedule_version_id === history?.selected_version_id);

    if (!version || !history?.selected_schedule) {
      showStudioAlert("Select a previous revision first.");
      return;
    }

    const businessDate = history?.business_date || state.capabilities?.business_date || "";
    const requestedDate = effectiveDateInput.value || businessDate;
    const effectiveFrom = requestedDate >= businessDate ? requestedDate : businessDate;

    openScheduleActionDialog({
      title: `Restore Revision ${version.version_number}`,
      description: "This copies the selected schedule into a new protected update. Review and confirm it before the live planner changes.",
      confirmLabel: "Confirm Restore",
      showEffectiveDate: true,
      effectiveFrom,
      reviewHtml: (history?.restore_comparison || history?.comparison) ? renderPublishReviewSummary(history.restore_comparison || history.comparison) : "",
      async onConfirm({ reason, effectiveFrom: confirmedDate }) {
        const result = await rpc("restore_customer_schedule_version_as_update", {
          p_source_version_id: version.schedule_version_id,
          p_effective_from: confirmedDate,
          p_reason: reason,
          p_source_application: "CUSTOMER_STUDIO_HISTORY"
        });
        const publishedId = result?.published_schedule?.schedule_version_id || null;

        await loadScheduleManagementState(
          state.studio.customerId,
          publishedId
        );
        renderScheduleManagementState();
        await loadMainView();
        showToast(`Revision ${version.version_number} was restored as a new update.`);
      }
    });
  }

  function renderEmptyScheduleManagement(customer, management) {
    const canCreate = Boolean(management?.permissions?.can_create_draft);

    return `
      ${renderStudioViewTabs("schedule")}
      <div id="customersStudioAlert" class="customers-form-alert customers-studio-alert hidden" aria-live="polite"></div>
      <section class="customers-studio-hero">
        <div class="customers-studio-identity">
          <div class="customers-studio-name-line">
            <span class="customers-studio-customer-dot" aria-hidden="true"></span>
            <strong>${escapeHtml(customer?.customer_name || "Customer")}</strong>
          </div>
          <p>No published production schedule is effective on ${escapeHtml(formatDate(management?.effective_date || effectiveDateInput.value))}.</p>
        </div>
      </section>
      <div class="customers-studio-empty-management">
        <strong>No schedule is available.</strong>
        <p>Create the weekly schedule and add the required production days and products.</p>
        ${
          canCreate
            ? '<button class="customers-primary-button" type="button" data-studio-action="create-draft">Create Schedule</button>'
            : ""
        }
      </div>
    `;
  }

  function renderScheduleManagementToolbar(draft, published, management) {
    if (!draft) {
      return `
        <div class="customers-studio-actionbar">
          <div>
            <strong>Published schedule is protected</strong>
            <span>Edit Schedule opens a safe working revision. Saving shows the changes for confirmation before the live planner is updated.</span>
          </div>
          <div class="customers-studio-actions">
            <button
              class="customers-primary-button"
              type="button"
              data-studio-action="create-draft"
              ${management?.permissions?.can_create_draft ? "" : "disabled"}
            >
              Edit Schedule
            </button>
          </div>
        </div>
      `;
    }

    return `
      <div class="customers-studio-actionbar is-draft">
        <div>
          <strong>Schedule editing</strong>
          <span data-studio-edit-status>
            ${
              published
                ? `Based on Published Revision ${escapeHtml(published.version_number)}.`
                : "This is the first schedule for this customer."
            }
            ${state.studio.dirty ? " Unsaved changes are waiting." : " Saved changes are waiting for final confirmation."}
          </span>
        </div>
        <div class="customers-studio-actions">
          <button class="customers-secondary-button" type="button" data-studio-action="reload-draft">Reload Saved</button>
          <button class="customers-secondary-button" type="button" data-studio-action="cancel-draft">Discard Changes</button>
          <button class="customers-primary-button" type="button" data-studio-action="save-draft">${state.studio.dirty ? "Save Changes" : "Review & Update"}</button>
        </div>
      </div>
    `;
  }

  function renderDraftGlobalFields(documentValue) {
    const businessDate = state.studio.management?.business_date || state.capabilities?.business_date || "";

    return `
      <section class="customers-studio-global-section customers-studio-edit-section">
        <div class="customers-studio-section-heading">
          <div>
            <h3>Schedule change details</h3>
            <p>Effective dates and general instructions for the updated schedule.</p>
          </div>
          <span class="customers-draft-badge">Editable</span>
        </div>
        <div class="customers-studio-global-grid">
          ${editableField("Effective from *", "effective_from", documentValue?.effective_from, { type: "date", min: businessDate })}
          ${editableField("Effective until", "effective_until", documentValue?.effective_until, { type: "date", min: documentValue?.effective_from || businessDate })}
          ${editableField("General instructions", "general_instructions", documentValue?.general_instructions, { wide: true, multiline: true })}
        </div>
      </section>
    `;
  }

  function renderPublishedGlobalFields(customer, snapshot) {
    return `
      <section class="customers-studio-global-section">
        <div class="customers-studio-section-heading">
          <div>
            <h3>Customer and revision information</h3>
            <p>This published revision is read only.</p>
          </div>
          <span class="customers-readonly-badge">Protected</span>
        </div>
        <div class="customers-studio-global-grid">
          ${readonlyField("Customer", customer?.customer_name)}
          ${readonlyField("Customer code", customer?.customer_code)}
          ${readonlyField("Effective until", formatDate(snapshot?.effective_until))}
          ${readonlyField("Source", snapshot?.source_code)}
          ${readonlyField("Operational alert", customer?.operational_alert, { wide: true, multiline: true })}
          ${readonlyField("Revision instructions", snapshot?.general_instructions, { wide: true, multiline: true })}
        </div>
      </section>
    `;
  }

  function editableField(label, fieldName, value, options = {}) {
    const wideClass = options.wide ? " customers-studio-field-wide" : "";
    const attributes = [
      `data-studio-field="${escapeHtml(fieldName)}"`,
      options.min ? `min="${escapeHtml(options.min)}"` : ""
    ].filter(Boolean).join(" ");

    return `
      <label class="customers-studio-field${wideClass}">
        <span>${escapeHtml(label)}</span>
        ${
          options.multiline
            ? `<textarea rows="3" ${attributes}>${escapeHtml(value || "")}</textarea>`
            : `<input type="${escapeHtml(options.type || "text")}" value="${escapeHtml(value ?? "")}" ${attributes}>`
        }
      </label>
    `;
  }

  function renderDraftDayCard(dayDefinition) {
    const documentValue = state.studio.draftDocument;
    const day = (Array.isArray(documentValue?.days) ? documentValue.days : [])
      .find((item) => Number(item.production_weekday) === dayDefinition.number);
    const isActive = Boolean(day);
    const route = routeReferenceById(day?.default_route_id);
    const routeColor = normalizeRouteColor(route?.route_color);

    return `
      <article
        class="customers-studio-day-card customers-studio-edit-day${isActive ? "" : " is-off"}"
        data-studio-weekday="${dayDefinition.number}"
        style="${routeCssVariables(routeColor)}"
      >
        <header class="customers-studio-day-header ${dayDefinition.className}">
          <label class="customers-studio-day-toggle">
            <input type="checkbox" data-studio-day-toggle ${isActive ? "checked" : ""}>
            <span>${escapeHtml(dayDefinition.name.slice(0, 3))}</span>
          </label>
          <span class="customers-studio-day-status">${isActive ? "ON LIST" : "OFF"}</span>
        </header>

        ${
          isActive
            ? renderDraftDayBody(day, dayDefinition)
            : `
              <div class="customers-studio-day-off-body">
                <span>Not scheduled</span>
                <small>Turn this day on to add it to the draft.</small>
              </div>
            `
        }
      </article>
    `;
  }

  function renderDraftDayBody(day, dayDefinition) {
    const references = state.studio.management?.reference_data || {};
    const productTypes = Array.isArray(references.product_types) ? references.product_types : [];
    const routes = Array.isArray(references.routes) ? references.routes : [];
    const activeProducts = Array.isArray(day.products) ? day.products : [];
    const activeCodes = new Set(activeProducts.map((product) => product.product_code));
    const availableCodes = new Set(productTypes.map((product) => product.product_code));
    const unavailableCodes = Array.from(activeCodes).filter((code) => !availableCodes.has(code));
    const pickerProducts = productTypes.concat(
      unavailableCodes.map((code) => ({
        product_code: code,
        display_name: `${code} (not enabled in Customer Master)`,
        unavailable: true
      }))
    );

    return `
      <div class="customers-studio-day-body">
        <label class="customers-studio-field customers-studio-field-wide">
          <span>Default route</span>
          <select data-day-field="default_route_id">
            <option value="">No default route</option>
            ${routes.map((route) => `
              <option value="${escapeHtml(route.route_id)}" ${String(day.default_route_id || "") === String(route.route_id) ? "selected" : ""}>
                ${escapeHtml(route.display_name || route.route_code)} · ${escapeHtml(route.route_code)}
              </option>
            `).join("")}
          </select>
        </label>

        <div class="customers-studio-product-picker">
          <span>Products on ${escapeHtml(dayDefinition.name)}</span>
          <div>
            ${pickerProducts.map((product) => `
              <label class="customers-studio-check-chip${product.unavailable ? " is-unavailable" : ""}" title="${product.unavailable ? "Remove this product from the schedule or enable the service again in Customer Master." : ""}">
                <input
                  type="checkbox"
                  data-product-toggle="${escapeHtml(product.product_code)}"
                  ${activeCodes.has(product.product_code) ? "checked" : ""}
                >
                <span>${escapeHtml(product.display_name || product.product_code)}</span>
              </label>
            `).join("")}
          </div>
        </div>

        ${unavailableCodes.length
          ? `<div class="customers-studio-service-warning"><strong>Customer Master service changed.</strong> Remove ${escapeHtml(unavailableCodes.join(", "))} from this day, or enable the service again before publishing.</div>`
          : ""}

        ${activeProducts.map((product) => renderDraftProduct(day, product)).join("")}

        ${renderDraftTrolleySection(day)}

        <div class="customers-studio-day-fields customers-studio-day-edit-fields">
          <div class="customers-studio-managed-order">
            <span>Delivery day</span>
            <strong>${escapeHtml(weekdayLabel(nextDistributionWeekday(dayDefinition.number)))}</strong>
            <small>Calculated automatically as the next day after production, skipping Sunday.</small>
          </div>
          ${dayInputField("Delivery order", "delivery_order", day.delivery_order, "number", "1")}
          ${dayInputField("Window start", "delivery_window_start", day.delivery_window_start, "time")}
          ${dayInputField("Window end", "delivery_window_end", day.delivery_window_end, "time")}
          ${dayTextareaField("Day alert", "day_alert", day.day_alert)}
          ${dayTextareaField("Distribution instructions", "distribution_instructions", day.distribution_instructions)}
        </div>
      </div>
    `;
  }

  function productionOrderManagedField(value) {
    const orderText = plannerOrderText(value);
    const missing = orderText === "!";

    return `
      <div class="customers-studio-managed-order${missing ? " is-pending" : ""}">
        <span>Production order</span>
        <strong>${missing ? "Auto" : escapeHtml(orderText)}</strong>
        <small>${missing ? "Assigned automatically when this schedule is saved." : "Move the customer in the weekly planner to change this number."}</small>
      </div>
    `;
  }

  function renderDraftProduct(day, product) {
    const reference = productReferenceByCode(product.product_code) || {};
    const variants = Array.isArray(reference.variants) ? reference.variants : [];
    const selectedVariants = new Set(Array.isArray(product.variant_codes) ? product.variant_codes : []);
    const unavailable = !reference.product_code;

    return `
      <section class="customers-studio-product customers-studio-edit-product${unavailable ? " is-unavailable" : ""}" data-product-code="${escapeHtml(product.product_code)}">
        <div class="customers-studio-product-heading">
          <strong>${escapeHtml(reference.display_name || product.product_code)}</strong>
          <span>${escapeHtml(product.product_code)}</span>
        </div>
        ${unavailable ? '<div class="customers-studio-product-unavailable">This product is no longer enabled in Customer Master. Untick it above to remove it from this day.</div>' : ""}
        <div class="customers-studio-product-edit-grid">
          ${productionOrderManagedField(product.production_order)}
          ${reference.uses_kg ? productInputField("Expected KG", "expected_kg", product.expected_kg, "number", "0.01") : ""}
          ${reference.uses_units ? productInputField("Expected units", "expected_units", product.expected_units, "number", "1") : ""}
          ${productTextareaField("Production instructions", "production_instructions", product.production_instructions)}
          ${
            variants.length
              ? `
                <div class="customers-studio-variant-field">
                  <span>Product variants</span>
                  <div>
                    ${variants.map((variant) => `
                      <label class="customers-studio-check-chip">
                        <input
                          type="checkbox"
                          data-product-variant="${escapeHtml(variant.variant_code)}"
                          ${selectedVariants.has(variant.variant_code) ? "checked" : ""}
                        >
                        <span>${escapeHtml(variant.display_name || variant.variant_code)}</span>
                      </label>
                    `).join("")}
                  </div>
                </div>
              `
              : ""
          }
        </div>
      </section>
    `;
  }

  function renderDraftTrolleySection(day) {
    const requirements = Array.isArray(day.trolley_requirements) ? day.trolley_requirements : [];

    return `
      <section class="customers-studio-trolley-section">
        <div class="customers-studio-trolley-heading">
          <div>
            <strong>Trolley requirements</strong>
            <span>Shared trolleys may serve more than one scheduled product.</span>
          </div>
          <button class="customers-small-button" type="button" data-studio-add-trolley>Add trolley</button>
        </div>
        ${
          requirements.length
            ? requirements.map((requirement, index) => renderDraftTrolleyRequirement(day, requirement, index)).join("")
            : '<p class="customers-studio-no-trolley">No trolley requirement for this day.</p>'
        }
      </section>
    `;
  }

  function renderDraftTrolleyRequirement(day, requirement, index) {
    const trolleyTypes = Array.isArray(state.studio.management?.reference_data?.trolley_types)
      ? state.studio.management.reference_data.trolley_types
      : [];
    const products = Array.isArray(day.products) ? day.products : [];
    const servedCodes = new Set(Array.isArray(requirement.serves_product_codes)
      ? requirement.serves_product_codes
      : []);

    return `
      <div class="customers-studio-trolley-row" data-trolley-index="${index}">
        <label class="customers-studio-field">
          <span>Trolley type *</span>
          <select data-trolley-field="trolley_type_code">
            ${trolleyTypes.map((type) => `
              <option value="${escapeHtml(type.trolley_type_code)}" ${type.trolley_type_code === requirement.trolley_type_code ? "selected" : ""}>
                ${escapeHtml(type.display_code || type.trolley_type_name || type.trolley_type_code)}
              </option>
            `).join("")}
          </select>
        </label>
        <label class="customers-studio-field">
          <span>Owner product *</span>
          <select data-trolley-field="owner_product_code">
            ${products.map((product) => `
              <option value="${escapeHtml(product.product_code)}" ${product.product_code === requirement.owner_product_code ? "selected" : ""}>
                ${escapeHtml(product.product_code)}
              </option>
            `).join("")}
          </select>
        </label>
        <label class="customers-studio-field">
          <span>Quantity *</span>
          <input type="number" min="1" step="1" value="${escapeHtml(requirement.quantity ?? 1)}" data-trolley-field="quantity">
        </label>
        <label class="customers-studio-empty-toggle">
          <input type="checkbox" data-trolley-field="empty_trolley" ${requirement.empty_trolley ? "checked" : ""}>
          <span>Empty trolley</span>
        </label>
        <div class="customers-studio-serves-field">
          <span>Serves products *</span>
          <div>
            ${products.map((product) => `
              <label class="customers-studio-check-chip">
                <input
                  type="checkbox"
                  data-trolley-serves="${escapeHtml(product.product_code)}"
                  ${servedCodes.has(product.product_code) ? "checked" : ""}
                >
                <span>${escapeHtml(product.product_code)}</span>
              </label>
            `).join("")}
          </div>
        </div>
        <label class="customers-studio-field customers-studio-trolley-notes">
          <span>Notes</span>
          <input type="text" value="${escapeHtml(requirement.notes || "")}" data-trolley-field="notes">
        </label>
        <button class="customers-icon-danger-button" type="button" data-studio-remove-trolley title="Remove trolley requirement">×</button>
      </div>
    `;
  }

  function renderManagementPublishedDayCard(dayDefinition, day = null) {
    const isActive = Boolean(day);
    const products = Array.isArray(day?.products) ? day.products : [];
    const requirements = Array.isArray(day?.trolley_requirements) ? day.trolley_requirements : [];
    const routeColor = normalizeRouteColor(day?.default_route?.route_color);
    const routeLabel = day?.default_route?.display_name || day?.default_route?.route_code || "No default route";

    return `
      <article class="customers-studio-day-card${isActive ? "" : " is-off"}" style="${routeCssVariables(routeColor)}">
        <header class="customers-studio-day-header ${dayDefinition.className}">
          <label class="customers-studio-day-toggle">
            <input type="checkbox" ${isActive ? "checked" : ""} disabled>
            <span>${escapeHtml(dayDefinition.name.slice(0, 3))}</span>
          </label>
          <span class="customers-studio-day-status">${isActive ? "ON LIST" : "OFF"}</span>
        </header>
        ${
          isActive
            ? `
              <div class="customers-studio-day-body">
                <div class="customers-studio-route-row">
                  ${routeDotHtml(routeColor, routeLabel)}
                  <div>
                    <strong>${escapeHtml(routeLabel)}</strong>
                    <span>${escapeHtml(routeColor || "No route colour")}</span>
                  </div>
                </div>
                ${products.map(renderManagementPublishedProduct).join("")}
                ${requirements.length ? readonlyField("Trolleys", trolleyRequirementSummary(requirements), { wide: true, multiline: true }) : ""}
                <div class="customers-studio-day-fields">
                  ${readonlyField("Delivery day", day.delivery_day || "Not set")}
                  ${readonlyField("Delivery order", day.delivery_order)}
                  ${readonlyField("Day alert", day.day_alert, { wide: true, multiline: true })}
                </div>
              </div>
            `
            : `
              <div class="customers-studio-day-off-body">
                <span>Not scheduled</span>
                <small>Create a draft to add this day.</small>
              </div>
            `
        }
      </article>
    `;
  }

  function renderManagementPublishedProduct(product) {
    const quantityParts = [];
    const variants = Array.isArray(product.variant_codes) ? product.variant_codes : [];

    if (product.expected_kg !== null && product.expected_kg !== undefined) {
      quantityParts.push(`${formatNumber(product.expected_kg)} kg`);
    }

    if (product.expected_units !== null && product.expected_units !== undefined) {
      quantityParts.push(`${formatNumber(product.expected_units)} units`);
    }

    return `
      <section class="customers-studio-product">
        <div class="customers-studio-product-heading">
          <strong>${escapeHtml(product.display_name || product.product_code)}</strong>
          <span>Order ${escapeHtml(product.production_order ?? "—")}</span>
        </div>
        <div class="customers-studio-product-fields">
          ${readonlyField("Quantity plan", quantityParts.join(" · ") || "Not set")}
          ${variants.length ? readonlyField("Products", variants.join(", "), { wide: true }) : ""}
          ${readonlyField("Instructions", product.production_instructions, { wide: true, multiline: true })}
        </div>
      </section>
    `;
  }

  function trolleyRequirementSummary(requirements) {
    return requirements.map((requirement) => {
      const served = Array.isArray(requirement.serves_product_codes)
        ? requirement.serves_product_codes.join(" + ")
        : requirement.owner_product_code;
      return `${requirement.quantity} × ${requirement.display_code || requirement.trolley_type_code} · ${served}${requirement.empty_trolley ? " · Empty" : ""}`;
    }).join("\n");
  }

  function daySelectField(label, fieldName, value) {
    return `
      <label class="customers-studio-field">
        <span>${escapeHtml(label)}</span>
        <select data-day-field="${escapeHtml(fieldName)}">
          <option value="">Not set</option>
          ${DAYS.map((day) => `
            <option value="${day.number}" ${Number(value) === day.number ? "selected" : ""}>${escapeHtml(day.name)}</option>
          `).join("")}
        </select>
      </label>
    `;
  }

  function dayInputField(label, fieldName, value, type = "text", step = "") {
    return `
      <label class="customers-studio-field">
        <span>${escapeHtml(label)}</span>
        <input type="${escapeHtml(type)}" value="${escapeHtml(value ?? "")}" ${step ? `min="${step === "0.01" ? "0" : "1"}" step="${escapeHtml(step)}"` : ""} data-day-field="${escapeHtml(fieldName)}">
      </label>
    `;
  }

  function dayTextareaField(label, fieldName, value) {
    return `
      <label class="customers-studio-field customers-studio-field-wide">
        <span>${escapeHtml(label)}</span>
        <textarea rows="2" data-day-field="${escapeHtml(fieldName)}">${escapeHtml(value || "")}</textarea>
      </label>
    `;
  }

  function productInputField(label, fieldName, value, type = "text", step = "") {
    return `
      <label class="customers-studio-field">
        <span>${escapeHtml(label)}</span>
        <input type="${escapeHtml(type)}" value="${escapeHtml(value ?? "")}" ${step ? `min="0" step="${escapeHtml(step)}"` : ""} data-product-field="${escapeHtml(fieldName)}">
      </label>
    `;
  }

  function productTextareaField(label, fieldName, value) {
    return `
      <label class="customers-studio-field customers-studio-product-instructions">
        <span>${escapeHtml(label)}</span>
        <textarea rows="2" data-product-field="${escapeHtml(fieldName)}">${escapeHtml(value || "")}</textarea>
      </label>
    `;
  }

  function productReferenceByCode(productCode) {
    const products = Array.isArray(state.studio.management?.reference_data?.product_types)
      ? state.studio.management.reference_data.product_types
      : [];
    return products.find((product) => product.product_code === productCode) || null;
  }

  function routeReferenceById(routeId) {
    const routes = Array.isArray(state.studio.management?.reference_data?.routes)
      ? state.studio.management.reference_data.routes
      : [];
    return routes.find((route) => String(route.route_id) === String(routeId || "")) || null;
  }

  function dayDocumentByElement(element) {
    const card = element.closest("[data-studio-weekday]");
    const weekday = Number(card?.dataset.studioWeekday);
    return state.studio.draftDocument?.days?.find(
      (day) => Number(day.production_weekday) === weekday
    ) || null;
  }

  function productDocumentByElement(element) {
    const day = dayDocumentByElement(element);
    const productCode = element.closest("[data-product-code]")?.dataset.productCode;
    return day?.products?.find((product) => product.product_code === productCode) || null;
  }

  function trolleyDocumentByElement(element) {
    const day = dayDocumentByElement(element);
    const row = element.closest("[data-trolley-index]");
    const index = Number(row?.dataset.trolleyIndex);
    return { day, requirement: day?.trolley_requirements?.[index], index };
  }

  function markStudioDirty() {
    if (!state.studio.dirty) {
      state.studio.dirty = true;
      state.studio.comparison = null;
      updateStudioActionButtons();
    }
  }

  function updateStudioActionButtons() {
    const saveButton = scheduleBody.querySelector('[data-studio-action="save-draft"]');
    const status = scheduleBody.querySelector("[data-studio-edit-status]");
    const published = state.studio.management?.published_schedule || null;

    if (saveButton) {
      saveButton.disabled = false;
      saveButton.textContent = state.studio.dirty ? "Save Changes" : "Review & Update";
    }

    if (status) {
      const base = published
        ? `Based on Published Revision ${published.version_number}.`
        : "This is the first schedule for this customer.";
      status.textContent = `${base} ${
        state.studio.dirty
          ? "Unsaved changes are waiting."
          : "Saved changes are waiting for final confirmation."
      }`;
    }
  }

  function rerenderScheduleManagement(preserveScroll = true) {
    const scrollTop = preserveScroll ? scheduleBody.scrollTop : 0;
    renderScheduleManagementState();
    requestAnimationFrame(() => {
      scheduleBody.scrollTop = scrollTop;
    });
  }

  function bindScheduleManagementEditor() {
    scheduleBody.onclick = (event) => {
      const viewButton = event.target.closest("[data-studio-view]");

      if (viewButton) {
        const requestedView = viewButton.dataset.studioView;

        if (requestedView === state.studio.view) {
          return;
        }

        if (requestedView === "history") {
          if (state.studio.dirty && !window.confirm("Open Version History? Unsaved schedule changes will remain in this screen, but should be saved before you close Customer Studio.")) {
            return;
          }

          loadScheduleHistory().catch((error) => {
            console.error("Schedule history load failed:", error);
            showStudioAlert(errorMessage(error));
          });
        } else {
          returnToCurrentSchedule();
        }
        return;
      }

      const historyVersionButton = event.target.closest("[data-history-version-id]");

      if (historyVersionButton) {
        loadScheduleHistory(historyVersionButton.dataset.historyVersionId).catch((error) => {
          console.error("Schedule history version load failed:", error);
          showStudioAlert(errorMessage(error));
        });
        return;
      }

      const historyRestoreButton = event.target.closest("[data-history-restore]");

      if (historyRestoreButton) {
        openRestoreHistoryDialog();
        return;
      }

      const actionButton = event.target.closest("[data-studio-action]");

      if (actionButton) {
        actionButton.disabled = true;
        handleStudioAction(actionButton.dataset.studioAction).finally(() => {
          if (actionButton.isConnected) {
            actionButton.disabled = false;
          }
        });
        return;
      }

      const addTrolleyButton = event.target.closest("[data-studio-add-trolley]");

      if (addTrolleyButton) {
        addDraftTrolleyRequirement(addTrolleyButton);
        return;
      }

      const removeTrolleyButton = event.target.closest("[data-studio-remove-trolley]");

      if (removeTrolleyButton) {
        removeDraftTrolleyRequirement(removeTrolleyButton);
        return;
      }

      const closeComparisonButton = event.target.closest("[data-studio-close-comparison]");

      if (closeComparisonButton) {
        state.studio.comparison = null;
        rerenderScheduleManagement();
      }
    };

    scheduleBody.oninput = (event) => {
      updateDraftControl(event.target);
    };

    scheduleBody.onchange = (event) => {
      const target = event.target;

      if (target.matches("[data-studio-day-toggle]")) {
        toggleDraftDay(target);
        return;
      }

      if (target.matches("[data-product-toggle]")) {
        toggleDraftProduct(target);
        return;
      }

      if (target.matches("[data-studio-field], [data-day-field], [data-product-field], [data-product-variant], [data-trolley-field], [data-trolley-serves]")) {
        updateDraftControl(target);
      }

      if (target.matches("[data-day-field=\"default_route_id\"]")) {
        rerenderScheduleManagement();
      }
    };
  }

  function updateDraftControl(target) {
    if (!state.studio.draftDocument || !target) {
      return;
    }

    if (target.matches("[data-studio-field]")) {
      state.studio.draftDocument[target.dataset.studioField] = target.value;
      markStudioDirty();
      return;
    }

    if (target.matches("[data-day-field]")) {
      const day = dayDocumentByElement(target);

      if (day) {
        day[target.dataset.dayField] = target.value;
        markStudioDirty();
      }
      return;
    }

    if (target.matches("[data-product-field]")) {
      const product = productDocumentByElement(target);

      if (product) {
        product[target.dataset.productField] = target.value;
        markStudioDirty();
      }
      return;
    }

    if (target.matches("[data-product-variant]")) {
      const product = productDocumentByElement(target);
      const code = target.dataset.productVariant;

      if (product) {
        const variants = new Set(Array.isArray(product.variant_codes) ? product.variant_codes : []);
        target.checked ? variants.add(code) : variants.delete(code);
        product.variant_codes = Array.from(variants);
        markStudioDirty();
      }
      return;
    }

    if (target.matches("[data-trolley-field]")) {
      const { requirement } = trolleyDocumentByElement(target);

      if (requirement) {
        const field = target.dataset.trolleyField;
        requirement[field] = field === "empty_trolley" ? target.checked : target.value;

        if (field === "owner_product_code") {
          const served = new Set(Array.isArray(requirement.serves_product_codes)
            ? requirement.serves_product_codes
            : []);
          served.add(target.value);
          requirement.serves_product_codes = Array.from(served);
          markStudioDirty();
          rerenderScheduleManagement();
          return;
        }

        markStudioDirty();
      }
      return;
    }

    if (target.matches("[data-trolley-serves]")) {
      const { requirement } = trolleyDocumentByElement(target);
      const code = target.dataset.trolleyServes;

      if (requirement) {
        const served = new Set(Array.isArray(requirement.serves_product_codes)
          ? requirement.serves_product_codes
          : []);
        target.checked ? served.add(code) : served.delete(code);
        requirement.serves_product_codes = Array.from(served);
        markStudioDirty();
      }
    }
  }

  function defaultProductCodeForNewDay() {
    const products = Array.isArray(state.studio.management?.reference_data?.product_types)
      ? state.studio.management.reference_data.product_types
      : [];
    const preferredCode = state.schedule.service === "mop" ? "MOP" : "CLOTHES";
    return products.find((product) => product.product_code === preferredCode)?.product_code
      || products[0]?.product_code
      || "";
  }

  function newDraftProduct(productCode) {
    return {
      product_code: productCode,
      production_order: "",
      expected_kg: "",
      expected_units: "",
      production_instructions: "",
      variant_codes: []
    };
  }

  function toggleDraftDay(target) {
    const card = target.closest("[data-studio-weekday]");
    const weekday = Number(card?.dataset.studioWeekday);
    const documentValue = state.studio.draftDocument;

    if (!documentValue || !weekday) {
      return;
    }

    const index = documentValue.days.findIndex(
      (day) => Number(day.production_weekday) === weekday
    );

    if (target.checked && index < 0) {
      const defaultProductCode = defaultProductCodeForNewDay();
      documentValue.days.push({
        production_weekday: weekday,
        delivery_weekday: nextDistributionWeekday(weekday),
        default_route_id: "",
        delivery_window_start: "",
        delivery_window_end: "",
        delivery_order: "",
        day_alert: "",
        distribution_instructions: "",
        products: defaultProductCode ? [newDraftProduct(defaultProductCode)] : [],
        trolley_requirements: []
      });
      documentValue.days.sort((left, right) => left.production_weekday - right.production_weekday);
    } else if (!target.checked && index >= 0) {
      documentValue.days.splice(index, 1);
    }

    markStudioDirty();
    rerenderScheduleManagement();
  }

  function toggleDraftProduct(target) {
    const day = dayDocumentByElement(target);
    const productCode = target.dataset.productToggle;

    if (!day || !productCode) {
      return;
    }

    const index = day.products.findIndex((product) => product.product_code === productCode);

    if (target.checked && index < 0) {
      day.products.push(newDraftProduct(productCode));
    } else if (!target.checked && index >= 0) {
      day.products.splice(index, 1);
      day.trolley_requirements = day.trolley_requirements
        .filter((requirement) => requirement.owner_product_code !== productCode)
        .map((requirement) => ({
          ...requirement,
          serves_product_codes: requirement.serves_product_codes.filter((code) => code !== productCode)
        }));
    }

    markStudioDirty();
    rerenderScheduleManagement();
  }

  function addDraftTrolleyRequirement(button) {
    const day = dayDocumentByElement(button);
    const trolleyTypes = Array.isArray(state.studio.management?.reference_data?.trolley_types)
      ? state.studio.management.reference_data.trolley_types
      : [];
    const owner = day?.products?.[0]?.product_code || "";
    const trolleyType = trolleyTypes[0]?.trolley_type_code || "";

    if (!day || !owner || !trolleyType) {
      showStudioAlert("Select at least one product and ensure trolley reference data is available.");
      return;
    }

    day.trolley_requirements.push({
      trolley_type_code: trolleyType,
      owner_product_code: owner,
      quantity: 1,
      empty_trolley: false,
      notes: "",
      serves_product_codes: [owner]
    });

    markStudioDirty();
    rerenderScheduleManagement();
  }

  function removeDraftTrolleyRequirement(button) {
    const { day, index } = trolleyDocumentByElement(button);

    if (!day || index < 0) {
      return;
    }

    day.trolley_requirements.splice(index, 1);
    markStudioDirty();
    rerenderScheduleManagement();
  }

  function validateDraftDocument(documentValue) {
    const errors = [];
    const businessDate = state.studio.management?.business_date || state.capabilities?.business_date || "";
    const days = Array.isArray(documentValue?.days) ? documentValue.days : [];

    if (!documentValue?.effective_from) {
      errors.push("Effective from is required.");
    } else if (businessDate && documentValue.effective_from < businessDate) {
      errors.push(`Effective from cannot be before ${formatDate(businessDate)}.`);
    }

    if (documentValue?.effective_until && documentValue.effective_until < documentValue.effective_from) {
      errors.push("Effective until cannot be before Effective from.");
    }

    if (days.length === 0) {
      errors.push("Turn on at least one production day.");
    }

    days.forEach((day) => {
      const dayName = weekdayLabel(day.production_weekday);
      const products = Array.isArray(day.products) ? day.products : [];

      if (products.length === 0) {
        errors.push(`${dayName} must contain at least one product.`);
      }

      if (day.delivery_order !== "" && (!Number.isInteger(Number(day.delivery_order)) || Number(day.delivery_order) <= 0)) {
        errors.push(`${dayName} delivery order must be greater than zero.`);
      }

      if (day.delivery_window_start && day.delivery_window_end && day.delivery_window_end <= day.delivery_window_start) {
        errors.push(`${dayName} delivery window must end after it starts.`);
      }

      products.forEach((product) => {
        if (product.production_order !== "" && (!Number.isInteger(Number(product.production_order)) || Number(product.production_order) <= 0)) {
          errors.push(`${dayName} ${product.product_code} production order must be greater than zero.`);
        }

        if (product.expected_kg !== "" && Number(product.expected_kg) < 0) {
          errors.push(`${dayName} ${product.product_code} expected KG cannot be negative.`);
        }

        if (product.expected_units !== "" && (!Number.isInteger(Number(product.expected_units)) || Number(product.expected_units) < 0)) {
          errors.push(`${dayName} ${product.product_code} expected units must be a whole non-negative number.`);
        }
      });

      (Array.isArray(day.trolley_requirements) ? day.trolley_requirements : []).forEach((requirement, index) => {
        const label = `${dayName} trolley ${index + 1}`;

        if (!requirement.trolley_type_code) {
          errors.push(`${label} needs a trolley type.`);
        }

        if (!requirement.owner_product_code) {
          errors.push(`${label} needs an owner product.`);
        }

        if (!Number.isInteger(Number(requirement.quantity)) || Number(requirement.quantity) <= 0) {
          errors.push(`${label} quantity must be greater than zero.`);
        }

        const served = Array.isArray(requirement.serves_product_codes)
          ? requirement.serves_product_codes
          : [];

        if (served.length === 0) {
          errors.push(`${label} must serve at least one product.`);
        } else if (!served.includes(requirement.owner_product_code)) {
          errors.push(`${label} owner product must also be selected under Serves products.`);
        }
      });
    });

    return errors;
  }

  function showStudioAlert(message, type = "error") {
    const alert = document.getElementById("customersStudioAlert");

    if (!alert) {
      showToast(message);
      return;
    }

    alert.textContent = message;
    alert.classList.remove("hidden", "success");

    if (type === "success") {
      alert.classList.add("success");
    }

    alert.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  async function handleStudioAction(action) {
    try {
      if (action === "create-draft") {
        await beginScheduleEdit();
      } else if (action === "save-draft") {
        openSaveChangesDialog();
      } else if (action === "cancel-draft") {
        await discardScheduleChanges();
      } else if (action === "reload-draft") {
        await reloadScheduleChanges();
      }
    } catch (error) {
      console.error("Customer Studio action failed:", error);
      showStudioAlert(errorMessage(error));
    }
  }

  async function beginScheduleEdit() {
    const management = state.studio.management;
    const published = management?.selected_schedule?.status === "PUBLISHED"
      ? management.selected_schedule
      : management?.published_schedule;
    const businessDate = management?.business_date || state.capabilities?.business_date || "";
    const requestedDate = effectiveDateInput.value || businessDate;
    const effectiveFrom = requestedDate >= businessDate ? requestedDate : businessDate;

    showStudioAlert("Opening the protected schedule editor...", "success");

    const result = await rpc("create_customer_schedule_management_draft", {
      p_customer_id: state.studio.customerId,
      p_effective_from: effectiveFrom,
      p_based_on_version_id: published?.schedule_version_id || null,
      p_change_reason: "Schedule editing started in Customer Studio.",
      p_source_application: "CUSTOMER_STUDIO"
    });

    await loadScheduleManagementState(
      state.studio.customerId,
      result?.schedule_version_id || result?.draft?.schedule_version_id || null
    );
    renderScheduleManagementState();
    showToast("Schedule editing is ready. Published data remains protected.");
  }

  function openSaveChangesDialog() {
    const errors = validateDraftDocument(state.studio.draftDocument);

    if (errors.length) {
      showStudioAlert(errors[0] + (errors.length > 1 ? ` ${errors.length - 1} more issue(s) must be corrected.` : ""));
      return;
    }

    openScheduleActionDialog({
      title: state.studio.dirty ? "Save Schedule Changes" : "Review Schedule Changes",
      description: state.studio.dirty
        ? "Enter a short reason. The changes will be saved and shown immediately for final confirmation."
        : "Enter a short reason to review the saved changes and confirm the live update.",
      confirmLabel: state.studio.dirty ? "Save and Review" : "Review Changes",
      async onConfirm({ reason }) {
        let draft = state.studio.management?.draft_schedule;

        if (state.studio.dirty) {
          const saved = await rpc("save_customer_schedule_draft_with_auto_orders", {
            p_schedule_version_id: draft.schedule_version_id,
            p_expected_row_version: draft.row_version,
            p_draft: draftDocumentForRpc(state.studio.draftDocument),
            p_change_reason: reason,
            p_source_application: "CUSTOMER_STUDIO"
          });

          state.studio.management.draft_schedule = saved;
          state.studio.management.selected_schedule = saved;
          state.studio.draftDocument = draftDocumentFromSnapshot(saved);
          state.studio.dirty = false;
          draft = saved;
        }

        const comparison = await rpc("compare_customer_schedule_draft", {
          p_schedule_version_id: draft.schedule_version_id
        });
        state.studio.comparison = comparison;
        renderScheduleManagementState();

        if (!comparison?.has_changes) {
          await rpc("cancel_customer_schedule_draft", {
            p_schedule_version_id: draft.schedule_version_id,
            p_expected_row_version: draft.row_version,
            p_reason: "No schedule changes were detected.",
            p_source_application: "CUSTOMER_STUDIO"
          });
          await loadScheduleManagementState(state.studio.customerId);
          renderScheduleManagementState();
          setTimeout(() => showToast("No changes were detected. The live schedule was not updated."), 0);
          return;
        }

        setTimeout(() => openPublishReviewDialog(comparison, reason), 0);
      }
    });
  }

  function openPublishReviewDialog(comparison, reason) {
    openScheduleActionDialog({
      title: "Confirm Schedule Update",
      description: "Review the saved changes below. Confirming updates the live planner and keeps the previous revision in history.",
      confirmLabel: "Confirm Update",
      cancelLabel: "Continue Editing",
      showReason: false,
      reason,
      reviewHtml: renderPublishReviewSummary(comparison),
      async onConfirm() {
        const draft = state.studio.management?.draft_schedule;
        const result = await rpc("publish_customer_schedule_draft_with_order_normalization", {
          p_schedule_version_id: draft.schedule_version_id,
          p_expected_row_version: draft.row_version,
          p_change_reason: reason,
          p_source_application: "CUSTOMER_STUDIO"
        });
        const publishedId = result?.published_schedule?.schedule_version_id || null;

        await loadScheduleManagementState(state.studio.customerId, publishedId);
        renderScheduleManagementState();
        await loadMainView();
        showToast("Schedule updated successfully.");
      }
    });
  }

  function renderPublishReviewSummary(comparison) {
    return renderHistoryChangeSummary(comparison, {
      title: "Changes ready to update",
      subtitle: "Review the operational changes below. Full before-and-after data remains available under technical details."
    });
  }

  async function discardScheduleChanges() {
    const draft = state.studio.management?.draft_schedule;

    if (!draft) {
      return;
    }

    const confirmed = window.confirm(
      "Discard all schedule changes for this customer? The published schedule and history will remain unchanged."
    );

    if (!confirmed) {
      return;
    }

    await rpc("cancel_customer_schedule_draft", {
      p_schedule_version_id: draft.schedule_version_id,
      p_expected_row_version: draft.row_version,
      p_reason: "Schedule changes discarded in Customer Studio.",
      p_source_application: "CUSTOMER_STUDIO"
    });

    await loadScheduleManagementState(state.studio.customerId);
    renderScheduleManagementState();
    showToast("Schedule changes discarded. The published schedule was not changed.");
  }

  async function reloadScheduleChanges() {
    if (state.studio.dirty && !window.confirm("Discard unsaved changes and reload the last saved version?")) {
      return;
    }

    scheduleBody.innerHTML = loadingHtml("Reloading saved schedule changes...");
    await loadScheduleManagementState(
      state.studio.customerId,
      state.studio.management?.draft_schedule?.schedule_version_id || null
    );
    renderScheduleManagementState();
    showToast("Saved schedule changes reloaded.");
  }

  function renderScheduleComparison(comparison) {
    const changedWeekdays = Array.isArray(comparison?.changed_weekdays)
      ? comparison.changed_weekdays
      : [];
    const before = comparison?.summary?.before || {};
    const after = comparison?.summary?.after || {};

    return `
      <section id="customersStudioComparison" class="customers-studio-comparison">
        <div class="customers-studio-comparison-header">
          <div>
            <span class="customers-modal-code">Schedule change review</span>
            <h3>${comparison?.has_changes ? "Changes ready for review" : "No changes detected"}</h3>
            <p>The comparison uses normalized schedule content and ignores technical row IDs.</p>
          </div>
          <button class="customers-icon-button" type="button" data-studio-close-comparison aria-label="Close comparison">×</button>
        </div>

        <div class="customers-studio-comparison-summary">
          ${comparisonMetric("Days", before.days, after.days)}
          ${comparisonMetric("Products", before.products, after.products)}
          ${comparisonMetric("Trolley rows", before.trolley_requirements, after.trolley_requirements)}
          ${comparisonMetric("Trolley quantity", before.trolley_quantity, after.trolley_quantity)}
        </div>

        <div class="customers-studio-change-flags">
          ${comparison.effective_period_changed ? '<span>Effective period changed</span>' : ""}
          ${comparison.general_instructions_changed ? '<span>General instructions changed</span>' : ""}
          ${changedWeekdays.length ? changedWeekdays.map((day) => `<span>${escapeHtml(day.day_name)} · ${escapeHtml(day.change_type)}</span>`).join("") : '<span class="unchanged">No weekday changes</span>'}
        </div>

        ${
          changedWeekdays.length
            ? `<div class="customers-studio-comparison-days">${changedWeekdays.map((change) => renderComparisonDay(change, comparison)).join("")}</div>`
            : ""
        }
      </section>
    `;
  }

  function comparisonMetric(label, before, after) {
    return `
      <div>
        <span>${escapeHtml(label)}</span>
        <strong>${escapeHtml(before ?? 0)} → ${escapeHtml(after ?? 0)}</strong>
      </div>
    `;
  }

  function renderComparisonDay(change, comparison) {
    const beforeDay = (Array.isArray(comparison?.before?.days) ? comparison.before.days : [])
      .find((day) => Number(day.production_weekday) === Number(change.weekday));
    const afterDay = (Array.isArray(comparison?.after?.days) ? comparison.after.days : [])
      .find((day) => Number(day.production_weekday) === Number(change.weekday));

    return `
      <article class="customers-studio-comparison-day">
        <header>
          <strong>${escapeHtml(change.day_name)}</strong>
          <span>${escapeHtml(change.change_type)}</span>
        </header>
        <div>
          ${comparisonDaySide("Before", beforeDay)}
          ${comparisonDaySide("After", afterDay)}
        </div>
      </article>
    `;
  }

  function comparisonDaySide(label, day) {
    if (!day) {
      return `
        <section>
          <span>${escapeHtml(label)}</span>
          <p>Not scheduled</p>
        </section>
      `;
    }

    const route = routeReferenceById(day.default_route_id);
    const products = Array.isArray(day.products) ? day.products : [];
    const requirements = Array.isArray(day.trolley_requirements) ? day.trolley_requirements : [];

    return `
      <section>
        <span>${escapeHtml(label)}</span>
        <p><b>Products:</b> ${escapeHtml(products.map((product) => product.product_code).join(" + ") || "None")}</p>
        <p><b>Route:</b> ${escapeHtml(route?.display_name || route?.route_code || "Not set")}</p>
        <p><b>Delivery:</b> ${escapeHtml(weekdayLabel(day.delivery_weekday))}</p>
        <p><b>Trolleys:</b> ${escapeHtml(requirements.reduce((sum, item) => sum + (Number(item.quantity) || 0), 0))}</p>
      </section>
    `;
  }

  function openScheduleActionDialog(options) {
    const showReason = options.showReason !== false;
    const hasReview = Boolean(options.reviewHtml);

    state.studio.actionHandler = options.onConfirm;
    scheduleActionTitle.textContent = options.title || "Schedule action";
    scheduleActionDescription.textContent = options.description || "";
    scheduleActionReason.value = options.reason || "";
    scheduleActionEffectiveFrom.value = options.effectiveFrom || "";
    scheduleActionEffectiveFrom.min = state.studio.management?.business_date || state.capabilities?.business_date || "";
    scheduleActionEffectiveField.classList.toggle("hidden", !options.showEffectiveDate);
    scheduleActionReasonField.classList.toggle("hidden", !showReason);
    scheduleActionReview.innerHTML = options.reviewHtml || "";
    scheduleActionReview.classList.toggle("hidden", !hasReview);
    scheduleActionCard.classList.toggle("has-review", hasReview);
    scheduleActionModal.dataset.reasonRequired = showReason ? "true" : "false";
    scheduleActionAlert.classList.add("hidden");
    scheduleActionAlert.textContent = "";
    scheduleActionCancel.textContent = options.cancelLabel || "Cancel";
    scheduleActionConfirm.textContent = options.confirmLabel || "Confirm";
    scheduleActionConfirm.classList.toggle("customers-danger-button", Boolean(options.danger));
    scheduleActionConfirm.classList.toggle("customers-primary-button", !options.danger);
    scheduleActionConfirm.dataset.defaultLabel = options.confirmLabel || "Confirm";
    openModal(scheduleActionModal);
    requestAnimationFrame(() => {
      if (options.showEffectiveDate) {
        scheduleActionEffectiveFrom.focus();
      } else if (showReason) {
        scheduleActionReason.focus();
      } else {
        scheduleActionConfirm.focus();
      }
    });
  }

  function closeScheduleActionDialog() {
    state.studio.actionHandler = null;
    scheduleActionReview.replaceChildren();
    scheduleActionReview.classList.add("hidden");
    scheduleActionReasonField.classList.remove("hidden");
    scheduleActionCard.classList.remove("has-review");
    scheduleActionCancel.textContent = "Cancel";
    delete scheduleActionModal.dataset.reasonRequired;
    closeModal(scheduleActionModal);
  }

  async function confirmScheduleAction() {
    const reason = scheduleActionReason.value.trim();
    const effectiveFrom = scheduleActionEffectiveFrom.value;
    const reasonRequired = scheduleActionModal.dataset.reasonRequired !== "false";

    if (reasonRequired && !reason) {
      scheduleActionAlert.textContent = "A reason is required for the audit trail.";
      scheduleActionAlert.classList.remove("hidden");
      scheduleActionReason.focus();
      return;
    }

    if (!scheduleActionEffectiveField.classList.contains("hidden") && !effectiveFrom) {
      scheduleActionAlert.textContent = "Effective from is required.";
      scheduleActionAlert.classList.remove("hidden");
      scheduleActionEffectiveFrom.focus();
      return;
    }

    const handler = state.studio.actionHandler;

    if (typeof handler !== "function") {
      return;
    }

    const defaultLabel = scheduleActionConfirm.dataset.defaultLabel || "Confirm";
    scheduleActionConfirm.disabled = true;
    scheduleActionConfirm.textContent = "Working...";
    scheduleActionAlert.classList.add("hidden");

    try {
      await handler({ reason, effectiveFrom });
      closeScheduleActionDialog();
    } catch (error) {
      console.error("Schedule action failed:", error);
      scheduleActionAlert.textContent = errorMessage(error);
      scheduleActionAlert.classList.remove("hidden");
    } finally {
      scheduleActionConfirm.disabled = false;
      scheduleActionConfirm.textContent = defaultLabel;
    }
  }

  function requestCloseScheduleModal() {
    const hasSavedChanges = Boolean(state.studio.management?.draft_schedule);

    if (
      state.studio.dirty &&
      !window.confirm("Close Customer Studio? Unsaved schedule changes will be lost, and the published schedule will remain unchanged.")
    ) {
      return;
    }

    if (
      !state.studio.dirty &&
      hasSavedChanges &&
      !window.confirm("Close Customer Studio? Saved schedule changes are still waiting for final confirmation and have not updated the live planner.")
    ) {
      return;
    }

    closeModal(scheduleModal);
  }

  async function loadCustomerMaster(requestId) {
    mainPanel.innerHTML = loadingHtml("Loading Customer Master...");

    const payload = await rpc("get_customer_directory", {
      p_status: state.master.status,
      p_service_filter: state.master.service,
      p_search: state.master.search || null,
      p_effective_date: effectiveDateInput.value,
      p_limit: 500,
      p_offset: 0
    });

    if (requestId !== state.requestId) {
      return;
    }

    renderCustomerMaster(payload);
  }

  function renderCustomerMaster(payload) {
    const items = Array.isArray(payload?.items) ? payload.items : [];
    const canEdit = Boolean(state.capabilities?.can_edit_customers);
    const canDeactivate = Boolean(state.capabilities?.can_deactivate_customers);

    mainPanel.innerHTML = `
      <div class="customers-panel-title">
        <div>
          <h2>Customer Master</h2>
          <p>
            Add, edit, deactivate or reactivate the customer master record.
            Schedule changes are managed separately.
          </p>
        </div>
        <span class="customers-count-badge">
          ${escapeHtml(formatNumber(payload?.total_count, "0"))} customers
        </span>
      </div>

      <div class="customers-toolbar">
        <label class="customers-toolbar-group grow">
          <span class="customers-toolbar-label">Search</span>
          <input
            id="customerMasterSearch"
            class="customers-search"
            type="search"
            value="${escapeHtml(state.master.search)}"
            placeholder="Customer name, code or Eircode"
            autocomplete="off"
          >
        </label>

        <label class="customers-toolbar-group">
          <span class="customers-toolbar-label">Status</span>
          <select id="customerMasterStatus" class="customers-select">
            <option value="ACTIVE"${state.master.status === "ACTIVE" ? " selected" : ""}>Active</option>
            <option value="INACTIVE"${state.master.status === "INACTIVE" ? " selected" : ""}>Inactive</option>
            <option value="ALL"${state.master.status === "ALL" ? " selected" : ""}>All</option>
          </select>
        </label>

        <label class="customers-toolbar-group">
          <span class="customers-toolbar-label">Service</span>
          <select id="customerMasterService" class="customers-select">
            <option value="ALL"${state.master.service === "ALL" ? " selected" : ""}>All services</option>
            <option value="CLOTHES"${state.master.service === "CLOTHES" ? " selected" : ""}>Includes Clothes</option>
            <option value="MOP"${state.master.service === "MOP" ? " selected" : ""}>Includes MOP</option>
            <option value="CLOTHES_ONLY"${state.master.service === "CLOTHES_ONLY" ? " selected" : ""}>Clothes only</option>
            <option value="MOP_ONLY"${state.master.service === "MOP_ONLY" ? " selected" : ""}>MOP only</option>
            <option value="CLOTHES_AND_MOP"${state.master.service === "CLOTHES_AND_MOP" ? " selected" : ""}>Clothes + MOP</option>
          </select>
        </label>

        <button id="customerMasterRefresh" class="customers-secondary-button" type="button">
          Reload
        </button>

        ${
          canEdit
            ? `
              <button id="customerMasterAdd" class="customers-primary-button" type="button">
                + Add Customer
              </button>
            `
            : ""
        }
      </div>

      ${
        items.length === 0
          ? emptyHtml("No customers match these filters.")
          : `
            <div class="customers-master-scroll">
              <table class="customers-master-table">
                <thead>
                  <tr>
                    <th>Customer</th>
                    <th>Services</th>
                    <th>Schedule</th>
                    <th>Eircode</th>
                    <th>Alert</th>
                    <th>Status</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  ${items.map((item) => renderCustomerMasterRow(item, canEdit, canDeactivate)).join("")}
                </tbody>
              </table>
            </div>
          `
      }
    `;

    bindCustomerMasterControls();
  }

  function renderCustomerMasterRow(item, canEdit, canDeactivate) {
    const schedule = item.current_schedule;
    const scheduleHtml = schedule
      ? `<span class="customers-master-schedule-state is-ready">Revision ${escapeHtml(schedule.version_number)} · ${escapeHtml(schedule.schedule_day_count)} days</span>`
      : item.active
        ? '<span class="customers-master-schedule-state needs-setup">Schedule setup required</span>'
        : '<span class="customers-master-schedule-state is-inactive">No active schedule</span>';
    const scheduleTitle = schedule
      ? "Open schedule"
      : item.active
        ? "Set up schedule"
        : "View schedule history";

    let actions = `
      <button
        class="customers-action-icon${!schedule && item.active ? " setup" : ""}"
        type="button"
        data-master-schedule
        data-customer-id="${escapeHtml(item.customer_id)}"
        data-customer-code="${escapeHtml(item.customer_code)}"
        data-customer-name="${escapeHtml(item.customer_name)}"
        title="${escapeHtml(scheduleTitle)}"
      >
        ${!schedule && item.active ? "+" : "◫"}
      </button>
    `;

    if (item.active && canEdit) {
      actions += `
        <button
          class="customers-action-icon edit"
          type="button"
          data-master-edit="${escapeHtml(item.customer_id)}"
          title="Edit Customer Master"
        >
          ✎
        </button>
      `;
    }

    if (item.active && canDeactivate) {
      actions += `
        <button
          class="customers-action-icon deactivate"
          type="button"
          data-master-deactivate="${escapeHtml(item.customer_id)}"
          data-customer-name="${escapeHtml(item.customer_name)}"
          title="Deactivate customer"
        >
          ×
        </button>
      `;
    }

    if (!item.active && canDeactivate) {
      actions += `
        <button
          class="customers-action-icon reactivate"
          type="button"
          data-master-reactivate="${escapeHtml(item.customer_id)}"
          title="Reactivate customer"
        >
          ↻
        </button>
      `;
    }

    return `
      <tr class="customers-master-row">
        <td>
          <div class="customers-name-block">
            <strong>${escapeHtml(item.customer_name)}</strong>
            <small>${escapeHtml(item.customer_code)}</small>
          </div>
        </td>
        <td><div class="customers-badge-row">${serviceBadges(item.product_services)}</div></td>
        <td>${scheduleHtml}</td>
        <td>${escapeHtml(item.eircode || "—")}</td>
        <td>
          ${
            item.operational_alert
              ? `<span class="customers-alert-text">${escapeHtml(item.operational_alert)}</span>`
              : "—"
          }
        </td>
        <td>${statusBadge(Boolean(item.active))}</td>
        <td><div class="customers-actions">${actions}</div></td>
      </tr>
    `;
  }

  function bindCustomerMasterControls() {
    const searchInput = document.getElementById("customerMasterSearch");
    const statusSelect = document.getElementById("customerMasterStatus");
    const serviceSelect = document.getElementById("customerMasterService");
    const refreshButton = document.getElementById("customerMasterRefresh");
    const addButton = document.getElementById("customerMasterAdd");

    searchInput?.addEventListener("input", () => {
      state.master.search = searchInput.value.trim();

      clearTimeout(searchTimer);
      searchTimer = setTimeout(loadMainView, 320);
    });

    statusSelect?.addEventListener("change", () => {
      state.master.status = statusSelect.value;
      loadMainView();
    });

    serviceSelect?.addEventListener("change", () => {
      state.master.service = serviceSelect.value;
      loadMainView();
    });

    refreshButton?.addEventListener("click", loadMainView);
    addButton?.addEventListener("click", () => openCustomerForm("create"));

    mainPanel.querySelectorAll("[data-master-schedule]").forEach((button) => {
      button.addEventListener("click", () => {
        openScheduleDetails(
          button.dataset.customerId,
          button.dataset.customerCode,
          button.dataset.customerName
        );
      });
    });

    mainPanel.querySelectorAll("[data-master-edit]").forEach((button) => {
      button.addEventListener("click", () => {
        openCustomerForm("edit", button.dataset.masterEdit);
      });
    });

    mainPanel.querySelectorAll("[data-master-reactivate]").forEach((button) => {
      button.addEventListener("click", () => {
        openCustomerForm("reactivate", button.dataset.masterReactivate);
      });
    });

    mainPanel.querySelectorAll("[data-master-deactivate]").forEach((button) => {
      button.addEventListener("click", () => {
        openDeactivateModal(
          button.dataset.masterDeactivate,
          button.dataset.customerName
        );
      });
    });
  }

  async function loadDistribution(requestId) {
    mainPanel.innerHTML = loadingHtml("Loading Distribution schedule...");

    const payload = await rpc("get_distribution_weekly_planner", {
      p_effective_date: effectiveDateInput.value,
      p_delivery_weekday: state.distribution.weekday
        ? Number(state.distribution.weekday)
        : null,
      p_search: state.distribution.search || null
    });

    if (requestId !== state.requestId) {
      return;
    }

    state.distribution.items = Array.isArray(payload?.items) ? payload.items : [];
    state.distribution.payload = payload;
    renderDistributionContent();
  }

  function distributionRouteValue(item) {
    return item?.default_route_code || "__UNASSIGNED__";
  }

  function distributionRouteLabel(item) {
    return (
      item?.default_route_display_name ||
      item?.default_route_code ||
      "Unassigned route"
    );
  }

  function distributionGroupKey(item) {
    const dayNumber = Number(item?.delivery_weekday) || 0;
    const routeIdentity =
      item?.default_route_id || item?.default_route_code || "UNASSIGNED";

    return `${dayNumber}::${routeIdentity}`;
  }

  function distributionTimeLabel(item) {
    if (!item?.delivery_window_start && !item?.delivery_window_end) {
      return "—";
    }

    const start = String(item.delivery_window_start || "").slice(0, 5);
    const end = String(item.delivery_window_end || "").slice(0, 5);

    if (start && end) {
      return `${start}–${end}`;
    }

    return start || end || "—";
  }

  function sumDistributionField(items, fieldName) {
    return items.reduce((total, item) => {
      const value = Number(item?.[fieldName]);
      return Number.isFinite(value) ? total + value : total;
    }, 0);
  }

  function buildDistributionGroups(items) {
    const groups = new Map();

    items.forEach((item) => {
      const key = distributionGroupKey(item);

      if (!groups.has(key)) {
        groups.set(key, {
          key,
          deliveryWeekday: Number(item.delivery_weekday) || 0,
          deliveryDay: item.delivery_day || weekdayLabel(item.delivery_weekday),
          routeCode: item.default_route_code || "",
          routeName: distributionRouteLabel(item),
          routeColor: normalizeRouteColor(item.default_route_color),
          items: []
        });
      }

      groups.get(key).items.push(item);
    });

    return Array.from(groups.values())
      .map((group) => {
        group.items.sort((left, right) => {
          const leftOrder = Number(left.delivery_order);
          const rightOrder = Number(right.delivery_order);
          const safeLeft = Number.isFinite(leftOrder) ? leftOrder : 999999;
          const safeRight = Number.isFinite(rightOrder) ? rightOrder : 999999;

          return (
            safeLeft - safeRight ||
            String(left.customer_name || "").localeCompare(
              String(right.customer_name || ""),
              "en"
            )
          );
        });

        group.customerCount = new Set(
          group.items.map((item) => item.customer_id).filter(Boolean)
        ).size;
        group.kgTotal = sumDistributionField(
          group.items,
          "distribution_estimated_kg"
        );
        group.stopTotal = sumDistributionField(
          group.items,
          "distribution_stop_count"
        );
        group.trolleyTotal = sumDistributionField(
          group.items,
          "planned_trolley_total"
        );

        return group;
      })
      .sort((left, right) => {
        return (
          left.deliveryWeekday - right.deliveryWeekday ||
          String(left.routeCode || left.routeName).localeCompare(
            String(right.routeCode || right.routeName),
            "en",
            { numeric: true }
          )
        );
      });
  }

  function distributionRouteOptions(items) {
    const routeMap = new Map();

    items.forEach((item) => {
      const value = distributionRouteValue(item);

      if (!routeMap.has(value)) {
        routeMap.set(value, {
          value,
          code: item.default_route_code || "",
          label: distributionRouteLabel(item),
          color: normalizeRouteColor(item.default_route_color)
        });
      }
    });

    return Array.from(routeMap.values()).sort((left, right) => {
      if (left.value === "__UNASSIGNED__") {
        return 1;
      }

      if (right.value === "__UNASSIGNED__") {
        return -1;
      }

      return String(left.code || left.label).localeCompare(
        String(right.code || right.label),
        "en",
        { numeric: true }
      );
    });
  }

  function distributionMetricHtml(value, label) {
    return `
      <span class="customers-distribution-route-metric">
        <strong>${escapeHtml(formatNumber(value, "0"))}</strong>
        <small>${escapeHtml(label)}</small>
      </span>
    `;
  }

  function renderDistributionContent() {
    const sourceItems = Array.isArray(state.distribution.items)
      ? state.distribution.items
      : [];
    const routeOptions = distributionRouteOptions(sourceItems);

    if (
      state.distribution.route &&
      !routeOptions.some((route) => route.value === state.distribution.route)
    ) {
      state.distribution.route = "";
    }

    const filteredItems = state.distribution.route
      ? sourceItems.filter(
          (item) => distributionRouteValue(item) === state.distribution.route
        )
      : sourceItems;
    const groups = buildDistributionGroups(filteredItems);
    const totalKg = sumDistributionField(
      filteredItems,
      "distribution_estimated_kg"
    );
    const totalTrolleys = sumDistributionField(
      filteredItems,
      "planned_trolley_total"
    );

    mainPanel.innerHTML = `
      <div class="customers-panel-title">
        <div>
          <h2>Distribution Schedule</h2>
          <p>
            Delivery follows the published Customer Schedule automatically:
            the next day after production, skipping Sunday.
          </p>
        </div>
        <span class="customers-count-badge">
          ${escapeHtml(formatNumber(groups.length, "0"))} route/day groups
        </span>
      </div>

      <div class="customers-toolbar customers-distribution-toolbar">
        <label class="customers-toolbar-group grow">
          <span class="customers-toolbar-label">Search</span>
          <input
            id="distributionSearch"
            class="customers-search"
            type="search"
            value="${escapeHtml(state.distribution.search)}"
            placeholder="Customer or route"
          >
        </label>

        <label class="customers-toolbar-group">
          <span class="customers-toolbar-label">Delivery day</span>
          <select id="distributionWeekday" class="customers-select">
            <option value="">All days</option>
            ${DAYS.filter((day) => day.number !== 7).map(
              (day) => `
                <option value="${day.number}"${String(state.distribution.weekday) === String(day.number) ? " selected" : ""}>
                  ${day.name}
                </option>
              `
            ).join("")}
          </select>
        </label>

        <label class="customers-toolbar-group">
          <span class="customers-toolbar-label">Route</span>
          <select id="distributionRoute" class="customers-select">
            <option value="">All routes</option>
            ${routeOptions
              .map(
                (route) => `
                  <option value="${escapeHtml(route.value)}"${state.distribution.route === route.value ? " selected" : ""}>
                    ${escapeHtml(
                      route.code
                        ? `${route.code} — ${route.label}`
                        : route.label
                    )}
                  </option>
                `
              )
              .join("")}
          </select>
        </label>

        <div class="customers-toolbar-group customers-distribution-toolbar-actions">
          <span class="customers-toolbar-label">Routes</span>
          <div class="customers-distribution-action-row">
            <button id="distributionExpandAll" class="customers-secondary-button compact" type="button">
              Expand all
            </button>
            <button id="distributionCollapseAll" class="customers-secondary-button compact" type="button">
              Collapse all
            </button>
          </div>
        </div>

        <button id="distributionRefresh" class="customers-secondary-button" type="button">
          Reload
        </button>
      </div>

      <div class="customers-distribution-summary" aria-label="Distribution schedule summary">
        ${distributionMetricHtml(groups.length, "Route/day groups")}
        ${distributionMetricHtml(filteredItems.length, "Schedule rows")}
        ${distributionMetricHtml(totalKg, "Estimated KG")}
        ${distributionMetricHtml(totalTrolleys, "Planned trolleys")}
      </div>

      <div class="customers-distribution-notice">
        <strong>Automatic delivery rule.</strong>
        Monday production is delivered Tuesday; Friday production is delivered Saturday;
        Saturday production is delivered Monday. Sunday is skipped.
        Driver assignment will be handled later in the separate Distribution Roster.
      </div>

      ${
        groups.length === 0
          ? emptyHtml("No Distribution routes match these filters.")
          : `
            <div class="customers-distribution-route-list">
              ${groups.map(renderDistributionRouteCard).join("")}
            </div>
          `
      }
    `;

    bindDistributionControls(groups);
  }

  function renderDistributionRouteCard(group) {
    const expanded = state.distribution.expandedGroups.has(group.key);
    const routeCodeLabel = group.routeCode
      ? `Route ${group.routeCode}`
      : "No route assigned";
    const routeStyle = routeCssVariables(group.routeColor);

    return `
      <section
        class="customers-distribution-route-card${expanded ? " expanded" : " collapsed"}"
        style="${routeStyle}"
      >
        <button
          class="customers-distribution-route-head"
          type="button"
          data-distribution-toggle="${escapeHtml(group.key)}"
          aria-expanded="${expanded ? "true" : "false"}"
        >
          <span class="customers-distribution-chevron" aria-hidden="true">▼</span>
          <span class="customers-distribution-route-swatch" aria-hidden="true"></span>
          <span class="customers-distribution-route-title">
            <strong>${escapeHtml(group.routeName)}</strong>
            <small>${escapeHtml(routeCodeLabel)} · ${escapeHtml(group.deliveryDay || "Delivery day not set")}</small>
          </span>
          <span class="customers-distribution-route-metrics">
            ${distributionMetricHtml(group.customerCount, "Customers")}
            ${distributionMetricHtml(group.stopTotal, "Stop units")}
            ${distributionMetricHtml(group.kgTotal, "KG")}
            ${distributionMetricHtml(group.trolleyTotal, "Trolleys")}
          </span>
        </button>

        <div class="customers-distribution-route-body"${expanded ? "" : " hidden"}>
          <div class="customers-distribution-scroll">
            <table class="customers-distribution-table customers-distribution-route-table">
              <thead>
                <tr>
                  <th>#</th>
                  <th>Customer / delivery stop</th>
                  <th>Production</th>
                  <th>Delivery</th>
                  <th>Time</th>
                  <th>Eircode</th>
                  <th>Products</th>
                  <th>KG</th>
                  <th>Stops</th>
                  <th>Trolleys</th>
                  <th>Alerts / instructions</th>
                </tr>
              </thead>
              <tbody>
                ${group.items
                  .map((item, index) => renderDistributionStopRow(item, index))
                  .join("")}
              </tbody>
            </table>
          </div>
        </div>
      </section>
    `;
  }

  function renderDistributionStopRow(item, index) {
    const products = Array.isArray(item.scheduled_products)
      ? item.scheduled_products.join(" + ")
      : "";
    const alerts = [
      item.operational_alert,
      item.day_alert,
      item.distribution_instructions
    ].filter(Boolean);
    const order =
      item.delivery_order === null || item.delivery_order === undefined
        ? index + 1
        : item.delivery_order;

    return `
      <tr class="customers-distribution-row">
        <td class="customers-distribution-order">${escapeHtml(order)}</td>
        <td>
          <button
            class="customers-planner-customer customers-distribution-customer"
            type="button"
            data-open-schedule
            data-customer-id="${escapeHtml(item.customer_id)}"
            data-customer-code="${escapeHtml(item.customer_code)}"
            data-customer-name="${escapeHtml(item.customer_name)}"
          >
            <span class="customers-planner-customer-name">${escapeHtml(item.customer_name)}</span>
            <span class="customers-distribution-customer-code">${escapeHtml(item.customer_code || "")}</span>
          </button>
        </td>
        <td>${escapeHtml(item.production_day || "—")}</td>
        <td>${escapeHtml(item.delivery_day || weekdayLabel(item.delivery_weekday))}</td>
        <td>${escapeHtml(distributionTimeLabel(item))}</td>
        <td>${escapeHtml(item.eircode || "—")}</td>
        <td>${escapeHtml(products || "—")}</td>
        <td>${escapeHtml(formatNumber(item.distribution_estimated_kg))}</td>
        <td>${escapeHtml(formatNumber(item.distribution_stop_count))}</td>
        <td class="customers-distribution-trolley-cell">
          <strong>${escapeHtml(formatNumber(item.planned_trolley_total, "0"))}</strong>
          <span>${escapeHtml(item.trolley_summary || "No planned trolley")}</span>
        </td>
        <td>
          ${
            alerts.length
              ? `<div class="customers-distribution-alert-stack">${alerts
                  .map(
                    (alert) =>
                      `<span class="customers-distribution-alert">${escapeHtml(alert)}</span>`
                  )
                  .join("")}</div>`
              : '<span class="customers-muted">—</span>'
          }
        </td>
      </tr>
    `;
  }

  function bindDistributionControls(groups = []) {
    const searchInput = document.getElementById("distributionSearch");
    const weekdaySelect = document.getElementById("distributionWeekday");
    const routeSelect = document.getElementById("distributionRoute");
    const refreshButton = document.getElementById("distributionRefresh");
    const expandAllButton = document.getElementById("distributionExpandAll");
    const collapseAllButton = document.getElementById("distributionCollapseAll");

    searchInput?.addEventListener("input", () => {
      state.distribution.search = searchInput.value.trim();

      clearTimeout(searchTimer);
      searchTimer = setTimeout(loadMainView, 320);
    });

    weekdaySelect?.addEventListener("change", () => {
      state.distribution.weekday = weekdaySelect.value;
      loadMainView();
    });

    routeSelect?.addEventListener("change", () => {
      state.distribution.route = routeSelect.value;
      renderDistributionContent();
    });

    refreshButton?.addEventListener("click", loadMainView);

    expandAllButton?.addEventListener("click", () => {
      groups.forEach((group) => state.distribution.expandedGroups.add(group.key));
      renderDistributionContent();
    });

    collapseAllButton?.addEventListener("click", () => {
      groups.forEach((group) => state.distribution.expandedGroups.delete(group.key));
      renderDistributionContent();
    });

    mainPanel.querySelectorAll("[data-distribution-toggle]").forEach((button) => {
      button.addEventListener("click", () => {
        const key = button.dataset.distributionToggle;

        if (state.distribution.expandedGroups.has(key)) {
          state.distribution.expandedGroups.delete(key);
        } else {
          state.distribution.expandedGroups.add(key);
        }

        renderDistributionContent();
      });
    });

    bindScheduleCustomerButtons(mainPanel);
  }


  function serviceOptionDescription(productCode) {
    const descriptions = {
      CLOTHES: "Laundry and linen production",
      MOP: "MOP production and product variants"
    };

    return descriptions[String(productCode || "").toUpperCase()] || "Customer production service";
  }

  function renderServiceOptions(selectedCodes = [], disabled = false) {
    const selected = new Set(selectedCodes);
    const productTypes = Array.isArray(state.referenceData?.product_types)
      ? state.referenceData.product_types
      : [];

    formServices.innerHTML = productTypes
      .map(
        (productType) => `
          <label class="customers-service-option">
            <input
              type="checkbox"
              value="${escapeHtml(productType.product_code)}"
              ${selected.has(productType.product_code) ? "checked" : ""}
              ${disabled ? "disabled" : ""}
            >
            <span class="customers-service-option-copy">
              <strong>${escapeHtml(productType.display_name)}</strong>
              <small>${escapeHtml(serviceOptionDescription(productType.product_code))}</small>
            </span>
          </label>
        `
      )
      .join("");
  }

  function selectedServiceCodes() {
    return Array.from(
      formServices.querySelectorAll('input[type="checkbox"]:checked')
    )
      .map((input) => input.value)
      .sort();
  }

  function customerFormSnapshot() {
    return {
      customer_name: formName.value.trim(),
      eircode: formEircode.value.trim().toUpperCase(),
      distribution_estimated_kg: formEstimatedKg.value.trim(),
      distribution_stop_count: formStops.value.trim(),
      notes: formNotes.value.trim(),
      operational_alert: formOperationalAlert.value.trim(),
      product_services: selectedServiceCodes()
    };
  }

  function customerFormSnapshotKey(snapshot) {
    return JSON.stringify(snapshot || {});
  }

  function customerFormChangedFields() {
    const before = state.form.baseline || {};
    const after = customerFormSnapshot();
    const labels = [];

    if (before.customer_name !== after.customer_name) labels.push("customer name");
    if (before.eircode !== after.eircode) labels.push("Eircode");
    if (before.distribution_estimated_kg !== after.distribution_estimated_kg) labels.push("estimated KG");
    if (before.distribution_stop_count !== after.distribution_stop_count) labels.push("stop count");
    if (before.notes !== after.notes) labels.push("notes");
    if (before.operational_alert !== after.operational_alert) labels.push("operational alert");
    if (JSON.stringify(before.product_services || []) !== JSON.stringify(after.product_services || [])) labels.push("services");

    return labels;
  }

  function customerFormValidationMessage() {
    if (state.form.loading) {
      return "Loading customer details...";
    }

    if (state.form.mode !== "reactivate" && !formName.value.trim()) {
      return "Enter the customer name.";
    }

    if (selectedServiceCodes().length === 0) {
      return "Select at least one service.";
    }

    const kgValue = formEstimatedKg.value.trim();
    if (kgValue !== "" && (!Number.isFinite(Number(kgValue)) || Number(kgValue) < 0)) {
      return "Estimated KG must be zero or greater.";
    }

    const stopsValue = formStops.value.trim();
    if (
      stopsValue !== "" &&
      (!Number.isInteger(Number(stopsValue)) || Number(stopsValue) < 0)
    ) {
      return "Stops must be a whole number of zero or greater.";
    }

    return "";
  }

  function serviceChangeSummary() {
    if (state.form.mode !== "edit" || !state.form.baseline) {
      return null;
    }

    const before = new Set(state.form.baseline.product_services || []);
    const after = new Set(selectedServiceCodes());
    const added = Array.from(after).filter((code) => !before.has(code));
    const removed = Array.from(before).filter((code) => !after.has(code));

    return added.length || removed.length ? { added, removed } : null;
  }

  function updateCustomerFormState() {
    const snapshot = customerFormSnapshot();
    state.form.dirty = Boolean(
      state.form.baseline &&
      customerFormSnapshotKey(snapshot) !== customerFormSnapshotKey(state.form.baseline)
    );

    const validationMessage = customerFormValidationMessage();
    const serviceChange = serviceChangeSummary();
    const valid = !validationMessage;
    const actionReady = state.form.mode === "reactivate" || state.form.dirty;
    const canSave = valid && actionReady && !state.form.loading && !state.form.saving;

    formSave.disabled = !canSave;
    formStatus.classList.toggle("is-loading", state.form.loading);
    formStatus.classList.toggle("is-dirty", state.form.dirty && !state.form.loading);
    formStatus.classList.toggle("is-ready", canSave);

    if (state.form.loading) {
      formStatusText.textContent = "Loading customer details...";
      formSaveHint.textContent = "Loading...";
    } else if (validationMessage) {
      formStatusText.textContent = validationMessage;
      formSaveHint.textContent = validationMessage;
    } else if (!state.form.dirty && state.form.mode !== "reactivate") {
      formStatusText.textContent = state.form.mode === "create"
        ? "Complete the customer details to continue."
        : "No changes to save.";
      formSaveHint.textContent = state.form.mode === "create"
        ? "Enter the customer details."
        : "No changes to save.";
    } else {
      const changedFields = customerFormChangedFields();
      formStatusText.textContent = state.form.mode === "create"
        ? "Ready to add this customer."
        : state.form.mode === "reactivate"
          ? "Ready to reactivate this customer."
          : `Unsaved changes: ${changedFields.join(", ")}.`;
      formSaveHint.textContent = "Ready to save.";
    }

    if (serviceChange) {
      const parts = [];
      if (serviceChange.added.length) parts.push(`Added: ${serviceChange.added.join(", ")}`);
      if (serviceChange.removed.length) parts.push(`Removed: ${serviceChange.removed.join(", ")}`);
      formServiceImpact.innerHTML = `
        <strong>Schedule review recommended.</strong>
        ${escapeHtml(parts.join(" · "))}. Existing published schedules are not rewritten automatically.
      `;
      formServiceImpact.classList.remove("hidden");
      formNextStepSection.classList.remove("hidden");
      formOpenScheduleTitle.textContent = "Review schedule after saving";
      formOpenScheduleHelp.textContent = "Open Customer Studio so the weekly schedule matches the updated services.";
    } else {
      formServiceImpact.classList.add("hidden");
      if (state.form.mode === "edit") {
        formNextStepSection.classList.add("hidden");
      }
    }
  }

  function autoCustomerChangeReason() {
    const services = selectedServiceCodes().join(" + ") || "no services";
    const name = formName.value.trim() || state.form.record?.customer_name || "customer";

    if (state.form.mode === "create") {
      return `Created Customer Master record for ${name} with ${services} service eligibility.`;
    }

    if (state.form.mode === "reactivate") {
      return `Reactivated ${name} with ${services} service eligibility.`;
    }

    const changedFields = customerFormChangedFields();
    return `Updated Customer Master for ${name}: ${changedFields.join(", ") || "record details"}.`;
  }

  function setFormAlert(message = "") {
    formAlert.textContent = message;
    formAlert.classList.toggle("hidden", !message);
  }

  function setFormBusy(busy, label) {
    state.form.saving = busy;
    formSave.disabled = busy;
    formCancel.disabled = busy;
    formClose.disabled = busy;
    formSave.textContent = busy ? "Saving..." : label;

    if (!busy) {
      updateCustomerFormState();
    }
  }

  function setCustomerFormLoading(loading) {
    state.form.loading = loading;
    form.setAttribute("aria-busy", loading ? "true" : "false");

    const lockMasterFields = !loading && state.form.mode === "reactivate";

    [formName, formEircode, formEstimatedKg, formStops, formNotes, formOperationalAlert]
      .forEach((control) => {
        control.disabled = loading || lockMasterFields;
      });

    formServices.querySelectorAll("input").forEach((input) => {
      input.disabled = loading;
    });

    updateCustomerFormState();
  }

  function resetCustomerForm() {
    form.reset();
    formCode.value = "";
    formName.readOnly = false;
    formName.disabled = false;
    formEircode.disabled = false;
    formEstimatedKg.disabled = false;
    formStops.disabled = false;
    formNotes.disabled = false;
    formOperationalAlert.disabled = false;
    formOpenSchedule.checked = true;
    formAuditDetails.open = false;
    formNextStepSection.classList.remove("hidden");
    formServiceImpact.classList.add("hidden");
    formStatus.className = "customers-form-status";
    state.form.baseline = null;
    state.form.dirty = false;
    state.form.loading = false;
    state.form.saving = false;
    setFormAlert("");
  }

  function establishCustomerFormBaseline() {
    state.form.baseline = customerFormSnapshot();
    state.form.dirty = false;
    updateCustomerFormState();
  }

  function requestCloseCustomerForm() {
    if (
      state.form.dirty &&
      !window.confirm("Close Customer Master? Unsaved customer changes will be lost.")
    ) {
      return;
    }

    state.form.dirty = false;
    closeModal(formModal);
  }

  async function openCustomerForm(mode, customerId = null) {
    state.form.mode = mode;
    state.form.customerId = customerId;
    state.form.record = null;

    resetCustomerForm();
    renderServiceOptions([]);
    openModal(formModal);

    if (mode === "create") {
      formTitle.textContent = "Add Customer";
      formSubtitle.textContent = "Create the Customer Master record, then continue directly to schedule setup.";
      formReasonLabel.textContent = "Custom creation note";
      formSave.textContent = "Add Customer";
      formOpenScheduleTitle.textContent = "Open schedule setup after saving";
      formOpenScheduleHelp.textContent = "Continue directly to the weekly production schedule.";
      establishCustomerFormBaseline();
      return;
    }

    formTitle.textContent = mode === "edit" ? "Edit Customer" : "Reactivate Customer";
    formSubtitle.textContent = "Loading Customer Master record...";
    formSave.textContent = mode === "edit" ? "Save Changes" : "Reactivate Customer";
    formReasonLabel.textContent = mode === "edit" ? "Custom change note" : "Custom reactivation note";
    formNextStepSection.classList.toggle("hidden", mode === "edit");
    formOpenScheduleTitle.textContent = mode === "reactivate"
      ? "Open schedule setup after reactivation"
      : "Review schedule after saving";
    formOpenScheduleHelp.textContent = mode === "reactivate"
      ? "Reactivated customers need a new effective production schedule."
      : "Open Customer Studio after changing service eligibility.";

    setCustomerFormLoading(true);

    try {
      const record = await rpc("get_customer_master_record", {
        p_customer_id: customerId,
        p_effective_date: effectiveDateInput.value
      });

      state.form.record = record;
      populateCustomerForm(record, mode);
      establishCustomerFormBaseline();
    } catch (error) {
      console.error("Customer Master record load failed:", error);
      setFormAlert(errorMessage(error));
    } finally {
      setCustomerFormLoading(false);
    }
  }

  function populateCustomerForm(record, mode) {
    formCode.value = record.customer_code || "";
    formName.value = record.customer_name || "";
    formEircode.value = String(record.eircode || "").toUpperCase();
    formEstimatedKg.value = record.distribution_estimated_kg ?? "";
    formStops.value = record.distribution_stop_count ?? "";
    formNotes.value = record.notes || "";
    formOperationalAlert.value = record.operational_alert || "";
    formSubtitle.textContent = mode === "reactivate"
      ? "Confirm the services, reactivate the customer and continue to schedule setup."
      : `Editing ${record.customer_name}. Concurrent changes are protected automatically.`;

    renderServiceOptions(record.product_services || []);

    if (mode === "reactivate") {
      formName.readOnly = true;
      formEircode.disabled = true;
      formEstimatedKg.disabled = true;
      formStops.disabled = true;
      formNotes.disabled = true;
      formOperationalAlert.disabled = true;
    }
  }

  function parseOptionalNumber(input, integer = false) {
    const value = input.value.trim();

    if (value === "") {
      return null;
    }

    const parsed = Number(value);

    if (!Number.isFinite(parsed) || parsed < 0 || (integer && !Number.isInteger(parsed))) {
      throw new Error(integer ? "Stops must be a whole number of zero or greater." : "Estimated KG must be zero or greater.");
    }

    return parsed;
  }

  async function saveCustomerForm(event) {
    event.preventDefault();
    setFormAlert("");

    try {
      const validationMessage = customerFormValidationMessage();
      if (validationMessage) {
        throw new Error(validationMessage);
      }

      if (!state.form.dirty && state.form.mode !== "reactivate") {
        throw new Error("No customer changes are waiting to be saved.");
      }

      const services = selectedServiceCodes();
      const reason = formReason.value.trim() || autoCustomerChangeReason();
      const shouldOpenSchedule =
        !formNextStepSection.classList.contains("hidden") && formOpenSchedule.checked;
      const saveLabel =
        state.form.mode === "create"
          ? "Add Customer"
          : state.form.mode === "edit"
            ? "Save Changes"
            : "Reactivate Customer";

      setFormBusy(true, saveLabel);

      let result;

      if (state.form.mode === "create") {
        result = await rpc("create_customer_master", {
          p_customer_name: formName.value.trim(),
          p_eircode: formEircode.value.trim().toUpperCase() || null,
          p_distribution_estimated_kg: parseOptionalNumber(formEstimatedKg),
          p_distribution_stop_count: parseOptionalNumber(formStops, true),
          p_notes: formNotes.value.trim() || null,
          p_operational_alert: formOperationalAlert.value.trim() || null,
          p_product_codes: services,
          p_change_reason: reason,
          p_source_application: "CUSTOMER_MASTER_UI"
        });

        showToast("Customer created.");
      } else if (state.form.mode === "edit") {
        const record = state.form.record;

        result = await rpc("update_customer", {
          p_customer_id: record.customer_id,
          p_expected_row_version: record.row_version,
          p_customer_code: record.customer_code,
          p_customer_name: formName.value.trim(),
          p_eircode: formEircode.value.trim().toUpperCase() || null,
          p_distribution_estimated_kg: parseOptionalNumber(formEstimatedKg),
          p_distribution_stop_count: parseOptionalNumber(formStops, true),
          p_notes: formNotes.value.trim() || null,
          p_operational_alert: formOperationalAlert.value.trim() || null,
          p_product_codes: services,
          p_change_reason: reason,
          p_source_application: "CUSTOMER_MASTER_UI"
        });

        showToast("Customer updated.");
      } else {
        result = await rpc("reactivate_customer", {
          p_customer_id: state.form.record.customer_id,
          p_product_codes: services,
          p_reason: reason,
          p_source_application: "CUSTOMER_MASTER_UI"
        });

        showToast("Customer reactivated.");
      }

      const customerId = result?.customer_id || state.form.record?.customer_id;
      const customerCode = result?.customer_code || state.form.record?.customer_code || formCode.value;
      const customerName = result?.customer_name || state.form.record?.customer_name || formName.value.trim();

      state.form.baseline = customerFormSnapshot();
      state.form.dirty = false;
      closeModal(formModal);
      await loadMainView();

      if (shouldOpenSchedule && customerId) {
        await openScheduleDetails(customerId, customerCode, customerName);
      }
    } catch (error) {
      console.error("Customer save failed:", error);
      setFormAlert(errorMessage(error));

      if (/another user|reload/i.test(errorMessage(error))) {
        formSubtitle.textContent = "This customer changed elsewhere. Close and reopen the form before saving again.";
      }
    } finally {
      const label =
        state.form.mode === "create"
          ? "Add Customer"
          : state.form.mode === "edit"
            ? "Save Changes"
            : "Reactivate Customer";

      setFormBusy(false, label);
    }
  }

  function openDeactivateModal(customerId, customerName) {
    state.deactivate.customerId = customerId;
    state.deactivate.customerName = customerName;
    deactivateName.textContent = customerName;
    deactivateReason.value = "";
    deactivateAlert.textContent = "";
    deactivateAlert.classList.add("hidden");
    openModal(deactivateModal);
  }

  async function confirmDeactivate() {
    const reason = deactivateReason.value.trim();

    if (!reason) {
      deactivateAlert.textContent = "A deactivation reason is required.";
      deactivateAlert.classList.remove("hidden");
      return;
    }

    deactivateConfirm.disabled = true;
    deactivateConfirm.textContent = "Deactivating...";

    try {
      await rpc("deactivate_customer", {
        p_customer_id: state.deactivate.customerId,
        p_reason: reason,
        p_source_application: "CUSTOMER_MASTER_UI"
      });

      closeModal(deactivateModal);
      showToast("Customer deactivated. Historical data was preserved.");
      await loadMainView();
    } catch (error) {
      console.error("Customer deactivation failed:", error);
      deactivateAlert.textContent = errorMessage(error);
      deactivateAlert.classList.remove("hidden");
    } finally {
      deactivateConfirm.disabled = false;
      deactivateConfirm.textContent = "Deactivate Customer";
    }
  }

  async function initialize() {
    if (!client || window.ELIS_SUPABASE_ERROR) {
      setPageMessage(
        window.ELIS_SUPABASE_ERROR || "Supabase could not be initialized.",
        "error"
      );
      mainPanel.innerHTML = emptyHtml("Supabase is not available.");
      return;
    }

    try {
      const {
        data: { session },
        error
      } = await client.auth.getSession();

      if (error) {
        throw error;
      }

      if (!session?.user) {
        window.location.replace("../index.html");
        return;
      }

      state.capabilities = await rpc("get_customer_read_capabilities");

      effectiveDateInput.value =
        state.capabilities?.business_date ||
        new Date().toISOString().slice(0, 10);

      if (state.capabilities?.can_view_customer_directory) {
        state.referenceData = await rpc("get_customer_master_reference_data");
      }

      const requested = requestedInitialView();

      if (requested.legacyDistribution) {
        window.location.replace("./distribution.html");
        return;
      }

      if (requested.service && canUseScheduleService(requested.service)) {
        state.schedule.service = requested.service;
      }

      ensureScheduleService();

      const tabs = availableMainTabs();

      if (tabs.length === 0) {
        throw new Error("Your account does not have access to this module.");
      }

      state.mainView = tabs.some((tab) => tab.id === requested.view)
        ? requested.view
        : tabs[0].id;
      renderMainTabs();
      await loadMainView();

      client.auth.onAuthStateChange((event) => {
        if (event === "SIGNED_OUT") {
          window.location.replace("../index.html");
        }
      });
    } catch (error) {
      console.error("Customers initialization failed:", error);
      setPageMessage(errorMessage(error), "error");
      mainPanel.innerHTML = emptyHtml(
        "The Customers module could not be opened.",
        errorMessage(error)
      );
    }
  }

  signOutButton.addEventListener("click", async () => {
    signOutButton.disabled = true;
    signOutButton.textContent = "Signing out...";

    try {
      const { error } = await client.auth.signOut();

      if (error) {
        throw error;
      }

      window.location.replace("../index.html");
    } catch (error) {
      setPageMessage(errorMessage(error), "error");
    } finally {
      signOutButton.disabled = false;
      signOutButton.textContent = "Sign out";
    }
  });

  scheduleBackdrop.addEventListener("click", requestCloseScheduleModal);
  scheduleClose.addEventListener("click", requestCloseScheduleModal);
  scheduleCloseSecondary?.addEventListener("click", requestCloseScheduleModal);

  scheduleActionBackdrop.addEventListener("click", closeScheduleActionDialog);
  scheduleActionClose.addEventListener("click", closeScheduleActionDialog);
  scheduleActionCancel.addEventListener("click", closeScheduleActionDialog);
  scheduleActionConfirm.addEventListener("click", confirmScheduleAction);

  window.addEventListener("beforeunload", (event) => {
    if (!state.studio.dirty && !state.form.dirty) {
      return;
    }

    event.preventDefault();
    event.returnValue = "";
  });

  formBackdrop.addEventListener("click", requestCloseCustomerForm);
  formClose.addEventListener("click", requestCloseCustomerForm);
  formCancel.addEventListener("click", requestCloseCustomerForm);
  form.addEventListener("submit", saveCustomerForm);
  form.addEventListener("input", (event) => {
    if (event.target === formEircode) {
      const selectionStart = formEircode.selectionStart;
      const selectionEnd = formEircode.selectionEnd;
      formEircode.value = formEircode.value.toUpperCase();
      formEircode.setSelectionRange(selectionStart, selectionEnd);
    }

    updateCustomerFormState();
  });
  form.addEventListener("change", updateCustomerFormState);

  deactivateBackdrop.addEventListener("click", () => closeModal(deactivateModal));
  deactivateClose.addEventListener("click", () => closeModal(deactivateModal));
  deactivateCancel.addEventListener("click", () => closeModal(deactivateModal));
  deactivateConfirm.addEventListener("click", confirmDeactivate);

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") {
      return;
    }

    if (!scheduleActionModal.classList.contains("hidden")) {
      closeScheduleActionDialog();
    } else if (!deactivateModal.classList.contains("hidden")) {
      closeModal(deactivateModal);
    } else if (!formModal.classList.contains("hidden")) {
      requestCloseCustomerForm();
    } else if (!scheduleModal.classList.contains("hidden")) {
      requestCloseScheduleModal();
    }
  });

  initialize();
});
