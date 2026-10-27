/**
 * ElisCaretex Legacy Sync — sender (add as a new file next to Code.gs).
 *
 * Reads the legacy sheets and sends them to the Supabase Edge Function `legacy-sync-finish`.
 * Every request is signed with HMAC-SHA256. All mapping rules, switches and limits are in
 * Postgres: this file only reads the sheets and normalises cell formats. It never writes the sheets.
 *
 * Parts of the sync, in the order they run:
 *   wash    Sorting workbook "Sorting Area" + CentralDB WashItems (+ WashItemsHistory) + Sorting "Staff"
 *   normal  Finish Area FinishEntries (+ FinishEntriesHistory) + CentralDB WashItems
 *   rewash  Finish Area HOUSEHOLD entries + RewashProduction
 *
 * Script Properties (Project Settings > Script Properties; never in code):
 *   LSF_ENDPOINT  https://<project-ref>.supabase.co/functions/v1/legacy-sync-finish
 *   LSF_SECRET    the same value as the Supabase secret LEGACY_SYNC_HMAC_SECRET (64 hex chars)
 * Spreadsheet IDs come from the existing Legacy Sync configuration (Code.gs, lsConfig_):
 * sources.finish and sources.central must be enabled and configured; sources.sorting for washes.
 *
 * Entry points (run from the editor):
 *   previewFinishSync('2026-10-24','2026-10-27')  read-only dry run of every part
 *   importFinishSync('2026-10-24','2026-10-27')   imports; refused by the database for a part
 *                                                  whose switch is off
 *   installLegacySyncTrigger()                     once: polls V2 every 5 minutes (legacySyncTick)
 *   removeLegacySyncTrigger()                      stops the polling
 * Index.html (the web app page) calls getFinishSyncPanel, setFinishSyncEnabled, syncFinishNow,
 * previewFinishSync, importFinishSync and the two trigger functions, plus getDashboard /
 * saveConfig / saveConnection / testSource from Code.gs.
 * The poll runs an import only when V2 says so: once per night while the sync is ON.
 * The ON/OFF switch and "Sync now" are on the web app page (Index.html).
 */
const LSF = {
  timeZone: 'Europe/Dublin',
  maxDays: 7,
  finishBatch: 60,
  rewashBatch: 40,
  timeBudgetMs: 5 * 60 * 1000,
  entrySheets: ['FinishEntries', 'FinishEntriesHistory'],
  washSheets: ['WashItems', 'WashItemsHistory'],
  entryFields: ['EntryID', 'CreatedAt', 'BusinessDate', 'Shift', 'TableID', 'EntryType', 'WashItemID', 'CustomerID',
    'BatchNo', 'QtyKg', 'QtyUnits', 'TotalKg', 'Status', 'Trolleys'],
  lineFields: ['RewashLineID', 'EntryID', 'LineNo', 'BusinessDate', 'Shift', 'TableID', 'CustomerID', 'BatchNo',
    'QtyKg', 'QtyUnits', 'Status'],
  washFields: ['WashItemID', 'CustomerID', 'ScheduledDate', 'Type'],
  // Sorting washes
  washBatch: 60,
  loadSheet: 'Sorting Area',
  loadFields: ['WashID', 'START TIME', 'REGISTER TIME', 'MACHINE', 'WHO', 'Type', 'KG', 'CUSTOMERS'],
  washItemFields: ['WashItemID', 'WashID', 'CustomerID', 'ScheduledDate', 'Type', 'KGShare', 'LoadNo'],
  staffFields: ['Name', 'Shift', 'Date'],
  userFields: ['UserID', 'Name'],
  parts: ['wash', 'normal', 'rewash']
};

function lsfConnection_() {
  const p = PropertiesService.getScriptProperties();
  const url = String(p.getProperty('LSF_ENDPOINT') || '').trim();
  const secret = String(p.getProperty('LSF_SECRET') || '').trim();
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/functions\/v1\/legacy-sync-finish$/.test(url)) throw Error('Set Script Property LSF_ENDPOINT to the legacy-sync-finish Edge Function URL');
  if (!/^[0-9a-f]{64}$/i.test(secret)) throw Error('Set Script Property LSF_SECRET (64 hex characters)');
  return {url: url, secret: secret};
}

function lsfHex_(bytes) { return bytes.map(function (b) { return ('0' + (b & 255).toString(16)).slice(-2); }).join(''); }

