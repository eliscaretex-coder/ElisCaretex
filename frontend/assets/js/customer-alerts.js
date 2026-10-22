"use strict";

// Customer Service alerts and department tasks on the production screens.
// Include with data-area="SORTING|FINISH|MOP|DISTRIBUTION". The bar appears at the top
// of the page only while Customer Service has an active alert or an open task for
// that area, and refreshes every few minutes. Other scripts can call
// window.ELIS_CUSTOMER_ALERTS.badge(customerId, code, name) to mark a customer in their own lists.
(function initCustomerAlerts() {
  const area = String(document.currentScript?.dataset.area || "").toUpperCase();
  const refreshMs = 4 * 60 * 1000;
  const hiddenKey = `elis.customer-alerts.collapsed.${area}`;
  const state = { alerts: [], tasks: [], byCustomer: new Map(), openTask: null };
  const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" })[c]);
  const fmtDate = (v) => v ? new Intl.DateTimeFormat("en-IE",{weekday:"short",day:"2-digit",month:"short",timeZone:"UTC"}).format(new Date(`${String(v).slice(0,10)}T12:00:00Z`)) : "";
  let bar = null;

  function collapsed() { try { return sessionStorage.getItem(hiddenKey) === "1"; } catch (_) { return false; } }
  function setCollapsed(value) { try { sessionStorage.setItem(hiddenKey, value ? "1" : "0"); } catch (_) { /* page still works */ } }

  // Lists identify customers by id when they have it, otherwise by code or name.
  function find(id, code, name) {
    const keys = [id && `id:${id}`, code && `code:${String(code).trim().toLowerCase()}`, name && `name:${String(name).trim().toLowerCase()}`].filter(Boolean);
    for (const key of keys) if (state.byCustomer.has(key)) return state.byCustomer.get(key);
    return null;
  }

  window.ELIS_CUSTOMER_ALERTS = Object.freeze({
    has: (id, code, name) => Boolean(find(id, code, name)),
    messages: (id, code, name) => find(id, code, name) || [],
    badge(id, code, name) {
      const list = find(id, code, name);
      return list ? `<span class="customer-alert-badge" title="${esc(list.join(" · "))}">⚠ Customer alert</span>` : "";
    }
  });

  function mount() {
    if (bar) return bar;
    const main = document.querySelector("[data-operational-shell-root] main") || document.querySelector("main");
    if (!main) return null;
    bar = document.createElement("section");
    bar.className = "customer-alerts-bar";
    bar.setAttribute("aria-live", "polite");
    bar.hidden = true;
    main.prepend(bar);
    bar.addEventListener("click", onClick);
    bar.addEventListener("submit", onSubmit);
    return bar;
  }

  function render() {
    if (!mount()) return;
    const count = state.alerts.length + state.tasks.length;
    bar.hidden = count === 0;
    if (!count) { bar.innerHTML = ""; return; }
    const isCollapsed = collapsed();
    bar.classList.toggle("collapsed", isCollapsed);
    const summary = [
      state.alerts.length ? `${state.alerts.length} customer alert${state.alerts.length === 1 ? "" : "s"}` : "",
      state.tasks.length ? `${state.tasks.length} task${state.tasks.length === 1 ? "" : "s"} for this area` : ""
    ].filter(Boolean).join(" · ");
    bar.innerHTML = `
      <header><strong>⚠ Customer Service</strong><span>${esc(summary)}</span><button type="button" data-toggle>${isCollapsed ? "Show" : "Hide"}</button></header>
      ${isCollapsed ? "" : `<div class="customer-alerts-list">
        ${state.alerts.map((a) => `<article class="alert"><b>${esc(a.customer_name)}</b><p>${esc(a.message)}</p>${a.ends_on ? `<small>Until ${esc(fmtDate(a.ends_on))}</small>` : ""}</article>`).join("")}
        ${state.tasks.map((t) => `<article class="task ${t.overdue ? "overdue" : ""}"><b>Task${t.customer_name ? ` · ${esc(t.customer_name)}` : ""}</b><p>${esc(t.title)}${t.details ? ` — ${esc(t.details)}` : ""}</p><small>${t.due_on ? `${t.overdue ? "Overdue since" : "Due"} ${esc(fmtDate(t.due_on))}` : "No due date"}</small>
          ${state.openTask === t.task_id
            ? `<form data-task="${esc(t.task_id)}"><input name="notes" required minlength="2" maxlength="500" placeholder="What was done and who did it"><button type="submit">Save</button><button type="button" data-cancel>Back</button></form>`
            : `<button type="button" data-done="${esc(t.task_id)}">Mark done</button>`}
        </article>`).join("")}
      </div>`}`;
  }

  function onClick(event) {
    if (event.target.closest("[data-toggle]")) { setCollapsed(!collapsed()); render(); return; }
    const done = event.target.closest("[data-done]");
    if (done) { state.openTask = done.dataset.done; render(); bar.querySelector("form input")?.focus(); return; }
    if (event.target.closest("[data-cancel]")) { state.openTask = null; render(); }
  }

  async function onSubmit(event) {
    event.preventDefault();
    const form = event.target.closest("form[data-task]");
    if (!form) return;
    const button = form.querySelector('button[type="submit"]');
    button.disabled = true;
    try {
      const { error } = await window.elisSupabase.rpc("complete_production_customer_task_v1", { p_task_id: form.dataset.task, p_notes: form.notes.value });
      if (error) throw error;
      state.openTask = null;
      await load();
    } catch (err) {
      console.error(err);
      button.disabled = false;
      form.querySelector("input").setCustomValidity(err.message || "The task could not be saved.");
      form.reportValidity();
      form.querySelector("input").setCustomValidity("");
    }
  }

  async function load() {
    const client = window.elisSupabase;
    if (!client || !area) return;
    try {
      const { data: { session } } = await client.auth.getSession();
      if (!session?.user) return;
      const { data, error } = await client.rpc("get_production_customer_alerts_v1", { p_area_code: area });
      if (error) throw error;
      state.alerts = data?.alerts || [];
      state.tasks = data?.tasks || [];
      state.byCustomer = new Map();
      state.alerts.forEach((a) => {
        [`id:${a.customer_id}`, a.customer_code && `code:${String(a.customer_code).trim().toLowerCase()}`, `name:${String(a.customer_name || "").trim().toLowerCase()}`]
          .filter(Boolean).forEach((key) => state.byCustomer.set(key, [...(state.byCustomer.get(key) || []), a.message]));
      });
      render();
      document.dispatchEvent(new CustomEvent("elis:customer-alerts-changed"));
    } catch (err) {
      // Alerts are an aid; the production screen keeps working without them.
      console.warn("Customer alerts could not be loaded.", err);
    }
  }

  function start() {
    load();
    window.setInterval(() => { if (!document.hidden) load(); }, refreshMs);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) load(); });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
