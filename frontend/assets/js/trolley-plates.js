"use strict";

// Trolley plates for Finish and MOP Production: one row per planned trolley of the
// customer being processed, with the subunit(s) on the plate, the on-screen
// instruction for the staff and a Print label button. Data comes from
// get_production_flow_trolley_plates; a customer without planned trolleys shows nothing.
(function initializeTrolleyPlates() {
  const LOGO_URL = new URL("../assets/img/elis-logo.svg", document.baseURI).href;
  let requestToken = 0;
  // The label window is written from script, so the logo is embedded as a data URI
  // to print even before the window has fetched anything.
  let logoSrc = LOGO_URL;
  const logoReady = fetch(LOGO_URL)
    .then((response) => (response.ok ? response.text() : Promise.reject(response.status)))
    .then((svg) => { logoSrc = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`; })
    .catch(() => {});

  const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[char]);

  function injectStyles() {
    if (document.getElementById("trolleyPlatesStyles")) return;
    const style = document.createElement("style");
    style.id = "trolleyPlatesStyles";
    style.textContent = `
      .trolley-plates{border:1px solid #d6dde6;border-radius:12px;background:#f8fafc;padding:8px 10px;margin:8px 0;display:grid;gap:6px}
      .trolley-plates[hidden]{display:none}
      .trolley-plates-head{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap}
      .trolley-plates-head strong{font-size:14px;color:#0f2742}
      .trolley-plates-head span{font-size:12px;color:#5b6b7f}
      .trolley-plates-list{display:grid;gap:4px;margin:0;padding:0;list-style:none}
      .trolley-plate{display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:4px 10px;background:#fff;border:1px solid #e2e8f0;border-radius:9px;padding:5px 8px}
      .trolley-plate-badge{display:inline-flex;align-items:baseline;gap:3px;justify-content:center;min-width:42px;padding:4px 6px;border-radius:7px;background:#0f2742;color:#fff;font-weight:800;font-size:14px}
      .trolley-plate-badge small{font-size:10px;font-weight:600;opacity:.8}
      .trolley-plate-name{display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 8px;min-width:0}
      .trolley-plate-name b{font-size:15px;font-weight:800;color:#b45309;overflow-wrap:anywhere}
      .trolley-plate-name b.is-customer{color:#0f2742;font-weight:700}
      .trolley-plate-name small{font-size:12px;color:#5b6b7f}
      .trolley-plate-instruction{grid-column:2/4;font-size:13px;font-weight:700;color:#7c2d12;background:#fff7ed;border:1px solid #fed7aa;border-radius:7px;padding:4px 8px;overflow-wrap:anywhere}
      .trolley-plates button{border:1px solid #0f2742;background:#fff;color:#0f2742;border-radius:7px;padding:4px 10px;font-weight:700;cursor:pointer;min-height:32px}
      .trolley-plates button:hover{background:#0f2742;color:#fff}
      .trolley-plates-error{font-size:12px;color:#b91c1c}
      @media (max-width:560px){.trolley-plate{grid-template-columns:auto 1fr}.trolley-plate>button{grid-column:1/3}.trolley-plate-instruction{grid-column:1/3}}
    `;
    document.head.appendChild(style);
  }

  function trolleyName(data, trolley) {
    return trolley.subunit_label || "";
  }

  function trolleyMeta(trolley, total) {
    const parts = [`Trolley ${trolley.position} of ${total}`, trolley.trolley_type_name || trolley.display_code];
    if (trolley.empty_trolley) parts.push("Empty trolley");
    if (trolley.shared_with_other_product) {
      const served = (trolley.serves_product_codes || []).map((code) => code === "CLOTHES" ? "Clothes" : code === "MOP" ? "MOP" : code);
      parts.push(`Shared: ${served.join(" + ")}`);
    }
    return parts.filter(Boolean).join(" · ");
  }

  function render(container, data) {
    const trolleys = Array.isArray(data?.trolleys) ? data.trolleys : [];
    if (!trolleys.length) {
      container.hidden = true;
      container.innerHTML = "";
      return;
    }
    trolleys.forEach((trolley, index) => { trolley.position = index + 1; });
    const withSub = trolleys.filter((trolley) => trolley.subunit_label).length;
    container.hidden = false;
    container.innerHTML = `
      <div class="trolley-plates-head">
        <div><strong>🛒 Trolley plates (${trolleys.length})</strong> <span>${withSub ? `${withSub} with subunit` : "Customer name only"}</span></div>
        ${trolleys.length > 1 ? '<button type="button" data-plate-print="all">Print all labels</button>' : ""}
      </div>
      <ol class="trolley-plates-list">
        ${trolleys.map((trolley, index) => `
          <li class="trolley-plate">
            <span class="trolley-plate-badge">${esc(trolley.display_code || "?")}<small>#${trolley.position}</small></span>
            <span class="trolley-plate-name">
              ${trolleyName(data, trolley)
                ? `<b>${esc(trolleyName(data, trolley))}</b>`
                : `<b class="is-customer">${esc(data.customer_name)}</b>`}
              <small>${esc(trolleyMeta(trolley, trolleys.length))}</small>
            </span>
            <button type="button" data-plate-print="${index}">Print label</button>
            ${trolley.instructions ? `<span class="trolley-plate-instruction">⚠ ${esc(trolley.instructions)}</span>` : ""}
          </li>`).join("")}
      </ol>`;
    container.onclick = (event) => {
      const button = event.target.closest("[data-plate-print]");
      if (!button) return;
      const key = button.dataset.platePrint;
      printLabels(data, key === "all" ? trolleys : [trolleys[Number(key)]]);
    };
  }

  function labelHtml(data, trolley, total) {
    const sub = trolleyName(data, trolley);
    return `
      <section class="label">
        <img class="logo" src="${esc(logoSrc)}" alt="Elis">
        <div class="names">
          <div class="customer">${esc(data.customer_name)}</div>
          ${sub ? `<div class="sub">${esc(sub)}</div>` : ""}
        </div>
        <div class="foot">${esc(`${trolley.display_code || ""} · ${trolley.position}/${total}`)}</div>
      </section>`;
  }

  async function printLabels(data, trolleys) {
    const all = Array.isArray(data?.trolleys) ? data.trolleys : [];
    const win = window.open("", "_blank");
    if (!win) {
      window.alert("The label window was blocked. Allow pop-ups for this site and try again.");
      return;
    }
    await logoReady;
    win.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Trolley label · ${esc(data.customer_name)}</title>
      <style>
        @page{size:A5 landscape;margin:8mm}
        *{box-sizing:border-box}
        body{margin:0;font-family:Arial,Helvetica,sans-serif;color:#000}
        .label{position:relative;height:130mm;page-break-after:always;break-after:page;display:grid;place-items:center;border:1px solid #000;padding:10mm}
        .label:last-child{page-break-after:auto;break-after:auto}
        .logo{position:absolute;top:6mm;left:6mm;height:16mm}
        .names{text-align:center;display:grid;gap:6mm;max-width:100%}
        .customer{font-size:34pt;font-weight:800;line-height:1.1;overflow-wrap:anywhere}
        .sub{font-size:28pt;font-weight:700;line-height:1.1;overflow-wrap:anywhere}
        .foot{position:absolute;bottom:5mm;left:6mm;font-size:10pt}
      </style></head><body>
      ${trolleys.map((trolley) => labelHtml(data, trolley, all.length)).join("")}
      <script>
        function printWhenReady(){
          var pending = Array.prototype.filter.call(document.images, function(img){ return !img.complete; });
          if (!pending.length) { setTimeout(function(){ window.focus(); window.print(); }, 150); return; }
          var left = pending.length;
          pending.forEach(function(img){ img.onload = img.onerror = function(){ if (--left === 0) printWhenReady(); }; });
        }
        window.onload = printWhenReady;
      <\/script>
      </body></html>`);
    win.document.close();
  }

  async function mount(container, { rpc, productionFlowItemId }) {
    if (!container) return null;
    injectStyles();
    const token = ++requestToken;
    container.hidden = true;
    container.innerHTML = "";
    if (!productionFlowItemId) return null;
    try {
      const data = await rpc("get_production_flow_trolley_plates", { p_production_flow_item_id: productionFlowItemId });
      if (token !== requestToken) return null;
      render(container, data);
      return data;
    } catch (error) {
      if (token !== requestToken) return null;
      // Database change not applied yet: keep the screen exactly as before.
      if (error?.code === "PGRST202") return null;
      console.error("Trolley plates could not be loaded:", error);
      container.hidden = false;
      container.innerHTML = '<p class="trolley-plates-error">Trolley plates could not be loaded. The trolley plan above still applies.</p>';
      return null;
    }
  }

  function clear(container) {
    requestToken += 1;
    if (!container) return;
    container.hidden = true;
    container.innerHTML = "";
  }

  window.ELIS_TROLLEY_PLATES = { mount, clear };
})();
