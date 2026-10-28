"use strict";

// My PPE & Uniform: staff with a roster login request uniforms, safety shoes
// and PPE, see their locker key (or ask for one), follow their requests and
// see what is registered in their name. When Staff Master has their last
// working day, they are told to return everything.
// Authorization is enforced by the RPCs (202610280003_stock_control.sql and
// 202610280005_stock_control_locker_requests_and_leavers.sql).
(() => {
  const MAX_LINES = 10;
  const HISTORY_ROWS = 12;
  const STATUS = {
    REQUESTED: { label: "Waiting for approval", tone: "requested" },
    APPROVED: { label: "Approved, collect at the store", tone: "approved" },
    ISSUED: { label: "Handed over", tone: "issued" },
    REJECTED: { label: "Declined", tone: "rejected" },
    CANCELLED: { label: "Cancelled", tone: "cancelled" }
  };
  const LOCKER_STATUS = { ...STATUS, ISSUED: { label: "Solved", tone: "issued" } };
  const LOCKER_REASONS = [
    ["lost", "I lost my key"],
    ["wrong", "This is not my locker"],
    ["broken", "The key or the locker is broken"],
    ["other", "Something else"]
  ];

  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const date = (value) => value ? new Intl.DateTimeFormat("en-IE", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(value)) : "—";
  const longDate = (value) => new Intl.DateTimeFormat("en-IE", { weekday: "long", day: "numeric", month: "long", year: "numeric" }).format(new Date(`${value}T12:00:00`));
  const dateTime = (value) => value ? new Intl.DateTimeFormat("en-IE", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "—";
  const qty = (value) => Number(value || 0).toLocaleString("en-IE", { maximumFractionDigits: 2 });
  const isOpen = (request) => ["REQUESTED", "APPROVED"].includes(request.request_status);

  const state = { data: null, cart: [], category: "", saving: false, tab: "request", historyAll: false, lockerMode: "need" };

  async function rpc(name, args) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function friendly(error) {
    const text = error?.message || String(error || "Something went wrong.");
    if (/permission denied|not authorized/i.test(text)) return "Your account cannot request PPE and uniforms.";
    return text;
  }

  function message(text, tone = "") {
    const element = $("myMessage");
    element.textContent = text || "";
    element.className = `stk-message${tone ? ` ${tone}` : ""}${text ? "" : " hidden"}`;
    if (text && tone !== "error") window.clearTimeout(message.timer), message.timer = window.setTimeout(() => message(""), 6000);
  }

  async function load() {
    state.data = await rpc("get_my_stock");
    render();
  }

  function render() {
    const data = state.data;
    const open = data.requests.filter(isOpen).length;
    const held = data.holding.reduce((sum, item) => sum + Number(item.qty || 0), 0);
    $("myStats").innerHTML = `
      <div class="${open ? "warn" : ""}"><b>${open}</b><small>open requests</small></div>
      <div><b>${qty(held)}</b><small>items held</small></div>
      <div><b>${data.lockers.map((locker) => esc(locker.label)).join(", ") || "—"}</b><small>locker key</small></div>`;
    if (data.can_view_stock) {
      $("myIntro").innerHTML = 'Ask for uniforms, safety shoes and PPE. You also manage stock: <a href="./stock.html#requests">open Stock Control</a> to answer requests.';
    }
    $("myOpenCount").textContent = open;
    $("myOpenCount").classList.toggle("hidden", !open);
    renderLeaving();
    renderLocker();
    renderHolding();
    renderItems();
    renderCart();
    renderRequests();
    renderHistory();
  }

  // ------------------------------------------------------------ Leaving

  function renderLeaving() {
    const { leaving_on: leaving, holding, lockers } = state.data;
    $("myLeaving").classList.toggle("hidden", !leaving);
    if (!leaving) return;
    const today = new Date().toISOString().slice(0, 10);
    const things = [
      ...lockers.map((locker) => `Locker key ${locker.label}`),
      ...holding.map((item) => `${qty(item.qty)} × ${item.description}${item.size ? ` (size ${item.size})` : ""}`)
    ];
    $("myLeaving").innerHTML = `
      <strong>${leaving >= today ? `Your last working day is ${esc(longDate(leaving))}.` : `Your last working day was ${esc(longDate(leaving))}.`}</strong>
      ${things.length
        ? `<span>Before you leave, return these company items to your supervisor:</span><ul>${things.map((thing) => `<li>${esc(thing)}</li>`).join("")}</ul>`
        : "<span>You have no company items or keys to return.</span>"}`;
  }

  // ------------------------------------------------------------ Locker key

  function renderLocker() {
    const { lockers, requests } = state.data;
    const pending = requests.find((request) => request.request_kind === "LOCKER_KEY" && isOpen(request));
    const keys = lockers.map((locker) => `
      <div class="my-key"><span class="my-key-label">${esc(locker.label)}</span>
        <div><strong>Locker ${esc(locker.label)}</strong><small>Registered in your name since ${esc(date(locker.assigned_at))}</small></div></div>`).join("");
    const waiting = pending ? `<p class="my-key-pending">${pill(LOCKER_STATUS[pending.request_status])} Request #${esc(pending.request_number)} sent ${esc(date(pending.created_at))}: ${esc(pending.reason || "")}</p>` : "";
    if (lockers.length) {
      $("myLocker").innerHTML = `${keys}${waiting}
        ${pending ? "" : '<div class="my-key-actions"><span class="stk-muted">Not your locker, or lost the key?</span><button type="button" class="stk-button" data-locker-request="problem">Report a problem</button></div>'}`;
    } else {
      $("myLocker").innerHTML = `<div class="my-key none"><span class="my-key-label">?</span>
        <div><strong>No locker key in your name</strong><small>Every staff member should have a locker key.</small></div></div>${waiting}
        ${pending ? "" : '<div class="my-key-actions"><span class="stk-muted">Do you have a key that is not listed, or need one?</span><button type="button" class="stk-button stk-primary" data-locker-request="need">Request a locker key</button></div>'}`;
    }
  }

  function openLockerDialog(mode) {
    state.lockerMode = mode;
    const problem = mode === "problem";
    const labels = state.data.lockers.map((locker) => locker.label).join(", ");
    $("myLockerTitle").textContent = problem ? "Report a problem with my key" : "Request a locker key";
    $("myLockerMeta").textContent = problem ? `Registered key: ${labels}` : "Your supervisor or manager will give you a locker.";
    const reasons = problem ? LOCKER_REASONS : [["need", "I do not have a key"], ["have", "I have a key, but it is not listed here"]];
    $("myLockerReasons").innerHTML = reasons.map(([code, label], index) => `
      <label class="my-reason"><input type="radio" name="myLockerReason" value="${esc(code)}" data-text="${esc(label)}"${index === 0 ? " checked" : ""}> ${esc(label)}</label>`).join("");
    $("myLockerNote").value = "";
    $("myLockerStatus").textContent = "";
    syncLockerDialog();
    $("myLockerDialog").showModal();
  }

  function syncLockerDialog() {
    const code = document.querySelector('input[name="myLockerReason"]:checked')?.value;
    const required = ["wrong", "other", "have"].includes(code);
    $("myLockerNoteHint").textContent = required ? code === "other" ? "(required)" : "(required: write your locker number)" : "(optional)";
    $("myLockerNote").required = required;
  }

  async function sendLockerRequest(event) {
    event.preventDefault();
    const choice = document.querySelector('input[name="myLockerReason"]:checked');
    const note = $("myLockerNote").value.trim();
    if ($("myLockerNote").required && !note) { $("myLockerStatus").textContent = "Write a note for your supervisor."; return; }
    $("myLockerSave").disabled = true;
    $("myLockerStatus").textContent = "Sending…";
    try {
      const request = await rpc("submit_my_locker_request", { p_reason: [choice?.dataset.text, note].filter(Boolean).join(": ") });
      $("myLockerDialog").close();
      await load();
      message(`Locker key request #${request.request_number} was sent. You will see the answer here.`, "good");
    } catch (error) {
      $("myLockerStatus").textContent = friendly(error);
    } finally {
      $("myLockerSave").disabled = false;
    }
  }

  // ------------------------------------------------------------ Holding

  function renderHolding() {
    $("myHolding").innerHTML = state.data.holding.map((item) => `
      <li><div><strong>${esc(item.description)}${item.size ? ` · size ${esc(item.size)}` : ""}</strong>
        <small>${esc(item.item_type)} · last handed over ${esc(date(item.last_issued_at))}</small></div><span class="stk-qty">${qty(item.qty)}</span></li>`).join("")
      || '<li class="stk-muted">No uniforms or PPE are registered in your name.</li>';
  }

  // ------------------------------------------------------------ Request items

  function pill(status) { return `<span class="stk-pill ${status.tone}">${esc(status.label)}</span>`; }

  function renderItems() {
    const items = state.data.items;
    const categories = [...new Map(items.map((item) => [item.category_code, item.category_name])).entries()];
    $("myCategories").classList.toggle("hidden", categories.length < 2);
    $("myCategoryChips").innerHTML = [["", "All"], ...categories].map(([code, name]) =>
      `<button type="button" data-category="${esc(code)}" class="${state.category === code ? "active" : ""}">${esc(name)}</button>`).join("");
    const list = items.filter((item) => !state.category || item.category_code === state.category);
    if (!items.length) {
      $("myItems").innerHTML = '<p class="stk-empty">No items can be requested at the moment. Ask your supervisor.</p>';
      return;
    }
    $("myItems").innerHTML = list.map((item) => `
      <article class="my-item" data-item="${esc(item.item_id)}">
        <div><strong>${esc(item.item_name)}</strong><small>${esc(item.category_name)} · ${item.available ? "In stock" : "Out of stock, you can still ask"}</small></div>
        <div class="my-item-row">
          ${item.size_options.length
            ? `<select data-size aria-label="Size for ${esc(item.item_name)}"><option value="">Size…</option>${item.size_options.map((size) => `<option>${esc(size)}</option>`).join("")}</select>`
            : '<span class="my-one-size">One size</span>'}
          <input data-qty type="number" min="1" max="20" value="1" aria-label="Quantity">
          <button type="button" class="stk-button stk-primary" data-add>Add</button>
        </div>
      </article>`).join("");
  }

  function renderCart() {
    $("myCartList").innerHTML = state.cart.map((line, index) => `
      <li><span><strong>${esc(line.qty)} × ${esc(line.item_name)}</strong>${line.size ? ` <span class="stk-muted">size ${esc(line.size)}</span>` : ""}</span>
      <button type="button" data-remove="${index}">Remove</button></li>`).join("");
    $("myCartHint").textContent = state.cart.length ? `${state.cart.length} item${state.cart.length === 1 ? "" : "s"} in this request.` : "No items added yet.";
    $("mySubmit").disabled = !state.cart.length || state.saving;
  }

  function addToCart(card) {
    const item = state.data.items.find((entry) => entry.item_id === card.dataset.item);
    if (!item) return;
    const size = card.querySelector("[data-size]")?.value || "";
    const amount = Math.round(Number(card.querySelector("[data-qty]").value));
    if (item.size_options.length && !size) return message(`Choose the size for ${item.item_name}.`, "error");
    if (!(amount >= 1 && amount <= 20)) return message("Enter a quantity from 1 to 20.", "error");
    const existing = state.cart.find((line) => line.item_id === item.item_id && line.size === size);
    if (existing) existing.qty = Math.min(20, existing.qty + amount);
    else {
      if (state.cart.length >= MAX_LINES) return message(`A request can have up to ${MAX_LINES} items.`, "error");
      state.cart.push({ item_id: item.item_id, item_name: item.item_name, size, qty: amount });
    }
    message("");
    renderCart();
  }

  async function submit() {
    if (!state.cart.length || state.saving) return;
    state.saving = true;
    renderCart();
    $("myCartStatus").textContent = "Sending…";
    try {
      const request = await rpc("submit_my_stock_request", {
        p_lines: state.cart.map(({ item_id, size, qty: amount }) => ({ item_id, size: size || null, qty: amount })),
        p_reason: $("myReason").value.trim() || null
      });
      state.cart = [];
      $("myReason").value = "";
      $("myCartStatus").textContent = "";
      await load();
      showTab("requests");
      message(`Request #${request.request_number} was sent. You will see the answer here.`, "good");
    } catch (error) {
      $("myCartStatus").textContent = friendly(error);
    } finally {
      state.saving = false;
      renderCart();
    }
  }

  // ------------------------------------------------------------ Requests and history

  function renderRequests() {
    const requests = state.data.requests;
    if (!requests.length) {
      $("myRequests").innerHTML = '<p class="stk-empty">You have not requested anything yet.</p>';
      return;
    }
    $("myRequests").innerHTML = requests.map((request) => {
      const locker = request.request_kind === "LOCKER_KEY";
      const status = (locker ? LOCKER_STATUS : STATUS)[request.request_status] || STATUS.REQUESTED;
      const issued = request.request_status === "ISSUED";
      return `<article class="stk-request ${status.tone}">
        <div class="stk-request-head">
          <div><strong>${locker ? "Locker key" : "Request"} #${esc(request.request_number)}</strong><br><small>${esc(dateTime(request.created_at))}</small></div>
          ${pill(status)}
        </div>
        ${locker
          ? `<ul class="stk-request-lines"><li><span>${esc(request.reason || "Locker key")}</span>${request.locker_label ? `<b>Locker ${esc(request.locker_label)}</b>` : ""}</li></ul>`
          : `<ul class="stk-request-lines">${request.lines.map((line) => `<li><span>${esc(line.item_name)}${line.size ? ` · size ${esc(line.size)}` : ""}</span>
            <b>${issued ? `${qty(line.issued_qty)} of ${qty(line.qty)}` : qty(line.qty)}</b></li>`).join("")}</ul>
            ${request.reason ? `<p class="stk-request-note">Your note: ${esc(request.reason)}</p>` : ""}`}
        ${request.decision_note ? `<p class="stk-request-note"><b>${esc(request.decided_by_name || "Store")}:</b> ${esc(request.decision_note)}</p>` : ""}
        ${request.request_status === "REQUESTED" ? `<div class="stk-request-actions"><button type="button" class="stk-button stk-ghost-red" data-cancel="${esc(request.request_id)}">Cancel request</button></div>` : ""}
      </article>`;
    }).join("");
  }

  function renderHistory() {
    const rows = state.data.history;
    const shown = state.historyAll ? rows : rows.slice(0, HISTORY_ROWS);
    $("myHistory").innerHTML = shown.map((event) => `
      <li><div><strong>${esc(event.description)}${event.size ? ` · size ${esc(event.size)}` : ""}</strong><small>${esc(dateTime(event.recorded_at))}</small></div>
      <span class="stk-pill ${event.ppe_action === "ISSUED" ? "issued" : "muted"}">${event.ppe_action === "ISSUED" ? `Received ${qty(event.qty)}` : `Returned ${qty(event.qty)}`}</span></li>`).join("")
      || '<li class="stk-muted">No history yet.</li>';
    $("myHistoryMore").classList.toggle("hidden", state.historyAll || rows.length <= HISTORY_ROWS);
  }

  async function cancel(requestId) {
    if (!window.confirm("Cancel this request?")) return;
    try {
      await rpc("cancel_my_stock_request", { p_request_id: requestId });
      await load();
      message("The request was cancelled.");
    } catch (error) {
      message(friendly(error), "error");
    }
  }

  function showTab(tab) {
    state.tab = tab;
    document.querySelectorAll("[data-my-tab]").forEach((button) => button.classList.toggle("active", button.dataset.myTab === tab));
    document.querySelectorAll("[data-my-panel]").forEach((panel) => panel.classList.toggle("hidden", panel.dataset.myPanel !== tab));
  }

  function bind() {
    $("myTabs").addEventListener("click", (event) => { const button = event.target.closest("[data-my-tab]"); if (button) showTab(button.dataset.myTab); });
    $("myCategoryChips").addEventListener("click", (event) => {
      const chip = event.target.closest("[data-category]");
      if (!chip) return;
      state.category = chip.dataset.category;
      renderItems();
    });
    $("myItems").addEventListener("click", (event) => { if (event.target.closest("[data-add]")) addToCart(event.target.closest("[data-item]")); });
    $("myCartList").addEventListener("click", (event) => {
      const button = event.target.closest("[data-remove]");
      if (!button) return;
      state.cart.splice(Number(button.dataset.remove), 1);
      renderCart();
    });
    $("mySubmit").addEventListener("click", submit);
    $("myRequests").addEventListener("click", (event) => { const button = event.target.closest("[data-cancel]"); if (button) cancel(button.dataset.cancel); });
    $("myHistoryMore").addEventListener("click", () => { state.historyAll = true; renderHistory(); });
    $("myLocker").addEventListener("click", (event) => { const button = event.target.closest("[data-locker-request]"); if (button) openLockerDialog(button.dataset.lockerRequest); });
    $("myLockerReasons").addEventListener("change", syncLockerDialog);
    $("myLockerForm").addEventListener("submit", sendLockerRequest);
    document.querySelectorAll("dialog [data-close]").forEach((button) => button.addEventListener("click", () => button.closest("dialog").close()));
  }

  document.addEventListener("DOMContentLoaded", async () => {
    if (!client) return message("The Supabase connection could not be initialized.", "error");
    bind();
    try {
      const { data: { session } } = await client.auth.getSession();
      if (!session) return void location.replace("../index.html");
      await load();
    } catch (error) {
      $("myItems").innerHTML = `<p class="stk-empty error">${esc(friendly(error))}</p>`;
      ["myRequests", "myHolding", "myHistory", "myLocker"].forEach((id) => { $(id).innerHTML = ""; });
      $("myCart").classList.add("hidden");
    }
  });
})();
