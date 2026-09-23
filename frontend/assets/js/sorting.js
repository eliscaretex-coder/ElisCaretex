"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const standaloneMop = document.body?.dataset?.mopStandalone === "true";

  const el = {
    nav: [...document.querySelectorAll("[data-sorting-view]")],
    panels: [...document.querySelectorAll("[data-view-panel]")],
    title: $("sortingPageTitle"),
    subtitle: $("sortingPageSubtitle"),
    shiftTabs: $("sortingShiftTabs"),
    shiftAutoButton: $("sortingShiftAutoButton"),
    sidebarShift: $("sortingSidebarShift"),
    sidebarDate: $("sortingSidebarDate"),
    businessDate: $("sortingBusinessDate"),
    businessDateStatus: $("sortingBusinessDateStatus"),
    rosterSource: $("sortingRosterSource"),
    plannedCount: $("sortingPlannedCount"),
    sessionName: $("sortingSignedInName"),
    message: $("sortingPageMessage"),
    reload: $("sortingReloadButton"),
    signOut: $("sortingSignOutButton"),

    washForm: $("sortingWashForm"),
    operator: $("sortingWashOperator"),
    washer: $("sortingWasher"),
    washerCapacity: $("sortingWasherCapacity"),
    registerTime: $("sortingRegisterTime"),
    type: $("sortingWashType"),
    weight: $("sortingWashWeight"),
    start: $("sortingWashStartTime"),
    notes: $("sortingWashNotes"),
    clearWash: $("sortingWashClearButton"),
    missedWash: $("sortingWashMissedButton"),
    rareActions: $("sortingRareActions"),
    saveWash: $("sortingWashSaveButton"),
    historySearch: $("sortingWashHistorySearch"),
    historySearchButton: $("sortingWashHistorySearchButton"),
    historyClearButton: $("sortingWashHistoryClearButton"),
    historySearchStatus: $("sortingWashHistorySearchStatus"),
    editBanner: $("sortingWashEditBanner"),
    editTitle: $("sortingWashEditTitle"),
    cancelEdit: $("sortingWashCancelEditButton"),
    washConfirmDialog: $("sortingWashConfirmDialog"),
    washConfirmForm: $("sortingWashConfirmForm"),
    washConfirmTitle: $("sortingWashConfirmTitle"),
    washConfirmMode: $("sortingWashConfirmMode"),
    washConfirmRisk: $("sortingWashConfirmRisk"),
    washConfirmRiskText: $("sortingWashConfirmRiskText"),
    washConfirmWeight: $("sortingWashConfirmWeight"),
    washConfirmType: $("sortingWashConfirmType"),
    washConfirmCustomerCount: $("sortingWashConfirmCustomerCount"),
    washConfirmCustomers: $("sortingWashConfirmCustomers"),
    washConfirmStaff: $("sortingWashConfirmStaff"),
    washConfirmWasher: $("sortingWashConfirmWasher"),
    washConfirmStart: $("sortingWashConfirmStart"),
    washConfirmBusiness: $("sortingWashConfirmBusiness"),
    washConfirmSpecial: $("sortingWashConfirmSpecial"),
    washConfirmReasonLabel: $("sortingWashConfirmReasonLabel"),
    washConfirmReason: $("sortingWashConfirmReason"),
    washConfirmNotesWrap: $("sortingWashConfirmNotesWrap"),
    washConfirmNotes: $("sortingWashConfirmNotes"),
    washConfirmReceptionException: $("sortingWashConfirmReceptionException"),
    washConfirmReceptionExceptionList: $("sortingWashConfirmReceptionExceptionList"),
    washConfirmMessage: $("sortingWashConfirmMessage"),
    washConfirmSave: $("sortingWashConfirmSaveButton"),
    customerButton: $("sortingCustomerPickerButton"),
    selectedCustomers: $("sortingSelectedCustomers"),
    recentWashes: $("sortingRecentWashesBody"),
    todayType: $("sortingTodayTypeBadge"),
    todayProgress: $("sortingTodayProgress"),
    todayList: $("sortingTodayCustomers"),

    dialog: $("sortingCustomerDialog"),
    dialogHint: $("sortingCustomerDialogHint"),
    customerSearch: $("sortingCustomerSearch"),
    customerShowAll: $("sortingCustomerShowAll"),
    customerOptions: $("sortingCustomerOptions"),
    customerCount: $("sortingCustomerSelectionCount"),
    washReceptionExceptionButton: $("sortingWashReceptionExceptionButton"),
    washReceptionExceptionDialog: $("sortingWashReceptionExceptionDialog"),
    washReceptionExceptionOptions: $("sortingWashReceptionExceptionOptions"),
    washReceptionExceptionReason: $("sortingWashReceptionExceptionReason"),
    washReceptionExceptionMessage: $("sortingWashReceptionExceptionMessage"),
    washReceptionExceptionCount: $("sortingWashReceptionExceptionCount"),
    washReceptionExceptionUse: $("sortingWashReceptionExceptionUseButton"),

    trolleyStaffBar: $("sortingTrolleyStaffBar"),
    trolleyStaffPrompt: $("sortingTrolleyStaffPrompt"),
    trolleyScanIdle: $("sortingTrolleyScanIdle"),
    trolleyScanTitle: $("sortingTrolleyScanTitle"),
    trolleyScanHint: $("sortingTrolleyScanHint"),
    trolleyScanBuffer: $("sortingTrolleyScanBuffer"),
    trolleyManualButton: $("sortingTrolleyManualButton"),
    trolleyBatchToggle: $("sortingTrolleyBatchToggle"),
    trolleyOutboxStatus: $("sortingTrolleyOutboxStatus"),
    trolleyBasketPanel: $("sortingTrolleyBasketPanel"),
    trolleyBasketCount: $("sortingTrolleyBasketCount"),
    trolleyBasketList: $("sortingTrolleyBasketList"),
    trolleyBasketClear: $("sortingTrolleyBasketClearButton"),
    trolleyBasketConfirm: $("sortingTrolleyBasketConfirmButton"),
    trolleyPreview: $("sortingTrolleyPreview"),
    trolleyResultDialog: $("sortingTrolleyResultDialog"),
    trolleySummary: $("sortingTrolleySummary"),
    trolleyTodayType: $("sortingTrolleyTodayTypeBadge"),
    trolleyTodayProgress: $("sortingTrolleyTodayProgress"),
    trolleyTodayList: $("sortingTrolleyTodayCustomers"),
    arrivals: $("sortingRecentArrivals"),
    trolleyCustomerDialog: $("sortingTrolleyCustomerDialog"),
    trolleyCustomerTabs: $("sortingTrolleyCustomerTabs"),
    trolleyCustomerOptions: $("sortingTrolleyCustomerOptions"),
    trolleyEditDialog: $("sortingTrolleyEditDialog"),
    trolleyEditForm: $("sortingTrolleyEditForm"),
    trolleyEditSummary: $("sortingTrolleyEditSummary"),
    trolleyEditCustomer: $("sortingTrolleyEditCustomer"),
    trolleyEditDate: $("sortingTrolleyEditDate"),
    trolleyEditProduct: $("sortingTrolleyEditProduct"),
    trolleyEditContents: $("sortingTrolleyEditContents"),
    trolleyEditStaff: $("sortingTrolleyEditStaff"),
    trolleyEditReason: $("sortingTrolleyEditReason"),
    trolleyEditMessage: $("sortingTrolleyEditMessage"),
    trolleyEditSave: $("sortingTrolleyEditSaveButton"),
    trolleyManualDialog: $("sortingTrolleyManualDialog"),
    trolleyManualDisplay: $("sortingTrolleyManualDisplay"),
    trolleyKeypad: $("sortingTrolleyKeypad"),
    trolleyManualScan: $("sortingTrolleyManualScanButton"),
    staffWorkList: $("sortingStaffWorkList"),
    staffScheduleNote: $("sortingStaffScheduleNote"),
    staffCount: $("sortingStaffCount"),
    addManualStaffButton: $("sortingAddManualStaffButton"),
    manualStaffDialog: $("sortingManualStaffDialog"),
    manualStaffSearch: $("sortingManualStaffSearch"),
    manualStaffOptions: $("sortingManualStaffOptions"),
    manualStaffHint: $("sortingManualStaffHint"),
    attendanceDialog: $("sortingAttendanceDialog"),
    attendanceForm: $("sortingAttendanceForm"),
    attendanceTitle: $("sortingAttendanceTitle"),
    attendanceHint: $("sortingAttendanceHint"),
    attendanceNotes: $("sortingAttendanceNotes"),
    attendanceMessage: $("sortingAttendanceMessage"),
    attendanceSave: $("sortingAttendanceSaveButton"),
    absencePanel: $("sortingAbsencePanel"),
    moveAreaPanel: $("sortingMoveAreaPanel"),
    moveAreaSelect: $("sortingMoveAreaSelect"),
    noTrolleyArrivalDialog: $("sortingNoTrolleyArrivalDialog"),
    noTrolleyArrivalSummary: $("sortingNoTrolleyArrivalSummary"),
    noTrolleyArrivalNotes: $("sortingNoTrolleyArrivalNotes"),
    noTrolleyArrivalMessage: $("sortingNoTrolleyArrivalMessage"),
    noTrolleyArrivalSave: $("sortingNoTrolleyArrivalSaveButton"),
    mopDueBanner: $("sortingMopDueBanner"),
    mopStaffBadge: $("sortingMopStaffBadge"),
    mopEmptySelection: $("sortingMopEmptySelection"),
    mopForm: $("sortingMopForm"),
    mopCustomerSummary: $("sortingMopCustomerSummary"),
    mopLateCompletionBanner: $("sortingMopLateCompletionBanner"),
    mopTrolleySection: $("sortingMopTrolleySection"),
    mopTrolleyRequirement: $("sortingMopTrolleyRequirement"),
    mopTrolleyInputWrap: $("sortingMopTrolleyInputWrap"),
    mopTrolleyInput: $("sortingMopTrolleyInput"),
    mopAddTrolley: $("sortingMopAddTrolleyButton"),
    mopTrolleyChips: $("sortingMopTrolleyChips"),
    mopLateTrolleyUnknownInlineLabel: $("sortingMopLateTrolleyUnknownInlineLabel"),
    mopLateTrolleyUnknownInline: $("sortingMopLateTrolleyUnknownInline"),
    mopTrolleyHelp: $("sortingMopTrolleyHelp"),
    mopTypeRows: $("sortingMopTypeRows"),
    mopNotes: $("sortingMopNotes"),
    mopClear: $("sortingMopClearButton"),
    mopSave: $("sortingMopSaveButton"),
    mopSaveMessage: $("sortingMopSaveMessage"),
    mopRecent: $("sortingMopRecent"),
    mopTraceSummary: $("sortingMopTraceSummary"),
    mopAbsDialog: $("sortingMopAbsDialog"),
    mopAbsClose: $("sortingMopAbsCloseButton"),
    mopAbsCancel: $("sortingMopAbsCancelButton"),
    mopAbsSummary: $("sortingMopAbsSummary"),
    mopAbsBatchInput: $("sortingMopAbsBatchInput"),
    mopAbsNotes: $("sortingMopAbsNotes"),
    mopAbsMessage: $("sortingMopAbsMessage"),
    mopAbsSave: $("sortingMopAbsSaveButton"),
    mopCorrectionDialog: $("sortingMopCorrectionDialog"),
    mopCorrectionClose: $("sortingMopCorrectionCloseButton"),
    mopCorrectionCancel: $("sortingMopCorrectionCancelButton"),
    mopCorrectionSave: $("sortingMopCorrectionSaveButton"),
    mopCorrectionSummary: $("sortingMopCorrectionSummary"),
    mopCorrectionLines: $("sortingMopCorrectionLines"),
    mopCorrectionTrolleySection: $("sortingMopCorrectionTrolleySection"),
    mopCorrectionTrolleyMode: $("sortingMopCorrectionTrolleyMode"),
    mopCorrectionTrolleyLocked: $("sortingMopCorrectionTrolleyLocked"),
    mopCorrectionTrolleyCodesWrap: $("sortingMopCorrectionTrolleyCodesWrap"),
    mopCorrectionTrolleyCodes: $("sortingMopCorrectionTrolleyCodes"),
    mopCorrectionTrolleyUnknownWrap: $("sortingMopCorrectionTrolleyUnknownWrap"),
    mopCorrectionTrolleyUnknown: $("sortingMopCorrectionTrolleyUnknown"),
    mopCorrectionNotes: $("sortingMopCorrectionNotes"),
    mopCorrectionReason: $("sortingMopCorrectionReason"),
    mopCorrectionHistory: $("sortingMopCorrectionHistory"),
    mopCorrectionMessage: $("sortingMopCorrectionMessage"),
    mopCancelDialog: $("sortingMopCancelDialog"),
    mopCancelClose: $("sortingMopCancelCloseButton"),
    mopCancelCancel: $("sortingMopCancelCancelButton"),
    mopCancelSave: $("sortingMopCancelSaveButton"),
    mopCancelSummary: $("sortingMopCancelSummary"),
    mopCancelAbsWarning: $("sortingMopCancelAbsWarning"),
    mopCancelAbsEvidence: $("sortingMopCancelAbsEvidence"),
    mopCancelReason: $("sortingMopCancelReason"),
    mopCancelMessage: $("sortingMopCancelMessage"),
    mopQueueDate: $("sortingMopQueueDate"),
    mopQueueCount: $("sortingMopQueueCount"),
    mopQueue: $("sortingMopQueue"),
    mopReconciliationDialog: $("sortingMopReconciliationDialog"),
    mopReconciliationSummary: $("sortingMopReconciliationSummary"),
    mopReconciliationChoices: $("sortingMopReconciliationChoices"),
    mopLateEntryPanel: $("sortingMopLateEntryPanel"),
    mopLateProcessedDate: $("sortingMopLateProcessedDate"),
    mopLateProcessedTime: $("sortingMopLateProcessedTime"),
    mopLateReason: $("sortingMopLateReason"),
    mopLateTrolleyUnknownLabel: $("sortingMopLateTrolleyUnknownLabel"),
    mopLateTrolleyUnknown: $("sortingMopLateTrolleyUnknown"),
    mopLateContinue: $("sortingMopLateContinueButton"),
    mopNotProcessedPanel: $("sortingMopNotProcessedPanel"),
    mopNotProcessedReason: $("sortingMopNotProcessedReason"),
    mopNotProcessedSave: $("sortingMopNotProcessedSaveButton"),
    mopReconciliationMessage: $("sortingMopReconciliationMessage"),
    mopTypesButton: $("sortingMopTypesButton"),
    mopTypesDialog: $("sortingMopTypesDialog"),
    mopTypesClose: $("sortingMopTypesCloseButton"),
    mopTypesPermission: $("sortingMopTypesPermission"),
    mopTypesCount: $("sortingMopTypesCount"),
    mopTypesSearch: $("sortingMopTypesSearch"),
    mopTypeNewButton: $("sortingMopTypeNewButton"),
    mopTypesList: $("sortingMopTypesList"),
    mopTypeEditor: $("sortingMopTypeEditor"),
    mopTypesMessage: $("sortingMopTypesMessage"),

    trackerDayCards: $("sortingTrackerDayCards"),
    trackerHistoryButton: $("sortingTrackerHistoryButton"),
    trackerRefreshButton: $("sortingTrackerRefreshButton"),
    trackerDemoButton: $("sortingTrackerDemoButton"),
    trackerDemoBanner: $("sortingTrackerDemoBanner"),
    trackerUpdated: $("sortingTrackerUpdated"),
    trackerHistoryBanner: $("sortingTrackerHistoryBanner"),
    trackerHistoryDate: $("sortingTrackerHistoryDate"),
    trackerHistoryExit: $("sortingTrackerHistoryExitButton"),
    trackerKpiScheduled: $("sortingTrackerKpiScheduled"),
    trackerKpiNotStarted: $("sortingTrackerKpiNotStarted"),
    trackerKpiWashed: $("sortingTrackerKpiWashed"),
    trackerKpiAbs: $("sortingTrackerKpiAbs"),
    trackerKpiDone: $("sortingTrackerKpiDone"),
    trackerKpiKg: $("sortingTrackerKpiKg"),
    trackerSearch: $("sortingTrackerSearch"),
    trackerStatusFilter: $("sortingTrackerStatusFilter"),
    trackerTypeFilter: $("sortingTrackerTypeFilter"),
    trackerRowCount: $("sortingTrackerRowCount"),
    trackerTableWrap: $("sortingTrackerTableWrap"),
    trackerExpandAll: $("sortingTrackerExpandAll"),
    trackerCollapseAll: $("sortingTrackerCollapseAll"),
    trackerHistoryDialog: $("sortingTrackerHistoryDialog"),
    trackerHistoryClose: $("sortingTrackerHistoryCloseButton"),
    trackerHistoryCancel: $("sortingTrackerHistoryCancelButton"),
    trackerHistoryLoad: $("sortingTrackerHistoryLoadButton"),
    trackerHistoryInput: $("sortingTrackerHistoryInput"),
    trackerHistoryMessage: $("sortingTrackerHistoryMessage"),
    trackerAbsDialog: $("sortingTrackerAbsDialog"),
    trackerAbsClose: $("sortingTrackerAbsCloseButton"),
    trackerAbsCancel: $("sortingTrackerAbsCancelButton"),
    trackerAbsSummary: $("sortingTrackerAbsSummary"),
    trackerAbsInput: $("sortingTrackerAbsInput"),
    trackerAbsNotes: $("sortingTrackerAbsNotes"),
    trackerAbsMessage: $("sortingTrackerAbsMessage"),
    trackerAbsSave: $("sortingTrackerAbsSaveButton")
  };

  const state = {
    view: standaloneMop ? "mop" : (["washing","trolley","mop","tracker","staff"].includes(location.hash.slice(1)) ? location.hash.slice(1) : "washing"),
    shift: "MORNING",
    shiftMode: "AUTO",
    autoShift: null,
    washing: null,
    sorting: null,
    staffWork: null,
    editingStaffId: null,
    attendanceStaffId: null,
    noWorkOptions: null,
    manualStaffCandidates: [],
    trolley: null,
    trolleyDraft: null,
    trolleyOperatorStaffId: null,
    trolleyScanBuffer: "",
    trolleyScanTimer: null,
    trolleyCustomerTab: "SCHEDULED",
    trolleyManualDigits: "",
    trolleyBatchMode: false,
    trolleyBasket: [],
    trolleyOutboxFlushing: false,
    pendingTrolleyConfirmation: null,
    pendingTrolleyEdit: null,
    pendingNoTrolleyArrival: null,
    mop: null,
    mopTrace: null,
    pendingMopAbsBatch: null,
    pendingMopCorrectionBatch: null,
    mopCorrectionContext: null,
    mopCorrectionSaving: false,
    pendingMopCancelBatch: null,
    mopCancelSaving: false,
    mopSelectedFlowId: null,
    mopTrolleyCodes: [],
    mopLateEntry: null,
    mopReconciliationFlowId: null,
    mopTrolleyReportReference: null,
    mopTrolleyReportSaving: false,
    mopTypeCatalog: null,
    mopTypeSelectedId: null,
    mopTypeUploadFile: null,
    mopTypeCreating: false,
    mopTypeSearch: "",
    mopTypeCodeTouched: false,
    mopTypePreviewUrl: null,
    mopTypeDirty: false,
    mopTypeSaving: false,
    trackerData: null,
    trackerDate: null,
    trackerTodayDate: null,
    trackerHistoryMode: false,
    trackerDayStats: {},
    trackerAbsItem: null,
    trackerDemoActive: false,
    trackerDemoData: null,
    trackerCollapsedRoutes: new Set(),
    selectedCustomers: [],
    draftCustomers: [],
    washCustomerShowAll: false,
    washReceptionExceptions: {},
    draftWashReceptionExceptionKeys: [],
    pendingWashNoTrolleyRow: null,
    editingWash: null,
    lateEntryMode: false,
    pendingWashConfirmation: null,
    typeAutofilledByStaff: false,
    washSearchResults: null,
    busy: false,
    clockTimer: null,
    refreshTimer: null,
    autoShiftTimer: null
  };

  const washFormHome = {
    parent: el.washForm?.parentNode || null,
    next: el.washForm?.nextSibling || null
  };

  const viewCopy = {
    washing: ["Washing","Record washer loads and keep today's production traceable."],
    trolley: ["Trolley Intake","Confirm who received it, customer, scheduled date, contents and product before washing."],
    mop: ["MOP Production","Process MOP customers from the same workstation."],
    tracker: ["Tracker","Follow each customer from published plan through Washing, Production and ABS."],
    staff: ["Staff","Adjust actual worked time only when it differs from the published plan."]
  };

  const esc = (v) => String(v ?? "")
    .replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;")
    .replaceAll('"',"&quot;").replaceAll("'","&#039;");

  function fmtDate(v){
    if(!v) return "—";
    return new Intl.DateTimeFormat("en-IE",{weekday:"short",day:"2-digit",month:"short",year:"numeric"})
      .format(new Date(`${String(v).slice(0,10)}T12:00:00`));
  }
  function fmtTime(v){
    if(!v) return "—";
    if(/^\d{2}:\d{2}/.test(String(v))) return String(v).slice(0,5);
    return new Intl.DateTimeFormat("en-IE",{hour:"2-digit",minute:"2-digit",hour12:false}).format(new Date(v));
  }
  function titleCode(v){ return String(v||"").toLowerCase().split("_").map(x=>x?x[0].toUpperCase()+x.slice(1):"").join(" "); }
  const TROLLEY_OUTBOX_KEY = "eliscaretex.sorting.trolleyIntake.outbox.v1";
  function safeLocalGet(key,fallback){
    try{const raw=localStorage.getItem(key);return raw?JSON.parse(raw):fallback;}catch{return fallback;}
  }
  function safeLocalSet(key,value){
    try{localStorage.setItem(key,JSON.stringify(value));return true;}catch{return false;}
  }
  function outboxRows(){
    const rows=safeLocalGet(TROLLEY_OUTBOX_KEY,[]);
    return Array.isArray(rows)?rows:[];
  }
  function writeOutbox(rows){safeLocalSet(TROLLEY_OUTBOX_KEY,rows.slice(-500));renderTrolleyOutboxStatus();}
  function outboxId(){return crypto?.randomUUID?.()||`outbox-${Date.now()}-${Math.random().toString(36).slice(2)}`;}
  function routeTextColor(hex){
    const match=/^#([0-9a-f]{6})$/i.exec(String(hex||""));
    if(!match)return "#111827";
    const n=parseInt(match[1],16);
    const r=(n>>16)&255,g=(n>>8)&255,b=n&255;
    const luminance=(0.299*r+0.587*g+0.114*b)/255;
    return luminance>0.62?"#111827":"#ffffff";
  }
  function safeRouteColor(value){
    const color=String(value||"").trim();
    return /^#[0-9a-f]{6}$/i.test(color)?color:"";
  }
  function plannedPositionLabel(row){
    return String(row?.planned_position_label||"Not planned").replaceAll("_"," ");
  }
  function setMessage(text="", type=""){
    el.message.textContent=text; el.message.className="sorting-message"; if(type) el.message.classList.add(type);
  }
  function friendly(error){
    const message=String(error?.message || "The operation could not be completed.");
    if(/Selected staff member is not active in Sorting for this shift/i.test(message)){
      return "This receipt can only be saved by an active Sorting staff member for the current shift. Sign in with the Sorting account and select your name in RECEIVING AS.";
    }
    if(/terminal|workstation|permission|not authorized|not authorised|access denied/i.test(message)){
      return "This workstation is not allowed to save Sorting production. Sign in with the Sorting account, not Admin or Viewer.";
    }
    return message;
  }
  function isTransientSendError(message){
    return /failed to fetch|network|offline|timeout|timed out|load failed|abort|could not connect|connection|temporarily unavailable/i.test(String(message||""));
  }
  async function rpc(name,args={}){
    const stationWrites={
      save_sorting_wash_run_v4:"terminal_save_sorting_wash_run_v4",
      save_sorting_missed_wash_v4:"terminal_save_sorting_missed_wash_v4",
      correct_sorting_wash_run_v4:"terminal_correct_sorting_wash_run_v4",
      record_sorting_trolley_intake_v2:"terminal_record_sorting_trolley_intake_v2",
      record_sorting_non_trolley_arrival:"terminal_record_sorting_non_trolley_arrival",
      correct_sorting_trolley_intake:"terminal_correct_sorting_trolley_intake",
      cancel_sorting_trolley_intake:"terminal_cancel_sorting_trolley_intake"
    };
    if(stationWrites[name]){
      name=stationWrites[name];
    }
    const {data,error}=await client.rpc(name,args); if(error) throw error; return data;
  }

  function renderView(){
    if(standaloneMop)state.view="mop";
    const copy=viewCopy[state.view];
    el.title.textContent=copy[0]; el.subtitle.textContent=copy[1];
    el.nav.forEach(b=>b.classList.toggle("active",b.dataset.sortingView===state.view));
    el.panels.forEach(p=>{const on=p.dataset.viewPanel===state.view;p.hidden=!on;p.classList.toggle("active",on);});
    if(location.hash!==`#${state.view}`) history.replaceState(null,"",`#${state.view}`);
  }
  function renderShift(){
    el.shiftTabs.querySelectorAll("[data-shift]").forEach(b=>{
      const on=b.dataset.shift===state.shift;
      b.classList.toggle("active",on);
      b.disabled=state.busy;
    });
    if(el.shiftAutoButton){
      el.shiftAutoButton.classList.toggle("active",state.shiftMode==="AUTO");
      el.shiftAutoButton.classList.toggle("manual",state.shiftMode==="MANUAL");
      el.shiftAutoButton.textContent=state.shiftMode==="AUTO"?"Auto":"Auto off";
      el.shiftAutoButton.title=state.shiftMode==="AUTO"
        ? "Shift changes automatically from the standard weekly schedule."
        : "Manual shift override is active for this workstation session. Click to return to Auto.";
    }
    el.sidebarShift.textContent=`${state.shift==="MORNING"?"Morning":"Evening"} Shift${state.shiftMode==="MANUAL"?" · Manual":""}`;
  }

  function hasWashDraft(){
    return Boolean(
      state.editingWash
      || state.lateEntryMode
      || state.selectedCustomers.length
      || el.washer.value
      || el.type.value
      || el.weight.value
      || el.start.value
      || el.notes.value.trim()
    );
  }

  async function refreshAutoShift(force=false){
    if(state.shiftMode!=="AUTO"&&!force)return false;
    try{
      const auto=await rpc(standaloneMop?"get_mop_auto_shift_context":"get_sorting_auto_shift_context",{});
      state.autoShift=auto||null;
      const recommended=auto?.recommended_shift_code;
      if(!["MORNING","EVENING"].includes(recommended))return false;
      if(recommended===state.shift){renderShift();return false;}
      if(!force&&(hasWashDraft()||hasMopProductionDraft())){
        const draftName=hasMopProductionDraft()?"MOP production":"wash";
        setMessage(`Auto Shift recommends ${recommended==="MORNING"?"Morning":"Evening"}, but the current ${draftName} form has unsaved data. Save or Clear it first.`,"warning");
        return false;
      }
      state.shift=recommended;
      state.selectedCustomers=[];
      state.trolley=null;
      state.trolleyDraft=null;
      state.pendingTrolleyConfirmation=null;
      state.staffWork=null;
      state.washing=null;
      state.sorting=null;
      state.mop=null;
      state.mopSelectedFlowId=null;
      state.mopTrolleyCodes=[];
      state.mopLateEntry=null;
      state.trolleyOperatorStaffId=null;
      state.attendanceStaffId=null;
      el.operator.value="";
      clearWashSearch();
      renderTrolleyResult();
      renderTrolleyStaffBar();
      renderShift();
      return true;
    }catch(error){
      console.error("Auto Shift:",error);
      return false;
    }
  }
  function tickClock(){
    el.registerTime.value=new Intl.DateTimeFormat("en-IE",{
      day:"2-digit",month:"2-digit",year:"numeric",hour:"2-digit",minute:"2-digit",second:"2-digit",hour12:false
    }).format(new Date());
  }

  const plannedStaff=()=>Array.isArray(state.washing?.planned_staff)?state.washing.planned_staff:[];
  const washers=()=>Array.isArray(state.washing?.washers)?state.washing.washers:[];
  const allCustomers=()=>Array.isArray(state.washing?.all_customers)?state.washing.all_customers:[];
  const boardCustomers=()=>Array.isArray(state.washing?.today_customers)?state.washing.today_customers:[];
  const customerById=(id)=>allCustomers().find(c=>c.customer_id===id);

  function shortDayDate(value){
    if(!value)return "—";
    const d=new Date(`${String(value).slice(0,10)}T12:00:00`);
    if(Number.isNaN(d.getTime()))return String(value);
    const day=new Intl.DateTimeFormat("en-IE",{weekday:"short"}).format(d);
    const dm=new Intl.DateTimeFormat("en-IE",{day:"2-digit",month:"2-digit"}).format(d);
    return `${day} ${dm}`;
  }

  function fullDayDate(value){
    if(!value)return "—";
    const d=new Date(`${String(value).slice(0,10)}T12:00:00`);
    if(Number.isNaN(d.getTime()))return String(value);
    return new Intl.DateTimeFormat("en-IE",{weekday:"long",day:"2-digit",month:"2-digit"}).format(d);
  }

  function scheduleSelectionKey(row){
    return `S:${row.schedule_product_id}:${row.scheduled_for_date}`;
  }

  function unscheduledSelectionKey(customer){
    return `U:${customer.customer_id}`;
  }

  function unscheduledScanEvidence(customerId,washType){
    const product=String(washType||"").toUpperCase()==="MOP"?"MOP":"CLOTHES";
    const rows=Array.isArray(state.washing?.unscheduled_scan_customers)
      ? state.washing.unscheduled_scan_customers
      : [];
    return rows.find(row=>row.customer_id===customerId&&row.product_code===product)||null;
  }

  function selectionScanReady(row){
    if(!row)return false;
    if(row.schedule_product_id)return Boolean(row.wash_enabled);
    return Boolean(unscheduledScanEvidence(row.customer_id,el.type.value));
  }

  function selectionReceptionException(row){
    return row?.key ? state.washReceptionExceptions[row.key] || null : null;
  }

  function selectionExceptionReady(row){
    const ex=selectionReceptionException(row);
    return Boolean(ex&&String(ex.reason||"").trim());
  }

  function correctionKeepsLegacySelection(){
    if(!state.editingWash)return false;
    const original=(state.editingWash.originalSelectionKeys||[]).slice().sort();
    const current=state.selectedCustomers.slice().sort();
    return state.editingWash.originalWashType===el.type.value
      && original.length===current.length
      && original.every((key,index)=>key===current[index]);
  }

  function selectionAllowedForCurrentMode(row){
    if(selectionScanReady(row)||selectionExceptionReady(row))return true;
    return correctionKeepsLegacySelection()
      && state.selectedCustomers.includes(row.key);
  }

  function selectionInfo(key){
    const value=String(key||"");
    if(value.startsWith("S:")){
      const row=boardCustomers().find(item=>scheduleSelectionKey(item)===value);
      if(!row)return null;
      return {
        key:value,
        customer_id:row.customer_id,
        customer_name:row.customer_name,
        customer_code:row.customer_code,
        schedule_product_id:row.schedule_product_id,
        scheduled_for_date:row.scheduled_for_date,
        scheduled_weekday_name:row.scheduled_weekday_name,
        day_relation:row.day_relation,
        route_color:row.route_color||"",
        route_display_name:row.route_display_name||"",
        planned_trolley_quantity:Number(row.planned_trolley_quantity||0),
        scan_contents_count:Number(row.scan_contents_count||0),
        scan_empty_count:Number(row.scan_empty_count||0),
        contents_scans:Array.isArray(row.contents_scans)?row.contents_scans:[],
        wash_enabled:Boolean(row.wash_enabled),
        wash_gate_status:row.wash_gate_status||"WAITING_SCAN",
        no_trolley_eligible:Boolean(row.no_trolley_eligible),
        trolley_reception_expected:row.trolley_reception_expected!==false,
        reception_evidence_source:row.reception_evidence_source||"NONE",
        status:row.status
      };
    }
    if(value.startsWith("U:")){
      const customer=customerById(value.slice(2));
      if(!customer)return null;
      return {
        key:value,
        customer_id:customer.customer_id,
        customer_name:customer.customer_name,
        customer_code:customer.customer_code,
        schedule_product_id:null,
        scheduled_for_date:null,
        scheduled_weekday_name:null,
        day_relation:"UNSCHEDULED",
        route_color:"",
        route_display_name:"",
        planned_trolley_quantity:0,
        scan_contents_count:Number(unscheduledScanEvidence(customer.customer_id,el.type.value)?.contents_count||0),
        scan_empty_count:0,
        contents_scans:[],
        wash_enabled:Boolean(unscheduledScanEvidence(customer.customer_id,el.type.value)),
        wash_gate_status:unscheduledScanEvidence(customer.customer_id,el.type.value)?"READY_TO_WASH":"WAITING_SCAN",
        no_trolley_eligible:false,
        trolley_reception_expected:true,
        reception_evidence_source:unscheduledScanEvidence(customer.customer_id,el.type.value)?"PHYSICAL_TROLLEY":"NONE",
        status:"PENDING"
      };
    }
    return null;
  }

  function operatorStaff(){
    const actual=Array.isArray(state.staffWork?.staff)?state.staffWork.staff:[];
    if(actual.length)return actual
      .filter(row=>row.attendance_status!=="ABSENT"&&row.attendance_status!=="MOVED")
      .map(row=>({
        staff_id:row.staff_id,
        display_name:row.display_name,
        work_mode:row.work_mode||"CLOTHES",
        attendance_status:row.attendance_status||"PLANNED"
      }));
    return plannedStaff().map(row=>({
      staff_id:row.staff_id,
      display_name:row.display_name,
      work_mode:"CLOTHES",
      attendance_status:"PLANNED"
    }));
  }

  function renderHeader(){
    const c=state.washing||state.sorting||{};
    el.businessDate.textContent=fmtDate(c.business_date);
    el.sidebarDate.textContent=fmtDate(c.business_date);
    const clock=c.operational_clock||{};
    if(el.businessDateStatus){
      el.businessDateStatus.textContent=clock.overnight_continuation
        ? `Evening continuation after midnight · counted as ${fmtDate(c.business_date)}`
        : "";
      el.businessDateStatus.classList.toggle("overnight",Boolean(clock.overnight_continuation));
    }
    el.rosterSource.textContent=c.roster?`Published v${c.roster.version_number}`:"No published roster";
    el.plannedCount.textContent=Number(c.planned_staff_count||0);
    el.sessionName.textContent=c.operator?.display_name||"Sorting Area";
  }

  function renderReference(){
    const staff=operatorStaff();
    const oldOperator=el.operator.value;
    el.operator.innerHTML='<option value="">Select your name…</option>'+staff
      .map(s=>`<option value="${esc(s.staff_id)}">${esc(s.display_name)} — ${esc(s.work_mode==="MOP"?"MOP":"Clothes")}${s.attendance_status==="AUTO_ABSENT"?" · Auto absent":""}</option>`).join("");
    if(staff.some(s=>s.staff_id===oldOperator)) el.operator.value=oldOperator;
    el.operator.disabled=false;

    const oldWasher=el.washer.value;
    el.washer.innerHTML='<option value="">Select washer…</option>'+washers()
      .map(w=>`<option value="${esc(w.washer_id)}">${esc(w.washer_name)}</option>`).join("");
    if(washers().some(w=>w.washer_id===oldWasher)) el.washer.value=oldWasher;
    renderCapacity();
    syncOperatorForType();
    if(el.operator.value && !el.type.value)prefillTypeForOperator(true);
  }

  function syncOperatorForType(){
    const type=el.type.value;
    const staff=operatorStaff();
    const mop=staff.find(row=>row.work_mode==="MOP");
    if(type==="MOP"&&mop){
      el.operator.value=mop.staff_id;
      return;
    }
    if(type==="CLOTHES"&&mop&&el.operator.value===mop.staff_id){
      el.operator.value="";
    }
  }

  function prefillTypeForOperator(force=false){
    const staffId=el.operator.value;
    if(!staffId){
      if(state.typeAutofilledByStaff){
        el.type.value="";
        state.typeAutofilledByStaff=false;
        state.selectedCustomers=[];
        renderSelected();
        renderToday();
      }
      return;
    }

    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId)
      || operatorStaff().find(item=>item.staff_id===staffId);
    if(!row)return;

    const suggested=row.work_mode==="MOP"?"MOP":"CLOTHES";

    // Do not overwrite a Type that the operator deliberately selected.
    // Only blank or previously auto-filled values may follow a staff change.
    if(!force && el.type.value && !state.typeAutofilledByStaff)return;

    if(el.type.value!==suggested){
      el.type.value=suggested;
      state.selectedCustomers=[];
      state.washReceptionExceptions={};
      renderSelected();
      renderToday();
    }

    state.typeAutofilledByStaff=true;
  }

  function renderCapacity(prefillWeight=false){
    const w=washers().find(x=>x.washer_id===el.washer.value);
    if(!w){el.washerCapacity.textContent="Select a washer to see capacity.";el.weight.removeAttribute("max");return;}
    el.washerCapacity.textContent=`${w.washer_code} capacity: ${Number(w.capacity_kg).toFixed(0)} KG`;
    el.weight.max=String(w.capacity_kg);
    if(prefillWeight) el.weight.value=String(Number(w.capacity_kg));
  }

  function renderSelected(){
    const rows=state.selectedCustomers.map(selectionInfo).filter(Boolean);
    el.selectedCustomers.innerHTML=rows.map(row=>{
      const color=row.route_color||"";
      const fg=routeTextColor(color);
      const style=color?` style="--chip-bg:${esc(color)};--chip-fg:${fg}"`:"";
      const schedule=row.scheduled_for_date?shortDayDate(row.scheduled_for_date):"Off schedule";
      const scanReady=selectionScanReady(row);
      const exceptionReady=selectionExceptionReady(row);
      return `<span class="sorting-customer-chip${color?" route-chip":""}${scanReady?" scan-ready":""}${exceptionReady?" exception-ready":""}"${style}>
        ${esc(row.customer_name)} · ${esc(schedule)}${scanReady?" · RECEPTION OK":exceptionReady?" · EXCEPTION":""}
        <button type="button" data-remove-customer="${esc(row.key)}">×</button>
      </span>`;
    }).join("");
    if(!el.type.value){
      el.customerButton.disabled=true;
      el.customerButton.textContent="Select type first";
      el.customerButton.title="";
    }else{
      el.customerButton.disabled=false;
      const names=rows.map(row=>row.customer_name).join(", ");
      el.customerButton.textContent=rows.length?names:"Select customers…";
      el.customerButton.title=rows.length?names:"Only customers identified by Trolley Reception CONTENTS scan can be used for a new wash.";
    }

    const legacyCorrection=correctionKeepsLegacySelection();
    const gateReady=rows.length>0&&rows.every(row=>selectionScanReady(row)||legacyCorrection);
    if(!state.busy)el.saveWash.disabled=!gateReady;
    el.saveWash.title=gateReady
      ? ""
      : rows.length
        ? "Washing is locked until every selected customer has a CONTENTS trolley scan."
        : "Select a scanned customer before saving Washing.";
  }

  function renderToday(){
    const selectedType=String(el.type.value||"").toUpperCase();
    const visibleTypes=selectedType==="MOP"
      ? ["MOP"]
      : ["CLOTHES","OTHERS"].includes(selectedType)
        ? ["CLOTHES"]
        : ["CLOTHES","MOP"];
    const rows=boardCustomers().filter(r=>visibleTypes.includes(r.product_code));
    const todayRows=rows.filter(r=>r.day_relation==="TODAY");
    const tomorrowRows=rows.filter(r=>r.day_relation==="TOMORROW");
    const todayDone=todayRows.filter(r=>r.status==="WASHED").length;
    const todayTotal=todayRows.length;
    const todayPct=todayTotal?Math.round(todayDone/todayTotal*100):0;
    const todayComplete=todayTotal>0&&todayDone===todayTotal;
    const tomorrowStarted=tomorrowRows.some(r=>r.status==="WASHED");
    const showTomorrow=tomorrowStarted||todayComplete;

    el.todayType.textContent=showTomorrow?"Today + next":"Today";
    el.todayProgress.innerHTML=`<div class="sorting-progress-copy"><span>${todayDone} of ${todayTotal} completed today</span><strong>${todayPct}%</strong></div>
      <div class="sorting-progress-track"><div class="sorting-progress-fill" style="width:${todayPct}%"></div></div>`;

    if(!todayRows.length&&!tomorrowRows.length){
      el.todayList.innerHTML='<div class="sorting-today-empty">No CLOTHES or MOP customers are scheduled.</div>';
      return;
    }

    const renderDay=(dayRows,relation)=>{
      if(!dayRows.length)return "";
      const date=dayRows[0].scheduled_for_date;
      const dayDone=dayRows.filter(r=>r.status==="WASHED").length;
      const relationLabel=relation==="TODAY"?"TODAY":"WORK AHEAD";
      return `<section class="sorting-board-day ${relation.toLowerCase()}">
        <div class="sorting-board-day-header">
          <div><strong>${esc(fullDayDate(date))}</strong><span>${relationLabel}</span></div>
          <b>${dayDone}/${dayRows.length}</b>
        </div>
        ${visibleTypes.map(type=>{
          const group=dayRows.filter(r=>r.product_code===type);
          if(!group.length)return "";
          const groupDone=group.filter(r=>r.status==="WASHED").length;
          return `<div class="sorting-today-group${el.type.value===type?" selected-type":""}">
            <div class="sorting-today-group-title"><strong>${type}</strong><span>${groupDone}/${group.length}</span></div>
            ${group.map(r=>{
              const routeColor=r.route_color||"";
              const routeFg=routeTextColor(routeColor);
              const routeStyle=routeColor?` style="--route-bg:${esc(routeColor)};--route-fg:${routeFg}"`:"";
              const trolleyQty=Number(r.planned_trolley_quantity||0);
              const washed=r.status==="WASHED";
              const scanCount=Number(r.scan_contents_count||0);
              const emptyCount=Number(r.scan_empty_count||0);
              const scanReady=Boolean(r.wash_enabled);
              const otherReceipt=otherProductReceipt(r);
              const emptyOnly=!scanReady&&emptyCount>0;
              const washedNoScan=washed&&!scanReady;
              let gateLabel=washed
                ? `${scanReady?"SCAN OK · ":"NO CONTENTS SCAN · "}Washed${r.last_wash_code?` · ${esc(r.last_wash_code)}`:""}`
                : scanReady
                  ? `SCAN OK · READY TO WASH · ${scanCount} trolley${scanCount===1?"":"s"}`
                  : emptyOnly
                    ? "EMPTY ONLY · WASHING LOCKED"
                    : "WAITING TROLLEY SCAN";
              if(!washed&&!scanReady&&otherReceipt){
                gateLabel=`RECEIVED AS ${esc(intakeProductCodes(otherReceipt).join(" + "))} Â· FIX IN INTAKE`;
              }
              const dotClass=washed?"done":scanReady?"scan-ready":otherReceipt?"other-service":emptyOnly?"empty-only":"pending";
              return `<div class="sorting-today-item${routeColor?" route-colored":""}${washed?" is-washed":""}${scanReady?" wash-scan-ready":""}${otherReceipt?" wash-other-service":""}${emptyOnly?" wash-empty-only":""}${washedNoScan?" wash-no-scan":""}"${routeStyle}
                title="${esc(r.route_display_name||r.route_code||"No route color")}">
                <span class="sorting-today-status ${dotClass}"></span>
                <div class="sorting-today-main">
                  <strong>${esc(r.customer_name)}</strong>
                  <span>${gateLabel} · ${esc(shortDayDate(r.scheduled_for_date))}${r.route_display_name?` · ${esc(r.route_display_name)}`:""}</span>
                </div>
                <span class="sorting-today-trolleys">${trolleyQty} ${trolleyQty===1?"Trolley":"Trolleys"}</span>
              </div>`;
            }).join("")}
          </div>`;
        }).join("")}
      </section>`;
    };

    el.todayList.innerHTML=renderDay(todayRows,"TODAY")+(showTomorrow?renderDay(tomorrowRows,"TOMORROW"):"");
  }

  function renderRecentWashes(){
    const rows=Array.isArray(state.washSearchResults)
      ? state.washSearchResults
      : Array.isArray(state.washing?.recent_washes)?state.washing.recent_washes:[];
    const today=String(state.washing?.business_date||"").slice(0,10);
    el.recentWashes.innerHTML=rows.length?rows.map(w=>{
      const cs=Array.isArray(w.customers)?w.customers:[];
      const cancelled=w.status==="CANCELLED";
      const customerHtml=cs.map(c=>{
        const color=c.route_color||"";
        const fg=routeTextColor(color);
        const style=color?` style="--wash-customer-bg:${esc(color)};--wash-customer-fg:${fg}"`:"";
        return `<span class="sorting-wash-customer${color?" colored":""}"${style}>
          <b>${esc(c.customer_name)}</b>
          <small>${esc(c.trace_code)}</small>
        </span>`;
      }).join("");
      const scheduledHtml=cs.map(c=>{
        const relation=c.schedule_relation==="EARLY"?"Ahead":c.schedule_relation==="LATE"?"Late":c.schedule_relation==="TODAY"?"Today":"Off schedule";
        return `<span class="sorting-scheduled-line"><b>${esc(c.scheduled_for_date?shortDayDate(c.scheduled_for_date):"—")}</b><small>${esc(relation)}</small></span>`;
      }).join("");
      const mode=w.entry_mode==="LATE_ENTRY"
        ? '<span class="sorting-entry-badge late">Late entry</span>'
        : w.entry_mode==="CORRECTION"
          ? '<span class="sorting-entry-badge correction">Correction</span>'
          : "";
      const status=cancelled?'<span class="sorting-entry-badge cancelled">Cancelled</span>':"";
      const linkage=w.replaces_wash_code
        ? `<small class="sorting-wash-link">Corrects ${esc(w.replaces_wash_code)}</small>`
        : w.replacement_wash_code
          ? `<small class="sorting-wash-link">Replaced by ${esc(w.replacement_wash_code)}</small>`
          : "";
      const receptionException=Number(w.reception_exception_count||0)>0
        ? `<span class="sorting-wash-reception-exception-badge" title="${esc((w.reception_exceptions||[]).map(x=>x.reason||"").join(" · "))}">RECEPTION EXCEPTION · ${Number(w.reception_exception_count||0)}</span>`
        : "";
      const canChange=!cancelled&&String(w.business_date).slice(0,10)===today;
      const actions=canChange?`
        <div class="sorting-wash-actions">
          <button type="button" class="sorting-mini-button" data-edit-wash="${esc(w.wash_run_id)}">Edit</button>
          <button type="button" class="sorting-mini-button danger" data-cancel-wash="${esc(w.wash_run_id)}">Cancel</button>
        </div>`:"—";
      return `<tr class="${cancelled?"sorting-wash-cancelled":""}">
        <td class="sorting-washed-date">${esc(shortDayDate(w.business_date))}</td>
        <td><span class="sorting-wash-code">${esc(w.wash_code)}</span>${mode}${status}${linkage}${receptionException}</td>
        <td>${esc(w.washer_code)}</td>
        <td><div class="sorting-customer-stack">${customerHtml}</div></td>
        <td><div class="sorting-scheduled-stack">${scheduledHtml}</div></td>
        <td>${esc(fmtTime(w.started_at))}</td>
        <td>${Number(w.total_weight_kg||0).toFixed(1)} KG</td>
        <td>${esc(w.operator_name)}</td>
        <td>${esc(w.wash_type)}</td>
        <td>${actions}</td>
      </tr>`;
    }).join(""):'<tr><td colspan="10" class="sorting-today-empty">No washing loads recorded in the recent 3-day window.</td></tr>';
  }

  function renderCustomerOptions(){
    const type=el.type.value,q=el.customerSearch.value.trim().toLowerCase();
    const showAll=Boolean(state.washCustomerShowAll);
    const scheduledBase=type==="OTHERS"?[]:boardCustomers().filter(row=>row.product_code===type);
    const readyOrSelected=(row)=>{
      const key=scheduleSelectionKey(row);
      return showAll
        || state.draftCustomers.includes(key)
        || Boolean(row.wash_enabled)
        || Boolean(row.no_trolley_eligible)
        || selectionExceptionReady({...row,key});
    };
    const scheduled=scheduledBase.filter(readyOrSelected);
    const scheduledIds=new Set(scheduledBase.map(row=>row.customer_id));
    const match=(row)=>!q||`${row.customer_name} ${row.customer_code||""}`.toLowerCase().includes(q);
    if(el.customerShowAll)el.customerShowAll.checked=showAll;

    const scheduledOption=(row)=>{
      const key=scheduleSelectionKey(row);
      const checked=state.draftCustomers.includes(key);
      const color=row.route_color||"";
      const dot=color?`<span class="sorting-picker-route-dot" style="background:${esc(color)}"></span>`:"";
      const washCount=Number(row.wash_count||0);
      const scanCount=Number(row.scan_contents_count||0);
      const emptyCount=Number(row.scan_empty_count||0);
      const scanReady=Boolean(row.wash_enabled);
      const otherReceipt=otherProductReceipt(row);
      const legacyAllowed=Boolean(state.editingWash
        && (state.editingWash.originalSelectionKeys||[]).includes(key)
        && state.editingWash.originalWashType===type);
      const exceptionReady=selectionExceptionReady({...row,key});
      const enabled=scanReady||legacyAllowed||exceptionReady;
      let badge=scanReady
        ? `RECEPTION OK · ${scanCount}`
        : exceptionReady
          ? "EXCEPTION READY"
          : row.no_trolley_eligible
            ? "NO TROLLEY · RECEIVE"
            : emptyCount>0
              ? "EMPTY · LOCKED"
              : legacyAllowed
                ? "LEGACY CORRECTION"
                : "RECEPTION REQUIRED";
      const washNote=washCount>0
        ? ` · already washed ${washCount} time${washCount===1?"":"s"}${row.last_wash_code?` · last ${row.last_wash_code}`:""}`
        : "";
      if(!scanReady&&!exceptionReady&&!row.no_trolley_eligible&&otherReceipt){
        badge=`RECEIVED AS ${intakeProductCodes(otherReceipt).join(" + ")}`;
      }
      let gateNote=scanReady
        ? ` · Reception evidence confirmed`
        : exceptionReady
          ? ` · controlled reception exception will be saved with this Wash ID`
          : legacyAllowed
            ? " · existing Wash ID correction"
            : row.no_trolley_eligible
              ? " · published schedule has no trolley; record contents arrival here"
              : emptyCount>0
                ? " · empty trolley does not unlock Washing"
                : " · trolley contents Reception is missing";
      const noTrolleyAction=!scanReady&&!exceptionReady&&row.no_trolley_eligible
        ? `<button type="button" class="sorting-picker-inline-action" data-wash-no-trolley="${esc(key)}">Receive without trolley</button>`
        : "";
      if(!scanReady&&!exceptionReady&&!row.no_trolley_eligible&&otherReceipt){
        gateNote=" · receipt exists under another product; edit the trolley receipt before washing";
      }
      return `<div class="sorting-customer-option-wrap"><label class="sorting-customer-option${washCount>0?" already-washed":""}${enabled?" scan-enabled":" scan-locked"}">
        <input type="checkbox" value="${esc(key)}"${checked?" checked":""}${enabled?"":" disabled"}>
        ${dot}
        <span class="sorting-customer-option-copy">
          <strong>${esc(row.customer_name)}</strong>
          <span>${esc(shortDayDate(row.scheduled_for_date))}${row.route_display_name?` · ${esc(row.route_display_name)}`:""}${esc(washNote)}${esc(gateNote)}</span>
        </span>
        <span class="sorting-customer-option-badge">${esc(badge)}</span>
      </label>${noTrolleyAction}</div>`;
    };

    const unscheduledOption=(customer)=>{
      const key=unscheduledSelectionKey(customer);
      const evidence=unscheduledScanEvidence(customer.customer_id,type);
      const legacyAllowed=Boolean(state.editingWash
        && (state.editingWash.originalSelectionKeys||[]).includes(key)
        && state.editingWash.originalWashType===type);
      const row={...customer,key,schedule_product_id:null,scheduled_for_date:null};
      const exceptionReady=selectionExceptionReady(row);
      const enabled=Boolean(evidence)||legacyAllowed||exceptionReady;
      const badge=evidence?`RECEPTION OK · ${Number(evidence.contents_count||0)}`:exceptionReady?"EXCEPTION READY":legacyAllowed?"LEGACY CORRECTION":"RECEPTION REQUIRED";
      return `<label class="sorting-customer-option${enabled?" scan-enabled":" scan-locked"}">
        <input type="checkbox" value="${esc(key)}"${state.draftCustomers.includes(key)?" checked":""}${enabled?"":" disabled"}>
        <span class="sorting-customer-option-copy"><strong>${esc(customer.customer_name)}</strong><span>${esc(customer.customer_code||"")}${evidence?" · Reception evidence confirmed":exceptionReady?" · controlled reception exception staged":" · Reception evidence missing"}</span></span>
        <span class="sorting-customer-option-badge">${esc(badge)}</span>
      </label>`;
    };

    let html="";
    if(type!=="OTHERS"){
      const today=scheduled.filter(row=>row.day_relation==="TODAY"&&match(row));
      const tomorrow=scheduled.filter(row=>row.day_relation==="TOMORROW"&&match(row));
      const hiddenCount=showAll?0:scheduledBase.filter(row=>!readyOrSelected(row)&&match(row)).length;
      html+='<div class="sorting-customer-group-title">Scheduled today</div>';
      html+=today.length?today.map(scheduledOption).join(""):'<div class="sorting-today-empty">No scheduled customer matches today.</div>';
      html+='<div class="sorting-customer-group-title sorting-next-day-title">Tomorrow / work ahead</div>';
      html+=tomorrow.length?tomorrow.map(scheduledOption).join(""):'<div class="sorting-today-empty">No tomorrow customer matches.</div>';
      if(hiddenCount){
        html+=`<div class="sorting-customer-filter-note">${hiddenCount} scheduled customer${hiddenCount===1?" is":"s are"} hidden until Reception scan or no-trolley confirmation. Use "Show all scheduled customers" to view the full list.</div>`;
      }
    }
    html+='<div class="sorting-customer-group-title">Other active customers</div>';
    const others=showAll||type==="OTHERS"
      ? allCustomers().filter(c=>!scheduledIds.has(c.customer_id)&&match(c))
      : allCustomers().filter(c=>{
        const key=unscheduledSelectionKey(c);
        return !scheduledIds.has(c.customer_id)
          && match(c)
          && (state.draftCustomers.includes(key)||Boolean(unscheduledScanEvidence(c.customer_id,type))||selectionExceptionReady({...c,key,schedule_product_id:null,scheduled_for_date:null}));
      });
    html+=others.length?others.map(unscheduledOption).join(""):'<div class="sorting-today-empty">No other customer matches.</div>';
    el.customerOptions.innerHTML=html;
    el.customerCount.textContent=`${state.draftCustomers.length} selected`;
  }

  function openCustomerDialog(){
    if(!el.type.value)return;
    state.draftCustomers=[...state.selectedCustomers];el.customerSearch.value="";
    state.washCustomerShowAll=false;
    if(el.customerShowAll)el.customerShowAll.checked=false;
    el.dialogHint.textContent=el.type.value==="OTHERS"
      ?"Normal flow requires Reception evidence. If Reception was genuinely missed, use the controlled Reception exception below."
      :"Today and tomorrow are separate schedule choices. Use normal Reception evidence whenever possible; no-trolley customers can be confirmed here, and genuine missed Reception can use a reasoned exception.";
    renderCustomerOptions();el.dialog.showModal();
  }


  function washExceptionCandidates(){
    const type=el.type.value;
    const scheduled=type==="OTHERS"?[]:boardCustomers().filter(row=>row.product_code===type).map(row=>({
      ...selectionInfo(scheduleSelectionKey(row)),
      key:scheduleSelectionKey(row)
    }));
    const scheduledIds=new Set(scheduled.map(row=>row.customer_id));
    const others=allCustomers().filter(c=>!scheduledIds.has(c.customer_id)).map(c=>selectionInfo(unscheduledSelectionKey(c))).filter(Boolean);
    return [...scheduled,...others].filter(row=>!selectionScanReady(row));
  }

  function renderWashReceptionExceptionOptions(){
    const rows=washExceptionCandidates();
    const selected=new Set(state.draftWashReceptionExceptionKeys||[]);
    el.washReceptionExceptionOptions.innerHTML=rows.length?rows.map(row=>{
      const noTrolley=row.no_trolley_eligible?'<span class="sorting-exception-no-trolley">NO TROLLEY</span>':'';
      const scheduled=row.scheduled_for_date?fullDayDate(row.scheduled_for_date):'Off schedule';
      return `<label class="sorting-customer-option sorting-exception-option">
        <input type="checkbox" data-wash-exception-key="${esc(row.key)}"${selected.has(row.key)?' checked':''}>
        <span class="sorting-customer-option-copy"><strong>${esc(row.customer_name)}</strong><span>${esc(scheduled)} · ${esc(el.type.value)}${row.no_trolley_eligible?' · published schedule has no trolley':''}</span></span>
        ${noTrolley}
      </label>`;
    }).join(''):'<div class="sorting-empty">No customers are currently waiting for Reception evidence.</div>';
    el.washReceptionExceptionCount.textContent=`${selected.size} selected`;
  }

  function openWashReceptionExceptionDialog(){
    if(!el.type.value)return setMessage('Select the wash type first.','warning');
    state.draftWashReceptionExceptionKeys=[];
    el.washReceptionExceptionReason.value='';
    el.washReceptionExceptionMessage.textContent='';
    renderWashReceptionExceptionOptions();
    el.washReceptionExceptionDialog.showModal();
  }

  function useWashReceptionException(){
    const reason=el.washReceptionExceptionReason.value.trim();
    if(!state.draftWashReceptionExceptionKeys.length){el.washReceptionExceptionMessage.textContent='Select at least one customer.';return;}
    if(!reason){el.washReceptionExceptionMessage.textContent='A reason is required for this exception.';el.washReceptionExceptionReason.focus();return;}
    state.draftWashReceptionExceptionKeys.forEach(key=>{
      const row=selectionInfo(key);if(!row)return;
      Object.keys(state.washReceptionExceptions).forEach(otherKey=>{
        const other=selectionInfo(otherKey);if(other&&other.customer_id===row.customer_id&&otherKey!==key)delete state.washReceptionExceptions[otherKey];
      });
      state.washReceptionExceptions[key]={reason};
      state.draftCustomers=state.draftCustomers.filter(otherKey=>{
        const other=selectionInfo(otherKey);return !other||other.customer_id!==row.customer_id;
      });
      if(!state.draftCustomers.includes(key))state.draftCustomers.push(key);
    });
    el.washReceptionExceptionDialog.close();
    renderCustomerOptions();
    setMessage('Reception exception staged. It will be recorded only when the Washing load is saved.','warning');
  }

  function washingOperatorForNoTrolley(){
    const staffId=el.operator.value;
    if(!staffId)return null;
    return operatorStaff().find(row=>row.staff_id===staffId)||null;
  }

  async function receiveNoTrolleyFromWashing(key,button){
    const row=selectionInfo(key),operator=washingOperatorForNoTrolley();
    if(!row?.no_trolley_eligible)return setMessage('This customer expects normal trolley Reception.','error');
    if(!operator)return setMessage('Select your name in Washing first.','warning');
    if(button){button.disabled=true;button.textContent='Recording…';}
    try{
      const result=await rpc('record_sorting_non_trolley_arrival',{
        p_shift_code:state.shift,
        p_customer_id:row.customer_id,
        p_scheduled_for_date:row.scheduled_for_date,
        p_product_code:el.type.value==='MOP'?'MOP':'CLOTHES',
        p_operator_staff_id:operator.staff_id,
        p_notes:'Recorded from Washing customer selector — published schedule has no trolley.'
      });
      await loadWashing();
      state.draftCustomers=[...new Set([...state.draftCustomers,key])];
      renderCustomerOptions();
      setMessage(result?.message||`${row.customer_name} received without trolley. Washing is unlocked.`,'success');
    }catch(error){console.error(error);setMessage(friendly(error),'error');renderCustomerOptions();}
  }

  function renderEditState(){
    const editing=Boolean(state.editingWash);
    const late=Boolean(state.lateEntryMode);
    el.editBanner.hidden=!editing&&!late;
    el.cancelEdit.hidden=!editing&&!late;
    el.missedWash.disabled=editing||late;
    el.saveWash.textContent=editing?"Save correction":late?"Save late entry":"Save washing";
    if(editing){
      el.editTitle.textContent=`Correcting ${state.editingWash.wash_code}`;
      el.editBanner.querySelector("span").textContent="The original Wash ID remains in history as Cancelled.";
    }else if(late){
      el.editTitle.textContent="Late entry — wash already happened";
      el.editBanner.querySelector("span").textContent="Use only when the physical wash was missed from the system. Enter the real washer start time.";
    }
  }

  function ensureWashEditDialog(){
    let dialog=document.getElementById("sortingWashEditDialog");
    if(dialog)return dialog;
    document.body.insertAdjacentHTML("beforeend",`<dialog id="sortingWashEditDialog" class="sorting-dialog sorting-wash-edit-dialog">
      <section class="sorting-dialog-card sorting-wash-edit-modal-card">
        <header class="sorting-dialog-header">
          <div>
            <p class="sorting-section-eyebrow">Correction with history</p>
            <h2 id="sortingWashEditDialogTitle">Edit washing load</h2>
            <p>The original Wash ID stays in history; saving creates the corrected trace.</p>
          </div>
          <button type="button" class="sorting-dialog-close" data-close-wash-edit-modal aria-label="Close">x</button>
        </header>
        <div id="sortingWashEditFormHost" class="sorting-wash-edit-form-host"></div>
      </section>
    </dialog>`);
    dialog=document.getElementById("sortingWashEditDialog");
    dialog.addEventListener("click",e=>{
      if(e.target.closest("[data-close-wash-edit-modal]")){
        clearWash(true);
        setMessage("Wash correction cancelled. No database change was made.");
      }
    });
    dialog.addEventListener("cancel",e=>{
      e.preventDefault();
      clearWash(true);
      setMessage("Wash correction cancelled. No database change was made.");
    });
    return dialog;
  }

  function returnWashFormHome(){
    if(!el.washForm||!washFormHome.parent||el.washForm.parentNode===washFormHome.parent)return;
    washFormHome.parent.insertBefore(el.washForm,washFormHome.next);
  }

  function closeWashEditModal(){
    const dialog=document.getElementById("sortingWashEditDialog");
    if(dialog?.open)dialog.close();
    returnWashFormHome();
  }

  function openWashEditModal(wash){
    const dialog=ensureWashEditDialog();
    const host=document.getElementById("sortingWashEditFormHost");
    document.getElementById("sortingWashEditDialogTitle").textContent=`Edit ${wash.wash_code}`;
    if(host&&el.washForm.parentNode!==host)host.appendChild(el.washForm);
    if(!dialog.open)dialog.showModal();
  }

  function clearWash(keepOperator=true){
    const op=keepOperator?el.operator.value:"";
    el.washer.value="";el.type.value="";el.weight.value="";el.start.value="";el.notes.value="";
    state.typeAutofilledByStaff=false;
    state.selectedCustomers=[];state.washReceptionExceptions={};state.editingWash=null;state.lateEntryMode=false;if(keepOperator)el.operator.value=op;
    closeWashEditModal();
    renderCapacity();renderSelected();renderToday();renderEditState();
    if(keepOperator&&op)prefillTypeForOperator(true);
  }

  async function loadWashing(){
    try{state.washing=await rpc("get_sorting_washing_context_v4",{p_shift_code:state.shift});}
    catch(error){console.warn("Washing context V4 not available; using V3 until Migration 031 is applied.",error);state.washing=await rpc("get_sorting_washing_context_v3",{p_shift_code:state.shift});}
    let board;
    try{board=await rpc("get_sorting_customer_board_v4",{p_shift_code:state.shift});}
    catch(error){console.warn("Washing board V4 not available; using V3 until Migration 030 is applied.",error);board=await rpc("get_sorting_customer_board_v3",{p_shift_code:state.shift});}
    if(state.washing){
      state.washing.today_customers=Array.isArray(board?.customers)?board.customers:[];
      state.washing.unscheduled_scan_customers=Array.isArray(board?.unscheduled_scan_customers)?board.unscheduled_scan_customers:[];
      state.washing.wash_scan_gate_required=Boolean(board?.wash_scan_gate_required);
    }
    renderHeader();renderReference();renderSelected();renderToday();renderRecentWashes();
  }

  function recentWashById(id){
    return (state.washing?.recent_washes||[]).find(row=>row.wash_run_id===id);
  }

  function selectionKeyFromRecent(customer){
    if(customer.schedule_product_id&&customer.scheduled_for_date){
      return `S:${customer.schedule_product_id}:${String(customer.scheduled_for_date).slice(0,10)}`;
    }
    return `U:${customer.customer_id}`;
  }

  function beginEditWash(id){
    const wash=recentWashById(id);
    if(!wash||wash.status!=="RECORDED")return setMessage("This wash is no longer available for correction.","error");
    if(String(wash.business_date).slice(0,10)!==String(state.washing?.business_date||"").slice(0,10)){
      return setMessage("Only today's washes can be corrected from the Sorting workstation.","error");
    }
    const originalSelectionKeys=(wash.customers||[]).map(selectionKeyFromRecent);
    state.editingWash={
      wash_run_id:wash.wash_run_id,
      wash_code:wash.wash_code,
      row_version:Number(wash.row_version),
      originalSelectionKeys:[...originalSelectionKeys],
      originalWashType:wash.wash_type||""
    };
    el.operator.value=wash.operator_staff_id||"";
    el.washer.value=wash.washer_id||"";
    el.type.value=wash.wash_type||"";
    state.typeAutofilledByStaff=false;
    el.weight.value=String(Number(wash.total_weight_kg||0));
    el.start.value=fmtTime(wash.started_at);
    el.notes.value=wash.notes||"";
    state.selectedCustomers=[...originalSelectionKeys];
    renderCapacity();renderSelected();renderToday();syncOperatorForType();renderEditState();
    openWashEditModal(wash);
    setMessage(`Editing ${wash.wash_code}. Saving creates a replacement Wash ID; the original stays in history.`,"warning");
  }

  async function cancelWashRecord(id){
    const wash=recentWashById(id);
    if(!wash||wash.status!=="RECORDED")return;
    const reason=prompt(`Why should ${wash.wash_code} be cancelled?`);
    if(reason===null)return;
    if(!reason.trim())return setMessage("Cancellation reason is required.","error");
    try{
      setMessage(`Cancelling ${wash.wash_code}…`);
      const result=await rpc("cancel_sorting_wash_run",{
        p_wash_run_id:wash.wash_run_id,
        p_expected_row_version:Number(wash.row_version),
        p_reason:reason.trim()
      });
      if(state.editingWash?.wash_run_id===wash.wash_run_id)clearWash(true);
      await loadWashing();
      setMessage(result?.message||"Washing record cancelled.","success");
    }catch(error){console.error(error);setMessage(friendly(error),"error");}
  }

  function washPayload(){
    const washer=washers().find(w=>w.washer_id===el.washer.value),weight=Number(el.weight.value);
    if(!el.operator.value)throw new Error("Select your name.");
    const selectedOperator=(state.staffWork?.staff||[]).find(row=>row.staff_id===el.operator.value);
    if(selectedOperator?.attendance_status==="AUTO_ABSENT"){
      const accepted=confirm(`${selectedOperator.display_name} is currently marked Auto absent because no earlier activity was recorded. Continue only if this person is actually working now.`);
      if(!accepted)throw new Error("Select the correct staff member.");
    }
    if(!washer)throw new Error("Select the washer.");
    if(!el.type.value)throw new Error("Select the wash type.");
    if(!state.selectedCustomers.length)throw new Error("Choose at least one customer. A wash cannot be saved without a customer.");
    if(!el.start.value)throw new Error("Enter the washer start time.");
    if(!Number.isFinite(weight)||weight<=0)throw new Error("Enter a valid washed weight.");
    if(weight>Number(washer.capacity_kg))throw new Error(`Weight (${weight} KG) exceeds ${washer.washer_code} capacity (${Number(washer.capacity_kg).toFixed(0)} KG).`);
    const customerRows=state.selectedCustomers.map(selectionInfo).filter(Boolean);
    const legacyCorrection=correctionKeepsLegacySelection();
    const lockedRows=customerRows.filter(row=>!selectionScanReady(row)&&!selectionExceptionReady(row));
    if(lockedRows.length&&!legacyCorrection){
      throw new Error(`Washing locked: Reception evidence or a controlled exception is required for ${lockedRows.map(row=>row.customer_name).join(", ")}.`);
    }
    const receptionExceptions=customerRows.filter(row=>!selectionScanReady(row)&&selectionExceptionReady(row)).map(row=>({
      customer_id:row.customer_id,
      schedule_product_id:row.schedule_product_id,
      scheduled_for_date:row.scheduled_for_date,
      reason:String(selectionReceptionException(row)?.reason||"").trim()
    }));
    const selections=customerRows.map(row=>({
      customer_id:row.customer_id,
      schedule_product_id:row.schedule_product_id,
      scheduled_for_date:row.scheduled_for_date
    }));
    if(!selections.length)throw new Error("Selected customer data is no longer available. Reload and select the customers again.");
    const operator=(state.staffWork?.staff||[]).find(row=>row.staff_id===el.operator.value)
      || operatorStaff().find(row=>row.staff_id===el.operator.value)
      || null;
    return {washer,weight,selections,customerRows,operator,receptionExceptions};
  }

  function startLateEntryMode(){
    if(state.busy||state.editingWash)return;
    clearWash(true);
    state.lateEntryMode=true;
    renderEditState();
    if(el.rareActions)el.rareActions.open=false;
    el.washForm.scrollIntoView({behavior:"smooth",block:"start"});
    setMessage("Late entry mode. Use only for a wash that already happened but was not recorded.","warning");
  }

  async function searchWashHistory(){
    const query=el.historySearch.value.trim();
    if(!query){
      state.washSearchResults=null;
      renderRecentWashes();
      el.historyClearButton.hidden=true;
      el.historySearchStatus.textContent="Showing recent washes";
      return;
    }
    el.historySearchButton.disabled=true;
    el.historySearchStatus.textContent="Searching…";
    try{
      const result=await rpc("search_sorting_wash_history",{
        p_shift_code:state.shift,
        p_query:query,
        p_date_from:null,
        p_date_to:null,
        p_limit:100
      });
      state.washSearchResults=Array.isArray(result?.washes)?result.washes:[];
      renderRecentWashes();
      el.historyClearButton.hidden=false;
      el.historySearchStatus.textContent=`${Number(result?.result_count||0)} result${Number(result?.result_count||0)===1?"":"s"} · last 90 days`;
    }catch(error){
      console.error(error);setMessage(friendly(error),"error");
      el.historySearchStatus.textContent="Search failed";
    }finally{
      el.historySearchButton.disabled=false;
    }
  }

  function clearWashSearch(){
    state.washSearchResults=null;
    el.historySearch.value="";
    el.historyClearButton.hidden=true;
    el.historySearchStatus.textContent="Showing recent washes";
    renderRecentWashes();
  }


  function estimatedCustomerWeightAllocations(totalWeight,rows){
    const count=rows.length;
    if(!count)return [];
    const totalCents=Math.round(Number(totalWeight||0)*100);
    const base=Math.floor(totalCents/count);
    const remainder=totalCents%count;
    return rows.map((row,index)=>({
      ...row,
      estimated_allocated_weight_kg:(base+(index<remainder?1:0))/100,
      weight_allocation_method:count===1?"FULL_LOAD":"EQUAL_SPLIT_ESTIMATE"
    }));
  }

  function customerScheduleConfirmMeta(row){
    const scheduled=String(row.scheduled_for_date||"").slice(0,10);
    const business=String(state.washing?.business_date||"").slice(0,10);
    const sameCustomerDates=[...new Set(
      boardCustomers()
        .filter(item=>
          item.customer_id===row.customer_id
          && item.product_code===row.product_code
          && item.scheduled_for_date
        )
        .map(item=>String(item.scheduled_for_date).slice(0,10))
    )];
    const repeatedAcrossDays=sameCustomerDates.length>1;

    let relation="OFF SCHEDULE";
    let relationClass="off";
    if(scheduled&&business){
      if(scheduled===business){relation="TODAY";relationClass="today";}
      else if(scheduled>business){relation="WORK AHEAD";relationClass="ahead";}
      else{relation="LATE SCHEDULE";relationClass="late";}
    }

    return {scheduled,business,repeatedAcrossDays,relation,relationClass};
  }

  function confirmCustomerHtml(row,index,total){
    const color=row.route_color||"";
    const fg=routeTextColor(color);
    const style=color?` style="--confirm-route-bg:${esc(color)};--confirm-route-fg:${fg}"`:"";
    const washCount=Number(row.wash_count||0);
    const meta=customerScheduleConfirmMeta(row);
    const schedule=meta.scheduled?shortDayDate(meta.scheduled):"OFF SCHEDULE";
    const repeated=washCount>0
      ? `<span class="sorting-confirm-repeat">Already washed ${washCount}x${row.last_wash_code?` · last ${esc(row.last_wash_code)}`:""}</span>`
      : "";
    const dailyWarning=meta.repeatedAcrossDays
      ? '<span class="sorting-confirm-daily-warning">DAILY / MULTI-DAY CUSTOMER · CHECK THE DATE</span>'
      : "";
    const allocation=Number(row.estimated_allocated_weight_kg||0).toFixed(2);
    const scanCount=Number(row.scan_contents_count||0);
    const scanProof=scanCount>0
      ? `<span class="sorting-confirm-scan-proof">SCAN VERIFIED · ${scanCount} CONTENTS trolley${scanCount===1?"":"s"}</span>`
      : state.editingWash&&correctionKeepsLegacySelection()
        ? '<span class="sorting-confirm-scan-proof legacy">LEGACY RECORD CORRECTION</span>'
        : "";
    const allocationText=row.weight_allocation_method==="EQUAL_SPLIT_ESTIMATE"
      ? `Approx. ${allocation} KG of this load`
      : `${allocation} KG · full load`;

    return `<article class="sorting-confirm-customer${color?" colored":""}${meta.repeatedAcrossDays?" daily-risk":""}"${style}>
      <div class="sorting-confirm-customer-number">${index+1} of ${total}</div>
      <div class="sorting-confirm-customer-main">
        <strong>${esc(row.customer_name)}</strong>
        ${dailyWarning}
        ${scanProof}
        <div class="sorting-confirm-schedule-line">
          <span>SCHEDULED</span>
          <b>${esc(schedule)}</b>
          <em class="${meta.relationClass}">${esc(meta.relation)}</em>
        </div>
        <span class="sorting-confirm-route">${row.route_display_name?esc(row.route_display_name):"No Route"}</span>
        ${repeated}
      </div>
      <div class="sorting-confirm-customer-weight">
        <span>EST. CUSTOMER KG</span>
        <strong>${allocation}</strong>
        <small>${esc(allocationText)}</small>
      </div>
    </article>`;
  }

  function openWashConfirmation(){
    if(state.busy)return;
    let payload;
    try{payload=washPayload();}catch(error){return setMessage(error.message,"error");}

    const mode=state.editingWash?"CORRECTION":state.lateEntryMode?"LATE_ENTRY":"LIVE";
    payload.customerRows=estimatedCustomerWeightAllocations(payload.weight,payload.customerRows);
    state.pendingWashConfirmation={
      mode,
      payload,
      editingWash:state.editingWash?{...state.editingWash}:null,
      shift:state.shift,
      operatorStaffId:el.operator.value,
      startTime:el.start.value,
      washType:el.type.value,
      notes:el.notes.value.trim()||null
    };

    el.washConfirmTitle.textContent=mode==="CORRECTION"
      ? `Check correction for ${state.editingWash.wash_code}`
      : mode==="LATE_ENTRY"
        ? "Check missed wash before saving"
        : "Check before saving";

    el.washConfirmMode.className=`sorting-confirm-mode ${mode==="CORRECTION"?"correction":mode==="LATE_ENTRY"?"late":"live"}`;
    el.washConfirmMode.textContent=mode==="CORRECTION"
      ? `CORRECTION · original ${state.editingWash.wash_code} stays in history`
      : mode==="LATE_ENTRY"
        ? "LATE ENTRY · wash already happened"
        : "CURRENT WASHING";

    el.washConfirmWeight.textContent=`${Number(payload.weight).toFixed(1)} KG`;
    el.washConfirmType.textContent=state.pendingWashConfirmation.washType;
    el.washConfirmCustomerCount.textContent=`${payload.customerRows.length} customer${payload.customerRows.length===1?"":"s"} · all shown below`;

    const riskRows=payload.customerRows.map(row=>({row,meta:customerScheduleConfirmMeta(row)}));
    const hasMultiDay=riskRows.some(item=>item.meta.repeatedAcrossDays);
    const hasNonToday=riskRows.some(item=>item.meta.relation!=="TODAY");
    el.washConfirmRisk.hidden=!hasMultiDay&&!hasNonToday;
    el.washConfirmRiskText.textContent=hasMultiDay&&hasNonToday
      ? "At least one selected customer appears on multiple days and/or is not scheduled for this Business Date. Check every customer name and date below."
      : hasMultiDay
        ? "At least one selected customer appears on more than one scheduled day. Check the date carefully."
        : hasNonToday
          ? "At least one selected customer is work-ahead, late or off schedule. Confirm that the selected day is intentional."
          : "";

    el.washConfirmCustomers.dataset.customerCount=String(payload.customerRows.length);
    el.washConfirmCustomers.classList.toggle("multi-customer",payload.customerRows.length>1);
    el.washConfirmCustomers.innerHTML=payload.customerRows
      .map((row,index)=>confirmCustomerHtml(row,index,payload.customerRows.length))
      .join("");
    el.washConfirmStaff.textContent=payload.operator?.display_name||"Selected staff";
    el.washConfirmWasher.textContent=`${payload.washer.washer_code} · ${payload.washer.washer_name||"Washer"}`;
    el.washConfirmStart.textContent=state.pendingWashConfirmation.startTime;
    el.washConfirmBusiness.textContent=`${fmtDate(state.washing?.business_date)} · ${state.shift==="MORNING"?"Morning":"Evening"}`;

    const special=mode!=="LIVE";
    el.washConfirmSpecial.hidden=!special;
    el.washConfirmReason.value="";
    if(special){
      el.washConfirmReasonLabel.textContent=mode==="CORRECTION"
        ? "Why is this washing being corrected?"
        : "Why was this washing entered late?";
      el.washConfirmReason.placeholder=mode==="CORRECTION"
        ? "Example: Wrong KG / wrong customer selected"
        : "Example: Wash happened but was not entered at the time";
    }

    const exceptionRows=payload.customerRows.filter(row=>selectionExceptionReady(row));
    el.washConfirmReceptionException.hidden=!exceptionRows.length;
    el.washConfirmReceptionExceptionList.innerHTML=exceptionRows.map(row=>`<p><strong>${esc(row.customer_name)}</strong> · ${esc(selectionReceptionException(row)?.reason||"")}</p>`).join("");
    el.washConfirmNotesWrap.hidden=!state.pendingWashConfirmation.notes;
    el.washConfirmNotes.textContent=state.pendingWashConfirmation.notes||"";
    el.washConfirmMessage.textContent="";
    el.washConfirmSave.disabled=false;
    el.washConfirmSave.textContent=mode==="CORRECTION"?"Confirm correction":mode==="LATE_ENTRY"?"Confirm late entry":"Confirm & save";

    el.washConfirmDialog.showModal();
  }

  async function commitConfirmedWash(){
    if(state.busy||!state.pendingWashConfirmation)return;
    const pending=state.pendingWashConfirmation;
    const payload=pending.payload;
    const specialReason=pending.mode==="LIVE"?"":el.washConfirmReason.value.trim();

    if(pending.mode!=="LIVE"&&!specialReason){
      el.washConfirmMessage.textContent="Enter the reason before confirming.";
      el.washConfirmReason.focus();
      return;
    }

    state.busy=true;
    el.washConfirmSave.disabled=true;
    el.washConfirmSave.textContent="Saving…";
    el.washConfirmMessage.textContent="Saving and creating the production trace…";
    el.saveWash.disabled=true;
    el.missedWash.disabled=true;

    try{
      const common={
        p_shift_code:pending.shift,
        p_washer_id:payload.washer.washer_id,
        p_operator_staff_id:pending.operatorStaffId,
        p_start_time:pending.startTime,
        p_weight_kg:payload.weight,
        p_wash_type:pending.washType,
        p_customer_selections:payload.selections,
        p_reception_exceptions:payload.receptionExceptions||[],
        p_notes:pending.notes
      };

      const result=pending.mode==="CORRECTION"
        ? await rpc("correct_sorting_wash_run_v4",{
            p_wash_run_id:pending.editingWash.wash_run_id,
            p_expected_row_version:pending.editingWash.row_version,
            ...common,
            p_reason:specialReason
          })
        : pending.mode==="LATE_ENTRY"
          ? await rpc("save_sorting_missed_wash_v4",{
              ...common,
              p_reason:specialReason
            })
          : await rpc("save_sorting_wash_run_v4",common);

      el.washConfirmDialog.close();
      state.pendingWashConfirmation=null;

      const op=pending.operatorStaffId;
      clearWash(true);
      el.operator.value=op;
      await loadWashing();
      await loadStaffWork();
      renderSelected();
      setMessage(
        result?.message||(pending.mode==="CORRECTION"?"Correction saved.":pending.mode==="LATE_ENTRY"?"Late entry saved.":"Washing saved."),
        result?.unscheduled_customer_count?"warning":"success"
      );
    }catch(error){
      console.error(error);
      el.washConfirmMessage.textContent=friendly(error);
      setMessage(friendly(error),"error");
    }finally{
      state.busy=false;
      el.washConfirmSave.disabled=false;
      el.saveWash.disabled=false;
      el.missedWash.disabled=false;
      renderEditState();
      renderShift();
    }
  }

  async function saveWash(){
    openWashConfirmation();
  }

  function minutesToLabel(value){
    const minutes=Math.max(0,Number(value||0));
    const h=Math.floor(minutes/60),m=minutes%60;
    return `${h}h ${String(m).padStart(2,"0")}m`;
  }

  function performanceValue(value){
    return value===null||value===undefined?"—":`${Number(value).toFixed(1)} kg/hr`;
  }

  function targetPercentClass(pct){
    const value=Number(pct);
    if(!Number.isFinite(value))return "";
    if(value>=100)return "good";
    if(value>=80)return "near";
    return "low";
  }

  function renderStaffWorkLegacy(){
    const rows=Array.isArray(state.staffWork?.staff)?state.staffWork.staff:[];
    if(!el.staffWorkList)return;

    const profile=state.staffWork?.work_profile;
    const targets=state.staffWork?.performance_targets||{};
    const autoAbsence=state.staffWork?.auto_absence||{};

    if(el.staffScheduleNote){
      const scheduleText=profile?.schedule_label
        ? `Standard weekly schedule: ${profile.schedule_label} · break ${Number(profile.break_minutes||0)} min.`
        : "Published weekly schedule is the standard time reference.";
      const mopCoverage=state.staffWork?.operational_mop_coverage;
      const mopText=mopCoverage==="DEDICATED"
        ? ` Actual MOP: ${state.staffWork?.operational_mop_staff_name||"Assigned"}.`
        : mopCoverage==="UNRESOLVED_ABSENT_MOP"
          ? " Planned MOP is unavailable in Sorting. Choose another MOP or operate with no dedicated MOP."
          : mopCoverage==="NO_DEDICATED_MOP"
            ? " Actual: No dedicated MOP."
            : mopCoverage==="NO_PRESENT_SORTING_STAFF"
              ? " No Sorting staff are currently available."
              : " Actual MOP coverage is unresolved.";
      const autoText=autoAbsence.cutoff_reached
        ? " Staff with no activity after the standard finish are shown as Auto absent."
        : "";
      el.staffScheduleNote.textContent=`${scheduleText} Roster = Planned; this page records Actual.${mopText}${autoText} Clothes target ${Number(targets.clothes_kg_hr||160)} kg/hr · MOP reference ${Number(targets.mop_kg_hr||100)} kg/hr (provisional).`;
      el.staffScheduleNote.classList.toggle("mop-missing",["UNRESOLVED","UNRESOLVED_ABSENT_MOP"].includes(mopCoverage));
    }

    if(!rows.length){
      el.staffWorkList.innerHTML='<div class="sorting-empty">No staff are currently shown in Sorting for this shift. Use Add staff manually when the actual position changed.</div>';
      return;
    }

    el.staffWorkList.innerHTML=rows.map(row=>{
      const movedOut=row.attendance_status==="MOVED"||row.actual_in_sorting===false;
      const confirmedAbsent=row.attendance_status==="ABSENT";
      const autoAbsent=row.attendance_status==="AUTO_ABSENT";
      const absent=confirmedAbsent||autoAbsent;
      const unavailable=absent||movedOut;
      const training=confirmedAbsent&&row.absence_reason==="TRAINING";
      const attendanceLabel=movedOut
        ? `MOVED · ${String(row.actual_area_name||row.actual_area_code||"OTHER AREA").toUpperCase()}`
        : training
          ? "TRAINING"
          : confirmedAbsent
            ? `ABSENT · ${titleCode(row.absence_reason||"OTHER")}`
            : autoAbsent
              ? "ABSENT · AUTO"
              : row.attendance_status==="PRESENT_EVIDENCE"
                ? "Activity recorded"
                : row.attendance_status==="PRESENT"
                  ? "Present"
                  : "Planned";

      const plannedLabel=row.planned_schedule_label
        || (row.planned_start_time&&row.planned_end_time
          ? `${fmtTime(row.planned_start_time)}–${fmtTime(row.planned_end_time)}`
          : "Published weekly schedule");
      const actualStart=row.actual_start_time?fmtTime(row.actual_start_time):"";
      const actualEnd=row.actual_end_time?fmtTime(row.actual_end_time):"";
      const workMode=row.work_mode==="MOP"?"MOP":"CLOTHES";
      const plannedMode=row.planned_work_mode==="MOP"?"MOP":row.planned_work_mode==="CLOTHES"?"CLOTHES":"No dedicated MOP";
      const away=Number(row.extra_non_work_minutes||0);
      const awayHours=Math.floor(away/60);
      const awayMinutes=away%60;
      const editing=!unavailable&&state.editingStaffId===row.staff_id;
      const perf=row.performance||{};
      const hasWashActivity=Number(perf.total_loads||0)>0;
      const hasActualActivity=Boolean(row.has_actual_operational_activity)||hasWashActivity||Number(row.trolley_intake_count||0)>0;
      const positionNote=movedOut
        ? `<span class="sorting-staff-position-change moved">Planned: ${esc(plannedPositionLabel(row)||"Sorting Area")} → Actual: ${esc(row.actual_area_name||titleCode(row.actual_area_code)||"Other area")}</span>`
        : row.manual_position
          ? `<span class="sorting-staff-position-change">Planned: ${esc(plannedPositionLabel(row))} → Actual: Sorting</span>`
          : "";
      const modeChangeNote=!movedOut&&row.work_mode_changed
        ? `<span class="sorting-work-mode-change-note">Changed from planned ${esc(plannedMode)} · ${esc(row.work_mode_change_reason||"Reason recorded")}</span>`
        : "";
      const autoAbsentNote=autoAbsent
        ? `<span class="sorting-auto-absence-note">No washing/Actual activity was recorded by the end-of-shift check. This is an automatic inference, not a confirmed No show.</span>`
        : "";
      const timeDisplay=movedOut
        ? "Not counted in Sorting"
        : absent
          ? "Not counted"
          : actualStart&&actualEnd
            ? `${esc(actualStart)} → ${esc(actualEnd)}`
            : esc(plannedLabel);
      const stateLabel=movedOut?"Actual elsewhere":training?"Training":confirmedAbsent?"Absent":autoAbsent?"Auto absent":row.manual_position?"Manual Actual":row.adjusted?"Adjusted":"As planned";
      const clothesPct=perf.clothes_target_pct;
      const mopPct=perf.mop_target_pct;

      return `
      <article class="sorting-staff-card${row.manual_position?" manual-position":""}${editing?" is-editing":""}${absent?" is-absent":""}${autoAbsent?" auto-absent":""}${movedOut?" is-moved":""}" data-staff-work="${esc(row.staff_id)}">
        <div class="sorting-staff-card-top">
          <div class="sorting-staff-card-identity">
            <strong>${esc(row.display_name)}</strong>
            <span>${esc(plannedPositionLabel(row)||"Sorting Area")}</span>
            ${positionNote}
            ${modeChangeNote}
            ${confirmedAbsent&&row.attendance_notes?`<span class="sorting-attendance-note${training?" training":""}">${esc(row.attendance_notes)}</span>`:""}
            ${movedOut&&row.area_transfer_notes?`<span class="sorting-transfer-note">${esc(row.area_transfer_notes)}</span>`:""}
            ${autoAbsentNote}
          </div>
          <div class="sorting-staff-card-badges">
            <span class="sorting-attendance-badge ${movedOut?"moved":absent?"absent":"working"}">${esc(attendanceLabel)}</span>
            ${movedOut?"":`<span class="sorting-work-mode ${workMode==="MOP"?"mop":"clothes"}">${workMode}</span>`}
            <span class="sorting-staff-state ${movedOut?"moved":absent?"absent":row.manual_position?"manual":row.adjusted?"adjusted":"planned"}">${stateLabel}</span>
          </div>
        </div>

        <div class="sorting-staff-card-summary">
          <div>
            <span>Started / Leaving</span>
            <strong>${timeDisplay}</strong>
            <small>${movedOut?`Actual area: ${esc(row.actual_area_name||titleCode(row.actual_area_code)||"Other area")}`:`Standard: ${esc(plannedLabel)}`}</small>
          </div>
          <div>
            <span>Time away</span>
            <strong>${unavailable?"—":away>0?minutesToLabel(away):"None"}</strong>
            <small>${unavailable?"Excluded from Sorting worked time":"Only interruptions during the shift"}</small>
          </div>
          <div>
            <span>Effective worked</span>
            <strong>${unavailable?"0h 00m":minutesToLabel(row.net_work_minutes)}</strong>
            <small>${movedOut?"Working in another Actual area":absent?(autoAbsent?"Auto inferred":training?"Training":"Confirmed absent"):Number(row.variance_minutes||0)===0?"Matches standard":`${Number(row.variance_minutes)>0?"+":""}${Number(row.variance_minutes)} min vs standard`}</small>
          </div>
        </div>

        <div class="sorting-performance-grid">
          <div class="sorting-performance-box clothes ${unavailable?"disabled":""}">
            <div><strong>CLOTHES</strong><span>Target ${Number(perf.clothes_target_kg_hr||targets.clothes_kg_hr||160)} kg/hr</span></div>
            <b>${unavailable?"Excluded":performanceValue(perf.clothes_kg_hr)}</b>
            <small>${Number(perf.clothes_kg||0).toFixed(1)} kg · ${Number(perf.clothes_loads||0)} load${Number(perf.clothes_loads||0)===1?"":"s"}${unavailable?"":` · ${Number.isFinite(Number(clothesPct))?`${Number(clothesPct).toFixed(0)}% target`:"—"}`}</small>
            ${unavailable?"":`<div class="sorting-performance-track"><span class="${targetPercentClass(clothesPct)}" style="width:${Math.max(0,Math.min(Number(clothesPct||0),100))}%"></span></div>`}
          </div>
          <div class="sorting-performance-box mop ${unavailable?"disabled":""}">
            <div><strong>MOP</strong><span>Provisional ${Number(perf.mop_target_kg_hr||targets.mop_kg_hr||100)} kg/hr</span></div>
            <b>${unavailable?"Excluded":performanceValue(perf.mop_kg_hr)}</b>
            <small>${Number(perf.mop_kg||0).toFixed(1)} kg · ${Number(perf.mop_loads||0)} load${Number(perf.mop_loads||0)===1?"":"s"}${unavailable?"":` · ${Number.isFinite(Number(mopPct))?`${Number(mopPct).toFixed(0)}% ref.`:"—"}`}</small>
            ${unavailable?"":`<div class="sorting-performance-track"><span class="${targetPercentClass(mopPct)}" style="width:${Math.max(0,Math.min(Number(mopPct||0),100))}%"></span></div>`}
          </div>
        </div>

        <div class="sorting-staff-card-buttons">
          ${movedOut
            ? `<button class="sorting-primary-button" data-return-sorting="${esc(row.staff_id)}" type="button">Return to Sorting</button>`
            : confirmedAbsent
              ? `<button class="sorting-primary-button" data-mark-present="${esc(row.staff_id)}" type="button">Correct to present</button>`
              : autoAbsent
                ? `<button class="sorting-primary-button" data-mark-present="${esc(row.staff_id)}" type="button">I confirm they worked</button>
                   <button class="sorting-attendance-button" data-no-work="${esc(row.staff_id)}" type="button">No Work</button>`
                : `${hasActualActivity
                     ? ``
                     : `<button class="sorting-attendance-button" data-no-work="${esc(row.staff_id)}" type="button">No Work</button>`}
                   <button class="sorting-primary-button sorting-staff-edit-button" data-edit-staff-work="${esc(row.staff_id)}" type="button">${editing?"Editing":"Edit time"}</button>
                   ${workMode==="MOP"
                     ? `<button class="sorting-mode-button clothes" data-change-work-mode="${esc(row.staff_id)}" data-work-mode="CLOTHES" type="button">Change to Clothes</button>`
                     : `<button class="sorting-mode-button mop" data-change-work-mode="${esc(row.staff_id)}" data-work-mode="MOP" type="button">Set as MOP</button>`}
                   ${row.manual_position?`<button class="sorting-small-danger" data-cancel-manual-staff="${esc(row.work_session_id)}" type="button">Remove manual</button>`:""}`}
        </div>

        ${editing?`
        <div class="sorting-staff-card-editor sorting-simple-time-editor">
          <div class="sorting-staff-editor-note">
            <strong>Enter the real clock times.</strong>
            <span>Overtime? Change <b>Leaving at</b> to the time they will actually leave. Arrived early/late? Change <b>Started at</b>. No overtime calculation is needed.</span>
          </div>

          <div class="sorting-clock-time-grid">
            <label>Started at
              <input data-work-field="start" type="time" value="${esc(actualStart)}">
            </label>
            <label class="sorting-leaving-time">Leaving at
              <input data-work-field="end" type="time" value="${esc(actualEnd)}">
              <small>For overtime, enter the new leaving time.</small>
            </label>
          </div>

          <label class="sorting-time-away-toggle">
            <input data-work-field="away-enabled" type="checkbox"${away>0?" checked":""}>
            <span><strong>Add time away during shift</strong><small>Only use this for an interruption while at work. Do not use it for overtime, late arrival or leaving early.</small></span>
          </label>

          <div class="sorting-time-away-panel${away>0?"":" hidden"}" data-time-away-panel>
            <fieldset class="sorting-time-away-field">
              <legend>How long were they away?</legend>
              <label>Hours
                <input data-work-field="away-hours" type="number" min="0" max="12" step="1" value="${awayHours}">
              </label>
              <label>Minutes
                <input data-work-field="away-minutes" type="number" min="0" max="59" step="5" value="${awayMinutes}">
              </label>
            </fieldset>
            <label>Why were they away?
              <select data-work-field="reason">
                <option value="NONE">Choose…</option>
                <option value="TRAINING"${row.adjustment_reason==="TRAINING"?" selected":""}>Training</option>
                <option value="PERSONAL"${row.adjustment_reason==="PERSONAL"?" selected":""}>Personal</option>
                <option value="OTHER"${row.adjustment_reason==="OTHER"?" selected":""}>Other</option>
              </select>
            </label>
          </div>

          <div class="sorting-staff-work-bottom">
            <label class="sorting-staff-notes">Notes
              <input data-work-field="notes" maxlength="1000" value="${esc(row.notes||"")}" placeholder="Optional operational note">
            </label>
            <div class="sorting-staff-net"><span>Effective worked</span><strong>${minutesToLabel(row.net_work_minutes)}</strong><small>Standard break + time away excluded</small></div>
            <div class="sorting-staff-editor-actions">
              <button class="sorting-secondary-button" data-cancel-staff-edit="${esc(row.staff_id)}" type="button">Close</button>
              <button class="sorting-primary-button" data-save-staff-work="${esc(row.staff_id)}" type="button">Save time</button>
            </div>
          </div>
        </div>`:""}
      </article>`;
    }).join("");
  }

  function renderStaffWork(){
    const rows=Array.isArray(state.staffWork?.staff)?state.staffWork.staff:[];
    if(!el.staffWorkList)return;
    if(el.staffCount)el.staffCount.textContent=`${rows.length} staff`;
    const profile=state.staffWork?.work_profile;
    const targets=state.staffWork?.performance_targets||{};
    const autoAbsence=state.staffWork?.auto_absence||{};
    if(el.staffScheduleNote){
      const schedule=profile?.schedule_label?`${profile.schedule_label} · break ${Number(profile.break_minutes||0)} min.`:"Published weekly schedule.";
      const auto=autoAbsence.cutoff_reached?" Staff without activity after the normal end are marked Auto absent.":"";
      el.staffScheduleNote.textContent=`Roster is Planned; this page records Actual. Standard schedule: ${schedule}${auto} Clothes target ${Number(targets.clothes_kg_hr||160)} kg/hr · MOP reference ${Number(targets.mop_kg_hr||100)} kg/hr.`;
    }
    if(!rows.length){
      el.staffWorkList.innerHTML='<div class="sorting-empty">No staff are currently shown in Sorting for this shift. Use Add staff manually when the actual position changed.</div>';
      return;
    }
    el.staffWorkList.innerHTML=`<div class="sorting-staff-simple-table"><table><thead><tr><th>Staff</th><th>Planned</th><th>Actual position</th><th>Sorting time</th><th>Worked</th><th>Output</th><th>Status</th><th></th></tr></thead><tbody>${rows.map(row=>{
      const movedOut=row.attendance_status==="MOVED"||row.actual_in_sorting===false;
      const confirmedAbsent=row.attendance_status==="ABSENT";
      const autoAbsent=row.attendance_status==="AUTO_ABSENT";
      const absent=confirmedAbsent||autoAbsent;
      const unavailable=absent||movedOut;
      const training=confirmedAbsent&&row.absence_reason==="TRAINING";
      const editing=false;
      const actualStart=row.actual_start_time?fmtTime(row.actual_start_time):"";
      const actualEnd=row.actual_end_time?fmtTime(row.actual_end_time):"";
      const plannedLabel=row.planned_schedule_label||(row.planned_start_time&&row.planned_end_time?`${fmtTime(row.planned_start_time)}-${fmtTime(row.planned_end_time)}`:"Published weekly schedule");
      const workMode=row.work_mode==="MOP"?"MOP":"CLOTHES";
      const plannedMode=row.planned_work_mode==="MOP"?"MOP":row.planned_work_mode==="CLOTHES"?"CLOTHES":"No dedicated MOP";
      const away=Number(row.extra_non_work_minutes||0),awayHours=Math.floor(away/60),awayMinutes=away%60,breakMinutes=Number(row.standard_break_minutes??state.staffWork?.work_profile?.break_minutes??0);
      const perf=row.performance||{};
      const hasActualActivity=Boolean(row.has_actual_operational_activity)||Number(perf.total_loads||0)>0||Number(row.trolley_intake_count||0)>0;
      const overtime=Math.max(0,Number(row.variance_minutes||0));
      const attendanceLabel=movedOut?`Moved · ${row.actual_area_name||row.actual_area_code||"Other area"}`:training?"Training":confirmedAbsent?`Absent · ${titleCode(row.absence_reason||"OTHER")}`:autoAbsent?"Auto absent":row.manual_position?"Manual Actual":overtime>0?`Overtime +${minutesToLabel(overtime)}`:row.adjusted?"Adjusted":"As planned";
      const stateClass=movedOut?"moved":absent?"absent":row.manual_position?"manual":overtime>0?"overtime":row.adjusted?"adjusted":"planned";
      const actualPosition=movedOut?(row.actual_area_name||titleCode(row.actual_area_code)||"Other area"):(workMode==="MOP"?"MOP":"Clothes");
      const timeDisplay=unavailable?"Not counted":actualStart&&actualEnd?`${actualStart} - ${actualEnd}`:plannedLabel;
      const worked=unavailable?"0h 00m":minutesToLabel(row.net_work_minutes);
      let actions="";
      if(movedOut)actions=`<button class="sorting-finish-staff-action" data-return-sorting="${esc(row.staff_id)}" type="button">Return to Sorting</button>`;
      else if(confirmedAbsent)actions=`<button class="sorting-finish-staff-action" data-mark-present="${esc(row.staff_id)}" type="button">Confirm arrived</button>`;
      else if(autoAbsent)actions=`<button class="sorting-finish-staff-action" data-mark-present="${esc(row.staff_id)}" type="button">Confirm</button><button class="sorting-finish-staff-action danger-outline" data-no-work="${esc(row.staff_id)}" type="button">No Work</button>`;
      else actions=`${hasActualActivity?"":`<button class="sorting-finish-staff-action danger-outline" data-no-work="${esc(row.staff_id)}" type="button">No Work</button>`}<button class="sorting-finish-staff-action" data-edit-staff-work="${esc(row.staff_id)}" type="button">${editing?"Editing":"Edit"}</button><button class="sorting-finish-staff-action" data-change-work-mode="${esc(row.staff_id)}" data-work-mode="${workMode==="MOP"?"CLOTHES":"MOP"}" type="button">${workMode==="MOP"?"Clothes":"Set MOP"}</button>${row.manual_position?`<button class="sorting-finish-staff-action danger-outline" data-cancel-manual-staff="${esc(row.work_session_id)}" type="button">Remove</button>`:""}`;
      const editor=editing?`<tr class="sorting-staff-editor-row" data-staff-work="${esc(row.staff_id)}"><td colspan="8"><div class="sorting-staff-table-editor"><div><strong>Actual clock times</strong><small>Set a later leaving time for overtime. Time away is only for an interruption during the shift.</small></div><div class="sorting-clock-time-grid"><label>Started at<input data-work-field="start" type="time" value="${esc(actualStart)}"></label><label>Leaving at<input data-work-field="end" type="time" value="${esc(actualEnd)}"></label><label>Break (minutes)<input data-work-field="break" type="number" min="0" max="240" step="5" value="${breakMinutes}"></label></div><label class="sorting-time-away-toggle"><input data-work-field="away-enabled" type="checkbox"${away>0?" checked":""}><span><strong>Add time away</strong><small>Do not use this for late arrival, early leave or overtime.</small></span></label><div class="sorting-time-away-panel${away>0?"":" hidden"}" data-time-away-panel><fieldset class="sorting-time-away-field"><legend>Time away</legend><label>Hours<input data-work-field="away-hours" type="number" min="0" max="12" step="1" value="${awayHours}"></label><label>Minutes<input data-work-field="away-minutes" type="number" min="0" max="59" step="5" value="${awayMinutes}"></label></fieldset><label>Reason<select data-work-field="reason"><option value="NONE">Choose...</option><option value="TRAINING"${row.adjustment_reason==="TRAINING"?" selected":""}>Training</option><option value="PERSONAL"${row.adjustment_reason==="PERSONAL"?" selected":""}>Personal</option><option value="OTHER"${row.adjustment_reason==="OTHER"?" selected":""}>Other</option></select></label></div><div class="sorting-staff-table-editor-footer"><label>Notes<input data-work-field="notes" maxlength="1000" value="${esc(row.notes||"")}" placeholder="Optional operational note"></label><div><strong>${worked}</strong><small>Effective worked time</small></div><button class="sorting-secondary-button" data-cancel-staff-edit="${esc(row.staff_id)}" type="button">Close</button><button class="sorting-primary-button" data-save-staff-work="${esc(row.staff_id)}" type="button">Save time</button></div></div></td></tr>`:"";
      return `<tr class="${unavailable?"is-unavailable":""}" data-staff-work="${esc(row.staff_id)}"><td><strong>${esc(row.display_name)}</strong><small>${esc(workMode)}${row.work_mode_changed?` · changed from ${esc(plannedMode)}`:""}</small></td><td><b>${esc(plannedPositionLabel(row)||"Sorting Area")}</b><small>${esc(plannedLabel)}</small></td><td><b>${esc(actualPosition)}</b><small>${row.manual_position?"Planned elsewhere":movedOut?"Moved from Sorting":"Confirmed area"}</small></td><td><b>${esc(timeDisplay)}</b><small>Standard: ${esc(plannedLabel)}</small></td><td><b>${esc(worked)}</b><small>${unavailable?"Excluded":away>0?`${minutesToLabel(away)} away`:"No time away"}</small></td><td><b>${unavailable?"Excluded":`${Number(perf.clothes_kg||0).toFixed(1)} kg clothes`}</b><small>${unavailable?"":`${Number(perf.mop_kg||0).toFixed(1)} kg MOP · ${Number(perf.total_loads||0)} loads`}</small></td><td><span class="sorting-staff-simple-state ${stateClass}">${esc(attendanceLabel)}</span></td><td><div class="sorting-staff-table-actions">${actions}</div></td></tr>${editor}`;
    }).join("")}</tbody></table></div>`;
  }

  function ensureStaffTimeDialog(){
    let dialog=document.getElementById("sortingStaffTimeDialog");
    if(dialog)return dialog;
    document.body.insertAdjacentHTML("beforeend",`<dialog id="sortingStaffTimeDialog" class="sorting-staff-time-dialog"><section class="sorting-staff-time-dialog-card" data-staff-work=""><header><div><p>Actual staffing</p><h2 id="sortingStaffTimeDialogTitle">Edit Sorting staff</h2><span id="sortingStaffTimeDialogSubtitle">Actual times are recorded separately from the published Roster.</span></div><button type="button" class="sorting-staff-time-dialog-close" data-close-staff-time aria-label="Close">x</button></header><div id="sortingStaffTimeDialogBody"></div></section></dialog>`);
    dialog=document.getElementById("sortingStaffTimeDialog");
    dialog.addEventListener("change",event=>{const toggle=event.target.closest('[data-work-field="away-enabled"]');if(!toggle)return;const panel=dialog.querySelector("[data-time-away-panel]");if(panel)panel.classList.toggle("hidden",!toggle.checked);});
    dialog.addEventListener("click",async event=>{const close=event.target.closest("[data-close-staff-time],[data-cancel-staff-edit]");if(close){dialog.close();return;}const save=event.target.closest("[data-save-staff-work]");if(save&&!state.busy)await saveStaffActual(save.dataset.saveStaffWork,save);});
    dialog.addEventListener("close",()=>{state.editingStaffId=null;});
    return dialog;
  }

  function openStaffTimeDialog(staffId){
    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId);
    if(!row)return;
    const dialog=ensureStaffTimeDialog(),actualStart=row.actual_start_time?fmtTime(row.actual_start_time):fmtTime(row.planned_start_time),actualEnd=row.actual_end_time?fmtTime(row.actual_end_time):fmtTime(row.planned_end_time),away=Number(row.extra_non_work_minutes||0),awayHours=Math.floor(away/60),awayMinutes=away%60,breakMinutes=Number(row.standard_break_minutes??state.staffWork?.work_profile?.break_minutes??0),worked=minutesToLabel(row.net_work_minutes);
    state.editingStaffId=staffId;
    document.getElementById("sortingStaffTimeDialogTitle").textContent=row.display_name;
    document.getElementById("sortingStaffTimeDialogSubtitle").textContent="Actual work in Sorting Area. Planned times remain visible for reference.";
    document.getElementById("sortingStaffTimeDialogBody").innerHTML=`<div class="sorting-staff-time-form" data-staff-work="${esc(staffId)}"><label class="sorting-staff-time-name">Staff member<input type="text" value="${esc(row.display_name)}" readonly></label><div class="sorting-staff-time-grid"><label>Started at<input data-work-field="start" type="time" value="${esc(actualStart)}"></label><label>Leaving at<input data-work-field="end" type="time" value="${esc(actualEnd)}"><small>Change this time for early leave or overtime.</small></label><label>Break (minutes)<input data-work-field="break" type="number" min="0" max="240" step="5" value="${breakMinutes}"><small>Change only when the actual break was different.</small></label></div><label class="sorting-time-away-toggle"><input data-work-field="away-enabled" type="checkbox"${away>0?" checked":""}><span><strong>Add time away</strong><small>Use only for an interruption during the shift.</small></span></label><div class="sorting-time-away-panel${away>0?"":" hidden"}" data-time-away-panel><fieldset class="sorting-time-away-field"><legend>Time away</legend><label>Hours<input data-work-field="away-hours" type="number" min="0" max="12" step="1" value="${awayHours}"></label><label>Minutes<input data-work-field="away-minutes" type="number" min="0" max="59" step="5" value="${awayMinutes}"></label></fieldset><label>Reason<select data-work-field="reason"><option value="NONE">Choose...</option><option value="TRAINING"${row.adjustment_reason==="TRAINING"?" selected":""}>Training</option><option value="PERSONAL"${row.adjustment_reason==="PERSONAL"?" selected":""}>Personal</option><option value="OTHER"${row.adjustment_reason==="OTHER"?" selected":""}>Other</option></select></label></div><footer><label>Notes<input data-work-field="notes" maxlength="1000" value="${esc(row.notes||"")}" placeholder="Optional operational note"></label><div><strong>${worked}</strong><small>Effective worked time</small></div><button class="sorting-secondary-button" data-cancel-staff-edit="${esc(staffId)}" type="button">Cancel</button><button class="sorting-primary-button" data-save-staff-work="${esc(staffId)}" type="button">Save time</button></footer></div>`;
    dialog.showModal();
  }

  function openStaffActualDialog(staffId){
    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId);
    if(!row)return;

    const dialog=ensureStaffTimeDialog();
    const actualStart=row.actual_start_time?fmtTime(row.actual_start_time):fmtTime(row.planned_start_time);
    const actualEnd=row.actual_end_time?fmtTime(row.actual_end_time):fmtTime(row.planned_end_time);
    const breakMinutes=Number(row.standard_break_minutes??state.staffWork?.work_profile?.break_minutes??0);
    const existingAway=Number(row.extra_non_work_minutes||0);
    const existingReason=String(row.adjustment_reason||"NONE");
    const workMode=row.work_mode==="MOP"?"MOP":"CLOTHES";
    const hasRecordedEnd=Boolean(row.work_session_id&&row.actual_end_time);

    state.editingStaffId=staffId;
    document.getElementById("sortingStaffTimeDialogTitle").textContent=row.display_name;
    document.getElementById("sortingStaffTimeDialogSubtitle").textContent="Actual work in Sorting Area. The planned times remain visible for reference.";
    document.getElementById("sortingStaffTimeDialogBody").innerHTML=`<div class="sorting-staff-time-form sorting-staff-time-form-finish" data-staff-work="${esc(staffId)}" data-existing-away="${existingAway}" data-existing-reason="${esc(existingReason)}" data-existing-mode="${esc(workMode)}"><label class="sorting-staff-time-name">Staff member<input type="text" value="${esc(row.display_name)}" readonly></label><label class="sorting-staff-position">Actual Position<select data-work-field="position"><option value="CLOTHES"${workMode==="CLOTHES"?" selected":""}>Clothes</option><option value="MOP"${workMode==="MOP"?" selected":""}>MOP</option></select></label><div class="sorting-staff-time-grid"><label>Started at<input data-work-field="start" type="time" value="${esc(actualStart)}"></label><label>Leaving at<input data-work-field="end" type="time" value="${esc(actualEnd)}"><small>This will close the shift at ${esc(actualEnd)}.</small></label><label>Break (minutes)<input data-work-field="break" type="number" min="0" max="240" step="5" value="${breakMinutes}"><small>Change only when the actual break was different.</small></label></div><label class="sorting-staff-close-toggle"><input data-work-field="close-shift" type="checkbox"${hasRecordedEnd?" checked":""}><span>Record this as the actual leaving time and close the shift.</span></label><label class="sorting-staff-time-note">Note / reason<input data-work-field="notes" maxlength="1000" value="${esc(row.notes||"")}" placeholder="Optional operational note"></label><p class="sorting-staff-time-message" data-staff-time-message aria-live="polite"></p><footer><span></span><button class="sorting-secondary-button" data-cancel-staff-edit="${esc(staffId)}" type="button">Cancel</button><button class="sorting-primary-button" data-save-staff-work="${esc(staffId)}" type="button">Save Staff Actual</button></footer></div>`;
    dialog.showModal();
  }

  function renderManualStaffCandidates(){
    if(!el.manualStaffOptions)return;
    const query=String(el.manualStaffSearch?.value||"").trim().toLowerCase();
    const rows=(state.manualStaffCandidates||[]).filter(row=>
      !query || `${row.display_name} ${row.planned_position_label||""} ${row.planned_shift_code||""}`.toLowerCase().includes(query)
    );

    if(!rows.length){
      el.manualStaffOptions.innerHTML='<div class="sorting-today-empty">No matching staff available.</div>';
      return;
    }

    el.manualStaffOptions.innerHTML=rows.map(row=>{
      const statusMap={
        SAME_SHIFT_OTHER_POSITION:"Planned elsewhere",
        SAME_SHIFT_NON_WORKING:"Not working in plan",
        OTHER_SHIFT:"Other shift",
        NOT_PLANNED:"Not planned"
      };
      return `<button class="sorting-manual-staff-option" type="button" data-add-manual-staff="${esc(row.staff_id)}"${row.already_actual_sorting?" disabled":""}>
        <span><strong>${esc(row.display_name)}</strong>
          <small>${esc(row.planned_shift_code||"No shift")} · ${esc(plannedPositionLabel(row))}${row.planned_day_status?` · ${esc(titleCode(row.planned_day_status))}`:""}</small>
        </span>
        <em>${row.already_actual_sorting?"Already in Sorting":esc(statusMap[row.candidate_status]||"Manual")}</em>
      </button>`;
    }).join("");
  }

  async function loadManualStaffCandidates(){
    const data=await rpc("get_sorting_manual_staff_candidates",{p_shift_code:state.shift});
    state.manualStaffCandidates=Array.isArray(data?.candidates)?data.candidates:[];
    renderManualStaffCandidates();
  }

  async function openManualStaffDialog(){
    try{
      setMessage("Loading staff candidates…");
      await loadManualStaffCandidates();
      el.manualStaffSearch.value="";
      renderManualStaffCandidates();
      el.manualStaffDialog.showModal();
      setMessage("");
      setTimeout(()=>el.manualStaffSearch.focus(),40);
    }catch(error){
      console.error(error);setMessage(friendly(error),"error");
    }
  }

  async function addManualStaff(staffId,button){
    button.disabled=true;
    const accepted=confirm("Add this person to Sorting Actual staffing? The published Roster will not be changed.");
    if(!accepted){button.disabled=false;return;}
    try{
      const result=await rpc("add_sorting_actual_staff",{
        p_shift_code:state.shift,
        p_staff_id:staffId,
        p_notes:"Manual operational position change."
      });
      el.manualStaffDialog.close();
      await loadStaffWork();
      setMessage(result?.message||"Staff added to Sorting Actual staffing.","success");
    }catch(error){
      console.error(error);setMessage(friendly(error),"error");button.disabled=false;
    }
  }

  async function cancelManualStaff(sessionId){
    const accepted=confirm("Remove this manual Actual position from Sorting? The history will be preserved as Cancelled.");
    if(!accepted)return;
    try{
      const result=await rpc("cancel_sorting_actual_staff",{
        p_work_session_id:sessionId,
        p_reason:"Cancelled from Sorting workstation."
      });
      await loadStaffWork();
      setMessage(result?.message||"Manual position cancelled.","success");
    }catch(error){
      console.error(error);setMessage(friendly(error),"error");
    }
  }

  async function loadStaffWork(){
    state.staffWork=await rpc("get_sorting_staff_dashboard_context_v2",{p_shift_code:state.shift});
    renderStaffWork();
    renderReference();
  }

  function renderNoWorkDialogMode(){
    const action=el.attendanceForm.querySelector('input[name="sortingNoWorkAction"]:checked')?.value||"";
    if(el.absencePanel)el.absencePanel.hidden=action!=="ABSENT";
    if(el.moveAreaPanel)el.moveAreaPanel.hidden=action!=="MOVE";
    if(el.attendanceSave){
      el.attendanceSave.textContent=action==="MOVE"?"Move to Finish":"Save Actual status";
    }
    el.attendanceMessage.textContent="";
  }

  async function loadNoWorkOptions(){
    if(state.noWorkOptions)return state.noWorkOptions;
    state.noWorkOptions=await rpc("get_sorting_staff_no_work_options",{});
    return state.noWorkOptions;
  }

  async function openAttendanceDialog(staffId){
    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId);
    if(!row)return;
    state.attendanceStaffId=staffId;
    el.attendanceTitle.textContent=`No Work — ${row.display_name}`;
    el.attendanceHint.textContent="Why will this person not work in Sorting? The published Roster will not change.";
    el.attendanceNotes.value="";
    el.attendanceMessage.textContent="";
    el.attendanceForm.querySelectorAll('input[name="sortingNoWorkAction"], input[name="sortingAttendanceReason"]').forEach(input=>{input.checked=false;});
    if(el.absencePanel)el.absencePanel.hidden=true;
    if(el.moveAreaPanel)el.moveAreaPanel.hidden=true;
    if(el.moveAreaSelect)el.moveAreaSelect.innerHTML='<option value="">Loading Finish Tables...</option>';
    el.attendanceDialog.showModal();

    try{
      const options=await loadNoWorkOptions();
      const tables=Array.isArray(options?.finish_tables)?options.finish_tables:[];
      if(el.moveAreaSelect){
        el.moveAreaSelect.innerHTML='<option value="">Choose Finish Table...</option>'+tables
          .map(table=>`<option value="${esc(table.station_code)}">${esc(table.station_name)}</option>`).join("");
      }
    }catch(error){
      console.error(error);
      el.attendanceMessage.textContent=friendly(error);
      if(el.moveAreaSelect)el.moveAreaSelect.innerHTML='<option value="">Unable to load Finish Tables</option>';
    }
  }

  async function saveNoWorkStatus(){
    const staffId=state.attendanceStaffId;
    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId);
    if(!row)return;
    const action=el.attendanceForm.querySelector('input[name="sortingNoWorkAction"]:checked')?.value||"";
    const notes=el.attendanceNotes.value.trim();

    if(!action){
      el.attendanceMessage.textContent="Choose Not working in Sorting or Moved to Finish.";
      return;
    }

    el.attendanceSave.disabled=true;
    try{
      let result;
      if(action==="ABSENT"){
        const reason=el.attendanceForm.querySelector('input[name="sortingAttendanceReason"]:checked')?.value||"";
        if(!reason){
          el.attendanceMessage.textContent="Choose Sick, No show, Training or Other.";
          return;
        }
        if(reason==="OTHER"&&!notes){
          el.attendanceMessage.textContent="Add a short note when choosing Other.";
          return;
        }
        el.attendanceMessage.textContent="Saving Actual staffing status…";
        result=await rpc("set_sorting_staff_attendance",{
          p_shift_code:state.shift,
          p_staff_id:staffId,
          p_attendance_status:"ABSENT",
          p_absence_reason:reason,
          p_notes:notes||null
        });
      }else{
        const tableCode=el.moveAreaSelect?.value||"";
        if(!tableCode){
          el.attendanceMessage.textContent="Choose the Finish Table where this staff member will work.";
          return;
        }
        el.attendanceMessage.textContent="Saving Actual Finish transfer...";
        result=await rpc("move_sorting_staff_to_finish_table_v1",{
          p_shift_code:state.shift,
          p_staff_id:staffId,
          p_target_table_code:tableCode,
          p_notes:notes||null
        });
      }

      el.attendanceDialog.close();
      state.attendanceStaffId=null;
      if(state.editingStaffId===staffId)state.editingStaffId=null;
      await loadStaffWork();
      setMessage(result?.message||`${row.display_name} Actual staffing updated.`,"success");
    }catch(error){
      console.error(error);
      el.attendanceMessage.textContent=friendly(error);
    }finally{
      el.attendanceSave.disabled=false;
      renderNoWorkDialogMode();
    }
  }

  async function returnStaffToSorting(staffId){
    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId);
    if(!row)return;
    const accepted=confirm(`Return ${row.display_name} to Sorting Actual staffing? The published Roster will not change.`);
    if(!accepted)return;
    try{
      const restoreRpc=String(row.actual_area_code||"").toUpperCase()==="FINISH"
        ? "restore_sorting_staff_from_finish_table_v1"
        : "restore_sorting_staff_actual_area";
      const result=await rpc(restoreRpc,{
        p_shift_code:state.shift,
        p_staff_id:staffId,
        p_reason:"Actual area transfer reversed from Sorting workstation."
      });
      await loadStaffWork();
      setMessage(result?.message||`${row.display_name} returned to Sorting.`,"success");
    }catch(error){
      console.error(error);setMessage(friendly(error),"error");
    }
  }

  async function markStaffPresent(staffId){
    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId);
    if(!row)return;
    const accepted=confirm(`Return ${row.display_name} to normal Sorting attendance? Use this to correct Sick, No show, Training or Other.`);
    if(!accepted)return;
    try{
      const result=await rpc("set_sorting_staff_attendance",{
        p_shift_code:state.shift,
        p_staff_id:staffId,
        p_attendance_status:"PRESENT",
        p_absence_reason:null,
        p_notes:"Sorting availability corrected from the Sorting workstation."
      });
      await loadStaffWork();
      setMessage(result?.message||`${row.display_name} marked present.`,"success");
    }catch(error){
      console.error(error);setMessage(friendly(error),"error");
    }
  }

  async function changeSortingWorkMode(staffId,workMode){
    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId);
    if(!row)return;
    const isMop=workMode==="MOP";
    const promptText=isMop
      ? `Why is ${row.display_name} changing to MOP? The current Actual MOP, if any, will automatically change to Clothes.`
      : `Why is ${row.display_name} changing from MOP to Clothes? This may leave the shift with no dedicated Actual MOP.`;
    const reason=prompt(promptText);
    if(reason===null)return;
    if(!reason.trim())return setMessage("A reason is required for a MOP/Clothes change.","error");
    try{
      setMessage(`Saving ${row.display_name} as ${workMode==="MOP"?"MOP":"Clothes"}…`);
      const result=await rpc("set_sorting_staff_work_mode",{
        p_shift_code:state.shift,
        p_staff_id:staffId,
        p_work_mode:workMode,
        p_reason:reason.trim()
      });
      await loadStaffWork();
      setMessage(result?.message||"Sorting work mode updated and recorded.","success");
    }catch(error){
      console.error(error);setMessage(friendly(error),"error");
    }
  }

  async function saveStaffWork(staffId, button){
    const card=button.closest("[data-staff-work]");
    const get=(name)=>card.querySelector(`[data-work-field="${name}"]`);
    const start=get("start").value;
    const end=get("end").value;
    const breakMinutes=Number(get("break")?.value||0);
    const awayEnabled=Boolean(get("away-enabled")?.checked);
    const awayHours=awayEnabled?Number(get("away-hours").value||0):0;
    const awayMinutes=awayEnabled?Number(get("away-minutes").value||0):0;
    const away=(awayHours*60)+awayMinutes;
    const reason=awayEnabled?get("reason").value:"NONE";
    const notes=get("notes").value.trim();

    if(!start||!end)return setMessage("Started at and Leaving at are required.","error");
    if(!Number.isInteger(breakMinutes)||breakMinutes<0||breakMinutes>240)return setMessage("Break must be a whole number from 0 to 240 minutes.","error");
    if(awayEnabled&&(!Number.isInteger(awayHours)||awayHours<0||awayHours>12))return setMessage("Time away hours must be between 0 and 12.","error");
    if(awayEnabled&&(!Number.isInteger(awayMinutes)||awayMinutes<0||awayMinutes>59))return setMessage("Time away minutes must be between 0 and 59.","error");
    if(awayEnabled&&away<=0)return setMessage("Enter how long the staff member was away, or turn off Time away.","error");
    if(awayEnabled&&reason==="NONE")return setMessage("Choose why the staff member was away.","error");
    if(awayEnabled&&reason==="OTHER"&&!notes)return setMessage("Add a short note when Time away reason is Other.","error");

    const [startHour,startMinute]=start.split(":").map(Number),[endHour,endMinute]=end.split(":").map(Number);let grossMinutes=(endHour*60+endMinute)-(startHour*60+startMinute);if(grossMinutes<0)grossMinutes+=1440;
    if(grossMinutes<=0)return setMessage("Leaving at must be later than Started at.","error");
    if(grossMinutes>780)return setMessage("A staff shift cannot be longer than 13 hours.","error");
    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId),workedMinutes=Math.max(0,grossMinutes-breakMinutes-away);
    if(!window.confirm(`Confirm staff time\n\n${row?.display_name||"Staff"}\nStarted: ${start}\nLeaving: ${end}\nBreak: ${breakMinutes} min\nTime away: ${away} min\nWorked: ${minutesToLabel(workedMinutes)}\n\nSave these changes?`))return;

    button.disabled=true;button.textContent="Saving…";setMessage("Saving actual Started/Leaving time…");
    try{
      const result=await rpc("save_sorting_staff_work_adjustment",{
        p_shift_code:state.shift,
        p_staff_id:staffId,
        p_actual_start_time:start,
        p_actual_end_time:end,
        p_extra_non_work_minutes:away,
        p_adjustment_reason:reason,
        p_notes:notes||null
      });
      await rpc("set_sorting_staff_break_v1",{p_shift_code:state.shift,p_staff_id:staffId,p_break_minutes:breakMinutes});
      state.editingStaffId=null;
      document.getElementById("sortingStaffTimeDialog")?.close();
      await loadStaffWork();
      setMessage(result?.message||"Worked-time adjustment saved.","success");
    }catch(error){
      console.error(error);setMessage(friendly(error),"error");
      button.disabled=false;button.textContent="Save adjustment";
    }
  }

  async function saveStaffActual(staffId, button){
    const card=button.closest("[data-staff-work]");
    const get=(name)=>card.querySelector(`[data-work-field="${name}"]`);
    const start=get("start")?.value;
    const end=get("end")?.value;
    const closeShift=Boolean(get("close-shift")?.checked);
    const breakMinutes=Number(get("break")?.value||0);
    const away=Number(card.dataset.existingAway||0);
    const reason=away>0?String(card.dataset.existingReason||"OTHER"):"NONE";
    const position=get("position")?.value||String(card.dataset.existingMode||"CLOTHES");
    const previousPosition=String(card.dataset.existingMode||"CLOTHES");
    const notes=get("notes")?.value.trim()||"";
    const show=(message,type="error")=>{
      const target=card.querySelector("[data-staff-time-message]");
      if(target){target.textContent=message;target.className=`sorting-staff-time-message ${type}`;}
      setMessage(message,type);
    };

    if(!start)return show("Started at is required.");
    if(closeShift&&!end)return show("Leaving at is required when closing the shift.");
    if(!Number.isInteger(breakMinutes)||breakMinutes<0||breakMinutes>240)return show("Break must be a whole number from 0 to 240 minutes.");
    if(position!==previousPosition&&!notes)return show("Add a note or reason when changing the Actual Position.");

    let workedLabel="Open shift";
    if(closeShift){
      const [startHour,startMinute]=start.split(":").map(Number);
      const [endHour,endMinute]=end.split(":").map(Number);
      let grossMinutes=(endHour*60+endMinute)-(startHour*60+startMinute);
      if(grossMinutes<0)grossMinutes+=1440;
      if(grossMinutes<=0)return show("Leaving at must be later than Started at.");
      if(grossMinutes>780)return show("A staff shift cannot be longer than 13 hours.");
      workedLabel=minutesToLabel(Math.max(0,grossMinutes-breakMinutes-away));
    }

    const row=(state.staffWork?.staff||[]).find(item=>item.staff_id===staffId);
    if(!window.confirm(`Confirm staff actual\n\n${row?.display_name||"Staff"}\nActual Position: ${position==="MOP"?"MOP":"Clothes"}\nStarted: ${start}\nLeaving: ${closeShift?end:"Open shift"}\nBreak: ${breakMinutes} min\nWorked: ${workedLabel}\n\nSave these changes?`))return;

    button.disabled=true;
    button.textContent="Saving...";
    show("Saving staff actual...","info");
    try{
      const result=await rpc("save_sorting_staff_actual_v3",{
        p_shift_code:state.shift,
        p_staff_id:staffId,
        p_actual_start_time:start,
        p_actual_end_time:end||null,
        p_keep_open:!closeShift,
        p_extra_non_work_minutes:away,
        p_adjustment_reason:reason,
        p_notes:notes||null
      });
      await rpc("set_sorting_staff_break_v1",{p_shift_code:state.shift,p_staff_id:staffId,p_break_minutes:breakMinutes});
      if(position!==previousPosition){
        await rpc("set_sorting_staff_work_mode",{p_shift_code:state.shift,p_staff_id:staffId,p_work_mode:position,p_reason:notes});
      }
      state.editingStaffId=null;
      document.getElementById("sortingStaffTimeDialog")?.close();
      await loadStaffWork();
      setMessage(result?.message||"Staff actual saved.","success");
    }catch(error){
      console.error(error);
      show(friendly(error),"error");
      button.disabled=false;
      button.textContent="Save Staff Actual";
    }
  }

  // Trolley Reception Kiosk — touch-first physical receipt + Production Flow.
  const trolleyBoard=()=>Array.isArray(state.sorting?.board)?state.sorting.board:[];
  const trolleyRecent=()=>Array.isArray(state.sorting?.recent_intakes)?state.sorting.recent_intakes:[];
  const FOUR_HOURS_MS=4*60*60*1000;

  function recentDuplicateTrolleyReceipt(code){
    const normalized=String(code||"").trim().toUpperCase();
    if(!normalized)return null;
    const now=Date.now();
    return trolleyRecent().find(row=>{
      if(String(row.arrival_mode||"").toUpperCase()==="NO_TROLLEY")return false;
      if(String(row.record_status||"RECORDED").toUpperCase()==="CANCELLED")return false;
      if(String(row.trolley_code||"").trim().toUpperCase()!==normalized)return false;
      const arrived=new Date(row.arrived_at).getTime();
      return Number.isFinite(arrived)&&now-arrived>=0&&now-arrived<FOUR_HOURS_MS;
    })||null;
  }

  function duplicateTrolleyMessage(row){
    const when=fmtTime(row?.arrived_at);
    const staff=row?.operator_name?` by ${row.operator_name}`:"";
    return `This trolley was already scanned in this shift at ${when}${staff}. Use Edit/Remove on the existing receipt, or wait 4 hours before scanning it again.`;
  }

  function trolleyOperatorRows(){
    return operatorStaff().filter(row=>row.attendance_status!=="ABSENT");
  }

  function renderTrolleyStaffBar(){
    if(!el.trolleyStaffBar)return;
    const rows=trolleyOperatorRows();
    if(state.trolleyOperatorStaffId&&!rows.some(row=>row.staff_id===state.trolleyOperatorStaffId)){
      state.trolleyOperatorStaffId=null;
    }
    if(!rows.length){
      el.trolleyStaffBar.innerHTML='<span class="sorting-reception-no-staff">No Sorting staff available for this shift.</span>';
      updateTrolleyScanGate();
      return;
    }
    el.trolleyStaffBar.innerHTML=rows.map(row=>{
      const active=row.staff_id===state.trolleyOperatorStaffId;
      const initials=String(row.display_name||"").trim().split(/\s+/).slice(0,2).map(v=>v[0]||"").join("").toUpperCase();
      return `<button type="button" class="sorting-reception-staff-chip${active?" active":""}" data-reception-staff="${esc(row.staff_id)}">
        <span class="sorting-reception-avatar">${esc(initials||"?")}</span>
        <span><strong>${esc(row.display_name)}</strong><small>${row.work_mode==="MOP"?"MOP":"Clothes"}</small></span>
      </button>`;
    }).join("");
    updateTrolleyScanGate();
  }

  function selectTrolleyStaff(staffId){
    if(!trolleyOperatorRows().some(row=>row.staff_id===staffId))return;
    state.trolleyOperatorStaffId=staffId;
    if(state.trolleyDraft)state.trolleyDraft.operator_staff_id=staffId;
    renderTrolleyStaffBar();
    renderTrolleyResult();
  }

  function trolleySelectedOperator(){
    return trolleyOperatorRows().find(row=>row.staff_id===state.trolleyOperatorStaffId)||null;
  }

  function trolleyOperatorRequiredMessage(){
    return "Only active Sorting staff can save trolley receipts. Sign in with the Sorting account and select your name in RECEIVING AS.";
  }

  function updateTrolleyScanGate(){
    if(!el.trolleyScanTitle)return;
    const operator=trolleySelectedOperator();
    const staffbar=el.trolleyStaffBar?.closest('.sorting-reception-staffbar');
    if(el.trolleyStaffPrompt)el.trolleyStaffPrompt.hidden=Boolean(operator);
    staffbar?.classList.toggle('needs-selection',!operator);
    if(operator){
      el.trolleyScanTitle.textContent="Scan the trolley";
      el.trolleyScanHint.textContent=`Receiving as ${operator.display_name} · point the scanner at the barcode`;
      el.trolleyScanIdle?.classList.remove("staff-required");
    }else{
      el.trolleyScanTitle.textContent="Step 1 · Select your name";
      el.trolleyScanHint.textContent="Choose your name in RECEIVING AS above. Scanning unlocks immediately after selection.";
      el.trolleyScanIdle?.classList.add("staff-required");
    }
  }

  function promptTrolleyStaffSelection(message="Select your name in RECEIVING AS before scanning."){
    setMessage(message,"warning");
    const staffbar=el.trolleyStaffBar?.closest('.sorting-reception-staffbar');
    if(!staffbar)return;
    staffbar.classList.remove('attention');
    void staffbar.offsetWidth;
    staffbar.classList.add('attention');
    staffbar.scrollIntoView({behavior:'smooth',block:'center'});
    setTimeout(()=>staffbar.classList.remove('attention'),1800);
  }

  function paintTrolleyScanBuffer(){
    if(!el.trolleyScanBuffer)return;
    const value=state.trolleyScanBuffer;
    el.trolleyScanBuffer.classList.toggle("live",Boolean(value));
    el.trolleyScanBuffer.innerHTML=value
      ? `${esc(value)}<span class="sorting-reception-caret"></span>`
      : '<span class="sorting-reception-scan-placeholder">T_____T</span>';
  }

  function clearTrolleyScanBuffer(){
    state.trolleyScanBuffer="";
    if(state.trolleyScanTimer)clearTimeout(state.trolleyScanTimer);
    state.trolleyScanTimer=null;
    paintTrolleyScanBuffer();
  }

  function receptionDialogOpen(){
    return Boolean(document.querySelector("dialog[open]"));
  }

  function receptionTypingTarget(target){
    return Boolean(target?.closest?.("input,textarea,select,[contenteditable='true']"));
  }

  function handleTrolleyScannerKey(e){
    if(state.view!=="trolley"||state.busy||receptionDialogOpen()||receptionTypingTarget(e.target))return;
    if(e.key==="Escape"){
      clearTrolleyScanBuffer();
      if(state.trolley)resetTrolleyScan();
      return;
    }
    if(e.key==="Enter"){
      if(state.trolleyScanBuffer){
        const code=state.trolleyScanBuffer;
        clearTrolleyScanBuffer();
        lookupTrolley(code);
      }
      return;
    }
    if(e.key==="Backspace"){
      state.trolleyScanBuffer=state.trolleyScanBuffer.slice(0,-1);
      paintTrolleyScanBuffer();
      return;
    }
    if(e.key.length!==1||e.ctrlKey||e.metaKey||e.altKey)return;
    const ch=e.key.toUpperCase();
    if(!/[A-Z0-9]/.test(ch))return;
    state.trolleyScanBuffer=(state.trolleyScanBuffer+ch).slice(-40);
    paintTrolleyScanBuffer();
    if(state.trolleyScanTimer)clearTimeout(state.trolleyScanTimer);
    state.trolleyScanTimer=setTimeout(clearTrolleyScanBuffer,3000);
  }

  function trolleyScheduleRows(customerId){
    return trolleyBoard().filter(row=>row.customer_id===customerId);
  }

  function trolleyScheduleRowsForDate(customerId,date){
    return trolleyScheduleRows(customerId).filter(row=>row.scheduled_for_date===date);
  }

  function trolleyDefaultDate(customerId){
    const rows=trolleyScheduleRows(customerId);
    return rows.find(row=>row.day_relation==="TODAY")
      || rows.find(row=>row.day_relation==="TOMORROW")
      || rows.filter(row=>Number(row.day_offset||0)>1).sort((a,b)=>a.day_offset-b.day_offset)[0]
      || rows.find(row=>row.day_relation==="YESTERDAY")
      || null;
  }

  function chooseDefaultTrolleyProducts(customerId,date){
    const rows=date?trolleyScheduleRowsForDate(customerId,date):[];
    const available=[...new Set(rows.map(row=>row.product_code))];
    if(available.length===1)return available;
    const mode=trolleySelectedOperator()?.work_mode;
    if(available.length>1&&mode&&available.includes(mode))return [mode];
    if(!date&&mode)return [mode==="MOP"?"MOP":"CLOTHES"];
    return [];
  }

  function initTrolleyDraft(customerId){
    const defaultRow=customerId?trolleyDefaultDate(customerId):null;
    const date=defaultRow?.scheduled_for_date||null;
    state.trolleyDraft={
      operator_staff_id:state.trolleyOperatorStaffId,
      customer_id:customerId||"",
      scheduled_for_date:date,
      off_schedule:!date,
      contents_status:"CONTENTS",
      product_codes:chooseDefaultTrolleyProducts(customerId,date),
      customer_override_reason:"",
      off_schedule_reason:date?"":"NOT_ON_PUBLISHED_SCHEDULE",
      notes:""
    };
  }

  function setTrolleyCustomer(customerId,date=null,productCode=null){
    if(!state.trolley)return;
    const old=state.trolleyDraft||{};
    const row=date?trolleyScheduleRowsForDate(customerId,date).find(r=>!productCode||r.product_code===productCode):null;
    const defaultRow=row||trolleyDefaultDate(customerId);
    const chosenDate=date||defaultRow?.scheduled_for_date||null;
    state.trolleyDraft={
      ...old,
      operator_staff_id:state.trolleyOperatorStaffId,
      customer_id:customerId,
      scheduled_for_date:chosenDate,
      off_schedule:!chosenDate,
      product_codes:productCode?[productCode]:chooseDefaultTrolleyProducts(customerId,chosenDate),
      customer_override_reason:"",
      off_schedule_reason:chosenDate?"":"NOT_ON_PUBLISHED_SCHEDULE"
    };
    renderTrolleyResult();
    renderTrolleySidebar();
  }

  function trolleyRelation(customerId,date){
    if(!date)return "OFF_SCHEDULE";
    return trolleyScheduleRowsForDate(customerId,date)[0]?.day_relation||"OFF_SCHEDULE";
  }

  function trolleyDateButtons(){
    const d=state.trolleyDraft;
    if(!d?.customer_id)return "";
    const dates=[...new Map(trolleyScheduleRows(d.customer_id).map(row=>[row.scheduled_for_date,row])).values()]
      .sort((a,b)=>{
        const priority=row=>{
          if(row.day_relation==="TODAY")return 0;
          if(row.day_relation==="TOMORROW")return 1;
          if(Number(row.day_offset||0)>1)return 2;
          if(row.day_relation==="YESTERDAY")return 3;
          return 4;
        };
        return priority(a)-priority(b)||Number(a.day_offset||0)-Number(b.day_offset||0);
      });
    if(!dates.length){
      return `<div class="sorting-reception-offschedule">
        <strong>Not on Yesterday / Today / Tomorrow schedule</strong>
        <span>This can still be received. It will be recorded as an exception without inventing a scheduled date.</span>
      </div>`;
    }
    const primaryDates=dates.filter(row=>row.day_relation!=="YESTERDAY");
    const lateDates=dates.filter(row=>row.day_relation==="YESTERDAY");
    const mainDates=primaryDates.length?primaryDates:lateDates;
    const lateHtml=primaryDates.length&&lateDates.length
      ? `<div class="sorting-reception-late-date-row">
          <span>1 day late</span>
          ${lateDates.map(row=>`<button type="button" class="sorting-reception-date-button ${row.day_relation.toLowerCase()} secondary${d.scheduled_for_date===row.scheduled_for_date?" active":""}" data-reception-date="${esc(row.scheduled_for_date)}">
            <span>${esc(row.day_relation)}</span><strong>${esc(fullDayDate(row.scheduled_for_date))}</strong>
          </button>`).join("")}
        </div>`
      : "";
    return `<div class="sorting-reception-date-row">${mainDates.map(row=>
      `<button type="button" class="sorting-reception-date-button ${row.day_relation.toLowerCase()}${d.scheduled_for_date===row.scheduled_for_date?" active":""}" data-reception-date="${esc(row.scheduled_for_date)}">
        <span>${esc(row.day_relation)}</span><strong>${esc(fullDayDate(row.scheduled_for_date))}</strong>
      </button>`).join("")}</div>${lateHtml}`;
  }

  function trolleyProductButtons(){
    const d=state.trolleyDraft;
    if(!d?.customer_id)return "";
    const rows=d.scheduled_for_date?trolleyScheduleRowsForDate(d.customer_id,d.scheduled_for_date):[];
    const available=d.scheduled_for_date?[...new Set(rows.map(row=>row.product_code))]:["CLOTHES","MOP"];
    const chosen=d.product_codes||[];
    const buttons=[];
    if(available.includes("CLOTHES"))buttons.push(["CLOTHES","CLOTHES"]);
    if(available.includes("MOP"))buttons.push(["MOP","MOP"]);
    if(available.includes("CLOTHES")&&available.includes("MOP"))buttons.push(["BOTH","CLOTHES + MOP"]);
    return `<div class="sorting-reception-option-row">${buttons.map(([code,label])=>{
      const active=code==="BOTH"?chosen.length===2:chosen.length===1&&chosen[0]===code;
      return `<button type="button" class="sorting-reception-option${active?" active":""}" data-reception-product="${code}">${label}</button>`;
    }).join("")}</div>`;
  }

  function trolleyMismatchButtons(){
    const p=state.trolley,d=state.trolleyDraft;
    const tracked=p?.custody;
    const mismatch=tracked?.customer_id&&d?.customer_id&&tracked.customer_id!==d.customer_id;
    if(!mismatch)return "";
    return `<div class="sorting-reception-exception">
      <strong>Why is the contents/customer different from the tracked trolley stay?</strong>
      <div class="sorting-reception-option-row">
        <button type="button" class="sorting-reception-option warning${d.customer_override_reason==="TROLLEY_CHANGED_BEFORE_SCAN"?" active":""}" data-reception-mismatch="TROLLEY_CHANGED_BEFORE_SCAN">Trolley changed before scan</button>
        <button type="button" class="sorting-reception-option warning${d.customer_override_reason==="CONTENTS_CUSTOMER_CONFIRMED_DIFFERENT"?" active":""}" data-reception-mismatch="CONTENTS_CUSTOMER_CONFIRMED_DIFFERENT">Customer/content confirmed different</button>
      </div>
    </div>`;
  }

  function trolleyOffScheduleButtons(){
    const d=state.trolleyDraft;
    if(!d?.off_schedule)return "";
    const opts=[
      ["NOT_ON_PUBLISHED_SCHEDULE","Not on published schedule"],
      ["SPECIAL_PRODUCTION","Special production"],
      ["SCHEDULE_DATA_ISSUE","Schedule data issue"]
    ];
    return `<div class="sorting-reception-exception">
      <strong>Why is this off schedule?</strong>
      <div class="sorting-reception-option-row">${opts.map(([code,label])=>
        `<button type="button" class="sorting-reception-option warning${d.off_schedule_reason===code?" active":""}" data-reception-offschedule="${code}">${label}</button>`).join("")}</div>
    </div>`;
  }

  function trolleySaveReady(){
    const d=state.trolleyDraft,p=state.trolley;
    if(!p||!d||!state.trolleyOperatorStaffId||!d.customer_id||!d.contents_status||!d.product_codes.length)return false;
    if(!d.off_schedule&&!d.scheduled_for_date)return false;
    if(d.off_schedule&&!d.off_schedule_reason)return false;
    const tracked=p.custody;
    if(tracked?.customer_id&&tracked.customer_id!==d.customer_id&&!d.customer_override_reason)return false;
    return true;
  }

  function trolleyReceiptPayloadFrom(preview,draft,operatorStaffId){
    return {
      p_shift_code:state.shift,
      p_trolley_code:preview?.trolley?.trolley_code,
      p_operator_staff_id:operatorStaffId,
      p_customer_id:draft.customer_id,
      p_contents_status:draft.contents_status,
      p_scheduled_for_date:draft.off_schedule?null:draft.scheduled_for_date,
      p_product_codes:[...(draft.product_codes||[])],
      p_customer_override_reason:draft.customer_override_reason||null,
      p_off_schedule_reason:draft.off_schedule_reason||null,
      p_notes:null
    };
  }

  function basketLabel(item){
    const payload=item?.payload||{};
    const customer=allCustomers().find(c=>c.customer_id===payload.p_customer_id);
    return {
      trolley:payload.p_trolley_code||item?.trolley_code||"Trolley",
      customer:customer?.customer_name||item?.customer_name||"Customer",
      date:payload.p_scheduled_for_date?shortDayDate(payload.p_scheduled_for_date):"Off schedule",
      product:(payload.p_product_codes||[]).join(" + ")||"Product",
      contents:payload.p_contents_status==="EMPTY"?"EMPTY":"CONTENTS",
      operator:trolleyOperatorRows().find(s=>s.staff_id===payload.p_operator_staff_id)?.display_name||item?.operator_name||"Staff"
    };
  }

  function renderTrolleyOutboxStatus(){
    if(!el.trolleyOutboxStatus)return;
    const count=outboxRows().length;
    el.trolleyOutboxStatus.textContent=count?`${count} confirmed receipt${count===1?"":"s"} waiting to send`:"All confirmed receipts sent";
    el.trolleyOutboxStatus.classList.toggle("pending",count>0);
  }

  function renderTrolleyBasket(){
    if(!el.trolleyBasketPanel)return;
    const count=state.trolleyBasket.length;
    el.trolleyBasketPanel.hidden=!state.trolleyBatchMode&&!count;
    el.trolleyBatchToggle?.classList.toggle("active",state.trolleyBatchMode);
    if(el.trolleyBatchToggle)el.trolleyBatchToggle.textContent=state.trolleyBatchMode?"Scan list mode on":"Scan list mode";
    if(el.trolleyBasketCount)el.trolleyBasketCount.innerHTML=`<span><b>${count}</b> pending</span>`;
    if(el.trolleyBasketConfirm)el.trolleyBasketConfirm.disabled=!count||state.busy;
    if(el.trolleyBasketClear)el.trolleyBasketClear.disabled=!count||state.busy;
    if(!el.trolleyBasketList)return;
    el.trolleyBasketList.innerHTML=count?state.trolleyBasket.map(item=>{
      const label=basketLabel(item);
      return `<article class="sorting-reception-basket-item" data-basket-id="${esc(item.id)}">
        <div><strong>${esc(label.trolley)}</strong><small>${esc(label.contents)} · ${esc(label.operator)}</small></div>
        <div><strong>${esc(label.customer)}</strong><small>${esc(label.date)} · ${esc(label.product)}</small></div>
        <button type="button" class="sorting-secondary-button" data-basket-edit="${esc(item.id)}">Review</button>
        <button type="button" class="sorting-secondary-button" data-basket-remove="${esc(item.id)}">Remove</button>
      </article>`;
    }).join(""):'<div class="sorting-empty">No trolley receipts waiting for confirmation.</div>';
  }

  function addCurrentTrolleyToBasket(){
    if(!trolleySaveReady()||state.trolley?.blocked)return;
    const payload=trolleyReceiptPayloadFrom(state.trolley,state.trolleyDraft,state.trolleyOperatorStaffId);
    const existing=state.trolleyBasket.find(item=>String(item.payload?.p_trolley_code||"").toUpperCase()===String(payload.p_trolley_code||"").toUpperCase());
    if(existing){setMessage(`${payload.p_trolley_code} is already in the review list.`,"warning");return;}
    const item={
      id:outboxId(),
      created_at:new Date().toISOString(),
      preview:typeof structuredClone==="function"?structuredClone(state.trolley):JSON.parse(JSON.stringify(state.trolley)),
      draft:typeof structuredClone==="function"?structuredClone(state.trolleyDraft):JSON.parse(JSON.stringify(state.trolleyDraft)),
      payload,
      customer_name:allCustomers().find(c=>c.customer_id===payload.p_customer_id)?.customer_name||"",
      operator_name:trolleySelectedOperator()?.display_name||""
    };
    state.trolleyBasket.push(item);
    resetTrolleyScan();
    renderTrolleyBasket();
    setMessage(`${payload.p_trolley_code} added to review list. Scan the next trolley or confirm all.`,"success");
  }

  function enqueueTrolleyOutbox(payload,label){
    const row={id:outboxId(),created_at:new Date().toISOString(),attempts:0,payload,label};
    writeOutbox([...outboxRows(),row]);
    return row.id;
  }

  function removeTrolleyOutbox(id){
    writeOutbox(outboxRows().filter(row=>row.id!==id));
  }

  async function sendTrolleyPayload(payload,{outboxId:queuedId=null,label=null}={}){
    const id=queuedId||enqueueTrolleyOutbox(payload,label);
    try{
      const result=await rpc("record_sorting_trolley_intake_v2",payload);
      removeTrolleyOutbox(id);
      return result;
    }catch(error){
      const message=friendly(error);
      if(/already scanned in this shift/i.test(message)){
        removeTrolleyOutbox(id);
      }else if(isTransientSendError(message)){
        const rows=outboxRows().map(row=>row.id===id?{...row,attempts:Number(row.attempts||0)+1,last_error:message,last_attempt_at:new Date().toISOString()}:row);
        writeOutbox(rows);
      }else{
        removeTrolleyOutbox(id);
      }
      throw error;
    }
  }

  async function flushTrolleyOutbox({silent=false}={}){
    if(state.trolleyOutboxFlushing)return;
    const rows=outboxRows();
    if(!rows.length){renderTrolleyOutboxStatus();return;}
    state.trolleyOutboxFlushing=true;
    if(!silent)setMessage(`Sending ${rows.length} confirmed trolley receipt${rows.length===1?"":"s"}...`);
    try{
      for(const row of rows){
        try{await sendTrolleyPayload(row.payload,{outboxId:row.id,label:row.label});}
        catch(error){console.warn("Trolley outbox send failed",error);break;}
      }
      if(!outboxRows().length){
        await loadStaffWork();
        await loadSorting();
        if(!silent)setMessage("All confirmed trolley receipts sent.","success");
      }else if(!silent){
        setMessage(`${outboxRows().length} confirmed receipt${outboxRows().length===1?"":"s"} still waiting to send.`,"warning");
      }
    }finally{
      state.trolleyOutboxFlushing=false;
      renderTrolleyOutboxStatus();
    }
  }

  async function confirmTrolleyBasket(){
    if(!state.trolleyBasket.length||state.busy)return;
    state.busy=true;
    renderTrolleyBasket();
    setMessage(`Confirming ${state.trolleyBasket.length} trolley receipt${state.trolleyBasket.length===1?"":"s"}...`);
    const items=[...state.trolleyBasket];
    let saved=0;
    try{
      for(const item of items){
        const label=basketLabel(item);
        try{
          await sendTrolleyPayload(item.payload,{label});
          state.trolleyBasket=state.trolleyBasket.filter(row=>row.id!==item.id);
          saved+=1;
          renderTrolleyBasket();
        }catch(error){
          console.error(error);
          setMessage(`${label.trolley} could not be sent now. It is kept in the local send queue.`,"warning");
          state.trolleyBasket=state.trolleyBasket.filter(row=>row.id!==item.id);
        }
      }
      await loadStaffWork();
      await loadSorting();
      setMessage(`${saved} trolley receipt${saved===1?"":"s"} confirmed. ${outboxRows().length?`${outboxRows().length} waiting to resend.`:""}`.trim(),"success");
    }finally{
      state.busy=false;
      renderTrolleyBasket();
      renderTrolleyOutboxStatus();
    }
  }

  function otherProductReceipt(row){
    if(!row?.customer_id||!row?.scheduled_for_date||!row?.product_code)return null;
    return trolleyRecent().find(receipt=>{
      if(String(receipt.record_status||"RECORDED").toUpperCase()==="CANCELLED")return false;
      if(receipt.customer_id!==row.customer_id)return false;
      if(String(receipt.scheduled_for_date||"").slice(0,10)!==String(row.scheduled_for_date||"").slice(0,10))return false;
      if(String(receipt.contents_status||"").toUpperCase()==="EMPTY")return false;
      const codes=intakeProductCodes(receipt);
      return codes.length&&!codes.includes(row.product_code);
    })||null;
  }

  function renderTrolleyResult(){
    if(!el.trolleyPreview||!el.trolleyScanIdle)return;
    const p=state.trolley;
    updateTrolleyScanGate();
    if(!p){
      el.trolleyPreview.innerHTML="";
      return;
    }

    const t=p.trolley||{},d=state.trolleyDraft||{},custody=p.custody||{};
    const customer=allCustomers().find(c=>c.customer_id===d.customer_id);
    const relation=trolleyRelation(d.customer_id,d.scheduled_for_date);
    const dateRows=d.scheduled_for_date?trolleyScheduleRowsForDate(d.customer_id,d.scheduled_for_date):[];
    const routeNames=[...new Set(dateRows.map(r=>r.route_display_name||r.route_code).filter(Boolean))];
    const daysKnown=custody.days_at_customer!==null&&custody.days_at_customer!==undefined&&custody.days_at_customer!==""&&Number.isFinite(Number(custody.days_at_customer));
    const trackedMismatch=Boolean(custody.customer_id&&d.customer_id&&custody.customer_id!==d.customer_id);
    const blocked=Boolean(p.blocked);
    const operator=trolleySelectedOperator();
    const ready=trolleySaveReady()&&!blocked&&Boolean(operator);

    const alerts=[];
    if(custody.tracking_status==="MISSING_OUTBOUND_RECORD"){
      alerts.push(`<div class="sorting-reception-alert danger"><b>No outbound trolley record.</b> Finish/MOP may not have registered this trolley. Days out is unavailable; the gap will remain traceable.</div>`);
    }
    if(trackedMismatch){
      alerts.push(`<div class="sorting-reception-alert warning"><b>Tracked trolley stay ≠ confirmed contents customer.</b> Days out below belongs to ${esc(custody.customer_name||"the tracked customer")}, not ${esc(customer?.customer_name||"the selected customer")}.</div>`);
    }
    if(p.needs_review_if_confirmed){
      alerts.push(`<div class="sorting-reception-alert warning">This receipt will remain visible for review because trolley history is incomplete or mismatched.</div>`);
    }
    if(blocked){
      alerts.push(`<div class="sorting-reception-alert danger">${esc(p.message||"This trolley cannot be received.")}</div>`);
    }
    if(!operator){
      alerts.push(`<div class="sorting-reception-alert danger"><b>Sorting staff required.</b> ${esc(trolleyOperatorRequiredMessage())}</div>`);
    }

    el.trolleyPreview.innerHTML=`<article class="sorting-reception-result-card${blocked?" blocked":trackedMismatch||p.needs_review_if_confirmed?" warning":""}">
      <header class="sorting-reception-result-head">
        <div>
          <span class="sorting-reception-trolley-label">TROLLEY</span>
          <strong>${esc(t.trolley_code||"—")}</strong>
          <small>${esc(t.type_name||t.type_display_code||"")}</small>
        </div>
        <div class="sorting-reception-days${daysKnown?"":" unknown"}">
          <b>${daysKnown?Number(custody.days_at_customer):"?"}</b>
          <span>${daysKnown?"DAYS OUT":"DAYS OUT UNKNOWN"}</span>
        </div>
      </header>

      <div class="sorting-reception-result-body">
        <div class="sorting-reception-custody-line">
          <div><span>TRACKED TROLLEY STAY</span><strong>${esc(custody.customer_name||"No outbound record")}</strong><small>${custody.sent_on?`Sent ${esc(fmtDate(custody.sent_on))}`:"No sent date available"}</small></div>
          <div><span>AFTER CONFIRM</span><strong>AVAILABLE AT ELIS</strong><small>Free to be used for any next customer</small></div>
        </div>

        ${alerts.join("")}

        <section class="sorting-reception-step">
          <div class="sorting-reception-step-title"><b>1</b><div><strong>Customer / contents owner</strong><span>Tap the lateral list when possible.</span></div></div>
          <div class="sorting-reception-customer-line">
            <div><strong>${esc(customer?.customer_name||p.recommended_customer_name||"Choose customer")}</strong>
              <span>${routeNames.length?esc(routeNames.join(" · ")):""}</span>
            </div>
            <button type="button" class="sorting-secondary-button sorting-reception-other-customer" data-reception-other-customer>Other customer</button>
          </div>
        </section>

        <section class="sorting-reception-step date-focus">
          <div class="sorting-reception-step-title"><b>2</b><div><strong>Scheduled Date</strong><span>Check this carefully for daily customers.</span></div></div>
          ${trolleyDateButtons()}
          ${trolleyOffScheduleButtons()}
        </section>

        <section class="sorting-reception-step">
          <div class="sorting-reception-step-title"><b>3</b><div><strong>What is physically in the trolley?</strong></div></div>
          <div class="sorting-reception-option-row contents">
            <button type="button" class="sorting-reception-option big contents${d.contents_status==="CONTENTS"?" active":""}" data-reception-contents="CONTENTS">LAUNDRY INSIDE</button>
            <button type="button" class="sorting-reception-option big empty${d.contents_status==="EMPTY"?" active":""}" data-reception-contents="EMPTY">EMPTY TROLLEY</button>
          </div>
        </section>

        <section class="sorting-reception-step">
          <div class="sorting-reception-step-title"><b>4</b><div><strong>Product</strong></div></div>
          ${trolleyProductButtons()}
        </section>

        ${trolleyMismatchButtons()}

        <div class="sorting-reception-actions">
          <button type="button" class="sorting-secondary-button sorting-reception-cancel" data-reception-cancel>Cancel</button>
          <button type="button" class="sorting-primary-button sorting-reception-confirm" data-reception-confirm ${ready?"":"disabled"}>${state.trolleyBatchMode?"ADD TO REVIEW LIST":"CONFIRM RECEIPT"}</button>
        </div>
      </div>
    </article>`;
  }

  function trolleyRequirementSummary(row){
    const reqs=Array.isArray(row?.trolley_requirements)?row.trolley_requirements:[];
    if(row?.no_trolley_eligible)return "No trolley";
    if(!reqs.length){
      const total=Number(row?.planned_trolley_quantity||0);
      return total>0?`${total} trolley${total===1?"":"s"}`:"No trolley qty set";
    }
    return reqs.map(req=>{
      const code=req.display_code||req.trolley_type_code||"T";
      const qty=Number(req.quantity||0);
      return `${qty}×${code}${req.empty_trolley?" EMPTY":""}`;
    }).join(" · ");
  }

  function scannedTrolleySizeSummary(row){
    const trolleys=Array.isArray(row?.trolleys)?row.trolleys:[];
    if(!trolleys.length)return "";
    const counts=new Map();
    trolleys.forEach(t=>{
      const code=t.trolley_display_code||t.trolley_type_code||"T";
      counts.set(code,(counts.get(code)||0)+1);
    });
    return [...counts.entries()].map(([code,qty])=>`${qty}×${code}`).join(" · ");
  }

  function receptionRowState(row){
    if(Number(row.review_count||0)>0)return {label:"Review required",kind:"warning"};
    if(Number(row.wash_count||0)>0)return {label:`Washing recorded ${row.wash_count}x`,kind:"washed"};
    if(Number(row.no_trolley_arrival_count||0)>0)return {label:"Contents received · no trolley",kind:"received"};
    if(row.no_trolley_eligible)return {label:"No trolley · confirm contents arrival",kind:"pending"};
    if(row.operational_state==="NOTHING_TO_WASH")return {label:"Received empty · nothing to wash",kind:"empty"};
    if(Number(row.contents_count||0)>0)return {label:"Received · waiting wash",kind:"received"};
    if(Number(row.empty_count||0)>0)return {label:"Empty receipt recorded",kind:"empty"};
    return {label:"Waiting receipt",kind:"pending"};
  }

  function renderTrolleySidebar(){
    if(!el.trolleyTodayList)return;
    const rows=trolleyBoard();
    const todayRows=rows.filter(r=>r.day_relation==="TODAY");
    const tomorrowRows=rows.filter(r=>r.day_relation==="TOMORROW");
    const todayReceived=todayRows.filter(r=>Number((r.receipt_evidence_count??r.received_count)||0)>0).length;
    const todayTotal=todayRows.length;
    const pct=todayTotal?Math.round(todayReceived/todayTotal*100):0;
    const tomorrowStarted=tomorrowRows.some(r=>Number((r.receipt_evidence_count??r.received_count)||0)>0);
    const todayComplete=todayTotal>0&&todayRows.every(r=>{
      const planned=Number(r.planned_trolley_quantity||0);
      return r.operational_state==="NOTHING_TO_WASH"
        || Number((r.receipt_evidence_count??r.received_count)||0)>0
        || (planned>0&&Number(r.received_count||0)>=planned)
        || Number(r.wash_count||0)>0;
    });
    const showTomorrow=tomorrowStarted||todayComplete;

    el.trolleyTodayType.textContent=showTomorrow?"Today + next":"Today";
    el.trolleyTodayProgress.innerHTML=`<div class="sorting-progress-copy"><span>${todayReceived} of ${todayTotal} customers have receipt evidence</span><strong>${pct}%</strong></div>
      <div class="sorting-progress-track"><div class="sorting-progress-fill" style="width:${pct}%"></div></div>`;

    const renderDay=(dayRows,relation)=>{
      if(!dayRows.length)return "";
      const date=dayRows[0].scheduled_for_date;
      const relationLabel=relation==="TODAY"?"TODAY":"WORK AHEAD";
      return `<section class="sorting-board-day ${relation.toLowerCase()}">
        <div class="sorting-board-day-header">
          <div><strong>${esc(fullDayDate(date))}</strong><span>${relationLabel}</span></div>
          <b>${dayRows.filter(r=>Number((r.receipt_evidence_count??r.received_count)||0)>0).length}/${dayRows.length}</b>
        </div>
        ${["CLOTHES","MOP"].map(type=>{
          const group=dayRows.filter(r=>r.product_code===type);
          if(!group.length)return "";
          return `<div class="sorting-today-group">
            <div class="sorting-today-group-title"><strong>${type}</strong><span>${group.filter(r=>Number((r.receipt_evidence_count??r.received_count)||0)>0).length}/${group.length}</span></div>
            ${group.map(r=>{
              const routeColor=r.route_color||"";
              const routeFg=routeTextColor(routeColor);
              const routeStyle=routeColor?` style="--route-bg:${esc(routeColor)};--route-fg:${routeFg}"`:"";
              const stateInfo=receptionRowState(r);
              const selected=Boolean(state.trolley&&state.trolleyDraft?.customer_id===r.customer_id&&state.trolleyDraft?.scheduled_for_date===r.scheduled_for_date&&state.trolleyDraft?.product_codes?.includes(r.product_code));
              const qty=Number(r.planned_trolley_quantity||0);
              const received=Number(r.received_count||0);
              const noTrolleyReceived=Number(r.no_trolley_arrival_count||0)>0;
              const washed=Number(r.wash_count||0)>0;
              const scanned=received>0;
              const hasEvidence=scanned||noTrolleyReceived;
              const noReceiptWash=washed&&!hasEvidence;
              const requirementText=trolleyRequirementSummary(r);
              const receivedSizeText=scannedTrolleySizeSummary(r);
              const scanText=noTrolleyReceived
                ? "CONTENTS RECEIVED · NO TROLLEY"
                : scanned
                  ? `SCANNED ${received}${qty>0?`/${qty}`:""}${receivedSizeText?` · ${receivedSizeText}`:""}`
                  : r.no_trolley_eligible?"NO TROLLEY · ARRIVAL NOT CONFIRMED":"NOT SCANNED";
              const statusClass=washed?"done":hasEvidence?"scanned":"pending";
              const noTrolleyAction=r.no_trolley_eligible
                ? `<button type="button" class="sorting-no-trolley-action${noTrolleyReceived?" recorded":""}" ${noTrolleyReceived?"disabled":""}
                    data-no-trolley-arrival="${esc(r.schedule_product_id)}"
                    data-no-trolley-customer="${esc(r.customer_id)}"
                    data-no-trolley-date="${esc(r.scheduled_for_date)}"
                    data-no-trolley-product="${esc(r.product_code)}">${noTrolleyReceived?"✓ Contents received without trolley":"Receive without trolley"}</button>`
                : "";
              return `<div class="sorting-reception-board-wrap"><button type="button" class="sorting-today-item sorting-reception-board-item${routeColor?" route-colored":""}${selected?" reception-selected":""}${washed?" is-washed":""}${hasEvidence?" is-received":""}${noReceiptWash?" reception-no-receipt-wash":""} state-${stateInfo.kind}"${routeStyle}
                data-reception-board-customer="${esc(r.customer_id)}"
                data-reception-board-date="${esc(r.scheduled_for_date)}"
                data-reception-board-product="${esc(r.product_code)}">
                <span class="sorting-today-status ${statusClass}"></span>
                <div class="sorting-today-main">
                  <strong>${esc(r.customer_name)}</strong>
                  <span class="sorting-reception-state-line">${esc(stateInfo.label)} · ${esc(shortDayDate(r.scheduled_for_date))}${r.route_display_name?` · ${esc(r.route_display_name)}`:""}</span>
                  <span class="sorting-reception-scan-line ${hasEvidence?"scanned":"waiting"}">${esc(scanText)}</span>
                </div>
                <span class="sorting-today-trolleys sorting-reception-contract" title="Contracted trolley requirement">${esc(requirementText)}</span>
              </button>${noTrolleyAction}</div>`;
            }).join("")}
          </div>`;
        }).join("")}
      </section>`;
    };

    el.trolleyTodayList.innerHTML=renderDay(todayRows,"TODAY")+(showTomorrow?renderDay(tomorrowRows,"TOMORROW"):"");
  }

  function renderTrolleySummary(){
    if(!el.trolleySummary)return;
    const s=state.sorting?.summary||{};
    el.trolleySummary.innerHTML=`
      <span><b>${Number(s.received_today||0)}</b> received</span>
      <span><b>${Number(s.contents_today||0)}</b> contents</span>
      <span><b>${Number(s.empty_today||0)}</b> empty</span>`;
  }

  function recentIntakeRoute(row){
    const products=Array.isArray(row?.products)?row.products:[];
    const codes=products.map(p=>String(p.product_code||'').trim()).filter(Boolean);
    const board=trolleyBoard().find(item=>
      item.customer_id===row.customer_id
      && (!row.scheduled_for_date||item.scheduled_for_date===row.scheduled_for_date)
      && (!codes.length||codes.includes(item.product_code))
    )||null;
    const product=products.find(p=>p.route_display_name||p.route_code)||products[0]||{};
    return {
      route_display_name:product.route_display_name||board?.route_display_name||'',
      route_code:product.route_code||board?.route_code||'',
      route_color:board?.route_color||''
    };
  }

  function recentIntakeById(id){
    return trolleyRecent().find(row=>row.sorting_trolley_intake_id===id)||null;
  }

  function intakeProductCodes(row){
    const products=Array.isArray(row?.products)&&row.products.length
      ? row.products.map(p=>p.product_code).filter(Boolean)
      : String(row?.product_scope||"").split("+").map(x=>x.trim()).filter(Boolean);
    return [...new Set(products.map(code=>String(code).toUpperCase()).filter(code=>["CLOTHES","MOP"].includes(code)))];
  }

  function editDateOptions(customerId,currentDate){
    const map=new Map();
    trolleyScheduleRows(customerId).forEach(row=>{
      if(row.scheduled_for_date)map.set(row.scheduled_for_date,row);
    });
    if(currentDate&&!map.has(currentDate)){
      map.set(currentDate,{scheduled_for_date:currentDate,day_relation:"CURRENT",day_offset:999});
    }
    return [...map.values()].sort((a,b)=>{
      const priority=row=>{
        if(row.day_relation==="TODAY")return 0;
        if(row.day_relation==="TOMORROW")return 1;
        if(Number(row.day_offset||0)>1)return 2;
        if(row.day_relation==="YESTERDAY")return 3;
        return 4;
      };
      return priority(a)-priority(b)||Number(a.day_offset||0)-Number(b.day_offset||0);
    });
  }

  function editProductOptions(customerId,date,currentCodes=[]){
    const available=[...new Set(trolleyScheduleRowsForDate(customerId,date).map(row=>row.product_code).filter(Boolean))];
    currentCodes.forEach(code=>{if(!available.includes(code))available.push(code);});
    if(!available.length)available.push("CLOTHES","MOP");
    const opts=[];
    if(available.includes("CLOTHES"))opts.push(["CLOTHES","Clothes"]);
    if(available.includes("MOP"))opts.push(["MOP","MOP"]);
    if(available.includes("CLOTHES")&&available.includes("MOP"))opts.push(["BOTH","Clothes + MOP"]);
    return opts;
  }

  function renderTrolleyEditDialog(){
    const edit=state.pendingTrolleyEdit,row=edit?.row;
    if(!edit||!row)return;
    const currentCodes=intakeProductCodes(row);
    const customerId=edit.customerId||row.customer_id||"";
    const date=edit.date||String(row.scheduled_for_date||"").slice(0,10);
    const productValue=edit.product||(currentCodes.length===2?"BOTH":currentCodes[0]||"CLOTHES");

    el.trolleyEditSummary.innerHTML=`<strong>${esc(row.trolley_code||"Trolley")}</strong>
      <span>Current: ${esc(row.customer_name||"Customer")} · ${esc(row.scheduled_for_date?fullDayDate(row.scheduled_for_date):"No date")} · ${esc(intakeProductCodes(row).join(" + ")||"Product")} · ${esc(row.operator_name||"Staff")}</span>`;
    el.trolleyEditCustomer.innerHTML=allCustomers().map(c=>
      `<option value="${esc(c.customer_id)}" ${c.customer_id===customerId?"selected":""}>${esc(c.customer_name)}${c.customer_code?` · ${esc(c.customer_code)}`:""}</option>`
    ).join("");
    const dateOptions=editDateOptions(customerId,date);
    el.trolleyEditDate.innerHTML=dateOptions.map(item=>
      `<option value="${esc(item.scheduled_for_date)}" ${item.scheduled_for_date===date?"selected":""}>${esc(fullDayDate(item.scheduled_for_date))} · ${esc(titleCode(item.day_relation||"Scheduled"))}</option>`
    ).join("");
    const selectedDate=dateOptions.some(item=>item.scheduled_for_date===date)?date:(dateOptions[0]?.scheduled_for_date||date);
    el.trolleyEditDate.value=selectedDate;
    edit.date=selectedDate;
    const productOptions=editProductOptions(customerId,selectedDate,currentCodes);
    el.trolleyEditProduct.innerHTML=productOptions.map(([value,label])=>
      `<option value="${esc(value)}" ${value===productValue?"selected":""}>${esc(label)}</option>`
    ).join("");
    el.trolleyEditContents.value=row.contents_status==="EMPTY"?"EMPTY":"CONTENTS";
    const staffRows=trolleyOperatorRows();
    el.trolleyEditStaff.innerHTML=staffRows.map(staff=>
      `<option value="${esc(staff.staff_id)}" ${staff.staff_id===(edit.staffId||row.operator_staff_id||state.trolleyOperatorStaffId)?"selected":""}>${esc(staff.display_name)} · ${esc(staff.work_mode==="MOP"?"MOP":"Clothes")}</option>`
    ).join("");
    if(!staffRows.length){
      el.trolleyEditStaff.innerHTML='<option value="">No active Sorting staff</option>';
    }
  }

  function openTrolleyEditDialog(id){
    const row=recentIntakeById(id);
    if(!row||String(row.arrival_mode||"").toUpperCase()==="NO_TROLLEY")return;
    const currentCodes=intakeProductCodes(row);
    state.pendingTrolleyEdit={
      row,
      customerId:row.customer_id||"",
      date:String(row.scheduled_for_date||"").slice(0,10),
      product:currentCodes.length===2?"BOTH":currentCodes[0]||"CLOTHES",
      staffId:row.operator_staff_id||state.trolleyOperatorStaffId||""
    };
    el.trolleyEditMessage.textContent="";
    el.trolleyEditReason.value="";
    renderTrolleyEditDialog();
    el.trolleyEditDialog.showModal();
  }

  function closeTrolleyEditDialog(){
    state.pendingTrolleyEdit=null;
    if(el.trolleyEditReason)el.trolleyEditReason.value="";
    if(el.trolleyEditMessage)el.trolleyEditMessage.textContent="";
    if(el.trolleyEditDialog?.open)el.trolleyEditDialog.close();
  }

  async function saveTrolleyEdit(){
    const edit=state.pendingTrolleyEdit,row=edit?.row;
    if(!row||state.busy)return;
    const reason=el.trolleyEditReason.value.trim();
    if(!reason){el.trolleyEditMessage.textContent="Correction reason is required.";return;}
    const product=el.trolleyEditProduct.value;
    const productCodes=product==="BOTH"?["CLOTHES","MOP"]:[product];
    const staffId=el.trolleyEditStaff.value;
    if(!staffId){el.trolleyEditMessage.textContent=trolleyOperatorRequiredMessage();return;}
    state.busy=true;
    el.trolleyEditSave.disabled=true;
    el.trolleyEditSave.textContent="Saving...";
    setMessage("Saving trolley intake correction...");
    try{
      const result=await rpc("correct_sorting_trolley_intake",{
        p_sorting_trolley_intake_id:row.sorting_trolley_intake_id,
        p_customer_id:el.trolleyEditCustomer.value,
        p_scheduled_for_date:el.trolleyEditDate.value,
        p_product_codes:productCodes,
        p_contents_status:el.trolleyEditContents.value,
        p_operator_staff_id:staffId,
        p_reason:reason
      });
      el.trolleyEditDialog.close();
      state.pendingTrolleyEdit=null;
      await loadSorting();
      setMessage(`Trolley intake corrected · Rev ${result?.revision_no||""}.`,"success");
    }catch(error){
      console.error(error);
      const message=friendly(error);
      el.trolleyEditMessage.textContent=message;
      setMessage(message,"error");
    }finally{
      state.busy=false;
      el.trolleyEditSave.disabled=false;
      el.trolleyEditSave.textContent="Save correction";
    }
  }

  function promptRequired(message,initial=""){
    const value=window.prompt(message,initial);
    if(value===null)return null;
    const trimmed=String(value).trim();
    return trimmed?trimmed:null;
  }

  async function removeTrolleyIntake(id){
    const row=recentIntakeById(id);
    if(!row||String(row.arrival_mode||"").toUpperCase()==="NO_TROLLEY")return;
    const reason=promptRequired(`Reason to remove trolley receipt ${row.trolley_code||""}:`);
    if(reason===null){setMessage("Removal reason is required.","error");return;}
    state.busy=true;
    setMessage("Removing trolley intake from active production...");
    try{
      const result=await rpc("cancel_sorting_trolley_intake",{
        p_sorting_trolley_intake_id:id,
        p_reason:reason
      });
      await loadSorting();
      setMessage(`Trolley intake removed from active production · Rev ${result?.revision_no||""}.`,"success");
    }catch(error){
      console.error(error);
      setMessage(friendly(error),"error");
    }finally{
      state.busy=false;
    }
  }

  function renderArrivals(){
    const rows=trolleyRecent().slice(0,12);
    if(!rows.length){el.arrivals.innerHTML='<div class="sorting-empty">No trolley receipts for this shift yet.</div>';return;}
    const head='<div class="sorting-intake-trace-row sorting-intake-trace-head"><span>Trolley</span><span>Customer</span><span>Schedule / Route</span><span>Product</span><span>Contents</span><span>Actions</span><span>Received</span></div>';
    const body=rows.map(r=>{
      const products=Array.isArray(r.products)?r.products:[];
      const productNames=products.map(p=>p.product_code).filter(Boolean);
      if(!productNames.length&&r.product_scope)productNames.push(r.product_scope);
      const route=recentIntakeRoute(r);
      const routeColor=safeRouteColor(route.route_color);
      const customerStyle=routeColor?` style="--intake-route:${routeColor}"`:'';
      const routeLabel=String(route.route_display_name||'').trim()||(route.route_code?`Route ${route.route_code}`:'Route not recorded');
      const empty=r.contents_status==='EMPTY';
      const noTrolley=String(r.arrival_mode||'').toUpperCase()==='NO_TROLLEY'||String(r.trolley_code||'').toUpperCase()==='NO TROLLEY';
      const schedule=r.scheduled_for_date?shortDayDate(r.scheduled_for_date):'Off schedule';
      const cancelled=String(r.record_status||"RECORDED").toUpperCase()==="CANCELLED";
      const revision=Number(r.revision_no||1);
      const actions=!noTrolley?`<div class="sorting-intake-trace-actions">
        <button type="button" class="sorting-secondary-button" data-trolley-intake-edit="${esc(r.sorting_trolley_intake_id)}" ${cancelled?"disabled":""}>Edit</button>
        <button type="button" class="sorting-secondary-button" data-trolley-intake-remove="${esc(r.sorting_trolley_intake_id)}" ${cancelled?"disabled":""}>Remove</button>
      </div>`:"";
      return `<article class="sorting-intake-trace-row${empty?' is-empty':''}${cancelled?' is-cancelled':''}">
        <div class="sorting-intake-trace-trolley"><strong>${esc(noTrolley?'NO TROLLEY':r.trolley_code||'—')}</strong><small>${esc(titleCode(r.schedule_relation||''))}</small></div>
        <div class="sorting-intake-trace-customer"${customerStyle}><strong>${esc(r.customer_name||'Customer not available')}</strong><small>${cancelled?'Removed from active production':`Receipt confirmed${revision>1?` · Rev ${revision}`:""}`}</small></div>
        <div class="sorting-intake-trace-schedule"><strong>${esc(schedule)}</strong><small>${esc(routeLabel)}</small></div>
        <div class="sorting-intake-trace-product"><strong>${esc(productNames.join(' + ')||'—')}</strong><small>${noTrolley?'Controlled no-trolley arrival':'Physical trolley receipt'}</small></div>
        <div><span class="sorting-intake-content-badge ${empty?'empty':'contents'}">${empty?'EMPTY':'CONTENTS'}</span></div>
        ${actions}
        <div class="sorting-intake-trace-received"><strong>${esc(r.operator_name||'—')}</strong><small>${esc(fmtTime(r.arrived_at))}</small></div>
      </article>`;
    }).join('');
    el.arrivals.innerHTML=`<div class="sorting-intake-trace-table">${head}${body}</div>`;
  }

  async function loadSorting(){
    try{
      state.sorting=await rpc("get_sorting_trolley_intake_context_v3",{p_shift_code:state.shift});
    }catch(error){
      console.warn("Reception V3 not available; using V2 until Migration 030 is applied.",error);
      state.sorting=await rpc("get_sorting_trolley_intake_context_v2",{p_shift_code:state.shift});
    }
    renderTrolleyStaffBar();
    renderTrolleySummary();
    renderArrivals();
    renderTrolleySidebar();
    renderTrolleyResult();
    renderTrolleyBasket();
    renderTrolleyOutboxStatus();
  }

  async function lookupTrolley(raw){
    if(state.busy)return;
    const operator=trolleySelectedOperator();
    if(!operator){
      promptTrolleyStaffSelection("Select your name in RECEIVING AS before scanning the trolley.");
      return;
    }
    const code=String(raw||"").trim().toUpperCase().replace(/\s+/g,"");
    if(!/^T\d{1,10}T$/.test(code)){
      setMessage("Invalid trolley code. Expected format like T123T.","error");
      return;
    }
    state.busy=true;
    setMessage(`Checking ${code}…`);
    try{
      state.trolley=await rpc("get_sorting_trolley_intake_preview_v2",{
        p_shift_code:state.shift,
        p_trolley_code:code
      });
      const duplicate=recentDuplicateTrolleyReceipt(code);
      if(duplicate){
        state.trolley={
          ...state.trolley,
          blocked:true,
          message:duplicateTrolleyMessage(duplicate),
          duplicate_recent_intake:duplicate
        };
      }
      initTrolleyDraft(state.trolley.recommended_customer_id||"");
      renderTrolleyResult();
      renderTrolleySidebar();
      if(!el.trolleyResultDialog.open)el.trolleyResultDialog.showModal();
      setMessage(state.trolley?.message||"Trolley ready to review.",state.trolley?.needs_review_if_confirmed?"warning":"success");
    }catch(error){
      console.error(error);
      state.trolley=null;
      state.trolleyDraft=null;
      renderTrolleyResult();
      setMessage(friendly(error),"error");
    }finally{
      state.busy=false;
    }
  }

  function resetTrolleyScan(){
    state.trolley=null;
    state.trolleyDraft=null;
    state.pendingTrolleyConfirmation=null;
    if(el.trolleyResultDialog?.open)el.trolleyResultDialog.close();
    renderTrolleyResult();
    renderTrolleySidebar();
    clearTrolleyScanBuffer();
  }

  function openTrolleyCustomerPicker(){
    state.trolleyCustomerTab="SCHEDULED";
    renderTrolleyCustomerPicker();
    el.trolleyCustomerDialog.showModal();
  }

  function renderTrolleyCustomerPicker(){
    if(!el.trolleyCustomerOptions)return;
    el.trolleyCustomerTabs.querySelectorAll("[data-reception-customer-tab]").forEach(btn=>
      btn.classList.toggle("active",btn.dataset.receptionCustomerTab===state.trolleyCustomerTab)
    );

    let rows=[];
    if(state.trolleyCustomerTab==="SCHEDULED"){
      const map=new Map();
      trolleyBoard().filter(r=>["TODAY","TOMORROW"].includes(r.day_relation)).forEach(r=>{
        const key=`${r.customer_id}|${r.scheduled_for_date}|${r.product_code}`;
        map.set(key,r);
      });
      rows=[...map.values()];
      el.trolleyCustomerOptions.innerHTML=rows.length?rows.map(r=>{
        const color=r.route_color||"";
        return `<button type="button" class="sorting-reception-customer-option${color?" route-colored":""}" ${color?`style="--route-bg:${esc(color)};--route-fg:${routeTextColor(color)}"`:""}
          data-reception-customer="${esc(r.customer_id)}" data-reception-date="${esc(r.scheduled_for_date)}" data-reception-product-code="${esc(r.product_code)}">
          <strong>${esc(r.customer_name)}</strong>
          <span>${esc(fullDayDate(r.scheduled_for_date))} · ${esc(r.product_code)}${r.route_display_name?` · ${esc(r.route_display_name)}`:""}</span>
        </button>`;
      }).join(""):'<div class="sorting-empty">No scheduled customers.</div>';
    }else{
      rows=allCustomers();
      el.trolleyCustomerOptions.innerHTML=rows.map(c=>
        `<button type="button" class="sorting-reception-customer-option" data-reception-customer="${esc(c.customer_id)}">
          <strong>${esc(c.customer_name)}</strong><span>${esc(c.customer_code||"Active customer")}</span>
        </button>`).join("");
    }
  }

  function paintManualTrolley(){
    const digits=state.trolleyManualDigits;
    el.trolleyManualDisplay.textContent=digits?`T${digits}T`:"T_____T";
    el.trolleyManualScan.disabled=!digits;
  }

  function openManualTrolley(){
    state.trolleyManualDigits="";
    paintManualTrolley();
    el.trolleyManualDialog.showModal();
  }

  async function saveTrolleyReceipt(){
    if(state.busy||!trolleySaveReady())return;
    const operator=trolleySelectedOperator();
    if(!operator){promptTrolleyStaffSelection(trolleyOperatorRequiredMessage());renderTrolleyResult();return;}
    const d=state.trolleyDraft,p=state.trolley;
    state.busy=true;
    const button=el.trolleyPreview.querySelector("[data-reception-confirm]");
    if(button){button.disabled=true;button.textContent="SAVING…";}
    setMessage("Recording trolley receipt and Production Flow…");
    try{
      const payload=trolleyReceiptPayloadFrom(p,d,state.trolleyOperatorStaffId);
      const result=await sendTrolleyPayload(payload,{label:basketLabel({payload})});
      const days=result?.tracked_days_at_customer;
      const daysText=Number.isFinite(Number(days))?` · ${Number(days)} days out`:" · days out unavailable";
      resetTrolleyScan();
      await loadStaffWork();
      await loadSorting();
      setMessage(`${result?.trolley_code||"Trolley"} received${daysText}. Trolley is AVAILABLE for the next use.`,"success");
    }catch(error){
      console.error(error);
      setMessage(friendly(error),"error");
      renderTrolleyResult();
    }finally{
      state.busy=false;
    }
  }


  function noTrolleyRowFromButton(button){
    return trolleyBoard().find(row=>
      row.schedule_product_id===button.dataset.noTrolleyArrival
      && row.customer_id===button.dataset.noTrolleyCustomer
      && row.scheduled_for_date===button.dataset.noTrolleyDate
      && row.product_code===button.dataset.noTrolleyProduct
    )||null;
  }

  function openNoTrolleyArrival(row){
    const operator=trolleySelectedOperator();
    if(!operator){promptTrolleyStaffSelection("Select your name in RECEIVING AS before confirming this arrival.");return;}
    if(!row?.no_trolley_eligible)return setMessage("This schedule product expects trolley Reception evidence.","error");
    state.pendingNoTrolleyArrival=row;
    el.noTrolleyArrivalNotes.value="";
    el.noTrolleyArrivalMessage.textContent="";
    el.noTrolleyArrivalSummary.innerHTML=`<strong>${esc(row.customer_name)}</strong>
      ${esc(row.product_code)} · ${esc(fullDayDate(row.scheduled_for_date))}<br>
      <span>Operator: ${esc(operator.display_name)} · Published schedule confirms no trolley is mapped to this product.</span>`;
    el.noTrolleyArrivalDialog.showModal();
  }

  async function saveNoTrolleyArrival(){
    const row=state.pendingNoTrolleyArrival,operator=trolleySelectedOperator();
    if(!row||!operator)return;
    el.noTrolleyArrivalSave.disabled=true;
    el.noTrolleyArrivalMessage.textContent="Recording contents arrival…";
    try{
      const result=await rpc("record_sorting_non_trolley_arrival",{
        p_shift_code:state.shift,
        p_customer_id:row.customer_id,
        p_scheduled_for_date:row.scheduled_for_date,
        p_product_code:row.product_code,
        p_operator_staff_id:operator.staff_id,
        p_notes:el.noTrolleyArrivalNotes.value.trim()||null
      });
      el.noTrolleyArrivalDialog.close();
      state.pendingNoTrolleyArrival=null;
      await loadSorting();
      await loadWashing();
      setMessage(result?.message||`${row.customer_name} contents received without trolley. Washing is now unlocked.`,"success");
    }catch(error){
      console.error(error);el.noTrolleyArrivalMessage.textContent=friendly(error);
    }finally{el.noTrolleyArrivalSave.disabled=false;}
  }


  function mopTypeCatalogRows(){return Array.isArray(state.mopTypeCatalog?.types)?state.mopTypeCatalog.types:[];}
  function selectedMopType(){return state.mopTypeCreating?null:mopTypeCatalogRows().find(row=>row.product_variant_id===state.mopTypeSelectedId)||null;}
  function mopTypeFilteredRows(){
    const q=String(state.mopTypeSearch||'').trim().toLowerCase();
    if(!q)return mopTypeCatalogRows();
    return mopTypeCatalogRows().filter(row=>[row.display_name,row.variant_code,row.category,row.notes].some(v=>String(v||'').toLowerCase().includes(q)));
  }
  function mopVariantCodeFromName(value){
    return String(value||'').normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toUpperCase().replace(/[^A-Z0-9]+/g,'_').replace(/^_+|_+$/g,'').slice(0,80);
  }
  function clearMopTypePreviewUrl(){
    if(state.mopTypePreviewUrl){try{URL.revokeObjectURL(state.mopTypePreviewUrl);}catch{}state.mopTypePreviewUrl=null;}
  }
  function mopTypePhotoMarkup(row,isNew){
    const image=row?.image_url;
    return image?`<img src="${esc(image)}" alt="${esc(row?.display_name||row?.variant_code||'MOP type')}">`:`<span class="sorting-mop-type-photo-empty"><span>📷</span>No photo registered</span>`;
  }
  function mopTypeWeightLabel(row){
    if(row?.unit_weight_grams)return `${Number(row.unit_weight_grams)} g/unit`;
    if(row?.unit_weight_review_required)return 'Needs weight review';
    return 'Weight not set';
  }
  function mopTypeWeightEvidenceMarkup(row){
    const source=String(row?.unit_weight_source||'');
    const count=Number(row?.unit_weight_evidence_count||0);
    const obs=row?.legacy_weight_observations&&typeof row.legacy_weight_observations==='object'?row.legacy_weight_observations:{};
    if(row?.unit_weight_review_required&&Object.keys(obs).length){
      const parts=Object.entries(obs).sort((a,b)=>Number(b[1])-Number(a[1])).map(([grams,n])=>`${esc(grams)} g (${Number(n)} record${Number(n)===1?'':'s'})`);
      return `<div class="sorting-mop-type-weight-evidence review"><strong>Needs weight review</strong><span>Legacy production history contains conflicting unit weights: ${parts.join(' and ')}. Choose the official dry unit weight before relying on automatic KG ↔ Units conversion.</span></div>`;
    }
    if(source==='LEGACY_MOP_TRACKER_HISTORY'&&row?.unit_weight_grams){
      return `<div class="sorting-mop-type-weight-evidence legacy"><strong>Legacy verified prefill</strong><span>${Number(row.unit_weight_grams)} g/unit was prefilled from ${count||'matching'} historical MOP production record${count===1?'':'s'}. You can replace it with the current official dry weight.</span></div>`;
    }
    if(source==='MOP_TYPE_MASTER_MANUAL'&&row?.unit_weight_grams){
      return `<div class="sorting-mop-type-weight-evidence manual"><strong>Master value</strong><span>This unit weight was set manually in MOP Types Management.</span></div>`;
    }
    return '';
  }
  function renderMopTypeList(){
    if(!el.mopTypesList)return;
    const all=mopTypeCatalogRows();
    const rows=mopTypeFilteredRows();
    if(el.mopTypesCount)el.mopTypesCount.textContent=String(all.length);
    el.mopTypesPermission.textContent=state.mopTypeCatalog?.can_manage?'ADMIN / MANAGER':'Read only';
    if(el.mopTypeNewButton)el.mopTypeNewButton.hidden=!state.mopTypeCatalog?.can_manage;
    el.mopTypesList.innerHTML=rows.length?rows.map(row=>{
      const photo=row.image_url?`<img src="${esc(row.image_url)}" alt="">`:'<span>📷</span>';
      const weight=mopTypeWeightLabel(row);
      const category=row.category||'Uncategorised';
      const links=Number(row.schedule_link_count||0);
      return `<button type="button" class="sorting-mop-type-list-item${!state.mopTypeCreating&&row.product_variant_id===state.mopTypeSelectedId?' active':''}" data-mop-type-id="${esc(row.product_variant_id)}">
        <span class="sorting-mop-type-list-thumb">${photo}</span>
        <span class="sorting-mop-type-list-copy">
          <span class="sorting-mop-type-list-title"><strong>${esc(row.display_name||row.variant_code)}</strong><em class="${row.active?'is-active':'is-inactive'}">${row.active?'Active':'Inactive'}</em></span>
          <span>${esc(category)} · ${weight}</span>
          <small>${esc(row.variant_code)} · ${links} schedule link${links===1?'':'s'}</small>
        </span>
      </button>`;
    }).join(''):`<div class="sorting-empty">${state.mopTypeSearch?'No MOP types match this search.':'No MOP types are configured.'}</div>`;
  }
  function renderMopTypeEditor(){
    const row=selectedMopType();
    const isNew=Boolean(state.mopTypeCreating);
    const can=Boolean(state.mopTypeCatalog?.can_manage);
    if(!isNew&&!row){
      el.mopTypeEditor.innerHTML='<div class="sorting-mop-type-editor-empty"><span class="sorting-mop-type-editor-empty-icon">🧹</span><strong>Select a MOP type</strong><span>Choose a saved type to edit, or create a new one.</span></div>';
      return;
    }
    const model=isNew?{variant_code:'',display_name:'',category:'',unit_weight_grams:'',notes:'',sort_order:(Math.max(0,...mopTypeCatalogRows().map(x=>Number(x.sort_order||0)))+10),image_url:null,active:true,schedule_link_count:0,production_line_count:0}:row;
    const photo=mopTypePhotoMarkup(model,isNew);
    const links=Number(model.schedule_link_count||0);
    const productionLines=Number(model.production_line_count||0);
    const codeReadonly=!isNew||!can;
    el.mopTypeEditor.innerHTML=`
      <div class="sorting-mop-type-editor-heading">
        <div><span class="sorting-section-eyebrow">${isNew?'New catalogue item':'Saved catalogue item'}</span><h3>${isNew?'New MOP Type':esc(model.display_name||model.variant_code)}</h3></div>
        ${!isNew?`<span class="sorting-mop-type-status ${model.active?'active':'inactive'}">${model.active?'Active':'Inactive'}</span>`:''}
      </div>
      <div class="sorting-mop-type-editor-grid">
        <div class="sorting-mop-type-photo-editor">
          <div id="sortingMopTypePhotoDrop" class="sorting-mop-type-photo-drop ${can?'can-edit':''}" role="button" tabindex="${can?'0':'-1'}">
            <div id="sortingMopTypePhotoPreview" class="sorting-mop-type-photo-preview">${photo}</div>
            ${can?'<div class="sorting-mop-type-photo-drop-copy"><strong>Choose or drop photo</strong><span>JPG, PNG or WebP · max 2 MB</span></div>':''}
            <input id="sortingMopTypePhotoFile" type="file" accept="image/jpeg,image/png,image/webp" hidden ${can?'':'disabled'}>
          </div>
          ${!isNew&&model.image_url&&can?'<label class="sorting-mop-type-remove-photo"><input id="sortingMopTypeRemovePhoto" type="checkbox"> Remove current photo</label>':''}
          ${!isNew?`<div class="sorting-mop-type-usage"><strong>Usage</strong><span>${links} Customer Schedule link${links===1?'':'s'}</span><span>${productionLines} production line${productionLines===1?'':'s'}</span></div>`:''}
        </div>
        <div class="sorting-mop-type-fields">
          <div class="sorting-mop-type-field-row two">
            <label class="sorting-field">Model name <span class="sorting-required">*</span><input id="sortingMopTypeDisplayName" type="text" maxlength="160" value="${esc(model.display_name||'')}" ${can?'':'readonly'} placeholder="e.g. Kentucky 400g"></label>
            <label class="sorting-field">Variant code <span class="sorting-required">*</span><input id="sortingMopTypeVariantCode" class="sorting-code-input" type="text" maxlength="80" value="${esc(model.variant_code||'')}" ${codeReadonly?'readonly':''} placeholder="KENTUCKY_400G"><span class="sorting-field-help">Permanent after creation.</span></label>
          </div>
          <div class="sorting-mop-type-field-row two">
            <label class="sorting-field">Type / Category<input id="sortingMopTypeCategory" type="text" maxlength="120" value="${esc(model.category||'')}" ${can?'':'readonly'} placeholder="e.g. STANDARD POCKET MOPS"></label>
            <label class="sorting-field">Weight per unit (grams)<input id="sortingMopTypeUnitWeight" type="number" min="0.001" step="0.001" value="${model.unit_weight_grams??''}" ${can?'':'readonly'} placeholder="400"><span class="sorting-field-help">Dry clean weight of one unit.</span></label>
          </div>
          ${mopTypeWeightEvidenceMarkup(model)}
          <label class="sorting-field sorting-mop-sort-order-field">Display order<input id="sortingMopTypeSortOrder" type="number" min="0" max="100000" step="10" value="${Number(model.sort_order||0)}" ${can?'':'readonly'}></label>
          <label class="sorting-field">Notes<textarea id="sortingMopTypeNotes" maxlength="1000" rows="4" ${can?'':'readonly'} placeholder="Optional operational notes…">${esc(model.notes||'')}</textarea></label>
          ${can?`<div class="sorting-mop-type-governance-note"><strong>Master-data rule</strong><span>${isNew?'The code becomes permanent when this type is created.':'The code is locked because schedules and production history may reference this identity.'}</span></div>`:'<div class="sorting-mop-type-readonly">Only ADMIN or MANAGER can change MOP type master data.</div>'}
          <div class="sorting-mop-type-editor-actions">
            ${isNew&&can?'<button id="sortingMopTypeCancelNewButton" class="sorting-secondary-button" type="button">Cancel</button>':''}
            ${can?`<button id="sortingMopTypeSaveButton" class="sorting-primary-button" type="button">${isNew?'Create MOP type':'Save changes'}</button>`:''}
          </div>
        </div>
      </div>`;
  }
  async function loadMopTypes(){
    el.mopTypesMessage.textContent='Loading MOP types…';
    try{
      state.mopTypeCatalog=await rpc('get_sorting_mop_type_catalog');
      const rows=mopTypeCatalogRows();
      if(!state.mopTypeCreating&&!rows.some(row=>row.product_variant_id===state.mopTypeSelectedId))state.mopTypeSelectedId=rows[0]?.product_variant_id||null;
      renderMopTypeList();renderMopTypeEditor();el.mopTypesMessage.textContent='';
    }catch(error){console.error(error);el.mopTypesMessage.textContent=friendly(error);}
  }
  function confirmDiscardMopTypeChanges(){
    if(state.mopTypeSaving){el.mopTypesMessage.textContent='Wait for the current MOP Type save to finish.';return false;}
    return !state.mopTypeDirty||window.confirm('Discard unsaved MOP Type changes?');
  }
  function resetMopTypeEditState(){
    clearMopTypePreviewUrl();state.mopTypeUploadFile=null;state.mopTypeCreating=false;state.mopTypeCodeTouched=false;state.mopTypeDirty=false;state.mopTypeSaving=false;
  }
  function closeMopTypes(){
    if(!confirmDiscardMopTypeChanges())return false;
    resetMopTypeEditState();el.mopTypesDialog.close();return true;
  }
  async function openMopTypes(){
    if(hasMopProductionDraft()){setMessage(mopDraftWarning("opening MOP Types"),"warning");return;}
    resetMopTypeEditState();state.mopTypeSearch='';
    if(el.mopTypesSearch)el.mopTypesSearch.value='';
    el.mopTypesDialog.showModal();await loadMopTypes();
  }
  function startNewMopType(){
    if(!state.mopTypeCatalog?.can_manage||!confirmDiscardMopTypeChanges())return;
    resetMopTypeEditState();state.mopTypeCreating=true;state.mopTypeSelectedId=null;el.mopTypesMessage.textContent='';renderMopTypeList();renderMopTypeEditor();
    setTimeout(()=>document.getElementById('sortingMopTypeDisplayName')?.focus(),0);
  }
  function cancelNewMopType(){
    if(!confirmDiscardMopTypeChanges())return;
    resetMopTypeEditState();state.mopTypeSelectedId=mopTypeCatalogRows()[0]?.product_variant_id||null;el.mopTypesMessage.textContent='';renderMopTypeList();renderMopTypeEditor();
  }
  function restoreMopTypePhotoPreview(){
    const preview=document.getElementById('sortingMopTypePhotoPreview');if(!preview)return;
    const row=selectedMopType();preview.innerHTML=mopTypePhotoMarkup(row,state.mopTypeCreating);
  }
  function mopPhotoStoragePath(url,bucket){
    const marker=`/storage/v1/object/public/${bucket}/`;const value=String(url||'');const at=value.indexOf(marker);return at>=0?decodeURIComponent(value.slice(at+marker.length)):null;
  }
  function setMopTypePhotoFile(file){
    if(!file)return;
    const allowed=state.mopTypeCatalog?.allowed_mime_types||['image/jpeg','image/png','image/webp'];const max=Number(state.mopTypeCatalog?.max_file_bytes||2097152);
    if(!allowed.includes(file.type)||file.size>max){el.mopTypesMessage.textContent='Photo must be JPG, PNG or WebP and no larger than 2 MB.';return;}
    clearMopTypePreviewUrl();state.mopTypeUploadFile=file;state.mopTypePreviewUrl=URL.createObjectURL(file);state.mopTypeDirty=true;
    const preview=document.getElementById('sortingMopTypePhotoPreview');if(preview)preview.innerHTML=`<img src="${esc(state.mopTypePreviewUrl)}" alt="Selected MOP photo preview">`;
    const remove=document.getElementById('sortingMopTypeRemovePhoto');if(remove)remove.checked=false;
    el.mopTypesMessage.textContent=`Selected photo: ${file.name}`;
  }
  async function saveMopTypeMaster(){
    const isNew=Boolean(state.mopTypeCreating);const row=selectedMopType();if((!isNew&&!row)||!state.mopTypeCatalog?.can_manage||state.mopTypeSaving)return;
    const name=document.getElementById('sortingMopTypeDisplayName')?.value.trim()||'';
    const codeRaw=document.getElementById('sortingMopTypeVariantCode')?.value.trim()||'';
    const code=mopVariantCodeFromName(codeRaw||name);
    const category=document.getElementById('sortingMopTypeCategory')?.value.trim()||null;
    const weightRaw=document.getElementById('sortingMopTypeUnitWeight')?.value.trim()||'';
    const notes=document.getElementById('sortingMopTypeNotes')?.value.trim()||null;
    const sortRaw=document.getElementById('sortingMopTypeSortOrder')?.value.trim()||'';
    const sortOrder=sortRaw===''?null:Number(sortRaw);
    const removePhoto=Boolean(document.getElementById('sortingMopTypeRemovePhoto')?.checked);
    const file=state.mopTypeUploadFile||document.getElementById('sortingMopTypePhotoFile')?.files?.[0]||null;
    if(!name){el.mopTypesMessage.textContent='Model name is required.';return;}
    if(isNew&&!/^[A-Z0-9][A-Z0-9_]{1,79}$/.test(code)){el.mopTypesMessage.textContent='Variant code must use only A-Z, 0-9 and underscore, with at least 2 characters.';return;}
    const weight=weightRaw?Number(weightRaw):null;if(weightRaw&&(!Number.isFinite(weight)||weight<=0)){el.mopTypesMessage.textContent='Unit weight must be greater than zero.';return;}
    if(sortOrder!==null&&(!Number.isInteger(sortOrder)||sortOrder<0||sortOrder>100000)){el.mopTypesMessage.textContent='Display order must be a whole number from 0 to 100000.';return;}
    const allowed=state.mopTypeCatalog.allowed_mime_types||['image/jpeg','image/png','image/webp'];const max=Number(state.mopTypeCatalog.max_file_bytes||2097152);const bucket=state.mopTypeCatalog.bucket_id||'mop-type-photos';
    if(file&&(!allowed.includes(file.type)||file.size>max)){el.mopTypesMessage.textContent='Photo must be JPG, PNG or WebP and no larger than 2 MB.';return;}
    let uploadedPath=null,imageUrl=null;
    state.mopTypeSaving=true;const saveButton=document.getElementById('sortingMopTypeSaveButton');if(saveButton)saveButton.disabled=true;
    el.mopTypesMessage.textContent=isNew?'Creating MOP type…':'Saving MOP type…';
    try{
      if(file&&!removePhoto){
        const ext=file.type==='image/png'?'png':file.type==='image/webp'?'webp':'jpg';
        uploadedPath=isNew?`catalog/${crypto.randomUUID()}.${ext}`:`${row.product_variant_id}/${Date.now()}.${ext}`;
        const {error:upErr}=await client.storage.from(bucket).upload(uploadedPath,file,{contentType:file.type,upsert:false});if(upErr)throw upErr;
        imageUrl=client.storage.from(bucket).getPublicUrl(uploadedPath).data.publicUrl;
      }
      let result;
      if(isNew){
        result=await rpc('create_sorting_mop_type_master',{p_variant_code:code,p_display_name:name,p_category:category,p_unit_weight_grams:weight,p_notes:notes,p_image_url:imageUrl,p_sort_order:sortOrder});
      }else{
        result=await rpc('update_sorting_mop_type_master_v2',{p_product_variant_id:row.product_variant_id,p_display_name:name,p_category:category,p_unit_weight_grams:weight,p_notes:notes,p_image_url:imageUrl,p_remove_image:removePhoto,p_sort_order:sortOrder});
      }
      const oldPath=!isNew?mopPhotoStoragePath(row.image_url,bucket):null;
      if(!isNew&&(removePhoto||uploadedPath)&&oldPath&&oldPath!==uploadedPath){try{await client.storage.from(bucket).remove([oldPath]);}catch(e){console.warn('Old MOP photo cleanup failed',e);}}
      clearMopTypePreviewUrl();state.mopTypeUploadFile=null;state.mopTypeCreating=false;state.mopTypeCodeTouched=false;state.mopTypeDirty=false;state.mopTypeSelectedId=result?.product_variant_id||row?.product_variant_id||null;
      await loadMopTypes();await loadMop();el.mopTypesMessage.textContent=isNew?'MOP type created.':'MOP type saved.';setMessage(isNew?'New MOP type added to the master catalogue.':'MOP type master updated. Production photos refreshed.','success');
    }catch(error){console.error(error);if(uploadedPath){try{await client.storage.from(bucket).remove([uploadedPath]);}catch{}}el.mopTypesMessage.textContent=friendly(error);}
    finally{state.mopTypeSaving=false;const currentSave=document.getElementById('sortingMopTypeSaveButton');if(currentSave)currentSave.disabled=false;}
  }

  const mopQueue=()=>Array.isArray(state.mop?.queue)?state.mop.queue:[];
  const mopRecent=()=>Array.isArray(state.mopTrace?.rows)?state.mopTrace.rows:(Array.isArray(state.mop?.recent_production)?state.mop.recent_production:[]);
  const mopSelected=()=>mopQueue().find(row=>row.production_flow_item_id===state.mopSelectedFlowId)||null;

  function mopFormHasQuantity(){
    if(!el.mopTypeRows)return false;
    return [...el.mopTypeRows.querySelectorAll('[data-mop-field="kg"],[data-mop-field="units"]')]
      .some(input=>Number(input.value||0)>0);
  }

  function hasMopProductionDraft(){
    if(!state.mopSelectedFlowId)return false;
    if(state.mopLateEntry)return true;
    if(state.mopTrolleyCodes.length>0)return true;
    if(String(el.mopNotes?.value||"").trim())return true;
    return mopFormHasQuantity();
  }

  function mopDraftWarning(action="continue"){
    const row=mopSelected();
    return `${row?.customer_name||"MOP production"} has unsaved production details. Save or Clear the draft before ${action}.`;
  }

  function setMopSaveMessage(message="",tone="info"){
    if(!el.mopSaveMessage)return;
    const text=String(message||"").trim();
    el.mopSaveMessage.hidden=!text;
    el.mopSaveMessage.textContent=text;
    el.mopSaveMessage.dataset.tone=tone;
    if(text&&tone==="error")setTimeout(()=>el.mopSaveMessage.scrollIntoView({block:"nearest",behavior:"smooth"}),0);
  }

  function mopStatusLabel(row){
    const code=row?.production_status||"READY";
    if(code==="RECONCILIATION_REQUIRED")return "CONFIRM NOW";
    if(code==="DUE_BY_NOON")return "DUE BY 12:00";
    if(code==="NOT_PROCESSED_CONFIRMED")return "NOT PROCESSED";
    return "READY";
  }

  function mopStatusClass(row){
    const code=row?.production_status||"READY";
    if(code==="RECONCILIATION_REQUIRED")return "overdue";
    if(code==="DUE_BY_NOON")return "due";
    if(code==="NOT_PROCESSED_CONFIRMED")return "confirmed";
    return "";
  }

  function renderMopDueBanner(){
    if(!el.mopDueBanner)return;
    const overdue=Number(state.mop?.overdue_unresolved_count||0);
    const dueSoon=Number(state.mop?.due_today_before_cutoff_count||0);
    if(overdue>0){
      el.mopDueBanner.hidden=false;el.mopDueBanner.classList.add("blocking");
      el.mopDueBanner.innerHTML=`<strong>${overdue} delivery-day confirmation${overdue===1?" is":"s are"} overdue</strong>Before other MOP production is recorded, confirm whether each washed customer was already processed or is still outstanding.`;
    }else if(dueSoon>0){
      el.mopDueBanner.hidden=false;el.mopDueBanner.classList.remove("blocking");
      el.mopDueBanner.innerHTML=`<strong>${dueSoon} customer${dueSoon===1?"":"s"} must be confirmed by 12:00 today</strong>Record MOP production normally before noon. If an entry was missed, the delivery-day reconciliation will become mandatory at 12:00.`;
    }else{
      el.mopDueBanner.hidden=true;el.mopDueBanner.classList.remove("blocking");el.mopDueBanner.innerHTML="";
    }
  }


  function mopQueueTrolleyRequirement(row){
    const reqs=Array.isArray(row?.output_trolley_requirements)?row.output_trolley_requirements:[];
    if(!reqs.length)return 'No trolley required';
    return reqs.map(req=>{
      const size=req.trolley_type_name||req.display_code||req.trolley_type_code||'Trolley';
      return `${Number(req.quantity||0)}× ${size}${req.empty_trolley?' EMPTY':''}`;
    }).join(' + ');
  }

  function renderMopQueue(){
    if(!el.mopQueue)return;
    const rows=mopQueue();
    el.mopQueueDate.textContent=state.mop?.business_date?fullDayDate(state.mop.business_date):"—";
    el.mopQueueCount.textContent=String(rows.length);
    el.mopQueue.innerHTML=rows.length?rows.map(row=>{
      const active=row.production_flow_item_id===state.mopSelectedFlowId;
      const klass=mopStatusClass(row);
      const washed=Number(row.washed_kg_total||0);
      const routeStyle=/^#[0-9A-Fa-f]{6}$/.test(String(row.route_color||""))?` style="--mop-route:${esc(row.route_color)}"`:"";
      return `<button type="button" class="sorting-mop-queue-item ${klass}${active?" active":""}" data-mop-flow="${esc(row.production_flow_item_id)}"${routeStyle}>
        <span class="dot"></span><span><strong>${esc(row.customer_name)}</strong><small>${esc(shortDayDate(row.scheduled_for_date||row.opened_business_date))} · Washed ${washed.toFixed(1)} kg · Delivery ${esc(shortDayDate(row.delivery_due_date))}</small><span class="mop-trolley-plan${row.output_trolley_required?"":" none"}">🛒 ${esc(mopQueueTrolleyRequirement(row))}</span></span><span class="state">${esc(mopStatusLabel(row))}</span>
      </button>`;
    }).join(""):'<div class="sorting-empty">No washed MOP customers are waiting for production.</div>';
  }

  function mopModelRows(row){
    const models=Array.isArray(row?.models)?row.models:[];
    if(models.length)return models;
    return [{product_variant_id:null,variant_code:"MOP_TOTAL",display_name:"MOP total",unit_weight_grams:null,image_url:null,notes:"No scheduled MOP variant is linked. Record the known total and add a note if needed.",generic:true}];
  }

  function renderMopTrolley(){
    ensureMopTrolleyReportUi();
    const row=mopSelected();
    if(!row||!el.mopTrolleySection)return;
    const required=Boolean(row.output_trolley_required);
    const qty=Number(row.planned_output_trolley_quantity||0);
    const lateUnknown=Boolean(state.mopLateEntry?.trolleyUnknown);
    const reportButton=$('sortingMopTrolleyReportButton');if(reportButton)reportButton.disabled=!row;
    const requirements=Array.isArray(row.output_trolley_requirements)?row.output_trolley_requirements:[];
    const requirementText=requirements.map(req=>{
      const code=req.trolley_type_name||req.display_code||req.trolley_type_code||"Trolley";
      return `${Number(req.quantity||0)}×${code}${req.empty_trolley?" EMPTY":""}`;
    }).join(" · ");
    const countMismatch=required&&!lateUnknown&&state.mopTrolleyCodes.length>0&&state.mopTrolleyCodes.length!==qty;
    el.mopTrolleySection.classList.toggle("not-required",!required);
    el.mopTrolleySection.classList.toggle("late-unknown",required&&lateUnknown);
    el.mopTrolleySection.classList.toggle("mismatch",countMismatch);
    el.mopTrolleyRequirement.textContent=!required?"No trolley required":`${qty} trolley${qty===1?"":"s"} expected${requirementText?` · ${requirementText}`:""}`;
    el.mopTrolleyInputWrap.hidden=!required||lateUnknown;
    if(el.mopLateTrolleyUnknownInlineLabel)el.mopLateTrolleyUnknownInlineLabel.hidden=!(required&&Boolean(state.mopLateEntry));
    if(el.mopLateTrolleyUnknownInline)el.mopLateTrolleyUnknownInline.checked=lateUnknown;
    el.mopTrolleyChips.innerHTML=state.mopTrolleyCodes.map(code=>`<span class="sorting-mop-trolley-chip">${esc(code)}<button type="button" data-mop-remove-trolley="${esc(code)}">×</button></span>`).join("");
    el.mopTrolleyHelp.textContent=!required
      ? "This MOP product does not own a clean trolley requirement. No trolley will be invented or assigned."
      : lateUnknown
        ? "Late entry: trolley number explicitly recorded as no longer available."
        : countMismatch
          ? `Contract expects ${qty} trolley${qty===1?"":"s"}; ${state.mopTrolleyCodes.length} ${state.mopTrolleyCodes.length===1?"is":"are"} scanned. Save will preserve this mismatch instead of changing the published schedule.`
          : `Scan the clean trolley${qty===1?"":"s"} used for this customer. The physical trolley lifecycle is assigned only when this production record is saved.`;
  }

  function ensureMopTrolleyReportUi(){
    if(!el.mopTrolleySection)return;
    const title=el.mopTrolleySection.querySelector('.sorting-mop-section-title');
    if(title&&!document.getElementById('sortingMopTrolleyReportButton')){
      const b=document.createElement('button');
      b.id='sortingMopTrolleyReportButton';b.type='button';b.className='sorting-mop-plan-report-button';b.textContent='Report trolley plan';
      b.title='Tell Customer Schedule editors that the planned trolley quantity or type is wrong.';
      title.appendChild(b);
      b.addEventListener('click',openMopTrolleyReport);
    }
    if(document.getElementById('sortingMopTrolleyReportDialog'))return;
    document.body.insertAdjacentHTML('beforeend',`<dialog id="sortingMopTrolleyReportDialog" class="sorting-dialog sorting-mop-plan-report-dialog">
      <form method="dialog" class="sorting-dialog-card sorting-mop-plan-report-card">
        <header><div><p class="sorting-section-eyebrow">Operational Data Report</p><h2>Report incorrect trolley plan</h2><p>This sends evidence to Customer Schedule editors. It never changes the published schedule.</p></div><button id="sortingMopTrolleyReportClose" class="sorting-dialog-close" type="button">×</button></header>
        <div id="sortingMopTrolleyReportSummary" class="sorting-mop-plan-report-summary"></div>
        <section class="sorting-mop-plan-report-section"><div><strong>What should be planned?</strong><span>Enter the quantity you believe should be sent for each trolley type.</span></div><div id="sortingMopTrolleyReportTypes" class="sorting-mop-plan-report-types"></div></section>
        <section class="sorting-mop-plan-report-section"><div><strong>Evidence from this production</strong><span id="sortingMopTrolleyReportObserved">No trolley scanned yet.</span></div></section>
        <label class="sorting-field">Why is the published trolley plan wrong?<textarea id="sortingMopTrolleyReportReason" rows="3" maxlength="1000" placeholder="Example: Supervisor confirmed today this customer needs 2 Medium instead of 3 Small."></textarea></label>
        <p id="sortingMopTrolleyReportMessage" class="sorting-dialog-message" aria-live="polite"></p>
        <footer><button id="sortingMopTrolleyReportCancel" class="sorting-secondary-button" type="button">Cancel</button><button id="sortingMopTrolleyReportSave" class="sorting-primary-button" type="button">Send report</button></footer>
      </form></dialog>`);
    const dialog=$('sortingMopTrolleyReportDialog');
    $('sortingMopTrolleyReportClose').addEventListener('click',()=>{if(!state.mopTrolleyReportSaving)dialog.close();});
    $('sortingMopTrolleyReportCancel').addEventListener('click',()=>{if(!state.mopTrolleyReportSaving)dialog.close();});
    $('sortingMopTrolleyReportSave').addEventListener('click',saveMopTrolleyReport);
    dialog.addEventListener('cancel',e=>{if(state.mopTrolleyReportSaving)e.preventDefault();});
  }

  function mopRequirementMap(row){
    const map=new Map();
    (Array.isArray(row?.output_trolley_requirements)?row.output_trolley_requirements:[]).forEach(r=>{
      const id=String(r.trolley_type_id||'');
      if(id)map.set(id,Number(r.quantity||0));
    });
    return map;
  }

  async function openMopTrolleyReport(){
    const row=mopSelected();if(!row)return;
    ensureMopTrolleyReportUi();
    const dialog=$('sortingMopTrolleyReportDialog'),msg=$('sortingMopTrolleyReportMessage');
    msg.textContent='';msg.className='sorting-dialog-message';
    try{
      if(!state.mopTrolleyReportReference)state.mopTrolleyReportReference=await rpc('get_trolley_reference_data');
      const types=(state.mopTrolleyReportReference?.trolley_types||[]).filter(t=>t.allowed_in_customer_schedule);
      const planned=mopRequirementMap(row);
      $('sortingMopTrolleyReportSummary').innerHTML=`<div><strong>${esc(row.customer_name)}</strong><span>${esc(row.scheduled_for_date?fullDayDate(row.scheduled_for_date):'Off schedule')} · MOP${row.route_display_name?` · ${esc(row.route_display_name)}`:''}</span></div><div><span>Published plan</span><strong>${esc(mopQueueTrolleyRequirement(row))}</strong></div>`;
      $('sortingMopTrolleyReportTypes').innerHTML=types.map(t=>`<label><span><b>${esc(t.display_code||t.trolley_type_code)}</b>${esc(t.trolley_type_name||t.trolley_type_code)}</span><input type="number" min="0" max="100" step="1" inputmode="numeric" data-mop-report-type="${esc(t.trolley_type_id)}" value="${planned.get(String(t.trolley_type_id))||0}"></label>`).join('')||'<div class="sorting-empty">No trolley types are enabled for Customer Schedule.</div>';
      $('sortingMopTrolleyReportObserved').textContent=state.mopTrolleyCodes.length?`Scanned now: ${state.mopTrolleyCodes.join(', ')}`:'No trolley scanned yet. You can still report the plan before scanning.';
      $('sortingMopTrolleyReportReason').value='';
      dialog.showModal();
    }catch(error){console.error(error);setMessage(friendly(error),'error');}
  }

  async function saveMopTrolleyReport(){
    if(state.mopTrolleyReportSaving)return;
    const row=mopSelected(),dialog=$('sortingMopTrolleyReportDialog'),msg=$('sortingMopTrolleyReportMessage'),save=$('sortingMopTrolleyReportSave');
    if(!row||!dialog?.open)return;
    const reason=$('sortingMopTrolleyReportReason').value.trim();
    if(!reason){msg.textContent='Explain what is wrong with the published trolley plan.';msg.className='sorting-dialog-message error';return;}
    const requirements=[...dialog.querySelectorAll('[data-mop-report-type]')].map(input=>({trolley_type_id:input.dataset.mopReportType,quantity:Number(input.value||0)}));
    if(requirements.some(r=>!Number.isInteger(r.quantity)||r.quantity<0||r.quantity>100)){msg.textContent='Trolley quantities must be whole numbers from 0 to 100.';msg.className='sorting-dialog-message error';return;}
    state.mopTrolleyReportSaving=true;save.disabled=true;save.textContent='Sending…';msg.textContent='Saving report without changing the published schedule…';msg.className='sorting-dialog-message';
    try{
      const result=await rpc('report_customer_trolley_requirement_issue',{p_production_flow_item_id:row.production_flow_item_id,p_source_area_code:'MOP',p_reported_requirements:requirements,p_observed_trolley_codes:state.mopTrolleyCodes,p_reason:reason});
      msg.textContent=result?.message||'Trolley plan report sent.';msg.className='sorting-dialog-message success';
      setMessage(result?.message||'Trolley plan report sent to Customer Schedule editors.','success');
      setTimeout(()=>{if(dialog.open)dialog.close();},900);
    }catch(error){console.error(error);msg.textContent=friendly(error);msg.className='sorting-dialog-message error';}
    finally{state.mopTrolleyReportSaving=false;save.disabled=false;save.textContent='Send report';}
  }

  function renderMopForm(){
    const row=mopSelected();
    if(!el.mopForm)return;
    setMopSaveMessage("");
    el.mopEmptySelection.hidden=Boolean(row);
    el.mopForm.hidden=!row;
    const staffName=state.mop?.operational_mop_staff_name||"Not assigned";
    el.mopStaffBadge.textContent=`MOP staff: ${staffName}`;
    el.mopStaffBadge.classList.toggle("missing",!state.mop?.operational_mop_staff_id);
    if(!row){el.mopSave.textContent="Save MOP production";if(el.mopLateCompletionBanner)el.mopLateCompletionBanner.hidden=true;const reportButton=$("sortingMopTrolleyReportButton");if(reportButton)reportButton.disabled=true;return;}
    const late=state.mopLateEntry;
    const lateText=late?`<p class="sorting-mop-late-mode"><strong>MISSED ENTRY</strong> Physically processed ${esc(fullDayDate(late.processedOn))}${late.processedTime?` at ${esc(late.processedTime)}`:" · time unknown"}${late.trolleyUnknown?" · trolley number unavailable":""}</p>`:"";
    if(el.mopLateCompletionBanner)el.mopLateCompletionBanner.hidden=!late;
    el.mopCustomerSummary.innerHTML=`<div><h3>${esc(row.customer_name)}</h3><p>${esc(row.scheduled_for_date?fullDayDate(row.scheduled_for_date):"Unscheduled MOP")} · Delivery ${esc(fullDayDate(row.delivery_due_date))}${row.route_display_name?` · ${esc(row.route_display_name)}`:""}</p><p>${esc(row.production_instructions||"No special MOP instructions.")}</p>${lateText}</div><div class="wash-total"><span>WASHED</span><strong>${Number(row.washed_kg_total||0).toFixed(1)} kg</strong><small>${Number(row.washed_load_count||0)} load${Number(row.washed_load_count||0)===1?"":"s"}</small></div>`;
    el.mopSave.textContent=late?"Save missed MOP entry":"Save MOP production";
    const models=mopModelRows(row);
    el.mopTypeRows.innerHTML=models.map((m,index)=>{
      const grams=Number(m.unit_weight_grams||0);
      const photo=m.image_url?`<img src="${esc(m.image_url)}" alt="${esc(m.display_name||m.variant_code||"MOP")}">`:`<span>No photo</span>`;
      return `<article class="sorting-mop-type-row" data-mop-line="${index}" data-variant-id="${esc(m.product_variant_id||"")}" data-variant-code="${esc(m.variant_code||"MOP_TOTAL")}" data-variant-name="${esc(m.display_name||m.variant_code||"MOP total")}" data-unit-grams="${grams}">
        <div class="sorting-mop-type-photo">${photo}</div><div class="sorting-mop-type-info"><strong>${esc(m.display_name||m.variant_code||"MOP total")}</strong><span>${grams>0?`1 unit = ${grams} g`:"No unit conversion configured"}${m.notes?` · ${esc(m.notes)}`:""}</span></div>
        <label class="sorting-mop-mini-field"><span>KG</span><input type="number" min="0" step="0.01" data-mop-field="kg" inputmode="decimal"></label>
        <label class="sorting-mop-mini-field"><span>Units</span><input type="number" min="0" step="1" data-mop-field="units" inputmode="numeric"></label>
      </article>`;
    }).join("");
    el.mopNotes.value="";
    renderMopTrolley();
  }

  function mopTraceLineMarkup(row){
    const lines=Array.isArray(row?.lines)?row.lines:[];
    if(!lines.length)return '<span class="sorting-mop-trace-muted">No line detail</span>';
    return `<div class="sorting-mop-trace-lines">${lines.map(line=>{
      const kg=Number(line.weight_kg||0);const units=Number(line.units||0);
      const detail=[kg>0?`${kg.toFixed(1)} kg`:'',units>0?`${units} u`:''].filter(Boolean).join(' · ');
      return `<span><strong>${esc(line.variant_name||line.variant_code||'MOP')}</strong>${detail?`<small>${esc(detail)}</small>`:''}</span>`;
    }).join('')}</div>`;
  }

  function mopActiveAbs(row){
    const batches=Array.isArray(row?.active_abs_batches)?row.active_abs_batches:[];
    return batches[0]||null;
  }

  function renderMopRecent(){
    if(!el.mopRecent)return;
    const allRows=mopRecent();
    const rows=allRows.filter(row=>row.status!=='CANCELLED');
    const traceReady=Boolean(state.mopTrace);
    if(el.mopTraceSummary){
      if(traceReady){
        const pending=rows.filter(r=>r.status==='RECORDED'&&!mopActiveAbs(r)).length;
        const posted=rows.filter(r=>r.status==='RECORDED'&&mopActiveAbs(r)).length;
        el.mopTraceSummary.innerHTML=`<span class="posted">ABS posted <strong>${posted}</strong></span><span class="pending">ABS pending <strong>${pending}</strong></span>`;
      }else{el.mopTraceSummary.innerHTML='<span class="pending">MOP Trace migration required</span>';}
    }
    if(!rows.length){el.mopRecent.innerHTML='<div class="sorting-empty">No active MOP production records yet. Cancelled revisions remain preserved in audit history.</div>';return;}
    const head='<div class="sorting-mop-trace-row sorting-mop-trace-head"><span>Customer</span><span>MOP details</span><span>Production</span><span>Trolley</span><span>Processed</span><span>ABS Batch</span><span>Actions</span></div>';
    const body=rows.map(row=>{
      const isCancelled=row.status==='CANCELLED';
      const abs=mopActiveAbs(row);
      const trolleyCodes=Array.isArray(row.trolley_codes)?row.trolley_codes:[];
      const trolley=trolleyCodes.length?trolleyCodes.join(', '):titleCode(row.trolley_capture_status||'NOT_REQUIRED');
      const processedDate=row.physical_processed_on||row.scheduled_for_date||row.business_date;
      const processedTime=row.physical_processed_time?String(row.physical_processed_time).slice(0,5):fmtTime(row.recorded_at);
      const late=row.entry_mode==='LATE_RECONCILIATION';
      const absHtml=isCancelled
        ? `<div class="sorting-mop-abs-cancelled"><span>Production cancelled</span>${row.cancellation_reason?`<small>${esc(row.cancellation_reason)}</small>`:''}</div>`
        : abs
          ? `<div class="sorting-mop-abs-posted"><span>ABS ${esc(abs.batch_reference)}</span><small>${esc(abs.recorded_by_name||'Recorded user')} · ${esc(shortDayDate(abs.batch_business_date||abs.recorded_at))} ${esc(fmtTime(abs.recorded_at))}</small></div>`
          : traceReady
            ? `<div class="sorting-mop-abs-pending"><span>ABS pending</span><button type="button" data-mop-post-abs="${esc(row.mop_production_batch_id)}">Post ABS</button></div>`
            : '<div class="sorting-mop-abs-pending"><span>ABS trace upgrade pending</span></div>';
      const customerColor=safeRouteColor(row.route_color);
      const customerFg=routeTextColor(customerColor);
      const customerStyle=customerColor?` style="--mop-customer-color:${customerColor};--mop-customer-fg:${customerFg}"`:'';
      const routeLabel=String(row.route_display_name||'').trim()||(row.route_code?`Route ${row.route_code}`:'Route not recorded');
      const revision=Number(row.revision_no||1);
      const reason=row.change_reason||row.cancellation_reason||'';
      const actionHtml=isCancelled
        ? `<div class="sorting-mop-trace-actions"><span class="sorting-mop-cancelled-badge">Cancelled</span></div>`
        : traceReady&&row.status==='RECORDED'
          ? `<div class="sorting-mop-trace-actions"><button type="button" class="correct" data-mop-correct="${esc(row.mop_production_batch_id)}">Edit</button><button type="button" class="cancel" data-mop-cancel="${esc(row.mop_production_batch_id)}"${row.live_trolley_locked?' disabled title="Live trolley lifecycle requires Trolley Control review"':''}>Cancel</button></div>`
          : '<div class="sorting-mop-trace-actions"><span class="sorting-mop-trace-muted">—</span></div>';
      return `<article class="sorting-mop-trace-row${late?' is-late':''}${isCancelled?' is-cancelled':''}">
        <div class="sorting-mop-trace-customer"${customerStyle}><strong>${esc(row.customer_name||'—')}</strong><small>${esc(shortDayDate(row.scheduled_for_date||row.physical_processed_on||row.business_date))}${late?' · Late entry':''}</small><span class="sorting-mop-trace-route">${esc(routeLabel)}</span></div>
        <div>${mopTraceLineMarkup(row)}</div>
        <div class="sorting-mop-trace-qty"><strong>${Number(row.total_kg||0).toFixed(1)} kg</strong><span>${Number(row.total_units||0)} units</span><small class="sorting-mop-revision-badge">Revision ${revision}${revision>1?' · edited':''}</small>${reason?`<small class="sorting-mop-trace-reason" title="${esc(reason)}">${esc(reason)}</small>`:''}</div>
        <div class="sorting-mop-trace-trolley"><strong>${esc(trolley)}</strong><small>${esc(titleCode(row.trolley_capture_status||'NOT_REQUIRED'))}</small></div>
        <div class="sorting-mop-trace-processed"><strong>${esc(row.operator_name||'—')}</strong><small>${esc(shortDayDate(processedDate))} · ${esc(processedTime||'—')}</small></div>
        <div>${absHtml}</div>
        <div>${actionHtml}</div>
      </article>`;
    }).join('');
    el.mopRecent.innerHTML=`<div class="sorting-mop-trace-table">${head}${body}</div>`;
  }

  function openMopAbsDialog(batchId){
    const row=mopRecent().find(item=>item.mop_production_batch_id===batchId);if(!row||mopActiveAbs(row))return;
    state.pendingMopAbsBatch=row;
    const lines=Array.isArray(row.lines)?row.lines:[];
    const lineNames=lines.map(line=>line.variant_name||line.variant_code).filter(Boolean).join(', ');
    el.mopAbsSummary.innerHTML=`<strong>${esc(row.customer_name||'—')}</strong><span>${Number(row.total_kg||0).toFixed(1)} kg · ${Number(row.total_units||0)} units${lineNames?` · ${esc(lineNames)}`:''}</span><small>Processed by ${esc(row.operator_name||'—')} · ${esc(shortDayDate(row.physical_processed_on||row.business_date))}</small>`;
    el.mopAbsBatchInput.value='';el.mopAbsNotes.value='';el.mopAbsMessage.textContent='';
    el.mopAbsDialog.showModal();setTimeout(()=>el.mopAbsBatchInput.focus(),0);
  }

  function closeMopAbsDialog(force=false){if(!force&&el.mopAbsSave?.disabled)return;state.pendingMopAbsBatch=null;el.mopAbsMessage.textContent='';el.mopAbsDialog.close();}

  async function saveMopAbsBatch(){
    const row=state.pendingMopAbsBatch;if(!row)return;
    const batchReference=String(el.mopAbsBatchInput.value||'').trim();
    const notes=String(el.mopAbsNotes.value||'').trim()||null;
    if(!batchReference){el.mopAbsMessage.textContent='ABS Batch number is required.';el.mopAbsBatchInput.focus();return;}
    el.mopAbsSave.disabled=true;el.mopAbsMessage.textContent='Posting ABS Batch…';
    try{
      const result=await rpc('record_sorting_mop_abs_batch',{p_mop_production_batch_id:row.mop_production_batch_id,p_batch_reference:batchReference,p_notes:notes});
      closeMopAbsDialog(true);await loadMop();setMessage(result?.message||`ABS batch ${batchReference} recorded.`,'success');
    }catch(error){console.error(error);el.mopAbsMessage.textContent=friendly(error);}
    finally{el.mopAbsSave.disabled=false;}
  }

  function mopCorrectionCurrentLineMap(context){
    const map=new Map();
    (Array.isArray(context?.lines)?context.lines:[]).forEach(line=>{
      const key=line.product_variant_id||line.variant_code||'MOP_TOTAL';
      map.set(String(key),line);
    });
    return map;
  }

  function renderMopCorrectionHistory(context){
    if(!el.mopCorrectionHistory)return;
    const rows=Array.isArray(context?.revision_history)?context.revision_history:[];
    el.mopCorrectionHistory.innerHTML=rows.length?rows.map(row=>{
      const status=row.status==='RECORDED'?'Current':row.cancellation_kind==='CORRECTED'?'Superseded':'Cancelled';
      const reason=row.change_reason||row.cancellation_reason||'';
      const who=row.cancelled_by_name||row.recorded_by_name||'Recorded user';
      const when=row.cancelled_at||row.recorded_at;
      return `<div class="sorting-mop-revision-row ${esc(String(row.status||'').toLowerCase())}"><span>Revision ${esc(row.revision_no||1)}</span><strong>${esc(status)}</strong><small>${Number(row.total_kg||0).toFixed(1)} kg · ${Number(row.total_units||0)} units · ${esc(who)} · ${esc(shortDayDate(when))} ${esc(fmtTime(when))}${reason?`<br>${esc(reason)}`:''}</small></div>`;
    }).join(''):'<div class="sorting-empty">No revision history.</div>';
  }

  function renderMopCorrectionDialog(context){
    const batch=context?.batch;if(!batch)return;
    const route=context?.flow?.route_display_name||context?.flow?.route_code||'';
    const current=mopCorrectionCurrentLineMap(context);
    const variants=Array.isArray(context?.available_variants)?context.available_variants:[];
    el.mopCorrectionSummary.innerHTML=`<strong>${esc(batch.customer_name||'—')}</strong><span>Revision ${esc(batch.revision_no||1)} · ${Number(batch.total_kg||0).toFixed(1)} kg · ${Number(batch.total_units||0)} units${route?` · ${esc(route)}`:''}</span><small>Physical production remains ${esc(shortDayDate(batch.physical_processed_on||batch.business_date))}${batch.physical_processed_time?` · ${esc(String(batch.physical_processed_time).slice(0,5))}`:''}. Correction changes the recorded evidence, not the physical processing time.</small>`;
    el.mopCorrectionLines.innerHTML=variants.map((variant,index)=>{
      const key=variant.product_variant_id||variant.variant_code||'MOP_TOTAL';
      const line=current.get(String(key))||{};
      const grams=Number(variant.unit_weight_grams||line.unit_weight_grams||0);
      const photo=variant.image_url?`<img src="${esc(variant.image_url)}" alt="${esc(variant.display_name||variant.variant_code||'MOP')}">`:'<span>No photo</span>';
      return `<article class="sorting-mop-correction-line${Number(line.weight_kg||0)>0||Number(line.units||0)>0?' has-value':''}" data-mop-correction-line="${index}" data-variant-id="${esc(variant.product_variant_id||'')}" data-variant-code="${esc(variant.variant_code||'MOP_TOTAL')}" data-unit-grams="${grams}">
        <div class="sorting-mop-correction-photo">${photo}</div>
        <div class="sorting-mop-correction-type"><strong>${esc(variant.display_name||variant.variant_code||'MOP total')}</strong><small>${grams>0?`1 unit = ${grams} g`:'No unit conversion configured'}</small></div>
        <label><span>KG</span><input type="number" min="0" step="0.01" inputmode="decimal" data-mop-correction-field="kg" value="${Number(line.weight_kg||0)>0?esc(Number(line.weight_kg).toFixed(2).replace(/\.00$/,'')):''}"></label>
        <label><span>Units</span><input type="number" min="0" step="1" inputmode="numeric" data-mop-correction-field="units" value="${Number(line.units||0)>0?esc(line.units):''}"></label>
      </article>`;
    }).join('');

    const trolleys=(Array.isArray(context?.trolleys)?context.trolleys:[]).map(t=>t.trolley_code).filter(Boolean);
    const lateEditable=Boolean(context?.late_trolley_reference_editable);
    el.mopCorrectionTrolleyMode.textContent=lateEditable?'Late reference only — editable':'Live lifecycle evidence — read only';
    el.mopCorrectionTrolleyLocked.hidden=lateEditable;
    el.mopCorrectionTrolleyCodesWrap.hidden=!lateEditable;
    el.mopCorrectionTrolleyUnknownWrap.hidden=!lateEditable;
    if(lateEditable){
      el.mopCorrectionTrolleyCodes.value=trolleys.join(', ');
      el.mopCorrectionTrolleyUnknown.checked=batch.trolley_capture_status==='UNKNOWN_LATE_ENTRY';
      el.mopCorrectionTrolleyCodes.disabled=el.mopCorrectionTrolleyUnknown.checked;
    }else{
      el.mopCorrectionTrolleyLocked.innerHTML=`<strong>${trolleys.length?esc(trolleys.join(', ')):esc(titleCode(batch.trolley_capture_status||'NOT_REQUIRED'))}</strong><span>Live trolley codes are linked to physical custody. They cannot be replaced from this correction dialog.</span>`;
      el.mopCorrectionTrolleyCodes.value=trolleys.join(', ');
      el.mopCorrectionTrolleyUnknown.checked=false;
    }
    el.mopCorrectionNotes.value=batch.notes||'';
    el.mopCorrectionReason.value='';
    el.mopCorrectionMessage.textContent='';
    renderMopCorrectionHistory(context);
  }

  async function openMopCorrectionDialog(batchId){
    const row=mopRecent().find(item=>item.mop_production_batch_id===batchId);if(!row||row.status!=='RECORDED')return;
    state.pendingMopCorrectionBatch=row;state.mopCorrectionContext=null;
    el.mopCorrectionMessage.textContent='Loading edit history…';
    if(!el.mopCorrectionDialog.open)el.mopCorrectionDialog.showModal();
    try{
      const context=await rpc('get_sorting_mop_production_correction_context',{p_mop_production_batch_id:batchId});
      state.mopCorrectionContext=context;renderMopCorrectionDialog(context);
    }catch(error){console.error(error);el.mopCorrectionMessage.textContent=friendly(error);}
  }

  function closeMopCorrectionDialog(force=false){
    if(!force&&state.mopCorrectionSaving)return;
    state.pendingMopCorrectionBatch=null;state.mopCorrectionContext=null;state.mopCorrectionSaving=false;
    el.mopCorrectionMessage.textContent='';if(el.mopCorrectionDialog.open)el.mopCorrectionDialog.close();
  }

  function recalcMopCorrectionLine(input){
    const card=input.closest('[data-mop-correction-line]');if(!card)return;
    const grams=Number(card.dataset.unitGrams||0);
    const kg=card.querySelector('[data-mop-correction-field="kg"]');
    const units=card.querySelector('[data-mop-correction-field="units"]');
    if(grams>0){
      if(input===kg&&Number(kg.value)>0&&!units.matches(':focus'))units.value=String(Math.round(Number(kg.value)*1000/grams));
      if(input===units&&Number(units.value)>0&&!kg.matches(':focus'))kg.value=(Number(units.value)*grams/1000).toFixed(2);
    }
    card.classList.toggle('has-value',Number(kg.value)>0||Number(units.value)>0);
  }

  function collectMopCorrectionLines(){
    return [...el.mopCorrectionLines.querySelectorAll('[data-mop-correction-line]')].map(card=>({
      product_variant_id:card.dataset.variantId||null,
      weight_kg:Number(card.querySelector('[data-mop-correction-field="kg"]')?.value||0)||null,
      units:Math.round(Number(card.querySelector('[data-mop-correction-field="units"]')?.value||0))||null
    })).filter(line=>Number(line.weight_kg||0)>0||Number(line.units||0)>0);
  }

  function parseMopCorrectionTrolleys(value){
    return [...new Set(String(value||'').toUpperCase().split(/[\s,;]+/).map(v=>v.trim()).filter(Boolean))];
  }

  async function saveMopCorrection(){
    const context=state.mopCorrectionContext,batch=context?.batch;if(!batch||state.mopCorrectionSaving)return;
    const reason=String(el.mopCorrectionReason.value||'').trim();
    const lines=collectMopCorrectionLines();
    if(reason.length<5){el.mopCorrectionMessage.textContent='Enter an edit reason with at least 5 characters.';el.mopCorrectionReason.focus();return;}
    if(!lines.length){el.mopCorrectionMessage.textContent='Enter KG or Units for at least one MOP type.';return;}
    const late=Boolean(context.late_trolley_reference_editable);
    const unknown=late?Boolean(el.mopCorrectionTrolleyUnknown.checked):false;
    const trolleyCodes=late?parseMopCorrectionTrolleys(el.mopCorrectionTrolleyCodes.value):null;
    if(trolleyCodes&&trolleyCodes.some(code=>!/^T\d{1,10}T$/.test(code))){el.mopCorrectionMessage.textContent='Invalid trolley code. Expected format like T123T.';return;}
    if(unknown&&trolleyCodes?.length){el.mopCorrectionMessage.textContent='Choose late trolley references or Trolley number unavailable, not both.';return;}
    state.mopCorrectionSaving=true;el.mopCorrectionSave.disabled=true;el.mopCorrectionMessage.textContent='Saving a new revision…';
    try{
      const result=await rpc('correct_sorting_mop_production',{
        p_mop_production_batch_id:batch.mop_production_batch_id,
        p_reason:reason,p_lines:lines,p_notes:String(el.mopCorrectionNotes.value||'').trim()||null,
        p_trolley_codes:trolleyCodes,p_trolley_unknown:late?unknown:null
      });
      closeMopCorrectionDialog(true);await loadMop();setMessage(result?.message||'MOP Production updated as a new revision. Original evidence preserved.','success');
    }catch(error){console.error(error);el.mopCorrectionMessage.textContent=friendly(error);}
    finally{state.mopCorrectionSaving=false;el.mopCorrectionSave.disabled=false;}
  }

  function openMopCancelDialog(batchId){
    const row=mopRecent().find(item=>item.mop_production_batch_id===batchId);if(!row||row.status!=='RECORDED')return;
    if(row.live_trolley_locked){setMessage('Cancellation is blocked because this MOP Production owns live trolley lifecycle evidence. Use Edit for quantities/types, or review the physical trolley in Trolley Control.','warning');return;}
    state.pendingMopCancelBatch=row;
    const abs=mopActiveAbs(row);const route=row.route_display_name||(row.route_code?`Route ${row.route_code}`:'');
    el.mopCancelSummary.innerHTML=`<strong>${esc(row.customer_name||'—')}</strong><span>Revision ${esc(row.revision_no||1)} · ${Number(row.total_kg||0).toFixed(1)} kg · ${Number(row.total_units||0)} units${route?` · ${esc(route)}`:''}</span><small>This removes only the active MOP Production status. Washing remains recorded and the customer returns to the production queue.</small>`;
    el.mopCancelAbsWarning.hidden=!abs;el.mopCancelAbsEvidence.checked=false;
    if(abs)el.mopCancelAbsWarning.querySelector('strong').textContent=`Also cancel ABS ${abs.batch_reference} evidence in ElisCaretex Trace`;
    el.mopCancelReason.value='';el.mopCancelMessage.textContent='';el.mopCancelSave.disabled=false;
    el.mopCancelDialog.showModal();setTimeout(()=>el.mopCancelReason.focus(),0);
  }

  function closeMopCancelDialog(force=false){
    if(!force&&state.mopCancelSaving)return;
    state.pendingMopCancelBatch=null;state.mopCancelSaving=false;el.mopCancelMessage.textContent='';if(el.mopCancelDialog.open)el.mopCancelDialog.close();
  }

  async function saveMopCancellation(){
    const row=state.pendingMopCancelBatch;if(!row||state.mopCancelSaving)return;
    const reason=String(el.mopCancelReason.value||'').trim();if(reason.length<5){el.mopCancelMessage.textContent='Enter a cancellation reason with at least 5 characters.';el.mopCancelReason.focus();return;}
    const abs=mopActiveAbs(row);if(abs&&!el.mopCancelAbsEvidence.checked){el.mopCancelMessage.textContent=`ABS ${abs.batch_reference} is still active. Tick the confirmation if you also want to cancel that local ElisCaretex evidence.`;return;}
    state.mopCancelSaving=true;el.mopCancelSave.disabled=true;el.mopCancelMessage.textContent='Cancelling MOP Production…';
    try{
      const result=await rpc('cancel_sorting_mop_production',{p_mop_production_batch_id:row.mop_production_batch_id,p_reason:reason,p_cancel_abs_evidence:Boolean(abs&&el.mopCancelAbsEvidence.checked)});
      closeMopCancelDialog(true);await loadMop();setMessage(result?.message||'MOP Production cancelled and returned to the queue.','success');
    }catch(error){console.error(error);el.mopCancelMessage.textContent=friendly(error);}
    finally{state.mopCancelSaving=false;el.mopCancelSave.disabled=false;}
  }

  function renderMop(){renderMopDueBanner();renderMopQueue();renderMopForm();renderMopRecent();}

  async function loadMop(){
    try{
      const [mopContext,traceContext]=await Promise.all([
        rpc("get_sorting_mop_production_context",{p_shift_code:state.shift}),
        rpc("get_sorting_mop_recent_trace",{p_limit:30}).catch(error=>{console.warn('Snapshot 93 MOP trace is not available until Migration 033 is applied.',error);return null;})
      ]);
      state.mop=mopContext;state.mopTrace=traceContext;
      if(standaloneMop){
        const businessDate=String(mopContext?.business_date||"").slice(0,10);
        if(el.businessDate)el.businessDate.textContent=businessDate?fmtDate(businessDate):"—";
        if(el.sidebarDate)el.sidebarDate.textContent=businessDate?fmtDate(businessDate):"—";
        if(el.rosterSource)el.rosterSource.textContent=mopContext?.operational_mop_staff_name||"No dedicated MOP staff";
        if(el.plannedCount)el.plannedCount.textContent=titleCode(mopContext?.operational_mop_coverage||"UNRESOLVED");
        if(el.sessionName)el.sessionName.textContent="MOP Production";
        if(el.businessDateStatus){el.businessDateStatus.textContent="Shared operational Business Date";el.businessDateStatus.className="sorting-business-date-status";}
      }
      if(state.mopSelectedFlowId&&!mopQueue().some(r=>r.production_flow_item_id===state.mopSelectedFlowId)){
        state.mopSelectedFlowId=null;state.mopTrolleyCodes=[];state.mopLateEntry=null;
      }
      renderMop();
    }catch(error){
      console.warn("MOP Production V2 is not available until Migration 030 is applied.",error);
      state.mop={queue:[],recent_production:[],migration_required:true};state.mopTrace=null;
      renderMop();
      if(el.mopQueue)el.mopQueue.innerHTML='<div class="sorting-empty">MOP Production backend is not available yet. Apply Migration 030 first.</div>';
    }
  }

  function selectMopFlow(flowId,{reconcile=true}={}){
    const row=mopQueue().find(r=>r.production_flow_item_id===flowId);
    if(!row)return;
    if(hasMopProductionDraft()){
      if(flowId===state.mopSelectedFlowId){
        setMessage("This MOP production draft is already open. Finish the KG / Units entry or Clear it.","warning");
        el.mopLateCompletionBanner?.scrollIntoView({behavior:"smooth",block:"center"});
      }else{
        setMessage(mopDraftWarning("opening another customer"),"warning");
      }
      return;
    }
    state.mopSelectedFlowId=flowId;state.mopTrolleyCodes=[];state.mopLateEntry=null;
    renderMop();
    if(reconcile&&["RECONCILIATION_REQUIRED","NOT_PROCESSED_CONFIRMED"].includes(row.production_status))openMopReconciliation(row);
  }

  function addMopTrolley(){
    const raw=String(el.mopTrolleyInput.value||"").trim().toUpperCase().replace(/\s+/g,"");
    if(!raw)return;
    if(!/^T\d{1,10}T$/.test(raw))return setMessage("Invalid trolley code. Expected format like T123T.","error");
    if(!state.mopTrolleyCodes.includes(raw))state.mopTrolleyCodes.push(raw);
    el.mopTrolleyInput.value="";renderMopTrolley();
  }

  function recalcMopLine(input){
    const card=input.closest("[data-mop-line]");if(!card)return;
    const grams=Number(card.dataset.unitGrams||0);
    const kgInput=card.querySelector('[data-mop-field="kg"]');
    const unitInput=card.querySelector('[data-mop-field="units"]');
    if(grams>0){
      if(input===kgInput&&Number(kgInput.value)>0&&!unitInput.matches(":focus"))unitInput.value=String(Math.round(Number(kgInput.value)*1000/grams));
      if(input===unitInput&&Number(unitInput.value)>0&&!kgInput.matches(":focus"))kgInput.value=(Number(unitInput.value)*grams/1000).toFixed(2);
    }
    card.classList.toggle("has-value",Number(kgInput.value)>0||Number(unitInput.value)>0);
  }

  function collectMopLines(){
    return [...el.mopTypeRows.querySelectorAll("[data-mop-line]")].map(card=>{
      let kg=Number(card.querySelector('[data-mop-field="kg"]')?.value||0);
      let units=Math.round(Number(card.querySelector('[data-mop-field="units"]')?.value||0));
      const grams=Number(card.dataset.unitGrams||0);
      if(kg<=0&&units>0&&grams>0)kg=units*grams/1000;
      if(units<=0&&kg>0&&grams>0)units=Math.round(kg*1000/grams);
      if(kg<=0&&units<=0)return null;
      return {product_variant_id:card.dataset.variantId||null,variant_code:card.dataset.variantCode||"MOP_TOTAL",variant_name:card.dataset.variantName||"MOP total",weight_kg:kg>0?Number(kg.toFixed(3)):null,units:units>0?units:null,unit_weight_grams:grams>0?grams:null};
    }).filter(Boolean);
  }

  async function saveMopProduction(){
    const row=mopSelected();
    if(!row){setMopSaveMessage("Select a MOP customer before saving.","warning");return;}
    const staffId=state.mop?.operational_mop_staff_id;
    if(!staffId){
      const message="No Actual MOP staff is available for this Shift. Set one available staff member as Actual MOP in Staff before saving.";
      setMopSaveMessage(message,"warning");setMessage(message,"warning");return;
    }
    const lines=collectMopLines();
    if(!lines.length){
      const message="Enter KG or Units in at least one MOP type before saving.";
      setMopSaveMessage(message,"warning");setMessage(message,"warning");return;
    }
    const required=Boolean(row.output_trolley_required);
    const lateUnknown=Boolean(state.mopLateEntry?.trolleyUnknown);
    if(required&&!lateUnknown&&!state.mopTrolleyCodes.length){
      const message=state.mopLateEntry
        ? "This missed entry expects a trolley. Scan the trolley if the code is known, or tick Trolley number no longer available below the trolley section."
        : "Scan the clean trolley used for this customer before saving.";
      setMopSaveMessage(message,"warning");setMessage(message,"warning");return;
    }
    el.mopSave.disabled=true;
    setMopSaveMessage("Saving MOP production…","info");
    setMessage("Saving MOP production…");
    try{
      const result=await rpc("save_sorting_mop_production",{
        p_shift_code:state.shift,
        p_production_flow_item_id:row.production_flow_item_id,
        p_operator_staff_id:staffId,
        p_lines:lines,
        p_trolley_codes:state.mopTrolleyCodes,
        p_trolley_unknown:lateUnknown,
        p_physical_processed_on:state.mopLateEntry?.processedOn||null,
        p_physical_processed_time:state.mopLateEntry?.processedTime||null,
        p_entry_mode:state.mopLateEntry?"LATE_RECONCILIATION":"LIVE",
        p_notes:state.mopLateEntry
          ? `Missed entry reason: ${state.mopLateEntry.reason}${el.mopNotes.value.trim()?` | ${el.mopNotes.value.trim()}`:""}`
          : (el.mopNotes.value.trim()||null)
      });
      state.mopSelectedFlowId=null;state.mopTrolleyCodes=[];state.mopLateEntry=null;state.mopReconciliationFlowId=null;
      setMopSaveMessage("");
      await loadMop();if(!standaloneMop)await loadStaffWork();
      setMessage(result?.message||"MOP production recorded.","success");
      enforceMopReconciliation();
    }catch(error){
      console.error(error);
      const message=friendly(error);
      setMopSaveMessage(message,"error");
      setMessage(message,"error");
    }finally{el.mopSave.disabled=false;}
  }

  function resetMopReconciliationPanels(){
    el.mopLateEntryPanel.hidden=true;el.mopNotProcessedPanel.hidden=true;
    el.mopReconciliationMessage.textContent="";el.mopNotProcessedReason.value="";
    if(el.mopLateReason)el.mopLateReason.value="";
    el.mopLateTrolleyUnknown.checked=false;
  }

  function openMopReconciliation(row){
    if(!row)return;
    state.mopReconciliationFlowId=row.production_flow_item_id;
    resetMopReconciliationPanels();
    el.mopReconciliationSummary.innerHTML=`<strong>${esc(row.customer_name)}</strong>${esc(row.scheduled_for_date?fullDayDate(row.scheduled_for_date):"Unscheduled MOP")} · Delivery due ${esc(fullDayDate(row.delivery_due_date))}<br>Washed ${Number(row.washed_kg_total||0).toFixed(1)} kg · ${Number(row.washed_load_count||0)} load${Number(row.washed_load_count||0)===1?"":"s"}`;
    const alreadyNotProcessed=row.production_status==="NOT_PROCESSED_CONFIRMED";
    const notButton=el.mopReconciliationChoices.querySelector('[data-mop-reconciliation-choice="NOT_PROCESSED"]');
    if(notButton)notButton.hidden=alreadyNotProcessed;
    if(!el.mopReconciliationDialog.open)el.mopReconciliationDialog.showModal();
  }

  function reconciliationRow(){return mopQueue().find(r=>r.production_flow_item_id===state.mopReconciliationFlowId)||null;}

  function chooseMopReconciliation(choice){
    const row=reconciliationRow();if(!row)return;
    resetMopReconciliationPanels();
    if(choice==="PROCESSED"){
      el.mopLateEntryPanel.hidden=false;
      el.mopLateProcessedDate.value=row.scheduled_for_date||row.opened_business_date||state.mop?.business_date||"";
      el.mopLateProcessedTime.value="";
      el.mopLateReason.value="";
      el.mopLateTrolleyUnknownLabel.hidden=!row.output_trolley_required;
    }else if(choice==="NOT_PROCESSED")el.mopNotProcessedPanel.hidden=false;
  }

  function continueMopLateEntry(){
    const row=reconciliationRow();if(!row)return;
    const processedOn=el.mopLateProcessedDate.value;
    const missedReason=el.mopLateReason.value.trim();
    if(!processedOn){el.mopReconciliationMessage.textContent="Choose the date the MOP was physically processed.";return;}
    if(missedReason.length<3){el.mopReconciliationMessage.textContent="Enter a short reason why the production entry was missed.";return;}
    state.mopSelectedFlowId=row.production_flow_item_id;
    state.mopTrolleyCodes=[];
    state.mopLateEntry={processedOn,processedTime:el.mopLateProcessedTime.value||null,trolleyUnknown:Boolean(el.mopLateTrolleyUnknown.checked),reason:missedReason};
    el.mopReconciliationDialog.close();renderMop();
    setMessage("Step 2 of 2: enter the actual processed KG or Units, then Save missed MOP entry. This confirmation remains unresolved until Save succeeds.","warning");
    requestAnimationFrame(()=>{
      el.mopLateCompletionBanner?.scrollIntoView({behavior:"smooth",block:"center"});
      setTimeout(()=>el.mopTypeRows?.querySelector('[data-mop-field="kg"],[data-mop-field="units"]')?.focus(),350);
    });
  }

  async function saveMopNotProcessed(){
    const row=reconciliationRow();if(!row)return;
    const reason=el.mopNotProcessedReason.value.trim();
    if(reason.length<3){el.mopReconciliationMessage.textContent="Enter a short reason.";return;}
    const staffId=state.mop?.operational_mop_staff_id;
    if(!staffId){el.mopReconciliationMessage.textContent="Set an available Actual MOP staff member first.";return;}
    el.mopNotProcessedSave.disabled=true;
    try{
      await rpc("record_sorting_mop_reconciliation",{p_shift_code:state.shift,p_production_flow_item_id:row.production_flow_item_id,p_operator_staff_id:staffId,p_decision:"NOT_PROCESSED",p_reason:reason});
      el.mopReconciliationDialog.close();state.mopReconciliationFlowId=null;
      await loadMop();setMessage(`${row.customer_name} recorded as not processed. It remains visible in the MOP queue.`,"warning");enforceMopReconciliation();
    }catch(error){console.error(error);el.mopReconciliationMessage.textContent=friendly(error);}
    finally{el.mopNotProcessedSave.disabled=false;}
  }

  function enforceMopReconciliation(){
    if(state.view!=="mop"||!state.mop||el.mopReconciliationDialog?.open||hasMopProductionDraft())return;
    const row=mopQueue().find(r=>r.production_status==="RECONCILIATION_REQUIRED");
    if(row)openMopReconciliation(row);
  }

  /* =====================================================================
     Snapshot 99 — Shared Production Tracker
     Planned source: published Customer Schedule.
     Actual sources: Production Flow, Washing, area production, shared ABS and trolley lifecycle.
     ===================================================================== */
  function trackerIsoShift(iso,days){
    const d=new Date(`${String(iso).slice(0,10)}T12:00:00`);d.setDate(d.getDate()+days);
    return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;
  }
  function trackerIsSunday(iso){return new Date(`${String(iso).slice(0,10)}T12:00:00`).getDay()===0;}
  function trackerPrevDay(iso){let d=String(iso);do{d=trackerIsoShift(d,-1);}while(trackerIsSunday(d));return d;}
  function trackerNextDay(iso){let d=String(iso);do{d=trackerIsoShift(d,1);}while(trackerIsSunday(d));return d;}
  function trackerBaseToday(){return state.trackerTodayDate||state.washing?.business_date||new Date().toISOString().slice(0,10);}
  function trackerCardDates(){const t=trackerBaseToday();return [trackerPrevDay(t),t,trackerNextDay(t)];}
  function trackerStatusMeta(status){
    return {
      NOT_STARTED:{label:"Not started",cls:"not-started",icon:"○"},
      WASHED_ONLY:{label:"Washed",cls:"washed",icon:"≈"},
      ABS_PENDING:{label:"ABS pending",cls:"abs-pending",icon:"◷"},
      TRACKER_OK:{label:"Tracker OK",cls:"tracker-ok",icon:"✓"},
      IN_PROGRESS:{label:"In progress",cls:"in-progress",icon:"↻"}
    }[String(status||"").toUpperCase()]||{label:titleCode(status||"Unknown"),cls:"unknown",icon:"?"};
  }
  function trackerBadge(status){const m=trackerStatusMeta(status);return `<span class="sorting-tracker-badge ${m.cls}"><b>${m.icon}</b>${esc(m.label)}</span>`;}
  function trackerStrict(data){
    if(data?.schema_version!=="PRODUCTION_TRACKER_V4"||data?.source_contract!=="PRODUCTION_FLOW_SHARED_TRACKER_V4"){
      throw new Error("Tracker backend contract is out of date. Apply Migration 044 before using this screen.");
    }
  }
  function trackerSourceData(){return state.trackerDemoActive&&state.trackerDemoData?state.trackerDemoData:state.trackerData;}
  function trackerProductRank(code){return String(code||"").toUpperCase()==="CLOTHES"?1:String(code||"").toUpperCase()==="MOP"?2:9;}
  function trackerPriorityTuple(group,requestedType=""){
    const type=String(requestedType||"").toUpperCase();
    const products=(group.products||[]).filter(p=>!type||String(p.product_code||"").toUpperCase()===type);
    const candidates=products.length?products:(group.products||[]);
    let best=[9,2147483647,String(group.customer_name||"").toLowerCase()];
    candidates.forEach(p=>{
      const tuple=[trackerProductRank(p.product_code),Number(p.production_order??2147483647),String(group.customer_name||"").toLowerCase()];
      if(tuple[0]<best[0]||(tuple[0]===best[0]&&(tuple[1]<best[1]||(tuple[1]===best[1]&&tuple[2]<best[2]))))best=tuple;
    });
    return [group.scheduled?0:1,...best];
  }
  function trackerGroupPrioritySort(a,b){
    const type=String(el.trackerTypeFilter?.value||"").toUpperCase();
    const aa=trackerPriorityTuple(a,type),bb=trackerPriorityTuple(b,type);
    for(let i=0;i<aa.length;i++){if(aa[i]<bb[i])return -1;if(aa[i]>bb[i])return 1;}
    return 0;
  }
  function trackerGroups(){
    const map=new Map();
    (trackerSourceData()?.items||[]).forEach(item=>{
      const key=item.customer_id||`${item.customer_name}:${item.scheduled_for_date}`;
      if(!map.has(key))map.set(key,{customer_id:item.customer_id,customer_name:item.customer_name,customer_code:item.customer_code,customer_status:item.customer_status,scheduled:Boolean(item.scheduled),route_code:item.route_code,route_display_name:item.route_display_name,route_color:item.route_color,production_order:item.production_order,products:[]});
      const g=map.get(key);g.products.push(item);
      if(g.production_order==null||Number(item.production_order)<Number(g.production_order))g.production_order=item.production_order;
      if(!g.route_display_name&&item.route_display_name){g.route_display_name=item.route_display_name;g.route_code=item.route_code;g.route_color=item.route_color;}
    });
    return [...map.values()];
  }
  function trackerDemoDataset(){
    const date=state.trackerDate||trackerBaseToday();
    const stamp=`${date}T09:15:00.000Z`;
    const wash=(code,washer,operator,kg,time="08:10:00",basis="EQUAL_SPLIT_ESTIMATE")=>[{wash_run_id:`DEMO-${code}`,wash_code:code,trace_code:`${code}-01`,washer_code:washer.split(" ")[0],washer_name:washer,operator_name:operator,started_at:`${date}T${time}.000Z`,registered_at:`${date}T${time}.000Z`,allocated_weight_kg:kg,weight_allocation_method:basis}];
    const dims={SMALL:{l:68,w:52,tare:29.2},MEDIUM:{l:90,w:70,tare:42},LARGE:{l:91,w:70,tare:48.6}};
    const physical=(type)=>{const d=dims[type]||{};return {footprint_length_cm:d.l||null,footprint_width_cm:d.w||null,footprint_area_m2:d.l&&d.w?d.l*d.w/10000:null,tare_weight_kg:d.tare||null,physical_master_complete:Boolean(d.l&&d.w&&d.tare)};};
    const req=(type,qty)=>[{trolley_type_code:type,display_code:type==="SMALL"?"S":type==="MEDIUM"?"M":type==="LARGE"?"L":type,trolley_type_name:`${titleCode(type)} Trolley`,quantity:qty,empty_trolley:false,...physical(type)}];
    const trolley=(code,type)=>({trolley_code:code,trolley_type_code:type,display_code:type==="SMALL"?"S":type==="MEDIUM"?"M":type==="LARGE"?"L":type,trolley_type_name:`${titleCode(type)} Trolley`,lifecycle_action:"PRODUCTION_ASSIGNMENT",...physical(type)});
    const base=(id,name,type,order,color,route,status)=>({
      customer_id:`demo-${id}`,customer_code:`DEMO-${id}`,customer_name:name,customer_status:status,scheduled:true,scheduled_for_date:date,
      product_code:type,product_status:status,production_order:order,route_code:route.replace("Route ",""),route_display_name:route,route_color:color,
      expected_kg:null,expected_units:null,production_flow_item_id:`demo-flow-${id}-${type}`,flow_code:`DEMO-PF-${id}-${type}`,flow_origin:"DEMO_PREVIEW",
      current_stage_code:status==="NOT_STARTED"?"INTAKE":status==="WASHED_ONLY"?"WASHING":"PRODUCTION",flow_status:"OPEN",
      washed_kg_total:0,washed_quantity_kg:0,washed_quantity_units:null,washed_quantity_basis:null,washed_units_source:"NOT_MEASURED_IN_WASHING",washed_load_count:0,wash_details:[],
      mop_production_batch_id:null,production_operator_name:null,processed_weight_kg:null,processed_units:null,processed_quantity_kg:null,processed_quantity_units:null,processed_quantity_source:type==="CLOTHES"?"FINISH_PENDING":"NOT_RECORDED",
      processed_at:null,production_revision_no:null,production_lines:[],trolley_capture_status:null,planned_trolley_quantity:0,planned_trolley_requirements:[],mop_trolleys:[],lifecycle_trolleys:[],abs_count:0,abs_details:[],batch_references:[]
    });
    const a=base("01","DEMO · Oakview Care","CLOTHES",1,"#4d93d9","Route 611","NOT_STARTED");a.expected_kg=70;a.planned_trolley_quantity=2;a.planned_trolley_requirements=req("LARGE",2);
    const b=base("02","DEMO · Riverside House","CLOTHES",2,"#00b050","Route 610","WASHED_ONLY");b.washed_kg_total=b.washed_quantity_kg=62;b.washed_quantity_basis="FULL_LOAD";b.washed_load_count=1;b.wash_details=wash("W-DEMO-102","WA01 [90KG] CLOTHES","Demo Operator",62,"08:05:00","FULL_LOAD");b.planned_trolley_quantity=1;b.planned_trolley_requirements=req("MEDIUM",1);b.lifecycle_trolleys=[trolley("T900001T","MEDIUM")];
    const c=base("03","DEMO · St Anne's Unit","CLOTHES",3,"#ffc000","Route 616","WASHED_ONLY");c.washed_kg_total=c.washed_quantity_kg=44;c.washed_quantity_basis="EQUAL_SPLIT_ESTIMATE";c.washed_load_count=1;c.wash_details=wash("W-DEMO-103","WA07 [90KG] CLOTHES","Demo Operator",44,"08:42:00");c.planned_trolley_quantity=2;c.planned_trolley_requirements=req("SMALL",2);c.lifecycle_trolleys=[trolley("T900002T","SMALL")];
    const mixC=base("04C","DEMO · Meadowlands","CLOTHES",4,"#9900cc","Route 613","IN_PROGRESS");mixC.customer_id="demo-04";mixC.washed_kg_total=mixC.washed_quantity_kg=36;mixC.washed_quantity_basis="EQUAL_SPLIT_ESTIMATE";mixC.washed_load_count=1;mixC.wash_details=wash("W-DEMO-104","WA02 [90KG] CLOTHES","Demo Operator",36,"09:00:00");mixC.planned_trolley_quantity=1;mixC.planned_trolley_requirements=req("LARGE",1);mixC.lifecycle_trolleys=[trolley("T900004T","LARGE")];
    const d=base("05","DEMO · MOP North Unit","MOP",1,"#e561dc","Route 612","NOT_STARTED");d.expected_units=450;d.planned_trolley_quantity=1;d.planned_trolley_requirements=req("SMALL",1);
    const e=base("06","DEMO · MOP South Unit","MOP",2,"#fefe00","Route 615","WASHED_ONLY");e.washed_kg_total=e.washed_quantity_kg=50;e.washed_quantity_basis="EQUAL_SPLIT_ESTIMATE";e.washed_load_count=1;e.wash_details=wash("W-DEMO-202","WA08 [100KG] HOUSEHOLD","Demo Operator",50,"08:18:00");e.planned_trolley_quantity=1;e.planned_trolley_requirements=req("MEDIUM",1);
    const f=base("07","DEMO · MOP Rehab","MOP",3,"#ff0000","Route 618","ABS_PENDING");f.washed_kg_total=f.washed_quantity_kg=48;f.washed_quantity_basis="EQUAL_SPLIT_ESTIMATE";f.washed_load_count=1;f.wash_details=wash("W-DEMO-203","WA09 [60KG] HOUSEHOLD","Demo Operator",48,"08:33:00");f.mop_production_batch_id="demo-mop-07";f.production_operator_name="Demo MOP Operator";f.processed_weight_kg=f.processed_quantity_kg=50.4;f.processed_units=f.processed_quantity_units=504;f.processed_quantity_source="MOP_PRODUCTION";f.processed_at=`${date}T09:28:00.000Z`;f.production_revision_no=1;f.production_lines=[{variant_name:"Velcro Mop",variant_code:"VELCRO_MOP",weight_kg:36,units:360},{variant_name:"Cleaning Cloths",variant_code:"CLEANING_CLOTHS",weight_kg:14.4,units:144}];f.trolley_capture_status="RECORDED";f.planned_trolley_quantity=2;f.planned_trolley_requirements=req("LARGE",2);f.mop_trolleys=[trolley("T900101T","LARGE")];f.lifecycle_trolleys=[trolley("T900101T","LARGE")];
    const g=base("08","DEMO · MOP Central","MOP",4,"#f2ceef","Route 617","TRACKER_OK");g.washed_kg_total=g.washed_quantity_kg=54;g.washed_quantity_basis="FULL_LOAD";g.washed_load_count=1;g.wash_details=wash("W-DEMO-204","WA08 [100KG] HOUSEHOLD","Demo Operator",54,"07:55:00","FULL_LOAD");g.mop_production_batch_id="demo-mop-08";g.production_operator_name="Demo MOP Operator";g.processed_weight_kg=g.processed_quantity_kg=55.2;g.processed_units=g.processed_quantity_units=552;g.processed_quantity_source="MOP_PRODUCTION";g.processed_at=`${date}T09:05:00.000Z`;g.production_revision_no=2;g.production_lines=[{variant_name:"Standard Pocket Mops",variant_code:"STANDARD_POCKET_MOPS",weight_kg:55.2,units:552}];g.trolley_capture_status="RECORDED";g.planned_trolley_quantity=1;g.planned_trolley_requirements=req("SMALL",1);g.mop_trolleys=[trolley("T900202T","SMALL")];g.lifecycle_trolleys=[trolley("T900202T","SMALL")];g.abs_count=1;g.abs_details=[{batch_reference:"ABS-DEMO-4421",recorded_by:"Demo ABS User",recorded_at:`${date}T09:12:00.000Z`,quantity:55.2,unit_code:"KG"}];g.batch_references=["ABS-DEMO-4421"];
    const mixM=base("04M","DEMO · Meadowlands","MOP",5,"#9900cc","Route 613","IN_PROGRESS");mixM.customer_id="demo-04";mixM.washed_kg_total=mixM.washed_quantity_kg=42;mixM.washed_quantity_basis="EQUAL_SPLIT_ESTIMATE";mixM.washed_load_count=1;mixM.wash_details=wash("W-DEMO-205","WA09 [60KG] HOUSEHOLD","Demo Operator",42,"09:06:00");
    return {schema_version:"PRODUCTION_TRACKER_V3",source_contract:"PRODUCTION_FLOW_SHARED_TRACKER_V3",demo_preview:true,business_date:date,generated_at:stamp,
      quantity_contract:"WASHED_ESTIMATE_VS_PROCESSED_ACTUAL",route_trolley_contract:"PHYSICAL_TYPED_TROLLEYS_PLUS_SCHEDULE_REQUIREMENTS",trolley_physical_master_contract:"CONFIRMED_FOOTPRINT_AND_TARE_WEIGHT",route_vehicle_load_contract:"ACTUAL_FOOTPRINT_AND_TARE_PLUS_RECORDED_PROCESSED_KG",truck_capacity_contract:"PENDING_TRUCK_MASTER_CAPACITY",
      summary:{scheduled:8,total_customers:8,not_started:2,washed:6,abs_pending:1,tracker_ok:1,in_progress:1,total_kg:336},
      items:[a,b,c,mixC,d,e,f,g,mixM]};
  }
  function renderTrackerDemoState(){
    if(el.trackerDemoBanner)el.trackerDemoBanner.hidden=!state.trackerDemoActive;
  }
  function toggleTrackerDemo(){
    state.trackerDemoActive=!state.trackerDemoActive;
    if(state.trackerDemoActive)state.trackerDemoData=trackerDemoDataset();
    renderTrackerDemoState();renderTrackerKpis();renderTrackerTable();
    if(el.trackerUpdated)el.trackerUpdated.textContent=state.trackerDemoActive?"Demo data · not saved":`Updated ${new Intl.DateTimeFormat("en-IE",{hour:"2-digit",minute:"2-digit",hour12:false}).format(new Date(state.trackerData?.generated_at||Date.now()))}`;
  }

  function trackerProductMeta(code){
    const normalized=String(code||"").toUpperCase();
    if(normalized==="CLOTHES")return {label:"CLOTHES",cls:"clothes",icon:"C"};
    if(normalized==="MOP")return {label:"MOP",cls:"mop",icon:"M"};
    return {label:titleCode(normalized||"OTHER"),cls:"other",icon:"•"};
  }
  function trackerProductChip(product){
    const meta=trackerProductMeta(product?.product_code),priority=Number(product?.production_order);
    return `<div class="sorting-tracker-stream-title ${meta.cls}"><span>${meta.icon}</span><div><strong>${esc(meta.label)}</strong><small>${Number.isFinite(priority)?`Priority ${esc(priority)}`:"Priority not recorded"}</small></div></div>`;
  }
  function trackerProductStatus(product){return trackerBadge(product?.product_status||"NOT_STARTED");}
  function trackerOrderedProducts(group){
    const requested=String(el.trackerTypeFilter?.value||"").toUpperCase();
    return (group.products||[]).filter(p=>!requested||String(p.product_code||"").toUpperCase()===requested).sort((a,b)=>trackerProductRank(a.product_code)-trackerProductRank(b.product_code)||Number(a.production_order??2147483647)-Number(b.production_order??2147483647)||String(a.product_code||"").localeCompare(String(b.product_code||"")));
  }
  function trackerWashBasis(p){const basis=String(p.washed_quantity_basis||"").toUpperCase();if(basis==="EQUAL_SPLIT_ESTIMATE")return {label:"Estimated split",cls:"estimate"};if(basis==="FULL_LOAD")return {label:"Full load",cls:"full"};if(basis==="MIXED_WASH_ALLOCATION")return {label:"Mixed allocation",cls:"estimate"};return {label:"Wash allocation",cls:"neutral"};}
  function trackerPlannedHint(p){const kg=Number(p.expected_kg||0),units=Number(p.expected_units||0),bits=[];if(kg>0)bits.push(`${kg.toFixed(1)} kg`);if(units>0)bits.push(`${Math.round(units)} units`);return bits.length?`<small>Schedule estimate · ${esc(bits.join(" / "))}</small>`:"";}
  function trackerProductWashCell(p){
    const washed=Number(p.washed_quantity_kg??p.washed_kg_total??0),basis=trackerWashBasis(p),details=(p.wash_details||[]).map(w=>`<div class="sorting-tracker-detail compact"><b>${esc(w.washer_name||w.washer_code||"Washer")}</b><span>${esc(w.operator_name||"—")} · ${esc(fmtTime(w.started_at||w.registered_at))}${w.wash_code?` · ${esc(w.wash_code)}`:""}</span></div>`);
    if(washed<=0&&!details.length)return '<span class="sorting-tracker-dash">—</span>';
    return `<div class="sorting-tracker-quantity-card washed"><div class="sorting-tracker-quantity-head"><b>Washed estimate</b><span class="sorting-tracker-source-pill ${basis.cls}">${esc(basis.label)}</span></div><strong>${washed>0?`${washed.toFixed(1)} kg`:"—"}</strong><em>Units not measured at Washing</em>${trackerPlannedHint(p)}</div>${details.length?`<div class="sorting-tracker-detail-stack">${details.join("")}</div>`:""}`;
  }
  function trackerProductProcessedCell(p){
    const kg=Number(p.processed_quantity_kg??p.processed_weight_kg??0),units=Number(p.processed_quantity_units??p.processed_units??0);
    if(p.product_code==="MOP"&&p.mop_production_batch_id){
      const details=(p.production_lines||[]).map(line=>{const bits=[];if(Number(line.weight_kg)>0)bits.push(`${Number(line.weight_kg).toFixed(1)} kg`);if(Number(line.units)>0)bits.push(`${Number(line.units)} units`);return `${esc(line.variant_name||line.variant_code||"MOP")}${bits.length?` · ${esc(bits.join(" / "))}`:""}`;}).join("<br>");
      return `<div class="sorting-tracker-quantity-card processed"><div class="sorting-tracker-quantity-head"><b>Processed actual</b><span class="sorting-tracker-source-pill actual">MOP Production</span></div><strong>${kg>0?`${kg.toFixed(1)} kg`:"—"}${units>0?` · ${Math.round(units)} units`:""}</strong><small>${esc(p.production_operator_name||"—")} · ${esc(fmtTime(p.processed_at))}${p.production_revision_no?` · Rev ${esc(p.production_revision_no)}`:""}</small>${details?`<em>${details}</em>`:""}</div>`;
    }
    if(p.product_code==="CLOTHES"&&String(p.processed_quantity_source||"")==="FINISH_PRODUCTION"){const tables=(p.finish_tables||[]).map(titleCode).join(", ");return `<div class="sorting-tracker-quantity-card processed"><div class="sorting-tracker-quantity-head"><b>Processed actual</b><span class="sorting-tracker-source-pill actual">Finish Production</span></div><strong>${kg>0?`${kg.toFixed(1)} kg`:"—"}${units>0?` · ${Math.round(units)} units`:""}</strong><small>${tables?esc(tables):"Finish"}${p.finish_contribution_count?` · ${esc(p.finish_contribution_count)} contribution${Number(p.finish_contribution_count)===1?"":"s"}`:""}</small></div>`;}if(p.product_code==="CLOTHES"&&Number(p.washed_kg_total||0)>0)return `<div class="sorting-tracker-quantity-card pending"><div class="sorting-tracker-quantity-head"><b>Processed actual</b><span class="sorting-tracker-source-pill pending">Finish pending</span></div><strong>—</strong><em>Waiting for Finish Production. Nothing is inferred from Washing.</em>${trackerPlannedHint(p)}</div>`;
    return '<span class="sorting-tracker-dash">—</span>';
  }
  function trackerProductAbsCell(p){
    const abs=Array.isArray(p.abs_details)?p.abs_details:[];
    if(abs.length)return abs.map(a=>`<div class="sorting-tracker-detail"><b>ABS ${esc(a.batch_reference)}</b><span>${esc(a.recorded_by||"Recorded user")} · ${esc(fmtTime(a.recorded_at))}</span><em>${Number(a.quantity||0).toFixed(a.unit_code==="UNIT"?0:1)} ${esc(a.unit_code||"")}</em></div>`).join('<i class="sorting-tracker-divider"></i>');
    if(p.product_code==="MOP"&&p.product_status==="ABS_PENDING"&&p.mop_production_batch_id)return state.trackerDemoActive?'<span class="sorting-tracker-demo-action">DEMO · ABS pending</span>':`<button class="sorting-tracker-abs-button" type="button" data-tracker-post-abs="${esc(p.mop_production_batch_id)}">Post ABS</button>`;
    return '<span class="sorting-tracker-dash">—</span>';
  }
  function trackerAllTrolleys(p){const map=new Map();[...(p.mop_trolleys||[]),...(p.lifecycle_trolleys||[])].forEach(t=>{const code=String(t.trolley_code||"").trim();if(!code)return;const prev=map.get(code)||{};map.set(code,{...prev,...t,trolley_code:code});});return [...map.values()];}
  function trackerTrolleyTypeLabel(t){return String(t.display_code||t.trolley_type_code||"?").toUpperCase();}
  function trackerPlannedTrolleyCounts(p){const map=new Map();(p.planned_trolley_requirements||[]).forEach(r=>{const code=String(r.display_code||r.trolley_type_code||"?").toUpperCase();map.set(code,(map.get(code)||0)+Number(r.quantity||0));});return map;}
  function trackerProductTrolleyCell(p){
    const actual=trackerAllTrolleys(p),planned=Number(p.planned_trolley_quantity||0),plan=trackerPlannedTrolleyCounts(p),actualCounts=new Map();actual.forEach(t=>{const k=trackerTrolleyTypeLabel(t);actualCounts.set(k,(actualCounts.get(k)||0)+1);});const types=[...new Set([...plan.keys(),...actualCounts.keys()])];
    if(!actual.length&&!planned)return '<span class="sorting-tracker-dash">—</span>';
    return `<div class="sorting-tracker-trolley-cell"><strong>${actual.length} actual${planned>0?` / ${planned} planned`:""}</strong>${types.length?`<div class="sorting-tracker-trolley-types">${types.map(k=>`<span class="${(actualCounts.get(k)||0)<(plan.get(k)||0)?"missing":""}"><b>${esc(k)}</b>${actualCounts.get(k)||0}${plan.has(k)?`/${plan.get(k)}`:""}</span>`).join("")}</div>`:""}${actual.length?`<div class="sorting-tracker-trolleys">${actual.map(t=>`<span title="${esc(t.trolley_type_name||"Trolley type not resolved")}">${esc(t.trolley_code)} <b>${esc(trackerTrolleyTypeLabel(t))}</b></span>`).join("")}</div>`:""}${planned>actual.length?`<em>${planned-actual.length} planned trolley${planned-actual.length===1?"":"s"} still missing</em>`:""}</div>`;
  }
  function trackerProductBatchCell(p){const refs=[];(p.batch_references||[]).forEach(v=>{const x=String(v||"").trim();if(x&&!refs.includes(x))refs.push(x);});return refs.length?refs.map(x=>`<span class="sorting-tracker-batch">${esc(x)}</span>`).join(" "):'<span class="sorting-tracker-dash">—</span>';}
  function trackerMatches(group){const status=String(el.trackerStatusFilter?.value||""),type=String(el.trackerTypeFilter?.value||""),term=String(el.trackerSearch?.value||"").trim().toLowerCase();if(status&&group.customer_status!==status)return false;if(type&&!group.products.some(p=>p.product_code===type))return false;if(term&&!JSON.stringify(group).toLowerCase().includes(term))return false;return true;}
  function trackerRouteKey(group){const code=String(group.route_code||"").trim(),name=String(group.route_display_name||"").trim();return (code?`CODE:${code}`:name?`NAME:${name}`:"UNASSIGNED").toUpperCase();}
  function trackerRouteIdentity(group){return {key:trackerRouteKey(group),code:String(group.route_code||"").trim(),name:String(group.route_display_name||group.route_code||"Route not recorded").trim()||"Route not recorded",color:safeRouteColor(group.route_color)||"#94a3b8"};}
  function trackerCompareTuple(aa,bb){for(let i=0;i<Math.max(aa.length,bb.length);i++){const a=aa[i]??0,b=bb[i]??0;if(a<b)return -1;if(a>b)return 1;}return 0;}
  function trackerRouteBlocks(allGroups,visibleGroups){const full=new Map(),visible=new Map();allGroups.forEach(group=>{const route=trackerRouteIdentity(group);if(!full.has(route.key))full.set(route.key,{...route,groups:[]});full.get(route.key).groups.push(group);});visibleGroups.forEach(group=>{const route=trackerRouteIdentity(group);if(!visible.has(route.key))visible.set(route.key,{...route,groups:[]});visible.get(route.key).groups.push(group);});return [...visible.values()].map(block=>{block.fullGroups=full.get(block.key)?.groups||block.groups;block.groups.sort(trackerGroupPrioritySort);block.fullGroups.sort(trackerGroupPrioritySort);const scoped=block.fullGroups.filter(group=>trackerOrderedProducts(group).length);block.sortTuple=scoped.length?trackerPriorityTuple(scoped[0],String(el.trackerTypeFilter?.value||"")):[9,9,2147483647,block.name.toLowerCase()];return block;}).sort((a,b)=>trackerCompareTuple(a.sortTuple,b.sortTuple)||a.name.localeCompare(b.name));}
  function trackerRouteProducts(block){return block.fullGroups.flatMap(group=>trackerOrderedProducts(group));}
  function trackerRouteAllProducts(block){return block.fullGroups.flatMap(group=>group.products||[]);}
  function trackerRouteTrolleyInventory(block){const map=new Map();trackerRouteAllProducts(block).forEach(p=>trackerAllTrolleys(p).forEach(t=>{const code=String(t.trolley_code||"").trim();if(!code)return;const prev=map.get(code)||{};map.set(code,{...prev,...t,trolley_code:code});}));return [...map.values()];}
  function trackerTrolleyArea(t){const direct=Number(t?.footprint_area_m2);if(Number.isFinite(direct)&&direct>0)return direct;const l=Number(t?.footprint_length_cm),w=Number(t?.footprint_width_cm);return Number.isFinite(l)&&l>0&&Number.isFinite(w)&&w>0?l*w/10000:0;}
  function trackerTrolleyTare(t){const n=Number(t?.tare_weight_kg);return Number.isFinite(n)&&n>0?n:0;}
  function trackerRoutePlannedTrolleyCounts(block){const map=new Map();let total=0,areaM2=0,tareKg=0,unknownArea=0,unknownTare=0;trackerRouteAllProducts(block).forEach(p=>{total+=Number(p.planned_trolley_quantity||0);trackerPlannedTrolleyCounts(p).forEach((qty,type)=>map.set(type,(map.get(type)||0)+qty));(p.planned_trolley_requirements||[]).forEach(r=>{const qty=Number(r.quantity||0),area=trackerTrolleyArea(r),tare=trackerTrolleyTare(r);if(qty<=0)return;if(area>0)areaM2+=qty*area;else unknownArea+=qty;if(tare>0)tareKg+=qty*tare;else unknownTare+=qty;});});return {total,types:map,areaM2,tareKg,unknownArea,unknownTare};}
  function trackerSequenceRuns(values){const nums=[...new Set(values.map(Number).filter(Number.isFinite))].sort((a,b)=>a-b);if(!nums.length)return [];const runs=[];let start=nums[0],prev=nums[0];for(const n of nums.slice(1)){if(n===prev+1){prev=n;continue;}runs.push([start,prev]);start=prev=n;}runs.push([start,prev]);return runs;}
  function trackerSequenceLabel(runs){return runs.map(([a,b])=>a===b?String(a):`${a}–${b}`).join(" · ");}
  function trackerRouteSequence(block){const products=trackerRouteProducts(block),chips=[];["CLOTHES","MOP"].forEach(code=>{const selected=products.filter(p=>String(p.product_code||"").toUpperCase()===code);if(!selected.length)return;const runs=trackerSequenceRuns(selected.map(p=>p.production_order)),split=runs.length>1;chips.push(`<span class="sorting-tracker-route-sequence ${code.toLowerCase()}${split?" split":""}"><b>${code==="CLOTHES"?"C":"M"}</b><span>${esc(trackerSequenceLabel(runs)||"No priority")}</span>${split?'<em>SPLIT</em>':""}</span>`);});return chips.join("");}
  function trackerRouteStats(block){
    const products=trackerRouteProducts(block),total=products.length,done=products.filter(p=>p.product_status==="TRACKER_OK").length,notStarted=products.filter(p=>p.product_status==="NOT_STARTED").length,absPending=products.filter(p=>p.product_status==="ABS_PENDING").length,inProgress=products.filter(p=>p.product_status==="IN_PROGRESS").length,washedOnly=products.filter(p=>p.product_status==="WASHED_ONLY").length;
    const customerCount=block.fullGroups.filter(g=>trackerOrderedProducts(g).length).length,customersComplete=block.fullGroups.filter(g=>{const ps=trackerOrderedProducts(g);return ps.length&&ps.every(p=>p.product_status==="TRACKER_OK");}).length;
    const trolleys=trackerRouteTrolleyInventory(block),planned=trackerRoutePlannedTrolleyCounts(block),actualTypes=new Map();let actualAreaM2=0,actualTareKg=0,unknownActualArea=0,unknownActualTare=0;trolleys.forEach(t=>{const type=trackerTrolleyTypeLabel(t),area=trackerTrolleyArea(t),tare=trackerTrolleyTare(t);actualTypes.set(type,(actualTypes.get(type)||0)+1);if(area>0)actualAreaM2+=area;else unknownActualArea+=1;if(tare>0)actualTareKg+=tare;else unknownActualTare+=1;});let missingTrolleys=0;planned.types.forEach((qty,type)=>{missingTrolleys+=Math.max(qty-(actualTypes.get(type)||0),0);});
    const processedKg=products.reduce((sum,p)=>{const n=Number(p.processed_quantity_kg??p.processed_weight_kg);return sum+(Number.isFinite(n)&&n>0?n:0);},0),processedWeightComplete=total>0&&products.every(p=>{const n=Number(p.processed_quantity_kg??p.processed_weight_kg);return Number.isFinite(n)&&n>0;}),knownLoadKg=actualTareKg+processedKg,weightComplete=processedWeightComplete&&unknownActualTare===0&&missingTrolleys===0;
    const complete=total>0&&done===total&&missingTrolleys===0,attention=notStarted+absPending+inProgress+missingTrolleys>0;
    const ordered=block.fullGroups.flatMap(group=>trackerOrderedProducts(group).map(product=>({group,product}))).sort((a,b)=>trackerProductRank(a.product.product_code)-trackerProductRank(b.product.product_code)||Number(a.product.production_order??2147483647)-Number(b.product.production_order??2147483647)||String(a.group.customer_name||"").localeCompare(String(b.group.customer_name||"")));
    const first=ordered.find(x=>x.product.product_status!=="TRACKER_OK")||null;
    return {total,done,notStarted,absPending,inProgress,washedOnly,customerCount,customersComplete,trolleys,planned,actualTypes,missingTrolleys,actualAreaM2,actualTareKg,unknownActualArea,unknownActualTare,processedKg,processedWeightComplete,knownLoadKg,weightComplete,complete,attention,progress:total?Math.round(done*100/total):0,first};
  }
  function trackerRouteState(stats){if(stats.complete)return {label:"Route complete",cls:"complete",icon:"✓"};if(stats.attention)return {label:"Attention",cls:"attention",icon:"!"};return {label:"In progress",cls:"progress",icon:"↻"};}
  function trackerRouteFirstIncomplete(stats){if(stats.first){const {group,product}=stats.first,meta=trackerStatusMeta(product.product_status),type=product.product_code==="MOP"?"M":"C",priority=Number(product.production_order);return `${type}${Number.isFinite(priority)?priority:"?"} · ${group.customer_name} · ${meta.label}`;}if(stats.missingTrolleys>0)return `${stats.missingTrolleys} planned trolley${stats.missingTrolleys===1?"":"s"} still missing`;return "All production streams and planned trolley evidence complete";}
  function trackerRouteTypeLoad(stats){const types=[...new Set([...stats.planned.types.keys(),...stats.actualTypes.keys()])];if(!types.length)return '<span class="sorting-tracker-route-trolley-empty">No trolley requirement/evidence</span>';return types.map(type=>{const actual=stats.actualTypes.get(type)||0,planned=stats.planned.types.get(type),missing=planned!=null&&actual<planned;return `<span class="sorting-tracker-route-trolley-type${missing?" missing":""}"><b>${esc(type)}</b><strong>${actual}${planned!=null?` / ${planned}`:""}</strong></span>`;}).join("");}
  function trackerRouteCapacityLoad(stats){const actualArea=stats.actualAreaM2>0?stats.actualAreaM2.toFixed(1):"—",plannedArea=stats.planned.areaM2>0?stats.planned.areaM2.toFixed(1):"",areaUnknown=stats.unknownActualArea+stats.planned.unknownArea>0,weight=stats.knownLoadKg>0?stats.knownLoadKg.toFixed(0):"—",partial=!stats.weightComplete;const areaTitle=`Actual physical trolley footprint${plannedArea?" / planned Schedule footprint":""}.${areaUnknown?" Some trolley types have no confirmed dimensions and are excluded from the m² total.":""}`;const weightTitle=`Known vehicle load = physical trolley tare (${stats.actualTareKg.toFixed(1)} kg) + recorded processed contents (${stats.processedKg.toFixed(1)} kg). Planned trolley tare from the Schedule is ${stats.planned.tareKg.toFixed(1)} kg.${partial?" Partial until all route streams have recorded processed KG and all planned physical trolleys are known.":""}`;return `<div class="sorting-tracker-route-capacity"><span class="${areaUnknown?"partial":""}" title="${esc(areaTitle)}"><b>Floor</b><strong>${actualArea}${plannedArea?` / ${plannedArea}`:""} m²</strong></span><span class="${partial?"partial":""}" title="${esc(weightTitle)}"><b>Weight</b><strong>${partial&&weight!=="—"?"≥ ":""}${weight} kg</strong>${partial?"<em>partial</em>":""}</span></div>`;}
  function trackerRouteHeader(block,visibleCount,collapsed){
    const stats=trackerRouteStats(block),routeState=trackerRouteState(stats),fg=routeTextColor(block.color),filtered=visibleCount<stats.customerCount;
    return `<button class="sorting-tracker-route-header" type="button" data-tracker-route-toggle="${esc(block.key)}" aria-expanded="${collapsed?"false":"true"}" style="--route-color:${block.color}"><div class="sorting-tracker-route-title"><span class="sorting-tracker-route-chevron" aria-hidden="true">▼</span><span class="sorting-tracker-route-mark" style="background:${block.color};color:${fg}">${esc(block.code||"R")}</span><div><p>Route block</p><h3>${esc(block.name)}</h3><div class="sorting-tracker-route-sequences">${trackerRouteSequence(block)}</div></div></div><div class="sorting-tracker-route-summary"><span class="sorting-tracker-route-state ${routeState.cls}"><b>${routeState.icon}</b>${routeState.label}</span><span><b>${stats.customersComplete}/${stats.customerCount}</b> customers complete${filtered?` · ${visibleCount} shown`:""}</span><span><b>${stats.done}/${stats.total}</b> streams complete</span><span class="${stats.missingTrolleys?"warn":""}"><b>${stats.trolleys.length}${stats.planned.total?` / ${stats.planned.total}`:""}</b> trolleys${stats.planned.total?" actual / planned":""}</span>${stats.absPending?`<span class="warn"><b>${stats.absPending}</b> ABS pending</span>`:""}${stats.notStarted?`<span class="danger"><b>${stats.notStarted}</b> not started</span>`:""}</div><div class="sorting-tracker-route-trolley-load"><b>Trolleys</b><div>${trackerRouteTypeLoad(stats)}</div>${trackerRouteCapacityLoad(stats)}</div><div class="sorting-tracker-route-progress"><span style="width:${stats.progress}%;background:${block.color}"></span></div><div class="sorting-tracker-route-next"><b>First incomplete</b><span>${esc(trackerRouteFirstIncomplete(stats))}</span></div></button>`;
  }
  function renderTrackerCustomerRows(groups){
    return groups.map(group=>{const products=trackerOrderedProducts(group);if(!products.length)return "";const color=safeRouteColor(group.route_color)||"#94a3b8",mixed=products.length>1;return products.map((product,productIndex)=>{const rowStatus=String(product.product_status||"NOT_STARTED").toLowerCase().replaceAll("_","-"),stream=trackerProductMeta(product.product_code);const customerCell=productIndex===0?`<td class="sorting-tracker-customer-cell${mixed?" is-mixed":""}" rowspan="${products.length}"><div class="sorting-tracker-customer"><span style="background:${color}"></span><div><strong>${esc(group.customer_name||"—")}</strong>${group.customer_code?`<small>${esc(group.customer_code)}</small>`:""}<div class="sorting-tracker-overall"><span>Overall</span>${trackerBadge(group.customer_status)}</div>${mixed?'<em class="sorting-tracker-mixed-label">2 production streams</em>':""}</div></div></td>`:"";return `<tr class="tracker-row-${esc(rowStatus)} sorting-tracker-stream-row stream-${stream.cls}">${customerCell}<td class="sorting-tracker-stream-cell">${trackerProductChip(product)}</td><td>${trackerProductStatus(product)}</td><td>${trackerProductWashCell(product)}</td><td>${trackerProductProcessedCell(product)}</td><td>${trackerProductAbsCell(product)}</td><td>${trackerProductTrolleyCell(product)}</td><td>${trackerProductBatchCell(product)}</td></tr>`;}).join("");}).join("");
  }
  function renderTrackerTable(){
    const allGroups=trackerGroups(),visibleGroups=allGroups.filter(trackerMatches).sort(trackerGroupPrioritySort);if(!el.trackerTableWrap)return;
    const blocks=trackerRouteBlocks(allGroups,visibleGroups),streamCount=visibleGroups.reduce((sum,g)=>sum+trackerOrderedProducts(g).length,0);
    el.trackerRowCount.textContent=`${blocks.length} route${blocks.length===1?"":"s"} · ${visibleGroups.length} customer${visibleGroups.length===1?"":"s"} · ${streamCount} stream${streamCount===1?"":"s"}`;
    if(!visibleGroups.length){el.trackerTableWrap.innerHTML='<div class="sorting-empty">No customers match this Production Tracker view.</div>';return;}
    el.trackerTableWrap.innerHTML=`<div class="sorting-tracker-route-blocks">${blocks.map(block=>{const collapsed=state.trackerCollapsedRoutes.has(block.key);return `<section class="sorting-tracker-route-block${collapsed?" collapsed":" expanded"}" style="--route-color:${block.color}">${trackerRouteHeader(block,block.groups.length,collapsed)}<div class="sorting-tracker-route-body"${collapsed?" hidden":""}><div class="sorting-tracker-route-table-wrap"><table class="sorting-tracker-table sorting-tracker-stream-table"><thead><tr><th>Customer</th><th>Product / Priority</th><th>Status</th><th>Washed estimate</th><th>Processed actual</th><th>ABS</th><th>Trolleys</th><th>Batch</th></tr></thead><tbody>${renderTrackerCustomerRows(block.groups)}</tbody></table></div></div></section>`;}).join("")}</div>`;
  }
  function renderTrackerKpis(){const s=trackerSourceData()?.summary||{};el.trackerKpiScheduled.textContent=s.scheduled??0;el.trackerKpiNotStarted.textContent=s.not_started??0;el.trackerKpiWashed.textContent=s.washed??0;el.trackerKpiAbs.textContent=s.abs_pending??0;el.trackerKpiDone.textContent=s.tracker_ok??0;el.trackerKpiKg.textContent=Number(s.total_kg||0)>0?`${Number(s.total_kg).toFixed(1)} kg`:"—";}
  function trackerDayStat(summary){if(!summary)return "Load";return `${Number(summary.washed||0)}/${Number(summary.scheduled||0)} washed${Number(summary.tracker_ok||0)?` · ${Number(summary.tracker_ok)} OK`:""}`;}
  function renderTrackerDayCards(){
    if(!el.trackerDayCards)return;const selected=state.trackerDate||trackerBaseToday();const dates=trackerCardDates();const labels=["Previous","Today","Next"];
    el.trackerDayCards.innerHTML=dates.map((date,i)=>`<button type="button" class="sorting-tracker-daycard${date===selected&&!state.trackerHistoryMode?" active":""}" data-tracker-date="${date}"><small>${labels[i]}</small><strong>${esc(new Intl.DateTimeFormat("en-IE",{weekday:"long"}).format(new Date(`${date}T12:00:00`)))}</strong><span>${esc(shortDayDate(date))}</span><em>${esc(trackerDayStat(state.trackerDayStats[date]))}</em></button>`).join("");
  }
  function renderTrackerHistoryState(){
    if(!el.trackerHistoryBanner)return;el.trackerHistoryBanner.hidden=!state.trackerHistoryMode;if(state.trackerHistoryMode)el.trackerHistoryDate.textContent=fullDayDate(state.trackerDate);
  }
  async function preloadTrackerDayStats(){
    const dates=trackerCardDates();await Promise.all(dates.map(async date=>{if(state.trackerDayStats[date])return;try{const data=await rpc("get_production_tracker_v4",{p_business_date:date});trackerStrict(data);state.trackerDayStats[date]=data.summary||{};}catch(error){console.warn("Tracker day summary unavailable",date,error);}}));renderTrackerDayCards();
  }
  async function loadTracker(date=null,{history=false,refreshCards=true,silent=false}={}){
    if(document.getElementById("productionTrackerTableWrap"))return;
    if(!el.trackerTableWrap)return;
    state.trackerDemoActive=false;
    renderTrackerDemoState();
    if(!silent)el.trackerTableWrap.classList.add("is-loading");
    try{
      const data=await rpc("get_production_tracker_v4",{p_business_date:date||null});trackerStrict(data);state.trackerData=data;
      const nextTrackerDate=String(data.business_date||date||trackerBaseToday()).slice(0,10);if(state.trackerDate&&state.trackerDate!==nextTrackerDate)state.trackerCollapsedRoutes.clear();state.trackerDate=nextTrackerDate;if(!date)state.trackerTodayDate=state.trackerDate;
      if(!state.trackerTodayDate)state.trackerTodayDate=state.washing?.business_date||state.trackerDate;
      state.trackerHistoryMode=Boolean(history);state.trackerDayStats[state.trackerDate]=data.summary||{};
      renderTrackerKpis();renderTrackerTable();renderTrackerDayCards();renderTrackerHistoryState();
      el.trackerUpdated.textContent=`Updated ${new Intl.DateTimeFormat("en-IE",{hour:"2-digit",minute:"2-digit",hour12:false}).format(new Date(data.generated_at||Date.now()))}`;
      if(refreshCards&&!history)preloadTrackerDayStats();
    }catch(error){console.error(error);if(!silent)el.trackerTableWrap.innerHTML=`<div class="sorting-empty sorting-tracker-error">${esc(friendly(error))}</div>`;else setMessage(friendly(error),"error");}
    finally{el.trackerTableWrap.classList.remove("is-loading");}
  }
  function openTrackerHistory(){
    const today=trackerBaseToday();el.trackerHistoryInput.max=trackerPrevDay(today);el.trackerHistoryInput.value=state.trackerHistoryMode?state.trackerDate:trackerPrevDay(today);el.trackerHistoryMessage.textContent="";if(!el.trackerHistoryDialog.open)el.trackerHistoryDialog.showModal();
  }
  async function loadTrackerHistory(){
    const date=el.trackerHistoryInput.value;if(!date){el.trackerHistoryMessage.textContent="Choose a date.";return;}if(date>=trackerBaseToday()){el.trackerHistoryMessage.textContent="History must be before today's production date.";return;}if(trackerIsSunday(date)){el.trackerHistoryMessage.textContent="Sunday is not a production day.";return;}
    el.trackerHistoryDialog.close();await loadTracker(date,{history:true,refreshCards:false});
  }
  function findTrackerMopBatch(batchId){return (state.trackerData?.items||[]).find(p=>p.mop_production_batch_id===batchId)||null;}
  function openTrackerAbs(batchId){
    const item=findTrackerMopBatch(batchId);if(!item)return;state.trackerAbsItem=item;el.trackerAbsInput.value="";el.trackerAbsNotes.value="";el.trackerAbsMessage.textContent="";
    const lines=(item.production_lines||[]).map(x=>`<div><strong>${esc(x.variant_name||x.variant_code||"MOP")}</strong><span>${Number(x.weight_kg||0)>0?`${Number(x.weight_kg).toFixed(1)} kg`:""}${Number(x.units||0)>0?` · ${Number(x.units)} units`:""}</span></div>`).join("");
    el.trackerAbsSummary.innerHTML=`<div><span>Customer</span><strong>${esc(item.customer_name)}</strong></div><div><span>Processed</span><strong>${Number(item.processed_weight_kg||0).toFixed(1)} kg${Number(item.processed_units||0)>0?` · ${Number(item.processed_units)} units`:""}</strong></div>${lines?`<section>${lines}</section>`:""}`;
    if(!el.trackerAbsDialog.open)el.trackerAbsDialog.showModal();setTimeout(()=>el.trackerAbsInput.focus(),80);
  }
  function closeTrackerAbs(){if(el.trackerAbsSave.disabled)return;state.trackerAbsItem=null;el.trackerAbsMessage.textContent="";if(el.trackerAbsDialog.open)el.trackerAbsDialog.close();}
  async function saveTrackerAbs(){
    const item=state.trackerAbsItem;const ref=String(el.trackerAbsInput.value||"").trim();if(!item)return;if(!ref){el.trackerAbsMessage.textContent="Enter the ABS batch number.";el.trackerAbsInput.focus();return;}
    el.trackerAbsSave.disabled=true;el.trackerAbsMessage.textContent="Saving ABS batch…";
    try{await rpc("record_sorting_mop_abs_batch",{p_mop_production_batch_id:item.mop_production_batch_id,p_batch_reference:ref,p_notes:el.trackerAbsNotes.value.trim()||null});el.trackerAbsDialog.close();state.trackerAbsItem=null;await loadTracker(state.trackerDate,{history:state.trackerHistoryMode,refreshCards:true});await loadMop();setMessage(`ABS ${ref} recorded for ${item.customer_name}.`,"success");}
    catch(error){console.error(error);el.trackerAbsMessage.textContent=friendly(error);}
    finally{el.trackerAbsSave.disabled=false;}
  }


  async function reload(show=true){
    const preserveMopDraft=hasMopProductionDraft();
    if(show&&preserveMopDraft){
      setMessage(mopDraftWarning("refreshing"),"warning");
      return;
    }
    state.busy=true;renderShift();
    try{
      if(standaloneMop){
        if(!preserveMopDraft)await loadMop();
      }else{
        await loadWashing();await loadStaffWork();await loadSorting();
        if(!preserveMopDraft)await loadMop();
        if(state.view==="tracker")await loadTracker(state.trackerDate||null,{history:state.trackerHistoryMode,refreshCards:show,silent:!show});
      }
      if(show)setMessage(`${viewCopy[state.view][0]} refreshed.`,"success");
    }
    catch(error){console.error(error);setMessage(friendly(error),"error");}
    finally{state.busy=false;renderShift();if(state.view==="mop"&&!hasMopProductionDraft())enforceMopReconciliation();}
  }

  async function switchSortingView(nextView){
    nextView=standaloneMop?"mop":nextView;
    if(!["washing","trolley","mop","tracker","staff"].includes(nextView))nextView="washing";
    if(nextView===state.view)return;
    if(hasMopProductionDraft()){
      if(nextView!==state.view)setMessage(mopDraftWarning("leaving MOP Production"),"warning");
      else setMessage("MOP production draft remains open. Finish the KG / Units entry or Clear it.","warning");
      return;
    }
    state.view=nextView;renderView();setMessage("");
    if(state.view==="trolley"){renderTrolleyStaffBar();renderTrolleySidebar();paintTrolleyScanBuffer();}
    if(state.view==="mop"){renderMop();enforceMopReconciliation();}
    if(state.view==="tracker"&&!state.trackerData){await loadTracker(null,{refreshCards:true});}
  }

  el.nav.forEach(b=>b.addEventListener("click",()=>switchSortingView(b.dataset.sortingView)));
  window.addEventListener("hashchange",()=>switchSortingView(location.hash.slice(1)||"washing"));
  el.shiftTabs.addEventListener("click",async e=>{
    const autoButton=e.target.closest("[data-shift-auto]");
    if(autoButton){
      if(state.busy)return;
      if(hasWashDraft()||hasMopProductionDraft()){
        setMessage(hasMopProductionDraft()?mopDraftWarning("returning to Auto Shift"):"Clear or save the current washing form before returning to Auto Shift.","warning");
        return;
      }
      state.shiftMode="AUTO";
      const changed=await refreshAutoShift(true);
      renderShift();
      if(changed)await reload(true);
      else setMessage(`Auto Shift is on · ${state.shift==="MORNING"?"Morning":"Evening"} from the standard weekly schedule.`,"success");
      return;
    }
    const b=e.target.closest("[data-shift]");
    if(!b||state.busy)return;
    if((hasWashDraft()||hasMopProductionDraft())&&b.dataset.shift!==state.shift){
      setMessage(hasMopProductionDraft()?mopDraftWarning("changing Shift"):"Clear or save the current washing form before changing Shift.","warning");
      return;
    }
    state.shiftMode="MANUAL";
    const changed=b.dataset.shift!==state.shift;
    state.shift=b.dataset.shift;
    state.selectedCustomers=[];
    state.trolley=null;
    state.trolleyDraft=null;
    state.pendingTrolleyConfirmation=null;
    state.staffWork=null;
    state.washing=null;
    state.sorting=null;
    state.trolleyOperatorStaffId=null;
    state.attendanceStaffId=null;
    el.operator.value="";
    clearWashSearch();
    renderTrolleyResult();
    renderTrolleyStaffBar();
    renderShift();
    if(changed)await reload(true);
    else setMessage(`Manual ${state.shift==="MORNING"?"Morning":"Evening"} Shift override is active for this session.`,"warning");
  });
  el.reload.addEventListener("click",()=>reload(true));
  el.washer.addEventListener("change",()=>renderCapacity(true));
  el.operator.addEventListener("change",()=>prefillTypeForOperator(false));
  el.type.addEventListener("change",()=>{
    state.typeAutofilledByStaff=false;
    state.selectedCustomers=[];
    state.washReceptionExceptions={};
    renderSelected();
    renderToday();
    syncOperatorForType();
  });
  el.customerButton.addEventListener("click",openCustomerDialog);
  el.selectedCustomers.addEventListener("click",e=>{const b=e.target.closest("[data-remove-customer]");if(!b)return;state.selectedCustomers=state.selectedCustomers.filter(id=>id!==b.dataset.removeCustomer);delete state.washReceptionExceptions[b.dataset.removeCustomer];renderSelected();});
  el.customerSearch.addEventListener("input",renderCustomerOptions);
  el.customerShowAll?.addEventListener("change",()=>{
    state.washCustomerShowAll=Boolean(el.customerShowAll.checked);
    renderCustomerOptions();
  });
  el.customerOptions.addEventListener("click",async e=>{
    const button=e.target.closest("[data-wash-no-trolley]");
    if(!button)return;
    e.preventDefault();e.stopPropagation();
    await receiveNoTrolleyFromWashing(button.dataset.washNoTrolley,button);
  });
  el.washReceptionExceptionButton?.addEventListener("click",openWashReceptionExceptionDialog);
  el.washReceptionExceptionOptions?.addEventListener("change",e=>{
    const cb=e.target.closest("[data-wash-exception-key]");if(!cb)return;
    state.draftWashReceptionExceptionKeys=cb.checked?[...new Set([...state.draftWashReceptionExceptionKeys,cb.dataset.washExceptionKey])]:state.draftWashReceptionExceptionKeys.filter(key=>key!==cb.dataset.washExceptionKey);
    renderWashReceptionExceptionOptions();
  });
  el.washReceptionExceptionUse?.addEventListener("click",useWashReceptionException);
  el.customerOptions.addEventListener("change",e=>{
    const cb=e.target.closest('input[type="checkbox"]');if(!cb)return;
    const current=selectionInfo(cb.value);
    if(cb.checked){
      if(current){
        state.draftCustomers=state.draftCustomers.filter(key=>{
          const other=selectionInfo(key);
          return !other||other.customer_id!==current.customer_id;
        });
      }
      if(!state.draftCustomers.includes(cb.value))state.draftCustomers.push(cb.value);
    }else{
      state.draftCustomers=state.draftCustomers.filter(id=>id!==cb.value);
    }
    renderCustomerOptions();
  });
  el.dialog.addEventListener("close",()=>{if(el.dialog.returnValue==="default"){state.selectedCustomers=[...state.draftCustomers];renderSelected();}});
  el.washForm.addEventListener("submit",async e=>{e.preventDefault();await saveWash();});
  el.washConfirmSave.addEventListener("click",commitConfirmedWash);
  el.washConfirmDialog.addEventListener("close",()=>{
    if(!state.busy)state.pendingWashConfirmation=null;
    el.washConfirmMessage.textContent="";
  });
  el.missedWash.addEventListener("click",startLateEntryMode);
  el.historySearchButton.addEventListener("click",searchWashHistory);
  el.historyClearButton.addEventListener("click",clearWashSearch);
  el.historySearch.addEventListener("keydown",e=>{if(e.key==="Enter"){e.preventDefault();searchWashHistory();}});
  el.cancelEdit.addEventListener("click",()=>{clearWash(true);setMessage("Special entry mode cancelled. No database change was made.");});
  el.recentWashes.addEventListener("click",async e=>{
    const edit=e.target.closest("[data-edit-wash]");
    if(edit){beginEditWash(edit.dataset.editWash);return;}
    const cancel=e.target.closest("[data-cancel-wash]");
    if(cancel){await cancelWashRecord(cancel.dataset.cancelWash);}
  });
  el.clearWash.addEventListener("click",()=>{clearWash(true);setMessage("");});
  if(el.attendanceSave) el.attendanceSave.addEventListener("click",saveNoWorkStatus);
  if(el.attendanceDialog) el.attendanceDialog.addEventListener("close",()=>{
    state.attendanceStaffId=null;
    el.attendanceMessage.textContent="";
  });
  if(el.attendanceForm) el.attendanceForm.addEventListener("change",e=>{
    if(e.target.matches('input[name="sortingNoWorkAction"]'))renderNoWorkDialogMode();
  });
  if(el.addManualStaffButton) el.addManualStaffButton.addEventListener("click",openManualStaffDialog);
  if(el.manualStaffSearch) el.manualStaffSearch.addEventListener("input",renderManualStaffCandidates);
  if(el.manualStaffOptions) el.manualStaffOptions.addEventListener("click",async e=>{
    const button=e.target.closest("[data-add-manual-staff]");
    if(!button)return;
    await addManualStaff(button.dataset.addManualStaff,button);
  });
  if(el.staffWorkList) el.staffWorkList.addEventListener("change",e=>{
    const toggle=e.target.closest('[data-work-field="away-enabled"]');
    if(!toggle)return;
    const card=toggle.closest("[data-staff-work]");
    const panel=card?.querySelector("[data-time-away-panel]");
    if(panel)panel.classList.toggle("hidden",!toggle.checked);
  });

  if(el.staffWorkList) el.staffWorkList.addEventListener("click",async e=>{
    const noWorkButton=e.target.closest("[data-no-work]");
    if(noWorkButton){await openAttendanceDialog(noWorkButton.dataset.noWork);return;}
    const returnButton=e.target.closest("[data-return-sorting]");
    if(returnButton){await returnStaffToSorting(returnButton.dataset.returnSorting);return;}
    const presentButton=e.target.closest("[data-mark-present]");
    if(presentButton){await markStaffPresent(presentButton.dataset.markPresent);return;}
    const editButton=e.target.closest("[data-edit-staff-work]");
    if(editButton){openStaffActualDialog(editButton.dataset.editStaffWork);return;}
    const closeButton=e.target.closest("[data-cancel-staff-edit]");
    if(closeButton){state.editingStaffId=null;renderStaffWork();return;}
    const modeButton=e.target.closest("[data-change-work-mode]");
    if(modeButton){
      await changeSortingWorkMode(modeButton.dataset.changeWorkMode,modeButton.dataset.workMode);
      return;
    }
    const cancelButton=e.target.closest("[data-cancel-manual-staff]");
    if(cancelButton){await cancelManualStaff(cancelButton.dataset.cancelManualStaff);return;}
    const button=e.target.closest("[data-save-staff-work]");
    if(!button||state.busy)return;
    await saveStaffWork(button.dataset.saveStaffWork,button);
  });
  document.addEventListener("keydown",handleTrolleyScannerKey);

  el.trolleyStaffBar.addEventListener("click",e=>{
    const button=e.target.closest("[data-reception-staff]");
    if(!button)return;
    selectTrolleyStaff(button.dataset.receptionStaff);
    setMessage("");
  });

  el.trolleyManualButton.addEventListener("click",()=>{
    if(!state.trolleyOperatorStaffId)return promptTrolleyStaffSelection("Select your name in RECEIVING AS before entering a trolley manually.");
    openManualTrolley();
  });

  el.trolleyBatchToggle?.addEventListener("click",()=>{
    state.trolleyBatchMode=!state.trolleyBatchMode;
    renderTrolleyBasket();
    renderTrolleyResult();
    setMessage(state.trolleyBatchMode?"Scan list mode is on. Confirmed cards go to review list before saving.":"Scan list mode is off.");
  });

  el.trolleyBasketList?.addEventListener("click",e=>{
    const edit=e.target.closest("[data-basket-edit]");
    if(edit){
      const item=state.trolleyBasket.find(row=>row.id===edit.dataset.basketEdit);
      if(!item)return;
      state.trolley=item.preview;
      state.trolleyDraft=item.draft;
      state.trolleyBasket=state.trolleyBasket.filter(row=>row.id!==item.id);
      renderTrolleyBasket();
      renderTrolleyResult();
      renderTrolleySidebar();
      if(!el.trolleyResultDialog.open)el.trolleyResultDialog.showModal();
      return;
    }
    const remove=e.target.closest("[data-basket-remove]");
    if(remove){
      state.trolleyBasket=state.trolleyBasket.filter(row=>row.id!==remove.dataset.basketRemove);
      renderTrolleyBasket();
      setMessage("Trolley removed from review list.");
    }
  });
  el.trolleyBasketClear?.addEventListener("click",()=>{
    if(!state.trolleyBasket.length)return;
    if(!window.confirm("Clear the trolley review list? No receipt will be saved."))return;
    state.trolleyBasket=[];
    renderTrolleyBasket();
    setMessage("Trolley review list cleared.");
  });
  el.trolleyBasketConfirm?.addEventListener("click",confirmTrolleyBasket);
  el.trolleyOutboxStatus?.addEventListener("click",()=>flushTrolleyOutbox({silent:false}));

  el.trolleyKeypad.addEventListener("click",e=>{
    const button=e.target.closest("[data-keypad]");
    if(!button)return;
    const key=button.dataset.keypad;
    if(key==="CLEAR")state.trolleyManualDigits="";
    else if(key==="BACK")state.trolleyManualDigits=state.trolleyManualDigits.slice(0,-1);
    else if(/^\d$/.test(key)&&state.trolleyManualDigits.length<10)state.trolleyManualDigits+=key;
    paintManualTrolley();
  });

  el.trolleyManualScan.addEventListener("click",()=>{
    if(!state.trolleyManualDigits)return;
    const code=`T${state.trolleyManualDigits}T`;
    el.trolleyManualDialog.close();
    lookupTrolley(code);
  });

  el.trolleyTodayList.addEventListener("click",e=>{
    const noTrolley=e.target.closest("[data-no-trolley-arrival]");
    if(noTrolley){const row=noTrolleyRowFromButton(noTrolley);if(row)openNoTrolleyArrival(row);return;}
    const row=e.target.closest("[data-reception-board-customer]");
    if(!row)return;
    if(!state.trolley){
      setMessage("Scan a trolley first, then tap the customer in this list.","warning");
      return;
    }
    setTrolleyCustomer(
      row.dataset.receptionBoardCustomer,
      row.dataset.receptionBoardDate,
      row.dataset.receptionBoardProduct
    );
  });

  el.arrivals.addEventListener("click",async e=>{
    const edit=e.target.closest("[data-trolley-intake-edit]");
    if(edit){openTrolleyEditDialog(edit.dataset.trolleyIntakeEdit);return;}
    const remove=e.target.closest("[data-trolley-intake-remove]");
    if(remove){await removeTrolleyIntake(remove.dataset.trolleyIntakeRemove);}
  });

  el.trolleyEditCustomer?.addEventListener("change",()=>{
    if(!state.pendingTrolleyEdit)return;
    const customerId=el.trolleyEditCustomer.value;
    state.pendingTrolleyEdit.customerId=customerId;
    const defaultRow=trolleyDefaultDate(customerId);
    state.pendingTrolleyEdit.date=defaultRow?.scheduled_for_date||"";
    state.pendingTrolleyEdit.product="";
    renderTrolleyEditDialog();
  });

  el.trolleyEditDate?.addEventListener("change",()=>{
    if(!state.pendingTrolleyEdit)return;
    state.pendingTrolleyEdit.date=el.trolleyEditDate.value;
    state.pendingTrolleyEdit.product="";
    renderTrolleyEditDialog();
  });
  el.trolleyEditProduct?.addEventListener("change",()=>{
    if(state.pendingTrolleyEdit)state.pendingTrolleyEdit.product=el.trolleyEditProduct.value;
  });
  el.trolleyEditStaff?.addEventListener("change",()=>{
    if(state.pendingTrolleyEdit)state.pendingTrolleyEdit.staffId=el.trolleyEditStaff.value;
  });
  el.trolleyEditDialog?.addEventListener("click",e=>{
    if(e.target.closest("[data-trolley-edit-cancel]"))closeTrolleyEditDialog();
  });
  el.trolleyEditDialog?.addEventListener("close",()=>{
    state.pendingTrolleyEdit=null;
  });
  el.trolleyEditSave?.addEventListener("click",saveTrolleyEdit);

  el.trolleyPreview.addEventListener("click",async e=>{
    if(e.target.closest("[data-reception-cancel]")){
      resetTrolleyScan();
      setMessage("");
      return;
    }
    if(e.target.closest("[data-reception-other-customer]")){
      openTrolleyCustomerPicker();
      return;
    }
    const date=e.target.closest("[data-reception-date]");
    if(date&&state.trolleyDraft){
      state.trolleyDraft.scheduled_for_date=date.dataset.receptionDate;
      state.trolleyDraft.off_schedule=false;
      state.trolleyDraft.off_schedule_reason="";
      state.trolleyDraft.product_codes=chooseDefaultTrolleyProducts(state.trolleyDraft.customer_id,state.trolleyDraft.scheduled_for_date);
      renderTrolleyResult();
      renderTrolleySidebar();
      return;
    }
    const contents=e.target.closest("[data-reception-contents]");
    if(contents&&state.trolleyDraft){
      state.trolleyDraft.contents_status=contents.dataset.receptionContents;
      renderTrolleyResult();
      return;
    }
    const product=e.target.closest("[data-reception-product]");
    if(product&&state.trolleyDraft){
      state.trolleyDraft.product_codes=product.dataset.receptionProduct==="BOTH"
        ? ["CLOTHES","MOP"]
        : [product.dataset.receptionProduct];
      renderTrolleyResult();
      return;
    }
    const mismatch=e.target.closest("[data-reception-mismatch]");
    if(mismatch&&state.trolleyDraft){
      state.trolleyDraft.customer_override_reason=mismatch.dataset.receptionMismatch;
      renderTrolleyResult();
      return;
    }
    const off=e.target.closest("[data-reception-offschedule]");
    if(off&&state.trolleyDraft){
      state.trolleyDraft.off_schedule_reason=off.dataset.receptionOffschedule;
      renderTrolleyResult();
      return;
    }
    if(e.target.closest("[data-reception-confirm]")){
      if(state.trolleyBatchMode){
        addCurrentTrolleyToBasket();
        return;
      }
      await saveTrolleyReceipt();
    }
  });

  el.trolleyResultDialog.addEventListener("cancel",e=>{
    e.preventDefault();
    resetTrolleyScan();
    setMessage("");
  });

  el.trolleyResultDialog.addEventListener("click",e=>{
    if(e.target===el.trolleyResultDialog){
      resetTrolleyScan();
      setMessage("");
    }
  });

  el.trolleyCustomerTabs.addEventListener("click",e=>{
    const button=e.target.closest("[data-reception-customer-tab]");
    if(!button)return;
    state.trolleyCustomerTab=button.dataset.receptionCustomerTab;
    renderTrolleyCustomerPicker();
  });

  el.trolleyCustomerOptions.addEventListener("click",e=>{
    const button=e.target.closest("[data-reception-customer]");
    if(!button)return;
    setTrolleyCustomer(
      button.dataset.receptionCustomer,
      button.dataset.receptionDate||null,
      button.dataset.receptionProductCode||null
    );
    el.trolleyCustomerDialog.close();
  });

  el.trackerDayCards?.addEventListener("click",async e=>{const b=e.target.closest("[data-tracker-date]");if(!b)return;state.trackerHistoryMode=false;await loadTracker(b.dataset.trackerDate,{history:false,refreshCards:false});});
  el.trackerRefreshButton?.addEventListener("click",()=>loadTracker(state.trackerDate||null,{history:state.trackerHistoryMode,refreshCards:true}));
  el.trackerDemoButton?.addEventListener("click",toggleTrackerDemo);
  el.trackerHistoryButton?.addEventListener("click",openTrackerHistory);
  el.trackerHistoryExit?.addEventListener("click",()=>loadTracker(null,{history:false,refreshCards:true}));
  el.trackerHistoryClose?.addEventListener("click",()=>el.trackerHistoryDialog.close());
  el.trackerHistoryCancel?.addEventListener("click",()=>el.trackerHistoryDialog.close());
  el.trackerHistoryLoad?.addEventListener("click",loadTrackerHistory);
  el.trackerHistoryInput?.addEventListener("keydown",e=>{if(e.key==="Enter"){e.preventDefault();loadTrackerHistory();}});
  el.trackerSearch?.addEventListener("input",renderTrackerTable);
  el.trackerStatusFilter?.addEventListener("change",renderTrackerTable);
  el.trackerTypeFilter?.addEventListener("change",renderTrackerTable);
  el.trackerTableWrap?.addEventListener("click",e=>{
    const toggle=e.target.closest("[data-tracker-route-toggle]");
    if(toggle){const key=toggle.dataset.trackerRouteToggle;if(state.trackerCollapsedRoutes.has(key))state.trackerCollapsedRoutes.delete(key);else state.trackerCollapsedRoutes.add(key);renderTrackerTable();return;}
    const b=e.target.closest("[data-tracker-post-abs]");if(b)openTrackerAbs(b.dataset.trackerPostAbs);
  });
  el.trackerExpandAll?.addEventListener("click",()=>{state.trackerCollapsedRoutes.clear();renderTrackerTable();});
  el.trackerCollapseAll?.addEventListener("click",()=>{const all=trackerGroups(),visible=all.filter(trackerMatches);trackerRouteBlocks(all,visible).forEach(block=>state.trackerCollapsedRoutes.add(block.key));renderTrackerTable();});
  el.trackerAbsClose?.addEventListener("click",closeTrackerAbs);
  el.trackerAbsCancel?.addEventListener("click",closeTrackerAbs);
  el.trackerAbsSave?.addEventListener("click",saveTrackerAbs);
  el.trackerAbsInput?.addEventListener("keydown",e=>{if(e.key==="Enter"){e.preventDefault();saveTrackerAbs();}});
  el.trackerAbsDialog?.addEventListener("cancel",e=>{if(el.trackerAbsSave.disabled)e.preventDefault();else state.trackerAbsItem=null;});

  el.signOut.addEventListener("click",async()=>{try{await client.auth.signOut();location.href="../index.html";}catch{setMessage("The session could not be closed.","error");}});

  if(window.ELIS_SUPABASE_ERROR||!client){setMessage(window.ELIS_SUPABASE_ERROR||"Supabase could not be initialized.","error");return;}
  try{
    const {data:{session},error}=await client.auth.getSession();if(error)throw error;if(!session?.user){location.href="../index.html";return;}
    state.terminalContext=await window.elisProductionStation?.getTerminalContext("SORTING")||null;
  
  el.noTrolleyArrivalSave?.addEventListener("click",saveNoTrolleyArrival);
  el.mopTypesButton?.addEventListener("click",openMopTypes);
  el.mopTypesClose?.addEventListener("click",closeMopTypes);
  el.mopTypesDialog?.addEventListener("cancel",e=>{if(state.mopTypeSaving){e.preventDefault();el.mopTypesMessage.textContent='Wait for the current MOP Type save to finish.';return;}if(state.mopTypeDirty&&!window.confirm('Discard unsaved MOP Type changes?')){e.preventDefault();return;}resetMopTypeEditState();});
  el.mopTypeNewButton?.addEventListener("click",startNewMopType);
  el.mopTypesSearch?.addEventListener("input",()=>{state.mopTypeSearch=el.mopTypesSearch.value;renderMopTypeList();});
  el.mopTypesList?.addEventListener("click",e=>{const b=e.target.closest("[data-mop-type-id]");if(!b||b.dataset.mopTypeId===state.mopTypeSelectedId&&!state.mopTypeCreating)return;if(!confirmDiscardMopTypeChanges())return;resetMopTypeEditState();state.mopTypeSelectedId=b.dataset.mopTypeId;renderMopTypeList();renderMopTypeEditor();el.mopTypesMessage.textContent="";});
  el.mopTypeEditor?.addEventListener("click",e=>{
    if(e.target.closest("#sortingMopTypeSaveButton")){saveMopTypeMaster();return;}
    if(e.target.closest("#sortingMopTypeCancelNewButton")){cancelNewMopType();return;}
    const drop=e.target.closest("#sortingMopTypePhotoDrop");if(drop&&state.mopTypeCatalog?.can_manage&&!state.mopTypeSaving)document.getElementById("sortingMopTypePhotoFile")?.click();
  });
  el.mopTypeEditor?.addEventListener("keydown",e=>{const drop=e.target.closest("#sortingMopTypePhotoDrop");if(!drop||!state.mopTypeCatalog?.can_manage)return;if(e.key==='Enter'||e.key===' '){e.preventDefault();document.getElementById("sortingMopTypePhotoFile")?.click();}});
  el.mopTypeEditor?.addEventListener("change",e=>{
    if(e.target.id==="sortingMopTypePhotoFile"){setMopTypePhotoFile(e.target.files?.[0]);return;}
    if(e.target.id==="sortingMopTypeRemovePhoto"){state.mopTypeDirty=true;clearMopTypePreviewUrl();state.mopTypeUploadFile=null;const preview=document.getElementById("sortingMopTypePhotoPreview");if(e.target.checked){if(preview)preview.innerHTML='<span class="sorting-mop-type-photo-empty"><span>📷</span>Photo will be removed</span>';}else{restoreMopTypePhotoPreview();}return;}
  });
  el.mopTypeEditor?.addEventListener("input",e=>{
    if(!state.mopTypeCatalog?.can_manage)return;
    if(["sortingMopTypeDisplayName","sortingMopTypeVariantCode","sortingMopTypeCategory","sortingMopTypeUnitWeight","sortingMopTypeSortOrder","sortingMopTypeNotes"].includes(e.target.id))state.mopTypeDirty=true;
    if(!state.mopTypeCreating)return;
    if(e.target.id==="sortingMopTypeVariantCode"){state.mopTypeCodeTouched=true;e.target.value=mopVariantCodeFromName(e.target.value);return;}
    if(e.target.id==="sortingMopTypeDisplayName"&&!state.mopTypeCodeTouched){const code=document.getElementById("sortingMopTypeVariantCode");if(code)code.value=mopVariantCodeFromName(e.target.value);}
  });
  el.mopTypeEditor?.addEventListener("dragover",e=>{const drop=e.target.closest("#sortingMopTypePhotoDrop");if(!drop||!state.mopTypeCatalog?.can_manage)return;e.preventDefault();drop.classList.add("drag-over");});
  el.mopTypeEditor?.addEventListener("dragleave",e=>{const drop=e.target.closest("#sortingMopTypePhotoDrop");if(drop&&!drop.contains(e.relatedTarget))drop.classList.remove("drag-over");});
  el.mopTypeEditor?.addEventListener("drop",e=>{const drop=e.target.closest("#sortingMopTypePhotoDrop");if(!drop||!state.mopTypeCatalog?.can_manage)return;e.preventDefault();drop.classList.remove("drag-over");setMopTypePhotoFile(e.dataTransfer?.files?.[0]);});
  el.mopRecent?.addEventListener("click",e=>{
    const abs=e.target.closest("[data-mop-post-abs]");if(abs){openMopAbsDialog(abs.dataset.mopPostAbs);return;}
    const correct=e.target.closest("[data-mop-correct]");if(correct){openMopCorrectionDialog(correct.dataset.mopCorrect);return;}
    const cancel=e.target.closest("[data-mop-cancel]");if(cancel&&!cancel.disabled){openMopCancelDialog(cancel.dataset.mopCancel);}
  });
  el.mopAbsClose?.addEventListener("click",closeMopAbsDialog);
  el.mopAbsCancel?.addEventListener("click",closeMopAbsDialog);
  el.mopAbsSave?.addEventListener("click",saveMopAbsBatch);
  el.mopAbsDialog?.addEventListener("cancel",e=>{if(el.mopAbsSave?.disabled){e.preventDefault();return;}state.pendingMopAbsBatch=null;el.mopAbsMessage.textContent='';});
  el.mopAbsBatchInput?.addEventListener("keydown",e=>{if(e.key==='Enter'){e.preventDefault();saveMopAbsBatch();}});
  el.mopCorrectionClose?.addEventListener("click",()=>closeMopCorrectionDialog());
  el.mopCorrectionCancel?.addEventListener("click",()=>closeMopCorrectionDialog());
  el.mopCorrectionSave?.addEventListener("click",saveMopCorrection);
  el.mopCorrectionDialog?.addEventListener("cancel",e=>{if(state.mopCorrectionSaving){e.preventDefault();return;}state.pendingMopCorrectionBatch=null;state.mopCorrectionContext=null;});
  el.mopCorrectionLines?.addEventListener("input",e=>{const input=e.target.closest("[data-mop-correction-field]");if(input)recalcMopCorrectionLine(input);});
  el.mopCorrectionTrolleyUnknown?.addEventListener("change",()=>{if(el.mopCorrectionTrolleyCodes)el.mopCorrectionTrolleyCodes.disabled=el.mopCorrectionTrolleyUnknown.checked;});
  el.mopCancelClose?.addEventListener("click",()=>closeMopCancelDialog());
  el.mopCancelCancel?.addEventListener("click",()=>closeMopCancelDialog());
  el.mopCancelSave?.addEventListener("click",saveMopCancellation);
  el.mopCancelDialog?.addEventListener("cancel",e=>{if(state.mopCancelSaving){e.preventDefault();return;}state.pendingMopCancelBatch=null;});
  el.mopQueue?.addEventListener("click",e=>{const b=e.target.closest("[data-mop-flow]");if(b)selectMopFlow(b.dataset.mopFlow);});
  el.mopAddTrolley?.addEventListener("click",()=>{setMopSaveMessage("");addMopTrolley();});
  el.mopTrolleyInput?.addEventListener("keydown",e=>{if(e.key==="Enter"){e.preventDefault();addMopTrolley();}});
  el.mopTrolleyChips?.addEventListener("click",e=>{const b=e.target.closest("[data-mop-remove-trolley]");if(!b)return;state.mopTrolleyCodes=state.mopTrolleyCodes.filter(code=>code!==b.dataset.mopRemoveTrolley);renderMopTrolley();});
  el.mopLateTrolleyUnknownInline?.addEventListener("change",()=>{
    if(!state.mopLateEntry)return;
    state.mopLateEntry.trolleyUnknown=Boolean(el.mopLateTrolleyUnknownInline.checked);
    if(state.mopLateEntry.trolleyUnknown)state.mopTrolleyCodes=[];
    setMopSaveMessage("");
    renderMopTrolley();
  });
  el.mopTypeRows?.addEventListener("input",e=>{const input=e.target.closest("[data-mop-field]");if(input){setMopSaveMessage("");recalcMopLine(input);}});
  el.mopClear?.addEventListener("click",()=>{
    const wasLate=Boolean(state.mopLateEntry);
    state.mopSelectedFlowId=null;state.mopTrolleyCodes=[];state.mopLateEntry=null;state.mopReconciliationFlowId=null;
    renderMop();
    setMopSaveMessage("");
    setMessage(wasLate?"Missed-entry draft cleared. The production confirmation is still required.":"");
    if(wasLate)setTimeout(enforceMopReconciliation,0);
  });
  el.mopSave?.addEventListener("click",saveMopProduction);
  el.mopReconciliationChoices?.addEventListener("click",e=>{const b=e.target.closest("[data-mop-reconciliation-choice]");if(b)chooseMopReconciliation(b.dataset.mopReconciliationChoice);});
  el.mopLateContinue?.addEventListener("click",continueMopLateEntry);
  el.mopNotProcessedSave?.addEventListener("click",saveMopNotProcessed);

  renderView();renderShift();renderSelected();renderTrolleyResult();renderTrolleyBasket();renderTrolleyOutboxStatus();paintTrolleyScanBuffer();tickClock();
    state.clockTimer=setInterval(tickClock,1000);
    await refreshAutoShift(true);
    await reload(false);
    flushTrolleyOutbox({silent:true}).catch(error=>console.warn("Trolley outbox flush failed",error));
    state.refreshTimer=setInterval(async()=>{
      if(state.busy||document.visibilityState!=="visible")return;
      if(state.shiftMode==="AUTO")await refreshAutoShift(false);
      await reload(false);
    },30000);
    state.autoShiftTimer=setInterval(async()=>{
      if(state.shiftMode!=="AUTO"||state.busy||document.visibilityState!=="visible")return;
      const changed=await refreshAutoShift(false);
      if(changed)await reload(false);
    },60000);
  }catch(error){console.error(error);setMessage(friendly(error),"error");}

  document.addEventListener("visibilitychange",async()=>{
    if(document.visibilityState!=="visible"||state.busy)return;
    if(state.shiftMode==="AUTO"){
      const changed=await refreshAutoShift(false);
      if(changed)await reload(false);
    }
  });

  addEventListener("beforeunload",(event)=>{
    if(state.trolleyBasket.length||outboxRows().length){
      event.preventDefault();
      event.returnValue="";
      return "";
    }
    if(state.clockTimer)clearInterval(state.clockTimer);
    if(state.refreshTimer)clearInterval(state.refreshTimer);
    if(state.autoShiftTimer)clearInterval(state.autoShiftTimer);
  });
});
