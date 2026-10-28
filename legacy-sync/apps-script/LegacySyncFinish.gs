/**
 * ElisCaretex Legacy Sync — sender (add as a new file next to Code.gs).
 *
 * Reads the legacy sheets and sends them to the Supabase Edge Function `legacy-sync-finish`.
 * Every request is signed with HMAC-SHA256. All mapping rules, switches and limits are in
 * Postgres: this file only reads the sheets and normalises cell formats. It never writes the sheets.
 *
 * Parts of the sync, in the order they run:
 *   master  CentralDB registers: User, CustomerMaster, Trolley, Driver, Vehicles (every row, every run;
 *           only rows that changed since the last sync are written)
 *   schedule CentralDB Routes (route list: name and colour) and CustomerSchedule (one record per
 *           customer with all its production days); a change is a new published schedule revision
 *   attendance Finish Area StaffSessions (+ History) and RosterNotWorking, Sorting "Staff": who worked,
 *           where and when, in the order it was typed
 *   wash    Sorting workbook "Sorting Area" + CentralDB WashItems (+ WashItemsHistory) + Sorting "Staff"
 *   mop     CentralDB MopProduction (+ MopProductionHistory) + WashItems: MOP production and ABS batch
 *   normal  Finish Area FinishEntries (+ FinishEntriesHistory) + CentralDB WashItems
 *   rewash  Finish Area HOUSEHOLD entries + RewashProduction
 *   trolley trolley codes typed on Finish entries and MOP saves (out to the customer) and CentralDB
 *           TrolleyReturns (back at Sorting), in time order: custody and Sorting intakes
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
 * previewFinishSync, importFinishSync, getLegacySyncReviews, decideLegacySyncReview and the
 * two trigger functions, plus getDashboard /
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
  // MOP production
  mopBatch: 60,
  mopSheets: ['MopProduction', 'MopProductionHistory'],
  mopFields: ['MopEventID', 'WashItemID', 'WashID', 'CustomerID', 'BusinessDate', 'Shift', 'EventType', 'QtyKgDelta',
    'QtyUnitsDelta', 'BatchNo', 'MopModel', 'MopModelID', 'Trolleys', 'ProcessedBy', 'ProcessedAt', 'CreatedAt',
    'ABSStatus', 'ABSBatchID', 'ABSLoggedAt', 'ABSLoggedBy', 'Status'],
  mopItemFields: ['WashItemID', 'WashID', 'CustomerID', 'CustomerName', 'ScheduledDate', 'Type'],
  // Trolley custody
  trolleyBatch: 60,
  returnSheet: 'TrolleyReturns',
  returnFields: ['ReturnID', 'TrolleyID', 'ReturnedAt', 'FromCustomerID', 'FromCustomerName', 'ReceivedBy', 'Notes',
    'LastDispatchAt', 'LastDispatchCustomerID', 'CustomerMatch', 'CustomerSource', 'CreatedAt', 'BusinessDate', 'Shift',
    'ServiceType', 'Content', 'ClientEventID', 'ScheduledDate', 'Voided', 'VoidedAt', 'VoidedBy', 'VoidReason',
    'CorrectedAt', 'CorrectedBy'],
  // Attendance
  attendanceBatch: 60,
  sessionSheets: ['StaffSessions', 'StaffSessionsHistory'],
  sessionFields: ['SessionID', 'CreatedAt', 'BusinessDate', 'Shift', 'TableID', 'UserName', 'StartTime', 'EndTime',
    'BreakMin', 'SessionType', 'Comments', 'Status'],
  notWorkingFields: ['DismissalID', 'CreatedAt', 'BusinessDate', 'Shift', 'TableID', 'UserName', 'UserID', 'Reason', 'Status'],
  sortingStaffFields: ['Name', 'Start Shift', 'End Shift', 'Break', 'Coments', 'Work position', 'Date', 'Shift'],
  // Registers (CentralDB). Never UserPrivate or DriverPrivate. Missing optional columns are sent empty.
  masterBatch: 60,
  masterSheets: [
    {type: 'STAFF', sheet: 'User', key: 'UserID', fields: ['UserID', 'Name', 'Shift', 'Position', 'Cover', 'Roster', 'Active',
      'DeactivatedAt', 'JoinedAt', 'FireTraining', 'FirstAidTraining', 'EODCapable']},
    {type: 'CUSTOMER', sheet: 'CustomerMaster', key: 'CustomerID', fields: ['CustomerID', 'CustomerName', 'ServiceType',
      'CustomerType', 'Eircode', 'KGEstimated', 'Stops', 'Information', 'Active']},
    {type: 'TROLLEY', sheet: 'Trolley', key: 'TrolleyID', fields: ['TrolleyID', 'Type', 'Status', 'RegisteredAt', 'Notes']},
    {type: 'DRIVER', sheet: 'Driver', key: 'DriverID', fields: ['DriverID', 'Name', 'LicenseType', 'Active', 'JoinedDate',
      'DeactivatedDate', 'RosterHidden']},
    {type: 'VEHICLE', sheet: 'Vehicles', key: 'Plate', fields: ['Plate', 'Type', 'Notes', 'Status', 'MaintStart', 'MaintEnd',
      'Active', 'RegisteredAt', 'UpdatedAt', 'ContractType', 'VehicleDescription', 'TachographType', 'Insurer', 'Make', 'Range',
      'CvrtMotExpiryDate', 'TachoCalibrationDate', 'Fuel', 'LastKmRecorded', 'ContractStartDate', 'ContractEndDate', 'BodyDetail',
      'TailLiftDetail1', 'TailLiftDetail2', 'MonthlyRentalExVat', 'TermMonths', 'CvrtLast', 'ServiceLast', 'ServiceNext',
      'TachographLast', 'RoadFundLicenceNext', 'TlWeightTestLast', 'TlWeightTestNext', 'RegistrationDate', 'TlLolerNext',
      'TlLolerLast']}
  ],
  masterInstants: ['RegisteredAt', 'UpdatedAt'],
  // Customer schedules (CentralDB): routes first, so a schedule can use a new route.
  scheduleBatch: 40,
  routeFields: ['RouteID', 'DisplayName', 'Colour'],
  scheduleFields: ['CustomerID', 'CustomerName', 'ProductionDay', 'Route', 'DeliveryTime', 'QtyClothes', 'ClothesOrder',
    'TrolleyMop', 'MopOrder', 'MopProducts', 'ClothesNotes', 'MopInstructions', 'Information', 'DeliveryOrder', 'DeliveryNotes'],
  // Parts sent through the generic dry_run / import operations.
  kinds: ['master', 'schedule', 'attendance', 'wash', 'mop', 'trolley'],
  // Import order: registers first (new people, customers and trolleys exist before their work),
  // then customer schedules (they need the customers);
  // attendance next (V2 checks who worked); trolleys last, because a trolley leaving production
  // needs its Finish or MOP record in V2.
  parts: ['master', 'schedule', 'attendance', 'wash', 'mop', 'normal', 'rewash', 'trolley']
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

  const userIds = lsfUserIds_(css);

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

/** Legacy user ID of each name (CentralDB User; never UserPrivate). Ambiguous names get none. */
function lsfUserIds_(css) {
  const userIds = {};
  lsfReadSheet_(css, 'User', LSF.userFields, false).forEach(function (row) {
    const name = lsfText_(row.Name), id = lsfText_(row.UserID);
    if (!name || !id) return;
    const key = name.toLowerCase();
    userIds[key] = userIds.hasOwnProperty(key) && userIds[key] !== id ? null : id;
  });
  return userIds;
}

