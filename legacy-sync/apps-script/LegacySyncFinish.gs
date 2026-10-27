/**
 * ElisCaretex Legacy Sync — Finish Area sender (add as a new file next to Code.gs).
 *
 * Reads FinishEntries (+ FinishEntriesHistory), RewashProduction and CentralDB WashItems,
 * and sends them to the Supabase Edge Function `legacy-sync-finish`. Every request is signed
 * with HMAC-SHA256. All mapping rules, switches and limits are in Postgres: this file only
 * reads the sheets and normalises cell formats.
 *
 * Script Properties (Project Settings > Script Properties; never in code):
 *   LSF_ENDPOINT  https://<project-ref>.supabase.co/functions/v1/legacy-sync-finish
 *   LSF_SECRET    the same value as the Supabase secret LEGACY_SYNC_HMAC_SECRET (64 hex chars)
 * Spreadsheet IDs come from the existing Legacy Sync configuration (Code.gs, lsConfig_):
 * sources.finish and sources.central must be enabled and configured.
 *
 * Entry points (run from the editor):
 *   previewFinishSync('2026-10-24','2026-10-27')  read-only dry run
 *   importFinishSync('2026-10-24','2026-10-27')   imports; refused by the database unless the
 *                                                  owner enabled the import switches
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
  washFields: ['WashItemID', 'CustomerID', 'ScheduledDate', 'Type']
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

function lsfCount_(map, key) { map[key] = (map[key] || 0) + 1; }

function lsfDryRun_(collected) {
  const plans = {normal: [], rewash: []};
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
  if (plans.normal.length !== collected.normal.length || plans.rewash.length !== collected.rewash.length) throw Error('Dry run response does not match the records sent');
  return plans;
}

function lsfSummary_(plans) {
  const out = {};
  ['normal', 'rewash'].forEach(function (kind) {
    const s = {records: plans[kind].length, outcomes: {}, actions: {}, blockers: {}, held: []};
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
  const plans = lsfDryRun_(lsfCollect_(range));
  const result = {mode: 'DRY_RUN', from: range.from, to: range.to, summary: lsfSummary_(plans)};
  Logger.log(JSON.stringify(result, null, 2));
  return result;
}

/**
 * Imports the range inside one COMMIT run. The database refuses unless the owner enabled
 * FINISH_HISTORICAL_IMPORT / FINISH_REWASH_HISTORICAL_IMPORT, and stops at max_entries_per_run.
 * READY records are written; BLOCKED records go to the review queue; others are left alone.
 */
function importFinishSync(fromDate, toDate) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) throw Error('A synchronization is already running');
  const started = Date.now();
  let runId = null;
  const result = {mode: 'COMMIT', results: {normal: {}, rewash: {}}, stopped: null};
  try {
    const range = lsfRange_(fromDate, toDate);
    result.from = range.from; result.to = range.to;
    const collected = lsfCollect_(range);
    const plans = lsfDryRun_(collected);
    result.plan = lsfSummary_(plans);

    const start = lsfCall_({operation: 'start_run', mode: 'COMMIT', dateFrom: range.from, dateTo: range.to,
      requestedBy: 'Apps Script Legacy Sync (LegacySyncFinish.gs)'});
    if (!start.ok) throw Error('Run refused: ' + start.error);
    runId = start.result; result.runId = runId;

    const groups = [
      {kind: 'normal', operation: 'import_finish', records: collected.normal},
      {kind: 'rewash', operation: 'import_rewash', records: collected.rewash}
    ];
    for (const g of groups) {
      for (let i = 0; i < g.records.length && !result.stopped; i++) {
        const outcome = plans[g.kind][i].outcome;
        if (outcome !== 'READY' && outcome !== 'BLOCKED') continue;
        if (Date.now() - started > LSF.timeBudgetMs) { result.stopped = 'TIME_BUDGET'; break; }
        const r = lsfCall_({operation: g.operation, runId: runId, record: g.records[i]});
        if (!r.ok) {
          lsfCount_(result.results[g.kind], 'REFUSED_' + r.code);
          if (r.code === '55000') { result.results[g.kind].refusal = r.error; break; } // switch OFF: skip the group
          continue;
        }
        lsfCount_(result.results[g.kind], r.result.outcome);
        if (r.result.outcome === 'RUN_LIMIT_REACHED') { result.stopped = 'RUN_LIMIT_REACHED'; break; }
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