/** Signed POST. Returns the body when ok; a database refusal comes back as {ok:false, code, error}. */
function lsfCall_(body) {
  const c = lsfConnection_();
  const payload = JSON.stringify(body);
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = lsfHex_(Utilities.computeHmacSha256Signature(timestamp + '.' + payload, c.secret, Utilities.Charset.UTF_8));
  const resp = UrlFetchApp.fetch(c.url, {method: 'post', contentType: 'application/json; charset=utf-8', payload: payload, muteHttpExceptions: true,
    headers: {'x-legacy-sync-timestamp': timestamp, 'x-legacy-sync-signature': signature}});
  const text = resp.getContentText();
  if (resp.getResponseCode() !== 200) throw Error('legacy-sync-finish HTTP ' + resp.getResponseCode() + ': ' + text.slice(0, 300));
  return JSON.parse(text);
}

/** Cell value as the database expects it: text, ISO dates, plain numbers, null when empty. */
function lsfText_(v, kind) {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) {
    if (isNaN(v.getTime())) return null;
    return kind === 'date' ? Utilities.formatDate(v, LSF.timeZone, 'yyyy-MM-dd') : v.toISOString();
  }
  if (typeof v === 'number') {
    if (!isFinite(v)) return null;
    return String(Number(v.toFixed(6)));
  }
  const t = String(v).trim();
  if (t === '' || t === 'None') return null;
  if (kind === 'date') {
    if (/^\d{4}-\d{2}-\d{2}/.test(t)) return t.slice(0, 10);
    const m = t.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
    if (m) return m[3] + '-' + ('0' + m[2]).slice(-2) + '-' + ('0' + m[1]).slice(-2);
  }
  return t;
}

function lsfKind_(field) { return field === 'BusinessDate' || field === 'ScheduledDate' ? 'date' : null; }

function lsfPick_(row, fields) {
  const o = {};
  fields.forEach(function (f) { o[f] = lsfText_(row[f], lsfKind_(f)); });
  return o;
}

/** Rows of a sheet as objects, keeping only the given columns. */
function lsfReadSheet_(ss, name, fields, required) {
  const sh = ss.getSheetByName(name);
  if (!sh) { if (required) throw Error('Sheet ' + name + ' is missing'); return []; }
  const n = sh.getLastRow() - 1, width = sh.getLastColumn();
  if (n < 1) return [];
  const headers = sh.getRange(1, 1, 1, width).getValues()[0].map(function (h) { return String(h || '').trim(); });
  const missing = fields.filter(function (f) { return f !== 'Trolleys' && headers.indexOf(f) < 0; });
  if (missing.length) throw Error(name + ' is missing columns: ' + missing.join(', '));
  const wanted = fields.concat(['UserName']).filter(function (f) { return headers.indexOf(f) >= 0; });
  const columns = {};
  wanted.forEach(function (f) { columns[f] = sh.getRange(2, headers.indexOf(f) + 1, n, 1).getValues(); });
  const rows = [];
  for (let i = 0; i < n; i++) {
    const row = {_row: i + 2};
    wanted.forEach(function (f) { row[f] = columns[f][i][0]; });
    rows.push(row);
  }
  return rows;
}

function lsfRange_(fromDate, toDate) {
  const today = Utilities.formatDate(new Date(), LSF.timeZone, 'yyyy-MM-dd');
  const shift = function (day, n) { const d = new Date(day + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return Utilities.formatDate(d, 'UTC', 'yyyy-MM-dd'); };
  const to = toDate || today, from = fromDate || shift(to, -2);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to) || from > to) throw Error('Invalid date range');
  const days = Math.round((Date.parse(to + 'T12:00:00Z') - Date.parse(from + 'T12:00:00Z')) / 86400000) + 1;
  if (days > LSF.maxDays) throw Error('At most ' + LSF.maxDays + ' days per run');
  return {from: from, to: to};
}

