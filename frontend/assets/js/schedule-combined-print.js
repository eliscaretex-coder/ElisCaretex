// Cloth + MOP combined weekly print.
// Shared by the Schedule Planner (customers.js) and Distribution (distribution.js).
// It only formats rows that the calling page already loaded through its own
// permission-checked RPCs; it reads nothing from the database itself.
(function () {
  "use strict";

  const DAY_NAMES = {
    1: "Monday",
    2: "Tuesday",
    3: "Wednesday",
    4: "Thursday",
    5: "Friday",
    6: "Saturday"
  };
  const PAGE_PAIRS = [[1, 2], [3, 4], [5, 6]];
  const SCHEDULED_MARK = "✓";

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function normalizeColor(value) {
    const color = String(value || "").trim();
    return /^#[0-9a-f]{6}$/i.test(color) ? color.toUpperCase() : null;
  }

  function contrastColor(value) {
    const color = normalizeColor(value);

    if (!color) {
      return "#0F172A";
    }

    const red = Number.parseInt(color.slice(1, 3), 16);
    const green = Number.parseInt(color.slice(3, 5), 16);
    const blue = Number.parseInt(color.slice(5, 7), 16);
    const luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255;

    return luminance > 0.55 ? "#0F172A" : "#FFFFFF";
  }

  function positiveNumber(value) {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 ? number : null;
  }

  function formatDate(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value || ""));

    if (!match) {
      return String(value || "");
    }

    return new Intl.DateTimeFormat("en-IE", {
      day: "2-digit",
      month: "short",
      year: "numeric",
      timeZone: "UTC"
    }).format(new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]))));
  }

  function generatedAt() {
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

  // Trolley text for one product, e.g. "2M + 1S". A scheduled product without a
  // trolley plan prints a tick, so the reader still sees the customer has it.
  function trolleyText(summary, total, scheduled) {
    const text = String(summary || "").trim();

    if (text) {
      return text;
    }

    const quantity = positiveNumber(total);

    if (quantity) {
      return String(quantity);
    }

    return scheduled ? SCHEDULED_MARK : "";
  }

  function compareOrder(left, right) {
    const leftOrder = positiveNumber(left) ?? Number.MAX_SAFE_INTEGER;
    const rightOrder = positiveNumber(right) ?? Number.MAX_SAFE_INTEGER;
    return leftOrder - rightOrder;
  }

  // Production view: Clothes and MOP planner rows of the same schedule day
  // become one customer row. Clothes production order leads; customers with
  // MOP only follow in MOP production order and are marked "M".
  function productionRows(clothesItems, mopItems) {
    const byDay = new Map();

    function entry(item) {
      const key = String(item?.schedule_day_id || `${item?.customer_id}|${item?.production_weekday}`);

      if (!byDay.has(key)) {
        byDay.set(key, {
          day: Number(item?.production_weekday),
          name: String(item?.customer_name || ""),
          color: item?.route_visual_color || null,
          clothes: null,
          mop: null
        });
      }

      return byDay.get(key);
    }

    (Array.isArray(clothesItems) ? clothesItems : []).forEach((item) => {
      entry(item).clothes = item;
    });
    (Array.isArray(mopItems) ? mopItems : []).forEach((item) => {
      const row = entry(item);
      row.mop = item;
      row.color = row.color || item?.route_visual_color || null;
    });

    return Array.from(byDay.values())
      .filter((row) => DAY_NAMES[row.day])
      .sort((left, right) => {
        const leftMopOnly = left.clothes ? 0 : 1;
        const rightMopOnly = right.clothes ? 0 : 1;

        return (
          left.day - right.day ||
          leftMopOnly - rightMopOnly ||
          compareOrder(
            left.clothes ? left.clothes.production_order : left.mop?.production_order,
            right.clothes ? right.clothes.production_order : right.mop?.production_order
          ) ||
          left.name.localeCompare(right.name)
        );
      })
      .map((row) => {
        const clothesOrder = positiveNumber(row.clothes?.production_order);
        const mopOrder = positiveNumber(row.mop?.production_order);

        return {
          day: row.day,
          group: null,
          order: row.clothes
            ? (clothesOrder ? String(clothesOrder) : "!")
            : (mopOrder ? `M${mopOrder}` : "M!"),
          name: row.name,
          color: row.color,
          cloth: row.clothes
            ? trolleyText(row.clothes.trolley_summary, row.clothes.planned_trolley_total, true)
            : "",
          mop: row.mop
            ? trolleyText(row.mop.trolley_summary, row.mop.planned_trolley_total, true)
            : ""
        };
      });
  }

  function breakdownSummary(breakdown, productCode) {
    return (Array.isArray(breakdown) ? breakdown : [])
      .filter((trolley) => String(trolley?.owner_product_code || "") === productCode)
      .map((trolley) =>
        `${Number(trolley.quantity) || 0}${trolley.display_code || trolley.trolley_type_code || ""}` +
        (trolley.empty_trolley ? " Empty" : "")
      )
      .join(" + ");
  }

  // Delivery view: Distribution planner rows grouped by delivery weekday and
  // route, in the defined delivery order (the same order as Route customers).
  function deliveryRows(distributionItems) {
    return (Array.isArray(distributionItems) ? distributionItems : [])
      .map((item) => {
        const products = Array.isArray(item?.scheduled_products) ? item.scheduled_products : [];
        const hasClothes = products.includes("CLOTHES");
        const hasMop = products.includes("MOP");
        const order = positiveNumber(item?.delivery_order);

        return {
          day: Number(item?.delivery_weekday),
          group: item?.default_route_code ? String(item.default_route_code) : "No route",
          groupLabel: item?.default_route_display_name ? String(item.default_route_display_name) : "",
          order: order ? String(order) : "",
          sortOrder: item?.delivery_order,
          name: String(item?.customer_name || ""),
          color: item?.default_route_color || null,
          cloth: trolleyText(breakdownSummary(item?.trolley_breakdown, "CLOTHES"), null, hasClothes),
          mop: trolleyText(breakdownSummary(item?.trolley_breakdown, "MOP"), null, hasMop),
          hasProduct: hasClothes || hasMop
        };
      })
      .filter((row) => DAY_NAMES[row.day] && row.hasProduct)
      .sort((left, right) =>
        left.day - right.day ||
        (left.group === "No route") - (right.group === "No route") ||
        left.group.localeCompare(right.group, undefined, { numeric: true }) ||
        compareOrder(left.sortOrder, right.sortOrder) ||
        left.name.localeCompare(right.name)
      );
  }

  function routeLabel(row) {
    if (row.group === "No route") {
      return "No route";
    }

    const name = String(row.groupLabel || "").trim();

    if (!name) {
      return `Route ${row.group}`;
    }

    return name.includes(row.group) ? name : `Route ${row.group} · ${name}`;
  }

  // Same idea as the Customer Planner list version: a deterministic code from
  // the printed content, so two printed copies are easy to compare.
  function listVersion(rows, mode, effectiveDate) {
    const source = JSON.stringify({
      mode,
      effectiveDate,
      rows: rows.map((row) => [row.day, row.group, row.order, row.name, normalizeColor(row.color), row.cloth, row.mop])
    });
    let hash = 2166136261;

    for (let index = 0; index < source.length; index += 1) {
      hash ^= source.charCodeAt(index);
      hash = Math.imul(hash, 16777619) >>> 0;
    }

    const modeCode = mode === "delivery" ? "CMD" : "CMP";
    const dateCode = String(effectiveDate || "").replace(/[^0-9]/g, "").slice(0, 8) || "NO-DATE";
    return `${modeCode}-${dateCode}-${hash.toString(36).toUpperCase().padStart(7, "0")}`;
  }

  function buildDocument(rows, mode, effectiveDateValue) {
    const isDelivery = mode === "delivery";
    const grouped = new Map(Object.keys(DAY_NAMES).map((day) => [Number(day), []]));

    rows.forEach((row) => grouped.get(row.day)?.push(row));

    // Each day becomes a list of printed lines: route headers (delivery) and customers.
    const lines = new Map();
    grouped.forEach((dayRows, day) => {
      const dayLines = [];
      let currentGroup = null;

      dayRows.forEach((row) => {
        if (isDelivery && row.group !== currentGroup) {
          currentGroup = row.group;
          dayLines.push({
            type: "group",
            label: routeLabel(row),
            color: row.color,
            count: dayRows.filter((item) => item.group === row.group).length
          });
        }

        dayLines.push({ type: "customer", row });
      });

      lines.set(day, dayLines);
    });

    const fontSizePt = 6.3;
    const smallFontPt = fontSizePt * 0.82;
    const headerFontSizePt = 9;
    const headerHeightMm = 5.5;
    const columnHeaderHeightMm = 3.6;
    const footerHeightMm = 4;
    const pagePaddingMm = 3;
    const maxLines = Math.max(1, ...Array.from(lines.values()).map((dayLines) => dayLines.length));
    const rowHeightMm = Math.min(
      9,
      (297 - pagePaddingMm * 2 - headerHeightMm - columnHeaderHeightMm - footerHeightMm - 6) / maxLines
    );
    const effectiveDate = formatDate(effectiveDateValue);
    const version = listVersion(rows, mode, effectiveDateValue);
    const printedAt = generatedAt();
    const title = isDelivery ? "Cloth + MOP Delivery Planner" : "Cloth + MOP Production Planner";
    const dayKind = isDelivery ? "Delivery" : "Production";
    const rowStyle = `height:${rowHeightMm}mm;line-height:${rowHeightMm}mm;`;

    function buildLine(line) {
      if (line.type === "group") {
        const background = normalizeColor(line.color) || "#E2E8F0";
        return `
          <tr>
            <td class="route-row" colspan="4" style="${rowStyle}font-size:${smallFontPt}pt;">
              <span class="route-swatch" style="background:${background};"></span>
              ${escapeHtml(line.label)} <span class="route-count">(${line.count})</span>
            </td>
          </tr>
        `;
      }

      const row = line.row;
      const background = normalizeColor(row.color) || "#F1F5F9";
      const foreground = contrastColor(background);
      const cellStyle = `${rowStyle}background:${background};color:${foreground};`;

      return `
        <tr>
          <td class="cell-order" style="${cellStyle}font-size:${smallFontPt}pt;">${escapeHtml(row.order)}</td>
          <td class="cell-name" style="${cellStyle}font-size:${fontSizePt}pt;">${escapeHtml(row.name)}</td>
          <td class="cell-trolley" style="${cellStyle}font-size:${smallFontPt}pt;">${escapeHtml(row.cloth)}</td>
          <td class="cell-trolley cell-mop" style="${cellStyle}font-size:${smallFontPt}pt;">${escapeHtml(row.mop)}</td>
        </tr>
      `;
    }

    function buildDay(day) {
      const dayLines = lines.get(day) || [];
      const customerCount = grouped.get(day)?.length || 0;

      return `
        <td class="day-column">
          <table class="day-table">
            <colgroup>
              <col class="col-order"><col><col class="col-cloth"><col class="col-mop">
            </colgroup>
            <thead>
              <tr>
                <th class="day-header" colspan="4" style="height:${headerHeightMm}mm;font-size:${headerFontSizePt}pt;">
                  ${escapeHtml(DAY_NAMES[day])}
                  <span class="day-count">(${customerCount})</span>
                  <span class="day-kind">${escapeHtml(dayKind)}</span>
                </th>
              </tr>
              <tr class="column-header" style="height:${columnHeaderHeightMm}mm;">
                <th>#</th><th>Customer</th><th>Cloth</th><th>MOP</th>
              </tr>
            </thead>
            <tbody>${dayLines.map(buildLine).join("")}</tbody>
          </table>
        </td>
      `;
    }

    const pagesHtml = PAGE_PAIRS.map((pair, index) => `
      <section class="print-page${index === PAGE_PAIRS.length - 1 ? " last" : ""}">
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
          ${escapeHtml(title)} · List version ${escapeHtml(version)} · Effective ${escapeHtml(effectiveDate)} · Generated ${escapeHtml(printedAt)}
        </footer>
      </section>
    `).join("");

    const toolbarMeta = isDelivery
      ? `Effective date ${escapeHtml(effectiveDate)} · grouped by delivery day and route · delivery order left · ${SCHEDULED_MARK} = scheduled without trolley plan`
      : `Effective date ${escapeHtml(effectiveDate)} · grouped by production day · production order left (M = MOP only) · ${SCHEDULED_MARK} = scheduled without trolley plan`;

    return `<!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>${escapeHtml(title)} - ${escapeHtml(effectiveDate)}</title>
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
            .print-toolbar strong { font-weight: 800; white-space: nowrap; }
            .print-toolbar-meta { color: #CBD5E1; }
            .print-toolbar-actions { display: flex; gap: 8px; margin-left: auto; }
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
            .page-table { width: 100%; height: 100%; border-collapse: collapse; table-layout: fixed; }
            .day-column { width: 48.5%; vertical-align: top; }
            .page-gap { width: 3%; }
            .day-table { width: 100%; border-collapse: collapse; table-layout: fixed; }
            .col-order { width: 7mm; }
            .col-cloth { width: 17mm; }
            .col-mop { width: 13mm; }
            .day-header {
              padding: 0 1.5mm;
              background: #111827;
              color: #FFFFFF;
              text-align: left;
              text-transform: uppercase;
              font-weight: 900;
            }
            .day-count { font-size: 10px; opacity: 0.7; }
            .day-kind { float: right; font-size: 6pt; font-weight: 700; letter-spacing: 0.06em; opacity: 0.7; }
            .column-header th {
              padding: 0 1mm;
              background: #E2E8F0;
              color: #334155;
              font-size: 5pt;
              font-weight: 800;
              letter-spacing: 0.04em;
              text-align: left;
              text-transform: uppercase;
            }
            .column-header th:nth-child(3),
            .column-header th:nth-child(4) { text-align: right; }
            .day-table td { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
            .cell-order { padding: 0 0 0 1.2mm; font-weight: 800; opacity: 0.85; }
            .cell-name { padding: 0 1mm; font-weight: 800; text-align: center; }
            .cell-trolley { padding: 0 1mm; font-weight: 900; text-align: right; }
            .cell-mop { border-left: 0.3mm solid rgba(15, 23, 42, 0.35); }
            .route-row {
              padding: 0 1.5mm;
              background: #FFFFFF;
              color: #0F172A;
              font-weight: 900;
              letter-spacing: 0.03em;
              text-transform: uppercase;
              border-bottom: 0.3mm solid #0F172A;
            }
            .route-swatch {
              display: inline-block;
              width: 2.6mm;
              height: 2.6mm;
              margin-right: 1mm;
              border: 0.2mm solid #0F172A;
              vertical-align: middle;
            }
            .route-count { font-weight: 700; opacity: 0.65; }
            .print-version-footer {
              position: absolute;
              left: 4mm;
              right: 4mm;
              bottom: 2.2mm;
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
              .print-page { margin: 12px auto; box-shadow: 0 4px 20px rgba(0, 0, 0, 0.2); }
            }
            @media print {
              @page { size: A4 portrait; margin: 0; }
              .print-toolbar { display: none !important; }
              .print-page { margin: 0; break-after: page; page-break-after: always; }
              .print-page.last { break-after: auto; page-break-after: auto; }
            }
          </style>
        </head>
        <body>
          <div class="print-toolbar">
            <strong>${escapeHtml(title)}</strong>
            <span class="print-toolbar-meta">${toolbarMeta}</span>
            <div class="print-toolbar-actions">
              <button id="combinedPrintAction" class="print-action" type="button">Print</button>
              <button id="combinedPrintClose" class="close-action" type="button">Close</button>
            </div>
          </div>
          ${pagesHtml}
          <script>
            document.getElementById("combinedPrintAction").addEventListener("click", function () { window.print(); });
            document.getElementById("combinedPrintClose").addEventListener("click", function () { window.close(); });
          <\/script>
        </body>
      </html>`;
  }

  function messageDocument(title, message, isError) {
    return `<!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>${escapeHtml(title)}</title>
          <style>
            body { margin: 0; font-family: "Segoe UI", Arial, sans-serif; background: #F1F5F9; color: #0F172A; }
            main { min-height: 100vh; display: grid; place-items: center; padding: 24px; text-align: center; }
            div { max-width: 560px; padding: 18px; border-radius: 12px; ${isError ? "border: 1px solid #FECACA; background: #FEF2F2; color: #991B1B;" : ""} }
            strong { display: block; margin-bottom: 6px; font-size: 18px; }
            button { margin-top: 16px; height: 36px; padding: 0 16px; border: 0; border-radius: 8px; background: #475569; color: #FFFFFF; cursor: pointer; font-weight: 800; }
          </style>
        </head>
        <body>
          <main><div><strong>${escapeHtml(title)}</strong><span>${escapeHtml(message)}</span>${isError ? '<br><button id="combinedPrintErrorClose" type="button">Close</button>' : ""}</div></main>
          ${isError ? '<script>document.getElementById("combinedPrintErrorClose").addEventListener("click", function () { window.close(); });<\/script>' : ""}
        </body>
      </html>`;
  }

  function writeDocument(printWindow, html) {
    printWindow.document.open();
    printWindow.document.write(html);
    printWindow.document.close();
  }

  // Opens the print window straight away (inside the click, so pop-up blockers
  // allow it), then loads the rows and writes the planner.
  // options.mode: "production" | "delivery"
  // options.load: async () => normalized rows (use productionRows / deliveryRows)
  async function open(options) {
    const printWindow = window.open("", "_blank", "width=900,height=1000,scrollbars=yes");

    if (!printWindow) {
      window.alert("Please allow pop-ups for this site to print the Cloth + MOP planner.");
      return false;
    }

    writeDocument(printWindow, messageDocument("Preparing Cloth + MOP planner...", "Loading the complete weekly schedule.", false));

    try {
      const rows = await options.load();

      if (!rows.length) {
        throw new Error("No Cloth or MOP schedule rows are available to print.");
      }

      writeDocument(printWindow, buildDocument(rows, options.mode, options.effectiveDate));
      printWindow.focus();
      return true;
    } catch (error) {
      console.error("Cloth + MOP print failed:", error);

      if (!printWindow.closed) {
        writeDocument(
          printWindow,
          messageDocument("The Cloth + MOP planner could not be prepared.", error?.message || String(error), true)
        );
      }

      return false;
    }
  }

  window.ElisCombinedSchedulePrint = { open, productionRows, deliveryRows, buildDocument };
})();