/**
 * MOP production of the date range (by BusinessDate): one record per washed MOP customer
 * (WashItemID) with every legacy MOP row of that WashItemID, cancelled ones included, and its
 * CentralDB WashItem.
 */
function lsfCollectMops_(range) {
  const central = lsConfig_().sources.central;
  const css = SpreadsheetApp.openById(central.id);
  // MopProduction wins over MopProductionHistory for the same MopEventID. History is optional.
  const all = [], seen = {}, wanted = {};
  LSF.mopSheets.forEach(function (name, sheetIndex) {
    let rows = [];
    try { rows = lsfReadSheet_(css, name, LSF.mopFields, sheetIndex === 0); } catch (e) { if (sheetIndex === 0) throw e; }
    rows.forEach(function (row) {
      const id = lsfText_(row.MopEventID), item = lsfText_(row.WashItemID);
      if (!id || !item || seen[id]) return;
      seen[id] = true;
      all.push(row);
      const day = lsfText_(row.BusinessDate, 'date');
      if (day && day >= range.from && day <= range.to) wanted[item] = true;
    });
  });
  if (!Object.keys(wanted).length) return {records: []};

  const userIds = lsfUserIds_(css);
  const events = {}, order = [];
  all.forEach(function (row) {
    const item = lsfText_(row.WashItemID);
    if (!wanted[item]) return;
    const e = lsfPick_(row, LSF.mopFields);
    ['ProcessedAt', 'CreatedAt', 'ABSLoggedAt'].forEach(function (f) { e[f] = lsfLocal_(row[f]); });
    e.ProcessedByUserID = userIds[String(e.ProcessedBy || '').toLowerCase()] || null;
    if (!events[item]) { events[item] = []; order.push(item); }
    events[item].push(e);
  });

  const items = {};
  LSF.washSheets.forEach(function (name, sheetIndex) {
    let rows = [];
    try { rows = lsfReadSheet_(css, name, LSF.mopItemFields, sheetIndex === 0); } catch (e) { if (sheetIndex === 0) throw e; }
    rows.forEach(function (row) {
      const id = lsfText_(row.WashItemID);
      if (id && wanted[id] && !items[id]) items[id] = lsfPick_(row, LSF.mopItemFields);
    });
  });

  return {records: order.map(function (id) {
    return {source_record_id: id, item: items[id] || null,
      events: events[id].sort(function (a, b) { return String(a.MopEventID).localeCompare(String(b.MopEventID)); })};
  })};
}

