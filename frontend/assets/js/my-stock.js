"use strict";

// My PPE & Uniform: staff with a roster login request uniforms, safety shoes
// and PPE, follow their requests and see what is registered in their name.
// Authorization is enforced by the RPCs (202610280003_stock_control.sql).
(() => {
  const MAX_LINES = 10;
  const STATUS = {
    REQUESTED: { label: "Waiting for approval", tone: "requested" },
    APPROVED: { label: "Approved, collect at the store", tone: "approved" },
    ISSUED: { label: "Handed over", tone: "issued" },
    REJECTED: { label: "Declined", tone: "rejected" },
    CANCELLED: { label: "Cancelled", tone: "cancelled" }
  };

  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const date = (value) => value ? new Intl.DateTimeFormat("en-IE", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(value)) : "—";
  const dateTime = (value) => value ? new Intl.DateTimeFormat("en-IE", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "—";
  const qty = (value) => Number(value || 0).toLocaleString("en-IE", { maximumFractionDigits: 2 });

  const state = { data: null, cart: [], category: "", saving: false };

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
    const open = data.requests.filter((request) => ["REQUESTED", "APPROVED"].includes(request.request_status)).length;
    const held = data.holding.reduce((sum, item) => sum + Number(item.qty || 0), 0);
    $("myStats").innerHTML = `
      <div class="${open ? "warn" : ""}"><b>${open}</b><small>open requests</small></div>
      <div><b>${qty(held)}</b><small>items held</small></div>
      <div><b>${data.lockers.length}</b><small>locker keys</small></div>`;
    if (data.can_view_stock) {
      $("myIntro").innerHTML = 'Ask for uniforms, safety shoes and PPE. You also manage stock: <a href="./stock.html#requests">open Stock Control</a> to answer requests.';
    }
    renderItems();
    renderCart();
    renderRequests();
    renderHolding();
    renderHistory();
  }

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
        <div><strong>${esc(item.item_name)}</strong><br><small>${esc(item.category_name)} · ${item.available ? "In stock" : "Out of stock, you can still ask"}</small></div>
        <div class="my-item-row">
          ${item.size_options.length
            ? `<select data-size aria-label="Size for ${esc(item.item_name)}"><option value="">Size…</option>${item.size_options.map((size) => `<option>${esc(size)}</option>`).join("")}</select>`
            : '<span class="stk-muted" style="flex:1">One size</span>'}
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

  function renderRequests() {
    const requests = state.data.requests;
    if (!requests.length) {
      $("myRequests").innerHTML = '<p class="stk-empty">You have not requested anything yet.</p>';
      return;
    }
    $("myRequests").innerHTML = requests.map((request) => {
      const status = STATUS[request.request_status] || STATUS.REQUESTED;
      const issued = request.request_status === "ISSUED";
      return `<article class="stk-request ${status.tone}">
        <div class="stk-request-head">
          <div><strong>Request #${esc(request.request_number)}</strong><br><small>${esc(dateTime(request.created_at))}</small></div>
          <span class="stk-pill ${status.tone}">${esc(status.label)}</span>
        </div>
        <ul class="stk-request-lines">${request.lines.map((line) => `<li><span>${esc(line.item_name)}${line.size ? ` · size ${esc(line.size)}` : ""}</span>
          <b>${issued ? `${qty(line.issued_qty)} of ${qty(line.qty)}` : qty(line.qty)}</b></li>`).join("")}</ul>
        ${request.reason ? `<p class="stk-request-note">Your note: ${esc(request.reason)}</p>` : ""}
        ${request.decision_note ? `<p class="stk-request-note"><b>${esc(request.decided_by_name || "Store")}:</b> ${esc(request.decision_note)}</p>` : ""}
        ${request.request_status === "REQUESTED" ? `<div class="stk-request-actions"><button type="button" class="stk-button stk-ghost-red" data-cancel="${esc(request.request_id)}">Cancel request</button></div>` : ""}
      </article>`;
    }).join("");
  }

  function renderHolding() {
    const { holding, lockers } = state.data;
    const rows = [
      ...lockers.map((locker) => `<li><div><strong>Locker key ${esc(locker.label)}</strong><small>Since ${esc(date(locker.assigned_at))}</small></div><span class="stk-qty">1</span></li>`),
      ...holding.map((item) => `<li><div><strong>${esc(item.description)}${item.size ? ` · size ${esc(item.size)}` : ""}</strong>
        <small>${esc(item.item_type)} · last handed over ${esc(date(item.last_issued_at))}</small></div><span class="stk-qty">${qty(item.qty)}</span></li>`)
    ];
    $("myHolding").innerHTML = rows.join("") || '<li class="stk-muted">Nothing is registered in your name.</li>';
  }

  function renderHistory() {
    $("myHistory").innerHTML = state.data.history.map((event) => `
      <li><div><strong>${esc(event.description)}${event.size ? ` · size ${esc(event.size)}` : ""}</strong><small>${esc(dateTime(event.recorded_at))}</small></div>
      <span class="stk-pill ${event.ppe_action === "ISSUED" ? "issued" : "muted"}">${event.ppe_action === "ISSUED" ? `Received ${qty(event.qty)}` : `Returned ${qty(event.qty)}`}</span></li>`).join("")
      || '<li class="stk-muted">No history yet.</li>';
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
      message(`Request #${request.request_number} was sent. You will see the answer here.`, "good");
    } catch (error) {
      $("myCartStatus").textContent = friendly(error);
    } finally {
      state.saving = false;
      renderCart();
    }
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

  function bind() {
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
      ["myRequests"].forEach((id) => { $(id).innerHTML = ""; });
      ["myHolding", "myHistory"].forEach((id) => { $(id).innerHTML = ""; });
      $("myCart").classList.add("hidden");
    }
  });
})();