/** Builds the NORMAL and HOUSEHOLD records of the date range. Reads only, never writes the sheets. */
function lsfCollect_(range) {
  const conf = lsConfig_();
  if (!conf.enabled) throw Error('Master switch is OFF');
  const finish = conf.sources.finish, central = conf.sources.central;
  if (!finish.enabled || !finish.id || !central.enabled || !central.id) throw Error('Enable and configure the Finish and CentralDB sources');
  const fss = SpreadsheetApp.openById(finish.id);

  // FinishEntries wins over FinishEntriesHistory for the same EntryID.
  const entries = {}, order = [], duplicates = [];
  LSF.entrySheets.forEach(function (name, sheetIndex) {
    lsfReadSheet_(fss, name, LSF.entryFields, sheetIndex === 0).forEach(function (row) {
      const id = lsfText_(row.EntryID), day = lsfText_(row.BusinessDate, 'date');
      if (!id || !day || day < range.from || day > range.to) return;
      if (entries[id]) { if (sheetIndex === 0) duplicates.push(id); return; }
      entries[id] = row; order.push(id);
    });
  });
  if (duplicates.length) throw Error('Duplicate EntryID in FinishEntries: ' + duplicates.slice(0, 10).join(', '));

  const linesByEntry = {};
  lsfReadSheet_(fss, 'RewashProduction', LSF.lineFields, true).forEach(function (row) {
    const id = lsfText_(row.EntryID);
    if (id && entries[id]) (linesByEntry[id] = linesByEntry[id] || []).push(row);
  });

  const washIds = {};
  order.forEach(function (id) { const w = lsfText_(entries[id].WashItemID); if (w) washIds[w] = true; });
  // WashItems wins over WashItemsHistory for the same WashItemID.
  const wash = {};
  if (Object.keys(washIds).length) {
    const css = SpreadsheetApp.openById(central.id);
    LSF.washSheets.forEach(function (name, sheetIndex) {
      const found = {};
      lsfReadSheet_(css, name, LSF.washFields, sheetIndex === 0).forEach(function (row) {
        const w = lsfText_(row.WashItemID);
        if (!w || !washIds[w] || (wash[w] && !found[w])) return;
        found[w] = true;
        (wash[w] = wash[w] || []).push(row);
      });
    });
  }

  const normal = [], rewash = [];
  order.forEach(function (id) {
    const row = entries[id], entry = lsfPick_(row, LSF.entryFields);
    entry.StaffName = lsfText_(row.UserName);
    if (String(entry.EntryType || '').toUpperCase() === 'HOUSEHOLD') {
      const lines = (linesByEntry[id] || []).map(function (l) { return lsfPick_(l, LSF.lineFields); });
      rewash.push({source_record_id: id, entry: entry, lines: lines});
    } else {
      const matches = entry.WashItemID ? (wash[entry.WashItemID] || []) : [];
      // An unknown or duplicated WashItemID is sent without a wash item; the planner holds it.
      normal.push({source_record_id: id, entry: entry, wash_item: matches.length === 1 ? lsfPick_(matches[0], LSF.washFields) : null});
    }
  });
  return {normal: normal, rewash: rewash};
}

/** A time-of-day cell (a Date on 1899-12-30, or text) as HH:mm:ss in the sheet's time zone. */
function lsfClock_(v, tz) {
  if (v instanceof Date) return isNaN(v.getTime()) ? null : Utilities.formatDate(v, tz, 'HH:mm:ss');
  const t = lsfText_(v), m = t && t.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  return m ? ('0' + m[1]).slice(-2) + ':' + m[2] + ':' + (m[3] || '00') : t;
}

/** A date-time cell as Dublin local time, yyyy-MM-ddTHH:mm:ss. */
function lsfLocal_(v) {
  if (v instanceof Date) return isNaN(v.getTime()) ? null : Utilities.formatDate(v, LSF.timeZone, "yyyy-MM-dd'T'HH:mm:ss");
  return lsfText_(v);
}

/**
 * Sorting washes of the date range (by register day): one record per Sorting Area row, with its
 * CentralDB WashItems (one per customer) and the shifts its operator worked that day (Staff sheet).
 */