/** A date-time cell or text (Dublin local, or ISO with zone) as milliseconds, for ordering. */
function lsfEpoch_(v) {
  if (v instanceof Date) return isNaN(v.getTime()) ? null : v.getTime();
  const t = lsfText_(v);
  if (!t) return null;
  if (/[zZ]$|[+-]\d{2}:?\d{2}$/.test(t)) { const ms = Date.parse(t); return isNaN(ms) ? null : ms; }
  const m = t.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})(?::(\d{2}))?/);
  return m ? Utilities.parseDate(m[1] + ' ' + m[2] + ':' + (m[3] || '00'), LSF.timeZone, 'yyyy-MM-dd HH:mm:ss').getTime() : null;
}

/** Trolley codes of a legacy Trolleys cell ("T0292025T,T3012025T"); NO_TROLLEY_AVAILABLE and other text are ignored. */
function lsfTrolleyCodes_(v) {
  const seen = {};
  return String(lsfText_(v) || '').toUpperCase().split(/[\s,;|]+/).filter(function (c) {
    if (!/^T\d{1,10}T$/.test(c) || seen[c]) return false;
    seen[c] = true;
    return true;
  });
}

/**
 * Trolley custody of the date range, in time order: OUT records (each trolley code of a Finish
 * entry or of a MOP save) and RETURN records (CentralDB TrolleyReturns rows, by BusinessDate).
 */
