"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const params = new URLSearchParams(window.location.search);
  const token = params.get("t") || "";
  const requestedDecision = String(params.get("decision") || "").toUpperCase();
  const nodes = {
    loading: document.getElementById("gmLoading"), content: document.getElementById("gmContent"), state: document.getElementById("gmState"),
    staff: document.getElementById("gmStaff"), dates: document.getElementById("gmDates"), duration: document.getElementById("gmDuration"), reason: document.getElementById("gmReason"),
    note: document.getElementById("gmNote"), actions: document.getElementById("gmActions"), approve: document.getElementById("gmApprove"), reject: document.getElementById("gmReject"), message: document.getElementById("gmMessage")
  };
  let review = null;

  function setMessage(text = "", kind = "") { nodes.message.textContent = text; nodes.message.className = `gm-message${kind ? ` ${kind}` : ""}`; }
  function formatDate(iso) { if (!iso) return "—"; return new Intl.DateTimeFormat("en-IE", { day: "2-digit", month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(`${String(iso).slice(0, 10)}T00:00:00Z`)); }
  async function rpc(name, args) { const { data, error } = await client.rpc(name, args); if (error) throw error; return data; }
  function lockActions() { nodes.approve.disabled = true; nodes.reject.disabled = true; nodes.note.disabled = true; }

  function render(data) {
    review = data;
    nodes.loading.classList.add("hidden"); nodes.content.classList.remove("hidden");
    nodes.staff.textContent = data.display_name || "Staff member";
    nodes.dates.textContent = data.end_date && data.end_date !== data.start_date ? `${formatDate(data.start_date)} – ${formatDate(data.end_date)}` : formatDate(data.start_date);
    nodes.duration.textContent = `${Number(data.duration_days || 0)} calendar days`;
    nodes.reason.textContent = data.reason || "—";
    const status = String(data.status || "PENDING").toUpperCase();
    const gmState = String(data.gm_state || "").toUpperCase();
    if (status !== "PENDING" || gmState === "DECIDED") {
      nodes.state.textContent = `Decision already recorded: ${status}.`;
      nodes.state.className = "gm-state done"; lockActions();
    } else if (data.expired) {
      nodes.state.textContent = "This secure review link has expired. Ask the Roster Manager to send a new email.";
      nodes.state.className = "gm-state error"; lockActions();
    } else {
      nodes.state.textContent = requestedDecision === "APPROVED"
        ? "Approve selected from the email. Review the request below and press Approve Holiday to confirm."
        : requestedDecision === "REJECTED"
          ? "Reject selected from the email. Review the request below and press Reject Holiday to confirm."
          : `Secure review link · expires ${new Intl.DateTimeFormat("en-IE", { dateStyle: "medium", timeStyle: "short" }).format(new Date(data.expires_at))}`;
      if (requestedDecision === "APPROVED") nodes.approve.focus();
      if (requestedDecision === "REJECTED") nodes.reject.focus();
    }
  }

  async function decide(decision) {
    if (!review || nodes.approve.disabled) return;
    const verb = decision === "APPROVED" ? "approve" : "reject";
    if (!window.confirm(`Confirm that you want to ${verb} this Holiday request?`)) return;
    nodes.approve.disabled = true; nodes.reject.disabled = true; setMessage("Saving decision…");
    try {
      const result = await rpc("decide_production_roster_gm_review", { p_token: token, p_decision: decision, p_note: nodes.note.value.trim() || null });
      nodes.state.textContent = result?.message || `Holiday request ${decision.toLowerCase()}.`;
      nodes.state.className = "gm-state done"; lockActions(); setMessage("Decision saved. You can close this page.", "ok");
      try { history.replaceState(null, "", `${location.pathname}?gmDone=1`); } catch (_) {}
    } catch (error) {
      nodes.approve.disabled = false; nodes.reject.disabled = false; setMessage(error?.message || "The decision could not be saved.", "error");
    }
  }

  nodes.approve.addEventListener("click", () => decide("APPROVED"));
  nodes.reject.addEventListener("click", () => decide("REJECTED"));

  if (!token) {
    nodes.loading.classList.add("hidden"); nodes.content.classList.remove("hidden"); nodes.state.textContent = "This General Manager review link is invalid."; nodes.state.className = "gm-state error"; lockActions(); return;
  }
  try { render(await rpc("get_production_roster_gm_review", { p_token: token })); }
  catch (error) { nodes.loading.classList.add("hidden"); nodes.content.classList.remove("hidden"); nodes.state.textContent = error?.message || "This General Manager review link is unavailable."; nodes.state.className = "gm-state error"; lockActions(); }
});