function lsfCollectWashes_(range) {
  const conf = lsConfig_();
  const sorting = conf.sources.sorting, central = conf.sources.central;
  if (!sorting || !sorting.enabled || !sorting.id) return {records: [], note: 'Sorting spreadsheet is not configured or not enabled.'};
  const sss = SpreadsheetApp.openById(sorting.id), tz = sss.getSpreadsheetTimeZone();

  const loads = [], ids = {}, duplicates = [];
  lsfReadSheet_(sss, LSF.loadSheet, LSF.loadFields, true).forEach(function (row) {
    const id = lsfText_(row.WashID), registered = lsfLocal_(row['REGISTER TIME']);
    if (!id || !registered) return;
    const day = registered.slice(0, 10);
    if (day < range.from || day > range.to) return;
    if (ids[id]) { duplicates.push(id); return; }
    ids[id] = true;
    loads.push({id: id, day: day, wash: {WashID: id, StartTime: lsfClock_(row['START TIME'], tz), RegisterTime: registered,
      Machine: lsfText_(row.MACHINE), Who: lsfText_(row.WHO), Type: lsfText_(row.Type), Kg: lsfText_(row.KG),
      Customers: lsfText_(row.CUSTOMERS)}});
  });
  if (!loads.length) return {records: [], duplicates: duplicates};

  // WashItems wins over WashItemsHistory for the same WashItemID. History is optional.
  const items = {}, seen = {};
  const css = SpreadsheetApp.openById(central.id);
  LSF.washSheets.forEach(function (name, sheetIndex) {
    let rows = [];
    try { rows = lsfReadSheet_(css, name, LSF.washItemFields, sheetIndex === 0); } catch (e) { if (sheetIndex === 0) throw e; }
    rows.forEach(function (row) {
      const washId = lsfText_(row.WashID), itemId = lsfText_(row.WashItemID);
      if (!washId || !ids[washId] || !itemId || seen[itemId]) return;
      seen[itemId] = true;
      (items[washId] = items[washId] || []).push(lsfPick_(row, LSF.washItemFields));
    });
  });

  // Shifts each person worked, by name and day.
  const shifts = {};
  lsfReadSheet_(sss, 'Staff', LSF.staffFields, false).forEach(function (row) {
    const name = lsfText_(row.Name), at = lsfLocal_(row.Date), shift = lsfText_(row.Shift);
    if (!name || !at || !shift) return;
    const key = name.toLowerCase() + '|' + at.slice(0, 10);
    (shifts[key] = shifts[key] || {})[shift] = true;
  });

  // Legacy user ID of each operator name (CentralDB User; never UserPrivate). Ambiguous names get none.
  const userIds = {};
  lsfReadSheet_(css, 'User', LSF.userFields, false).forEach(function (row) {
    const name = lsfText_(row.Name), id = lsfText_(row.UserID);
    if (!name || !id) return;
    const key = name.toLowerCase();
    userIds[key] = userIds.hasOwnProperty(key) && userIds[key] !== id ? null : id;
  });

  const previousDay = function (day) { const d = new Date(day + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() - 1); return Utilities.formatDate(d, 'UTC', 'yyyy-MM-dd'); };
  return {duplicates: duplicates, records: loads.map(function (l) {
    const who = String(l.wash.Who || '').toLowerCase();
    l.wash.WhoUserID = userIds[who] || null;
    // A load registered before 03:00 belongs to the previous day's Evening.
    const days = l.wash.RegisterTime.slice(11, 16) < '03:00' ? [l.day, previousDay(l.day)] : [l.day];
    const worked = {};
    days.forEach(function (d) { Object.keys(shifts[who + '|' + d] || {}).forEach(function (s) { worked[s] = true; }); });
    return {source_record_id: l.id, wash: l.wash,
      items: (items[l.id] || []).sort(function (a, b) { return String(a.WashItemID).localeCompare(String(b.WashItemID)); }),
      staff_shifts: Object.keys(worked).sort()};
  })};
}

/** Every part of the sync for the date range. */
function lsfCollectAll_(range) {
  const collected = lsfCollect_(range);
  const washes = lsfCollectWashes_(range);
  collected.wash = washes.records;
  collected.notes = {wash: [washes.note, washes.duplicates && washes.duplicates.length ? 'Duplicate WashID ignored: ' + washes.duplicates.slice(0, 10).join(', ') : null].filter(Boolean)};
  return collected;
}

function lsfCount_(map, key) { map[key] = (map[key] || 0) + 1; }