function lsfCollectTrolleys_(range, collected) {
  const out = [];
  (collected.normal || []).forEach(function (r) {
    const e = r.entry;
    lsfTrolleyCodes_(e.Trolleys).forEach(function (code) {
      out.push({at: lsfEpoch_(e.CreatedAt), record: {record_type: 'OUT', area: 'FINISH', source_id: r.source_record_id,
        source_record_id: r.source_record_id + ':' + code, trolley_code: code, customer_id: e.CustomerID,
        business_date: e.BusinessDate, at: e.CreatedAt}});
    });
  });
  (collected.mop || []).forEach(function (r) {
    const codes = {}, active = r.events.filter(function (e) {
      return String(e.Status || '').toUpperCase() === 'ACTIVE' && String(e.EventType || 'PRODUCTION').toUpperCase() === 'PRODUCTION';
    });
    if (!active.length) return;
    active.sort(function (a, b) { return (lsfEpoch_(a.ProcessedAt) || 0) - (lsfEpoch_(b.ProcessedAt) || 0); });
    active.forEach(function (e) { lsfTrolleyCodes_(e.Trolleys).forEach(function (c) { codes[c] = true; }); });
    Object.keys(codes).sort().forEach(function (code) {
      out.push({at: lsfEpoch_(active[0].ProcessedAt), record: {record_type: 'OUT', area: 'MOP', source_id: r.source_record_id,
        source_record_id: r.source_record_id + ':' + code, trolley_code: code, customer_id: active[0].CustomerID,
        business_date: active[0].BusinessDate, at: active[0].ProcessedAt}});
    });
  });

  const central = lsConfig_().sources.central;
  const css = SpreadsheetApp.openById(central.id);
  const userIds = lsfUserIds_(css), seen = {};
  lsfReadSheet_(css, LSF.returnSheet, LSF.returnFields, true).forEach(function (row) {
    const id = lsfText_(row.ReturnID), day = lsfText_(row.BusinessDate, 'date');
    if (!id || !day || day < range.from || day > range.to || seen[id]) return;
    seen[id] = true;
    const r = lsfPick_(row, LSF.returnFields);
    ['ReturnedAt', 'LastDispatchAt', 'CreatedAt', 'VoidedAt', 'CorrectedAt'].forEach(function (f) { r[f] = lsfLocal_(row[f]); });
    r.ReceivedByUserID = userIds[String(r.ReceivedBy || '').toLowerCase()] || null;
    out.push({at: lsfEpoch_(row.ReturnedAt), record: {record_type: 'RETURN', source_record_id: id, row: r}});
  });

  // Time order; a record without a time goes last. Same instant: the return first (it frees the trolley).
  out.sort(function (a, b) {
    const x = a.at === null ? Infinity : a.at, y = b.at === null ? Infinity : b.at;
    if (x !== y) return x < y ? -1 : 1;
    return a.record.record_type === b.record.record_type ? 0 : (a.record.record_type === 'RETURN' ? -1 : 1);
  });
  return out.map(function (o) { return o.record; });
}

/**
 * Attendance of the date range (by business day), in the order it was typed: Finish StaffSessions
 * (+ History; the current sheet wins), Finish RosterNotWorking and the Sorting "Staff" sheet
 * (one row per person, day and shift; the last row typed wins).
 */
