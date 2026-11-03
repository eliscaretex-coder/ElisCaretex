"use strict";

// Trolley plates for Finish and MOP Production: one row per planned trolley of the
// customer being processed, with the subunit(s) on the plate, the on-screen
// instruction for the staff and a print-label icon. Finish also passes a scan
// handler: the header button then scans the trolleys in plate order (M #1, M #2…)
// and each row shows the trolley scanned for it. Data comes from
// get_production_flow_trolley_plates; a customer without planned trolleys shows nothing.
// The Schedule Planner reuses the label print through ELIS_TROLLEY_PLATES.print.
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
      .trolley-plates-title{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
      .trolley-plates-head strong{font-size:14px;color:#0f2742}
      .trolley-plates-title>span{font-size:12px;color:#5b6b7f}
      .trolley-plates-title>.trolley-plates-count{display:inline-flex;align-items:center;justify-content:center;min-width:22px;height:22px;padding:0 7px;border-radius:999px;background:#0f2742;color:#fff;font-size:12px;font-weight:800}
      .trolley-plates-title>.trolley-plates-progress{font-weight:700}
      .trolley-plates-title>.trolley-plates-progress.ok{color:#047857}
      .trolley-plates-title>.trolley-plates-progress.bad{color:#b91c1c}
      .trolley-plates-list{display:grid;gap:4px;margin:0;padding:0;list-style:none}
      .trolley-plate{display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:4px 10px;background:#fff;border:1px solid #e2e8f0;border-radius:9px;padding:5px 8px}
      .trolley-plates.has-scan .trolley-plate{grid-template-columns:auto 1fr auto auto}
      .trolley-plate.is-next{border-color:#0f766e;box-shadow:0 0 0 2px #99f6e4}
      .trolley-plate.is-pickable{cursor:pointer}
      .trolley-plate.is-pickable:hover{border-color:#14b8a6;background:#f0fdfa}
      .trolley-plate.is-ok{border-color:#86efac;background:#f0fdf4}
      .trolley-plate.is-wrong{border-color:#fca5a5;background:#fef2f2}
      .trolley-plate-badge{display:inline-flex;align-items:baseline;gap:3px;justify-content:center;min-width:42px;padding:4px 6px;border-radius:7px;background:#0f2742;color:#fff;font-weight:800;font-size:14px}
      .trolley-plate-badge small{font-size:10px;font-weight:600;opacity:.8}
      .trolley-plate-name{display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 8px;min-width:0}
      .trolley-plate-name b{font-size:15px;font-weight:800;color:#b45309;overflow-wrap:anywhere}
      .trolley-plate-name b.is-customer{color:#0f2742;font-weight:700}
      .trolley-plate-name small{font-size:12px;color:#5b6b7f}
      .trolley-plate-instruction{grid-column:2/-1;font-size:13px;font-weight:700;color:#7c2d12;background:#fff7ed;border:1px solid #fed7aa;border-radius:7px;padding:4px 8px;overflow-wrap:anywhere}
      .trolley-plate-scan{display:inline-flex;align-items:center;gap:6px;justify-self:end;font-size:12px;font-weight:800;border-radius:999px;padding:3px 4px 3px 9px;white-space:nowrap;min-height:26px}
      .trolley-plate-scan code{font:inherit;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;letter-spacing:.2px}
      .trolley-plate-scan.missing{background:#f1f5f9;color:#64748b;padding-right:9px}
      .trolley-plate-scan.next{background:#ccfbf1;color:#115e59;padding-right:9px}
      .trolley-plate-scan.checking{background:#f1f5f9;color:#475569}
      .trolley-plate-scan.ok{background:#dcfce7;color:#166534}
      .trolley-plate-scan.wrong{background:#fee2e2;color:#991b1b}
      .trolley-plate-scan.pending{background:#fef3c7;color:#92400e}
      .trolley-plates .trolley-plate-scan button{min-height:20px;width:20px;padding:0;border:0;border-radius:999px;background:transparent;color:inherit;font-size:15px;line-height:1}
      .trolley-plates .trolley-plate-scan button:hover{background:#0000001a;color:inherit}
      .trolley-plates button{border:1px solid #0f2742;background:#fff;color:#0f2742;border-radius:7px;padding:4px 10px;font-weight:700;cursor:pointer;min-height:32px}
      .trolley-plates button:hover{background:#0f2742;color:#fff}
      .trolley-plates button.trolley-plate-print{display:inline-flex;align-items:center;justify-content:center;width:34px;min-height:32px;padding:0;border-color:#cbd5e1;color:#334155}
      .trolley-plates button.trolley-plate-print:hover{border-color:#0f2742;background:#0f2742;color:#fff}
      .trolley-plates button.trolley-plate-print svg{width:18px;height:18px}
      .trolley-plates button.trolley-plates-scan-button{display:inline-flex;align-items:center;gap:7px;background:#0f766e;border-color:#0f766e;color:#fff;padding:5px 12px}
      .trolley-plates button.trolley-plates-scan-button:hover{background:#115e59;border-color:#115e59;color:#fff}
      .trolley-plates button.trolley-plates-scan-button.is-done:hover{background:#d1fae5;color:#047857}
      .trolley-plates button.trolley-plates-scan-button.is-wrong:hover{background:#fef2f2;color:#b91c1c}
      .trolley-plates button.trolley-plates-scan-button.is-pending:hover{background:#fef3c7;color:#92400e}
      .trolley-plates button.trolley-plates-scan-button.is-done{background:#ecfdf5;border-color:#86efac;color:#047857}
      .trolley-plates button.trolley-plates-scan-button.is-wrong{background:#fff;border-color:#dc2626;color:#b91c1c}
      .trolley-plates button.trolley-plates-scan-button.is-pending{background:#fffbeb;border-color:#f59e0b;color:#92400e}
      .trolley-plates button.trolley-plates-scan-button svg{width:17px;height:17px}
      .trolley-plates-scanbar{display:grid;grid-template-columns:1fr auto auto;gap:6px;align-items:center;background:#fff;border:1px dashed #0f766e;border-radius:9px;padding:6px}
      .trolley-plates-scanbar[hidden]{display:none}
      .trolley-plates-scanbar input{width:100%;border:1px solid #cbd5e1;border-radius:7px;padding:7px 9px;font:inherit;font-size:14px;font-weight:700}
      .trolley-plates-scanbar input:focus{outline:2px solid #14b8a6;outline-offset:0;border-color:#14b8a6}
      .trolley-plates-scanbar .trolley-plates-later{border-color:#f59e0b;color:#92400e;background:#fffbeb}
      .trolley-plates-scanbar .trolley-plates-later:hover{background:#f59e0b;color:#fff}
      .trolley-plates-notice{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;font-size:12px;font-weight:700;border-radius:8px;padding:6px 9px}
      .trolley-plates-notice[hidden]{display:none}
      .trolley-plates-notice.bad{background:#fee2e2;color:#991b1b}
      .trolley-plates-notice.warn{background:#ffedd5;color:#9a3412}
      .trolley-plates-notice.pending{background:#fef3c7;color:#92400e}
      .trolley-plates-notice ul{margin:2px 0 0;padding-left:18px;font-weight:600}
      .trolley-plates-notice button{min-height:28px;padding:2px 9px;font-size:12px;border-color:currentColor;color:inherit}
      .trolley-plates-error{font-size:12px;color:#b91c1c}
      @media (max-width:560px){.trolley-plate,.trolley-plates.has-scan .trolley-plate{grid-template-columns:auto 1fr auto}.trolley-plates.has-scan .trolley-plate-scan{grid-column:1/3;justify-self:start}.trolley-plate-instruction{grid-column:1/-1}.trolley-plates-scanbar{grid-template-columns:1fr auto}.trolley-plates-scanbar .trolley-plates-later{grid-column:1/-1}}
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

  const PRINTER_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9V3h12v6"/><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/><rect x="6" y="14" width="12" height="7" rx="1"/></svg>';
  const SCAN_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/><path d="M7 8v8M11 8v8M15 8v8M18 8v8"/></svg>';

  // Plate label used on screen and by the scan prompt: "M #1".
  function plateLabel(trolley) {
    return `${trolley.display_code || "?"} #${trolley.position}`;
  }

  function render(container, data, options = {}) {
    const trolleys = Array.isArray(data?.trolleys) ? data.trolleys : [];
    if (!trolleys.length) {
      container.hidden = true;
      container.innerHTML = "";
      return;
    }
    trolleys.forEach((trolley, index) => { trolley.position = index + 1; });
    const withSub = trolleys.filter((trolley) => trolley.subunit_label).length;
    const scan = options.scan || null;
    container.hidden = false;
    container.classList.toggle("has-scan", Boolean(scan));
    let headAction = "";
    if (scan) headAction = `<button type="button" class="trolley-plates-scan-button" data-plate-scan>${SCAN_ICON}<span>Scan ${esc(plateLabel(trolleys[0]))}</span></button>`;
    else if (trolleys.length > 1) headAction = '<button type="button" data-plate-print="all">Print all labels</button>';
    container.innerHTML = `
      <div class="trolley-plates-head">
        <div class="trolley-plates-title">
          <strong>Trolleys needed for this customer</strong>
          <span class="trolley-plates-count">${trolleys.length}</span>
          ${withSub ? `<span>${withSub} with unit</span>` : ""}
          ${scan ? '<span class="trolley-plates-progress" data-plate-progress></span>' : ""}
        </div>
        ${headAction}
      </div>
      ${scan ? `
        <div class="trolley-plates-scanbar" data-plate-scanbar hidden>
          <input type="text" autocomplete="off" inputmode="text" data-plate-input aria-label="Scan trolley code" placeholder="Scan the trolley barcode">
          <button type="button" data-plate-add>Add</button>
          <button type="button" class="trolley-plates-later" data-plate-later>No trolley yet</button>
        </div>` : ""}
      <ol class="trolley-plates-list">
        ${trolleys.map((trolley, index) => `
          <li class="trolley-plate" data-plate-row="${index}">
            <span class="trolley-plate-badge">${esc(trolley.display_code || "?")}<small>#${trolley.position}</small></span>
            <span class="trolley-plate-name">
              ${trolleyName(data, trolley)
                ? `<b>${esc(trolleyName(data, trolley))}</b>`
                : `<b class="is-customer">${esc(data.customer_name)}</b>`}
              <small>${esc(trolleyMeta(trolley, trolleys.length))}</small>
            </span>
            ${scan ? `<span class="trolley-plate-scan missing" data-plate-slot="${index}">Missing</span>` : ""}
            <button type="button" class="trolley-plate-print" data-plate-print="${index}" title="Print label ${esc(plateLabel(trolley))}" aria-label="Print label ${esc(plateLabel(trolley))}">${PRINTER_ICON}</button>
            ${trolley.instructions ? `<span class="trolley-plate-instruction">⚠ ${esc(trolley.instructions)}</span>` : ""}
          </li>`).join("")}
      </ol>
      ${scan ? '<div class="trolley-plates-notice" data-plate-notice hidden></div>' : ""}`;
    container.onclick = (event) => {
      const print = event.target.closest("[data-plate-print]");
      if (print) {
        const key = print.dataset.platePrint;
        printLabels(data, key === "all" ? trolleys : [trolleys[Number(key)]]);
        return;
      }
      if (!scan) return;
      if (event.target.closest("[data-plate-scan]")) {
        // Every plate already has a trolley: the button opens the full scan review.
        if (container.dataset.plateFull === "1") scan.onReview?.();
        else toggleScanBar(container, true);
        return;
      }
      if (event.target.closest("[data-plate-add]")) { submitScan(container); return; }
      if (event.target.closest("[data-plate-later]")) { toggleScanBar(container, false); scan.onLater?.(); return; }
      if (event.target.closest("[data-plate-review]")) { scan.onReview?.(); return; }
      const remove = event.target.closest("[data-plate-remove]");
      if (remove) { scan.onRemove?.(remove.dataset.plateRemove); return; }
      const unlater = event.target.closest("[data-plate-unlater]");
      if (unlater) { scan.onUnlater?.(Number(unlater.dataset.plateUnlater)); toggleScanBar(container, true); return; }
      // A plate without a trolley can be picked: the next scan goes to that plate.
      const row = event.target.closest(".trolley-plate.is-pickable[data-plate-row]");
      if (row) { scan.onPick?.(Number(row.dataset.plateRow)); toggleScanBar(container, true); }
    };
    const input = container.querySelector("[data-plate-input]");
    if (input) {
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") { event.preventDefault(); submitScan(container); }
        if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); toggleScanBar(container, false); }
      });
    }
    container._plateScan = scan;
  }

  function toggleScanBar(container, open) {
    const bar = container.querySelector("[data-plate-scanbar]");
    if (!bar) return;
    bar.hidden = !open;
    if (open) setTimeout(() => bar.querySelector("[data-plate-input]")?.focus(), 30);
  }

  function submitScan(container) {
    const input = container.querySelector("[data-plate-input]");
    const code = String(input?.value || "").trim();
    if (!input || !code) { input?.focus(); return; }
    input.value = "";
    container._plateScan?.onAdd?.(code);
    input.focus();
  }

  // Scan state drawn by the page that owns the scan (Finish). view.slots has one entry
  // per plate row: {state: missing|next|checking|ok|wrong|pending, code, label}.
  function setScan(container, view) {
    if (!container || !container._plateScan || container.hidden) return;
    const slots = Array.isArray(view?.slots) ? view.slots : [];
    container.querySelectorAll("[data-plate-row]").forEach((row) => {
      const index = Number(row.dataset.plateRow);
      const slot = slots[index] || { state: "missing" };
      const cell = row.querySelector("[data-plate-slot]");
      row.classList.toggle("is-next", slot.state === "next");
      row.classList.toggle("is-ok", slot.state === "ok");
      row.classList.toggle("is-wrong", slot.state === "wrong");
      const pickable = slot.state === "missing" || slot.state === "next";
      row.classList.toggle("is-pickable", pickable);
      row.title = pickable ? "Click to scan the trolley for this plate" : "";
      if (!cell) return;
      cell.className = `trolley-plate-scan ${slot.state}`;
      cell.title = slot.title || "";
      const icon = slot.state === "ok" ? "✓ " : slot.state === "wrong" ? "✕ " : "";
      cell.innerHTML = slot.code
        ? `${icon}<code>${esc(slot.code)}</code>${slot.label ? `<span>· ${esc(slot.label)}</span>` : ""}<button type="button" data-plate-remove="${esc(slot.code)}" aria-label="Remove ${esc(slot.code)}" title="Remove this scan">×</button>`
        : Number.isInteger(slot.undo)
          ? `⌛ ${esc(slot.label || "No trolley yet")}<button type="button" data-plate-unlater="${slot.undo}" aria-label="Scan this trolley now" title="Scan this trolley now">×</button>`
          : esc(slot.label || "Missing");
    });
    const button = container.querySelector("[data-plate-scan]");
    if (button && view?.button) {
      button.className = `trolley-plates-scan-button${view.button.tone ? ` is-${view.button.tone}` : ""}`;
      button.querySelector("span").textContent = view.button.text;
    }
    const progress = container.querySelector("[data-plate-progress]");
    if (progress) {
      progress.className = `trolley-plates-progress${view?.progress?.tone ? ` ${view.progress.tone}` : ""}`;
      progress.textContent = view?.progress?.text || "";
    }
    const input = container.querySelector("[data-plate-input]");
    if (input) input.placeholder = view?.prompt || "Scan the trolley barcode";
    const later = container.querySelector("[data-plate-later]");
    if (later) later.hidden = Boolean(view?.hideLater);
    container.dataset.plateFull = view?.full ? "1" : "";
    if (view?.full) toggleScanBar(container, false);
    const notice = container.querySelector("[data-plate-notice]");
    if (notice) {
      notice.hidden = !view?.notice;
      notice.className = `trolley-plates-notice${view?.notice ? ` ${view.notice.tone}` : ""}`;
      notice.innerHTML = view?.notice?.html || "";
    }
  }

  function routeTextColor(hex) {
    const match = /^#?([0-9a-f]{6})$/i.exec(String(hex || ""));
    if (!match) return "#000";
    const value = parseInt(match[1], 16);
    const luminance = (0.299 * (value >> 16) + 0.587 * ((value >> 8) & 255) + 0.114 * (value & 255)) / 255;
    return luminance > 0.6 ? "#000" : "#fff";
  }

  // One half of an A4 sheet. The sheet holds the label twice, one copy turned
  // upside down, so the sheet folded in the middle and hung over the trolley
  // bar (fold on top) reads the right way up on both sides.
  function labelHalfHtml(data, trolley, total, flipped) {
    const sub = trolleyName(data, trolley);
    const days = Array.isArray(data.delivery_days) ? data.delivery_days : [];
    const color = /^#[0-9a-f]{6}$/i.test(String(data.route_color || "")) ? data.route_color : "";
    // The route sits on a band in its own colour so the staff see it at a glance.
    const band = data.route_code && color ? ` style="background:${color};color:${routeTextColor(color)}"` : "";
    return `
      <section class="half${flipped ? " flipped" : ""}">
        <img class="logo" src="${esc(logoSrc)}" alt="Elis">
        <div class="names">
          <div class="customer">${esc(data.customer_name)}</div>
          ${sub ? `<div class="sub">${esc(sub)}</div>` : ""}
        </div>
        <span class="trolley">${esc(`${trolley.display_code || ""} · ${trolley.position}/${total}`)}</span>
        <div class="foot${data.route_code ? " has-route" : ""}"${band}>
          ${data.route_code ? `<span class="route">Route ${esc(data.route_code)}</span>` : ""}
          ${days.length ? `<span class="days">Delivery: ${esc(days.join(" / "))}</span>` : ""}
        </div>
      </section>`;
  }

  function labelSheetHtml(data, trolley, total) {
    return `
      <div class="sheet">
        ${labelHalfHtml(data, trolley, total, true)}
        <div class="fold"></div>
        ${labelHalfHtml(data, trolley, total, false)}
      </div>`;
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
        @page{size:A4 portrait;margin:0}
        *{box-sizing:border-box}
        html,body{margin:0;padding:0}
        body{font-family:Arial,Helvetica,sans-serif;color:#000;-webkit-print-color-adjust:exact;print-color-adjust:exact}
        .sheet{position:relative;width:210mm;height:297mm;overflow:hidden;page-break-after:always;break-after:page}
        .sheet:last-child{page-break-after:auto;break-after:auto}
        .half{position:relative;width:210mm;height:148.5mm;padding:12mm 12mm 40mm;display:grid;place-items:center}
        .fold{position:absolute;left:0;right:0;top:148.5mm;border-top:1px dashed #9ca3af}
        .flipped{transform:rotate(180deg)}
        .logo{position:absolute;top:9mm;left:12mm;height:20mm}
        .names{text-align:center;display:grid;gap:6mm;max-width:100%;padding:0 2mm;margin-top:4mm}
        .customer{font-size:56pt;font-weight:800;line-height:1.1;overflow-wrap:anywhere}
        .sub{font-size:44pt;font-weight:700;line-height:1.1;overflow-wrap:anywhere}
        .trolley{position:absolute;top:12mm;right:12mm;font-size:19pt;font-weight:800;white-space:nowrap}
        .foot{position:absolute;left:8mm;right:8mm;bottom:7mm;height:28mm;display:flex;align-items:center;justify-content:center;gap:8mm;padding:0 7mm;border-top:1.5px solid #000;font-size:22pt;font-weight:800;white-space:nowrap}
        .foot.has-route{justify-content:space-between;border:2px solid #000;border-radius:4mm}
        .foot .route{font-size:40pt;font-weight:900;letter-spacing:.5pt}
        @media screen{body{background:#e5e7eb}.sheet{background:#fff;margin:8mm auto;box-shadow:0 2px 10px rgba(0,0,0,.2)}}
      </style></head><body>
      ${trolleys.map((trolley) => labelSheetHtml(data, trolley, all.length)).join("")}
      <script>
        // Long customer or unit names shrink until they fit between the logo and the footer.
        function fitText(){
          var mm = 96 / 25.4;
          Array.prototype.forEach.call(document.querySelectorAll('.names'), function(box){
            var parts = box.querySelectorAll('.customer,.sub');
            for (var step = 0; step < 30 && (box.scrollHeight > 78 * mm || box.scrollWidth > box.clientWidth + 1); step += 1) {
              Array.prototype.forEach.call(parts, function(el){ el.style.fontSize = (parseFloat(getComputedStyle(el).fontSize) * 0.94) + 'px'; });
            }
          });
          Array.prototype.forEach.call(document.querySelectorAll('.foot'), function(foot){
            for (var step = 0; step < 20 && foot.scrollWidth > foot.clientWidth + 1; step += 1) {
              Array.prototype.forEach.call(foot.querySelectorAll('*'), function(el){ el.style.fontSize = (parseFloat(getComputedStyle(el).fontSize) * 0.94) + 'px'; });
              foot.style.fontSize = (parseFloat(getComputedStyle(foot).fontSize) * 0.94) + 'px';
            }
          });
        }
        function printWhenReady(){
          fitText();
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

  async function mount(container, { rpc, productionFlowItemId, scan = null }) {
    if (!container) return null;
    injectStyles();
    const token = ++requestToken;
    container.hidden = true;
    container.innerHTML = "";
    container._plateScan = null;
    if (!productionFlowItemId) return null;
    try {
      const data = await rpc("get_production_flow_trolley_plates", { p_production_flow_item_id: productionFlowItemId });
      if (token !== requestToken) return null;
      render(container, data, { scan });
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
    container._plateScan = null;
  }

  // print: the Schedule Planner prints the same label from the published schedule,
  // without a production item.
  // setScan / openScan: Finish draws the scanned trolley of each plate row and opens
  // the inline scan field; other pages mount the plates without a scan.
  window.ELIS_TROLLEY_PLATES = { mount, clear, print: printLabels, setScan, openScan: (container) => toggleScanBar(container, true) };
})();