function lsfDryRun_(collected) {
  const plans = {normal: [], rewash: [], wash: []};
  for (let i = 0; i < collected.normal.length; i += LSF.finishBatch) {
    const r = lsfCall_({operation: 'finish_dry_run', records: collected.normal.slice(i, i + LSF.finishBatch)});
    if (!r.ok) throw Error('Finish dry run refused: ' + r.error);
    plans.normal = plans.normal.concat(r.result.plans || []);
  }
  for (let i = 0; i < collected.rewash.length; i += LSF.rewashBatch) {
    const r = lsfCall_({operation: 'rewash_dry_run', records: collected.rewash.slice(i, i + LSF.rewashBatch)});
    if (!r.ok) throw Error('ReWash dry run refused: ' + r.error);
    plans.rewash = plans.rewash.concat(r.result.plans || []);
  }
  // A part whose database side is not installed yet is reported and skipped, never fatal.
  const wash = collected.wash || [];
  try {
    for (let i = 0; i < wash.length; i += LSF.washBatch) {
      const r = lsfCall_({operation: 'dry_run', kind: 'wash', records: wash.slice(i, i + LSF.washBatch)});
      if (!r.ok) throw Error(r.error);
      plans.wash = plans.wash.concat(r.result.plans || []);
    }
    if (plans.wash.length !== wash.length) throw Error('Dry run response does not match the records sent');
  } catch (e) {
    plans.wash = null;
    collected.notes = collected.notes || {};
    collected.notes.wash = (collected.notes.wash || []).concat(['Washes not available yet: ' + String(e.message || e)]);
  }
  if (plans.normal.length !== collected.normal.length || plans.rewash.length !== collected.rewash.length) throw Error('Dry run response does not match the records sent');
  return plans;
}

function lsfSummary_(plans, notes) {
  const out = {};
  LSF.parts.forEach(function (kind) {
    if (!plans[kind]) { out[kind] = {records: 0, outcomes: {}, actions: {}, blockers: {}, held: [], notes: (notes || {})[kind] || []}; return; }
    const s = {records: plans[kind].length, outcomes: {}, actions: {}, blockers: {}, held: [], notes: (notes || {})[kind] || []};
    plans[kind].forEach(function (p) {
      lsfCount_(s.outcomes, p.outcome);
      if (p.action) lsfCount_(s.actions, p.action);
      (p.blockers || []).forEach(function (b) { lsfCount_(s.blockers, b.code); });
      if (p.outcome === 'BLOCKED' && s.held.length < 30) s.held.push({id: p.source_record_id, blockers: (p.blockers || []).map(function (b) { return b.code + (b.detail ? ': ' + b.detail : ''); })});
    });
    out[kind] = s;
  });
  return out;
}

/** Read-only: shows what an import would do. Nothing is written in V2 or in the sheets. */
function previewFinishSync(fromDate, toDate) {
  const range = lsfRange_(fromDate, toDate);
  const collected = lsfCollectAll_(range);
  const plans = lsfDryRun_(collected);
  const result = {mode: 'DRY_RUN', from: range.from, to: range.to, summary: lsfSummary_(plans, collected.notes)};
  Logger.log(JSON.stringify(result, null, 2));
  return result;
}

/**
 * Imports the range inside one COMMIT run: washes first, then Finish and ReWash. The database
 * refuses a part whose switch is off, and stops a part at its max_entries_per_run.
 * READY records are written; BLOCKED records go to the review queue; others are left alone.
 */
function importFinishSync(fromDate, toDate, reason) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) throw Error('A synchronization is already running');
  const started = Date.now();
  let runId = null;
  const result = {mode: 'COMMIT', reason: reason || 'MANUAL', results: {wash: {}, normal: {}, rewash: {}}, stopped: null};
  try {
    const range = lsfRange_(fromDate, toDate);
    result.from = range.from; result.to = range.to;
    // The run is opened first so that a sheet or network error is recorded as FAILED in V2.
    const start = lsfCall_({operation: 'start_run', mode: 'COMMIT', dateFrom: range.from, dateTo: range.to,
      requestedBy: 'Apps Script Legacy Sync (' + result.reason + ')'});
    if (!start.ok) throw Error('Run refused: ' + start.error);
    runId = start.result; result.runId = runId;

    const collected = lsfCollectAll_(range);
    const plans = lsfDryRun_(collected);
    result.plan = lsfSummary_(plans, collected.notes);

    const groups = [
      {kind: 'wash', body: function (record) { return {operation: 'import', kind: 'wash', runId: runId, record: record}; }},
      {kind: 'normal', body: function (record) { return {operation: 'import_finish', runId: runId, record: record}; }},
      {kind: 'rewash', body: function (record) { return {operation: 'import_rewash', runId: runId, record: record}; }}
    ];
    for (const g of groups) {
      if (!plans[g.kind]) continue;
      const records = collected[g.kind];
      for (let i = 0; i < records.length && !result.stopped; i++) {
        const outcome = plans[g.kind][i].outcome;
        if (outcome !== 'READY' && outcome !== 'BLOCKED') continue;
        if (Date.now() - started > LSF.timeBudgetMs) { result.stopped = 'TIME_BUDGET'; break; }
        const r = lsfCall_(g.body(records[i]));
        if (!r.ok) {
          lsfCount_(result.results[g.kind], 'REFUSED_' + r.code);
          if (r.code === '55000') { result.results[g.kind].refusal = r.error; break; } // switch OFF: skip the group
          continue;
        }
        lsfCount_(result.results[g.kind], r.result.outcome);
        if (r.result.outcome === 'RUN_LIMIT_REACHED') break; // this part's limit: the next part still runs
      }
    }
    lsfCall_({operation: 'finish_run', runId: runId, status: 'COMPLETED', summary: {results: result.results, stopped: result.stopped}});
  } catch (e) {
    result.error = String(e.message || e);
    if (runId) {
      try { lsfCall_({operation: 'finish_run', runId: runId, status: 'FAILED', summary: {error: result.error, results: result.results}}); } catch (ignored) {}
    }
  } finally {
    lock.releaseLock();
  }
  Logger.log(JSON.stringify(result, null, 2));
  return result;
}

