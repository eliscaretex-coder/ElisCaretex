"use strict";

// Company Documents: company policies and SSOW.
// Staff read each document and confirm it; managers publish, replace and
// follow up. Files live in the private "company-documents" Storage bucket,
// one file per document: a new version replaces the file and the previous
// one is removed. A document can be limited to areas; staff see and confirm
// only the documents of their areas. Authorization is enforced by the RPCs
// and Storage policies (202610280001_company_documents.sql,
// 202610280005_company_document_areas.sql).
(() => {
  const BUCKET = "company-documents";
  const MAX_BYTES = 20 * 1024 * 1024;
  const FILE_TYPES = ["application/pdf", "image/jpeg", "image/png", "image/webp"];
  const SECTIONS = [
    { code: "POLICY", title: "Company policies", short: "Company policy" },
    { code: "SSOW", title: "SSOW · Safe systems of work", short: "SSOW" }
  ];
  const STATUS = {
    PENDING: { label: "To read", tone: "pending" },
    OPENED: { label: "Opened, not confirmed", tone: "opened" },
    RECONFIRM: { label: "Updated, confirm again", tone: "reconfirm" },
    ACKNOWLEDGED: { label: "Confirmed", tone: "done" },
    INFORMATION: { label: "For information", tone: "info" },
    OTHER_AREA: { label: "Other area", tone: "muted" }
  };
  // Areas a document can be limited to (company_document_areas.area_code).
  const AREAS = [
    { code: "SORTING", label: "Sorting" }, { code: "FINISH", label: "Finish" }, { code: "MOP", label: "MOP" },
    { code: "DISTRIBUTION", label: "Distribution" }, { code: "CLEANER", label: "Cleaner" },
    { code: "LABEL", label: "Label" }, { code: "MAINTENANCE", label: "Maintenance" }
  ];
  const NEEDS_ACTION = new Set(["PENDING", "OPENED", "RECONFIRM"]);

  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const date = (value) => value ? new Intl.DateTimeFormat("en-IE", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(value)) : "—";
  const dateTime = (value) => value ? new Intl.DateTimeFormat("en-IE", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "—";
  const section = (code) => SECTIONS.find((item) => item.code === code) || SECTIONS[0];
  const areaName = (code) => AREAS.find((area) => area.code === code)?.label || code;
  const areaLabel = (areas) => (areas || []).length ? areas.map(areaName).join(", ") : "All areas";
  const areaTags = (areas) => (areas || []).length
    ? areas.map((code) => `<em class="docs-area-tag">${esc(areaName(code))}</em>`).join("")
    : '<em class="docs-area-tag all">All areas</em>';
  // A document with no area is for everyone.
  const forArea = (docAreas, personAreas) => !(docAreas || []).length || (docAreas || []).some((code) => (personAreas || []).includes(code));
  const size = (bytes) => !bytes ? "" : bytes >= 1048576 ? `${(bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;

  const state = {
    mine: [], canManage: false, canViewStatus: false,
    admin: null, adminLoaded: false,
    mineFilter: "all", peopleFilter: "pending", readersFilter: "ALL",
    viewing: null, readersDoc: null, editing: null, versioning: null
  };

  async function rpc(name, args) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function friendly(error) {
    const text = error?.message || String(error || "Something went wrong.");
    if (/row-level security|not authorized|permission/i.test(text)) return "Your account cannot do this. Ask a manager for Company Documents access.";
    if (/exceeded the maximum allowed size|too large/i.test(text)) return "The file is larger than 20 MB.";
    return text;
  }

  function message(text, tone = "") {
    const element = $("docsMessage");
    element.textContent = text || "";
    element.className = `docs-message${tone ? ` ${tone}` : ""}${text ? "" : " hidden"}`;
    if (text && tone !== "error") window.clearTimeout(message.timer), message.timer = window.setTimeout(() => message(""), 6000);
  }

  function statusPill(code) {
    const status = STATUS[code] || STATUS.PENDING;
    return `<span class="docs-pill ${status.tone}">${esc(status.label)}</span>`;
  }

  function fileBadge(mime) {
    const pdf = mime === "application/pdf";
    return `<span class="docs-file-badge ${pdf ? "pdf" : "img"}" aria-hidden="true">${pdf ? "PDF" : "IMG"}</span>`;
  }

  // ---------------------------------------------------------------- Staff

  async function loadMine() {
    const data = await rpc("get_my_company_documents");
    state.mine = data?.documents || [];
    state.canManage = !!data?.can_manage;
    state.canViewStatus = !!data?.can_view_status || state.canManage;
    $("docsTabs").classList.toggle("hidden", !state.canViewStatus);
    document.querySelector('[data-tab="manage"]').classList.toggle("hidden", !state.canViewStatus);
    document.querySelector('[data-tab="people"]').classList.toggle("hidden", !state.canViewStatus);
    $("addDocument").classList.toggle("hidden", !state.canManage);
    renderMine();
  }

  function renderHeadStats() {
    const pending = state.mine.filter((doc) => NEEDS_ACTION.has(doc.status)).length;
    const confirmed = state.mine.filter((doc) => doc.status === "ACKNOWLEDGED").length;
    $("docsHeadStats").innerHTML = `
      <div class="${pending ? "warn" : "good"}"><b>${pending}</b><small>to confirm</small></div>
      <div><b>${confirmed}</b><small>confirmed</small></div>
      <div><b>${state.mine.filter((doc) => doc.for_me !== false).length}</b><small>documents</small></div>`;
    $("minePendingCount").textContent = pending;
  }

  function renderMine() {
    renderHeadStats();
    const term = $("mineSearch").value.trim().toLowerCase();
    const list = state.mine.filter((doc) => (state.mineFilter === "all" || NEEDS_ACTION.has(doc.status)) &&
      (!term || `${doc.title} ${doc.reference_code || ""} ${doc.description || ""}`.toLowerCase().includes(term)));
    if (!state.mine.length) {
      $("mineList").innerHTML = '<p class="docs-empty">No company documents have been published yet.</p>';
      return;
    }
    if (!list.length) {
      $("mineList").innerHTML = state.mineFilter === "pending" && !term
        ? '<p class="docs-empty good">You are up to date. Every document is confirmed.</p>'
        : '<p class="docs-empty">No documents match your search.</p>';
      return;
    }
    $("mineList").innerHTML = SECTIONS.map((item) => {
      // Managers also see other areas' documents; theirs come first.
      const docs = list.filter((doc) => doc.category === item.code)
        .sort((a, b) => Number(b.for_me !== false) - Number(a.for_me !== false));
      if (!docs.length) return "";
      return `<section class="docs-section"><h2>${esc(item.title)} <b>${docs.length}</b></h2>
        <div class="docs-cards">${docs.map(mineCard).join("")}</div></section>`;
    }).join("");
  }

  function mineCard(doc) {
    const action = NEEDS_ACTION.has(doc.status);
    const detail = doc.status === "ACKNOWLEDGED"
      ? `Confirmed ${date(doc.acknowledged_at)}`
      : doc.status === "RECONFIRM" ? `Updated ${date(doc.version_published_at)}${doc.last_change_note ? `: ${doc.last_change_note}` : ""}`
      : doc.status === "OTHER_AREA" ? `For ${areaLabel(doc.areas)} · not on your list to confirm`
      : `Version ${doc.current_version} · ${date(doc.version_published_at)}`;
    return `<button type="button" class="docs-card${action ? " action" : ""}${doc.status === "OTHER_AREA" ? " other" : ""}" data-open="${esc(doc.document_id)}">
      ${fileBadge(doc.mime_type)}
      <span class="docs-card-copy">
        <span class="docs-card-top">${doc.reference_code ? `<em>${esc(doc.reference_code)}</em>` : ""}${(doc.areas || []).length ? areaTags(doc.areas) : ""}${statusPill(doc.status)}</span>
        <strong>${esc(doc.title)}</strong>
        ${doc.description ? `<span class="docs-card-desc">${esc(doc.description)}</span>` : ""}
        <small>${esc(detail)}</small>
      </span>
      <span class="docs-card-go">${action ? "Read" : "Open"}</span>
    </button>`;
  }

  async function signedUrl(doc, download = false) {
    const { data, error } = await client.storage.from(doc.storage_bucket || BUCKET)
      .createSignedUrl(doc.storage_path, 900, download ? { download: doc.original_file_name || true } : undefined);
    if (error) throw error;
    return data.signedUrl;
  }

  async function openViewer(doc, { record = true } = {}) {
    state.viewing = doc;
    const dialog = $("viewer");
    $("viewerSection").textContent = `${section(doc.category).short.toUpperCase()}${doc.reference_code ? ` · ${doc.reference_code}` : ""}`;
    $("viewerTitle").textContent = doc.title;
    $("viewerMeta").textContent = `Version ${doc.current_version} · published ${date(doc.version_published_at)} · ${areaLabel(doc.areas)}`;
    $("viewerBody").innerHTML = '<p class="docs-empty">Opening document…</p>';
    $("viewerOpen").removeAttribute("href");
    $("viewerNotice").classList.toggle("hidden", doc.status !== "RECONFIRM");
    $("viewerNotice").textContent = doc.status === "RECONFIRM"
      ? `This document was updated on ${date(doc.version_published_at)}${doc.last_change_note ? `: ${doc.last_change_note.replace(/[.\s]+$/, "")}` : ""}. Please read it and confirm again.`
      : "";
    renderAck(doc);
    if (!dialog.open) dialog.showModal();
    try {
      const url = await signedUrl(doc);
      $("viewerOpen").href = url;
      $("viewerBody").innerHTML = doc.mime_type === "application/pdf"
        ? `<iframe title="${esc(doc.title)}" src="${esc(url)}#view=FitH"></iframe>
           <a class="docs-mobile-open" href="${esc(url)}" target="_blank" rel="noopener">Tap to open the PDF</a>`
        : `<img alt="${esc(doc.title)}" src="${esc(url)}">`;
      if (record && state.mine.some((item) => item.document_id === doc.document_id)) {
        const status = await rpc("record_company_document_open", { p_document_id: doc.document_id });
        Object.assign(doc, status);
        renderAck(doc);
        renderMine();
      }
    } catch (error) {
      $("viewerBody").innerHTML = `<p class="docs-empty error">${esc(friendly(error))}</p>`;
    }
  }

  function renderAck(doc) {
    const mine = state.mine.find((item) => item.document_id === doc.document_id);
    const form = $("ackForm");
    const done = $("ackDone");
    form.classList.toggle("hidden", !mine || !NEEDS_ACTION.has(mine.status));
    done.classList.toggle("hidden", !mine || NEEDS_ACTION.has(mine.status));
    if (!mine) return;
    $("ackCheck").checked = false;
    $("ackButton").disabled = true;
    $("ackLabel").textContent = `I have read and understood "${mine.title}" (version ${mine.current_version}).`;
    done.innerHTML = mine.status === "ACKNOWLEDGED"
      ? `<span class="docs-pill done">Confirmed</span> You confirmed this document on ${esc(dateTime(mine.acknowledged_at))}.`
      : mine.status === "OTHER_AREA"
        ? `<span class="docs-pill muted">Other area</span> This document is for ${esc(areaLabel(mine.areas))}. It is not on your list to confirm.`
        : '<span class="docs-pill info">For information</span> This document does not need a confirmation.';
  }

  async function acknowledge(event) {
    event.preventDefault();
    const doc = state.viewing;
    if (!doc || !$("ackCheck").checked) return;
    const button = $("ackButton");
    button.disabled = true;
    button.textContent = "Confirming…";
    try {
      const status = await rpc("acknowledge_company_document", { p_document_id: doc.document_id, p_version: doc.current_version });
      Object.assign(doc, status);
      renderAck(doc);
      renderMine();
      refreshNavBadge();
      message(`Thank you. "${doc.title}" is confirmed.`, "good");
      state.adminLoaded = false;
    } catch (error) {
      message(friendly(error), "error");
      if (error?.code === "40001") await loadMine().catch(() => {});
    } finally {
      button.textContent = "Confirm";
      button.disabled = !$("ackCheck").checked;
    }
  }

  async function refreshNavBadge() {
    try {
      const data = await rpc("get_my_company_document_summary");
      // Keep the sidebar badge in step after a confirmation on this page.
      const item = document.querySelector('.operational-nav-item[data-module-id="company-documents"]');
      const badge = item?.querySelector(".operational-nav-badge");
      const count = Number(data?.pending_count || 0);
      item?.classList.toggle("has-attention", count > 0);
      if (badge) { badge.hidden = count === 0; badge.textContent = count > 99 ? "99+" : String(count); }
    } catch (_) { /* badge only */ }
  }

  // -------------------------------------------------------------- Managers

  async function loadAdmin(force = false) {
    if (state.adminLoaded && !force) return;
    $("manageList").innerHTML = '<p class="docs-empty">Loading documents…</p>';
    state.admin = await rpc("get_company_documents_admin");
    state.adminLoaded = true;
    state.canManage = !!state.admin.can_manage;
    $("addDocument").classList.toggle("hidden", !state.canManage);
    renderManage();
    renderPeople();
    cleanOrphans(state.admin.orphan_paths || []);
  }

  // Files left behind by an interrupted replacement are removed quietly.
  async function cleanOrphans(paths) {
    if (!state.canManage || !paths.length) return;
    const { error } = await client.storage.from(BUCKET).remove(paths);
    if (error) console.warn("Old company document files could not be removed.", error);
  }

  function statusesFor(documentId) {
    return (state.admin?.statuses || []).filter((row) => row.document_id === documentId);
  }

  function progress(doc) {
    const rows = statusesFor(doc.document_id);
    const count = (code) => rows.filter((row) => row.status === code).length;
    return { total: rows.length, done: count("ACKNOWLEDGED"), opened: count("OPENED"), reconfirm: count("RECONFIRM"), pending: count("PENDING") };
  }

  function renderManage() {
    if (!state.admin) return;
    const term = $("manageSearch").value.trim().toLowerCase();
    const category = $("manageCategory").value;
    const area = $("manageArea").value;
    const archived = $("manageArchived").checked;
    const docs = (state.admin.documents || []).filter((doc) =>
      (archived || doc.document_status === "ACTIVE") && (!category || doc.category === category) &&
      (!area || forArea(doc.areas, [area])) &&
      (!term || `${doc.title} ${doc.reference_code || ""}`.toLowerCase().includes(term)));
    if (!docs.length) {
      $("manageList").innerHTML = (state.admin.documents || []).length
        ? '<p class="docs-empty">No documents match these filters.</p>'
        : `<div class="docs-empty"><strong>No documents yet.</strong><br>${state.canManage ? "Use “Add document” to publish the first company policy or SSOW." : "Managers have not published any document yet."}</div>`;
      return;
    }
    $("manageList").innerHTML = `<div class="docs-table-head"><span>Document</span><span>Version</span><span>Read status</span><span></span></div>` +
      docs.map(manageRow).join("");
  }

  function manageRow(doc) {
    const active = doc.document_status === "ACTIVE";
    const p = progress(doc);
    const percent = p.total ? Math.round((p.done / p.total) * 100) : 0;
    const readStatus = !active
      ? '<span class="docs-pill muted">Archived</span>'
      : !p.total
        ? `<span class="docs-pill muted">Nobody yet</span><small>No account with a login in ${esc(areaLabel(doc.areas))}</small>`
      : !doc.requires_acknowledgement
        ? `<span class="docs-pill info">For information</span><small>${p.total} staff can read it</small>`
        : `<div class="docs-progress" role="img" aria-label="${p.done} of ${p.total} confirmed"><i style="width:${percent}%"></i></div>
           <small><b>${p.done}</b> of ${p.total} confirmed${p.total - p.done ? ` · <span class="warn">${p.total - p.done} missing</span>` : ""}</small>`;
    const manage = state.canManage;
    return `<article class="docs-row${active ? "" : " archived"}" data-doc="${esc(doc.document_id)}">
      <div class="docs-row-main">
        ${fileBadge(doc.mime_type)}
        <div>
          <span class="docs-card-top"><em class="docs-section-tag ${doc.category === "SSOW" ? "ssow" : "policy"}">${esc(section(doc.category).short)}</em>${doc.reference_code ? `<em>${esc(doc.reference_code)}</em>` : ""}</span>
          <strong>${esc(doc.title)}</strong>
          <span class="docs-area-row">${areaTags(doc.areas)}</span>
          <small>${esc(doc.original_file_name || "")}${doc.file_size_bytes ? ` · ${size(doc.file_size_bytes)}` : ""}</small>
        </div>
      </div>
      <div class="docs-row-version"><strong>v${doc.current_version}</strong><small>${esc(date(doc.version_published_at))}${doc.updated_by_name ? ` · ${esc(doc.updated_by_name)}` : ""}</small></div>
      <div class="docs-row-status">${readStatus}</div>
      <div class="docs-row-actions">
        <button type="button" data-action="view">View</button>
        ${active ? '<button type="button" data-action="readers">Who read</button>' : ""}
        ${manage && active ? '<button type="button" data-action="version" class="docs-accent">New version</button>' : ""}
        <details class="docs-more"><summary aria-label="More actions">⋯</summary><div>
          <button type="button" data-action="history">Update log</button>
          ${manage ? '<button type="button" data-action="edit">Edit details</button>' : ""}
          ${manage && active ? '<button type="button" data-action="archive">Archive</button>' : ""}
          ${manage && !active ? '<button type="button" data-action="restore">Restore</button>' : ""}
          ${manage ? '<button type="button" data-action="delete" class="danger">Delete</button>' : ""}
        </div></details>
      </div>
    </article>`;
  }

  function adminDoc(id) {
    return (state.admin?.documents || []).find((doc) => doc.document_id === id);
  }

  async function onManageClick(event) {
    const button = event.target.closest("[data-action]");
    if (!button) return;
    const doc = adminDoc(button.closest("[data-doc]")?.dataset.doc);
    if (!doc) return;
    button.closest("details")?.removeAttribute("open");
    const action = button.dataset.action;
    if (action === "view") return openViewer(doc, { record: false });
    if (action === "readers") return openReaders(doc);
    if (action === "version") return openVersion(doc);
    if (action === "history") return openHistory(doc);
    if (action === "edit") return openDocForm(doc);
    if (action === "archive" || action === "restore") return changeStatus(doc, action === "archive" ? "ARCHIVED" : "ACTIVE");
    if (action === "delete") return changeStatus(doc, "DELETED");
  }

  async function changeStatus(doc, status) {
    const prompts = {
      ARCHIVED: `Archive "${doc.title}"?\n\nStaff will no longer see it. The file and the read records are kept and you can restore it later.`,
      ACTIVE: `Restore "${doc.title}"? Staff will see it again.`,
      DELETED: `Delete "${doc.title}" permanently?\n\nThe file is removed from storage and cannot be restored. The update log and the read records are kept.`
    };
    if (!window.confirm(prompts[status])) return;
    try {
      const result = await rpc("set_company_document_status", { p_document_id: doc.document_id, p_status: status, p_note: null, p_row_version: doc.row_version });
      if (result?.old_storage_path) {
        const { error } = await client.storage.from(BUCKET).remove([result.old_storage_path]);
        if (error) console.warn("The deleted document file will be removed on the next visit.", error);
      }
      message(status === "DELETED" ? "Document deleted." : status === "ARCHIVED" ? "Document archived." : "Document restored.", "good");
      await Promise.all([loadAdmin(true), loadMine()]);
    } catch (error) {
      message(friendly(error), "error");
    }
  }

  // ------------------------------------------------------ Readers & people

  function personStatusRows(doc) {
    const people = new Map((state.admin?.people || []).map((person) => [person.auth_user_id, person]));
    return statusesFor(doc.document_id)
      .map((row) => ({ ...row, person: people.get(row.auth_user_id) || { display_name: "Account" } }))
      .sort((a, b) => readerOrder(a.status) - readerOrder(b.status) || String(a.person.display_name).localeCompare(b.person.display_name));
  }

  function readerOrder(code) {
    return { PENDING: 0, RECONFIRM: 1, OPENED: 2, ACKNOWLEDGED: 3, INFORMATION: 4 }[code] ?? 5;
  }

  function openReaders(doc) {
    state.readersDoc = doc;
    state.readersFilter = "ALL";
    $("readersSearch").value = "";
    $("readersSection").textContent = `${section(doc.category).short.toUpperCase()}${doc.reference_code ? ` · ${doc.reference_code}` : ""}`;
    $("readersTitle").textContent = doc.title;
    $("readersMeta").textContent = `Version ${doc.current_version} · published ${date(doc.version_published_at)} · For ${areaLabel(doc.areas)}`;
    renderReaders();
    $("readersDialog").showModal();
  }

  function renderReaders() {
    const doc = state.readersDoc;
    if (!doc) return;
    const rows = personStatusRows(doc);
    const count = (code) => rows.filter((row) => row.status === code).length;
    const missing = rows.filter((row) => NEEDS_ACTION.has(row.status)).length;
    const chips = doc.requires_acknowledgement ? [
      ["ALL", "Everyone", rows.length], ["MISSING", "Not confirmed", missing], ["ACKNOWLEDGED", "Confirmed", count("ACKNOWLEDGED")],
      ["OPENED", "Opened only", count("OPENED")], ["PENDING", "Not opened", count("PENDING")], ["RECONFIRM", "Must confirm again", count("RECONFIRM")]
    ] : [["ALL", "Everyone", rows.length]];
    $("readersFilters").innerHTML = chips.map(([code, label, n]) =>
      `<button type="button" class="docs-chip${state.readersFilter === code ? " active" : ""}" data-reader-filter="${code}">${esc(label)} <b>${n}</b></button>`).join("");
    const term = $("readersSearch").value.trim().toLowerCase();
    const filtered = rows.filter((row) =>
      (state.readersFilter === "ALL" || (state.readersFilter === "MISSING" ? NEEDS_ACTION.has(row.status) : row.status === state.readersFilter)) &&
      (!term || `${row.person.display_name} ${row.person.job_title_name || ""} ${row.person.employee_code || ""}`.toLowerCase().includes(term)));
    $("readersList").innerHTML = filtered.length ? filtered.map((row) => `
      <div class="docs-reader">
        <span class="docs-avatar" aria-hidden="true">${esc(initials(row.person.display_name))}</span>
        <span class="docs-reader-name"><strong>${esc(row.person.display_name)}</strong><small>${esc(personLine(row.person))}</small></span>
        ${statusPill(row.status)}
        <small class="docs-reader-when">${esc(readerWhen(row))}</small>
      </div>`).join("") : '<p class="docs-empty">Nobody in this list.</p>';
  }

  function readerWhen(row) {
    if (row.status === "ACKNOWLEDGED") return `Confirmed ${dateTime(row.acknowledged_at)}${row.acknowledged_version ? ` (v${row.acknowledged_version})` : ""}`;
    if (row.status === "RECONFIRM") return `Confirmed v${row.acknowledged_version} on ${date(row.acknowledged_at)}`;
    if (row.opened_at) return `Opened ${dateTime(row.opened_at)}`;
    return "Not opened yet";
  }

  function personLine(person) {
    return [person.job_title_name, person.employee_code, (person.areas || []).length ? person.areas.map(areaName).join(", ") : ""].filter(Boolean).join(" · ") || "Staff";
  }

  function initials(name) {
    return String(name || "").trim().split(/\s+/).slice(0, 2).map((part) => part[0] || "").join("").toUpperCase() || "—";
  }

  function renderPeople() {
    if (!state.admin) return;
    const docs = new Map((state.admin.documents || []).filter((doc) => doc.document_status === "ACTIVE" && doc.requires_acknowledgement).map((doc) => [doc.document_id, doc]));
    const term = $("peopleSearch").value.trim().toLowerCase();
    const area = $("peopleArea").value;
    const people = (state.admin.people || []).filter((person) => !area || (person.areas || []).includes(area)).map((person) => {
      const rows = (state.admin.statuses || []).filter((row) => row.auth_user_id === person.auth_user_id && docs.has(row.document_id));
      return { person, total: rows.length, done: rows.filter((row) => row.status === "ACKNOWLEDGED").length,
        missing: rows.filter((row) => NEEDS_ACTION.has(row.status)).map((row) => ({ ...row, doc: docs.get(row.document_id) })) };
    }).filter((item) => (state.peopleFilter === "all" || item.missing.length) &&
      (!term || `${item.person.display_name} ${item.person.job_title_name || ""} ${item.person.employee_code || ""}`.toLowerCase().includes(term)))
      .sort((a, b) => b.missing.length - a.missing.length || String(a.person.display_name).localeCompare(b.person.display_name));
    if (!docs.size) {
      $("peopleList").innerHTML = '<p class="docs-empty">No published document needs confirmation yet.</p>';
      return;
    }
    $("peopleList").innerHTML = people.length ? people.map((item) => `
      <details class="docs-person"${item.missing.length ? "" : " data-complete"}>
        <summary>
          <span class="docs-avatar" aria-hidden="true">${esc(initials(item.person.display_name))}</span>
          <span class="docs-reader-name"><strong>${esc(item.person.display_name)}</strong><small>${esc(personLine(item.person))}</small></span>
          <span class="docs-person-count">${item.missing.length ? `<span class="docs-pill pending">${item.missing.length} to confirm</span>` : '<span class="docs-pill done">All confirmed</span>'}<small>${item.done} of ${item.total} confirmed</small></span>
        </summary>
        ${item.missing.length ? `<ul>${item.missing.map((row) => `<li><span>${esc(row.doc.title)}${row.doc.reference_code ? ` <em>${esc(row.doc.reference_code)}</em>` : ""}</span>${statusPill(row.status)}</li>`).join("")}</ul>` : '<p class="docs-person-ok">Every document requiring confirmation is confirmed.</p>'}
      </details>`).join("") : `<p class="docs-empty good">${state.peopleFilter === "pending" && !term ? "Everyone has confirmed every document." : "Nobody matches your search."}</p>`;
  }

  function downloadCsv(name, rows) {
    const csv = rows.map((row) => row.map((value) => `"${String(value ?? "").replace(/"/g, '""')}"`).join(",")).join("\r\n");
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" }));
    link.download = name;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  }

  function exportReaders() {
    const doc = state.readersDoc;
    if (!doc) return;
    downloadCsv(`${(doc.reference_code || doc.title).replace(/[^a-z0-9-]+/gi, "-")}-read-status.csv`, [
      ["Document", "Version", "Document areas", "Staff", "Job title", "Employee code", "Staff areas", "Status", "Opened", "Confirmed", "Confirmed version"],
      ...personStatusRows(doc).map((row) => [doc.title, doc.current_version, areaLabel(doc.areas), row.person.display_name, row.person.job_title_name, row.person.employee_code, (row.person.areas || []).map(areaName).join(", "),
        STATUS[row.status]?.label || row.status, row.opened_at ? dateTime(row.opened_at) : "", row.acknowledged_at ? dateTime(row.acknowledged_at) : "", row.acknowledged_version || ""])
    ]);
  }

  function exportPeople() {
    if (!state.admin) return;
    const people = new Map((state.admin.people || []).map((person) => [person.auth_user_id, person]));
    const docs = new Map((state.admin.documents || []).map((doc) => [doc.document_id, doc]));
    downloadCsv(`company-documents-read-status-${new Date().toISOString().slice(0, 10)}.csv`, [
      ["Staff", "Job title", "Employee code", "Staff areas", "Section", "Reference", "Document", "Document areas", "Version", "Status", "Opened", "Confirmed"],
      ...(state.admin.statuses || []).map((row) => ({ row, person: people.get(row.auth_user_id) || {}, doc: docs.get(row.document_id) || {} }))
        .sort((a, b) => String(a.person.display_name).localeCompare(b.person.display_name) || String(a.doc.title).localeCompare(b.doc.title))
        .map(({ row, person, doc }) => [person.display_name, person.job_title_name, person.employee_code, (person.areas || []).map(areaName).join(", "), section(doc.category).short, doc.reference_code, doc.title, areaLabel(doc.areas),
          doc.current_version, STATUS[row.status]?.label || row.status, row.opened_at ? dateTime(row.opened_at) : "", row.acknowledged_at ? dateTime(row.acknowledged_at) : ""])
    ]);
  }

  // --------------------------------------------------------------- History

  const HISTORY_LABELS = {
    PUBLISHED: "Published", NEW_VERSION: "New version", DETAILS_UPDATED: "Details changed",
    ARCHIVED: "Archived", RESTORED: "Restored", DELETED: "Deleted"
  };

  async function openHistory(doc) {
    $("historyTitle").textContent = doc.title;
    $("historyList").innerHTML = '<li class="docs-empty">Loading…</li>';
    $("historyDialog").showModal();
    try {
      const rows = await rpc("get_company_document_history", { p_document_id: doc.document_id });
      $("historyList").innerHTML = rows.length ? rows.map((row) => `
        <li class="${esc(String(row.event_type).toLowerCase())}">
          <div><strong>${esc(HISTORY_LABELS[row.event_type] || row.event_type)}${["PUBLISHED", "NEW_VERSION"].includes(row.event_type) ? ` · v${row.version_number}` : ""}</strong>
          <small>${esc(dateTime(row.recorded_at))}${row.recorded_by_name ? ` · ${esc(row.recorded_by_name)}` : ""}</small></div>
          ${row.change_note ? `<p>${esc(row.change_note)}</p>` : ""}
          ${row.original_file_name && ["PUBLISHED", "NEW_VERSION"].includes(row.event_type) ? `<span>${esc(row.original_file_name)}${row.file_size_bytes ? ` · ${size(row.file_size_bytes)}` : ""}</span>` : ""}
          ${row.event_type === "NEW_VERSION" ? `<span>${row.reconfirmation_required ? "Staff asked to confirm again" : "Earlier confirmations kept"}</span>` : ""}
        </li>`).join("") : '<li class="docs-empty">No updates recorded.</li>';
    } catch (error) {
      $("historyList").innerHTML = `<li class="docs-empty error">${esc(friendly(error))}</li>`;
    }
  }

  // ---------------------------------------------------------- Upload forms

  // Phone photos are often several MB. Large images are reduced to at most
  // 2400 px on the long side before upload; PDFs are uploaded as they are.
  async function prepareFile(file) {
    if (!file) throw new Error("Choose a PDF or photo.");
    if (!FILE_TYPES.includes(file.type)) throw new Error("Use a PDF, JPG, PNG or WebP file.");
    let result = file;
    if (file.type !== "application/pdf" && file.size > 1.5 * 1024 * 1024) {
      try {
        const bitmap = await createImageBitmap(file);
        const scale = Math.min(1, 2400 / Math.max(bitmap.width, bitmap.height));
        const canvas = document.createElement("canvas");
        canvas.width = Math.round(bitmap.width * scale);
        canvas.height = Math.round(bitmap.height * scale);
        canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
        const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85));
        if (blob && blob.size < file.size) result = new File([blob], file.name.replace(/\.[^.]+$/, "") + ".jpg", { type: "image/jpeg" });
      } catch (error) {
        console.warn("Photo could not be reduced; uploading the original.", error);
      }
    }
    if (result.size > MAX_BYTES) throw new Error("The file is larger than 20 MB. Reduce it before uploading.");
    return result;
  }

  async function upload(documentId, file) {
    const safe = file.name.normalize("NFKD").replace(/[^a-zA-Z0-9._-]+/g, "-").replace(/-+/g, "-").slice(-100) || "document";
    const path = `${documentId}/${Date.now()}-${safe}`;
    const { error } = await client.storage.from(BUCKET).upload(path, file, { contentType: file.type, upsert: false });
    if (error) throw error;
    return { storage_path: path, original_file_name: file.name, mime_type: file.type, file_size_bytes: file.size };
  }

  function showFileName(input, label, fallback) {
    const file = input.files[0];
    label.textContent = file ? `${file.name} · ${size(file.size)}` : fallback;
    input.closest(".docs-drop").classList.toggle("has-file", !!file);
  }

  function openDocForm(doc = null) {
    state.editing = doc;
    $("docForm").reset();
    $("docDialogTitle").textContent = doc ? "Edit document details" : "Add document";
    $("docSave").textContent = doc ? "Save changes" : "Publish document";
    $("docFileField").classList.toggle("hidden", !!doc);
    $("docFile").required = !doc;
    $("docFormStatus").textContent = "";
    $("docFileName").textContent = "PDF, JPG, PNG or WebP up to 20 MB. Large photos are reduced automatically.";
    $("docFile").closest(".docs-drop").classList.remove("has-file");
    if (doc) {
      $("docCategory").value = doc.category;
      $("docReference").value = doc.reference_code || "";
      $("docTitle").value = doc.title;
      $("docDescription").value = doc.description || "";
      $("docRequiresAck").checked = !!doc.requires_acknowledgement;
    }
    setPickedAreas(doc?.areas || []);
    $("docDialog").showModal();
  }

  async function saveDoc(event) {
    event.preventDefault();
    const doc = state.editing;
    const button = $("docSave");
    const status = $("docFormStatus");
    const details = {
      category: $("docCategory").value,
      reference_code: $("docReference").value.trim(),
      title: $("docTitle").value.trim(),
      description: $("docDescription").value.trim(),
      requires_acknowledgement: $("docRequiresAck").checked,
      areas: pickedAreas()
    };
    if (!details.title) return void (status.textContent = "Enter the document title.");
    button.disabled = true;
    let uploaded = null;
    try {
      if (doc) {
        status.textContent = "Saving…";
        await rpc("update_company_document_details", { p_document_id: doc.document_id, p_details: details, p_row_version: doc.row_version });
        message("Document details saved.", "good");
      } else {
        const documentId = crypto.randomUUID();
        status.textContent = "Preparing file…";
        const file = await prepareFile($("docFile").files[0]);
        status.textContent = "Uploading…";
        uploaded = await upload(documentId, file);
        status.textContent = "Publishing…";
        await rpc("create_company_document", { p_document: { ...details, ...uploaded, document_id: documentId } });
        uploaded = null;
        message(`"${details.title}" is published. Staff will see it in Company Documents.`, "good");
      }
      $("docDialog").close();
      await Promise.all([loadAdmin(true), loadMine()]);
    } catch (error) {
      status.textContent = friendly(error);
      if (uploaded) await client.storage.from(BUCKET).remove([uploaded.storage_path]);
    } finally {
      button.disabled = false;
    }
  }

  // Area picker: "All areas" or one or more areas.
  function renderAreaPicker() {
    $("docAreas").innerHTML = `<label class="docs-area-option all"><input type="checkbox" value="" checked> All areas</label>` +
      AREAS.map((area) => `<label class="docs-area-option"><input type="checkbox" value="${area.code}"> ${esc(area.label)}</label>`).join("");
  }

  function pickedAreas() {
    return [...$("docAreas").querySelectorAll("input[value]:checked")].map((input) => input.value).filter(Boolean);
  }

  function setPickedAreas(areas) {
    $("docAreas").querySelectorAll("input").forEach((input) => { input.checked = input.value ? areas.includes(input.value) : !areas.length; });
    updateAreaHint();
  }

  function onAreaPick(event) {
    const input = event.target.closest("input");
    if (!input) return;
    if (!input.value) setPickedAreas([]);
    else setPickedAreas(pickedAreas());
  }

  function updateAreaHint() {
    const areas = pickedAreas();
    $("docAreas").querySelectorAll("label").forEach((label) => label.classList.toggle("checked", label.querySelector("input").checked));
    const people = (state.admin?.people || []).filter((person) => forArea(areas, person.areas)).length;
    const who = areas.length ? `Only staff of ${areaLabel(areas)} see this document.` : "Everyone with a login sees this document.";
    $("docAreasHint").textContent = state.admin ? `${who} ${people} account${people === 1 ? "" : "s"} today.` : who;
  }

  function openVersion(doc) {
    state.versioning = doc;
    $("versionForm").reset();
    $("versionDocTitle").textContent = `${doc.title} · now v${doc.current_version}`.toUpperCase();
    $("versionFormStatus").textContent = "";
    $("versionFileName").textContent = "PDF, JPG, PNG or WebP up to 20 MB.";
    $("versionFile").closest(".docs-drop").classList.remove("has-file");
    $("versionDialog").showModal();
  }

  async function saveVersion(event) {
    event.preventDefault();
    const doc = state.versioning;
    const button = $("versionSave");
    const status = $("versionFormStatus");
    const note = $("versionNote").value.trim();
    if (!note) return void (status.textContent = "Describe what changed in this version.");
    button.disabled = true;
    let uploaded = null;
    try {
      status.textContent = "Preparing file…";
      const file = await prepareFile($("versionFile").files[0]);
      status.textContent = "Uploading…";
      uploaded = await upload(doc.document_id, file);
      status.textContent = "Publishing…";
      const result = await rpc("replace_company_document_file", {
        p_document_id: doc.document_id, p_file: uploaded, p_change_note: note,
        p_require_reconfirmation: document.querySelector('input[name="reconfirm"]:checked').value === "yes",
        p_row_version: doc.row_version
      });
      uploaded = null;
      // Only one physical file is kept: remove the replaced one. If this fails
      // the manager page removes it on a later visit (orphan_paths).
      if (result?.old_storage_path) {
        const { error } = await client.storage.from(BUCKET).remove([result.old_storage_path]);
        if (error) console.warn("The previous file will be removed on the next visit.", error);
      }
      $("versionDialog").close();
      message(`Version ${result?.document?.current_version || ""} of "${doc.title}" is published.`, "good");
      await Promise.all([loadAdmin(true), loadMine()]);
    } catch (error) {
      status.textContent = friendly(error);
      if (uploaded) await client.storage.from(BUCKET).remove([uploaded.storage_path]);
    } finally {
      button.disabled = false;
    }
  }

  // ------------------------------------------------------------------ Tabs

  async function showTab(tab) {
    document.querySelectorAll("#docsTabs [data-tab]").forEach((button) => button.classList.toggle("active", button.dataset.tab === tab));
    $("tabMine").classList.toggle("hidden", tab !== "mine");
    $("tabManage").classList.toggle("hidden", tab !== "manage");
    $("tabPeople").classList.toggle("hidden", tab !== "people");
    if (tab !== "mine") {
      try { await loadAdmin(); } catch (error) { message(friendly(error), "error"); }
    }
    try { history.replaceState(null, "", tab === "mine" ? location.pathname : `#${tab}`); } catch (_) { /* optional */ }
  }

  function bind() {
    document.querySelectorAll("dialog [data-close]").forEach((button) => button.addEventListener("click", () => button.closest("dialog").close()));
    document.querySelectorAll("dialog").forEach((dialog) => dialog.addEventListener("click", (event) => { if (event.target === dialog) dialog.close(); }));
    $("viewer").addEventListener("close", () => { $("viewerBody").innerHTML = ""; state.viewing = null; });
    $("docsTabs").addEventListener("click", (event) => { const button = event.target.closest("[data-tab]"); if (button) showTab(button.dataset.tab); });
    $("mineList").addEventListener("click", (event) => {
      const card = event.target.closest("[data-open]");
      const doc = card && state.mine.find((item) => item.document_id === card.dataset.open);
      if (doc) openViewer(doc);
    });
    document.querySelectorAll("[data-mine-filter]").forEach((button) => button.addEventListener("click", () => {
      state.mineFilter = button.dataset.mineFilter;
      document.querySelectorAll("[data-mine-filter]").forEach((item) => item.classList.toggle("active", item === button));
      renderMine();
    }));
    document.querySelectorAll("[data-people-filter]").forEach((button) => button.addEventListener("click", () => {
      state.peopleFilter = button.dataset.peopleFilter;
      document.querySelectorAll("[data-people-filter]").forEach((item) => item.classList.toggle("active", item === button));
      renderPeople();
    }));
    $("mineSearch").addEventListener("input", renderMine);
    $("ackCheck").addEventListener("change", () => { $("ackButton").disabled = !$("ackCheck").checked; });
    $("ackForm").addEventListener("submit", acknowledge);
    $("manageList").addEventListener("click", onManageClick);
    ["manageSearch", "manageCategory", "manageArchived"].forEach((id) => $(id).addEventListener(id === "manageSearch" ? "input" : "change", renderManage));
    $("peopleSearch").addEventListener("input", renderPeople);
    const areaOptions = AREAS.map((area) => `<option value="${area.code}">${esc(area.label)}</option>`).join("");
    $("manageArea").insertAdjacentHTML("beforeend", areaOptions);
    $("peopleArea").insertAdjacentHTML("beforeend", areaOptions);
    $("manageArea").addEventListener("change", renderManage);
    $("peopleArea").addEventListener("change", renderPeople);
    renderAreaPicker();
    $("docAreas").addEventListener("change", onAreaPick);
    $("peopleExport").addEventListener("click", exportPeople);
    $("addDocument").addEventListener("click", () => openDocForm());
    $("docForm").addEventListener("submit", saveDoc);
    $("versionForm").addEventListener("submit", saveVersion);
    $("docFile").addEventListener("change", () => showFileName($("docFile"), $("docFileName"), "PDF, JPG, PNG or WebP up to 20 MB."));
    $("versionFile").addEventListener("change", () => showFileName($("versionFile"), $("versionFileName"), "PDF, JPG, PNG or WebP up to 20 MB."));
    $("readersFilters").addEventListener("click", (event) => { const chip = event.target.closest("[data-reader-filter]"); if (chip) { state.readersFilter = chip.dataset.readerFilter; renderReaders(); } });
    $("readersSearch").addEventListener("input", renderReaders);
    $("readersExport").addEventListener("click", exportReaders);
  }

  document.addEventListener("DOMContentLoaded", async () => {
    if (!client) return message("The Supabase connection could not be initialized.", "error");
    bind();
    try {
      const { data: { session } } = await client.auth.getSession();
      if (!session) return void location.replace("../index.html");
      await loadMine();
      const tab = location.hash.slice(1);
      if (state.canViewStatus && ["manage", "people"].includes(tab)) await showTab(tab);
    } catch (error) {
      $("mineList").innerHTML = `<p class="docs-empty error">${esc(friendly(error))}</p>`;
    }
  });
})();