function lsfCollectAttendance_(range) {
  const conf = lsConfig_();
  const out = [], notes = [];
  const css = SpreadsheetApp.openById(conf.sources.central.id);
  const userIds = lsfUserIds_(css);
  const inRange = function (day) { return day && day >= range.from && day <= range.to; };

  const fss = SpreadsheetApp.openById(conf.sources.finish.id), ftz = fss.getSpreadsheetTimeZone();
  const seen = {};
  LSF.sessionSheets.forEach(function (name, sheetIndex) {
    let rows = [];
    try { rows = lsfReadSheet_(fss, name, LSF.sessionFields, sheetIndex === 0); } catch (e) { if (sheetIndex === 0) throw e; notes.push(String(e.message || e)); }
    rows.forEach(function (row) {
      const id = lsfText_(row.SessionID), day = lsfText_(row.BusinessDate, 'date');
      if (!id || !inRange(day) || seen[id]) return;
      seen[id] = true;
      const r = lsfPick_(row, LSF.sessionFields);
      r.CreatedAt = lsfLocal_(row.CreatedAt);
      r.StartTime = lsfClock_(row.StartTime, ftz);
      r.EndTime = lsfClock_(row.EndTime, ftz);
      r.UserID = userIds[String(r.UserName || '').toLowerCase()] || null;
      out.push({at: lsfEpoch_(row.CreatedAt), record: {record_type: 'FINISH_SESSION', source_record_id: id, row: r}});
    });
  });
  lsfReadSheet_(fss, 'RosterNotWorking', LSF.notWorkingFields, false).forEach(function (row) {
    const id = lsfText_(row.DismissalID), day = lsfText_(row.BusinessDate, 'date');
    if (!id || !inRange(day) || seen[id]) return;
    seen[id] = true;
    const r = lsfPick_(row, LSF.notWorkingFields);
    r.CreatedAt = lsfLocal_(row.CreatedAt);
    out.push({at: lsfEpoch_(row.CreatedAt), record: {record_type: 'FINISH_NOT_WORKING', source_record_id: id, row: r}});
  });

  const sorting = conf.sources.sorting;
  if (sorting && sorting.enabled && sorting.id) {
    const sss = SpreadsheetApp.openById(sorting.id), stz = sss.getSpreadsheetTimeZone();
    const previousDay = function (day) { const d = new Date(day + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() - 1); return Utilities.formatDate(d, 'UTC', 'yyyy-MM-dd'); };
    const byKey = {};
    lsfReadSheet_(sss, 'Staff', LSF.sortingStaffFields, true).forEach(function (row) {
      const name = lsfText_(row.Name), shift = lsfText_(row.Shift), entered = lsfLocal_(row.Date);
      if (!name || !shift || !entered) return;
      // A row typed before 03:00 for the Evening belongs to the previous day.
      const day = /^evening$/i.test(shift) && entered.slice(11, 16) < '03:00' ? previousDay(entered.slice(0, 10)) : entered.slice(0, 10);
      if (!inRange(day)) return;
      const key = day + '|' + shift + '|' + name.toLowerCase();
      byKey[key] = {at: lsfEpoch_(row.Date), record: {record_type: 'SORTING_STAFF', source_record_id: key, row: {
        BusinessDate: day, Shift: shift, Name: name, UserID: userIds[name.toLowerCase()] || null,
        StartShift: lsfClock_(row['Start Shift'], stz), EndShift: lsfClock_(row['End Shift'], stz),
        Break: lsfClock_(row.Break, stz), Comments: lsfText_(row.Coments), WorkPosition: lsfText_(row['Work position']),
        EnteredAt: entered}}};
    });
    Object.keys(byKey).forEach(function (k) { out.push(byKey[k]); });
  } else {
    notes.push('Sorting spreadsheet is not configured or not enabled: Sorting staff not sent.');
  }

  out.sort(function (a, b) {
    const x = a.at === null ? Infinity : a.at, y = b.at === null ? Infinity : b.at;
    return x === y ? 0 : (x < y ? -1 : 1);
  });
  return {records: out.map(function (o) { return o.record; }), notes: notes};
}

/** Every part of the sync for the date range. */
/**
 * CentralDB registers: every row of User, CustomerMaster, Trolley, Driver and Vehicles. Dates are
 * Dublin calendar days (yyyy-MM-dd); RegisteredAt / UpdatedAt are Dublin local date-times.
 */
function lsfCollectMaster_() {
  const central = lsConfig_().sources.central;
  if (!central || !central.enabled || !central.id) return {records: [], notes: ['CentralDB is not configured or not enabled.']};
  const css = SpreadsheetApp.openById(central.id), out = [], notes = [];
  LSF.masterSheets.forEach(function (spec) {
    const sh = css.getSheetByName(spec.sheet);
    if (!sh) { notes.push('Sheet ' + spec.sheet + ' is missing.'); return; }
    const n = sh.getLastRow() - 1, width = sh.getLastColumn();
    if (n < 1) return;
    const headers = sh.getRange(1, 1, 1, width).getValues()[0].map(function (h) { return String(h || '').trim(); });
    if (headers.indexOf(spec.key) < 0) { notes.push(spec.sheet + ' has no ' + spec.key + ' column.'); return; }
    const missing = spec.fields.filter(function (f) { return headers.indexOf(f) < 0; });
    if (missing.length) notes.push(spec.sheet + ' has no column ' + missing.join(', ') + ' (sent empty).');
    const values = sh.getRange(2, 1, n, width).getValues(), seen = {};
    values.forEach(function (cells) {
      const row = {};
      spec.fields.forEach(function (f) {
        const i = headers.indexOf(f), v = i < 0 ? null : cells[i];
        if (LSF.masterInstants.indexOf(f) >= 0) row[f] = lsfLocal_(v);
        else row[f] = lsfText_(v, v instanceof Date ? 'date' : null);
      });
      const id = row[spec.key];
      if (!id) return;
      if (seen[id]) { notes.push(spec.sheet + ': duplicate ' + spec.key + ' ' + id + ' (first row kept).'); return; }
      seen[id] = true;
      out.push({record_type: spec.type, source_record_id: id, row: row});
    });
  });
  return {records: out, notes: notes};
}