/** Time trigger (every 5 minutes): asks V2 whether to run, and runs the window V2 returns. */
function legacySyncTick() {
  const r = lsfCall_({operation: 'poll'});
  if (!r.ok) throw Error('Poll refused: ' + r.error);
  const claim = r.result || {};
  if (!claim.run) return claim;
  return importFinishSync(claim.dateFrom, claim.dateTo, claim.reason);
}

/** Run once from the editor (or the Install button in Index.html). Replaces any earlier legacySyncTick trigger. */
function installLegacySyncTrigger() {
  removeLegacySyncTrigger();
  ScriptApp.newTrigger('legacySyncTick').timeBased().everyMinutes(5).create();
  Logger.log('legacySyncTick will run every 5 minutes.');
  return getFinishSyncPanel();
}

function removeLegacySyncTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'legacySyncTick') ScriptApp.deleteTrigger(t);
  });
  return getFinishSyncPanel();
}

/**
 * Status for Index.html: local settings plus the V2 state (on/off, last runs) through the
 * signed "control" call. Never sends "poll": a poll would claim a run.
 */
function getFinishSyncPanel() {
  const p = PropertiesService.getScriptProperties();
  const today = Utilities.formatDate(new Date(), LSF.timeZone, 'yyyy-MM-dd');
  const panel = {
    endpointConfigured: /^https:\/\/[a-z0-9-]+\.supabase\.co\/functions\/v1\/legacy-sync-finish$/.test(String(p.getProperty('LSF_ENDPOINT') || '').trim()),
    secretConfigured: /^[0-9a-f]{64}$/i.test(String(p.getProperty('LSF_SECRET') || '').trim()),
    triggerInstalled: ScriptApp.getProjectTriggers().some(function (t) { return t.getHandlerFunction() === 'legacySyncTick'; }),
    today: today,
    yesterday: Utilities.formatDate(new Date(Date.parse(today + 'T12:00:00Z') - 86400000), 'UTC', 'yyyy-MM-dd'),
    v2: null,
    v2Error: null
  };
  if (panel.endpointConfigured && panel.secretConfigured) {
    try { panel.v2 = lsfControl_('STATUS'); } catch (e) { panel.v2Error = String(e.message || e); }
  }
  return panel;
}

function lsfControl_(action) {
  const r = lsfCall_({operation: 'control', action: action, changedBy: 'Apps Script admin page'});
  if (!r.ok) throw Error(r.error || ('Refused: ' + r.code));
  return r.result;
}

/** Index.html switch: ON enables the nightly sync and the imports in V2; OFF stops everything. */
function setFinishSyncEnabled(on) {
  lsfControl_(on ? 'ON' : 'OFF');
  return getFinishSyncPanel();
}

/** Index.html "Sync now": imports the same window as the nightly run, straight away. */
function syncFinishNow() {
  const v2 = lsfControl_('STATUS');
  if (!v2.auto_enabled) throw Error('The sync is OFF. Turn it on first.');
  return importFinishSync(v2.date_from, v2.today, 'SYNC_NOW');
}
