"use strict";

// Stock Control: PPE and uniforms, chemicals and miscellaneous stock.
// Supervisors, managers and Distribution answer staff requests, register
// receipts, takes and counts, issue and return PPE and manage locker keys.
// Authorization is enforced by the RPCs (202610280003_stock_control.sql);
// the page only hides what the account cannot do.
(() => {
  const AREAS = { PPE_UNIFORM: "PPE & uniforms", CHEMICAL: "Chemicals", MISCELLANEOUS: "Miscellaneous" };
  const TRACK = { STAFF: "Person", CUSTOMER: "Customer", NONE: "Counted (internal use)" };
  const MOVE = {
    IN: { label: "Receive", kind: "RECEIVE", tone: "in", button: "stk-green" },
    OUT: { label: "Take", kind: "TAKE", tone: "out", button: "stk-red" },
    ADJUST: { label: "Adjust", kind: "ADJUST", tone: "adjust", button: "stk-primary" },
    COUNT: { label: "Count", tone: "count" },
    CONSUMPTION: { label: "Usage", tone: "consumption" }
  };
  const REQUEST = {
    REQUESTED: { label: "Waiting", tone: "requested" },
    APPROVED: { label: "Approved, to hand over", tone: "approved" },
    ISSUED: { label: "Handed over", tone: "issued" },
    REJECTED: { label: "Declined", tone: "rejected" },
    CANCELLED: { label: "Cancelled by staff", tone: "cancelled" }
  };

  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const date = (value) => value ? new Intl.DateTimeFormat("en-IE", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(value)) : "—";
  const dateTime = (value) => value ? new Intl.DateTimeFormat("en-IE", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "—";
  const qty = (value) => Number(value || 0).toLocaleString("en-IE", { maximumFractionDigits: 2 });
  const money = (value) => Number(value || 0).toLocaleString("en-IE", { style: "currency", currency: "EUR" });
  const isoDate = (value) => new Date(value.getTime() - value.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  const personKey = (person) => person?.staff_id || person?.driver_id || "";

  const state = {
    data: null, tab: "overview", canOperate: false, canManage: false,
    requestFilter: "open", answered: null, peopleFilter: "holding", lockerFilter: "all",
    countCategory: "", counts: new Map(), historyRows: [], historyKind: "MOVEMENTS",
    move: null, issue: null, ppeAction: "ISSUED", person: null, locker: null, editing: null
  };
  const pickers = {};

  async function rpc(name, args) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function friendly(error) {
    const text = error?.message || String(error || "Something went wrong.");
    if (/permission denied|not authorized/i.test(text)) return "Your account cannot do this. Ask a manager for Stock Control access.";
    return text;
  }

  function message(text, tone = "") {
    const element = $("stkMessage");
    element.textContent = text || "";
    element.className = `stk-message${tone ? ` ${tone}` : ""}${text ? "" : " hidden"}`;
    if (text && tone !== "error") window.clearTimeout(message.timer), message.timer = window.setTimeout(() => message(""), 6000);
  }

  function pill(text, tone) { return `<span class="stk-pill ${esc(tone)}">${esc(text)}</span>`; }
  function itemById(id) { return state.data.items.find((item) => item.item_id === id); }
  function category(code) { return state.data.categories.find((entry) => entry.category_code === code); }
  function activePeople() { return state.data.people.filter((person) => person.is_active); }
  function personOption(person) {
    return { key: personKey(person), label: person.display_name, sub: [person.person_group, person.employee_code].filter(Boolean).join(" · "), value: person };
  }

  function csv(name, rows) {
    const text = rows.map((row) => row.map((cell) => `"${String(cell ?? "").replace(/"/g, '""')}"`).join(",")).join("\r\n");
    const link = Object.assign(document.createElement("a"), { href: URL.createObjectURL(new Blob(["﻿" + text], { type: "text/csv" })), download: name });
    document.body.append(link); link.click(); link.remove();
    window.setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  }

  // ---------------------------------------------------------------- Pickers
  // A searchable list: native selects cannot be filtered on phones.

  function picker(id, options, placeholder) {
    pickers[id] = { options, value: null, placeholder };
    renderPicker(id);
  }

  function renderPicker(id, term = "") {
    const config = pickers[id];
    const root = $(id);
    if (config.value) {
      root.innerHTML = `<div class="stk-picked"><span>${esc(config.value.label)}${config.value.sub ? ` <small class="stk-muted">${esc(config.value.sub)}</small>` : ""}</span><button type="button" data-picker-clear>Change</button></div>`;
      return;
    }
    const words = term.toLowerCase().split(/\s+/).filter(Boolean);
    const list = config.options.filter((option) => words.every((word) => `${option.label} ${option.sub || ""}`.toLowerCase().includes(word))).slice(0, 60);
    root.innerHTML = `<input type="search" data-picker-search placeholder="${esc(config.placeholder)}" value="${esc(term)}" autocomplete="off">
      <div class="stk-picker-list">${list.map((option) => `<button type="button" data-picker-key="${esc(option.key)}"><span>${esc(option.label)}</span><small>${esc(option.sub || "")}</small></button>`).join("")
        || '<p class="stk-empty">No match.</p>'}</div>`;
  }

  function setPicker(id, key) {
    pickers[id].value = pickers[id].options.find((option) => option.key === key) || null;
    renderPicker(id);
    pickers[id].onChange?.(pickers[id].value);
  }

  function bindPicker(id) {
    const root = $(id);
    root.addEventListener("input", (event) => {
      if (!event.target.matches("[data-picker-search]")) return;
      const position = event.target.selectionStart;
      renderPicker(id, event.target.value);
      const input = root.querySelector("[data-picker-search]");
      input.focus(); input.setSelectionRange(position, position);
    });
    root.addEventListener("click", (event) => {
      const option = event.target.closest("[data-picker-key]");
      if (option) return setPicker(id, option.dataset.pickerKey);
      if (event.target.closest("[data-picker-clear]")) { setPicker(id, null); root.querySelector("[data-picker-search]")?.focus(); }
    });
  }

  // ---------------------------------------------------------------- Load

  async function load() {
    state.data = await rpc("get_stock_workspace");
    state.canOperate = !!state.data.can_operate;
    state.canManage = !!state.data.can_manage;
    state.answered = null;
    document.querySelectorAll("[data-operate]").forEach((element) => element.classList.toggle("hidden", !state.canOperate));
    document.querySelectorAll("[data-manage]").forEach((element) => element.classList.toggle("hidden", !state.canManage));
    renderAll();
  }

  function renderAll() {
    renderStats();
    renderOverview();
    renderRequests();
    renderItems();
    renderCount();
    renderPeople();
    renderLockers();
    renderUsage();
    renderHistoryItems();
  }

  function renderStats() {
    const { items, requests, lockers } = state.data;
    const active = items.filter((item) => item.active);
    const low = active.filter((item) => item.is_low).length;
    $("stkStats").innerHTML = `
      <div class="${requests.length ? "warn" : ""}"><b>${requests.length}</b><small>requests</small></div>
      <div class="${low ? "bad" : ""}"><b>${low}</b><small>low stock</small></div>
      <div><b>${active.length}</b><small>items</small></div>
      <div><b>${lockers.filter((locker) => locker.locker_status === "ASSIGNED").length}</b><small>keys out</small></div>`;
    $("tabRequestCount").textContent = requests.length;
    $("tabRequestCount").classList.toggle("hidden", !requests.length);
  }

  // ---------------------------------------------------------------- Overview

  function renderOverview() {
    const { requests, overdue_counts: overdue, pending_returns: returns, items, recent, settings } = state.data;
    $("ovRequests").innerHTML = requests.slice(0, 6).map((request) => `
      <li class="clickable" data-goto="requests"><div><strong>${esc(request.staff_name)}</strong>
        <small>${esc(request.lines.map((line) => `${qty(line.qty)} × ${line.item_name}${line.size ? ` (${line.size})` : ""}`).join(", "))}</small></div>
        ${pill((REQUEST[request.request_status] || REQUEST.REQUESTED).label, (REQUEST[request.request_status] || REQUEST.REQUESTED).tone)}</li>`).join("")
      || '<li class="stk-muted">No requests waiting.</li>';
    $("ovChemicalsHint").textContent = `Chemical usage comes from the counts. Count every ${settings.chemical_count_days} days.`;
    $("ovChemicals").innerHTML = overdue.slice(0, 8).map((item) => `
      <li><div><strong>${esc(item.item_name)}</strong><small>${item.last_counted_at ? `Last counted ${esc(date(item.last_counted_at))}` : "Never counted"}</small></div></li>`).join("")
      || '<li class="stk-muted">All chemicals were counted recently.</li>';
    $("ovReturns").innerHTML = returns.map((person) => `
      <li class="clickable" data-person="${esc(personKey(person))}"><div><strong>${esc(person.display_name)}</strong>
        <small>${esc([...person.locker_labels.map((label) => `Key ${label}`), ...person.ppe.map((item) => `${qty(item.qty)} × ${item.description}${item.size ? ` (${item.size})` : ""}`)].join(", "))}</small></div>
        ${pill("To collect", "warn")}</li>`).join("")
      || '<li class="stk-muted">Nobody who left still holds items.</li>';
    const low = items.filter((item) => item.is_low).sort((a, b) => a.item_name.localeCompare(b.item_name));
    $("ovLow").innerHTML = low.map((item) => `
      <li class="clickable" data-move="IN" data-item="${esc(item.item_id)}"><div><strong>${esc(item.item_name)}</strong><small>${esc(item.category_name)} · minimum ${qty(item.min_stock)} · ${esc(item.supplier || "no supplier")}</small></div>
        <span class="stk-qty low">${qty(item.stock_qty)} ${esc(item.unit)}</span></li>`).join("")
      || '<li class="stk-muted">No item is at or below its minimum.</li>';
    $("ovRecent").innerHTML = recent.slice(0, 12).map(movementLine).join("") || '<li class="stk-muted">No movements yet.</li>';
  }

  function movementLine(move) {
    const type = MOVE[move.movement_type] || MOVE.ADJUST;
    const change = Number(move.qty_change);
    const who = move.holder_name || move.customer_name || "";
    return `<li><div><strong>${esc(move.item_name)}</strong>
      <small>${esc(dateTime(move.recorded_at))} · ${esc(move.recorded_by_name || "—")}${who ? ` · for ${esc(who)}` : ""}</small></div>
      <span>${pill(type.label, type.tone)} <span class="stk-qty ${change >= 0 ? "plus" : "minus"}">${change > 0 ? "+" : ""}${qty(change)}</span></span></li>`;
  }

  // ---------------------------------------------------------------- Requests

  async function loadAnswered() {
    if (state.answered) return;
    const from = new Date(); from.setDate(from.getDate() - 90);
    const rows = await rpc("get_stock_history", { p_kind: "REQUESTS", p_from: isoDate(from), p_to: isoDate(new Date()), p_item_id: null, p_limit: 500 });
    state.answered = rows.filter((request) => !["REQUESTED", "APPROVED"].includes(request.request_status));
  }

  function renderRequests() {
    const source = state.requestFilter === "open" ? state.data.requests : (state.answered || []);
    const words = $("requestSearch").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const list = source.filter((request) => words.every((word) => `${request.staff_name} ${request.employee_code || ""} ${request.lines.map((line) => line.item_name).join(" ")}`.toLowerCase().includes(word)));
    if (state.requestFilter === "answered" && !state.answered) { $("requestList").innerHTML = '<p class="stk-empty">Loading…</p>'; return; }
    $("requestList").innerHTML = list.map(requestCard).join("")
      || `<p class="stk-empty">${state.requestFilter === "open" ? "No requests waiting. New requests from staff appear here." : "No answered requests in the last 90 days."}</p>`;
  }

  function requestCard(request) {
    const status = REQUEST[request.request_status] || REQUEST.REQUESTED;
    const open = ["REQUESTED", "APPROVED"].includes(request.request_status);
    const issued = request.request_status === "ISSUED";
    return `<article class="stk-request ${status.tone}">
      <div class="stk-request-head">
        <div><strong>${esc(request.staff_name)}</strong> <small>#${esc(request.request_number)}${request.employee_code ? ` · ${esc(request.employee_code)}` : ""} · asked ${esc(dateTime(request.created_at))}</small></div>
        ${pill(status.label, status.tone)}
      </div>
      <ul class="stk-request-lines">${request.lines.map((line) => `<li><span>${esc(line.item_name)}${line.size ? ` · size <b>${esc(line.size)}</b>` : ""}
        <small class="stk-muted">(${qty(line.stock_qty)} ${esc(line.unit)} in stock)</small></span>
        <b>${issued ? `${qty(line.issued_qty)} of ${qty(line.qty)}` : qty(line.qty)}</b></li>`).join("")}</ul>
      ${request.reason ? `<p class="stk-request-note">Reason: ${esc(request.reason)}</p>` : ""}
      ${request.decision_note ? `<p class="stk-request-note"><b>${esc(request.decided_by_name || "")}:</b> ${esc(request.decision_note)}</p>` : ""}
      ${!open && request.issued_at ? `<p class="stk-request-note">Handed over ${esc(dateTime(request.issued_at))} by ${esc(request.issued_by_name || "—")}</p>` : ""}
      ${open && state.canOperate ? `<div class="stk-request-actions">
        <button type="button" class="stk-button stk-ghost-red" data-request-action="REJECT" data-request="${esc(request.request_id)}">Decline</button>
        ${request.request_status === "REQUESTED" ? `<button type="button" class="stk-button" data-request-action="APPROVE" data-request="${esc(request.request_id)}">Approve, hand over later</button>` : ""}
        <button type="button" class="stk-button stk-green" data-request-action="ISSUE" data-request="${esc(request.request_id)}">Hand over now</button>
      </div>` : ""}
    </article>`;
  }

  function openIssue(requestId, mode) {
    const request = state.data.requests.find((entry) => entry.request_id === requestId);
    if (!request) return;
    state.issue = { request, mode };
    const titles = { ISSUE: ["HAND OVER", "Hand over", "stk-green"], APPROVE: ["APPROVE", "Approve", "stk-primary"], REJECT: ["DECLINE", "Decline request", "stk-red"] };
    const [kind, button, tone] = titles[mode];
    $("issueKind").textContent = kind;
    $("issueTitle").textContent = `${request.staff_name} · request #${request.request_number}`;
    $("issueMeta").textContent = `Asked ${dateTime(request.created_at)}${request.reason ? ` · ${request.reason}` : ""}`;
    $("issueSave").textContent = button;
    $("issueSave").className = `stk-button ${tone}`;
    $("issueHint").classList.toggle("hidden", mode !== "ISSUE");
    $("issueNoteLabel").innerHTML = mode === "REJECT" ? "Reason (the person sees it)" : 'Note for the person <em>(optional)</em>';
    $("issueNote").required = mode === "REJECT";
    $("issueNote").value = "";
    $("issueStatus").textContent = "";
    $("issueLines").innerHTML = request.lines.map((line) => mode !== "ISSUE"
      ? `<div class="stk-issue-line"><span><b>${esc(line.item_name)}</b>${line.size ? ` · size ${esc(line.size)}` : ""}</span><span></span><b class="num">${qty(line.qty)}</b></div>`
      : `<div class="stk-issue-line" data-line="${esc(line.line_id)}">
          <span><b>${esc(line.item_name)}</b><br><small class="stk-muted">${qty(line.stock_qty)} ${esc(line.unit)} in stock · asked ${qty(line.qty)}</small></span>
          ${line.size_options.length ? `<select data-issue-size aria-label="Size">${line.size_options.map((size) => `<option${size === line.size ? " selected" : ""}>${esc(size)}</option>`).join("")}</select>` : "<span></span>"}
          <input data-issue-qty type="number" min="0" max="${esc(line.qty)}" value="${esc(Math.min(Number(line.qty), Math.max(0, Math.floor(Number(line.stock_qty)))))}" aria-label="Quantity to hand over">
        </div>`).join("");
    $("issueDialog").showModal();
  }

  async function saveIssue(event) {
    event.preventDefault();
    const { request, mode } = state.issue;
    const lines = mode === "ISSUE" ? [...$("issueLines").querySelectorAll("[data-line]")].map((row) => ({
      line_id: Number(row.dataset.line),
      qty: Number(row.querySelector("[data-issue-qty]").value || 0),
      ...(row.querySelector("[data-issue-size]") ? { size: row.querySelector("[data-issue-size]").value } : {})
    })) : null;
    $("issueSave").disabled = true;
    $("issueStatus").textContent = "Saving…";
    try {
      await rpc("decide_stock_request", { p_request_id: request.request_id, p_decision: mode, p_note: $("issueNote").value.trim() || null, p_lines: lines, p_row_version: request.row_version });
      $("issueDialog").close();
      await load();
      message(mode === "ISSUE" ? `Handed over to ${request.staff_name}. Stock and their record were updated.` : mode === "APPROVE" ? `Request from ${request.staff_name} approved.` : `Request from ${request.staff_name} declined.`, "good");
    } catch (error) {
      $("issueStatus").textContent = friendly(error);
    } finally {
      $("issueSave").disabled = false;
    }
  }

  // ---------------------------------------------------------------- Items

  function filteredItems() {
    const words = $("itemSearch").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const area = $("itemArea").value;
    return state.data.items.filter((item) => ($("itemInactive").checked || item.active) && (!area || item.stock_area === area)
      && (!$("itemLowOnly").checked || item.is_low)
      && words.every((word) => `${item.item_name} ${item.item_code || ""} ${item.supplier || ""} ${item.category_name}`.toLowerCase().includes(word)));
  }

  function renderItems() {
    const list = filteredItems();
    const groups = state.data.categories.map((entry) => ({ entry, items: list.filter((item) => item.category_code === entry.category_code) })).filter((group) => group.items.length);
    $("itemRows").innerHTML = groups.map(({ entry, items }) => `<tr class="stk-group-row"><td colspan="7">${esc(entry.category_name)} · ${esc(AREAS[entry.stock_area])} <span class="stk-muted">(${items.length})</span></td></tr>`
      + items.map((item) => `<tr class="${item.active ? "" : "inactive"} ${item.is_low ? "low" : ""}">
        <td><strong>${esc(item.item_name)}</strong><small>${[item.item_code, item.location, item.requestable ? `Staff can request${item.size_options.length ? ` · ${item.size_options.join(", ")}` : ""}` : "", item.active ? "" : "Inactive"].filter(Boolean).map(esc).join(" · ")}</small></td>
        <td class="num"><span class="stk-qty ${item.is_low ? "low" : ""}">${qty(item.stock_qty)}</span> <small>${esc(item.unit)}</small></td>
        <td class="num">${qty(item.min_stock)}</td>
        <td class="optional">${esc(TRACK[item.track_by])}</td>
        <td class="optional">${esc(item.supplier || "—")}</td>
        <td class="num optional">${money(item.stock_value)}</td>
        <td><div class="stk-row-actions">${state.canOperate && item.active ? `
          <button type="button" class="stk-button" data-move="IN" data-item="${esc(item.item_id)}">Receive</button>
          ${item.track_by === "NONE" ? "" : `<button type="button" class="stk-button" data-move="OUT" data-item="${esc(item.item_id)}">Take</button>`}
          <button type="button" class="stk-button" data-move="ADJUST" data-item="${esc(item.item_id)}">Adjust</button>` : ""}
          <button type="button" class="stk-button" data-item-history="${esc(item.item_id)}">History</button>
          ${state.canManage ? `<button type="button" class="stk-button" data-item-edit="${esc(item.item_id)}">Edit</button>` : ""}</div></td>
      </tr>`).join("")).join("") || '<tr><td colspan="7"><p class="stk-empty">No items match.</p></td></tr>';
  }

  function exportItems() {
    csv(`stock-items-${isoDate(new Date())}.csv`, [["Item", "Code", "Category", "Area", "Stock", "Unit", "Minimum", "Low", "Unit price", "Value", "Supplier", "Location", "Booked to", "Staff can request", "Sizes", "Active", "Last count"],
      ...filteredItems().map((item) => [item.item_name, item.item_code, item.category_name, AREAS[item.stock_area], item.stock_qty, item.unit, item.min_stock, item.is_low ? "Yes" : "", item.unit_price, item.stock_value,
        item.supplier, item.location, TRACK[item.track_by], item.requestable ? "Yes" : "", item.size_options.join(" "), item.active ? "Yes" : "No", item.last_counted_at ? date(item.last_counted_at) : ""])]);
  }

  function openItemForm(itemId) {
    const item = itemId ? itemById(itemId) : null;
    state.editing = item;
    $("itemTitle").textContent = item ? `Edit ${item.item_name}` : "New item";
    $("itemCategory").innerHTML = state.data.categories.map((entry) => `<option value="${esc(entry.category_code)}">${esc(entry.category_name)} · ${esc(AREAS[entry.stock_area])}</option>`).join("");
    $("itemName").value = item?.item_name || "";
    $("itemCategory").value = item?.category_code || "UNIFORM";
    $("itemTrack").value = item?.track_by || category($("itemCategory").value).default_track_by;
    $("itemCode").value = item?.item_code || "";
    $("itemUnit").value = item?.unit || "unit";
    $("itemPrice").value = item?.unit_price ?? 0;
    $("itemStock").value = 0;
    $("itemMin").value = item?.min_stock ?? 0;
    $("itemLocation").value = item?.location || "";
    $("itemSupplier").value = item?.supplier || "";
    $("itemRequestable").checked = item ? item.requestable : category($("itemCategory").value).default_requestable;
    $("itemSizes").value = (item?.size_options || []).join(", ");
    $("itemActive").checked = item ? item.active : true;
    $("itemStockField").classList.toggle("hidden", !!item);
    $("itemActiveField").classList.toggle("hidden", !item);
    $("itemStatus").textContent = "";
    syncItemForm();
    $("itemDialog").showModal();
  }

  function syncItemForm() {
    const staff = $("itemTrack").value === "STAFF";
    $("itemRequestable").disabled = !staff;
    if (!staff) $("itemRequestable").checked = false;
    $("itemSizesField").classList.toggle("hidden", !staff);
  }

  async function saveItem(event) {
    event.preventDefault();
    const item = {
      item_id: state.editing?.item_id || null, item_name: $("itemName").value, category_code: $("itemCategory").value, track_by: $("itemTrack").value,
      item_code: $("itemCode").value, unit: $("itemUnit").value, unit_price: $("itemPrice").value, min_stock: $("itemMin").value,
      location: $("itemLocation").value, supplier: $("itemSupplier").value, requestable: $("itemRequestable").checked,
      size_options: $("itemSizes").value.split(/[,;\n]/).map((size) => size.trim()).filter(Boolean),
      ...(state.editing ? { active: $("itemActive").checked } : { stock_qty: $("itemStock").value })
    };
    $("itemStatus").textContent = "Saving…";
    try {
      await rpc("save_stock_item", { p_item: item, p_row_version: state.editing?.row_version ?? null });
      $("itemDialog").close();
      await load();
      message(`${item.item_name.trim()} was saved.`, "good");
    } catch (error) {
      $("itemStatus").textContent = friendly(error);
    }
  }

  // ---------------------------------------------------------------- Movements

  function openMove(type, itemId) {
    const active = state.data.items.filter((item) => item.active && (type !== "OUT" || item.track_by !== "NONE"));
    if (!active.length) return message("Add an item first.", "error");
    const config = MOVE[type];
    state.move = { type };
    $("moveKind").textContent = config.kind;
    $("moveTitle").textContent = `${config.label} item`;
    $("moveSave").className = `stk-button ${config.button}`;
    $("moveSave").textContent = `Confirm ${config.label.toLowerCase()}`;
    $("moveItem").innerHTML = active.map((item) => `<option value="${esc(item.item_id)}">${esc(item.item_name)} (${qty(item.stock_qty)} ${esc(item.unit)})</option>`).join("");
    $("moveItem").value = itemId && active.some((item) => item.item_id === itemId) ? itemId : active[0].item_id;
    $("moveQtyLabel").textContent = type === "ADJUST" ? "New total in stock" : "Quantity";
    $("moveNotesHint").textContent = type === "ADJUST" ? "(required: why)" : "(optional)";
    $("moveNotes").required = type === "ADJUST";
    $("movePo").value = ""; $("moveNotes").value = ""; $("moveSize").value = ""; $("moveStatus").textContent = "";
    picker("movePerson", activePeople().map(personOption), "Type the name…");
    picker("moveCustomer", state.data.customers.map((customer) => ({ key: customer.customer_id, label: customer.customer_name, value: customer })), "Type the customer name…");
    syncMove(true);
    $("moveDialog").showModal();
  }

  function syncMove(resetQty) {
    const item = itemById($("moveItem").value);
    const type = state.move.type;
    $("moveTitle").textContent = `${MOVE[type].label}: ${item.item_name}`;
    $("moveStock").textContent = `${qty(item.stock_qty)} ${item.unit} in stock · minimum ${qty(item.min_stock)}`;
    if (resetQty) $("moveQty").value = type === "ADJUST" ? item.stock_qty : 1;
    const out = type === "OUT";
    $("movePersonField").classList.toggle("hidden", !(out && item.track_by === "STAFF"));
    $("moveSizeField").classList.toggle("hidden", !(out && item.track_by === "STAFF" && item.stock_area === "PPE_UNIFORM"));
    $("moveCustomerField").classList.toggle("hidden", !(out && item.track_by === "CUSTOMER"));
    $("moveNoneHint").classList.toggle("hidden", !(out && item.track_by === "NONE"));
    $("movePoField").classList.toggle("hidden", type !== "IN");
  }

  async function saveMove(event) {
    event.preventDefault();
    const item = itemById($("moveItem").value);
    const type = state.move.type;
    const person = item.track_by === "STAFF" && type === "OUT" ? pickers.movePerson.value?.value : null;
    const customer = item.track_by === "CUSTOMER" && type === "OUT" ? pickers.moveCustomer.value?.value : null;
    if (type === "OUT" && item.track_by === "STAFF" && !person) return void ($("moveStatus").textContent = "Select who is taking the item.");
    if (type === "OUT" && item.track_by === "CUSTOMER" && !customer) return void ($("moveStatus").textContent = "Select the customer.");
    $("moveSave").disabled = true;
    $("moveStatus").textContent = "Saving…";
    try {
      const result = await rpc("record_stock_movement", { p_movement: {
        item_id: item.item_id, movement_type: type, qty: $("moveQty").value, po_number: $("movePo").value, notes: $("moveNotes").value,
        size: $("moveSize").value, staff_id: person?.staff_id || null, driver_id: person?.driver_id || null, customer_id: customer?.customer_id || null
      } });
      $("moveDialog").close();
      await load();
      const low = result?.item?.is_low;
      message(`${MOVE[type].label} saved. ${item.item_name}: ${qty(result.stock_after)} ${item.unit} in stock.${low ? " This item is now at or below its minimum." : ""}`, low ? "error" : "good");
    } catch (error) {
      $("moveStatus").textContent = friendly(error);
    } finally {
      $("moveSave").disabled = false;
    }
  }

  // ---------------------------------------------------------------- Count

  function countItems() {
    const words = $("countSearch").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const overdue = new Set(state.data.overdue_counts.map((item) => item.item_id));
    return state.data.items.filter((item) => item.active
      && (state.countCategory === "" || (state.countCategory === "DUE" ? overdue.has(item.item_id) : item.stock_area === state.countCategory))
      && words.every((word) => item.item_name.toLowerCase().includes(word)));
  }

  function renderCount() {
    const due = state.data.overdue_counts.length;
    $("countChips").innerHTML = [["", "All"], ["DUE", `Chemicals due (${due})`], ...Object.entries(AREAS)].map(([code, label]) =>
      `<button type="button" data-count-category="${esc(code)}" class="${state.countCategory === code ? "active" : ""}">${esc(label)}</button>`).join("");
    const list = countItems();
    $("countRows").innerHTML = list.map((item) => {
      const value = state.counts.get(item.item_id);
      const diff = value === undefined ? null : Number(value) - Number(item.stock_qty);
      return `<tr><td><strong>${esc(item.item_name)}</strong><small>${esc(item.category_name)} · ${esc(item.unit)}</small></td>
        <td class="num">${qty(item.stock_qty)}</td>
        <td class="num"><input class="stk-count-input ${value === undefined ? "" : "changed"}" data-count="${esc(item.item_id)}" type="number" min="0" step="any" inputmode="decimal" value="${value ?? ""}" aria-label="Counted ${esc(item.item_name)}" ${state.canOperate ? "" : "disabled"}></td>
        <td class="num" data-diff="${esc(item.item_id)}">${diff === null ? "" : `<span class="stk-qty ${diff > 0 ? "plus" : diff < 0 ? "minus" : ""}">${diff > 0 ? "+" : ""}${qty(diff)}</span>`}</td>
        <td class="optional">${esc(item.last_counted_at ? date(item.last_counted_at) : "Never")}</td></tr>`;
    }).join("") || '<tr><td colspan="5"><p class="stk-empty">No items match.</p></td></tr>';
    updateCountSummary();
  }

  function updateCountSummary() {
    const entries = [...state.counts.entries()];
    const changed = entries.filter(([id, value]) => Number(value) !== Number(itemById(id)?.stock_qty)).length;
    $("countSummary").textContent = entries.length ? `${entries.length} counted · ${changed} with a difference` : "";
    $("countSave").disabled = !entries.length || !state.canOperate;
  }

  function onCountInput(event) {
    const input = event.target.closest("[data-count]");
    if (!input) return;
    const item = itemById(input.dataset.count);
    if (input.value === "") state.counts.delete(item.item_id); else state.counts.set(item.item_id, input.value);
    input.classList.toggle("changed", input.value !== "");
    const diff = input.value === "" ? null : Number(input.value) - Number(item.stock_qty);
    document.querySelector(`[data-diff="${CSS.escape(item.item_id)}"]`).innerHTML = diff === null ? "" : `<span class="stk-qty ${diff > 0 ? "plus" : diff < 0 ? "minus" : ""}">${diff > 0 ? "+" : ""}${qty(diff)}</span>`;
    updateCountSummary();
  }

  async function saveCount() {
    const entries = [...state.counts.entries()].map(([item_id, counted_qty]) => ({ item_id, counted_qty }));
    if (!entries.length || !window.confirm(`Save the count of ${entries.length} item${entries.length === 1 ? "" : "s"}? Stock will be set to the counted quantities.`)) return;
    $("countSave").disabled = true;
    try {
      const session = await rpc("save_stock_count", { p_entries: entries, p_notes: $("countNotes").value.trim() || null });
      state.counts.clear();
      $("countNotes").value = "";
      await load();
      message(`Count ${session.session_code} saved: ${session.items_counted} counted, ${session.items_adjusted} adjusted (${money(session.variance_value)}), ${session.consumption_lines} chemical usage lines (${money(session.consumption_value)}).`, "good");
    } catch (error) {
      message(friendly(error), "error");
      updateCountSummary();
    }
  }

  // ---------------------------------------------------------------- People

  function renderPeople() {
    const words = $("peopleSearch").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const list = state.data.people.filter((person) => (state.peopleFilter === "all" ? person.is_active
      : state.peopleFilter === "leavers" ? !person.is_active : (Number(person.ppe_items) > 0 || person.locker_labels.length))
      && words.every((word) => `${person.display_name} ${person.employee_code || ""}`.toLowerCase().includes(word)));
    $("peopleList").innerHTML = list.map((person) => `
      <button type="button" class="stk-card ${person.is_active ? "" : "inactive"}" data-person="${esc(personKey(person))}">
        <strong>${esc(person.display_name)}</strong>
        <small>${esc([person.person_group, person.employee_code, person.is_active ? "" : "Left the company"].filter(Boolean).join(" · "))}</small>
        <span class="stk-tags">${Number(person.ppe_items) ? pill(`${qty(person.ppe_items)} PPE / uniform`, "approved") : ""}${person.locker_labels.map((label) => pill(`Key ${label}`, person.is_active ? "muted" : "warn")).join("")}</span>
      </button>`).join("") || '<p class="stk-empty">Nobody matches.</p>';
  }

  async function openPerson(key) {
    const person = state.data.people.find((entry) => personKey(entry) === key);
    if (!person) return;
    state.person = person;
    $("personTitle").textContent = person.display_name;
    $("personKind").textContent = person.person_group.toUpperCase();
    $("personMeta").textContent = [person.employee_code, person.is_active ? "Active" : "Left the company"].filter(Boolean).join(" · ");
    $("personBody").innerHTML = '<p class="stk-empty">Loading…</p>';
    $("personIssue").classList.toggle("hidden", !state.canOperate);
    $("personDialog").showModal();
    try {
      const profile = await rpc("get_stock_person", { p_staff_id: person.staff_id, p_driver_id: person.driver_id });
      $("personBody").innerHTML = `
        <p class="stk-section-title">Currently holding</p>
        <ul class="stk-list">${[
          ...profile.lockers.map((locker) => `<li><div><strong>Locker key ${esc(locker.label)}</strong><small>Since ${esc(date(locker.assigned_at))}</small></div>
            ${state.canOperate ? `<button type="button" class="stk-button" data-locker-return="${esc(locker.locker_id)}">Key returned</button>` : ""}</li>`),
          ...profile.holding.map((item) => `<li><div><strong>${qty(item.qty)} × ${esc(item.description)}${item.size ? ` · size ${esc(item.size)}` : ""}</strong>
            <small>${esc(item.item_type)} · first ${esc(date(item.first_issued_at))} · last ${esc(date(item.last_issued_at))}</small></div></li>`)
        ].join("") || '<li class="stk-muted">Nothing.</li>'}</ul>
        <p class="stk-section-title">Uniform &amp; PPE history</p>
        <ul class="stk-list">${profile.ppe_log.map((event) => `<li><div><strong>${esc(event.description)}${event.size ? ` · size ${esc(event.size)}` : ""}</strong>
          <small>${esc(dateTime(event.recorded_at))} · ${esc(event.recorded_by_name || "—")}${event.notes ? ` · ${esc(event.notes)}` : ""}</small></div>
          ${pill(`${event.ppe_action === "ISSUED" ? "Issued" : "Returned"} ${qty(event.qty)}`, event.ppe_action === "ISSUED" ? "issued" : "muted")}</li>`).join("") || '<li class="stk-muted">No records.</li>'}</ul>
        <p class="stk-section-title">Requests</p>
        <ul class="stk-list">${profile.requests.map((request) => `<li><div><strong>#${esc(request.request_number)} · ${esc(request.lines.map((line) => `${qty(line.qty)} × ${line.item_name}${line.size ? ` (${line.size})` : ""}`).join(", "))}</strong>
          <small>${esc(dateTime(request.created_at))}</small></div>${pill((REQUEST[request.request_status] || REQUEST.REQUESTED).label, (REQUEST[request.request_status] || REQUEST.REQUESTED).tone)}</li>`).join("") || '<li class="stk-muted">No requests.</li>'}</ul>
        <p class="stk-section-title">Other stock taken</p>
        <ul class="stk-list">${profile.stock_taken.map((move) => `<li><div><strong>${esc(move.item_name)}</strong><small>${esc(dateTime(move.recorded_at))}${move.notes ? ` · ${esc(move.notes)}` : ""}</small></div>
          <span class="stk-qty">${qty(Math.abs(move.qty_change))} ${esc(move.unit)}</span></li>`).join("") || '<li class="stk-muted">Nothing.</li>'}</ul>
        <p class="stk-section-title">Locker key history</p>
        <ul class="stk-list">${profile.locker_log.map((event) => `<li><div><strong>Key ${esc(event.label)}</strong><small>${esc(dateTime(event.recorded_at))} · ${esc(event.recorded_by_name || "—")}</small></div>
          ${pill(event.locker_action === "ASSIGNED" ? "Received" : "Returned", event.locker_action === "ASSIGNED" ? "approved" : "muted")}</li>`).join("") || '<li class="stk-muted">No records.</li>'}</ul>`;
    } catch (error) {
      $("personBody").innerHTML = `<p class="stk-empty error">${esc(friendly(error))}</p>`;
    }
  }

  // ---------------------------------------------------------------- PPE

  async function openPpe(person, action = "ISSUED") {
    state.ppeAction = action;
    const options = (action === "ISSUED" ? activePeople() : state.data.people).map(personOption);
    picker("ppePerson", options, "Type the name…");
    pickers.ppePerson.onChange = () => loadHeld();
    if (person) setPicker("ppePerson", personKey(person));
    const items = state.data.items.filter((item) => item.active && item.track_by === "STAFF");
    $("ppeItem").innerHTML = '<option value="">Not a stock item (type a description)</option>'
      + items.map((item) => `<option value="${esc(item.item_id)}">${esc(item.item_name)} · ${esc(item.category_name)} (${qty(item.stock_qty)} in stock)</option>`).join("");
    $("ppeItem").value = items.find((item) => item.stock_area === "PPE_UNIFORM")?.item_id || "";
    ["ppeDesc", "ppeSize", "ppeNotes"].forEach((id) => { $(id).value = ""; });
    $("ppeQty").value = 1;
    $("ppeRestock").checked = false;
    $("ppeStatus").textContent = "";
    syncPpe();
    if (!$("ppeDialog").open) $("ppeDialog").showModal();
    if (person) await loadHeld();
  }

  function syncPpe() {
    const returning = state.ppeAction === "RETURNED";
    document.querySelectorAll("[data-ppe-action]").forEach((button) => button.classList.toggle("active", button.dataset.ppeAction === state.ppeAction));
    $("ppeTitle").textContent = returning ? "Register a return" : "Issue to a person";
    $("ppeHeldField").classList.toggle("hidden", !returning);
    $("ppeItemField").classList.toggle("hidden", returning);
    const item = itemById($("ppeItem").value);
    $("ppeFreeFields").classList.toggle("hidden", returning || !!item);
    $("ppeRestockField").classList.toggle("hidden", !returning || !state.ppeHeld?.item_id);
    $("ppeSizeList").innerHTML = (item?.size_options || []).map((size) => `<option value="${esc(size)}">`).join("");
  }

  async function loadHeld() {
    const person = pickers.ppePerson.value?.value;
    state.ppeHeldList = [];
    state.ppeHeld = null;
    $("ppeHeld").innerHTML = '<option value="">Choose the person first</option>';
    if (person) {
      try {
        const profile = await rpc("get_stock_person", { p_staff_id: person.staff_id, p_driver_id: person.driver_id });
        state.ppeHeldList = profile.holding.map((held) => ({ ...held, item_id: state.data.items.find((item) => item.item_name.toLowerCase() === String(held.description).toLowerCase())?.item_id || null }));
        $("ppeHeld").innerHTML = state.ppeHeldList.map((held, index) => `<option value="${index}">${esc(held.description)}${held.size ? ` · size ${esc(held.size)}` : ""} (holds ${qty(held.qty)})</option>`).join("")
          || '<option value="">This person holds no uniform or PPE</option>';
        selectHeld();
      } catch (error) {
        $("ppeStatus").textContent = friendly(error);
      }
    }
    syncPpe();
  }

  function selectHeld() {
    state.ppeHeld = state.ppeHeldList[Number($("ppeHeld").value)] || null;
    if (state.ppeHeld && state.ppeAction === "RETURNED") {
      $("ppeSize").value = state.ppeHeld.size || "";
      $("ppeQty").value = Math.max(1, Math.min(Number(state.ppeHeld.qty), 50));
    }
    syncPpe();
  }

  async function savePpe(event) {
    event.preventDefault();
    const person = pickers.ppePerson.value?.value;
    if (!person) return void ($("ppeStatus").textContent = "Select the person.");
    const returning = state.ppeAction === "RETURNED";
    if (returning && !state.ppeHeld) return void ($("ppeStatus").textContent = "Choose the item being returned.");
    const payload = { staff_id: person.staff_id, driver_id: person.driver_id, ppe_action: state.ppeAction, qty: $("ppeQty").value, size: $("ppeSize").value, notes: $("ppeNotes").value };
    if (returning) Object.assign(payload, state.ppeHeld.item_id ? { item_id: state.ppeHeld.item_id, restock: $("ppeRestock").checked } : { item_type: state.ppeHeld.item_type, description: state.ppeHeld.description }, { size: state.ppeHeld.size || "" });
    else if ($("ppeItem").value) payload.item_id = $("ppeItem").value;
    else Object.assign(payload, { item_type: $("ppeType").value, description: $("ppeDesc").value });
    $("ppeStatus").textContent = "Saving…";
    try {
      await rpc("record_ppe_event", { p_event: payload });
      $("ppeDialog").close();
      await load();
      message(`${returning ? "Return" : "Issue"} registered for ${person.display_name}.`, "good");
    } catch (error) {
      $("ppeStatus").textContent = friendly(error);
    }
  }

  // ---------------------------------------------------------------- Lockers

  function renderLockers() {
    const active = new Map(state.data.people.map((person) => [personKey(person), person.is_active]));
    const words = $("lockerSearch").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const list = state.data.lockers.filter((locker) => {
      const leaver = locker.locker_status === "ASSIGNED" && active.get(locker.staff_id || locker.driver_id) === false;
      return (state.lockerFilter === "all" || (state.lockerFilter === "leavers" ? leaver : locker.locker_status === state.lockerFilter))
        && words.every((word) => `${locker.label} ${locker.holder_name || ""}`.toLowerCase().includes(word));
    });
    $("lockerList").innerHTML = list.map((locker) => {
      const leaver = locker.locker_status === "ASSIGNED" && active.get(locker.staff_id || locker.driver_id) === false;
      return `<button type="button" class="stk-locker ${leaver ? "leaver" : locker.locker_status.toLowerCase()}" data-locker="${esc(locker.locker_id)}">
        <strong>${esc(locker.label)}</strong>
        <small>${locker.locker_status === "ASSIGNED" ? esc(locker.holder_name) : locker.locker_status === "AVAILABLE" ? "Available" : "Out of service"}</small>
        ${leaver ? '<small>Left the company</small>' : locker.assigned_at ? `<small>Since ${esc(date(locker.assigned_at))}</small>` : ""}
      </button>`;
    }).join("") || '<p class="stk-empty">No lockers match.</p>';
  }

  async function openLocker(lockerId) {
    const locker = state.data.lockers.find((entry) => entry.locker_id === lockerId);
    if (!locker) return;
    state.locker = locker;
    const assigned = locker.locker_status === "ASSIGNED";
    $("lockerTitle").textContent = `Locker ${locker.label}`;
    $("lockerMeta").textContent = assigned ? `Held by ${locker.holder_name} since ${date(locker.assigned_at)}` : locker.locker_status === "AVAILABLE" ? "Available" : "Out of service";
    $("lockerPersonField").classList.toggle("hidden", locker.locker_status !== "AVAILABLE");
    picker("lockerPerson", activePeople().map(personOption), "Type the name…");
    $("lockerSave").textContent = assigned ? "Key returned" : "Assign key";
    $("lockerSave").classList.toggle("hidden", !state.canOperate || locker.locker_status === "OUT_OF_SERVICE");
    $("lockerService").textContent = locker.locker_status === "OUT_OF_SERVICE" ? "Back in service" : "Out of service";
    $("lockerService").classList.toggle("hidden", !state.canManage || assigned);
    $("lockerNotes").value = "";
    $("lockerStatus").textContent = "";
    $("lockerLog").innerHTML = "";
    $("lockerDialog").showModal();
    try {
      const from = new Date(); from.setFullYear(from.getFullYear() - 2);
      const log = (await rpc("get_stock_history", { p_kind: "LOCKERS", p_from: isoDate(from), p_to: isoDate(new Date()), p_item_id: null, p_limit: 2000 })).filter((event) => event.locker_id === locker.locker_id).slice(0, 10);
      $("lockerLog").innerHTML = log.length ? `<p class="stk-section-title">History</p><ul class="stk-list">${log.map((event) => `<li><div><strong>${esc(event.holder_name || event.locker_action)}</strong>
        <small>${esc(dateTime(event.recorded_at))} · ${esc(event.recorded_by_name || "—")}${event.notes ? ` · ${esc(event.notes)}` : ""}</small></div>${pill(event.locker_action.replace(/_/g, " ").toLowerCase(), event.locker_action === "ASSIGNED" ? "approved" : "muted")}</li>`).join("")}</ul>` : "";
    } catch (_) { /* the history is optional */ }
  }

  async function lockerAction(action) {
    const locker = state.locker;
    const person = pickers.lockerPerson.value?.value;
    if (action === "ASSIGN" && !person) return void ($("lockerStatus").textContent = "Select who receives the key.");
    $("lockerStatus").textContent = "Saving…";
    try {
      await rpc("record_locker_action", { p_locker_id: locker.locker_id, p_action: action, p_staff_id: person?.staff_id || null, p_driver_id: person?.driver_id || null,
        p_notes: $("lockerNotes").value.trim() || null, p_row_version: locker.row_version });
      $("lockerDialog").close();
      await load();
      message(action === "ASSIGN" ? `Key ${locker.label} given to ${person.display_name}.` : action === "RETURN" ? `Key ${locker.label} returned.` : `Locker ${locker.label} updated.`, "good");
    } catch (error) {
      $("lockerStatus").textContent = friendly(error);
    }
  }

  async function returnLockerFromPerson(lockerId) {
    const locker = state.data.lockers.find((entry) => entry.locker_id === lockerId);
    if (!locker || !window.confirm(`Register that key ${locker.label} was returned?`)) return;
    try {
      await rpc("record_locker_action", { p_locker_id: locker.locker_id, p_action: "RETURN", p_staff_id: null, p_driver_id: null, p_notes: null, p_row_version: locker.row_version });
      await load();
      if (state.person) await openPerson(personKey(state.person));
      message(`Key ${locker.label} returned.`, "good");
    } catch (error) {
      message(friendly(error), "error");
    }
  }

  async function addLockers(event) {
    event.preventDefault();
    const labels = $("lockersAddLabels").value.split(/[,;\n]/).map((label) => label.trim()).filter(Boolean);
    const from = Number($("lockersFrom").value), to = Number($("lockersTo").value);
    if (from && to && to >= from) {
      const width = String(to).length < 2 ? 2 : String(to).length;
      for (let number = from; number <= to; number += 1) labels.push(`${$("lockersPrefix").value.trim()}${String(number).padStart(width, "0")}`);
    }
    if (!labels.length) return void ($("lockersAddStatus").textContent = "Enter labels or a range.");
    try {
      const result = await rpc("add_stock_lockers", { p_labels: labels });
      $("lockersAddDialog").close();
      await load();
      message(`${result.added} locker${result.added === 1 ? "" : "s"} added${result.skipped ? `, ${result.skipped} already existed` : ""}.`, "good");
    } catch (error) {
      $("lockersAddStatus").textContent = friendly(error);
    }
  }

  // ---------------------------------------------------------------- Usage

  function renderUsage() {
    const area = $("usageArea").value;
    $("usageHint").textContent = `Average use per week over the last ${state.data.settings.consumption_weeks} weeks and how many weeks of stock are left. For chemicals this comes from the counts.`;
    const list = state.data.items.filter((item) => item.active && (!area || item.stock_area === area))
      .sort((a, b) => (a.weeks_cover ?? 999) - (b.weeks_cover ?? 999) || a.item_name.localeCompare(b.item_name));
    $("usageRows").innerHTML = list.map((item) => {
      const cover = item.weeks_cover;
      const tone = cover === null || cover === undefined ? "" : cover <= 2 ? "low" : "";
      return `<tr><td><strong>${esc(item.item_name)}</strong><small>${esc(item.category_name)}</small></td>
        <td class="num">${qty(item.stock_qty)} <small>${esc(item.unit)}</small></td>
        <td class="num">${Number(item.per_week) ? qty(item.per_week) : "—"}</td>
        <td class="num"><span class="stk-qty ${tone}">${cover === null || cover === undefined ? "—" : qty(cover)}</span></td>
        <td class="optional">${esc(item.supplier || "—")}</td>
        <td class="optional">${item.track_by === "NONE" ? esc(item.last_counted_at ? `${date(item.last_counted_at)} (${item.days_since_count} d)` : "Never") : "—"}</td></tr>`;
    }).join("") || '<tr><td colspan="6"><p class="stk-empty">No items.</p></td></tr>';
  }

  // ---------------------------------------------------------------- History

  function renderHistoryItems() {
    const current = $("historyItem").value;
    $("historyItem").innerHTML = '<option value="">All items</option>' + state.data.items.map((item) => `<option value="${esc(item.item_id)}">${esc(item.item_name)}</option>`).join("");
    $("historyItem").value = current;
  }

  const HISTORY = {
    MOVEMENTS: {
      head: ["When", "Item", "Type", "Change", "Stock after", "For", "By", "Notes"],
      row: (m) => [dateTime(m.recorded_at), m.item_name, (MOVE[m.movement_type] || {}).label || m.movement_type, qty(m.qty_change), qty(m.stock_after), m.holder_name || m.customer_name || "", m.recorded_by_name || "", [m.po_number && `PO ${m.po_number}`, m.notes].filter(Boolean).join(" · ")]
    },
    PPE: {
      head: ["When", "Person", "Action", "Item", "Size", "Qty", "By", "Notes"],
      row: (e) => [dateTime(e.recorded_at), e.holder_name, e.ppe_action === "ISSUED" ? "Issued" : "Returned", `${e.description} (${e.item_type})`, e.size || "", qty(e.qty), e.recorded_by_name || "", e.notes || ""]
    },
    LOCKERS: {
      head: ["When", "Locker", "Action", "Person", "By", "Notes"],
      row: (e) => [dateTime(e.recorded_at), e.label, e.locker_action.replace(/_/g, " ").toLowerCase(), e.holder_name || "", e.recorded_by_name || "", e.notes || ""]
    },
    COUNTS: {
      head: ["When", "Count", "By", "Items", "Adjusted", "Difference €", "Chemical usage €", "Details"],
      row: (s) => [dateTime(s.counted_at), s.session_code, s.counted_by_name || "", s.items_counted, s.items_adjusted, money(s.variance_value), money(s.consumption_value),
        (s.lines || []).filter((line) => Number(line.variance_qty)).map((line) => `${line.item_name} ${Number(line.variance_qty) > 0 ? "+" : ""}${qty(line.variance_qty)}`).join(", ")]
    },
    REQUESTS: {
      head: ["Asked", "#", "Person", "Items", "Status", "Answered by", "Note"],
      row: (r) => [dateTime(r.created_at), r.request_number, r.staff_name, r.lines.map((line) => `${qty(line.qty)} × ${line.item_name}${line.size ? ` (${line.size})` : ""}`).join(", "), (REQUEST[r.request_status] || {}).label || r.request_status, r.issued_by_name || r.decided_by_name || "", r.decision_note || ""]
    }
  };

  async function loadHistory() {
    state.historyKind = $("historyKind").value;
    $("historyItem").disabled = !["MOVEMENTS", "PPE"].includes(state.historyKind);
    $("historyRows").innerHTML = '<tr><td><p class="stk-empty">Loading…</p></td></tr>';
    try {
      state.historyRows = await rpc("get_stock_history", { p_kind: state.historyKind, p_from: $("historyFrom").value || null, p_to: $("historyTo").value || null,
        p_item_id: $("historyItem").disabled ? null : ($("historyItem").value || null), p_limit: 2000 });
      const config = HISTORY[state.historyKind];
      $("historyHead").innerHTML = `<tr>${config.head.map((cell) => `<th>${esc(cell)}</th>`).join("")}</tr>`;
      $("historyRows").innerHTML = state.historyRows.map((row) => `<tr>${config.row(row).map((cell) => `<td>${esc(cell)}</td>`).join("")}</tr>`).join("")
        || `<tr><td colspan="${config.head.length}"><p class="stk-empty">Nothing in this period.</p></td></tr>`;
    } catch (error) {
      $("historyRows").innerHTML = `<tr><td><p class="stk-empty error">${esc(friendly(error))}</p></td></tr>`;
    }
  }

  function exportHistory() {
    const config = HISTORY[state.historyKind];
    csv(`stock-${state.historyKind.toLowerCase()}-${isoDate(new Date())}.csv`, [config.head, ...state.historyRows.map(config.row)]);
  }

  // ---------------------------------------------------------------- Tabs

  async function showTab(tab) {
    if (!document.querySelector(`[data-panel="${tab}"]`)) tab = "overview";
    state.tab = tab;
    document.querySelectorAll("#stkTabs [data-tab]").forEach((button) => button.classList.toggle("active", button.dataset.tab === tab));
    document.querySelectorAll("[data-panel]").forEach((panel) => panel.classList.toggle("hidden", panel.dataset.panel !== tab));
    try { history.replaceState(null, "", `#${tab}`); } catch (_) { /* optional */ }
    if (tab === "history" && !state.historyRows.length) await loadHistory();
  }

  function onGlobalClick(event) {
    const target = event.target;
    const go = target.closest("[data-goto]");
    if (go) return showTab(go.dataset.goto);
    const move = target.closest("[data-move]");
    if (move && state.canOperate) return openMove(move.dataset.move, move.dataset.item);
    const quick = target.closest("[data-quick]");
    if (quick) {
      const action = quick.dataset.quick;
      if (action === "count" || action === "chemicals") { state.countCategory = action === "chemicals" ? "DUE" : ""; renderCount(); return showTab("count"); }
      if (action === "ppe") return openPpe(null, "ISSUED");
      return openMove(action);
    }
    const person = target.closest("[data-person]");
    if (person) return openPerson(person.dataset.person);
    const locker = target.closest("[data-locker]");
    if (locker) return openLocker(locker.dataset.locker);
    const lockerReturn = target.closest("[data-locker-return]");
    if (lockerReturn) return returnLockerFromPerson(lockerReturn.dataset.lockerReturn);
    const request = target.closest("[data-request-action]");
    if (request) return openIssue(request.dataset.request, request.dataset.requestAction);
    const edit = target.closest("[data-item-edit]");
    if (edit) return openItemForm(edit.dataset.itemEdit);
    const itemHistory = target.closest("[data-item-history]");
    if (itemHistory) {
      $("historyKind").value = "MOVEMENTS";
      $("historyItem").value = itemHistory.dataset.itemHistory;
      $("historyFrom").value = "";
      showTab("history").then(loadHistory);
    }
  }

  function bind() {
    document.addEventListener("click", onGlobalClick);
    document.querySelectorAll("dialog [data-close]").forEach((button) => button.addEventListener("click", () => button.closest("dialog").close()));
    document.querySelectorAll("dialog").forEach((dialog) => dialog.addEventListener("click", (event) => { if (event.target === dialog) dialog.close(); }));
    $("stkTabs").addEventListener("click", (event) => { const button = event.target.closest("[data-tab]"); if (button) showTab(button.dataset.tab); });
    ["movePerson", "moveCustomer", "ppePerson", "lockerPerson"].forEach(bindPicker);

    document.querySelectorAll("[data-request-filter]").forEach((button) => button.addEventListener("click", async () => {
      state.requestFilter = button.dataset.requestFilter;
      document.querySelectorAll("[data-request-filter]").forEach((item) => item.classList.toggle("active", item === button));
      renderRequests();
      if (state.requestFilter === "answered") {
        try { await loadAnswered(); } catch (error) { message(friendly(error), "error"); }
        renderRequests();
      }
    }));
    $("requestSearch").addEventListener("input", renderRequests);
    $("issueForm").addEventListener("submit", saveIssue);

    ["itemSearch", "itemArea", "itemLowOnly", "itemInactive"].forEach((id) => $(id).addEventListener(id === "itemSearch" ? "input" : "change", renderItems));
    $("itemExport").addEventListener("click", exportItems);
    $("itemAdd").addEventListener("click", () => openItemForm(null));
    $("itemCategory").addEventListener("change", () => {
      const entry = category($("itemCategory").value);
      if (!state.editing) { $("itemTrack").value = entry.default_track_by; $("itemRequestable").checked = entry.default_requestable; }
      syncItemForm();
    });
    $("itemTrack").addEventListener("change", syncItemForm);
    $("itemForm").addEventListener("submit", saveItem);

    $("moveItem").addEventListener("change", () => syncMove(true));
    document.querySelectorAll("[data-step]").forEach((button) => button.addEventListener("click", () => {
      $("moveQty").value = Math.max(0, Number($("moveQty").value || 0) + Number(button.dataset.step));
    }));
    $("moveForm").addEventListener("submit", saveMove);

    $("countChips").addEventListener("click", (event) => { const chip = event.target.closest("[data-count-category]"); if (chip) { state.countCategory = chip.dataset.countCategory; renderCount(); } });
    $("countSearch").addEventListener("input", renderCount);
    $("countRows").addEventListener("input", onCountInput);
    $("countSave").addEventListener("click", saveCount);

    document.querySelectorAll("[data-people-filter]").forEach((button) => button.addEventListener("click", () => {
      state.peopleFilter = button.dataset.peopleFilter;
      document.querySelectorAll("[data-people-filter]").forEach((item) => item.classList.toggle("active", item === button));
      renderPeople();
    }));
    $("peopleSearch").addEventListener("input", renderPeople);
    $("personIssue").addEventListener("click", () => { const person = state.person; $("personDialog").close(); openPpe(person, person.is_active ? "ISSUED" : "RETURNED"); });

    document.querySelectorAll("[data-ppe-action]").forEach((button) => button.addEventListener("click", () => openPpe(pickers.ppePerson?.value?.value || null, button.dataset.ppeAction)));
    $("ppeItem").addEventListener("change", syncPpe);
    $("ppeHeld").addEventListener("change", selectHeld);
    $("ppeForm").addEventListener("submit", savePpe);

    document.querySelectorAll("[data-locker-filter]").forEach((button) => button.addEventListener("click", () => {
      state.lockerFilter = button.dataset.lockerFilter;
      document.querySelectorAll("[data-locker-filter]").forEach((item) => item.classList.toggle("active", item === button));
      renderLockers();
    }));
    $("lockerSearch").addEventListener("input", renderLockers);
    $("lockerForm").addEventListener("submit", (event) => { event.preventDefault(); lockerAction(state.locker.locker_status === "ASSIGNED" ? "RETURN" : "ASSIGN"); });
    $("lockerService").addEventListener("click", () => lockerAction(state.locker.locker_status === "OUT_OF_SERVICE" ? "BACK_IN_SERVICE" : "OUT_OF_SERVICE"));
    $("lockerAdd").addEventListener("click", () => { $("lockersAddForm").reset(); $("lockersAddStatus").textContent = ""; $("lockersAddDialog").showModal(); });
    $("lockersAddForm").addEventListener("submit", addLockers);

    $("settingsOpen").addEventListener("click", () => {
      $("setCountDays").value = state.data.settings.chemical_count_days;
      $("setWeeks").value = state.data.settings.consumption_weeks;
      $("settingsStatus").textContent = "";
      $("settingsDialog").showModal();
    });
    $("settingsForm").addEventListener("submit", async (event) => {
      event.preventDefault();
      try {
        await rpc("save_stock_settings", { p_settings: { chemical_count_days: $("setCountDays").value, consumption_weeks: $("setWeeks").value } });
        $("settingsDialog").close();
        await load();
        message("Settings saved.", "good");
      } catch (error) {
        $("settingsStatus").textContent = friendly(error);
      }
    });

    $("usageArea").addEventListener("change", renderUsage);
    $("historyLoad").addEventListener("click", loadHistory);
    $("historyKind").addEventListener("change", loadHistory);
    $("historyExport").addEventListener("click", exportHistory);
    // The sidebar links to views of this page by hash.
    window.addEventListener("hashchange", () => { if (state.data && location.hash.slice(1) !== state.tab) showTab(location.hash.slice(1)); });
  }

  document.addEventListener("DOMContentLoaded", async () => {
    if (!client) return message("The Supabase connection could not be initialized.", "error");
    const from = new Date(); from.setDate(from.getDate() - 30);
    $("historyFrom").value = isoDate(from);
    $("historyTo").value = isoDate(new Date());
    bind();
    try {
      const { data: { session } } = await client.auth.getSession();
      if (!session) return void location.replace("../index.html");
      await load();
      await showTab(location.hash.slice(1) || "overview");
    } catch (error) {
      document.querySelectorAll("[data-panel]").forEach((panel) => panel.classList.add("hidden"));
      $("stkTabs").classList.add("hidden");
      message(friendly(error), "error");
    }
  });
})();