/**
 * CentralDB Routes (one record per RouteID; the sheet has a row per route and weekday, the last one is
 * kept: only the name and colour are synced) and CustomerSchedule (one record per CustomerID with all
 * its rows as production days).
 */
function lsfCollectSchedules_() {
  const central = lsConfig_().sources.central;
  if (!central || !central.enabled || !central.id) return {records: [], notes: ['CentralDB is not configured or not enabled.']};
  const css = SpreadsheetApp.openById(central.id), notes = [], routes = {}, customers = {}, order = [];
  lsfReadSheet_(css, 'Routes', LSF.routeFields, true).forEach(function (r) {
    const row = lsfPick_(r, LSF.routeFields);
    if (row.RouteID) routes[row.RouteID] = row;
  });
  lsfReadSheet_(css, 'CustomerSchedule', LSF.scheduleFields, true).forEach(function (r) {
    const row = lsfPick_(r, LSF.scheduleFields), id = row.CustomerID;
    if (!id) { if (row.ProductionDay) notes.push('CustomerSchedule row ' + r._row + ' has no CustomerID.'); return; }
    if (!customers[id]) { customers[id] = {CustomerID: id, CustomerName: row.CustomerName, days: []}; order.push(id); }
    delete row.CustomerID; delete row.CustomerName;
    customers[id].days.push(row);
  });
  const records = Object.keys(routes).map(function (id) { return {record_type: 'ROUTE', source_record_id: id, row: routes[id]}; })
    .concat(order.map(function (id) { return {record_type: 'SCHEDULE', source_record_id: id, row: customers[id]}; }));
  return {records: records, notes: notes.slice(0, 20)};
}

