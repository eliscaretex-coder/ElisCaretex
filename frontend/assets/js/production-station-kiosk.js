"use strict";

/* Fixed computer identity. Staff attribution remains in the Roster workflow. */
(() => {
  const state = { areaCode:"", terminal:null, adminReadOnly:false };
  const client = () => window.elisSupabase;
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, char => ({"&":"&amp;","<":"&gt;",">":"&gt;","'":"&#39;","\"":"&quot;"}[char]));

  async function getTerminalContext(areaCode=state.areaCode) {
    state.areaCode = String(areaCode || "").toUpperCase();
    if (!client()) throw new Error("Supabase could not be initialized.");
    const { data,error } = await client().rpc("get_production_terminal_context", { p_area_code:state.areaCode });
    if (error) {
      const { data: isAdmin, error: adminError } = await client().rpc("can_view_admin_account_access");
      if (adminError || !isAdmin) throw error;
      state.adminReadOnly = true;
      state.terminal = { admin_read_only:true, staff_source:"ROSTER" };
    } else {
      state.adminReadOnly = false;
      state.terminal = data;
    }
    renderStatus();
    return data;
  }

  function renderStatus() {
    const host = document.getElementById("productionStationStatus");
    if (!host) return;
    host.className = "production-station-status";
    if (state.adminReadOnly) {
      host.classList.add("admin");
      host.innerHTML = '<span class="production-station-status-copy"><b>Administrator access</b><small>You can review this area. Production entries remain available only on its registered computer.</small></span>';
      return;
    }
    if (!state.terminal?.device_code) {
      host.classList.add("terminal-required");
      host.innerHTML = '<span class="production-station-status-copy"><b>Terminal verification required</b><small>This computer is not registered to the production area.</small></span>';
      return;
    }
    host.classList.add("registered");
    host.innerHTML = `<span class="production-station-status-copy"><b>${esc(state.terminal.station_name)} · ${esc(state.terminal.device_code)}</b><small>Computer access is fixed. Staff attribution comes from the Roster.</small></span>`;
  }

  function insertStatus() {
    if (document.getElementById("productionStationStatus")) return;
    const anchor = document.querySelector(".finish-topbar, .sorting-topbar");
    if (anchor) anchor.insertAdjacentHTML("afterend", '<section class="production-station-status" id="productionStationStatus" aria-live="polite"></section>');
  }

  window.elisProductionStation = { getTerminalContext };
  document.addEventListener("DOMContentLoaded", async () => {
    state.areaCode = String(document.body?.dataset?.productionStationArea || "").toUpperCase();
    if (!state.areaCode) return;
    insertStatus();
    try { await getTerminalContext(state.areaCode); }
    catch (error) { console.warn("Production terminal status unavailable", error); renderStatus(); }
  });
})();
