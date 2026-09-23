"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const el = {
    message:$("finishMessage"), businessDate:$("finishBusinessDate"), target:$("finishTarget"), scannerMode:$("finishScannerMode"), signedIn:$("finishSignedIn"),
    productionView:$("finishProductionView"), staffView:$("finishStaffView"), viewEyebrow:$("finishViewEyebrow"), viewTitle:$("finishViewTitle"), viewSubtitle:$("finishViewSubtitle"),
    metrics:$("finishMetrics"), focusedTableTitle:$("finishFocusedTableTitle"), tableFocusTabs:$("finishTableFocusTabs"), recentTitle:$("finishRecentTitle"), recentSubtitle:$("finishRecentSubtitle"), savedSummary:$("finishSavedSummary"), queue:$("finishQueue"), queueCount:$("finishQueueCount"), queueWashedSummary:$("finishQueueWashedSummary"), queueModeTabs:$("finishQueueModeTabs"), queueDayTabs:$("finishQueueDayTabs"), queueModeHint:$("finishQueueModeHint"), routeSummary:$("finishRouteSummary"), search:$("finishQueueSearch"), recent:$("finishRecentEntries"), refresh:$("finishRefreshButton"), viewTabs:$("finishWorkspaceTabs"), shiftAuto:$("finishShiftAutoButton"),
    productionDialog:$("finishProductionDialog"), productionDialogClose:$("finishProductionDialogClose"), productionCancel:$("finishProductionCancelButton"),
    rewashCardLines:$("finishRewashLines"), rewashSummary:$("finishRewashSummary"), rewashSubtitle:$("finishRewashSubtitle"), rewashOpen:$("finishOpenRewashButton"), rewashDialog:$("finishRewashDialog"), rewashDialogTitle:$("finishRewashDialogTitle"), rewashDialogSubtitle:$("finishRewashDialogSubtitle"), rewashDialogClose:$("finishRewashDialogClose"), rewashForm:$("finishRewashForm"), rewashTable:$("finishRewashTable"), rewashShift:$("finishRewashShift"), rewashProcessedBy:$("finishRewashProcessedBy"), rewashOptions:$("finishRewashCustomerOptions"), rewashBatchLines:$("finishRewashBatchLines"), rewashAddLine:$("finishAddRewashLineButton"), rewashTotal:$("finishRewashTotal"), rewashNotes:$("finishRewashNotes"), rewashMessage:$("finishRewashDialogMessage"), rewashCancel:$("finishRewashCancelButton"), rewashSave:$("finishRewashSaveButton"),
    form:$("finishProductionForm"), dialogMessage:$("finishProductionDialogMessage"), flowId:$("finishFlowId"), editId:$("finishEditEntryId"), formTitle:$("finishFormTitle"), formSubtitle:$("finishFormSubtitle"), cutoff:$("finishCutoffBadge"),
    table:$("finishTable"), tableHint:$("finishTableHint"), shiftDisplay:$("finishShiftDisplay"), processedBy:$("finishProcessedBy"), processedByHint:$("finishProcessedByHint"), customerSummary:$("finishCustomerSummary"), existingWrap:$("finishExistingRecordsWrap"), existingRecords:$("finishExistingRecords"),
    batchLines:$("finishBatchLines"), addBatch:$("finishAddBatchButton"), total:$("finishRecordTotal"),
    trolleys:$("finishTrolleys"), trolleyPlanText:$("finishTrolleyPlanText"), trolleySummary:$("finishTrolleySummary"), trolleyOpen:$("finishOpenTrolleyButton"), trolleyReportButton:$("finishReportTrolleyPlanButton"),
    notes:$("finishNotes"), correctionWrap:$("finishCorrectionReasonWrap"), correctionReason:$("finishCorrectionReason"), editBanner:$("finishEditBanner"), editLabel:$("finishEditLabel"), cancelEdit:$("finishCancelEditButton"), save:$("finishSaveButton"), clear:$("finishClearButton"),
    trolleyDialog:$("finishTrolleyDialog"), trolleyDialogTitle:$("finishTrolleyDialogTitle"), trolleyDialogSubtitle:$("finishTrolleyDialogSubtitle"), trolleyDialogClose:$("finishTrolleyDialogClose"), trolleyRequirementCard:$("finishTrolleyRequirementCard"), trolleyScanInput:$("finishTrolleyScanInput"), trolleyAdd:$("finishTrolleyAddButton"), trolleyScannedList:$("finishTrolleyScannedList"), trolleyTally:$("finishTrolleyTally"), trolleyIssues:$("finishTrolleyIssues"), trolleyDialogReport:$("finishTrolleyDialogReportButton"), trolleyNoTrolley:$("finishTrolleyNoTrolleyButton"), trolleyDialogCancel:$("finishTrolleyDialogCancel"), trolleyDialogConfirm:$("finishTrolleyDialogConfirm"),
    staffCount:$("finishStaffCount"), staffList:$("finishStaffList"), staffTableSummary:$("finishStaffTableSummary"), staffScheduleNote:$("finishStaffScheduleNote"),
    staffAdd:$("finishAddStaffButton"), staffDialog:$("finishStaffDialog"), staffDialogTitle:$("finishStaffDialogTitle"), staffDialogSubtitle:$("finishStaffDialogSubtitle"), staffDialogClose:$("finishStaffDialogClose"), staffCancel:$("finishStaffCancelButton"),
    staffForm:$("finishStaffForm"), staffSelect:$("finishStaffSelect"), staffName:$("finishStaffName"), staffCandidates:$("finishStaffCandidates"), staffDialogMessage:$("finishStaffDialogMessage"), staffTable:$("finishStaffTable"), staffStart:$("finishStaffStart"), staffEnd:$("finishStaffEnd"), staffEndHint:$("finishStaffEndHint"), staffCloseShift:$("finishStaffCloseShift"), staffBreak:$("finishStaffBreak"), staffReason:$("finishStaffReason"),
    attendanceDialog:$("finishStaffAttendanceDialog"), attendanceForm:$("finishAttendanceForm"), attendanceDialogTitle:$("finishAttendanceDialogTitle"), attendanceDialogSubtitle:$("finishAttendanceDialogSubtitle"), attendanceDialogClose:$("finishAttendanceDialogClose"), attendanceCancel:$("finishAttendanceCancelButton"), attendanceStaffId:$("finishAttendanceStaffId"), attendanceReason:$("finishAttendanceReason"), attendanceNotes:$("finishAttendanceNotes"), attendanceMessage:$("finishAttendanceDialogMessage"),
    moveDialog:$("finishStaffMoveDialog"), moveForm:$("finishMoveForm"), moveDialogTitle:$("finishMoveDialogTitle"), moveDialogSubtitle:$("finishMoveDialogSubtitle"), moveDialogClose:$("finishMoveDialogClose"), moveCancel:$("finishMoveCancelButton"), moveStaffId:$("finishMoveStaffId"), moveFromTable:$("finishMoveFromTable"), moveToTable:$("finishMoveToTable"), moveTime:$("finishMoveTime"), moveNotes:$("finishMoveNotes"), moveMessage:$("finishMoveDialogMessage"),
    departureDialog:$("finishStaffDepartureDialog"), departureForm:$("finishDepartureForm"), departureDialogTitle:$("finishDepartureDialogTitle"), departureDialogSubtitle:$("finishDepartureDialogSubtitle"), departureDialogClose:$("finishDepartureDialogClose"), departureCancel:$("finishDepartureCancelButton"), departureStaffId:$("finishDepartureStaffId"), departureTable:$("finishDepartureTable"), departureTime:$("finishDepartureTime"), departureNotes:$("finishDepartureNotes"), departureMessage:$("finishDepartureDialogMessage"),
    deliveryReconciliationDialog:$("finishDeliveryReconciliationDialog"), deliveryReconciliationForm:$("finishDeliveryReconciliationForm"), deliveryReconciliationTitle:$("finishDeliveryReconciliationTitle"), deliveryReconciliationSubtitle:$("finishDeliveryReconciliationSubtitle"), deliveryReconciliationSummary:$("finishDeliveryReconciliationSummary"), deliveryReconciliationProcessedOn:$("finishDeliveryReconciliationProcessedOn"), deliveryReconciliationKg:$("finishDeliveryReconciliationKg"), deliveryReconciliationUnit:$("finishDeliveryReconciliationUnit"), deliveryReconciliationBatch:$("finishDeliveryReconciliationBatch"), deliveryReconciliationNotes:$("finishDeliveryReconciliationNotes"), deliveryReconciliationMessage:$("finishDeliveryReconciliationMessage"), deliveryNotProcessed:$("finishDeliveryNotProcessedButton")
  };

  const params = new URLSearchParams(location.search);
  const state = {
    shift:"MORNING",
    shiftMode:"AUTO",
    autoShift:null,
    autoShiftTimer:null,
    view:params.get("view") === "staff" ? "staff" : "production",
    data:null,
    staffData:null,
    selected:null,
    profile:null,
    lockedTable:"",
    activeTable:"FINISH_TABLE_1",
    trolleyReference:null,
    trolleyCodes:[],
    trolleyValidation:null,
    trolleyMismatchAccepted:false,
    trolleyAutoConfirmed:false,
    trolleyPending:false,
    trolleyDialogBackup:[],
    trolleyPendingBackup:false,
    trolleyValidating:false,
    reportSaving:false,
    tableMetrics:new Map(),
    trackerData:null,
    operationalTrackers:new Map(),
    staffCandidates:[],
    queueMode:"TODAY",
    queueDay:"TODAY",
    operationalQueue:null,
    deliveryReconciliation:null,
    deliveryReconciliationTimer:null,
    deliveryReconciliationSaving:false,
    rewashEditing:null
  };

  const esc=(v)=>String(v??"").replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&#039;");
  const tableName=(code)=>({FINISH_TABLE_1:"Table 1",FINISH_TABLE_2:"Table 2",FINISH_TABLE_3:"Table 3"}[code]||code||"—");
  const shiftName=(code)=>String(code||"").toUpperCase()==="EVENING"?"Evening":"Morning";
  const stateLabel=(code)=>({AS_PLANNED:"As planned",ADJUSTED:"Adjusted",INCOMING_ACTUAL:"Incoming Actual",ACTUAL_ELSEWHERE:"Actual elsewhere",ABSENT:"Absent"}[code]||code||"—");
  const fmtDate=(v)=>v?new Intl.DateTimeFormat("en-IE",{day:"2-digit",month:"short",year:"numeric",timeZone:"Europe/Dublin"}).format(new Date(`${String(v).slice(0,10)}T12:00:00Z`)):"—";
  const fmtDateKey=(date=new Date())=>{const parts=new Intl.DateTimeFormat("en-CA",{timeZone:"Europe/Dublin",year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(date);const m=Object.fromEntries(parts.map(p=>[p.type,p.value]));return `${m.year}-${m.month}-${m.day}`;};
  const fmtTime=(v)=>v?new Intl.DateTimeFormat("en-IE",{hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"Europe/Dublin"}).format(new Date(v)):"—";
  const timeText=(v)=>{if(v===null||v===undefined||v===""||v===0||v==="0")return "";const s=String(v).trim();if(/^\d+$/.test(s))return "";if(/^\d{4}-\d{2}-\d{2}[T ]/.test(s)){const date=new Date(s);return Number.isNaN(date.getTime())?"":fmtTime(date);}const m=s.match(/^(\d{1,2}):(\d{2})/);if(m)return `${String(Number(m[1])).padStart(2,"0")}:${m[2]}`;try{return fmtTime(v);}catch{return "";}};
  const timeMinutes=(v)=>{const t=timeText(v);if(!t)return null;const [h,m]=t.split(":").map(Number);return h*60+m;};
  const normalizeTrolley=(v)=>String(v||"").trim().toUpperCase().replace(/[^A-Z0-9_]/g,"");
  const safeRouteColor=(v)=>{const raw=String(v||"").trim();const hex=raw.match(/^#?([0-9a-fA-F]{6})$/);return hex?`#${hex[1]}`:"#0f766e";};
  const routeTextColor=(hex)=>{const m=/^#([0-9a-f]{6})$/i.exec(String(hex||""));if(!m)return"#111827";const n=parseInt(m[1],16),r=(n>>16)&255,g=(n>>8)&255,b=n&255;return ((.299*r+.587*g+.114*b)/255)>.62?"#111827":"#ffffff";};
   const staffStorageKey=(tableCode,shiftCode)=>`finish:lastProcessedStaff:${String(tableCode||"")}:${String(shiftCode||"")}`;
   const weekdayShort=(v)=>{const dateKey=String(v||"").slice(0,10);if(!/^\d{4}-\d{2}-\d{2}$/.test(dateKey))return "";const [year,month,day]=dateKey.split("-").map(Number),date=new Date(year,month-1,day);return Number.isNaN(date.getTime())?"":new Intl.DateTimeFormat("en-IE",{weekday:"short"}).format(date);};
   const scheduledDateBadge=(v)=>{const dateKey=String(v||"").slice(0,10),weekday=weekdayShort(dateKey);if(!weekday)return "";const [,month,day]=dateKey.split("-");return `${weekday} ${day}/${month}`;};

  async function rpc(name,args={}){
    const stationWrites={
      record_finish_production_v3:"terminal_record_finish_production_v1",
      correct_finish_production_v3:"terminal_correct_finish_production_v1",
      upsert_finish_staff_actual:"terminal_upsert_finish_staff_actual_v1",
      set_finish_staff_attendance_v1:"terminal_set_finish_staff_attendance_v1",
      move_finish_staff_table_v1:"terminal_move_finish_staff_table_v1",
      move_finish_staff_to_sorting_v1:"terminal_move_finish_staff_to_sorting_v1",
      finish_end_staff_shift_v1:"terminal_finish_end_staff_shift_v1",
      set_finish_staff_break_v1:"terminal_set_finish_staff_break_v1",
      correct_finish_staff_time_v1:"terminal_correct_finish_staff_time_v1",
      report_customer_trolley_requirement_issue:"terminal_report_finish_trolley_requirement_issue_v1",
      resolve_finish_delivery_reconciliation_v2:"terminal_resolve_finish_delivery_reconciliation_v2",
      record_finish_rewash_v1:"terminal_record_finish_rewash_v1"
    };
    if(stationWrites[name]){
      name=stationWrites[name];
    }
    const {data,error}=await client.rpc(name,args);if(error)throw error;return data;
  }
  function setMessage(text="",type=""){el.message.textContent=text;el.message.className=`finish-message ${type}`.trim();}
  function setDialogMessage(text="",type=""){el.dialogMessage.textContent=text;el.dialogMessage.className=`finish-message ${type}`.trim();}
  function setStaffDialogMessage(text="",type=""){el.staffDialogMessage.textContent=text;el.staffDialogMessage.className=`finish-message ${type}`.trim();}
  function trolleyCodes(){return state.trolleyCodes.slice();}
  function syncTrolleyHidden(){el.trolleys.value=state.trolleyCodes.join("\n");}
  function currentLines(){return [...el.batchLines.querySelectorAll(".finish-batch-line")].map(row=>({batch_reference:row.querySelector("[data-batch]").value.trim().toUpperCase(),unit_code:row.querySelector("[data-unit]").value,quantity:row.querySelector("[data-qty]").value})).filter(x=>x.batch_reference||x.quantity);}
  function unitsPerKg(){const value=Number(state.data?.units_per_kg||6);return Number.isFinite(value)&&value>0?value:6;}
  function quantitySummary(kg,units){const rawKg=Math.max(0,Number(kg)||0),rawUnits=Math.max(0,Number(units)||0),rate=unitsPerKg(),equivalent=rawKg+(rawUnits/rate);return rawUnits>0?`${equivalent.toFixed(2)} kg equivalent - ${rawKg.toFixed(2)} kg + ${Math.round(rawUnits)} units (${rate} units = 1 kg)`:`${rawKg.toFixed(2)} kg`;}

  function addLine(line={}){
    const row=document.createElement("div");row.className="finish-batch-line";
    row.innerHTML=`<input data-batch placeholder="Batch number" value="${esc(line.batch_reference||"")}"><select data-unit><option value="KG" ${line.unit_code==="KG"?"selected":""}>KG</option><option value="UNIT" ${line.unit_code==="UNIT"?"selected":""}>Units</option></select><input data-qty type="number" min="0.01" step="0.01" inputmode="decimal" placeholder="Quantity" value="${esc(line.quantity??"")}"><button type="button" title="Remove line">×</button>`;
    row.querySelector("button").addEventListener("click",()=>{row.remove();if(!el.batchLines.children.length)addLine();updateTotal();});
    row.querySelectorAll("input,select").forEach(x=>x.addEventListener("input",updateTotal));el.batchLines.appendChild(row);updateTotal();
  }
  function updateTotal(){let kg=0,units=0;currentLines().forEach(l=>{const n=Number(l.quantity)||0;if(l.unit_code==="KG")kg+=n;else units+=n;});el.total.textContent=`${kg.toFixed(2)} kg · ${Math.round(units)} units`;}

  function updateTotal(){let kg=0,units=0;currentLines().forEach(l=>{const n=Number(l.quantity)||0;if(l.unit_code==="KG")kg+=n;else units+=n;});el.total.textContent=quantitySummary(kg,units);}
  function currentProductionStaff(tableCode=el.table.value,shiftCode=state.shift){
    return (state.data?.production_staff_now||[]).filter(row=>row.table_code===tableCode&&row.shift_code===shiftCode&&row.available_now===true);
  }
  function historicalProductionStaff(entry){
    if(!entry)return[];
    return (state.data?.processing_staff_history||[]).filter(row=>String(row.business_date||"").slice(0,10)===String(entry.business_date||"").slice(0,10)&&row.table_code===entry.table_code&&row.shift_code===entry.shift_code);
  }
  function fillProcessedByOptions({entry=null,preserve=true}={}){
    if(!el.processedBy)return;
    const current=preserve?el.processedBy.value:"";
    let rows=entry?historicalProductionStaff(entry):currentProductionStaff();
    const dedup=new Map();rows.forEach(row=>{if(row?.staff_id&&!dedup.has(row.staff_id))dedup.set(row.staff_id,row);});
    if(entry?.processed_by_staff_id&&!dedup.has(entry.processed_by_staff_id))dedup.set(entry.processed_by_staff_id,{staff_id:entry.processed_by_staff_id,display_name:entry.processed_by||"Previously recorded staff"});
    rows=[...dedup.values()].sort((a,b)=>String(a.display_name||"").localeCompare(String(b.display_name||""),"en-IE",{sensitivity:"base"}));
    el.processedBy.innerHTML='<option value="">Select staff…</option>'+rows.map(row=>`<option value="${esc(row.staff_id)}">${esc(row.display_name)}</option>`).join("");
    let pick="";
    if(current&&rows.some(r=>r.staff_id===current))pick=current;
    if(!pick&&entry?.processed_by_staff_id&&rows.some(r=>r.staff_id===entry.processed_by_staff_id))pick=entry.processed_by_staff_id;
    if(!pick&&!entry){try{const last=localStorage.getItem(staffStorageKey(el.table.value,state.shift))||"";if(last&&rows.some(r=>r.staff_id===last))pick=last;}catch(_){} }
    if(!pick&&rows.length===1)pick=rows[0].staff_id;
    el.processedBy.value=pick;
    el.processedBy.disabled=false;
    if(entry){el.processedByHint.textContent=`Processed-by history for ${tableName(entry.table_code)} / ${shiftName(entry.shift_code)} / ${fmtDate(entry.business_date)}. Scanner identity is stored separately.`;}
    else if(rows.length){const planned=rows.filter(r=>r.source==="ROSTER_PLANNED").length,actual=rows.filter(r=>r.source==="ACTUAL").length;el.processedByHint.textContent=`${rows.length} staff available on ${tableName(el.table.value)} / ${shiftName(state.shift)}${actual?` · ${actual} Actual`:""}${planned?` · ${planned} from Roster`:""}. Last selection on this workstation is remembered.`;}
    else{el.processedByHint.textContent=`No staff is available for ${tableName(el.table.value)} / ${shiftName(state.shift)}. Check Finish Staff / Roster assignment before saving.`;}
  }

  function renderShift(){
    document.querySelectorAll("[data-shift]").forEach(btn=>btn.classList.toggle("active",btn.dataset.shift===state.shift));
    if(el.shiftAuto){el.shiftAuto.classList.toggle("active",state.shiftMode==="AUTO");el.shiftAuto.textContent=state.shiftMode==="AUTO"?`Auto · ${shiftName(state.shift)}`:"Auto";}
  }
  function hasProductionDraft(){
    if(!el.productionDialog?.open)return false;
    return Boolean(el.editId.value||currentLines().some(x=>x.batch_reference||x.quantity)||el.notes.value.trim()||state.trolleyCodes.length||state.trolleyPending);
  }
  async function refreshAutoShift(force=false){
    if(state.shiftMode!=="AUTO"&&!force)return false;
    const auto=await rpc("get_finish_auto_shift_context",{});state.autoShift=auto||null;
    const recommended=String(auto?.recommended_shift_code||"").toUpperCase();
    if(!["MORNING","EVENING"].includes(recommended))return false;
    if(recommended===state.shift){renderShift();return false;}
    if(!force&&(hasProductionDraft()||el.staffDialog?.open)){
      setMessage(`Auto Shift recommends ${shiftName(recommended)}, but an open Finish form has unsaved data. Save or close it before the shift changes.`,"warning");
      return false;
    }
    state.shift=recommended;renderShift();
    if(el.productionDialog?.open)closeProductionDialog();
    if(el.staffDialog?.open)closeStaffDialog();
    return true;
  }

  // Same formulas as the current Google Script Finish Results/Table flow.
  function staffFullHours(row){
    const start=timeMinutes(row.effective_start_time),endRaw=timeMinutes(row.effective_end_time);if(start==null)return 0;
    const br=Math.max(0,Number(row.break_minutes||0)+Number(row.extra_non_work_minutes||0));
    if(endRaw==null){const nowParts=new Intl.DateTimeFormat("en-GB",{timeZone:"Europe/Dublin",hour:"2-digit",minute:"2-digit",hour12:false}).format(new Date()).split(":").map(Number);let end=nowParts[0]*60+nowParts[1];if(end<start)end+=1440;return Math.max(0,(end-start-br)/60);}
    let end=endRaw;if(end<start)end+=1440;return Math.max(0,(end-start-br)/60);
  }
  function workedTimeText(row){
    if(!row.actual_in_finish||!row.actual_start_at||row.attendance_status==="ABSENT")return "Not confirmed";
    const start=new Date(row.actual_start_at).getTime(),end=row.actual_end_at?new Date(row.actual_end_at).getTime():Date.now();
    if(!Number.isFinite(start)||!Number.isFinite(end)||end<=start)return "0h 00m";
    const minutes=Math.max(0,Math.round((end-start)/60000)-Number(row.break_minutes||0)-Number(row.extra_non_work_minutes||0));
    return `${Math.floor(minutes/60)}h ${String(minutes%60).padStart(2,"0")}m`;
  }
  function plannedWorkedTimeText(row){const gross=shiftMinutes(row.planned_start_time||row.effective_start_time,row.planned_end_time||row.effective_end_time);return gross==null?"-":minutesLabel(Math.max(0,gross-Number(row.break_minutes||0)-Number(row.extra_non_work_minutes||0)));}
  function shiftMinutes(start,end){const s=timeMinutes(start),e=timeMinutes(end);if(s==null||e==null)return null;let total=e-s;if(total<0)total+=1440;return total;}
  function minutesLabel(minutes){const value=Math.max(0,Math.round(Number(minutes)||0));return `${Math.floor(value/60)}h ${String(value%60).padStart(2,"0")}m`;}
  function confirmStaffTimeChange({name,start,end,breakMinutes,extraMinutes=0,tableNameText}){const gross=end?shiftMinutes(start,end):null;if(gross!=null&&gross>780){setStaffDialogMessage("A staff shift cannot be longer than 13 hours.","error");return false;}const net=gross==null?"Open shift":minutesLabel(Math.max(0,gross-breakMinutes-extraMinutes));return window.confirm(`Confirm staff time\n\n${name}\nTable: ${tableNameText}\nStarted: ${start||"Not set"}\nLeaving: ${end||"Open shift"}\nBreak: ${breakMinutes} min\nWorked: ${net}\n\nSave these changes?`);}
  function updateStaffDepartureHint(){if(!el.staffEndHint||!el.staffCloseShift)return;const planned=el.staffEnd.dataset.plannedEnd||"";const saved=el.staffEnd.dataset.savedActualEnd||"";if(el.staffCloseShift.checked){el.staffEndHint.textContent=`This will close the shift at ${el.staffEnd.value||"the selected time"}.`;return;}if(saved){el.staffEndHint.textContent=`Saved leaving time: ${saved}. Untick to reopen the shift.`;return;}el.staffEndHint.textContent=planned?`Planned leaving time: ${planned}. Tick below only when the person has actually left.`:"Leave this open until the person has actually left.";}
  function resetStaffDepartureControl(){el.staffCloseShift.checked=false;el.staffEnd.dataset.plannedEnd="";el.staffEnd.dataset.savedActualEnd="";updateStaffDepartureHint();}
  function currentStaffHours(rows,businessDate,fallbackFullHours){
    const today=fmtDateKey(),bd=String(businessDate||"").slice(0,10);if(bd&&bd<today)return Number(fallbackFullHours||0);if(bd&&bd>today)return 0;
    const nowParts=new Intl.DateTimeFormat("en-GB",{timeZone:"Europe/Dublin",hour:"2-digit",minute:"2-digit",hour12:false}).format(new Date()).split(":").map(Number),nowBase=nowParts[0]*60+nowParts[1];let total=0;
    rows.forEach(row=>{const full=staffFullHours(row);if(full<=0)return;const start=timeMinutes(row.effective_start_time),endRaw=timeMinutes(row.effective_end_time);if(start==null)return;if(endRaw==null){let nowRel=nowBase;if(nowRel<start)nowRel+=1440;const elapsed=Math.max(0,nowRel-start),br=Math.max(0,Number(row.break_minutes||0)+Number(row.extra_non_work_minutes||0));total+=Math.min(full,Math.max(0,elapsed-br)/60);return;}let end=endRaw;if(end<start)end+=1440;let nowRel=nowBase;if(end>=1440&&nowRel<(end-1440))nowRel+=1440;const span=Math.max(0,end-start);if(!span)return;const elapsed=Math.max(0,Math.min(span,nowRel-start));total+=full*(elapsed/span);});
    const cap=Number(fallbackFullHours||0);if(cap>0)total=Math.min(total,cap);return Number(total.toFixed(2));
  }
  function calculateTableMetrics(){
    state.tableMetrics.clear();const target=Number(state.staffData?.target_kg_per_staff_hour||23.5),businessDate=state.staffData?.business_date,staff=(state.staffData?.staff||[]).filter(s=>s.actual_in_finish!==false&&s.effective_table_code);
    (state.staffData?.tables||[]).forEach(table=>{const rows=staff.filter(s=>s.effective_table_code===table.table_code),fullHours=rows.reduce((sum,row)=>sum+staffFullHours(row),0),nowHours=currentStaffHours(rows,businessDate,fullHours),produced=Number(table.produced_kg||0),planned=fullHours*target,targetNow=nowHours*target;state.tableMetrics.set(table.table_code,{...table,staff_count:rows.length,staff_hours:fullHours,current_staff_hours:nowHours,planned_kg:planned,target_now_kg:targetNow,difference_kg:produced-targetNow,efficiency_percent:planned>0?produced/planned*100:null,kg_per_staff_hour:fullHours>0?produced/fullHours:null,target_kg_per_staff_hour:target});});
  }
  function renderMetrics(){
    calculateTableMetrics();
    const code=state.lockedTable||state.activeTable||"FINISH_TABLE_1",t=state.tableMetrics.get(code)||{table_code:code,produced_kg:0,target_now_kg:0,difference_kg:0,planned_kg:0,staff_hours:0,staff_count:0,efficiency_percent:null,kg_per_staff_hour:null};
    state.activeTable=code;
    const diff=Number(t.difference_kg||0),eff=t.efficiency_percent==null?"—":`${Number(t.efficiency_percent).toFixed(1)}%`;
    if(el.focusedTableTitle)el.focusedTableTitle.textContent=tableName(code);
    if(el.tableFocusTabs){el.tableFocusTabs.hidden=Boolean(state.lockedTable);el.tableFocusTabs.querySelectorAll("[data-focus-table]").forEach(btn=>btn.classList.toggle("active",btn.dataset.focusTable===code));}
    el.metrics.innerHTML=`<div class="finish-kpi produced"><span>Produced</span><strong>${Number(t.produced_kg||0).toFixed(1)} kg</strong><small>${Number(t.staff_count||0)} staff working</small></div><div class="finish-kpi planned"><span>Planned</span><strong>${Number(t.planned_kg||0).toFixed(1)} kg</strong><small>${Number(t.staff_hours||0).toFixed(2)} staff hours × ${Number(t.target_kg_per_staff_hour||23.5).toFixed(1)}</small></div><div class="finish-kpi target-now"><span>Target now</span><strong>${Number(t.target_now_kg||0).toFixed(1)} kg</strong><small class="${diff>=0?"delta-positive":"delta-negative"}">${diff>=0?"Ahead":"Behind"} ${Math.abs(diff).toFixed(1)} kg</small></div><div class="finish-kpi efficiency"><span>Efficiency</span><strong>${esc(eff)}</strong><small>${t.kg_per_staff_hour==null?"—":`${Number(t.kg_per_staff_hour).toFixed(2)} kg/staff-hour`}</small></div>`;
  }

  function activeTableCode(){return state.lockedTable||state.activeTable||"FINISH_TABLE_1";}
  function rewashEntries(){return state.data?.rewash_entries||[];}
  function activeRewashEntry(){const code=activeTableCode();return rewashEntries().find(entry=>entry.table_code===code&&String(entry.shift_code||"").toUpperCase()===state.shift)||null;}
  function rewashCustomerOptions(){return state.data?.rewash_customer_options||[];}
  function shortWeekday(day){return String(day||"").slice(0,3);}
  function rewashCustomerOptionLabel(customer,day=null){
    if(!customer?.customer_id&&!customer?.customer_name)return "";
    const suffix=day?` (${shortWeekday(day)})`:"";
    return `${customer?.customer_name||"Customer"}${suffix}`;
  }
  function rewashCustomerOptionRows(){
    return rewashCustomerOptions().flatMap(customer=>{
      const days=(customer?.scheduled_days||[]).map(day=>String(day)).filter(Boolean);
      if(days.length){
        return days.map(day=>({...customer,option_label:rewashCustomerOptionLabel(customer,day),selected_scheduled_days:[day]}));
      }
      return [{...customer,option_label:rewashCustomerOptionLabel(customer),selected_scheduled_days:[]}];
    });
  }
  function rewashCustomerLabel(customer){
    const days=(customer?.scheduled_days||[]).map(day=>String(day)).filter(Boolean);
    return rewashCustomerOptionLabel(customer,days.length===1?days[0]:null);
  }
  function rewashCustomerByValue(value){const raw=String(value||"").trim().toLocaleLowerCase();return rewashCustomerOptionRows().find(customer=>String(customer.option_label||"").toLocaleLowerCase()===raw)||rewashCustomerOptions().find(customer=>String(customer.customer_name||"").toLocaleLowerCase()===raw||String(customer.customer_code||"").toLocaleLowerCase()===raw)||null;}
  function setRewashMessage(text="",type=""){el.rewashMessage.textContent=text;el.rewashMessage.className=`finish-message ${type}`.trim();}
  function rewashLinesFromForm(){return [...el.rewashBatchLines.querySelectorAll(".finish-rewash-batch-line")].map(row=>{const customer=rewashCustomerByValue(row.querySelector("[data-rewash-customer]").value);return {customer_id:customer?.customer_id||"",scheduled_days:customer?.selected_scheduled_days||customer?.scheduled_days||[],batch_reference:row.querySelector("[data-rewash-batch]").value.trim().toUpperCase(),quantity_kg:row.querySelector("[data-rewash-kg]").value};});}
  function updateRewashTotal(){const total=rewashLinesFromForm().reduce((sum,line)=>sum+(Number(line.quantity_kg)||0),0);el.rewashTotal.textContent=`${total.toFixed(1)} kg`;}
  function addRewashLine(line={}){
    const customer=rewashCustomerOptions().find(item=>item.customer_id===line.customer_id);
    const lineCustomer=line.customer_id||line.customer_name?{customer_id:line.customer_id,customer_name:line.customer_name,scheduled_days:line.scheduled_days}:null;
    const label=line.customer_label||rewashCustomerLabel(customer||lineCustomer);
    const row=document.createElement("div");row.className="finish-rewash-batch-line";
    row.innerHTML=`<input data-rewash-customer type="search" list="finishRewashCustomerOptions" autocomplete="off" placeholder="Search customer" value="${esc(label||"")}"><input data-rewash-batch maxlength="120" placeholder="Optional batch" value="${esc(line.batch_reference||"")}"><input data-rewash-kg type="number" min="0.01" step="0.1" inputmode="decimal" placeholder="KG" value="${esc(line.quantity_kg??"")}"><button type="button" class="secondary" title="Remove ReWash customer">x</button>`;
    row.querySelector("button").addEventListener("click",()=>{row.remove();if(!el.rewashBatchLines.children.length)addRewashLine();updateRewashTotal();});
    row.querySelectorAll("input").forEach(input=>input.addEventListener("input",updateRewashTotal));
    el.rewashBatchLines.appendChild(row);updateRewashTotal();
  }
  function renderRewashCard(){
    const entry=activeRewashEntry(),code=activeTableCode();
    if(el.rewashSubtitle)el.rewashSubtitle.textContent=`${tableName(code)} - ${shiftName(state.shift)} - one real production record. No trolley required.`;
    if(!entry){el.rewashSummary.textContent="No ReWash recorded";el.rewashOpen.textContent="Record ReWash";el.rewashCardLines.innerHTML='<div class="finish-rewash-empty">Blank ReWash record ready for this Table / Shift.</div>';return;}
    const total=Number(entry.processed_kg||0),lines=entry.lines||[];
    el.rewashSummary.textContent=`${lines.length} customers - ${total.toFixed(1)} kg`;
    el.rewashOpen.textContent="Edit ReWash";
    el.rewashCardLines.innerHTML=lines.map(line=>`<article><strong>${esc(line.customer_name)}</strong><span>${esc((line.scheduled_days||[]).map(day=>String(day).slice(0,3)).join(", ")||"No schedule day")}${line.batch_reference?` - Batch ${esc(line.batch_reference)}`:""}</span><b>${Number(line.quantity_kg||0).toFixed(1)} kg</b></article>`).join("");
  }
  function fillRewashStaffOptions(entry=null){
    const code=activeTableCode(),rows=currentProductionStaff(code,state.shift),dedup=new Map();
    rows.forEach(row=>{if(row.staff_id&&!dedup.has(row.staff_id))dedup.set(row.staff_id,row);});
    if(entry?.processed_by_staff_id&&!dedup.has(entry.processed_by_staff_id))dedup.set(entry.processed_by_staff_id,{staff_id:entry.processed_by_staff_id,display_name:entry.processed_by||"Previously recorded staff"});
    const list=[...dedup.values()].sort((a,b)=>String(a.display_name||"").localeCompare(String(b.display_name||""),"en-IE",{sensitivity:"base"}));
    el.rewashProcessedBy.innerHTML='<option value="">Select staff...</option>'+list.map(row=>`<option value="${esc(row.staff_id)}">${esc(row.display_name)}</option>`).join("");
    el.rewashProcessedBy.value=entry?.processed_by_staff_id||"";
    if(!el.rewashProcessedBy.value&&list.length===1)el.rewashProcessedBy.value=list[0].staff_id;
  }
  function closeRewashDialog(){if(el.rewashDialog.open)el.rewashDialog.close();state.rewashEditing=null;el.rewashForm.reset();el.rewashBatchLines.innerHTML="";setRewashMessage("");}
  function openRewashDialog(){
    if(activeDeliveryReconciliation()){presentDeliveryReconciliation();return;}
    const entry=activeRewashEntry(),code=activeTableCode();state.rewashEditing=entry;
    el.rewashForm.reset();el.rewashBatchLines.innerHTML="";el.rewashTable.value=tableName(code);el.rewashShift.value=shiftName(state.shift);el.rewashDialogTitle.textContent=entry?"Edit ReWash":"Record ReWash";
    el.rewashDialogSubtitle.textContent=`${tableName(code)} - ${shiftName(state.shift)}. Each line needs a valid Clothes or Others customer and KG; batch is optional.`;
    el.rewashOptions.innerHTML=rewashCustomerOptionRows().map(customer=>`<option value="${esc(customer.option_label)}"></option>`).join("");
    fillRewashStaffOptions(entry);(entry?.lines||[]).forEach(addRewashLine);if(!el.rewashBatchLines.children.length)addRewashLine();setRewashMessage("");el.rewashDialog.showModal();
  }
  function lineHasSavedProduction(line){return Boolean(String(line?.batch_reference||"").trim()) && Number(line?.quantity||0)>0;}
  function entryHasSavedProduction(entry){return Boolean(Number(entry?.processed_kg||0)>0||Number(entry?.processed_units||0)>0||(entry?.lines||[]).some(lineHasSavedProduction));}
  function flowEntries(flowId){return (state.data?.entries||[]).filter(e=>e.production_flow_item_id===flowId&&entryHasSavedProduction(e)).sort((a,b)=>new Date(b.recorded_at||0)-new Date(a.recorded_at||0));}
  function latestBatchForFlow(flowId){const e=flowEntries(flowId)[0];return e?.lines?.find(lineHasSavedProduction)?.batch_reference||e?.lines?.[0]?.batch_reference||"";}
  function entryBatchText(e){return (e.lines||[]).map(l=>l.batch_reference).filter(Boolean).join(", ")||"—";}
  function currentContextEntry(flowId,tableCode){const bd=String(state.data?.business_date||"").slice(0,10);return flowEntries(flowId).find(e=>String(e.business_date).slice(0,10)===bd&&e.shift_code===state.shift&&e.table_code===tableCode)||null;}

  function trackerRouteKey(row){return String(row?.route_code||row?.route_display_name||row?.route_name||"UNASSIGNED").trim().toUpperCase()||"UNASSIGNED";}
  function trackerRouteStats(routeKey){const rows=(state.trackerData?.items||[]).filter(x=>trackerRouteKey(x)===routeKey);if(!rows.length)return null;const done=rows.filter(x=>String(x.product_status||"").toUpperCase()==="TRACKER_OK").length;const customers=new Set(rows.map(x=>x.customer_id||x.customer_name));const customerDone=new Set();for(const c of customers){const cr=rows.filter(x=>(x.customer_id||x.customer_name)===c);if(cr.length&&cr.every(x=>String(x.product_status||"").toUpperCase()==="TRACKER_OK"))customerDone.add(c);}return {streams:rows.length,done,customers:customers.size,customersDone:customerDone.size,ready:done===rows.length&&rows.length>0};}
  function queueStateMeta(q){
    const st=String(q.finish_state||"").toUpperCase(),reconciled=String(q.reconciliation_outcome_code||"").toUpperCase()==="PROCESSED_CONFIRMED",hasProduction=Number(q.processed_kg||q.processed_quantity_kg||0)>0||Number(q.processed_units||q.processed_quantity_units||0)>0||flowEntries(q.production_flow_item_id).length>0;
    if(st==="RECONCILED"||reconciled)return{label:"CONFIRMED",icon:"OK",cls:"processed",actionable:false,done:true,reconciled:true};
    if(st==="LOCKED")return{label:"LOCKED",icon:"■",cls:"locked",actionable:false,done:hasProduction};
    if(st==="CONTINUE")return{label:"CONTINUE",icon:"↻",cls:"continue",actionable:true,done:true};
    if(st==="READY")return{label:"READY",icon:"○",cls:"todo",actionable:true,done:false};
    const trackerStatus=String(q.product_status||"").toUpperCase();
    if(hasProduction||trackerStatus==="TRACKER_OK")return{label:"DONE",icon:"✓",cls:"processed",actionable:false,done:true};
    if(trackerStatus==="WASHED_ONLY"||Number(q.washed_kg_total||0)>0)return{label:"WAIT",icon:"◷",cls:"waiting",actionable:false,done:false};
    return{label:"WAIT WASH",icon:"◷",cls:"waiting",actionable:false,done:false};
  }
  function queueRowKey(row){const flowId=String(row?.production_flow_item_id||"").trim();if(flowId)return `F:${flowId}`;return `S:${row?.schedule_product_id||""}:${row?.customer_id||row?.customer_code||row?.customer_name||""}:${String(row?.scheduled_for_date||"").slice(0,10)}:${row?.product_code||"CLOTHES"}`;}
  function trackerFinishRows(trackerData){
    const queueMap=new Map((state.data?.queue||[]).map(q=>[String(q.production_flow_item_id||""),q]));
    const trackerRows=(trackerData?.items||[]).filter(t=>String(t.product_code||"").toUpperCase()==="CLOTHES");
    if(!trackerRows.length)return (state.data?.queue||[]).filter(q=>String(q.scheduled_for_date||"").slice(0,10)===String(state.data?.business_date||"").slice(0,10));
    return trackerRows.map(t=>{
      const flowId=String(t.production_flow_item_id||"").trim(),q=flowId?queueMap.get(flowId):null;
      return {...t,
        ...(q||{}),
        route_name:q?.route_name||t.route_display_name||t.route_code||"No route",
        route_code:q?.route_code||t.route_code,
        route_color:q?.route_color||t.route_color,
        customer_name:q?.customer_name||t.customer_name,
        customer_code:q?.customer_code||t.customer_code,
        scheduled_for_date:q?.scheduled_for_date||t.scheduled_for_date,
        production_order:q?.production_order??t.production_order,
        processed_kg:q?.processed_kg??t.processed_quantity_kg??t.processed_weight_kg??0,
        processed_units:q?.processed_units??t.processed_quantity_units??t.processed_units??0,
        _finish_queue_available:Boolean(q)
      };
    });
  }
  function todayFinishRows(){return trackerFinishRows(state.trackerData);}
  function operationalBusinessDate(){return String(state.operationalQueue?.business_date||state.data?.business_date||"").slice(0,10);}
  function operationalAdvancedDate(){return String(state.operationalQueue?.advanced_date||"").slice(0,10);}
  function activeQueueDate(){
    const today=operationalBusinessDate(),tomorrow=operationalAdvancedDate();
    if(state.queueDay==="TOMORROW"&&tomorrow)return tomorrow;
    return today;
  }
  function operationalQueueRows(){
    const operationalDates=new Set([operationalBusinessDate(),operationalAdvancedDate()].filter(Boolean));
    const baseByFlow=new Map((state.data?.queue||[]).map(q=>[queueRowKey(q),q]));
    const rowsByFlow=new Map();
    const mergeRow=(row)=>{
      const rowKey=queueRowKey(row),base=baseByFlow.get(rowKey)||{};
      return {...base,...row,
        customer_name:row.customer_name||base.customer_name,
        customer_code:row.customer_code||base.customer_code,
        route_code:row.route_code||base.route_code,
        route_name:row.route_name||base.route_name,
        route_color:row.route_color||base.route_color,
        production_order:row.production_order??base.production_order,
        scheduled_for_date:row.scheduled_for_date||base.scheduled_for_date,
        delivery_date:row.delivery_date||base.delivery_date
      };
    };
    [...state.operationalTrackers.values()].flatMap(trackerFinishRows).filter(row=>!operationalDates.size||operationalDates.has(String(row.scheduled_for_date||"").slice(0,10))).forEach(row=>rowsByFlow.set(queueRowKey(row),mergeRow(row)));
    (state.operationalQueue?.rows||[]).filter(row=>operationalDates.has(String(row.scheduled_for_date||"").slice(0,10))).forEach(row=>rowsByFlow.set(queueRowKey(row),mergeRow(row)));
    if(rowsByFlow.size)return [...rowsByFlow.values()];
    return todayFinishRows();
  }
  function queueRows(){
    const term=el.search.value.trim().toLowerCase();
    const date=activeQueueDate();
    let rows=state.queueMode==="AVAILABLE"
      ? operationalQueueRows().filter(q=>queueStateMeta(q).actionable&&!flowEntries(q.production_flow_item_id).some(e=>(e.lines||[]).some(lineHasSavedProduction)))
      : operationalQueueRows();
    if(date)rows=rows.filter(q=>String(q.scheduled_for_date||"").slice(0,10)===date);
    rows=rows.slice().sort((a,b)=>String(a.scheduled_for_date||"").slice(0,10).localeCompare(String(b.scheduled_for_date||"").slice(0,10))||Number(a.production_order??999999)-Number(b.production_order??999999)||String(a.customer_name||"").localeCompare(String(b.customer_name||"")));
    if(term)rows=rows.filter(q=>JSON.stringify(q).toLowerCase().includes(term));
    return rows;
  }
  function operationalQueueDayLabel(value){
    const date=String(value||"").slice(0,10),businessDate=String(state.operationalQueue?.business_date||state.data?.business_date||"").slice(0,10);
    if(!date)return {title:"Scheduled",date:""};
    const difference=businessDate?Math.round((new Date(`${date}T00:00:00`)-new Date(`${businessDate}T00:00:00`))/86400000):0;
    const title=difference===0?"Today":difference===-1?"Yesterday":difference===1?"Tomorrow":difference<0?"Earlier schedule":"Upcoming schedule";
    return {title,date:fmtDate(date)};
  }
  function renderQueueDayTabs(){
    if(!el.queueDayTabs)return;
    const today=operationalBusinessDate(),tomorrow=operationalAdvancedDate();
    if(!tomorrow||tomorrow===today){
      state.queueDay="TODAY";
      el.queueDayTabs.hidden=true;
      el.queueDayTabs.innerHTML="";
      return;
    }
    if(!["TODAY","TOMORROW"].includes(state.queueDay))state.queueDay="TODAY";
    el.queueDayTabs.hidden=false;
    el.queueDayTabs.innerHTML=[
      ["TODAY","Today",today],
      ["TOMORROW","Tomorrow",tomorrow]
    ].map(([code,label,date])=>`<button type="button" class="${state.queueDay===code?"active":""}" data-queue-day="${code}"><strong>${esc(label)}</strong><span>${esc(fmtDate(date))}</span></button>`).join("");
  }
  function renderRouteSummary(){
    if(!el.routeSummary)return;
    const source=todayFinishRows();
    const groups=new Map();source.forEach(q=>{const key=trackerRouteKey(q);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(q);});
    const rows=[...groups.entries()].sort((a,b)=>Math.min(...a[1].map(x=>Number(x.production_order??999999)))-Math.min(...b[1].map(x=>Number(x.production_order??999999))));
    el.routeSummary.innerHTML=rows.map(([key,items])=>{const first=items[0],color=safeRouteColor(first.route_color),fg=routeTextColor(color),stats=trackerRouteStats(key),done=items.filter(q=>queueStateMeta(q).done).length,ready=Boolean(stats?.ready),text=ready?"READY":stats?`${stats.customersDone}/${stats.customers}`:`${done}/${items.length}`;return `<span class="finish-route-chip ${ready?"ready":""}" style="--route-color:${color};--route-fg:${fg}" title="${esc(first.route_name||first.route_display_name||first.route_code||"Route")} · ${ready?"Ready to deliver":`${text} customers ready`}"><b>${esc(first.route_code||"R")}</b><em>${esc(text)}</em>${ready?"<i>✓</i>":""}</span>`;}).join("");
  }
  function renderQueue(){
    renderQueueDayTabs();
    const items=queueRows();
    if(el.queueModeTabs)el.queueModeTabs.querySelectorAll("[data-queue-mode]").forEach(btn=>btn.classList.toggle("active",btn.dataset.queueMode===state.queueMode));
    if(el.queueModeHint)el.queueModeHint.textContent=state.queueMode==="TODAY"?(state.queueDay==="TOMORROW"?"Tomorrow list - full next schedule day while Finish works ahead.":"Today list - waiting, ready and completed customers in production order."):"Available only - customers with no saved Batch + KG/Units yet.";
    if(el.queueCount)el.queueCount.textContent=String(items.length);
    if(!items.length){el.queue.innerHTML=`<div class="finish-empty">${state.queueMode==="AVAILABLE"?"No customer is currently available for Finish production.":state.queueDay==="TOMORROW"?"No Clothes customers are scheduled in tomorrow's Finish list.":"No Clothes customers are scheduled in today's Finish list."}</div>`;return;}
    let previousDate="";
    el.queue.innerHTML=items.map(q=>{const m=queueStateMeta(q),color=safeRouteColor(q.route_color),fg=routeTextColor(color),batch=latestBatchForFlow(q.production_flow_item_id),produced=Number(q.processed_kg||0),planned=Number(q.expected_kg||0),disabled=!m.actionable,routeReady=Boolean(trackerRouteStats(trackerRouteKey(q))?.ready),scheduleDate=String(q.scheduled_for_date||"").slice(0,10),day=operationalQueueDayLabel(scheduleDate),dayHeader=scheduleDate!==previousDate?`<div class="finish-queue-day ${day.title.toLowerCase().replace(/\s+/g,"-")}"><strong>${esc(day.title)}</strong><span>${esc(day.date)}</span></div>`:"";previousDate=scheduleDate;let detail;if(m.cls==="waiting")detail=Number(q.washed_kg_total||0)>0?`${Number(q.washed_kg_total).toFixed(1)} kg washed · not available`:"Waiting for Washing";else if(m.done)detail=batch?`Batch ${esc(batch)}${produced>0?` · ${produced.toFixed(1)} kg`:""}`:`${produced.toFixed(1)} kg processed`;else detail=`Washed ${Number(q.washed_kg_total||0).toFixed(1)} kg`;return `${dayHeader}<button type="button" class="finish-queue-line ${m.cls} ${routeReady?"route-ready":""}" style="--route-color:${color};--route-fg:${fg}" data-queue-key="${esc(queueRowKey(q))}" ${disabled?"disabled":""}><span class="finish-queue-order">${esc(q.production_order??"—")}</span><span class="finish-queue-route" title="${routeReady?"Route ready to deliver":"Route"}">${esc(q.route_code||"R")}${routeReady?" ✓":""}</span><span class="finish-queue-copy"><strong>${esc(q.customer_name)}</strong><small>${detail}</small></span><span class="finish-queue-planned"><strong>${planned>0?planned.toFixed(1):"—"}</strong><small>kg plan</small></span><span class="finish-queue-status ${m.cls}"><b>${m.icon}</b>${m.label}</span></button>`;}).join("");
  }
  function applyQueueOperationalLabels(items){
    items.forEach(q=>{
      const row=el.queue.querySelector(`[data-queue-key="${CSS.escape(queueRowKey(q))}"]`);
      const badge=row?.querySelector(".finish-queue-status");
      const detail=row?.querySelector(".finish-queue-copy small");
      const schedule=scheduledDateBadge(q.scheduled_for_date);
      const statusText=badge?[...badge.childNodes].find(node=>node.nodeType===Node.TEXT_NODE):null;
      if(schedule&&statusText)statusText.nodeValue=schedule;

      if(!detail)return;
      const stateMeta=queueStateMeta(q),washedKg=Number(q.washed_kg_total||0),receivedAtIntake=Boolean(q.trolley_intake_received)||Number(q.trolley_intake_count||0)>0;
      if(stateMeta.reconciled){detail.textContent="Delivery check confirmed - excluded from metrics";return;}
      if(stateMeta.cls==="waiting")detail.textContent=washedKg>0?`${washedKg.toFixed(1)} kg washed · waiting for Finish`:receivedAtIntake?"Received at Trolley Intake":"Awaiting Trolley Intake";
      else if(stateMeta.cls==="todo")detail.textContent=washedKg>0?`${washedKg.toFixed(1)} kg washed · ready for Finish`:"Washed · ready for Finish";
    });
  }
  function renderQueueSummary(items){
    if(el.queueCount)el.queueCount.textContent=String(items.length);
    if(!el.queueWashedSummary)return;
    const washed=items.filter(q=>Number(q.washed_kg_total||0)>0),washedKg=washed.reduce((total,q)=>total+Number(q.washed_kg_total||0),0);
    el.queueWashedSummary.textContent=`${washed.length} washed · ${washedKg.toFixed(1)} kg`;
  }
  const renderQueueBase=renderQueue;
  renderQueue=function(){const items=queueRows();renderQueueBase();applyQueueOperationalLabels(items);renderQueueSummary(items);};

  function canEditEntry(entry){return entry?.edit_cutoff_at&&Date.now()<new Date(entry.edit_cutoff_at).getTime();}
  function renderRecent(){
    const code=state.lockedTable||state.activeTable||"FINISH_TABLE_1";
    if(el.recentTitle)el.recentTitle.textContent=`${tableName(code)} · ${shiftName(state.shift)}`;
    if(el.recentSubtitle)el.recentSubtitle.textContent="What this Table saved today. Route, batch, quantity and processor stay visible at a glance.";
    const queueByFlow=new Map((state.data?.queue||[]).map(q=>[q.production_flow_item_id,q]));
    const rows=(state.data?.entries||[]).filter(e=>String(e.business_date).slice(0,10)===String(state.data.business_date).slice(0,10)&&e.table_code===code&&e.shift_code===state.shift&&entryHasSavedProduction(e)).sort((a,b)=>Number(a.production_order??queueByFlow.get(a.production_flow_item_id)?.production_order??999999)-Number(b.production_order??queueByFlow.get(b.production_flow_item_id)?.production_order??999999)||new Date(a.recorded_at||0)-new Date(b.recorded_at||0));
    const totalKg=rows.reduce((n,e)=>n+Number(e.processed_kg||0),0),customers=new Set(rows.map(e=>e.customer_id||e.customer_name)).size;
    if(el.savedSummary)el.savedSummary.innerHTML=`<strong>${rows.length}</strong><span>records</span><b>${customers} customers · ${totalKg.toFixed(1)} kg</b>`;
    if(!rows.length){el.recent.innerHTML=`<div class="finish-empty finish-saved-empty">No ${esc(tableName(code))} records for this Business Date / ${esc(shiftName(state.shift))}.</div>`;return;}
    const head='<div class="finish-saved-table-head"><span>Time</span><span>Customer / Route</span><span>Batch / quantity</span><span>Processed by</span><span></span></div>';
    el.recent.innerHTML=head+rows.map(e=>{
      const q=queueByFlow.get(e.production_flow_item_id)||{},routeCode=e.route_code||q.route_code||"—",routeColor=safeRouteColor(e.route_color||q.route_color),fg=routeTextColor(routeColor),processedBy=e.processed_by||"Not recorded",scanner=e.recorded_by_scanner||e.recorded_by||"—",trolley=(e.trolley_codes||[]).length?` · 🛒 ${(e.trolley_codes||[]).join(", ")}`:e.trolley_scan_status==="PENDING"?" · Trolley pending":"";
      const groups=new Map();(e.lines||[]).forEach(l=>{const key=String(l.batch_reference||"—");if(!groups.has(key))groups.set(key,{kg:0,units:0});const g=groups.get(key),n=Number(l.quantity||0);if(l.unit_code==="KG")g.kg+=n;else if(l.unit_code==="UNIT")g.units+=n;});
      const batchRows=[...groups.entries()].map(([batch,g])=>`<span class="finish-saved-batch-row"><b>${esc(batch)}</b><em>${g.kg>0?`${g.kg.toFixed(1)} kg`:""}${g.kg>0&&g.units>0?" · ":""}${g.units>0?`${Math.round(g.units)} u`:""}</em></span>`).join("")||'<span class="finish-saved-batch-row"><b>—</b></span>';
      return `<article class="finish-saved-row" style="--route-color:${routeColor};--route-fg:${fg}"><span class="finish-saved-time">${esc(fmtTime(e.recorded_at))}</span><div class="finish-saved-customer-cell"><strong>${esc(e.customer_name)}</strong><small><b class="finish-saved-route-pill">${esc(routeCode)}</b> P${esc(e.production_order??q.production_order??"—")}</small></div><div class="finish-saved-batches">${batchRows}</div><div class="finish-saved-processor"><strong>${esc(processedBy)}</strong><small>Recorded by ${esc(scanner)} · Rev ${esc(e.revision_no)}${esc(trolley)}</small></div>${canEditEntry(e)?`<button class="secondary finish-saved-edit" type="button" data-edit="${esc(e.finish_production_entry_id)}">Edit</button>`:'<span class="finish-history-locked">Locked</span>'}</article>`;
    }).join("");
  }


  function renderExistingRecords(){
    if(!state.selected){el.existingWrap.hidden=true;el.existingRecords.innerHTML="";return;}
    const rows=flowEntries(state.selected.production_flow_item_id);if(!rows.length){el.existingWrap.hidden=true;el.existingRecords.innerHTML="";return;}
    const table=el.table.value||state.lockedTable;
    el.existingWrap.hidden=false;
    el.existingRecords.innerHTML=rows.map(e=>{
      const current=String(e.business_date).slice(0,10)===String(state.data?.business_date||"").slice(0,10)&&e.shift_code===state.shift&&e.table_code===table;
      let action='<span class="finish-history-locked">Locked</span>';
      if(current)action='<span class="finish-existing-current-label">Current Table / Date / Shift</span>';
      else if(canEditEntry(e))action=`<button type="button" class="secondary" data-edit-existing="${esc(e.finish_production_entry_id)}">Edit record</button>`;
      return `<article class="finish-existing-record ${current?"current":""}"><div><strong>Batch ${esc(entryBatchText(e))}</strong><span>${esc(tableName(e.table_code))} · ${esc(fmtDate(e.business_date))} · ${esc(shiftName(e.shift_code))}</span><small>${Number(e.processed_kg||0).toFixed(1)} kg${Number(e.processed_units||0)>0?` · ${Math.round(Number(e.processed_units))} units`:""} · Rev ${esc(e.revision_no)}${current?" · current Table/Date/Shift":""}</small></div>${action}</article>`;
    }).join("");
  }

  function plannedTrolleyText(q=state.selected){return q?.planned_trolley_summary||"No trolley requirement";}
  function latestFlowTrolleys(flowId){return flowEntries(flowId).find(e=>(e.trolley_codes||[]).length)?.trolley_codes||[];}
  function setTrolleySelection(codes,{accepted=false,clearValidation=true,pending=false}={}){state.trolleyCodes=[...new Set((codes||[]).map(normalizeTrolley).filter(Boolean))];state.trolleyMismatchAccepted=accepted;state.trolleyAutoConfirmed=false;state.trolleyPending=Boolean(pending);if(state.trolleyCodes.length)state.trolleyPending=false;if(clearValidation)state.trolleyValidation=null;syncTrolleyHidden();renderTrolleyFormSummary();}
  function scannedCountText(validation){const details=validation?.scanned||[];const counts=new Map();details.filter(x=>x.exists).forEach(x=>{const k=x.display_code||x.trolley_type_code||"?";counts.set(k,(counts.get(k)||0)+1);});return [...counts.entries()].map(([k,n])=>`${n}×${k}`).join(" + ")||(state.trolleyCodes.length?`${state.trolleyCodes.length} trolley(s)`:"None");}
  function renderTrolleyFormSummary(){
    const plan=plannedTrolleyText();el.trolleyPlanText.textContent=plan;
    if(state.trolleyPending){el.trolleySummary.innerHTML=`<div class="finish-trolley-match-card pending"><strong>⌛ No trolley yet</strong><small>Planned: ${esc(plan)} · add the trolley later using Edit.</small></div>`;el.trolleyOpen.textContent="Trolley pending";return;}
    if(!state.trolleyCodes.length){const v=state.trolleyValidation;if(v?.matches_plan&&Number(v.planned_total||0)===0){el.trolleySummary.innerHTML='<div class="finish-trolley-match-card good"><strong>✓ No trolley required</strong><small>Published plan has no trolley requirement.</small></div>';el.trolleyOpen.textContent="Trolley";return;}el.trolleySummary.innerHTML=`<div class="finish-trolley-match-card neutral"><strong>Not scanned</strong><small>Planned: ${esc(plan)}</small></div>`;el.trolleyOpen.textContent="Scan trolley";return;}
    const v=state.trolleyValidation,kind=v?.hard_block?"bad":v&&v.matches_plan?"good":v?"warn":"pending",status=v?.hard_block?"✕ Cannot use":v&&v.matches_plan?"✓ Quantity & size match":v?"⚠ Quantity / size mismatch":"Checking…";
    el.trolleySummary.innerHTML=`<div class="finish-trolley-match-card ${kind}"><strong>${esc(status)}</strong><small>Planned: ${esc(plan)} · Scanned: ${esc(v?scannedCountText(v):`${state.trolleyCodes.length} trolley(s)`)}</small></div><div class="finish-trolley-code-list">${state.trolleyCodes.map(c=>`<b>${esc(c)}</b>`).join("")}</div>`;el.trolleyOpen.textContent=v?.matches_plan&&!v?.hard_block?"Trolleys ✓":"Review trolley";
  }
  async function validateTrolleySelection(){
    if(!state.selected)return null;state.trolleyValidating=true;renderTrolleyDialog();
    try{const result=await rpc("validate_finish_trolley_selection",{p_production_flow_item_id:state.selected.production_flow_item_id,p_trolley_codes:state.trolleyCodes,p_at:null});if(result?.schema_version!=="FINISH_TROLLEY_SCAN_V1")throw new Error("Finish trolley scan backend is out of date. Migration 046 is required.");state.trolleyValidation=result;if(result.matches_plan&&!result.hard_block)state.trolleyMismatchAccepted=true;renderTrolleyFormSummary();return result;}finally{state.trolleyValidating=false;renderTrolleyDialog();}
  }
  function renderTrolleyDialog(){
    if(!state.selected)return;const q=state.selected,v=state.trolleyValidation,plan=v?.planned_requirements||q.planned_trolley_requirements||[],plannedTotal=v?.planned_total??plan.reduce((n,r)=>n+Number(r.quantity||0),0);
    el.trolleyDialogTitle.textContent=`Trolley · ${q.customer_name}`;el.trolleyDialogSubtitle.textContent=`Delivery ${fmtDate(q.delivery_date)} · physical trolley selection is separate from the scanner user.`;
    el.trolleyRequirementCard.innerHTML=`<div class="finish-trolley-required-big"><strong>${plannedTotal}</strong><span>trolley${plannedTotal===1?"":"s"}<br>planned</span></div><div class="finish-trolley-required-types">${plan.length?plan.map(r=>`<span><b>${Number(r.quantity||0)}× ${esc(r.display_code||r.trolley_type_code)}</b>${esc(r.trolley_type_name||"")}</span>`).join(""):'<span><b>No trolley requirement</b><small>Published Customer Schedule</small></span>'}</div>`;
    const detailMap=new Map((v?.scanned||[]).map(x=>[String(x.trolley_code||"").toUpperCase(),x]));
    el.trolleyScannedList.innerHTML=state.trolleyCodes.length?state.trolleyCodes.map(code=>{const d=detailMap.get(code),cls=!d?"pending":!d.exists||!d.usable?"bad":"good",type=d?.display_code||d?.trolley_type_code||"…",status=!d?"Checking…":!d.exists?"Not found":d.same_finish_flow?"Already linked to this Finish customer":d.usable?d.stored_status||"Available":d.stored_status||"Blocked";return `<article class="finish-trolley-scan-item ${cls}"><div><strong>${esc(code)}</strong><b>${esc(type)}</b><small>${esc(status)}</small></div><button type="button" data-remove-trolley="${esc(code)}" aria-label="Remove ${esc(code)}">×</button></article>`;}).join(""):'<div class="finish-empty">No trolley scanned yet.</div>';
    const match=v?.matches_plan&&!v?.hard_block;el.trolleyTally.innerHTML=`<span>Required: <strong>${esc(plannedTrolleyText())}</strong></span><span>Scanned: <strong>${esc(v?scannedCountText(v):(state.trolleyCodes.length?`${state.trolleyCodes.length} trolley(s)`:"None"))}</strong></span>${state.trolleyPending?'<b class="pending">⌛ No trolley yet</b>':state.trolleyValidating?'<b class="pending">Checking…</b>':v?`<b class="${v.hard_block?"bad":match?"good":"warn"}">${v.hard_block?"✕ Cannot use":match?"✓ Quantity & size match":"⚠ Quantity / size mismatch"}</b>`:""}`;
    const hard=v?.hard_issues||[],planIssues=v?.plan_issues||[];el.trolleyIssues.innerHTML=[hard.length?`<div class="finish-trolley-issue hard"><strong>Physical trolley problem</strong><ul>${hard.map(x=>`<li>${esc(x)}</li>`).join("")}</ul></div>`:"",planIssues.length?`<div class="finish-trolley-issue plan"><strong>Published plan mismatch</strong><ul>${planIssues.map(x=>`<li>${esc(x)}</li>`).join("")}</ul><small>Fix the scan if the plan is correct, or continue and use Report trolley plan if the published quantity/type is wrong.</small></div>`:""] .join("");
    const noScansExpected=Number(v?.planned_total??plannedTotal)>0&&state.trolleyCodes.length===0&&!state.trolleyPending;el.trolleyDialogReport.hidden=!(planIssues.length>0);if(el.trolleyNoTrolley)el.trolleyNoTrolley.hidden=Number(v?.planned_total??plannedTotal)===0;el.trolleyDialogConfirm.disabled=Boolean(state.trolleyPending||state.trolleyValidating||v?.hard_block||noScansExpected);el.trolleyDialogConfirm.textContent=state.trolleyPending?"No trolley yet selected":noScansExpected?"Scan trolley":v&&!v.matches_plan&&!v.hard_block?"Use with mismatch":"Use scanned trolleys";
  }
  async function openTrolleyDialog(){if(!state.selected)return;state.trolleyDialogBackup=state.trolleyCodes.slice();state.trolleyPendingBackup=state.trolleyPending;renderTrolleyDialog();el.trolleyDialog.showModal();try{if(!state.trolleyPending)await validateTrolleySelection();else renderTrolleyDialog();}catch(err){console.error(err);setMessage(err.message||"Trolley validation could not be loaded.");}setTimeout(()=>el.trolleyScanInput.focus(),50);}
  function closeTrolleyDialog({restore=false}={}){if(restore)setTrolleySelection(state.trolleyDialogBackup,{accepted:state.trolleyMismatchAccepted,pending:state.trolleyPendingBackup});if(el.trolleyDialog.open)el.trolleyDialog.close();el.trolleyScanInput.value="";}
  async function addTrolleyFromInput(){const code=normalizeTrolley(el.trolleyScanInput.value);el.trolleyScanInput.value="";if(!code)return;if(!state.trolleyCodes.includes(code))state.trolleyCodes.push(code);state.trolleyMismatchAccepted=false;state.trolleyAutoConfirmed=false;state.trolleyPending=false;syncTrolleyHidden();renderTrolleyFormSummary();renderTrolleyDialog();try{const v=await validateTrolleySelection();if(v?.matches_plan&&!v?.hard_block&&state.trolleyCodes.length){state.trolleyMismatchAccepted=true;state.trolleyAutoConfirmed=true;renderTrolleyDialog();renderTrolleyFormSummary();setTimeout(()=>{if(el.trolleyDialog.open&&!el.trolleyScanInput.value.trim())closeTrolleyDialog();},450);return;}}catch(err){console.error(err);setMessage(err.message||"Trolley could not be checked.");}el.trolleyScanInput.focus();}
  async function removeTrolley(code){state.trolleyCodes=state.trolleyCodes.filter(x=>x!==code);state.trolleyMismatchAccepted=false;state.trolleyAutoConfirmed=false;syncTrolleyHidden();state.trolleyValidation=null;renderTrolleyFormSummary();renderTrolleyDialog();try{await validateTrolleySelection();}catch(err){console.error(err);setMessage(err.message||"Trolley could not be checked.");}}
  async function confirmTrolleySelection(){let v=state.trolleyValidation;try{if(!v)v=await validateTrolleySelection();}catch(err){setMessage(err.message||"Trolley validation failed.");return;}if(v?.hard_block){renderTrolleyDialog();return;}state.trolleyMismatchAccepted=true;state.trolleyAutoConfirmed=false;state.trolleyPending=false;syncTrolleyHidden();renderTrolleyFormSummary();closeTrolleyDialog();}
  async function ensureTrolleyReadyForSave(){if(!state.selected)return true;if(state.trolleyPending)return true;const v=await validateTrolleySelection();if(v?.hard_block){if(!el.trolleyDialog.open){state.trolleyDialogBackup=state.trolleyCodes.slice();el.trolleyDialog.showModal();renderTrolleyDialog();}throw new Error("One or more scanned trolleys cannot be used. Review the trolley scan.");}if(v&&!v.matches_plan&&!state.trolleyMismatchAccepted){if(!el.trolleyDialog.open){state.trolleyDialogBackup=state.trolleyCodes.slice();el.trolleyDialog.showModal();renderTrolleyDialog();}throw new Error("Trolley quantity/type does not match the published plan. Review the scan, use with mismatch, or report the trolley plan.");}return true;}

  function staffTableMetric(code){return state.tableMetrics.get(code)||null;}
  function rowTableCode(row){return row.attendance_status==="ABSENT"?row.planned_table_code:(row.effective_table_code||row.planned_table_code||"");}
  function staffById(staffId){return (state.staffData?.staff||[]).find(row=>row.staff_id===staffId)||null;}
  function restoreRosterStartWhenPlaceholder(){const row=staffById(el.staffSelect.value);if(!row||el.staffStart.value!=="00:00")return;const planned=timeText(row.planned_start_time)||timeText(row.effective_start_time);if(planned&&planned!=="00:00")el.staffStart.value=planned;}
  function segmentTimeText(row){const segments=row.table_segments||[];if(!segments.length)return (timeText(row.effective_start_time)&&timeText(row.effective_end_time))?`${timeText(row.effective_start_time)} - ${timeText(row.effective_end_time)}`:row.actual_in_finish?"Open shift":"Not confirmed";return segments.map(segment=>`${tableName(segment.table_code)} ${timeText(segment.started_at)}-${timeText(segment.ended_at)||"now"}`).join(" · ");}
  function renderStaff(){
    const fixedTable=state.lockedTable||"";
    const rows=(state.staffData?.staff||[]).filter(row=>!fixedTable||rowTableCode(row)===fixedTable).slice().sort((a,b)=>String(rowTableCode(a)).localeCompare(String(rowTableCode(b)))||String(a.display_name||"").localeCompare(String(b.display_name||"")));
    el.staffCount.textContent=`${rows.length} staff`;
    el.staffScheduleNote.textContent=fixedTable?`${tableName(fixedTable)} only. Mark an absence, confirm an arrival, or transfer a confirmed staff member with the exact move time.`:"Roster names are pre-filled. Confirm the actual table, attendance, or a timed table transfer when needed.";
    el.staffAdd.textContent=fixedTable?`Add staff manually to ${tableName(fixedTable)}`:"Add staff manually";
    el.staffTableSummary.hidden=true;
    if(!rows.length){el.staffList.innerHTML=`<div class="finish-empty">No staff is planned or confirmed for ${esc(fixedTable?tableName(fixedTable):"this Finish shift")}.</div>`;return;}
    const profile=state.staffData?.work_profile?.schedule_label||"Roster schedule";
    el.staffList.innerHTML=`<div class="finish-staff-simple-table"><table><thead><tr><th>Staff</th><th>Planned</th><th>Actual table</th><th>Table time</th><th>Worked</th><th>Status</th><th></th></tr></thead><tbody>${rows.map(row=>{
      const absent=row.attendance_status==="ABSENT";
      const elsewhere=row.staff_state==="ACTUAL_ELSEWHERE";
      const plannedTable=tableName(row.planned_table_code)||"Not planned";
      const plannedTime=(timeText(row.planned_start_time)&&timeText(row.planned_end_time))?`${timeText(row.planned_start_time)} - ${timeText(row.planned_end_time)}`:profile;
      const actualTable=absent?"Not working":elsewhere?(row.actual_area_name||row.actual_area_code||"Other area"):tableName(row.effective_table_code||row.planned_table_code)||"Choose table";
      const hasActualStart=Boolean(row.actual_start_at),hasActualTime=row.actual_in_finish&&hasActualStart;
      const plannedEnd=timeMinutes(row.planned_end_time)||timeMinutes(row.effective_end_time);
      let overtimeMinutes=(timeMinutes(row.actual_end_at||row.effective_end_time)??0)-(plannedEnd??0);
      if(overtimeMinutes < -720)overtimeMinutes+=1440;
      overtimeMinutes=Math.max(0,overtimeMinutes);
      const stateText=absent?"Absent":elsewhere?"Elsewhere":overtimeMinutes>0?`Overtime +${Math.floor(overtimeMinutes/60)}h ${String(overtimeMinutes%60).padStart(2,"0")}m`:hasActualTime?"Confirmed":"Planned";
      const stateClass=absent?"absent":elsewhere?"elsewhere":hasActualTime?"confirmed":"planned";
      let actions="";
      if(absent) actions=`<button class="secondary finish-staff-edit" type="button" data-staff-present="${esc(row.staff_id)}">Confirm arrived</button>`;
      else if(!elsewhere) actions=`<button class="secondary finish-staff-edit" type="button" data-staff-edit="${esc(row.staff_id)}">${hasActualTime?"Edit":"Confirm"}</button><button class="secondary finish-staff-edit" type="button" data-staff-move="${esc(row.staff_id)}" ${hasActualTime&&!row.actual_end_at?"":"disabled"}>Move</button><button class="secondary finish-staff-edit" type="button" data-staff-leave="${esc(row.staff_id)}" ${hasActualTime&&!row.actual_end_at?"":"disabled"}>Leave early</button><button class="secondary danger-outline finish-staff-edit" type="button" data-staff-absent="${esc(row.staff_id)}">Absent</button>`;
      const worked=absent?"0h 00m":hasActualTime?workedTimeText(row):plannedWorkedTimeText(row);
      return `<tr><td><strong>${esc(row.display_name)}</strong></td><td><b>${esc(plannedTable)}</b><small>${esc(plannedTime)}</small></td><td><b>${esc(actualTable)}</b>${absent&&row.absence_reason?`<small>${esc(row.absence_reason.replaceAll("_"," "))}</small>`:""}</td><td><small>${esc(absent?"No shift recorded":segmentTimeText(row))}</small></td><td><b>${esc(worked)}</b><small>${hasActualTime?"Actual":"Planned"} · Break ${Number(row.break_minutes||0)} min</small></td><td><span class="finish-staff-simple-state ${stateClass}">${esc(stateText)}</span></td><td><div class="finish-staff-actions">${actions}</div></td></tr>`;
    }).join("")}</tbody></table></div>`;
  }

  function selectCustomer(q,{prefillTrolleys=true,isNewRecord=false}={}){
    const hasPrevious=flowEntries(q.production_flow_item_id).length>0;state.selected=q;el.flowId.value=q.production_flow_item_id;el.form.dataset.mode=isNewRecord||!hasPrevious?"new":"continue";el.formTitle.textContent=q.customer_name;el.formSubtitle.textContent=isNewRecord||!hasPrevious?"Record the first Finish contribution for this washed customer.":"Continue production. A new batch is required for a new Table/Business Date/Shift contribution.";el.cutoff.textContent=`Delivery ${fmtDate(q.delivery_date)} · edits until 12:00`;el.customerSummary.hidden=false;
    el.customerSummary.innerHTML=`<div><strong>${esc(q.customer_name)}</strong><span>${esc(q.customer_code||"")}</span><small>${esc(q.finish_instructions||"No Finish instruction")}</small></div><div><b>${Number(q.processed_kg||0).toFixed(1)} kg processed</b><small>🛒 ${esc(plannedTrolleyText(q))}</small></div>`;
    if(prefillTrolleys&&q.finish_state==="CONTINUE"){const previous=latestFlowTrolleys(q.production_flow_item_id);if(previous.length)setTrolleySelection(previous,{accepted:false});}
    el.trolleyPlanText.textContent=plannedTrolleyText(q);renderExistingRecords();renderTrolleyFormSummary();fillProcessedByOptions({preserve:true});
  }

  function ensureTrolleyReportDialog(){let d=document.getElementById("finishTrolleyReportDialog");if(d)return d;document.body.insertAdjacentHTML("beforeend",`<dialog id="finishTrolleyReportDialog" class="finish-report-dialog"><div class="finish-report-card"><header><div><strong>Report incorrect trolley plan</strong><small>This sends evidence to Customer Schedule editors and never changes the published schedule.</small></div><button type="button" data-report-close>×</button></header><div id="finishReportSummary"></div><div id="finishReportTypes" class="finish-report-types"></div><label>Why is the published trolley plan wrong?<textarea id="finishReportReason" rows="3" maxlength="1000" placeholder="Explain the expected quantity/type."></textarea></label><p id="finishReportStatus" class="finish-report-status"></p><footer><button type="button" class="secondary" data-report-cancel>Cancel</button><button type="button" class="primary" data-report-save>Send report</button></footer></div></dialog>`);d=document.getElementById("finishTrolleyReportDialog");d.querySelector("[data-report-close]").addEventListener("click",()=>{if(!state.reportSaving)d.close();});d.querySelector("[data-report-cancel]").addEventListener("click",()=>{if(!state.reportSaving)d.close();});d.querySelector("[data-report-save]").addEventListener("click",saveTrolleyReport);return d;}
  async function openTrolleyReport(){const q=state.selected;if(!q)return;const d=ensureTrolleyReportDialog(),status=document.getElementById("finishReportStatus");status.textContent="";status.className="finish-report-status";try{if(!state.trolleyReference)state.trolleyReference=await rpc("get_trolley_reference_data");const types=(state.trolleyReference?.trolley_types||[]).filter(t=>t.allowed_in_customer_schedule),planned=new Map((q.planned_trolley_requirements||[]).map(r=>[String(r.trolley_type_id),Number(r.quantity||0)]));document.getElementById("finishReportSummary").innerHTML=`<p><strong>${esc(q.customer_name)}</strong> · Published plan: ${esc(plannedTrolleyText(q))}</p><p>Observed scan: ${esc(state.trolleyValidation?scannedCountText(state.trolleyValidation):(state.trolleyCodes.join(", ")||"No trolley scanned"))}</p>`;document.getElementById("finishReportTypes").innerHTML=types.map(t=>`<label><span><b>${esc(t.display_code||t.trolley_type_code)}</b>${esc(t.trolley_type_name||t.trolley_type_code)}</span><input type="number" min="0" max="100" step="1" data-report-type="${esc(t.trolley_type_id)}" value="${planned.get(String(t.trolley_type_id))||0}"></label>`).join("");document.getElementById("finishReportReason").value="";d.showModal();}catch(err){console.error(err);setMessage(err.message||"Trolley plan report could not be opened.");}}
  async function saveTrolleyReport(){const q=state.selected,d=document.getElementById("finishTrolleyReportDialog"),status=document.getElementById("finishReportStatus"),save=d.querySelector("[data-report-save]");if(!q||state.reportSaving)return;const reason=document.getElementById("finishReportReason").value.trim();if(!reason){status.textContent="Explain what is wrong with the published trolley plan.";status.className="finish-report-status error";return;}const requirements=[...d.querySelectorAll("[data-report-type]")].map(i=>({trolley_type_id:i.dataset.reportType,quantity:Number(i.value||0)}));if(requirements.some(r=>!Number.isInteger(r.quantity)||r.quantity<0||r.quantity>100)){status.textContent="Quantities must be whole numbers from 0 to 100.";status.className="finish-report-status error";return;}state.reportSaving=true;save.disabled=true;try{const result=await rpc("report_customer_trolley_requirement_issue",{p_production_flow_item_id:q.production_flow_item_id,p_source_area_code:"FINISH",p_reported_requirements:requirements,p_observed_trolley_codes:trolleyCodes(),p_reason:reason});status.textContent=result?.message||"Trolley plan report sent.";status.className="finish-report-status success";setMessage(status.textContent,"success");setTimeout(()=>{if(d.open)d.close();},800);}catch(err){console.error(err);status.textContent=err.message||"Report could not be saved.";status.className="finish-report-status error";}finally{state.reportSaving=false;save.disabled=false;}}

  function resetForm(){state.selected=null;state.trolleyCodes=[];state.trolleyValidation=null;state.trolleyMismatchAccepted=false;state.trolleyAutoConfirmed=false;state.trolleyPending=false;syncTrolleyHidden();setDialogMessage("");el.flowId.value="";el.editId.value="";el.form.dataset.mode="new";el.formTitle.textContent="Select a customer";el.formSubtitle.textContent="Choose a washed Clothes customer from the list.";el.cutoff.textContent="Delivery cutoff —";el.customerSummary.hidden=true;el.existingWrap.hidden=true;el.existingRecords.innerHTML="";el.editBanner.hidden=true;el.correctionWrap.hidden=true;el.correctionReason.value="";el.batchLines.innerHTML="";addLine();el.notes.value="";el.save.textContent="Save Finish production";el.table.disabled=Boolean(state.lockedTable);el.table.value=state.lockedTable||state.activeTable||"FINISH_TABLE_1";el.shiftDisplay.value=shiftName(state.shift);el.processedBy.innerHTML='<option value="">Select staff…</option>';el.processedByHint.textContent="Only staff logged in on this Table / Shift are available. The scanner user is recorded separately.";el.trolleyPlanText.textContent="No trolley requirement";renderTrolleyFormSummary();}
  function closeProductionDialog(){if(el.productionDialog.open)el.productionDialog.close();resetForm();setTimeout(presentDeliveryReconciliation,0);}
  async function openCustomer(q){if(activeDeliveryReconciliation()){presentDeliveryReconciliation();return;}const table=state.lockedTable||state.activeTable||"FINISH_TABLE_1",current=currentContextEntry(q.production_flow_item_id,table);if(current&&entryHasSavedProduction(current)){editEntry(current.finish_production_entry_id);return;}resetForm();el.table.value=table;selectCustomer(q,{isNewRecord:!flowEntries(q.production_flow_item_id).length});el.productionDialog.showModal();if(state.trolleyCodes.length)validateTrolleySelection().catch(()=>{});setTimeout(()=>el.batchLines.querySelector("[data-batch]")?.focus(),50);}
  function editEntry(id){const e=(state.data?.entries||[]).find(x=>x.finish_production_entry_id===id);if(!e)return;if(!entryHasSavedProduction(e)){const q=(state.data?.queue||[]).find(x=>x.production_flow_item_id===e.production_flow_item_id);if(q){openCustomer(q);return;}return;}if(!canEditEntry(e)){setMessage("This Finish record is locked after the Delivery Date 12:00 cutoff.");return;}const q=(state.data?.queue||[]).find(x=>x.production_flow_item_id===e.production_flow_item_id);resetForm();if(q)selectCustomer(q,{prefillTrolleys:false});else{state.selected={production_flow_item_id:e.production_flow_item_id,customer_name:e.customer_name,delivery_date:e.delivery_date,planned_trolley_requirements:[]};el.flowId.value=e.production_flow_item_id;el.formTitle.textContent=e.customer_name;el.cutoff.textContent=`Delivery ${fmtDate(e.delivery_date)} · edits until 12:00`;}el.editId.value=e.finish_production_entry_id;el.form.dataset.mode="edit";el.table.value=e.table_code;el.table.disabled=true;el.shiftDisplay.value=shiftName(e.shift_code);el.editBanner.hidden=true;el.correctionWrap.hidden=true;fillProcessedByOptions({entry:e,preserve:false});el.batchLines.innerHTML="";(e.lines||[]).forEach(addLine);if(!(e.lines||[]).length)addLine();setTrolleySelection(e.trolley_codes||[],{accepted:true,pending:e.trolley_scan_status==="PENDING"});el.notes.value=e.notes||"";el.save.textContent="Save changes";renderExistingRecords();el.productionDialog.showModal();if(state.trolleyCodes.length)validateTrolleySelection().catch(()=>{});}

  function applyTableLock(){const raw=params.get("table"),urlTable=raw?({"1":"FINISH_TABLE_1","2":"FINISH_TABLE_2","3":"FINISH_TABLE_3",FINISH_TABLE_1:"FINISH_TABLE_1",FINISH_TABLE_2:"FINISH_TABLE_2",FINISH_TABLE_3:"FINISH_TABLE_3"}[raw.toUpperCase()]||""):"",terminalTable=String(state.terminalContext?.station_code||"").toUpperCase();const normalized=terminalTable.startsWith("FINISH_TABLE_")?terminalTable:urlTable;state.lockedTable=normalized;state.activeTable=normalized||state.activeTable||"FINISH_TABLE_1";if(normalized){el.table.value=normalized;el.table.disabled=true;el.tableHint.textContent=terminalTable?`This production terminal is registered to ${tableName(normalized)}. The Table cannot be changed here.`:`This workstation is locked to ${tableName(normalized)}. Remove ?table= from the URL for central multi-table scanning.`;el.scannerMode.textContent=`${tableName(normalized)} workstation`;}else el.scannerMode.textContent="Multi-table scanner";}
  function applyView(){const staff=state.view==="staff";el.productionView.hidden=staff;el.staffView.hidden=!staff;el.viewTabs?.querySelectorAll("[data-finish-view]").forEach(button=>{const active=button.dataset.finishView===state.view;button.classList.toggle("active",active);button.setAttribute("aria-current",active?"page":"false");});if(staff){el.viewEyebrow.textContent="Finish staffing workspace";el.viewTitle.textContent="Finish Staff";el.viewSubtitle.textContent="Published Roster Planned vs Finish Actual Table/time, using the same operational principle as Sorting.";document.title="Finish Staff | ElisCaretex";}else{el.viewEyebrow.textContent="Finish operational workspace";el.viewTitle.textContent="Finish Production";el.viewSubtitle.textContent="";document.title="Finish Production | ElisCaretex";}}

  async function load(){setMessage(state.view==="staff"?"Loading Finish Staff…":"Loading Finish Production…");try{const [data,staffData,trackerData,candidates]=await Promise.all([rpc("get_finish_production_context_v4",{p_shift_code:state.shift,p_at:null}),rpc("get_finish_staff_context_v4",{p_shift_code:state.shift,p_at:null}),rpc("get_production_tracker_v4",{p_business_date:null}).catch(err=>{console.warn("Finish route readiness unavailable",err);return null;}),rpc("get_finish_staff_candidates_v1",{})]);if(data?.schema_version!=="FINISH_PRODUCTION_V4")throw new Error("Finish production backend is out of date. Refresh after the latest update.");if(staffData?.schema_version!=="FINISH_STAFF_V4")throw new Error("Finish Staff backend is out of date. Refresh after the latest update.");if(candidates?.schema_version!=="FINISH_STAFF_CANDIDATES_V1")throw new Error("Finish staff lookup is out of date. Refresh after the latest update.");state.data=data;state.staffData=staffData;state.trackerData=trackerData?.schema_version==="PRODUCTION_TRACKER_V4"?trackerData:null;state.staffCandidates=candidates.staff||[];el.businessDate.textContent=fmtDate(data.business_date);el.shiftDisplay.value=shiftName(state.shift);el.target.textContent=`${Number(staffData.target_kg_per_staff_hour||23.5).toFixed(1)} kg/staff-hour`;renderShift();renderMetrics();renderRewashCard();renderQueue();renderRecent();renderStaff();setMessage("");}catch(e){console.error(e);setMessage(e.message||"Finish could not be loaded.");}}

  async function refreshFinishOperationalData(){
    const [operationalQueue,reconciliation]=await Promise.all([
      rpc("get_finish_operational_queue_context",{p_shift_code:state.shift,p_at:null}),
      rpc("get_finish_delivery_reconciliation_context",{p_at:null})
    ]);
    if(operationalQueue?.schema_version!=="FINISH_OPERATIONAL_QUEUE_V3")throw new Error("Finish operational queue is out of date. Refresh after the latest update.");
    if(reconciliation?.schema_version!=="FINISH_DELIVERY_RECONCILIATION_V1")throw new Error("Finish delivery check is out of date. Refresh after the latest update.");
    state.operationalQueue=operationalQueue;
    const currentDate=String(operationalQueue.business_date||state.data?.business_date||"").slice(0,10),extraDates=[operationalQueue.advanced_date].map(value=>String(value||"").slice(0,10)).filter(date=>date&&date!==currentDate),extraTrackers=await Promise.all(extraDates.map(date=>rpc("get_production_tracker_v4",{p_business_date:date}).catch(err=>{console.warn("Finish advanced schedule unavailable",err);return null;})));
    state.operationalTrackers=new Map();
    if(state.trackerData)state.operationalTrackers.set(currentDate,state.trackerData);
    extraTrackers.forEach((tracker,index)=>{if(tracker?.schema_version==="PRODUCTION_TRACKER_V4")state.operationalTrackers.set(extraDates[index],tracker);});
    state.deliveryReconciliation=reconciliation;
    renderQueue();
    presentDeliveryReconciliation();
  }
  const loadBase=load;
  load=async function(){
    await loadBase();
    if(state.trackerData)state.operationalTrackers=new Map([[String(state.data?.business_date||"").slice(0,10),state.trackerData]]);
    try{await refreshFinishOperationalData();}
    catch(err){console.error(err);setMessage(err.message||"Finish operational work could not be loaded.","error");}
  };
  function setDeliveryReconciliationMessage(text="",type=""){el.deliveryReconciliationMessage.textContent=text;el.deliveryReconciliationMessage.className=`finish-message ${type}`.trim();}
  function activeDeliveryReconciliation(){return state.deliveryReconciliation?.items?.[0]||null;}
  function renderDeliveryReconciliation(){
    const item=activeDeliveryReconciliation();
    if(!item)return;
    const overdueDays=Number(item.overdue_days||0),pendingCount=Number(state.deliveryReconciliation?.pending_count||state.deliveryReconciliation?.items?.length||1);
    if(el.deliveryReconciliationTitle)el.deliveryReconciliationTitle.textContent=overdueDays>0?"Overdue Finish confirmation required":"Finish confirmation required";
    if(el.deliveryReconciliationSubtitle)el.deliveryReconciliationSubtitle.textContent=`A washed customer has no Finish record after its delivery deadline.${pendingCount>1?` ${pendingCount} confirmations are waiting.`:""}`;
    const washedKg=Number(item.washed_kg_total||0),scheduled=scheduledDateBadge(item.scheduled_for_date)||fmtDate(item.scheduled_for_date),delivery=fmtDate(item.delivery_date);
    el.deliveryReconciliationSummary.innerHTML=`<strong>${esc(item.customer_name||"Customer")}</strong><span>${esc(item.route_code||"Route")} · scheduled ${esc(scheduled)} · delivery ${esc(delivery)}</span><b>${washedKg.toFixed(1)} kg washed</b>`;
    el.deliveryReconciliationProcessedOn.value=String(item.delivery_date||state.deliveryReconciliation?.local_date||fmtDateKey()).slice(0,10);
    el.deliveryReconciliationKg.value="";
    el.deliveryReconciliationUnit.value="KG";
    el.deliveryReconciliationBatch.value="";
    el.deliveryReconciliationNotes.value="";
    setDeliveryReconciliationMessage("");
  }
  function presentDeliveryReconciliation(){
    const item=activeDeliveryReconciliation();
    if(!item||el.deliveryReconciliationDialog.open||el.productionDialog.open||el.trolleyDialog.open||el.staffDialog.open)return;
    renderDeliveryReconciliation();
    el.deliveryReconciliationDialog.showModal();
  }
  async function saveDeliveryReconciliation(outcome){
    const item=activeDeliveryReconciliation();
    if(!item||state.deliveryReconciliationSaving)return;
    const processed=outcome==="PROCESSED_CONFIRMED",processedOn=el.deliveryReconciliationProcessedOn.value,processedQuantity=Number(String(el.deliveryReconciliationKg.value||"").trim().replace(",",".")),processedUnit=el.deliveryReconciliationUnit.value;
    if(processed&&!processedOn){setDeliveryReconciliationMessage("Enter the approximate processing date.","error");el.deliveryReconciliationProcessedOn.focus();return;}
    if(processed&&(!Number.isFinite(processedQuantity)||processedQuantity<=0)){setDeliveryReconciliationMessage("Enter an approximate quantity greater than zero.","error");el.deliveryReconciliationKg.focus();return;}
    state.deliveryReconciliationSaving=true;
    const buttons=[...el.deliveryReconciliationForm.querySelectorAll("button")];buttons.forEach(button=>button.disabled=true);
    setDeliveryReconciliationMessage("");
    try{
      const result=await rpc("resolve_finish_delivery_reconciliation_v2",{
        p_production_flow_item_id:item.production_flow_item_id,
        p_outcome_code:outcome,
        p_approximate_processed_on:processed?processedOn:null,
        p_approximate_processed_quantity:processed?processedQuantity:null,
        p_approximate_processed_unit:processed?processedUnit:null,
        p_batch_reference:processed?el.deliveryReconciliationBatch.value.trim()||null:null,
        p_notes:el.deliveryReconciliationNotes.value.trim()||null
      });
      if(el.deliveryReconciliationDialog.open)el.deliveryReconciliationDialog.close();
      await load();
      setMessage(result?.message||"Delivery check saved.","success");
    }catch(err){console.error(err);setDeliveryReconciliationMessage(err.message||"Delivery check could not be saved.","error");}
    finally{state.deliveryReconciliationSaving=false;buttons.forEach(button=>button.disabled=false);}
  }
  function staffCandidateByName(name){const key=String(name||"").trim().toLocaleLowerCase();return state.staffCandidates.find(row=>String(row.display_name||"").trim().toLocaleLowerCase()===key)||null;}
  function renderStaffCandidates(){el.staffCandidates.innerHTML=state.staffCandidates.map(row=>`<option value="${esc(row.display_name)}"></option>`).join("");}
  function localTimeNow(){return fmtTime(new Date());}
  function openStaffCheckIn(){renderStaffCandidates();el.staffForm.reset();el.staffSelect.value="";el.staffName.readOnly=false;el.staffDialogTitle.textContent="Confirm Finish staff";el.staffDialogSubtitle.textContent=state.lockedTable?`Type the staff name to confirm work on ${tableName(state.lockedTable)}.`:"Type the staff name to confirm the actual Finish Table. Roster names are suggested, but another active production staff member can be confirmed when the plan changed.";el.staffTable.value=state.lockedTable||state.activeTable||"";el.staffTable.disabled=Boolean(state.lockedTable);el.staffStart.value=localTimeNow();el.staffBreak.value=Number(state.staffData?.work_profile?.break_minutes||0);resetStaffDepartureControl();setStaffDialogMessage("");el.staffDialog.showModal();setTimeout(()=>el.staffName.focus(),50);}
  function openStaffEditor(staffId){const row=staffById(staffId);if(!row)return;if(row.staff_state==="ACTUAL_ELSEWHERE"){setMessage(`${row.display_name} has Actual work in ${row.actual_area_name||row.actual_area_code||"another area"}. Finish will not overwrite that Actual record.`);return;}renderStaffCandidates();el.staffSelect.value=row.staff_id;el.staffName.value=row.display_name;el.staffName.readOnly=true;el.staffDialogTitle.textContent=row.display_name;const hasTransfer=(row.table_segments||[]).length>1,plannedStart=timeText(row.planned_start_time)||timeText(row.effective_start_time),plannedEnd=timeText(row.planned_end_time)||timeText(row.effective_end_time),actualEnd=timeText(row.actual_end_at);el.staffDialogSubtitle.textContent=hasTransfer?"This staff member has timed Table transfers. You can still correct the overall start, leaving time and break here; the existing Table moves are preserved.":(state.lockedTable?`Actual work on ${tableName(state.lockedTable)}. The planned times remain visible for reference.`:`Planned ${tableName(row.planned_table_code)} · ${plannedStart||state.staffData?.work_profile?.schedule_label||"work profile"}. The planned times remain visible for reference.`);el.staffTable.value=state.lockedTable||row.effective_table_code||row.planned_table_code||"";el.staffTable.disabled=Boolean(state.lockedTable)||hasTransfer;el.staffStart.value=timeText(row.actual_start_at)||timeText(row.effective_start_time)||plannedStart;el.staffEnd.value=actualEnd||plannedEnd;el.staffEnd.dataset.plannedEnd=plannedEnd;el.staffEnd.dataset.savedActualEnd=actualEnd;el.staffCloseShift.checked=Boolean(actualEnd);updateStaffDepartureHint();el.staffBreak.value=Number(row.break_minutes??state.staffData?.work_profile?.break_minutes??0);el.staffStart.disabled=false;el.staffEnd.disabled=false;el.staffReason.value="";setStaffDialogMessage("");el.staffDialog.showModal();}
  function closeStaffDialog(){if(el.staffDialog.open)el.staffDialog.close();el.staffForm.reset();el.staffSelect.value="";el.staffName.readOnly=false;el.staffTable.disabled=false;el.staffStart.disabled=false;el.staffEnd.disabled=false;resetStaffDepartureControl();setStaffDialogMessage("");}
  function setAttendanceMessage(text="",type=""){el.attendanceMessage.textContent=text;el.attendanceMessage.className=`finish-message ${type}`.trim();}
  function setMoveMessage(text="",type=""){el.moveMessage.textContent=text;el.moveMessage.className=`finish-message ${type}`.trim();}
  function closeAttendanceDialog(){if(el.attendanceDialog.open)el.attendanceDialog.close();el.attendanceForm.reset();setAttendanceMessage("");}
  function closeMoveDialog(){if(el.moveDialog.open)el.moveDialog.close();el.moveForm.reset();setMoveMessage("");}
  function setDepartureMessage(text="",type=""){el.departureMessage.textContent=text;el.departureMessage.className=`finish-message ${type}`.trim();}
  function closeDepartureDialog(){if(el.departureDialog.open)el.departureDialog.close();el.departureForm.reset();setDepartureMessage("");}
  function openAbsentDialog(staffId){const row=staffById(staffId);if(!row)return;el.attendanceForm.reset();el.attendanceStaffId.value=staffId;el.attendanceDialogTitle.textContent=`Mark ${row.display_name} absent`;el.attendanceDialogSubtitle.textContent=`This records the actual absence for ${tableName(rowTableCode(row))}. It can be reversed when the person arrives.`;setAttendanceMessage("");el.attendanceDialog.showModal();}
  async function confirmArrival(staffId){const row=staffById(staffId);if(!row)return;try{await rpc("set_finish_staff_attendance_v1",{p_shift_code:state.shift,p_staff_id:staffId,p_attendance_status:"PRESENT",p_absence_reason:null,p_notes:"Arrived after absence was recorded"});await load();openStaffEditor(staffId);setMessage(`${row.display_name} is marked present. Confirm the actual start time.`,`success`);}catch(err){console.error(err);setMessage(err.message||"Attendance could not be updated.");}}
  function openMoveDialog(staffId){const row=staffById(staffId);if(!row||!row.actual_in_finish)return;const source=state.lockedTable||row.effective_table_code||row.planned_table_code;if(!source){setMessage("Confirm the current Table before moving this staff member.");return;}el.moveForm.reset();el.moveStaffId.value=staffId;el.moveFromTable.value=source;el.moveDialogTitle.textContent=`Move ${row.display_name}`;el.moveDialogSubtitle.textContent=`From ${tableName(source)}. Choose the exact time the staff member moved so both Table metrics remain correct.${row.is_sorting_cover?" This staff member has an active Sorting cover capability.":" Sorting is available only to staff with an active Sorting cover capability."}`;[...el.moveToTable.options].forEach(option=>{option.disabled=option.value===source||(option.value==="SORTING"&&!row.is_sorting_cover);});el.moveTime.value=localTimeNow();setMoveMessage("");el.moveDialog.showModal();}
  function openDepartureDialog(staffId){const row=staffById(staffId);if(!row||!row.actual_in_finish||row.actual_end_at)return;const table=state.lockedTable||row.effective_table_code||row.planned_table_code;if(!table){setMessage("Confirm the current Table before recording a departure.");return;}el.departureForm.reset();el.departureStaffId.value=staffId;el.departureTable.value=table;el.departureTime.value=localTimeNow();el.departureDialogTitle.textContent=`Record ${row.display_name}'s departure`;el.departureDialogSubtitle.textContent=`This closes the active ${tableName(table)} time. Earlier Table transfers stay unchanged.`;setDepartureMessage("");el.departureDialog.showModal();}
  async function authenticate(){if(window.ELIS_SUPABASE_ERROR||!client)throw new Error(window.ELIS_SUPABASE_ERROR||"Supabase could not be initialized.");const {data:{session},error}=await client.auth.getSession();if(error)throw error;if(!session?.user){location.href="../index.html";return false;}const {data:profile,error:pe}=await client.rpc("get_current_account_access");if(pe)throw pe;state.profile=profile;el.signedIn.textContent=profile?.display_name||session.user.email||"Signed in";return true;}

  el.queue.addEventListener("click",e=>{const b=e.target.closest("[data-queue-key]");if(!b)return;const q=queueRows().find(row=>queueRowKey(row)===b.dataset.queueKey);if(q?.production_flow_item_id)openCustomer(q);});
  el.recent.addEventListener("click",e=>{const b=e.target.closest("[data-edit]");if(b)editEntry(b.dataset.edit);});
  el.existingRecords.addEventListener("click",e=>{const b=e.target.closest("[data-edit-existing]");if(b)editEntry(b.dataset.editExisting);});
  el.staffList.addEventListener("click",e=>{const edit=e.target.closest("[data-staff-edit]"),absent=e.target.closest("[data-staff-absent]"),present=e.target.closest("[data-staff-present]"),move=e.target.closest("[data-staff-move]"),leave=e.target.closest("[data-staff-leave]");if(edit)openStaffEditor(edit.dataset.staffEdit);else if(absent)openAbsentDialog(absent.dataset.staffAbsent);else if(present)confirmArrival(present.dataset.staffPresent);else if(move&&!move.disabled)openMoveDialog(move.dataset.staffMove);else if(leave&&!leave.disabled)openDepartureDialog(leave.dataset.staffLeave);});
  el.staffAdd.addEventListener("click",openStaffCheckIn);
  el.rewashOpen?.addEventListener("click",openRewashDialog);
  el.rewashDialogClose?.addEventListener("click",closeRewashDialog);
  el.rewashCancel?.addEventListener("click",closeRewashDialog);
  el.rewashAddLine?.addEventListener("click",()=>addRewashLine());
  el.rewashForm?.addEventListener("submit",async event=>{event.preventDefault();const lines=rewashLinesFromForm(),invalidCustomer=lines.find(line=>!line.customer_id),invalidKg=lines.find(line=>!(Number(line.quantity_kg)>0));if(!el.rewashProcessedBy.value){setRewashMessage("Select the staff member who processed this ReWash.","error");el.rewashProcessedBy.focus();return;}if(invalidCustomer){setRewashMessage("Choose a valid Clothes or Others customer for every ReWash line.","error");return;}if(invalidKg){setRewashMessage("Each ReWash line needs a KG value greater than zero.","error");return;}el.rewashSave.disabled=true;setRewashMessage("");try{const result=await rpc("record_finish_rewash_v1",{p_shift_code:state.shift,p_table_code:activeTableCode(),p_processed_by_staff_id:el.rewashProcessedBy.value,p_lines:lines,p_notes:el.rewashNotes.value.trim()||null});closeRewashDialog();await load();setMessage(result?.status==="corrected"?"ReWash updated.":"ReWash saved.","success");}catch(err){console.error(err);setRewashMessage(err.message||"ReWash could not be saved.","error");}finally{el.rewashSave.disabled=false;}});
  el.deliveryReconciliationDialog?.addEventListener("cancel",event=>event.preventDefault());
  el.deliveryReconciliationForm?.addEventListener("submit",event=>{event.preventDefault();saveDeliveryReconciliation("PROCESSED_CONFIRMED");});
  el.deliveryNotProcessed?.addEventListener("click",()=>saveDeliveryReconciliation("NOT_PROCESSED"));
  if(el.tableFocusTabs)el.tableFocusTabs.addEventListener("click",e=>{const b=e.target.closest("[data-focus-table]");if(!b||state.lockedTable)return;state.activeTable=b.dataset.focusTable;el.table.value=state.activeTable;renderMetrics();renderRewashCard();renderRecent();setMessage(`${tableName(state.activeTable)} selected. New customer records will default to this Table.`,"success");});
  if(el.queueModeTabs)el.queueModeTabs.addEventListener("click",e=>{const b=e.target.closest("[data-queue-mode]");if(!b)return;state.queueMode=b.dataset.queueMode==="AVAILABLE"?"AVAILABLE":"TODAY";renderQueue();});
  if(el.queueDayTabs)el.queueDayTabs.addEventListener("click",e=>{const b=e.target.closest("[data-queue-day]");if(!b)return;state.queueDay=b.dataset.queueDay==="TOMORROW"?"TOMORROW":"TODAY";renderQueue();});
  if(el.viewTabs)el.viewTabs.addEventListener("click",async e=>{const button=e.target.closest("[data-finish-view]");if(!button||button.dataset.finishView===state.view)return;state.view=button.dataset.finishView==="staff"?"staff":"production";const next=new URL(location.href);if(state.view==="staff")next.searchParams.set("view","staff");else next.searchParams.delete("view");history.replaceState(null,"",next);applyView();await load();});
  el.search.addEventListener("input",renderQueue);el.addBatch.addEventListener("click",()=>addLine());
  el.table.addEventListener("change",()=>{if(!state.lockedTable&&el.table.value){state.activeTable=el.table.value;renderMetrics();renderRecent();}if(!el.editId.value)fillProcessedByOptions({preserve:false});if(!state.selected||el.editId.value)return;renderExistingRecords();const current=currentContextEntry(state.selected.production_flow_item_id,el.table.value);if(current&&!currentLines().some(x=>x.batch_reference||x.quantity)&&!state.trolleyCodes.length&&!state.trolleyPending&&!el.notes.value.trim()){editEntry(current.finish_production_entry_id);}else if(current){setMessage("This customer already has a record for this Table / Business Date / Shift. Use Edit current record instead of creating another contribution.");}});
  el.clear.addEventListener("click",()=>{const q=state.selected;resetForm();if(q){selectCustomer(q);if(state.lockedTable){el.table.value=state.lockedTable;el.table.disabled=true;}}});
  el.cancelEdit.addEventListener("click",closeProductionDialog);el.productionDialogClose.addEventListener("click",closeProductionDialog);el.productionCancel.addEventListener("click",closeProductionDialog);el.productionDialog.addEventListener("cancel",e=>{e.preventDefault();closeProductionDialog();});
  el.trolleyOpen.addEventListener("click",openTrolleyDialog);if(el.trolleyReportButton)el.trolleyReportButton.addEventListener("click",openTrolleyReport);el.trolleyDialogReport.addEventListener("click",openTrolleyReport);if(el.trolleyNoTrolley)el.trolleyNoTrolley.addEventListener("click",()=>{state.trolleyCodes=[];state.trolleyValidation=null;state.trolleyMismatchAccepted=true;state.trolleyAutoConfirmed=false;state.trolleyPending=true;syncTrolleyHidden();renderTrolleyFormSummary();closeTrolleyDialog();});el.trolleyDialogClose.addEventListener("click",()=>closeTrolleyDialog({restore:true}));el.trolleyDialogCancel.addEventListener("click",()=>closeTrolleyDialog({restore:true}));el.trolleyDialogConfirm.addEventListener("click",confirmTrolleySelection);el.trolleyAdd.addEventListener("click",addTrolleyFromInput);el.trolleyScanInput.addEventListener("keydown",e=>{if(e.key==="Enter"){e.preventDefault();addTrolleyFromInput();}});el.trolleyScannedList.addEventListener("click",e=>{const b=e.target.closest("[data-remove-trolley]");if(b)removeTrolley(b.dataset.removeTrolley);});el.trolleyDialog.addEventListener("cancel",e=>{e.preventDefault();closeTrolleyDialog({restore:true});});
  el.staffDialogClose.addEventListener("click",closeStaffDialog);el.staffCancel.addEventListener("click",closeStaffDialog);el.staffDialog.addEventListener("cancel",e=>{e.preventDefault();closeStaffDialog();});
  el.attendanceDialogClose.addEventListener("click",closeAttendanceDialog);el.attendanceCancel.addEventListener("click",closeAttendanceDialog);el.attendanceDialog.addEventListener("cancel",e=>{e.preventDefault();closeAttendanceDialog();});
  el.moveDialogClose.addEventListener("click",closeMoveDialog);el.moveCancel.addEventListener("click",closeMoveDialog);el.moveDialog.addEventListener("cancel",e=>{e.preventDefault();closeMoveDialog();});
  el.departureDialogClose.addEventListener("click",closeDepartureDialog);el.departureCancel.addEventListener("click",closeDepartureDialog);el.departureDialog.addEventListener("cancel",e=>{e.preventDefault();closeDepartureDialog();});

  el.form.addEventListener("submit",async e=>{e.preventDefault();setMessage("");setDialogMessage("");if(!el.flowId.value){setDialogMessage("Select a customer first.","error");return;}if(!el.table.value){setDialogMessage("Choose the production Table.","error");return;}if(!el.processedBy.value){setDialogMessage("Select the staff member who processed this production.","error");el.processedBy.focus();return;}const lines=currentLines();if(!lines.length||lines.some(l=>!l.batch_reference||!l.quantity)){setDialogMessage("Complete every batch line before saving.","error");return;}el.save.disabled=true;try{
    if(!el.editId.value){const auto=await rpc("get_finish_auto_shift_context",{}),expected=String(auto?.recommended_shift_code||"").toUpperCase();if(expected&&expected!==state.shift)throw new Error(`Current Finish operational shift is ${shiftName(expected)}. Switch to Auto/current shift before saving a new production record.`);}
    await ensureTrolleyReadyForSave();let result;if(el.editId.value){result=await rpc("correct_finish_production_v3",{p_finish_production_entry_id:el.editId.value,p_processed_by_staff_id:el.processedBy.value,p_lines:lines,p_trolley_codes:trolleyCodes(),p_trolley_pending:state.trolleyPending,p_accept_trolley_mismatch:state.trolleyMismatchAccepted,p_notes:el.notes.value.trim()||null});}else{result=await rpc("record_finish_production_v3",{p_production_flow_item_id:el.flowId.value,p_shift_code:state.shift,p_table_code:el.table.value,p_processed_by_staff_id:el.processedBy.value,p_lines:lines,p_trolley_codes:trolleyCodes(),p_trolley_pending:state.trolleyPending,p_accept_trolley_mismatch:state.trolleyMismatchAccepted,p_notes:el.notes.value.trim()||null});try{localStorage.setItem(staffStorageKey(el.table.value,state.shift),el.processedBy.value);}catch(_){}}closeProductionDialog();await load();setMessage(result?.status==="corrected"?`Correction saved · Rev ${result.revision_no}.`:"Finish production saved.","success");}catch(err){console.error(err);setDialogMessage(err.message||"Finish production could not be saved.","error");}finally{el.save.disabled=false;}});
  el.staffForm.addEventListener("submit",async e=>{e.preventDefault();const staffId=el.staffSelect.value||staffCandidateByName(el.staffName.value)?.staff_id||"",breakMinutes=Number(el.staffBreak.value),row=staffById(staffId),hasTransfer=(row?.table_segments||[]).length>1,closingShift=el.staffCloseShift.checked,endTime=closingShift?el.staffEnd.value:"";if(!staffId){setStaffDialogMessage("Select an active production staff name from the suggestions.","error");el.staffName.focus();return;}if(!el.staffTable.value){setStaffDialogMessage("Choose the Actual Finish Table.","error");return;}if(!el.staffStart.value){setStaffDialogMessage("Enter the actual start time before saving.","error");el.staffStart.focus();return;}if(closingShift&&!endTime){setStaffDialogMessage("Choose the actual leaving time before closing the shift.","error");el.staffEnd.focus();return;}if(!closingShift&&el.staffEnd.value&&el.staffEnd.value!==el.staffEnd.dataset.plannedEnd){setStaffDialogMessage("Tick Record this as the actual leaving time to save a changed departure time.","error");return;}if(!Number.isInteger(breakMinutes)||breakMinutes<0||breakMinutes>240){setStaffDialogMessage("Break must be a whole number from 0 to 240 minutes.","error");return;}if(!confirmStaffTimeChange({name:el.staffName.value,start:el.staffStart.value,end:endTime,breakMinutes,tableNameText:tableName(el.staffTable.value)}))return;const btn=el.staffForm.querySelector("button[type=submit]");btn.disabled=true;setStaffDialogMessage("");try{if(hasTransfer)await rpc("correct_finish_staff_time_v1",{p_staff_id:staffId,p_shift_code:state.shift,p_table_code:el.staffTable.value,p_start_time:el.staffStart.value,p_end_time:endTime||null,p_reason:el.staffReason.value.trim()||null});else await rpc("upsert_finish_staff_actual",{p_staff_id:staffId,p_shift_code:state.shift,p_table_code:el.staffTable.value,p_start_time:el.staffStart.value,p_end_time:endTime||null,p_reason:el.staffReason.value.trim()||null});await rpc("set_finish_staff_break_v1",{p_staff_id:staffId,p_shift_code:state.shift,p_table_code:el.staffTable.value,p_break_minutes:breakMinutes});closeStaffDialog();await load();setMessage("Finish staff actual attendance and break saved.","success");}catch(err){console.error(err);setStaffDialogMessage(err.message||"Finish staff could not be confirmed.","error");}finally{btn.disabled=false;}});
  el.staffCloseShift.addEventListener("change",updateStaffDepartureHint);
  el.staffEnd.addEventListener("input",updateStaffDepartureHint);
  el.staffDialog.addEventListener("toggle",()=>{if(el.staffDialog.open)restoreRosterStartWhenPlaceholder();});
  el.attendanceForm.addEventListener("submit",async e=>{e.preventDefault();const staffId=el.attendanceStaffId.value;if(!staffId||!el.attendanceReason.value){setAttendanceMessage("Choose an absence reason.","error");return;}const btn=el.attendanceForm.querySelector("button[type=submit]");btn.disabled=true;setAttendanceMessage("");try{await rpc("set_finish_staff_attendance_v1",{p_shift_code:state.shift,p_staff_id:staffId,p_attendance_status:"ABSENT",p_absence_reason:el.attendanceReason.value,p_notes:el.attendanceNotes.value.trim()||null});closeAttendanceDialog();await load();setMessage("Actual absence saved. Use Confirm arrived if the person comes in later.","success");}catch(err){console.error(err);setAttendanceMessage(err.message||"Attendance could not be saved.","error");}finally{btn.disabled=false;}});
  el.moveForm.addEventListener("submit",async e=>{e.preventDefault();if(!el.moveStaffId.value||!el.moveFromTable.value||!el.moveToTable.value||!el.moveTime.value){setMoveMessage("Choose the destination Table and move time.","error");return;}const btn=el.moveForm.querySelector("button[type=submit]"),movingToSorting=el.moveToTable.value==="SORTING";btn.disabled=true;setMoveMessage("");try{const args={p_staff_id:el.moveStaffId.value,p_shift_code:state.shift,p_from_table_code:el.moveFromTable.value,p_move_time:el.moveTime.value,p_notes:el.moveNotes.value.trim()||null};if(movingToSorting)await rpc("move_finish_staff_to_sorting_v1",args);else await rpc("move_finish_staff_table_v1",{...args,p_to_table_code:el.moveToTable.value});closeMoveDialog();await load();setMessage(movingToSorting?"Cover moved to Sorting. Finish time was closed at the selected time.":"Staff moved. Table hours now follow the selected move time.","success");}catch(err){console.error(err);setMoveMessage(err.message||"Staff could not be moved.","error");}finally{btn.disabled=false;}});
  el.departureForm.addEventListener("submit",async e=>{e.preventDefault();if(!el.departureStaffId.value||!el.departureTable.value||!el.departureTime.value){setDepartureMessage("Choose the leaving time.","error");return;}const btn=el.departureForm.querySelector("button[type=submit]");btn.disabled=true;setDepartureMessage("");try{await rpc("finish_end_staff_shift_v1",{p_staff_id:el.departureStaffId.value,p_shift_code:state.shift,p_table_code:el.departureTable.value,p_end_time:el.departureTime.value,p_notes:el.departureNotes.value.trim()||null});closeDepartureDialog();await load();setMessage("Early departure recorded. Table hours were closed at the selected time.","success");}catch(err){console.error(err);setDepartureMessage(err.message||"Departure could not be saved.","error");}finally{btn.disabled=false;}});

  document.querySelectorAll("[data-shift]").forEach(btn=>btn.addEventListener("click",async()=>{const next=btn.dataset.shift;if(state.shift===next&&state.shiftMode==="MANUAL")return;state.shiftMode="MANUAL";state.shift=next;renderShift();closeProductionDialog();closeRewashDialog();closeStaffDialog();await load();}));
  el.shiftAuto.addEventListener("click",async()=>{state.shiftMode="AUTO";const changed=await refreshAutoShift(true);renderShift();if(changed||state.data)await load();});
  el.refresh.addEventListener("click",async()=>{if(state.shiftMode==="AUTO")await refreshAutoShift(false);await load();});

  document.addEventListener("visibilitychange",async()=>{if(document.visibilityState!=="visible"||state.shiftMode!=="AUTO")return;try{const changed=await refreshAutoShift(false);if(changed)await load();}catch(err){console.error(err);}});
  addEventListener("beforeunload",()=>{if(state.autoShiftTimer)clearInterval(state.autoShiftTimer);if(state.deliveryReconciliationTimer)clearInterval(state.deliveryReconciliationTimer);});

  try{applyView();if(await authenticate()){state.terminalContext=await window.elisProductionStation?.getTerminalContext("FINISH")||null;applyTableLock();resetForm();await refreshAutoShift(true);await load();state.autoShiftTimer=setInterval(async()=>{if(state.shiftMode!=="AUTO"||document.visibilityState!=="visible")return;try{const changed=await refreshAutoShift(false);if(changed)await load();}catch(err){console.error(err);}},60000);state.deliveryReconciliationTimer=setInterval(async()=>{if(document.visibilityState!=="visible"||state.deliveryReconciliationSaving)return;try{const context=await rpc("get_finish_delivery_reconciliation_context",{p_at:null});if(context?.schema_version!=="FINISH_DELIVERY_RECONCILIATION_V1")return;state.deliveryReconciliation=context;presentDeliveryReconciliation();}catch(err){console.error(err);}},60000);}}catch(err){console.error(err);setMessage(err.message||"Finish could not be initialized.");}
});