function lsfCollectAll_(range) {
  const collected = lsfCollect_(range);
  const washes = lsfCollectWashes_(range);
  collected.wash = washes.records;
  collected.notes = {wash: [washes.note, washes.duplicates && washes.duplicates.length ? 'Duplicate WashID ignored: ' + washes.duplicates.slice(0, 10).join(', ') : null].filter(Boolean)};
  try {
    collected.mop = lsfCollectMops_(range).records;
  } catch (e) {
    collected.mop = [];
    collected.notes.mop = ['MOP sheets could not be read: ' + String(e.message || e)];
  }
  try {
    const master = lsfCollectMaster_();
    collected.master = master.records;
    if (master.notes.length) collected.notes.master = master.notes.slice(0, 20);
  } catch (e) {
    collected.master = [];
    collected.notes.master = ['CentralDB registers could not be read: ' + String(e.message || e)];
  }
  try {
    const schedules = lsfCollectSchedules_();
    collected.schedule = schedules.records;
    if (schedules.notes.length) collected.notes.schedule = schedules.notes;
  } catch (e) {
    collected.schedule = [];
    collected.notes.schedule = ['CentralDB schedules could not be read: ' + String(e.message || e)];
  }
  try {
    const attendance = lsfCollectAttendance_(range);
    collected.attendance = attendance.records;
    if (attendance.notes.length) collected.notes.attendance = attendance.notes;
  } catch (e) {
    collected.attendance = [];
    collected.notes.attendance = ['Attendance sheets could not be read: ' + String(e.message || e)];
  }
  try {
    collected.trolley = lsfCollectTrolleys_(range, collected);
  } catch (e) {
    collected.trolley = [];
    collected.notes.trolley = ['Trolley sheets could not be read: ' + String(e.message || e)];
  }
  return collected;
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
  // A part whose database side is not installed yet is reported and skipped, never fatal.
  LSF.kinds.forEach(function (kind) {
    const records = collected[kind] || [], size = LSF[kind + 'Batch'];
    plans[kind] = [];
    try {
      for (let i = 0; i < records.length; i += size) {
        const r = lsfCall_({operation: 'dry_run', kind: kind, records: records.slice(i, i + size)});
        if (!r.ok) throw Error(r.error);
        plans[kind] = plans[kind].concat(r.result.plans || []);
      }
      if (plans[kind].length !== records.length) throw Error('Dry run response does not match the records sent');
    } catch (e) {
      plans[kind] = null;
      collected.notes = collected.notes || {};
      collected.notes[kind] = (collected.notes[kind] || []).concat(['Not available yet: ' + String(e.message || e)]);
    }
  });
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
      // Registers: today's differences between the legacy row and V2, listed once at adoption.
      (p.warnings || []).forEach(function (w) {
        if (w.code !== 'V2_DIFFERS') return;
        s.differs = s.differs || [];
        if (s.differs.length < 300) s.differs.push({type: p.record_type, id: p.source_record_id, detail: w.detail});
      });
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
 * Imports the range inside one COMMIT run: attendance first, then washes, MOP, Finish, ReWash and trolleys. The database
 * refuses a part whose switch is off, and stops a part at its max_entries_per_run.
 * READY records are written; BLOCKED records go to the review queue; others are left alone.
 */
function importFinishSync(fromDate, toDate, reason) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) throw Error('A synchronization is already running');
  const started = Date.now();
  let runId = null;
  const result = {mode: 'COMMIT', reason: reason || 'MANUAL', results: {master: {}, schedule: {}, attendance: {}, wash: {}, mop: {}, normal: {}, rewash: {}, trolley: {}}, stopped: null};
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

    const groups = LSF.parts.map(function (kind) {
      if (kind === 'normal') return {kind: kind, body: function (record) { return {operation: 'import_finish', runId: runId, record: record}; }};
      if (kind === 'rewash') return {kind: kind, body: function (record) { return {operation: 'import_rewash', runId: runId, record: record}; }};
      return {kind: kind, body: function (record) { return {operation: 'import', kind: kind, runId: runId, record: record}; }};
    });
    for (const g of groups) {
      if (!plans[g.kind]) continue;
      if (g.kind === 'master' || g.kind === 'schedule') { lsfImportBatches_(g.kind, runId, collected[g.kind], plans[g.kind], result, started); continue; }
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

/** Registers and schedules go in batches (each record is still its own transaction in V2). */
function lsfImportBatches_(kind, runId, records, plans, result, started) {
  const out = result.results[kind], todo = [], size = LSF[kind + 'Batch'];
  records.forEach(function (record, i) {
    if (plans[i].outcome === 'READY' || plans[i].outcome === 'BLOCKED') todo.push(record);
  });
  for (let i = 0; i < todo.length && !result.stopped; i += size) {
    if (Date.now() - started > LSF.timeBudgetMs) { result.stopped = 'TIME_BUDGET'; break; }
    const r = lsfCall_({operation: 'import', kind: kind, runId: runId, record: {records: todo.slice(i, i + size)}});
    if (!r.ok) {
      lsfCount_(out, 'REFUSED_' + r.code);
      if (r.code === '55000') { out.refusal = r.error; return; }
      continue;
    }
    const counts = (r.result || {}).counts || {};
    Object.keys(counts).forEach(function (k) { out[k] = (out[k] || 0) + counts[k]; });
    if (counts.RUN_LIMIT_REACHED) return;
  }
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

/** Index.html "Pending": records the sync held, plus the latest decisions. */
function getLegacySyncReviews() {
  const r = lsfCall_({operation: 'review_list'});
  if (!r.ok) throw Error(r.error || ('Refused: ' + r.code));
  return r.result;
}

/**
 * Index.html "Pending": one choice for one held record, kept in V2 with who and when.
 * FIX_IN_SOURCE: the row will be corrected in the legacy sheet. NOT_IMPORTED: never import it.
 */
function decideLegacySyncReview(reviewId, action, note) {
  const who = String(Session.getActiveUser().getEmail() || '').trim() || 'Apps Script admin page';
  const r = lsfCall_({operation: 'review_decide', reviewId: String(reviewId || ''), action: String(action || ''),
    decidedBy: who, note: String(note || '').slice(0, 500)});
  if (!r.ok) throw Error(r.error || ('Refused: ' + r.code));
  return getLegacySyncReviews();
}
