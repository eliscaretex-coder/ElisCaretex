"use strict";

// End-of-shift trolley check (Production Tracker).
// The supervisor (or the person they choose) walks the ready trolleys with a phone and
// confirms each customer of the production list: number of trolleys, clothes and mops
// inside, the empty trolley some customers need, and production that is ready but not
// recorded. Results are append-only in the database (202611040001); the History view
// shows management whether each shift was checked, by whom, when and what was fixed.

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const el = {
    message: $("trolleyCheckMessage"),
    tabCheck: $("trolleyCheckTabCheck"), tabHistory: $("trolleyCheckTabHistory"),
    view: $("trolleyCheckView"), historyView: $("trolleyCheckHistoryView"),
    prev: $("trolleyCheckPrev"), next: $("trolleyCheckNext"), date: $("trolleyCheckDate"),
    dateLabel: $("trolleyCheckDateLabel"), deliveryLabel: $("trolleyCheckDeliveryLabel"), today: $("trolleyCheckToday"),
    status: $("trolleyCheckStatus"), list: $("trolleyCheckList"), search: $("trolleyCheckSearch"),
    footer: $("trolleyCheckFooter"), footerText: $("trolleyCheckFooterText"), finish: $("trolleyCheckFinish"),
    dialog: $("trolleyCheckDialog"), dialogTitle: $("trolleyCheckDialogTitle"), dialogRoute: $("trolleyCheckDialogRoute"),
    expected: $("trolleyCheckExpected"), summary: $("trolleyCheckSummary"), last: $("trolleyCheckLast"), actions: $("trolleyCheckActions"),
    problem: $("trolleyCheckProblem"), counted: $("trolleyCheckCounted"), countedEmpty: $("trolleyCheckCountedEmpty"),
    emptyCounter: $("trolleyCheckEmptyCounter"), issues: $("trolleyCheckIssues"), note: $("trolleyCheckNote"),
    dialogMessage: $("trolleyCheckDialogMessage"),
    finishDialog: $("trolleyCheckFinishDialog"), finishSummary: $("trolleyCheckFinishSummary"),
    finishNote: $("trolleyCheckFinishNote"), finishConfirm: $("trolleyCheckFinishConfirm"), finishMessage: $("trolleyCheckFinishMessage"),
    historyPeriod: $("trolleyCheckHistoryPeriod"), historyTotals: $("trolleyCheckHistoryTotals"), history: $("trolleyCheckHistory")
  };

  const ISSUES = [
    { code: "TROLLEY_COUNT", label: "Wrong number of trolleys" },
    { code: "CLOTHES_MISSING", label: "Clothes missing", when: (e) => e.has_clothes },
    { code: "MOP_MISSING", label: "MOPs missing", when: (e) => e.has_mop },
    { code: "EMPTY_TROLLEY_MISSING", label: "Empty trolley missing", when: (e) => Number(e.planned_empty_trolleys) > 0 },
    { code: "NOT_RECORDED", label: "Ready but not recorded in the system" },
    { code: "WRONG_TROLLEY_TYPE", label: "Wrong trolley size" },
    { code: "OTHER", label: "Other (write a note)" }
  ];
  const ISSUE_LABEL = Object.fromEntries(ISSUES.map((i) => [i.code, i.label]));
  const RESULT = {
    OK: { label: "OK", cls: "ok" },
    CORRECTED: { label: "Fixed", cls: "corrected" },
    PROBLEM: { label: "Problem", cls: "problem" },
    NOT_READY: { label: "Not ready", cls: "notready" }
  };

  const state = {
    data: null, date: "", shift: "", today: "", todayShift: "",
    filter: "ALL", open: null, issues: new Set(), counted: 0, countedEmpty: 0, saving: false,
    view: location.hash === "#history" ? "HISTORY" : "CHECK", historyLoaded: false
  };

  const esc = (v) => String(v ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");
  const safeColor = (v) => /^#[0-9a-f]{6}$/i.test(String(v || "")) ? String(v) : "#94a3b8";
  const textColor = (hex) => { const n = parseInt(safeColor(hex).slice(1), 16); return ((((n >> 16) & 255) * 299 + ((n >> 8) & 255) * 587 + (n & 255) * 114) / 1000) > 150 ? "#172033" : "#fff"; };
  const fmtTime = (v) => v ? new Intl.DateTimeFormat("en-IE", { hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(v)) : "—";
  const fmtDay = (iso, opts = { weekday: "short", day: "2-digit", month: "short" }) => iso ? new Intl.DateTimeFormat("en-IE", opts).format(new Date(`${iso}T12:00:00`)) : "—";
  const addDays = (iso, n) => { const d = new Date(`${iso}T12:00:00`); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };
  const isSunday = (iso) => new Date(`${iso}T12:00:00`).getDay() === 0;
  const stepDay = (iso, dir) => { let d = iso; do d = addDays(d, dir); while (isSunday(d)); return d; };
  const shiftName = (s) => s === "EVENING" ? "Evening" : "Morning";
  const rpc = async (name, args = {}) => { const { data, error } = await client.rpc(name, args); if (error) throw error; return data; };
  const setMessage = (text, kind = "") => { el.message.textContent = text || ""; el.message.className = `trolley-check-message ${kind}`; };

  // "M" for one size, "2 S + 1 M" for mixed sizes (the total is shown next to it).
  function typesText(list) {
    const items = list || [];
    if (items.length === 1) return items[0].type;
    return items.map((t) => `${t.quantity} ${t.type}`).join(" + ");
  }

  function needsAttention(c) {
    const e = c.expected || {};
    return (e.has_clothes && !e.clothes_recorded) || (e.has_mop && !e.mop_recorded);
  }

  function customerLine(c) {
    const e = c.expected || {};
    const parts = [];
    const planned = Number(e.planned_trolleys || 0);
    parts.push(`<b>${planned}</b> trolley${planned === 1 ? "" : "s"}${e.planned_types?.length ? ` <em>(${esc(typesText(e.planned_types))})</em>` : ""}`);
    if (Number(e.planned_empty_trolleys) > 0) parts.push(`<span class="tc-empty">+${Number(e.planned_empty_trolleys)} empty</span>`);
    if (e.has_clothes) parts.push(`<span class="tc-prod ${e.clothes_recorded ? "yes" : "no"}">Clothes ${e.clothes_recorded ? "✓" : "✗"}</span>`);
    if (e.has_mop) parts.push(`<span class="tc-prod ${e.mop_recorded ? "yes" : "no"}">MOP ${e.mop_recorded ? "✓" : "✗"}</span>`);
    return parts.join(" ");
  }

  function matches(c) {
    const q = el.search.value.trim().toLowerCase();
    if (q && !`${c.customer_name} ${c.route_code || ""} ${c.route_display_name || ""}`.toLowerCase().includes(q)) return false;
    const r = c.current?.result;
    if (state.filter === "TODO") return !r || r === "NOT_READY";
    if (state.filter === "ISSUES") return r === "PROBLEM" || r === "CORRECTED";
    if (state.filter === "UNRECORDED") return needsAttention(c);
    return true;
  }

  function counts() {
    const list = state.data?.customers || [];
    const c = { total: list.length, checked: 0, OK: 0, CORRECTED: 0, PROBLEM: 0, NOT_READY: 0, unrecorded: 0 };
    list.forEach((x) => { const r = x.current?.result; if (r) { c.checked += 1; c[r] += 1; } if (needsAttention(x)) c.unrecorded += 1; });
    return c;
  }

  function checkState() {
    const chk = state.data?.check;
    if (!chk) return "NOT_STARTED";
    return chk.status;
  }

  function canEdit() {
    return Boolean(state.data?.can_record) && checkState() !== "COMPLETED";
  }

  function renderHeader() {
    const isToday = state.date === state.today;
    el.dateLabel.textContent = `${fmtDay(state.date, { weekday: "long", day: "2-digit", month: "short" })}${isToday ? " · Today" : ""}`;
    el.deliveryLabel.textContent = `Production list · delivery ${fmtDay(stepDay(state.date, 1))}`;
    el.date.value = state.date;
    el.today.hidden = isToday && state.shift === state.todayShift;
    document.querySelectorAll("[data-shift]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.shift === state.shift)));
  }

  function renderStatus() {
    const c = counts();
    const chk = state.data?.check;
    const pct = c.total ? Math.round((c.checked * 100) / c.total) : 0;
    let line;
    if (!chk) line = `<span class="tc-badge waiting">Not started</span><span>${state.data?.can_record ? "Tap a customer to start." : "Read only: your login cannot record this check."}</span>`;
    else if (chk.status === "COMPLETED") line = `<span class="tc-badge done">Finished ${esc(fmtTime(chk.completed_at))}</span><span>by <b>${esc(chk.completed_by_name)}</b> · started ${esc(fmtTime(chk.started_at))} by ${esc(chk.started_by_name)}</span>`;
    else line = `<span class="tc-badge progress">In progress</span><span>started ${esc(fmtTime(chk.started_at))} by <b>${esc(chk.started_by_name)}</b></span>`;
    const other = (state.data?.day_checks || []).find((d) => d.shift_code !== state.shift);
    const otherLine = other ? `<small>${shiftName(other.shift_code)} check: ${other.status === "COMPLETED" ? `finished ${esc(fmtTime(other.completed_at))} by ${esc(other.completed_by_name)}` : `in progress (${esc(other.started_by_name)})`}</small>` : "";
    el.status.innerHTML = `<div class="tc-status-line">${line}</div>
      <div class="tc-progress"><i style="width:${pct}%"></i></div>
      <div class="tc-counts">
        <span><b>${c.checked}/${c.total}</b> checked</span>
        <span class="ok">${c.OK} OK</span>
        <span class="corrected">${c.CORRECTED} fixed</span>
        <span class="problem">${c.PROBLEM} problem${c.PROBLEM === 1 ? "" : "s"}</span>
        ${c.NOT_READY ? `<span class="notready">${c.NOT_READY} not ready</span>` : ""}
        ${c.unrecorded ? `<span class="warn" title="Customers with Clothes or MOP not yet recorded in the system">${c.unrecorded} not recorded yet</span>` : ""}
      </div>${otherLine}${chk?.completion_note ? `<p class="tc-note">“${esc(chk.completion_note)}”</p>` : ""}`;
  }

  function renderList() {
    const list = (state.data?.customers || []).filter(matches);
    if (!state.data) return;
    if (!list.length) {
      el.list.innerHTML = `<div class="trolley-check-empty">${(state.data.customers || []).length ? "No customer matches this filter." : "No customers on the production list of this day."}</div>`;
    } else {
      el.list.innerHTML = routeGroups(list).map((g) => routeBlock(g)).join("");
    }
    const c = counts();
    el.footer.hidden = !canEdit() || !state.data?.check;
    el.footerText.textContent = `${c.checked}/${c.total} checked${c.total - c.checked ? ` · ${c.total - c.checked} left` : ""}`;
  }

  // Customers grouped by delivery route, like the Production Tracker route board.
  // The server list is already in production order, so routes appear in the order
  // their first customer is produced and customers keep their order inside the route.
  function routeKey(c) {
    const code = String(c.route_code || "").trim(), name = String(c.route_display_name || "").trim();
    return (code ? `CODE:${code}` : name ? `NAME:${name}` : "UNASSIGNED").toUpperCase();
  }

  function routeGroups(list) {
    const map = new Map();
    list.forEach((c) => {
      const key = routeKey(c);
      if (!map.has(key)) map.set(key, { key, code: String(c.route_code || "").trim(), name: String(c.route_display_name || c.route_code || "").trim() || "Route not recorded", color: safeColor(c.route_color), customers: [] });
      map.get(key).customers.push(c);
    });
    return [...map.values()];
  }

  function routeBlock(g) {
    const all = (state.data?.customers || []).filter((c) => routeKey(c) === g.key);
    const checked = all.filter((c) => c.current?.result).length;
    const problems = all.filter((c) => c.current?.result === "PROBLEM").length;
    const trolleys = all.reduce((n, c) => n + Number(c.expected?.planned_trolleys || 0), 0);
    const empty = all.reduce((n, c) => n + Number(c.expected?.planned_empty_trolleys || 0), 0);
    const done = all.length && checked === all.length;
    return `<section class="tc-route-block${done ? " done" : ""}" style="--route:${g.color};--route-text:${textColor(g.color)}">
      <header class="tc-route-head">
        <span class="tc-route-mark">${esc(g.code || "R")}</span>
        <strong>${esc(g.name)}</strong>
        <small>${all.length} customer${all.length === 1 ? "" : "s"} · ${trolleys} trolley${trolleys === 1 ? "" : "s"}${empty ? ` + ${empty} empty` : ""}</small>
        <span class="tc-route-count${problems ? " problem" : done ? " ok" : ""}">${done ? "✓ " : ""}${checked}/${all.length}</span>
      </header>
      ${g.customers.map(customerRow).join("")}
    </section>`;
  }

  function customerRow(c) {
    const r = c.current?.result;
    const meta = r ? RESULT[r] : null;
    const order = c.production_order != null ? c.production_order : "";
    const issues = (c.current?.issue_codes || []).map((code) => ISSUE_LABEL[code] || code).join(", ");
    return `<button type="button" class="tc-row ${meta ? meta.cls : "todo"}${needsAttention(c) ? " attention" : ""}" data-customer="${esc(c.customer_id)}">
      <span class="tc-order">${esc(order)}</span>
      <span class="tc-main">
        <strong>${esc(c.customer_name)}</strong>
        <small>${customerLine(c)}${c.scheduled ? "" : ' <span class="tc-extra">Not on Schedule</span>'}</small>
        ${issues ? `<small class="tc-issues">${esc(issues)}${c.current?.note ? ` · “${esc(c.current.note)}”` : ""}</small>` : ""}
      </span>
      <span class="tc-pill ${meta ? meta.cls : "todo"}">${meta ? esc(meta.label) : "Check"}${r ? `<small>${esc(fmtTime(c.current.recorded_at))}</small>` : ""}</span>
    </button>`;
  }

  function render() {
    renderHeader();
    renderStatus();
    renderList();
  }

  async function load({ date = state.date || null, shift = state.shift || null, quiet = false } = {}) {
    if (!quiet) { el.list.style.opacity = ".5"; setMessage(""); }
    try {
      const data = await rpc("get_production_trolley_check_v1", { p_business_date: date, p_shift_code: shift });
      if (data?.schema_version !== "PRODUCTION_TROLLEY_CHECK_V1") throw new Error("The trolley check backend is not installed yet. Apply migration 202611040001.");
      state.data = data;
      state.date = String(data.business_date).slice(0, 10);
      state.shift = data.shift_code;
      state.today = String(data.current_business_date).slice(0, 10);
      state.todayShift = data.current_shift_code;
      render();
    } catch (e) {
      console.error(e);
      setMessage(e.message || "The trolley check could not be loaded.", "error");
      if (!state.data) el.list.innerHTML = `<div class="trolley-check-empty">${esc(e.message || "Unavailable")}</div>`;
    } finally {
      el.list.style.opacity = "1";
    }
  }

  // Customer sheet -----------------------------------------------------------------

  function findCustomer(id) { return (state.data?.customers || []).find((c) => c.customer_id === id); }

  function expectedHtml(c) {
    const e = c.expected || {};
    const rows = [];
    const planned = Number(e.planned_trolleys || 0);
    rows.push(`<div><span>Trolleys</span><strong>${planned}${e.planned_types?.length ? ` <em>${esc(typesText(e.planned_types))}</em>` : ""}</strong></div>`);
    if (Number(e.planned_empty_trolleys) > 0) rows.push(`<div class="empty"><span>Empty trolley</span><strong>${Number(e.planned_empty_trolleys)} <em>${esc(typesText(e.planned_empty_types))}</em></strong></div>`);
    if (e.has_clothes) rows.push(`<div class="${e.clothes_recorded ? "yes" : "no"}"><span>Clothes</span><strong>${e.clothes_recorded ? `Recorded in Finish · ${Number(e.clothes_kg || 0).toFixed(1)} kg` : "Not recorded in the system"}</strong></div>`);
    if (e.has_mop) rows.push(...mopRows(e));
    rows.push(...scannedRows(e));
    return rows.join("");
  }

  const kg = (v) => `${Number(v || 0).toFixed(1)} kg`;
  const units = (v) => v == null ? "" : `${Number(v).toLocaleString("en-IE")} unit${Number(v) === 1 ? "" : "s"}`;

  // MOP: recorded total, each MOP type with its units and kg, and the ABS status.
  function mopRows(e) {
    if (!e.mop_recorded) return [`<div class="no"><span>MOP</span><strong>Not recorded in the system</strong></div>`];
    const out = [`<div class="yes"><span>MOP</span><strong>Recorded in MOP Production${e.mop_kg != null ? ` · ${kg(e.mop_kg)}` : ""}</strong></div>`];
    (e.mop_lines || []).forEach((l) => {
      out.push(`<div class="mop-line"><span>${esc(l.type || "MOP")}</span><strong>${esc([units(l.units), l.weight_kg != null ? kg(l.weight_kg) : ""].filter(Boolean).join(" · "))}</strong></div>`);
    });
    const abs = e.mop_abs || [];
    if (abs.length) {
      const text = abs.map((a) => esc([a.batch_reference ? `Batch ${a.batch_reference}` : "", a.quantity != null ? `${Number(a.quantity).toFixed(1)} ${String(a.unit_code || "KG").toLowerCase()}` : "", a.recorded_by || "", a.recorded_at ? fmtTime(a.recorded_at) : ""].filter(Boolean).join(" · "))).join("<br>");
      out.push(`<div class="yes abs"><span>ABS</span><strong>Recorded<em class="tc-abs-detail">${text}</em></strong></div>`);
    } else if (e.mop_abs_recorded === false) {
      out.push(`<div class="no abs"><span>ABS</span><strong>Not recorded in ABS yet</strong></div>`);
    }
    return out;
  }

  // Scanned trolleys split by the area that recorded them (Finish = Clothes, MOP
  // Production = MOP), with the size of each trolley and a size total per area.
  function scannedRows(e) {
    const list = (e.recorded_trolleys || []).map((t) => typeof t === "string" ? { code: t, size: "?", source: "FINISH" } : t);
    if (!list.length) return [];
    const sources = [["FINISH", "Scanned · Finish"], ["MOP", "Scanned · MOP"]];
    return sources.map(([source, label]) => {
      const items = list.filter((t) => (t.source || "FINISH") === source);
      if (!items.length) return "";
      const sizes = new Map();
      items.forEach((t) => sizes.set(t.size || "?", (sizes.get(t.size || "?") || 0) + 1));
      const sizeText = [...sizes.entries()].map(([size, n]) => `${n} ${size}`).join(" + ");
      const chips = items.map((t) => `<code title="${esc(t.size_name || t.size || "")}">${esc(t.code)} <b>${esc(t.size || "?")}</b></code>`).join(" ");
      return `<div class="scanned ${source.toLowerCase()}"><span>${esc(label)}</span><strong><em class="tc-scan-total">${items.length} · ${esc(sizeText)}</em><span class="codes">${chips}</span></strong></div>`;
    }).filter(Boolean);
  }

  // Plain summary at the top of the customer sheet: planned trolleys vs trolleys
  // scanned by each area, and exactly where the difference is.
  function sizeMap(list) {
    const m = new Map();
    (list || []).forEach((t) => { const k = t.type || t.size || "?"; m.set(k, (m.get(k) || 0) + Number(t.quantity ?? 1)); });
    return m;
  }
  function mapText(m) { return [...m.entries()].filter(([, n]) => n > 0).map(([k, n]) => `${n} ${k}`).join(" + ") || "0"; }
  function mapTotal(m) { return [...m.values()].reduce((a, b) => a + b, 0); }

  // Production found ready but not recorded: open Finish / MOP Production on this
  // customer so it is recorded now (with the real KG), instead of becoming a
  // confirmation request after the delivery deadline.
  function recordNowHtml(c) {
    const e = c.expected || {};
    const q = `customer=${encodeURIComponent(c.customer_id)}&date=${encodeURIComponent(state.date || "")}`;
    const links = [];
    if (e.has_clothes && !e.clothes_recorded) links.push(`<a class="tc-record-now clothes" href="./finish-production.html?${q}"><b>Record Clothes in Finish</b><small>Enter the KG and trolleys now</small></a>`);
    if (e.has_mop && !e.mop_recorded) links.push(`<a class="tc-record-now mop" href="./mop-production.html?${q}"><b>Record MOP in MOP Production</b><small>Enter the MOP types and KG now</small></a>`);
    if (!links.length) return "";
    return `<div class="tc-record-now-wrap"><p>Produced but not recorded? Record it now, so no warning comes up after delivery.</p>${links.join("")}</div>`;
  }

  function summaryHtml(c) {
    const e = c.expected || {};
    const scanned = (e.recorded_trolleys || []).map((t) => typeof t === "string" ? { code: t, size: "?", source: "FINISH" } : t);
    const plannedBy = e.planned_by_source || { FINISH: e.planned_types || [] };
    const areas = [];
    if (e.has_clothes || plannedBy.FINISH || scanned.some((t) => t.source === "FINISH")) areas.push(["FINISH", "Clothes (Finish)", e.has_clothes, e.clothes_recorded]);
    if (e.has_mop || plannedBy.MOP || scanned.some((t) => t.source === "MOP")) areas.push(["MOP", "MOP", e.has_mop, e.mop_recorded]);
    const lines = [];
    let problems = 0;
    let plannedAll = 0;
    let scannedAll = 0;
    areas.forEach(([source, label, has, recorded]) => {
      const plan = sizeMap(plannedBy[source]);
      const scan = sizeMap(scanned.filter((t) => (t.source || "FINISH") === source).map((t) => ({ type: t.size || "?", quantity: 1 })));
      const p = mapTotal(plan), s = mapTotal(scan);
      plannedAll += p; scannedAll += s;
      if (!p && !s && !has) return;
      const diffs = [];
      new Set([...plan.keys(), ...scan.keys()]).forEach((k) => {
        const d = (plan.get(k) || 0) - (scan.get(k) || 0);
        if (d > 0) diffs.push(`${d} ${k} missing`);
        if (d < 0) diffs.push(`${-d} ${k} extra`);
      });
      if (has && !recorded) {
        problems += 1;
        lines.push(`<li class="bad"><b>${esc(label)}</b> not recorded in the system${s ? ` (${s} trolley${s === 1 ? "" : "s"} scanned)` : ""}. If it is ready here, it was produced but not recorded.</li>`);
        return;
      }
      if (!s && p) { problems += 1; lines.push(`<li class="bad"><b>${esc(label)}</b>: no trolley scanned. Plan ${esc(mapText(plan))}.</li>`); return; }
      if (diffs.length) { problems += 1; lines.push(`<li class="bad"><b>${esc(label)}</b>: ${s} scanned, plan ${p} — <b>${esc(diffs.join(", "))}</b>.</li>`); return; }
      lines.push(`<li class="good"><b>${esc(label)}</b>: ${s} of ${p} scanned (${esc(mapText(scan))})</li>`);
    });
    if (e.has_mop && e.mop_recorded && e.mop_abs_recorded === false) lines.push(`<li class="info abs">MOP not recorded in <b>ABS</b> yet.</li>`);
    const empty = sizeMap(e.planned_empty_types);
    if (mapTotal(empty)) lines.push(`<li class="info">Also send <b>${esc(mapText(empty))} empty</b> trolley${mapTotal(empty) === 1 ? "" : "s"} (not scanned: check it by eye).</li>`);
    const head = problems
      ? `<strong class="bad">${problems} thing${problems === 1 ? "" : "s"} to check</strong>`
      : `<strong class="good">System matches the plan</strong><span>Count ${scannedAll} trolley${scannedAll === 1 ? "" : "s"} here${mapTotal(empty) ? ` + ${mapTotal(empty)} empty` : ""}.</span>`;
    return `<div class="tc-summary ${problems ? "bad" : "good"}">${head}<ul>${lines.join("")}</ul></div>`;
  }

  function renderIssues(c) {
    const e = c.expected || {};
    el.issues.innerHTML = ISSUES.filter((i) => !i.when || i.when(e)).map((i) => `<button type="button" data-issue="${i.code}" aria-pressed="${state.issues.has(i.code)}">${esc(i.label)}</button>`).join("");
  }

  function renderCounters() {
    el.counted.textContent = String(state.counted);
    el.countedEmpty.textContent = String(state.countedEmpty);
    const c = state.open && findCustomer(state.open);
    el.emptyCounter.hidden = !(c && (Number(c.expected?.planned_empty_trolleys) > 0 || state.issues.has("EMPTY_TROLLEY_MISSING")));
  }

  function openCustomer(id) {
    const c = findCustomer(id);
    if (!c) return;
    state.open = id;
    const cur = c.current;
    const hasIssues = cur && (cur.result === "PROBLEM" || cur.result === "CORRECTED");
    state.issues = new Set(hasIssues ? cur.issue_codes : []);
    state.counted = cur?.counted_trolleys ?? Number(c.expected?.planned_trolleys || 0);
    state.countedEmpty = cur?.counted_empty_trolleys ?? Number(c.expected?.planned_empty_trolleys || 0);
    el.note.value = hasIssues ? (cur.note || "") : "";
    el.dialogTitle.textContent = c.customer_name;
    el.dialogRoute.textContent = [c.route_display_name || c.route_code, c.production_order != null ? `Order ${c.production_order}` : "", c.scheduled ? "" : "Not on Schedule"].filter(Boolean).join(" · ");
    el.summary.innerHTML = summaryHtml(c) + recordNowHtml(c);
    el.expected.innerHTML = expectedHtml(c);
    el.last.hidden = !cur;
    if (cur) el.last.innerHTML = `Last: <b class="${RESULT[cur.result].cls}">${esc(RESULT[cur.result].label)}</b> by ${esc(cur.recorded_by_name)} at ${esc(fmtTime(cur.recorded_at))}${cur.revisions > 1 ? ` · ${cur.revisions} changes` : ""}`;
    el.problem.hidden = !hasIssues;
    const editable = canEdit();
    el.dialog.querySelectorAll("[data-result],[data-open-problem],[data-step],#trolleyCheckNote").forEach((b) => { b.disabled = !editable; });
    el.dialogMessage.textContent = editable ? "" : (checkState() === "COMPLETED" ? "This check is finished and can no longer be changed." : "Your login can view this check but cannot record it.");
    el.dialogMessage.className = "trolley-check-dialog-message";
    renderIssues(c);
    renderCounters();
    el.dialog.showModal();
  }

  async function save(result) {
    if (state.saving || !state.open) return;
    const c = findCustomer(state.open);
    const issues = [...state.issues];
    const note = el.note.value.trim();
    if ((result === "PROBLEM" || result === "CORRECTED")) {
      if (!issues.length) { el.dialogMessage.textContent = "Choose what was wrong."; el.dialogMessage.className = "trolley-check-dialog-message error"; return; }
      if (issues.includes("OTHER") && !note) { el.dialogMessage.textContent = "Write what was wrong in the note."; el.dialogMessage.className = "trolley-check-dialog-message error"; el.note.focus(); return; }
    }
    const problem = result === "PROBLEM" || result === "CORRECTED";
    const previous = c.current;
    state.saving = true;
    // Optimistic: the supervisor moves to the next trolley while the result is saved.
    c.current = {
      result, issue_codes: problem ? issues : [], note: problem ? note : null,
      counted_trolleys: result === "NOT_READY" ? null : (problem ? state.counted : Number(c.expected?.planned_trolleys || 0)),
      counted_empty_trolleys: result === "NOT_READY" ? null : (problem ? state.countedEmpty : Number(c.expected?.planned_empty_trolleys || 0)),
      recorded_at: new Date().toISOString(), recorded_by_name: previous?.recorded_by_name || "You",
      revisions: (previous?.revisions || 0) + 1, pending: true
    };
    el.dialog.close();
    render();
    try {
      const res = await rpc("record_production_trolley_check_item", {
        p_business_date: state.date, p_shift_code: state.shift, p_customer_id: c.customer_id, p_result: result,
        p_issue_codes: problem ? issues : [], p_counted_trolleys: problem ? state.counted : null,
        p_counted_empty_trolleys: problem ? state.countedEmpty : null, p_note: problem ? (note || null) : null
      });
      c.current.recorded_by_name = res.recorded_by_name;
      c.current.recorded_at = res.recorded_at;
      delete c.current.pending;
      if (!state.data.check) {
        state.data.check = { trolley_check_id: res.trolley_check_id, status: "IN_PROGRESS", started_at: res.recorded_at, started_by_name: res.recorded_by_name };
      }
      setMessage(`${c.customer_name}: ${RESULT[result].label}`, "success");
      render();
    } catch (e) {
      console.error(e);
      c.current = previous;
      render();
      setMessage(`${c.customer_name} was not saved: ${e.message || "error"}`, "error");
    } finally {
      state.saving = false;
    }
  }

  // Finish -------------------------------------------------------------------------

  function openFinish() {
    const c = counts();
    const left = c.total - c.checked;
    el.finishSummary.innerHTML = `
      <div><span>Checked</span><strong>${c.checked}/${c.total}</strong></div>
      <div class="ok"><span>OK</span><strong>${c.OK}</strong></div>
      <div class="corrected"><span>Fixed</span><strong>${c.CORRECTED}</strong></div>
      <div class="problem"><span>Still wrong</span><strong>${c.PROBLEM}</strong></div>
      <div class="notready"><span>Not ready</span><strong>${c.NOT_READY}</strong></div>
      ${left ? `<p class="warn">${left} customer${left === 1 ? " was" : "s were"} not checked. Write a note saying why.</p>` : ""}`;
    el.finishNote.value = "";
    el.finishMessage.textContent = "";
    el.finishDialog.showModal();
  }

  async function confirmFinish() {
    const chk = state.data?.check;
    if (!chk) return;
    el.finishConfirm.disabled = true;
    el.finishMessage.textContent = "Saving…";
    el.finishMessage.className = "trolley-check-dialog-message";
    try {
      await rpc("complete_production_trolley_check", { p_trolley_check_id: chk.trolley_check_id, p_note: el.finishNote.value.trim() || null });
      el.finishDialog.close();
      setMessage(`${shiftName(state.shift)} check finished.`, "success");
      state.historyLoaded = false;
      await load({ quiet: true });
    } catch (e) {
      el.finishMessage.textContent = e.message || "The check could not be finished.";
      el.finishMessage.className = "trolley-check-dialog-message error";
    } finally {
      el.finishConfirm.disabled = false;
    }
  }

  // History (management) ------------------------------------------------------------

  function historyCard(row) {
    const s = row.summary || {};
    const status = row.status;
    const badge = status === "COMPLETED" ? `<span class="tc-badge done">Done</span>` : status === "IN_PROGRESS" ? `<span class="tc-badge progress">Not finished</span>` : `<span class="tc-badge missing">Not done</span>`;
    const who = status === "NOT_DONE" ? "<p class=\"tc-who\">Nobody recorded a check.</p>"
      : `<p class="tc-who">${status === "COMPLETED" ? `Finished <b>${esc(fmtTime(row.completed_at))}</b> by <b>${esc(row.completed_by_name)}</b>` : `Started ${esc(fmtTime(row.started_at))} by <b>${esc(row.started_by_name)}</b>`}${(row.checked_by || []).length > 1 ? ` · checked by ${esc(row.checked_by.join(", "))}` : ""}</p>`;
    const nums = row.summary ? `<div class="tc-counts">
        <span><b>${Number(s.checked || 0)}/${Number(s.customers || 0)}</b> checked</span>
        <span class="ok">${Number(s.ok || 0)} OK</span>
        <span class="corrected">${Number(s.corrected || 0)} fixed</span>
        <span class="problem">${Number(s.problem || 0)} still wrong</span>
        ${Number(s.not_ready || 0) ? `<span class="notready">${Number(s.not_ready)} not ready</span>` : ""}
        ${Number(s.not_recorded || 0) ? `<span class="warn">${Number(s.not_recorded)} not recorded</span>` : ""}
      </div>` : "";
    const findings = (row.findings || []).map((f) => `<li class="${f.result === "PROBLEM" ? "problem" : "corrected"}">
        <strong>${esc(f.customer_name)}</strong> <em>${esc(f.result === "PROBLEM" ? "Still wrong" : "Fixed")}</em>
        <span>${esc((f.issue_codes || []).map((c) => ISSUE_LABEL[c] || c).join(", "))}${f.counted_trolleys != null && Number(f.counted_trolleys) !== Number(f.planned_trolleys) ? ` · counted ${Number(f.counted_trolleys)} of ${Number(f.planned_trolleys)} trolleys` : ""}</span>
        ${f.note ? `<span class="tc-note">“${esc(f.note)}”</span>` : ""}
        <small>${esc(f.recorded_by_name)} · ${esc(fmtTime(f.recorded_at))}</small>
      </li>`).join("");
    return `<article class="tc-hcard ${status.toLowerCase()}">
      <header><strong>${shiftName(row.shift_code)}</strong>${badge}</header>
      ${who}${nums}
      ${row.completion_note ? `<p class="tc-note">“${esc(row.completion_note)}”</p>` : ""}
      ${findings ? `<ul class="tc-findings">${findings}</ul>` : ""}
      ${status !== "NOT_DONE" ? `<button type="button" class="trolley-check-link" data-open-check="${esc(row.business_date)}|${esc(row.shift_code)}">Open this check ›</button>` : ""}
    </article>`;
  }

  async function loadHistory() {
    el.history.innerHTML = '<div class="trolley-check-empty">Loading history…</div>';
    try {
      const days = Number(el.historyPeriod.value || 14);
      const to = state.today || null;
      const data = await rpc("get_production_trolley_check_history_v1", { p_date_from: to ? addDays(to, -(days - 1)) : null, p_date_to: to });
      const rows = data?.rows || [];
      const byDay = new Map();
      rows.forEach((r) => { const d = String(r.business_date).slice(0, 10); if (!byDay.has(d)) byDay.set(d, []); byDay.get(d).push(r); });
      const past = rows.filter((r) => !(String(r.business_date).slice(0, 10) === state.today && r.status === "NOT_DONE"));
      const done = past.filter((r) => r.status === "COMPLETED").length;
      const missing = past.filter((r) => r.status === "NOT_DONE").length;
      const open = past.filter((r) => r.status === "IN_PROGRESS").length;
      const problems = rows.reduce((n, r) => n + (r.findings || []).filter((f) => f.result === "PROBLEM").length, 0);
      const fixed = rows.reduce((n, r) => n + (r.findings || []).filter((f) => f.result === "CORRECTED").length, 0);
      el.historyTotals.innerHTML = `
        <div class="ok"><span>Checks done</span><strong>${done}/${past.length}</strong></div>
        <div class="missing"><span>Not done</span><strong>${missing}</strong></div>
        <div class="progress"><span>Not finished</span><strong>${open}</strong></div>
        <div class="corrected"><span>Fixed on the spot</span><strong>${fixed}</strong></div>
        <div class="problem"><span>Left wrong</span><strong>${problems}</strong></div>`;
      el.history.innerHTML = [...byDay.entries()].map(([d, list]) => `<section class="tc-hday">
          <h3>${esc(fmtDay(d, { weekday: "long", day: "2-digit", month: "short" }))}${d === state.today ? " · Today" : ""}</h3>
          <div class="tc-hgrid">${list.sort((a, b) => (a.shift_code === "MORNING" ? 0 : 1) - (b.shift_code === "MORNING" ? 0 : 1)).map(historyCard).join("")}</div>
        </section>`).join("") || '<div class="trolley-check-empty">No production days in this period.</div>';
      state.historyLoaded = true;
    } catch (e) {
      console.error(e);
      el.history.innerHTML = `<div class="trolley-check-empty">${esc(e.message || "History unavailable")}</div>`;
    }
  }

  function setView(view) {
    state.view = view;
    el.view.hidden = view !== "CHECK";
    el.historyView.hidden = view !== "HISTORY";
    el.tabCheck.setAttribute("aria-selected", String(view === "CHECK"));
    el.tabHistory.setAttribute("aria-selected", String(view === "HISTORY"));
    history.replaceState(null, "", view === "HISTORY" ? "#history" : location.pathname + location.search);
    if (view === "HISTORY" && !state.historyLoaded) loadHistory();
  }

  // Events ---------------------------------------------------------------------------

  el.tabCheck.addEventListener("click", () => setView("CHECK"));
  el.tabHistory.addEventListener("click", () => setView("HISTORY"));
  el.prev.addEventListener("click", () => load({ date: stepDay(state.date, -1) }));
  el.next.addEventListener("click", () => load({ date: stepDay(state.date, 1) }));
  el.date.addEventListener("change", () => { if (el.date.value) load({ date: el.date.value }); });
  el.today.addEventListener("click", () => load({ date: state.today, shift: state.todayShift }));
  document.querySelectorAll("[data-shift]").forEach((b) => b.addEventListener("click", () => load({ shift: b.dataset.shift })));
  document.querySelectorAll("[data-filter]").forEach((b) => b.addEventListener("click", () => {
    state.filter = b.dataset.filter;
    document.querySelectorAll("[data-filter]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    renderList();
  }));
  el.search.addEventListener("input", renderList);
  el.list.addEventListener("click", (e) => { const row = e.target.closest("[data-customer]"); if (row) openCustomer(row.dataset.customer); });
  el.dialog.addEventListener("click", (e) => {
    if (e.target === el.dialog || e.target.closest("[data-close]")) { el.dialog.close(); return; }
    if (e.target.closest("[data-open-problem]")) { el.problem.hidden = false; if (!state.issues.size) { state.issues.add("TROLLEY_COUNT"); renderIssues(findCustomer(state.open)); } el.problem.scrollIntoView({ block: "nearest", behavior: "smooth" }); return; }
    const issue = e.target.closest("[data-issue]");
    if (issue && !issue.disabled) {
      const code = issue.dataset.issue;
      if (state.issues.has(code)) state.issues.delete(code); else state.issues.add(code);
      issue.setAttribute("aria-pressed", String(state.issues.has(code)));
      renderCounters();
      return;
    }
    const step = e.target.closest("[data-step]");
    if (step) {
      const key = step.dataset.step === "empty" ? "countedEmpty" : "counted";
      state[key] = Math.max(0, Math.min(99, state[key] + Number(step.dataset.delta)));
      renderCounters();
      return;
    }
    const res = e.target.closest("[data-result]");
    if (res) save(res.dataset.result);
  });
  el.finish.addEventListener("click", openFinish);
  el.finishConfirm.addEventListener("click", confirmFinish);
  el.finishDialog.addEventListener("click", (e) => { if (e.target === el.finishDialog || e.target.closest("[data-close]")) el.finishDialog.close(); });
  el.historyPeriod.addEventListener("change", loadHistory);
  el.history.addEventListener("click", (e) => {
    const b = e.target.closest("[data-open-check]");
    if (!b) return;
    const [d, s] = b.dataset.openCheck.split("|");
    setView("CHECK");
    load({ date: d, shift: s });
  });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && state.data && state.view === "CHECK" && !el.dialog.open) load({ quiet: true }); });

  if (window.ELIS_SUPABASE_ERROR || !client) { setMessage(window.ELIS_SUPABASE_ERROR || "Supabase could not be initialized.", "error"); return; }
  try {
    const { data: { session }, error } = await client.auth.getSession();
    if (error) throw error;
    if (!session?.user) { window.location.href = "../index.html"; return; }
    const params = new URLSearchParams(location.search);
    await load({ date: params.get("date") || null, shift: params.get("shift") || null });
    setView(state.view);
  } catch (e) {
    console.error(e);
    setMessage(e.message || "The trolley check could not be initialized.", "error");
  }
});
