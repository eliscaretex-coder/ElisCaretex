"use strict";

// Customer Service workspace: complaints, the production trace behind each complaint,
// customer alerts for the production screens, department tasks, results and settings.
// Every read and write goes through the customer_service RPCs, which apply the
// person's block of customers (scope OWN) or the whole company (scope ALL).
document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const esc = (v) => String(v ?? "").replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&#039;");
  const DEPARTMENTS = { SORTING:"Sorting", FINISH:"Finish", MOP:"MOP", DISTRIBUTION:"Distribution", CUSTOMER_SERVICE:"Customer Service", MAINTENANCE:"Maintenance", MANAGEMENT:"Management" };
  const AREAS = { SORTING:"Sorting", FINISH:"Finish", MOP:"MOP", DISTRIBUTION:"Distribution" };
  const STATUS = { OPEN:"Open", INVESTIGATING:"Investigating", RESOLVED:"Resolved", CANCELLED:"Cancelled" };
  const TASK_STATUS = { OPEN:"Open", IN_PROGRESS:"In progress", DONE:"Done", CANCELLED:"Cancelled" };
  const OUTCOME = { JUSTIFIED:"Justified", NOT_JUSTIFIED:"Not justified", UNDETERMINED:"Could not tell" };
  const SEVERITY = { LOW:"Low", MEDIUM:"Medium", HIGH:"High" };
  const CHANNEL = { PHONE:"Phone", EMAIL:"Email", DRIVER:"Driver", IN_PERSON:"In person", OTHER:"Other" };
  const EVENTS = {
    CREATED:"Complaint logged", EDITED:"Complaint edited", NOTE:"Note", LINKED:"Linked to production", UNLINKED:"Production link removed",
    STATUS_OPEN:"Reopened", STATUS_INVESTIGATING:"Investigating", STATUS_RESOLVED:"Resolved", STATUS_CANCELLED:"Cancelled",
    ALERT_CREATED:"Customer alert created", ALERT_EDITED:"Customer alert changed", ALERT_ENDED:"Customer alert ended",
    TASK_CREATED:"Task created", TASK_EDITED:"Task changed", TASK_OPEN:"Task reopened", TASK_IN_PROGRESS:"Task started", TASK_DONE:"Task done", TASK_CANCELLED:"Task cancelled",
    DUE_CHANGED:"Resolve-by date changed", OWNER_CHANGED:"Person changed"
  };
  const TITLES = {
    complaints:["Complaints","Every complaint has a resolve-by date. Overdue ones and customers with several complaints come first."],
    alerts:["Customer alerts","Alerts appear on the Sorting, Finish, MOP and Distribution screens while they are active."],
    tasks:["Tasks","Work for a department or a person, followed until it is done."],
    results:["Results","How many complaints the company had, what they were about and where they came from."],
    settings:["Settings","Customer blocks for each person and the list of complaint types."]
  };
  const state = { ws:null, tab:"complaints", quick:"all", complaints:[], detail:null, trace:null, traceRange:null, ask:null, complaintEdit:null, alertEdit:null, taskEdit:null, typeEdit:null, blockSelection:new Set() };

  const fmtDate = (v) => v ? new Intl.DateTimeFormat("en-IE",{day:"2-digit",month:"short",year:"numeric",timeZone:"UTC"}).format(new Date(`${String(v).slice(0,10)}T12:00:00Z`)) : "—";
  const fmtShort = (v) => v ? new Intl.DateTimeFormat("en-IE",{weekday:"short",day:"2-digit",month:"short",timeZone:"UTC"}).format(new Date(`${String(v).slice(0,10)}T12:00:00Z`)) : "—";
  const fmtDateTime = (v) => v ? new Intl.DateTimeFormat("en-IE",{day:"2-digit",month:"short",hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"Europe/Dublin"}).format(new Date(v)) : "—";
  const fmtTime = (v) => v ? new Intl.DateTimeFormat("en-IE",{hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"Europe/Dublin"}).format(new Date(v)) : "—";
  const shiftName = (v) => ({MORNING:"Morning",EVENING:"Evening"}[String(v||"").toUpperCase()] || v || "—");
  const tableName = (v) => String(v||"").replace(/^FINISH_TABLE_/,"Table ").replace(/_/g," ") || "—";
  const addDays = (iso,days) => { const d=new Date(`${iso}T12:00:00Z`); d.setUTCDate(d.getUTCDate()+days); return d.toISOString().slice(0,10); };
  const today = () => String(state.ws?.today || new Date().toISOString()).slice(0,10);
  const num = (v,d=1) => Number(v||0).toFixed(d);
  const me = () => state.ws?.me || {};

  async function rpc(name,args={}){ const {data,error}=await client.rpc(name,args); if(error) throw error; return data; }
  function setMessage(text="",type=""){ $("csMessage").textContent=text; $("csMessage").className=`finish-results-message ${type}`.trim(); }
  function formMessage(id,text="",type="error"){ const el=$(id); el.textContent=text; el.className=`cs-form-message ${text?type:""}`.trim(); }
  function errorText(err,fallback){ return err?.message || fallback; }

  // Customers ---------------------------------------------------------------------
  const customerLabel = (c) => `${c.customer_name}${c.customer_code?` (${c.customer_code})`:""}`;
  function customerByLabel(text){
    const raw=String(text||"").trim().toLowerCase(); if(!raw) return null;
    const list=state.ws?.customers||[];
    return list.find(c=>customerLabel(c).toLowerCase()===raw) || list.find(c=>String(c.customer_name).toLowerCase()===raw) || list.find(c=>String(c.customer_code||"").toLowerCase()===raw) || null;
  }
  function customerById(id){ return (state.ws?.customers||[]).find(c=>c.customer_id===id) || null; }
  function fillCustomerList(){
    $("csCustomerList").innerHTML=(state.ws?.customers||[]).map(c=>`<option value="${esc(customerLabel(c))}">${c.owner_name?esc(c.owner_name):"No person"}</option>`).join("");
  }
  function typeOptions(selected){
    return (state.ws?.types||[]).filter(t=>t.active||t.type_code===selected).map(t=>`<option value="${esc(t.type_code)}"${t.type_code===selected?" selected":""}>${esc(t.type_name)}</option>`).join("");
  }
  function departmentOptions(selected,{blank=false}={}){
    return `${blank?'<option value="">—</option>':""}${Object.entries(DEPARTMENTS).map(([k,v])=>`<option value="${k}"${k===selected?" selected":""}>${v}</option>`).join("")}`;
  }
  const chip = (cls,label) => `<em class="cs-chip ${esc(cls)}">${esc(label)}</em>`;
  const statusChip = (s) => chip(String(s||"").toLowerCase(), STATUS[s]||s);
  const severityChip = (s) => chip(`sev-${String(s||"").toLowerCase()}`, SEVERITY[s]||s);
  function linkSummary(link){
    if(!link) return "";
    const parts=[];
    if(link.finish_table_code) parts.push(`${tableName(link.finish_table_code)} · ${shiftName(link.finish_shift_code)} · ${fmtShort(link.finish_business_date)}`);
    if(link.mop_shift_code) parts.push(`MOP ${shiftName(link.mop_shift_code)} · ${fmtShort(link.mop_business_date)}`);
    if(link.sorting_shift_code) parts.push(`Washed ${shiftName(link.sorting_shift_code)} · ${fmtShort(link.sorting_business_date)}`);
    return parts.join(" | ");
  }

  // Deadlines ------------------------------------------------------------------------
  const isActive = (c) => ["OPEN","INVESTIGATING"].includes(c?.status);
  const plural = (n,word) => `${n} ${word}${Number(n)===1?"":"s"}`;
  function dueChip(c){
    if(!isActive(c)) return c.status==="RESOLVED"&&c.resolved_on_time===false?chip("late","Resolved late"):"";
    if(c.due_state==="OVERDUE") return chip("overdue",`Overdue ${plural(Number(c.overdue_days)||1,"day")}`);
    if(c.due_state==="DUE_TODAY") return chip("due-today","Due today");
    return c.resolve_by?chip("due",`By ${fmtShort(c.resolve_by)}`):"";
  }
  const idleChip = (c) => isActive(c)&&Number(c.idle_days)>=3?chip("idle",`No update ${plural(Number(c.idle_days),"day")}`):"";
  const targetDays = (sev) => Number(state.ws?.target_days?.[sev] ?? ({HIGH:2,MEDIUM:5,LOW:7}[sev]));
  // Most urgent first: open before closed, most days overdue, nearest date, newest received.
  function byUrgency(a,b){
    return (isActive(b)-isActive(a)) || (Number(b.overdue_days||0)-Number(a.overdue_days||0))
      || String(a.resolve_by||"9999").localeCompare(String(b.resolve_by||"9999")) || String(b.received_on).localeCompare(String(a.received_on));
  }

  // Tabs ----------------------------------------------------------------------------
  function currentTab(){ const t=location.hash.replace("#",""); return TITLES[t]?t:"complaints"; }
  function showTab(tab){
    state.tab=tab;
    document.querySelectorAll(".cs-view").forEach(v=>{ v.hidden=v.dataset.view!==tab; });
    document.querySelectorAll(".cs-tabs a").forEach(a=>a.classList.toggle("active",a.dataset.tab===tab));
    $("csTitle").textContent=TITLES[tab][0]; $("csSubtitle").textContent=TITLES[tab][1];
    setMessage("");
    loadTab().catch(err=>{ console.error(err); setMessage(errorText(err,"This section could not be loaded."),"error"); });
  }
  async function loadTab(){
    if(state.tab==="complaints") return loadComplaints();
    if(state.tab==="alerts") return loadAlerts();
    if(state.tab==="tasks") return loadTasks();
    if(state.tab==="results") return loadResults();
    if(state.tab==="settings") return renderSettings();
  }

  // Workspace -----------------------------------------------------------------------
  async function loadWorkspace(){
    const data=await rpc("get_customer_service_workspace_v1");
    if(data?.schema_version!=="CUSTOMER_SERVICE_V1") throw new Error("Customer Service backend is out of date. Refresh after the latest update.");
    state.ws=data; fillCustomerList(); renderCounts();
    $("csNewComplaint").disabled=!me().can_create; $("csNewAlert").disabled=!me().can_create; $("csNewTask").disabled=!me().can_create;
  }
  // The first four cards also filter the complaint list (click again to show all).
  function renderCounts(){
    const c=state.ws?.counts||{}, q=state.tab==="complaints"?state.quick:"", n=(k)=>Number(c[k]||0);
    const card=(key,label,value,sub,cls="")=>`<article class="cs-count ${cls} ${q===key?"active":""}" data-quick="${key}" role="button" tabindex="0" aria-pressed="${q===key}"><span>${label}</span><strong>${value}</strong><small>${sub}</small></article>`;
    $("csCounts").innerHTML=
      card("all","Open complaints",n("open_complaints"),`${me().scope==="ALL"?"All customers":"My block of customers"}${n("no_person_complaints")?` · ${n("no_person_complaints")} without a person`:""}`,n("open_complaints")?"cs-attention":"")+
      card("overdue","Overdue",n("overdue_complaints"),"Past their resolve-by date",n("overdue_complaints")?"low":"")+
      card("today","Due today",n("due_today_complaints"),"Resolve before the end of the day",n("due_today_complaints")?"cs-warn":"")+
      card("idle","No update 3+ days",n("idle_complaints"),"Open, nothing written for 3 days",n("idle_complaints")?"cs-warn":"")+
      `<article class="${n("overdue_tasks")?"low":""}"><span>Follow-up</span><strong>${plural(n("open_tasks"),"task")}</strong><small>${n("overdue_tasks")?`${n("overdue_tasks")} overdue · `:""}${plural(n("active_alerts"),"alert")} on the production screens</small></article>`;
  }
  function setQuick(key){
    state.quick=state.quick===key&&key!=="all"?"all":key;
    if(state.quick!=="all"&&$("csStatus").value!=="ACTIVE"){ $("csStatus").value="ACTIVE"; }
    if(state.tab!=="complaints"){ location.hash="#complaints"; return; }
    loadComplaints().catch(err=>setMessage(errorText(err,"Complaints could not be loaded."),"error"));
  }

  // Complaints list -------------------------------------------------------------------
  async function loadComplaints(){
    const status=$("csStatus").value;
    document.querySelectorAll("[data-period]").forEach(el=>{ el.hidden=status==="ACTIVE"; });
    if(status!=="ACTIVE") state.quick="all";
    setMessage("Loading complaints…");
    const data=await rpc("get_customer_service_complaints_v1",{p_from:$("csFrom").value||null,p_to:$("csTo").value||null,p_status:status,p_customer_id:null,p_only_mine:$("csOnlyMine").checked});
    state.complaints=data?.complaints||[];
    renderCounts(); renderComplaints(); setMessage("");
  }
  function filteredComplaints(){
    const q=$("csSearch").value.trim().toLowerCase(), f=state.quick;
    return state.complaints.filter(c=>{
      if(q&&!`${c.customer_name} ${c.customer_code||""} ${c.complaint_code} ${c.type_name} ${c.description} ${c.owner_name||""}`.toLowerCase().includes(q)) return false;
      if(f==="overdue") return c.due_state==="OVERDUE";
      if(f==="today") return c.due_state==="DUE_TODAY";
      if(f==="idle") return isActive(c)&&Number(c.idle_days)>=3;
      return true;
    });
  }
  // One block per customer, so several complaints from the same customer are read together.
  function groupByCustomer(rows){
    const map=new Map();
    rows.forEach(c=>{ if(!map.has(c.customer_id)) map.set(c.customer_id,{customer_id:c.customer_id,customer_name:c.customer_name,customer_code:c.customer_code,items:[]}); map.get(c.customer_id).items.push(c); });
    const groups=[...map.values()];
    groups.forEach(g=>{
      g.items.sort(byUrgency);
      const open=g.items.filter(isActive);
      g.open=open.length; g.overdue=open.filter(c=>c.due_state==="OVERDUE").length; g.dueToday=open.filter(c=>c.due_state==="DUE_TODAY").length;
      g.maxOverdue=Math.max(0,...open.map(c=>Number(c.overdue_days||0)));
      g.next=open.map(c=>c.resolve_by).filter(Boolean).sort()[0]||"9999";
      g.alert=g.items.some(c=>c.active_alert);
      g.owner=customerById(g.customer_id)?.owner_name||g.items[0]?.owner_name||"";
    });
    return groups.sort((a,b)=>(b.overdue-a.overdue)||(b.maxOverdue-a.maxOverdue)||(b.dueToday-a.dueToday)||String(a.next).localeCompare(String(b.next))||(b.items.length-a.items.length)||String(a.customer_name).localeCompare(String(b.customer_name)));
  }
  function complaintRow(c){
    const canEdit=me().can_edit, tasks=Number(c.open_task_count);
    return `<div class="cs-crow sev-${esc(String(c.severity).toLowerCase())} ${c.due_state==="OVERDUE"?"is-overdue":""}" data-open-complaint="${esc(c.complaint_id)}" role="button" tabindex="0">
        <span class="cs-c-main"><strong>${esc(c.complaint_code)} · ${esc(c.type_name)}</strong>${severityChip(c.severity)}<small>${esc(String(c.description||"").slice(0,110))}${String(c.description||"").length>110?"…":""}</small></span>
        <span class="cs-c-when"><small>Received ${esc(fmtShort(c.received_on))}${c.owner_name?` · ${esc(c.owner_name)}`:" · no person"}</small>${dueChip(c)}${idleChip(c)}</span>
        <span class="cs-c-follow">${c.link?`<small class="cs-link-text">${esc(linkSummary(c.link))}</small>`:""}${tasks?chip("task",plural(tasks,"open task")):""}${c.status==="INVESTIGATING"?statusChip(c.status):""}${!isActive(c)?`${statusChip(c.status)}${c.outcome?`<small>${esc(OUTCOME[c.outcome]||c.outcome)}</small>`:""}`:""}</span>
        <span class="cs-c-act">${canEdit&&isActive(c)?`<button type="button" class="cs-button secondary" data-quick-resolve="${esc(c.complaint_id)}">Resolve…</button>`:""}</span>
      </div>`;
  }
  function renderComplaints(){
    const rows=filteredComplaints(), groups=groupByCustomer(rows), status=$("csStatus").value;
    const titles={all:status==="ACTIVE"?"Open complaints":$("csStatus").selectedOptions[0]?.textContent,overdue:"Overdue complaints",today:"Complaints due today",idle:"No update for 3 days or more"};
    $("csListTitle").textContent=`${titles[state.quick]||"Complaints"}${groups.length?` · ${plural(groups.length,"customer")}`:""}`;
    $("csComplaintCount").textContent=String(rows.length);
    if(!rows.length){ $("csComplaints").innerHTML=`<div class="finish-results-empty">${state.complaints.length?"No complaints for this filter.":status==="ACTIVE"?"No open complaints. Well done.":"No complaints in this period."}</div>`; return; }
    const canCreate=me().can_create;
    $("csComplaints").innerHTML=groups.map(g=>`
      <section class="cs-group ${g.overdue?"has-overdue":g.dueToday?"has-today":""}">
        <header class="cs-group-head">
          <div><strong>${esc(g.customer_name)}</strong><small>${esc([g.customer_code,g.owner||"No person"].filter(Boolean).join(" · "))}</small></div>
          <div class="cs-group-stats">${g.open?chip("count",`${g.open} open`):""}${g.overdue?chip("overdue",`${g.overdue} overdue`):""}${g.dueToday?chip("due-today",`${g.dueToday} due today`):""}${g.alert?chip("alert","Alert on"):""}${!g.open?chip("count",plural(g.items.length,"complaint")):""}</div>
          ${canCreate?`<button type="button" class="cs-button secondary" data-new-for="${esc(g.customer_id)}">+ Complaint</button>`:""}
        </header>
        ${g.items.map(complaintRow).join("")}
      </section>`).join("");
  }

  // New / edit complaint ------------------------------------------------------------------
  // One short form: customer, what went wrong (one click), what they said, severity. The rest is optional.
  const checkedValue = (name) => document.querySelector(`input[name="${name}"]:checked`)?.value || "";
  function renderTypeChoices(selected){
    $("cfTypes").innerHTML=(state.ws?.types||[]).filter(t=>t.active||t.type_code===selected).map(t=>`<label><input type="radio" name="cfType" value="${esc(t.type_code)}"${t.type_code===selected?" checked":""}><span>${esc(t.type_name)}</span></label>`).join("");
  }
  function updateDueHint(){
    const sev=checkedValue("cfSeverity")||"MEDIUM", days=targetDays(sev);
    if(state.complaintEdit){ $("cfDueHint").textContent=state.complaintEdit.resolve_by?`Resolve by ${fmtShort(state.complaintEdit.resolve_by)}. A higher severity brings the date forward.`:""; return; }
    const received=$("cfReceived").value||today(); let due=addDays(received,days); if(due<today()) due=today();
    $("cfDueHint").textContent=`Must be resolved by ${fmtShort(due)} (${plural(days,"day")} for ${SEVERITY[sev].toLowerCase()}).`;
  }
  function updateCustomerOpen(){
    const customer=customerByLabel($("cfCustomer").value), el=$("cfCustomerOpen");
    const open=customer?state.complaints.filter(c=>c.customer_id===customer.customer_id&&isActive(c)&&c.complaint_id!==state.complaintEdit?.complaint_id):[];
    el.hidden=!open.length;
    el.innerHTML=open.length?`${esc(customer.customer_name)} already has ${plural(open.length,"open complaint")}: ${open.slice(0,4).map(c=>`<b>${esc(c.complaint_code)}</b> ${esc(c.type_name)}`).join(", ")}${open.length>4?"…":""}. If it is the same problem, add a note to that one instead.`:"";
  }
  function openComplaintForm(complaint=null,{customerId=null}={}){
    state.complaintEdit=complaint;
    $("csComplaintFormTitle").textContent=complaint?`Edit ${complaint.complaint_code}`:"New complaint";
    const customer=customerById(complaint?.customer_id||customerId);
    $("cfCustomer").value=customer?customerLabel(customer):(complaint?.customer_name||"");
    $("cfReceived").value=complaint?.received_on?.slice(0,10)||today();
    $("cfReceived").max=addDays(today(),1);
    $("cfDelivery").value=complaint?.delivery_date?.slice(0,10)||"";
    renderTypeChoices(complaint?.type_code);
    document.querySelectorAll('input[name="cfSeverity"]').forEach(i=>{ i.checked=i.value===(complaint?.severity||"MEDIUM"); });
    $("cfChannel").value=complaint?.channel||"";
    $("cfReference").value=complaint?.customer_reference||"";
    $("cfDescription").value=complaint?.description||"";
    $("cfMore").open=Boolean(complaint&&(complaint.delivery_date||complaint.channel||complaint.customer_reference));
    $("cfSaveAnother").hidden=Boolean(complaint);
    formMessage("cfMessage"); updateDueHint(); updateCustomerOpen(); $("csComplaintDialog").showModal();
    (complaint?$("cfDescription"):customer?$("cfTypes").querySelector("input")||$("cfDescription"):$("cfCustomer")).focus();
  }
  async function saveComplaint(event,{another=false}={}){
    event?.preventDefault();
    const customer=customerByLabel($("cfCustomer").value);
    if(!customer){ formMessage("cfMessage","Choose a customer from the list."); $("cfCustomer").focus(); return; }
    if(!checkedValue("cfType")){ formMessage("cfMessage","Choose what went wrong."); return; }
    if($("cfDescription").value.trim().length<3){ formMessage("cfMessage","Write what the customer said."); $("cfDescription").focus(); return; }
    if(!$("cfReceived").value){ $("cfMore").open=true; formMessage("cfMessage","Give the date the complaint was received."); return; }
    $("cfSave").disabled=$("cfSaveAnother").disabled=true; formMessage("cfMessage","Saving…","");
    try{
      const editing=state.complaintEdit;
      const result=await rpc("save_customer_service_complaint_v1",{p_complaint_id:editing?.complaint_id||null,p_customer_id:customer.customer_id,p_received_on:$("cfReceived").value,p_type_code:checkedValue("cfType"),p_description:$("cfDescription").value,p_severity:checkedValue("cfSeverity")||"MEDIUM",p_delivery_date:$("cfDelivery").value||null,p_channel:$("cfChannel").value||null,p_customer_reference:$("cfReference").value||null});
      const saved=`${result.complaint_code} saved for ${result.customer_name}${result.resolve_by?`, resolve by ${fmtShort(result.resolve_by)}`:""}.`;
      if(another){
        // Same customer, same dates: only the problem and the words change.
        $("cfDescription").value=""; document.querySelectorAll('input[name="cfType"]').forEach(i=>{ i.checked=false; });
        formMessage("cfMessage",`${saved} Add the next one.`,"success");
        await refreshAfterChange(); updateCustomerOpen(); $("cfTypes").querySelector("input")?.focus();
        return;
      }
      $("csComplaintDialog").close();
      setMessage(saved,"success");
      if(editing&&state.detail) await reloadDetail();
      await refreshAfterChange();
    }catch(err){ console.error(err); formMessage("cfMessage",errorText(err,"The complaint could not be saved.")); }
    finally{ $("cfSave").disabled=$("cfSaveAnother").disabled=false; }
  }

  // Complaint detail -------------------------------------------------------------------
  async function openDetail(id,{trace=false}={}){
    try{
      state.detail=await rpc("get_customer_service_complaint_v1",{p_complaint_id:id});
      state.trace=null; state.traceRange=null;
      renderDetail();
      if(!$("csDetailDialog").open) $("csDetailDialog").showModal();
      if(trace) loadTrace().catch(()=>{});
    }catch(err){ console.error(err); setMessage(errorText(err,"The complaint could not be opened."),"error"); }
  }
  async function reloadDetail(){ if(state.detail) { const keepTrace=state.trace,keepRange=state.traceRange; state.detail=await rpc("get_customer_service_complaint_v1",{p_complaint_id:state.detail.complaint.complaint_id}); state.trace=keepTrace; state.traceRange=keepRange; renderDetail(); } }

  function renderDetail(){
    const d=state.detail, c=d.complaint, canEdit=me().can_edit, active=["OPEN","INVESTIGATING"].includes(c.status);
    $("cdCode").textContent=`${c.complaint_code} · ${STATUS[c.status]||c.status}`;
    $("cdTitle").textContent=`${c.customer_name} — ${c.type_name}`;
    const range=state.traceRange||defaultTraceRange(c);
    $("cdBody").innerHTML=`
      <section class="cs-card cs-summary">
        <div class="cs-summary-grid">
          <div><small>Received</small><strong>${esc(fmtDate(c.received_on))}</strong>${c.channel?`<em>${esc(CHANNEL[c.channel]||c.channel)}</em>`:""}</div>
          <div><small>Delivery</small><strong>${esc(c.delivery_date?fmtDate(c.delivery_date):"Not given")}</strong></div>
          <div><small>Severity</small><strong>${severityChip(c.severity)}</strong></div>
          <div class="${c.due_state==="OVERDUE"?"cs-due-box overdue":c.due_state==="DUE_TODAY"?"cs-due-box today":""}"><small>Resolve by</small><strong>${esc(c.resolve_by?fmtDate(c.resolve_by):"—")}</strong><em>${active?(c.due_state==="OVERDUE"?`Overdue ${plural(Number(c.overdue_days),"day")}`:c.due_state==="DUE_TODAY"?"Due today":"On time"):c.resolved_on_time===true?"Resolved on time":c.resolved_on_time===false?"Resolved late":""}</em></div>
          <div><small>Status</small><strong>${statusChip(c.status)}</strong>${c.outcome?`<em>${esc(OUTCOME[c.outcome])}</em>`:""}</div>
          <div><small>Person</small><strong>${esc(c.owner_name||"—")}</strong><em>Logged by ${esc(c.created_by_name||"—")}</em></div>
        </div>
        <p class="cs-description">${esc(c.description)}</p>
        ${c.customer_reference?`<p class="cs-muted">Customer reference: ${esc(c.customer_reference)}</p>`:""}
        ${c.resolution_notes?`<p class="cs-resolution"><b>${c.status==="CANCELLED"?"Cancelled":"Resolution"}:</b> ${esc(c.resolution_notes)}${c.resolved_by_name?` <small>— ${esc(c.resolved_by_name)}, ${esc(fmtDateTime(c.resolved_at))}</small>`:""}</p>`:""}
        ${canEdit?`<div class="cs-actions">
          ${c.status!=="CANCELLED"?'<button type="button" class="cs-button secondary" data-detail-action="edit">Edit</button>':""}
          ${active?'<button type="button" class="cs-button secondary" data-detail-action="due">Change date…</button>':""}
          ${c.status==="OPEN"?'<button type="button" class="cs-button secondary" data-detail-action="investigating">Mark investigating</button>':""}
          ${active?'<button type="button" class="cs-button primary" data-detail-action="resolve">Resolve…</button><button type="button" class="cs-button danger" data-detail-action="cancel">Cancel complaint…</button>':""}
          ${!active?'<button type="button" class="cs-button secondary" data-detail-action="reopen">Reopen</button>':""}
        </div>`:""}
      </section>

      <section class="cs-card">
        <header><h3>Production link</h3><small>Finish (clothes) and MOP Production, with the wash of the same goods</small></header>
        ${c.link?`<div class="cs-linked">
          ${c.link.finish_table_code?`<div><small>Finish</small><strong>${esc(tableName(c.link.finish_table_code))} · ${esc(shiftName(c.link.finish_shift_code))}</strong><em>${esc(fmtDate(c.link.finish_business_date))}${c.link.finish_processed_by?` · processed by ${esc(c.link.finish_processed_by)}`:""}</em></div>`:""}
          ${c.link.mop_shift_code?`<div><small>MOP Production</small><strong>${esc(shiftName(c.link.mop_shift_code))} shift</strong><em>${esc(fmtDate(c.link.mop_business_date))}${c.link.mop_operator_name?` · by ${esc(c.link.mop_operator_name)}`:""}</em></div>`:""}
          ${c.link.sorting_shift_code?`<div><small>Washing</small><strong>${esc(shiftName(c.link.sorting_shift_code))} shift</strong><em>${esc(fmtDate(c.link.sorting_business_date))} · ${esc(c.link.sorting_washer_name||"")}${c.link.sorting_operator_name?` · ${esc(c.link.sorting_operator_name)}`:""}</em></div>`:""}
          ${canEdit?'<button type="button" class="cs-button secondary" data-detail-action="unlink">Remove link</button>':""}
        </div>`:'<p class="cs-muted">Not linked yet. Search below and pick the Finish record (or the MOP batch) that matches. Its wash is linked with it.</p>'}
        <div class="cs-trace-controls">
          <label>From<input id="cdTraceFrom" type="date" value="${esc(range.from)}"></label>
          <label>To<input id="cdTraceTo" type="date" value="${esc(range.to)}"></label>
          <button type="button" class="cs-button secondary" data-detail-action="trace">Search production</button>
        </div>
        <div id="cdTrace" class="cs-trace">${renderTrace()}</div>
      </section>

      <section class="cs-card">
        <header><h3>Customer alerts</h3>${canEdit&&active?'<button type="button" class="cs-button secondary" data-detail-action="new-alert">+ Alert the staff</button>':""}</header>
        ${(d.alerts||[]).length?d.alerts.map(alertRow).join(""):'<p class="cs-muted">No alert for this complaint.</p>'}
      </section>

      <section class="cs-card">
        <header><h3>Tasks</h3>${canEdit&&active?'<button type="button" class="cs-button secondary" data-detail-action="new-task">+ Task</button>':""}</header>
        ${(d.tasks||[]).length?d.tasks.map(taskRow).join(""):'<p class="cs-muted">No task for this complaint.</p>'}
      </section>

      <section class="cs-card">
        <header><h3>History</h3></header>
        ${canEdit?`<div class="cs-note-form"><input id="cdNote" maxlength="2000" placeholder="Add a note: call made, information from production…"><button type="button" class="cs-button secondary" data-detail-action="note">Add note</button></div>`:""}
        <ol class="cs-events">${(d.events||[]).map(e=>`<li><time>${esc(fmtDateTime(e.created_at))}</time><div><strong>${esc(EVENTS[e.event_type]||e.event_type)}</strong>${e.notes?`<p>${esc(e.notes)}</p>`:""}${eventDetail(e)}<small>${esc(e.created_by_name||"")}</small></div></li>`).join("")}</ol>
      </section>

      ${(d.customer_history||[]).length?`<section class="cs-card"><header><h3>Previous complaints from ${esc(c.customer_name)}</h3></header>
        <div class="cs-history">${d.customer_history.map(h=>`<button type="button" class="cs-history-item" data-open-complaint="${esc(h.complaint_id)}"><strong>${esc(h.complaint_code)}</strong><span>${esc(fmtShort(h.received_on))} · ${esc(h.type_name)}</span>${statusChip(h.status)}</button>`).join("")}</div></section>`:""}`;
  }
  function eventDetail(e){
    const x=e.details||{};
    if(e.event_type==="LINKED"){ const parts=[]; if(x.finish_table) parts.push(`${tableName(x.finish_table)} ${shiftName(x.finish_shift)} ${fmtShort(x.finish_date)}`); if(x.mop_shift) parts.push(`MOP ${shiftName(x.mop_shift)} ${fmtShort(x.mop_date)}`); if(x.sorting_shift) parts.push(`washed ${shiftName(x.sorting_shift)} ${fmtShort(x.sorting_date)}`); return parts.length?`<p class="cs-muted">${esc(parts.join(" · "))}</p>`:""; }
    if(e.event_type?.startsWith("TASK_")&&x.department) return `<p class="cs-muted">${x.person?`For ${esc(x.person)} · `:""}${esc(DEPARTMENTS[x.department]||x.department)}${x.title&&e.event_type!=="TASK_CREATED"?` · ${esc(x.title)}`:""}</p>`;
    if(e.event_type?.startsWith("ALERT_")&&Array.isArray(x.areas)) return `<p class="cs-muted">${esc(x.areas.map(a=>AREAS[a]||a).join(", "))}${x.ends_on?` · until ${esc(fmtShort(x.ends_on))}`:""}</p>`;
    if(e.event_type==="STATUS_RESOLVED"&&x.outcome) return `<p class="cs-muted">${esc(OUTCOME[x.outcome]||x.outcome)}</p>`;
    if(e.event_type==="DUE_CHANGED") return `<p class="cs-muted">${esc(x.from?fmtShort(x.from):"—")} → ${esc(fmtShort(x.to))}</p>`;
    if(e.event_type==="CREATED"&&x.resolve_by) return `<p class="cs-muted">Resolve by ${esc(fmtShort(x.resolve_by))}</p>`;
    if(e.event_type==="OWNER_CHANGED") return `<p class="cs-muted">${esc(x.owner_name||"No person")}</p>`;
    if(e.event_type==="EDITED"&&x.resolve_by_to) return `<p class="cs-muted">Resolve by ${esc(fmtShort(x.resolve_by_to))}${x.link_removed?" · production link removed (other customer)":""}</p>`;
    if(e.event_type==="EDITED"&&x.link_removed) return '<p class="cs-muted">Production link removed (other customer)</p>';
    return "";
  }
  function defaultTraceRange(c){
    const anchor=String(c.delivery_date||c.received_on||today()).slice(0,10);
    return { from:addDays(anchor,-7), to:c.delivery_date?addDays(anchor,1):anchor };
  }
  async function loadTrace(){
    const from=$("cdTraceFrom")?.value, to=$("cdTraceTo")?.value, c=state.detail?.complaint;
    if(!c||!from||!to) return;
    state.traceRange={from,to};
    $("cdTrace").innerHTML='<p class="cs-muted">Searching production records…</p>';
    try{ state.trace=await rpc("get_customer_service_production_trace_v1",{p_customer_id:c.customer_id,p_from:from,p_to:to}); $("cdTrace").innerHTML=renderTrace(); }
    catch(err){ console.error(err); $("cdTrace").innerHTML=`<p class="cs-form-message error">${esc(errorText(err,"Production records could not be loaded."))}</p>`; }
  }
  // The wash of the same goods (same production flow), shown on the Finish or MOP row: the full cycle on one line.
  function cycleLine(row){
    const w=(row.washes||[])[0];
    if(!w) return '<span class="cs-cycle none">No wash recorded for these goods</span>';
    return `<span class="cs-cycle">Washed ${esc(fmtShort(w.business_date))} · ${esc(shiftName(w.shift_code))} · ${esc(w.washer_name||w.wash_code||"")}${w.operator_name?` · ${esc(w.operator_name)}`:""}${(row.washes||[]).length>1?` (+${row.washes.length-1})`:""}</span>`;
  }
  function renderTrace(){
    const t=state.trace, c=state.detail?.complaint; if(!t) return '<p class="cs-muted">Choose the period and search. The delivery date of the complaint is the best starting point.</p>';
    const canEdit=me().can_edit, link=c?.link||{}, delivery=String(c?.delivery_date||"").slice(0,10);
    const finish=t.finish||[], mop=t.mop||[], washes=t.washes||[], hasMop=Boolean(t.has_mop);
    const pick=(name,value,flow,checked)=>canEdit?`<input type="radio" name="${name}" value="${esc(value)}" data-flow="${esc(flow||"")}"${checked?" checked":""}>`:"";
    const finishRows=finish.length?finish.map(f=>`
      <label class="cs-trace-row ${f.finish_production_entry_id===link.finish_entry_id?"linked":""} ${delivery&&String(f.delivery_date).slice(0,10)===delivery?"match":""}">
        ${pick("cdFinish",f.finish_production_entry_id,f.production_flow_item_id,f.finish_production_entry_id===link.finish_entry_id)}
        <span><strong>${esc(fmtShort(f.business_date))} · ${esc(shiftName(f.shift_code))}</strong><small>Delivery ${esc(fmtShort(f.delivery_date))} · recorded ${esc(fmtTime(f.recorded_at))}</small></span>
        <span><strong>${esc(f.table_name||tableName(f.table_code))}</strong><small>Processed by ${esc(f.processed_by||"—")}</small></span>
        <span><strong>${num(f.kg)} kg</strong><small>${Number(f.units)?`${num(f.units,0)} units · `:""}${(f.batches||[]).length?`Batch ${esc(f.batches.join(", "))}`:""}</small></span>
        <span class="cs-staff">${(f.table_staff||[]).length?`Table: ${esc(f.table_staff.join(", "))}`:"No staff recorded"}<br>${cycleLine(f)}</span>
      </label>`).join(""):'<p class="cs-muted">No Finish records for this customer in the period.</p>';
    const mopRows=mop.length?mop.map(b=>`
      <label class="cs-trace-row ${b.mop_production_batch_id===link.mop_batch_id?"linked":""} ${delivery&&String(b.delivery_date).slice(0,10)===delivery?"match":""}">
        ${pick("cdMop",b.mop_production_batch_id,b.production_flow_item_id,b.mop_production_batch_id===link.mop_batch_id)}
        <span><strong>${esc(fmtShort(b.business_date))} · ${esc(shiftName(b.shift_code))}</strong><small>Delivery ${esc(fmtShort(b.delivery_date))} · recorded ${esc(fmtTime(b.recorded_at))}</small></span>
        <span><strong>${esc(b.operator_name||"—")}</strong><small>${(b.trolleys||[]).length?`Trolley ${esc(b.trolleys.join(", "))}`:"No trolley recorded"}</small></span>
        <span><strong>${num(b.kg)} kg</strong><small>${Number(b.units)?`${num(b.units,0)} units`:""}</small></span>
        <span class="cs-staff">${(b.products||[]).map(p=>`${esc(p.name)} ${Number(p.units)?num(p.units,0):`${num(p.kg)} kg`}`).join(" · ")||"—"}<br>${cycleLine(b)}</span>
      </label>`).join(""):'<p class="cs-muted">No MOP batches for this customer in the period.</p>';
    const washRows=washes.map(w=>`
      <label class="cs-trace-row ${w.wash_run_id===link.wash_run_id?"linked":""}">
        ${pick("cdWash",w.wash_run_id,w.production_flow_item_id,false)}
        <span><strong>${esc(fmtShort(w.business_date))} · ${esc(shiftName(w.shift_code))}</strong><small>${esc(fmtTime(w.registered_at))}${w.scheduled_for_date?` · for ${esc(fmtShort(w.scheduled_for_date))}`:""}</small></span>
        <span><strong>${esc(w.washer_name||"—")}</strong><small>${esc(w.wash_type||"")} · operator ${esc(w.operator_name||"—")}</small></span>
        <span><strong>${num(w.customer_kg||w.total_kg)} kg</strong><small>${w.customer_kg?`of ${num(w.total_kg)} kg load`:"load"}</small></span>
        <span class="cs-staff">${(w.sorting_staff||[]).length?esc(w.sorting_staff.join(", ")):"No staff recorded"}</span>
      </label>`).join("");
    const highlight=delivery?" · rows for the complaint delivery date are highlighted":"";
    return `<div class="cs-trace-block ${hasMop?"":"cs-wide"}"><h4>Finish · clothes <small>${plural(finish.length,"record")}${highlight}</small></h4>${finishRows}</div>
      ${hasMop?`<div class="cs-trace-block"><h4>MOP Production <small>${plural(mop.length,"batch")}</small></h4>${mopRows}</div>`:""}
      ${washes.length?`<details class="cs-trace-more"><summary>Sorting: all ${plural(washes.length,"wash")} in the period (only needed when a record above shows no wash)</summary><div class="cs-trace-block">${washRows}</div></details>`:""}
      ${canEdit&&(finish.length||mop.length||washes.length)?'<div class="cs-actions"><button type="button" class="cs-button primary" data-detail-action="link">Link the selected records</button></div>':""}`;
  }
  async function linkSelected(){
    const val=(n)=>document.querySelector(`input[name="${n}"]:checked`)?.value||null;
    const fin=val("cdFinish"), mop=val("cdMop"), wash=val("cdWash");
    if(!fin&&!mop&&!wash){ setMessage("Select a Finish record or a MOP batch first.","error"); return; }
    await runAction(()=>rpc("link_customer_service_complaint_production_v2",{p_complaint_id:state.detail.complaint.complaint_id,p_finish_entry_id:fin,p_mop_batch_id:mop,p_wash_run_id:wash}),"Production link saved.");
  }
  // When a wash is picked, highlight the Finish records of the same production flow (and back).
  function syncFlowHighlight(){
    const flows=new Set([...document.querySelectorAll('#cdTrace input[type="radio"]:checked')].map(i=>i.dataset.flow).filter(Boolean));
    document.querySelectorAll("#cdTrace .cs-trace-row").forEach(row=>{ const f=row.querySelector("input")?.dataset.flow; row.classList.toggle("same-flow",Boolean(f&&flows.has(f))); });
  }

  async function runAction(action,successText){
    try{ await action(); setMessage(successText,"success"); await reloadDetail(); await refreshAfterChange(); }
    catch(err){ console.error(err); setMessage(errorText(err,"The change could not be saved."),"error"); }
  }
  async function refreshAfterChange(){
    try{ await loadWorkspace(); }catch(err){ console.error(err); }
    if(state.tab!=="settings") await loadTab().catch(err=>console.error(err));
  }

  // Ask dialog (resolve, cancel, task done, end alert) -----------------------------------------
  function ask({eyebrow="Customer Service",title,notesLabel="Notes",outcome=false,date=null,check=null,required=true,confirm="Confirm",danger=false,onConfirm}){
    state.ask={onConfirm,outcome,required,date:Boolean(date)};
    $("askEyebrow").textContent=eyebrow; $("askTitle").textContent=title; $("askNotesLabel").textContent=notesLabel;
    $("askOutcomeWrap").hidden=!outcome; document.querySelectorAll('input[name="askOutcome"]').forEach(i=>{ i.checked=false; }); $("askNotes").value="";
    $("askDateWrap").hidden=!date; if(date){ $("askDate").min=date.min||""; $("askDate").value=date.value||""; }
    $("askCheckWrap").hidden=!check; $("askCheck").checked=Boolean(check?.checked); $("askCheckLabel").textContent=check?.label||"";
    $("askConfirm").textContent=confirm; $("askConfirm").classList.toggle("danger",danger); $("askConfirm").classList.toggle("primary",!danger);
    formMessage("askMessage"); $("csAskDialog").showModal(); $("askNotes").focus();
  }
  async function confirmAsk(event){
    event.preventDefault();
    const a=state.ask; if(!a) return;
    const outcome=checkedValue("askOutcome");
    if(a.outcome&&!outcome){ formMessage("askMessage","Say whether the complaint was justified."); return; }
    if(a.date&&!$("askDate").value){ formMessage("askMessage","Choose the new date."); return; }
    if(a.required&&$("askNotes").value.trim().length<3){ formMessage("askMessage","Write a short note."); return; }
    $("askConfirm").disabled=true;
    try{ await a.onConfirm({notes:$("askNotes").value.trim(),outcome:outcome||null,date:$("askDate").value||null,check:!$("askCheckWrap").hidden&&$("askCheck").checked}); $("csAskDialog").close(); }
    catch(err){ console.error(err); formMessage("askMessage",errorText(err,"The change could not be saved.")); }
    finally{ $("askConfirm").disabled=false; }
  }

  // Resolve from the list or from the complaint: outcome + what was done, and its alerts can end at the same time.
  function resolveComplaint(c){
    const alerts=Number(c.own_active_alerts||0);
    return ask({title:`Resolve ${c.complaint_code} · ${c.customer_name}`,notesLabel:"What was done for the customer",outcome:true,confirm:"Resolve",
      check:alerts?{checked:true,label:`Also end its ${plural(alerts,"customer alert")} on the production screens`}:null,
      onConfirm:async({notes,outcome,check})=>{
        await rpc("set_customer_service_complaint_status_v1",{p_complaint_id:c.complaint_id,p_status:"RESOLVED",p_outcome:outcome,p_notes:notes});
        let ended=0;
        if(check){
          const detail=state.detail?.complaint?.complaint_id===c.complaint_id?state.detail:await rpc("get_customer_service_complaint_v1",{p_complaint_id:c.complaint_id});
          for(const a of (detail?.alerts||[]).filter(a=>a.state==="ACTIVE"||a.state==="SCHEDULED")){ await rpc("end_customer_service_alert_v1",{p_alert_id:a.alert_id,p_reason:`Complaint ${c.complaint_code} resolved`}); ended++; }
        }
        setMessage(`${c.complaint_code} resolved${ended?` and ${plural(ended,"alert")} ended`:""}.`,"success");
        if(state.detail&&$("csDetailDialog").open) await reloadDetail();
        await refreshAfterChange();
      }});
  }

  async function detailAction(action){
    const c=state.detail?.complaint; if(!c) return;
    const id=c.complaint_id;
    if(action==="edit") return openComplaintForm(c);
    if(action==="trace") return loadTrace();
    if(action==="link") return linkSelected();
    if(action==="unlink") return runAction(()=>rpc("link_customer_service_complaint_production_v2",{p_complaint_id:id,p_finish_entry_id:null,p_mop_batch_id:null,p_wash_run_id:null}),"Production link removed.");
    if(action==="investigating") return runAction(()=>rpc("set_customer_service_complaint_status_v1",{p_complaint_id:id,p_status:"INVESTIGATING",p_outcome:null,p_notes:null}),"Complaint marked as investigating.");
    if(action==="reopen") return runAction(()=>rpc("set_customer_service_complaint_status_v1",{p_complaint_id:id,p_status:"OPEN",p_outcome:null,p_notes:null}),"Complaint reopened.");
    if(action==="resolve") return resolveComplaint(c);
    if(action==="due") return ask({title:`New date for ${c.complaint_code}`,notesLabel:"Why the date changes (kept in the history)",date:{min:today(),value:addDays(today(),2)},confirm:"Change date",onConfirm:async({notes,date})=>{ await rpc("set_customer_service_complaint_due_v1",{p_complaint_id:id,p_resolve_by:date,p_reason:notes}); setMessage(`${c.complaint_code} must now be resolved by ${fmtShort(date)}.`,"success"); await reloadDetail(); await refreshAfterChange(); }});
    if(action==="cancel") return ask({title:`Cancel ${c.complaint_code}`,notesLabel:"Why it is cancelled (for example, logged twice). Its alerts end and its open tasks are cancelled too.",confirm:"Cancel complaint",danger:true,onConfirm:async({notes})=>{ await rpc("set_customer_service_complaint_status_v1",{p_complaint_id:id,p_status:"CANCELLED",p_outcome:null,p_notes:notes}); setMessage(`${c.complaint_code} cancelled, with its alerts and open tasks.`,"success"); await reloadDetail(); await refreshAfterChange(); }});
    if(action==="new-alert") return openAlertForm({customer_id:c.customer_id,complaint_id:id,message:`${c.type_name}: ${c.description}`.slice(0,300)});
    if(action==="new-task"){ const type=(state.ws?.types||[]).find(t=>t.type_code===c.type_code); return openTaskForm({complaint_id:id,customer_id:c.customer_id,department_code:type?.default_department_code||"",title:`${c.type_name} — ${c.customer_name}`.slice(0,160)}); }
    if(action==="note"){ const text=$("cdNote").value.trim(); if(!text) return; return runAction(()=>rpc("add_customer_service_note_v1",{p_complaint_id:id,p_notes:text}),"Note added."); }
  }

  // Alerts ------------------------------------------------------------------------------
  function alertRow(a){
    const live=a.state==="ACTIVE"||a.state==="SCHEDULED", canEdit=me().can_edit;
    return `<article class="cs-item alert ${esc(String(a.state).toLowerCase())}">
      <div><strong>${esc(a.customer_name)}</strong>${chip(String(a.state).toLowerCase(),a.state==="ACTIVE"?"Active":a.state==="SCHEDULED"?"Starts "+fmtShort(a.starts_on):a.state==="EXPIRED"?"Expired":"Ended")}
        <p>${esc(a.message)}</p>
        <small>${esc((a.areas||[]).map(x=>AREAS[x]||x).join(" · "))} · from ${esc(fmtShort(a.starts_on))}${a.ends_on?` until ${esc(fmtShort(a.ends_on))}`:" until ended"}${a.complaint_code?` · ${esc(a.complaint_code)}`:""} · by ${esc(a.created_by_name||"—")}</small>
        ${a.ended_at?`<small>Ended ${esc(fmtDateTime(a.ended_at))} by ${esc(a.ended_by_name||"—")}${a.end_reason?`: ${esc(a.end_reason)}`:""}</small>`:""}
      </div>
      ${canEdit&&live?`<div class="cs-item-actions"><button type="button" class="cs-button secondary" data-edit-alert="${esc(a.alert_id)}">Edit</button><button type="button" class="cs-button secondary" data-end-alert="${esc(a.alert_id)}">End alert</button></div>`:""}
    </article>`;
  }
  async function loadAlerts(){
    setMessage("Loading customer alerts…");
    const rows=await rpc("get_customer_service_alerts_v1",{p_include_ended:$("csAlertsEnded").checked});
    state.alerts=rows||[]; $("csAlertCount").textContent=String(state.alerts.length);
    $("csAlerts").innerHTML=state.alerts.length?state.alerts.map(alertRow).join(""):'<div class="finish-results-empty">No customer alerts.</div>';
    setMessage("");
  }
  function openAlertForm(alert={}){
    state.alertEdit=alert;
    $("caTitle").textContent=alert.alert_id?"Edit customer alert":"New customer alert";
    const customer=customerById(alert.customer_id);
    $("caCustomer").value=customer?customerLabel(customer):""; $("caCustomer").disabled=Boolean(alert.alert_id||alert.complaint_id);
    $("caMessage").value=alert.message||"";
    const areas=new Set(alert.areas||["SORTING","FINISH"]);
    document.querySelectorAll(".cs-areas input").forEach(i=>{ i.checked=areas.has(i.value); });
    $("caStart").value=String(alert.starts_on||today()).slice(0,10);
    // New alerts end by themselves after two weeks unless someone changes the date, so none stays on forever by mistake.
    $("caEnd").value=String(alert.ends_on||(alert.alert_id?"":addDays(today(),14))).slice(0,10);
    formMessage("caMessageLine"); $("csAlertDialog").showModal(); $("caMessage").focus();
  }
  async function saveAlert(event){
    event.preventDefault();
    const a=state.alertEdit||{}, customer=customerByLabel($("caCustomer").value)||customerById(a.customer_id);
    if(!customer){ formMessage("caMessageLine","Choose a customer from the list."); return; }
    const areas=[...document.querySelectorAll(".cs-areas input:checked")].map(i=>i.value);
    if(!areas.length){ formMessage("caMessageLine","Choose at least one area."); return; }
    try{
      await rpc("save_customer_service_alert_v1",{p_alert_id:a.alert_id||null,p_customer_id:customer.customer_id,p_message:$("caMessage").value,p_areas:areas,p_starts_on:$("caStart").value||null,p_ends_on:$("caEnd").value||null,p_complaint_id:a.complaint_id||null});
      $("csAlertDialog").close(); setMessage(`Alert saved for ${customer.customer_name}. The production screens show it within a few minutes.`,"success");
      if(state.detail&&$("csDetailDialog").open) await reloadDetail();
      await refreshAfterChange();
    }catch(err){ console.error(err); formMessage("caMessageLine",errorText(err,"The alert could not be saved.")); }
  }
  function endAlert(id){
    ask({title:"End customer alert",notesLabel:"Why it can end (optional)",required:false,confirm:"End alert",onConfirm:async({notes})=>{ await rpc("end_customer_service_alert_v1",{p_alert_id:id,p_reason:notes||null}); setMessage("Alert ended. It no longer shows on the production screens.","success"); if(state.detail&&$("csDetailDialog").open) await reloadDetail(); await refreshAfterChange(); }});
  }
  function findAlert(id){ return [...(state.alerts||[]),...(state.detail?.alerts||[])].find(a=>a.alert_id===id); }

  // Tasks -------------------------------------------------------------------------------
  function taskRow(t){
    const open=["OPEN","IN_PROGRESS"].includes(t.status), canEdit=me().can_edit;
    return `<article class="cs-item task ${esc(String(t.status).toLowerCase())} ${t.overdue?"overdue":""}">
      <div><strong>${esc(t.title)}</strong>${chip(String(t.status).toLowerCase(),TASK_STATUS[t.status]||t.status)}${t.overdue?chip("overdue","Overdue"):""}
        ${t.details?`<p>${esc(t.details)}</p>`:""}
        <small>${t.assigned_name?`<b class="cs-task-person">For ${esc(t.assigned_name)}</b> · `:""}${esc(DEPARTMENTS[t.department_code]||t.department_code)}${t.due_on?` · due ${esc(fmtShort(t.due_on))}`:""}${t.customer_name?` · ${esc(t.customer_name)}`:""}${t.complaint_code?` · ${esc(t.complaint_code)}`:""} · by ${esc(t.created_by_name||"—")}</small>
        ${t.completed_at?`<small>${t.status==="DONE"?"Done":"Closed"} ${esc(fmtDateTime(t.completed_at))} by ${esc(t.completed_by_name||"—")}${t.completion_notes?`: ${esc(t.completion_notes)}`:""}</small>`:""}
      </div>
      ${canEdit?`<div class="cs-item-actions">
        ${t.complaint_id&&state.tab==="tasks"&&!$("csDetailDialog").open?`<button type="button" class="cs-button secondary" data-open-complaint="${esc(t.complaint_id)}">Complaint</button>`:""}
        ${open?`<button type="button" class="cs-button secondary" data-edit-task="${esc(t.task_id)}">Edit</button>`:""}
        ${t.status==="OPEN"?`<button type="button" class="cs-button secondary" data-task-status="IN_PROGRESS" data-task="${esc(t.task_id)}">Start</button>`:""}
        ${open?`<button type="button" class="cs-button primary" data-task-status="DONE" data-task="${esc(t.task_id)}">Done…</button><button type="button" class="cs-button secondary" data-task-status="CANCELLED" data-task="${esc(t.task_id)}">Cancel…</button>`:`<button type="button" class="cs-button secondary" data-task-status="OPEN" data-task="${esc(t.task_id)}">Reopen</button>`}
      </div>`:""}
    </article>`;
  }
  async function loadTasks(){
    setMessage("Loading tasks…");
    loadPeople().catch(err=>console.warn("People could not be loaded.",err));
    const rows=await rpc("get_customer_service_tasks_v2",{p_status:$("csTaskStatus").value,p_department_code:$("csTaskDepartment").value||null,p_assignee_key:$("csTaskPerson").value||null});
    state.tasks=rows||[]; $("csTaskCount").textContent=String(state.tasks.length);
    $("csTasks").innerHTML=state.tasks.length?state.tasks.map(taskRow).join(""):'<div class="finish-results-empty">No tasks for this filter.</div>';
    setMessage("");
  }
  function findTask(id){ return [...(state.tasks||[]),...(state.detail?.tasks||[])].find(t=>t.task_id===id); }
  // People a task can go to (loaded once, when first needed).
  const personLabel=p=>`${p.name} · ${p.detail}`;
  async function loadPeople(){
    if(state.people) return state.people;
    state.people=(await rpc("get_customer_service_task_people_v1"))||[];
    $("csPeopleList").innerHTML=state.people.map(p=>`<option value="${esc(personLabel(p))}">${p.has_login?"Sees it in Notifications":"Sees it on the production screen"}</option>`).join("");
    const keep=$("csTaskPerson").value;
    $("csTaskPerson").innerHTML=`<option value="">Everyone</option><option value="NONE">No person (whole department)</option>${state.people.map(p=>`<option value="${esc(p.key)}">${esc(p.name)}</option>`).join("")}`;
    $("csTaskPerson").value=keep;
    return state.people;
  }
  function personByLabel(text){ const t=String(text||"").trim().toLowerCase(); return (state.people||[]).find(p=>personLabel(p).toLowerCase()===t)||(state.people||[]).filter(p=>p.name.toLowerCase()===t).at(0)||null; }
  function personHint(){
    const p=personByLabel($("ctPerson").value);
    $("ctPersonHint").textContent=!$("ctPerson").value.trim()?"Supervisors, managers or a General Operative with extra work."
      :p?(p.has_login?`${p.name} sees it in Notifications and on the production screen of the department.`:`${p.name} has no sign-in: the task shows "For ${p.name}" on the production screen of the department.`)
      :"Choose a name from the list.";
  }
  function openTaskForm(task={}){
    state.taskEdit=task;
    $("ctPerson").value=task.assigned_name?(()=>{ const p=(state.people||[]).find(x=>x.key===task.assigned_key); return p?personLabel(p):task.assigned_name; })():"";
    loadPeople().then(()=>{ if(task.assigned_key){ const p=state.people.find(x=>x.key===task.assigned_key); if(p) $("ctPerson").value=personLabel(p); } personHint(); }).catch(err=>console.warn("People could not be loaded.",err));
    $("ctTitle").textContent=task.task_id?"Edit task":"New task";
    const customer=customerById(task.customer_id);
    $("ctCustomer").value=customer?customerLabel(customer):(task.customer_name||""); $("ctCustomer").disabled=Boolean(task.complaint_id||task.task_id);
    $("ctDepartment").innerHTML=`<option value="">Choose…</option>${departmentOptions(task.department_code)}`;
    $("ctDue").value=String(task.due_on||addDays(today(),2)).slice(0,10);
    $("ctTask").value=task.title||""; $("ctDetails").value=task.details||"";
    formMessage("ctMessage"); $("csTaskDialog").showModal(); $("ctTask").focus();
  }
  async function saveTask(event){
    event.preventDefault();
    const t=state.taskEdit||{}, typed=$("ctCustomer").value.trim(), customer=typed?customerByLabel(typed):null;
    if(typed&&!customer&&!t.customer_id){ formMessage("ctMessage","Choose a customer from the list, or leave it empty."); return; }
    if(!$("ctDepartment").value){ formMessage("ctMessage","Choose the department."); return; }
    const typedPerson=$("ctPerson").value.trim(), person=typedPerson?personByLabel(typedPerson):null;
    const keepPerson=typedPerson&&!person&&t.assigned_key&&typedPerson===t.assigned_name;
    if(typedPerson&&!person&&!keepPerson){ formMessage("ctMessage","Choose a person from the list, or leave it empty for the whole department."); return; }
    try{
      await rpc("save_customer_service_task_v2",{p_task_id:t.task_id||null,p_department_code:$("ctDepartment").value,p_title:$("ctTask").value,p_details:$("ctDetails").value||null,p_due_on:$("ctDue").value||null,p_complaint_id:t.complaint_id||null,p_customer_id:customer?.customer_id||t.customer_id||null,p_assignee_key:person?.key||(keepPerson?t.assigned_key:null)});
      $("csTaskDialog").close(); setMessage(`Task saved for ${person?person.name:keepPerson?t.assigned_name:DEPARTMENTS[$("ctDepartment").value]}.`,"success");
      if(state.detail&&$("csDetailDialog").open) await reloadDetail();
      await refreshAfterChange();
    }catch(err){ console.error(err); formMessage("ctMessage",errorText(err,"The task could not be saved.")); }
  }
  async function setTaskStatus(id,status){
    const t=findTask(id); if(!t) return;
    const apply=async(notes)=>{ await rpc("set_customer_service_task_status_v1",{p_task_id:id,p_status:status,p_notes:notes||null}); setMessage(`Task ${TASK_STATUS[status].toLowerCase()}.`,"success"); if(state.detail&&$("csDetailDialog").open) await reloadDetail(); await refreshAfterChange(); };
    if(status==="DONE") return ask({title:`Done: ${t.title}`,notesLabel:"What was done (and who did it)",confirm:"Mark done",onConfirm:({notes})=>apply(notes)});
    if(status==="CANCELLED") return ask({title:`Cancel: ${t.title}`,notesLabel:"Why it is cancelled",confirm:"Cancel task",danger:true,onConfirm:({notes})=>apply(notes)});
    try{ await apply(null); }catch(err){ console.error(err); setMessage(errorText(err,"The task could not be changed."),"error"); }
  }

  // Results -----------------------------------------------------------------------------
  function bars(rows,label,value,{extra=null,empty="Nothing in this period."}={}){
    if(!rows?.length) return `<div class="finish-results-empty">${empty}</div>`;
    const max=Math.max(...rows.map(r=>Number(r[value]||0)),1);
    return rows.map(r=>`<div class="cs-bar"><span>${esc(label(r))}</span><div><i style="width:${Math.max(2,Number(r[value]||0)/max*100)}%"></i></div><b>${Number(r[value]||0)}</b>${extra?`<small>${esc(extra(r))}</small>`:""}</div>`).join("");
  }
  // Donut chart (SVG), legend with count and share. Empty slices are left out.
  function donut(rows,{label,color,empty="Nothing in this period."}){
    const list=(rows||[]).filter(r=>Number(r.complaints)>0), total=list.reduce((a,r)=>a+Number(r.complaints),0);
    if(!total) return `<div class="finish-results-empty">${empty}</div>`;
    const R=42, C=2*Math.PI*R; let offset=0;
    const arcs=list.map((r,i)=>{ const len=Number(r.complaints)/total*C, arc=`<circle r="${R}" cx="60" cy="60" fill="none" stroke="${color(r,i)}" stroke-width="18" stroke-dasharray="${len} ${C-len}" stroke-dashoffset="${-offset}"><title>${esc(label(r))}: ${Number(r.complaints)}</title></circle>`; offset+=len; return arc; }).join("");
    return `<div class="cs-donut"><svg viewBox="0 0 120 120" role="img" aria-label="${esc(list.map(r=>`${label(r)} ${r.complaints}`).join(", "))}"><g transform="rotate(-90 60 60)">${arcs}</g><text x="60" y="60" text-anchor="middle" dominant-baseline="central">${total}</text></svg>
      <ul>${list.map((r,i)=>`<li><i style="background:${color(r,i)}"></i><span>${esc(label(r))}</span><b>${Number(r.complaints)}</b><small>${Math.round(Number(r.complaints)/total*100)}%</small></li>`).join("")}</ul></div>`;
  }
  const PRODUCT={CLOTHES:["Clothes","#0f766e"],MOP:["MOP","#7c3aed"],NOT_KNOWN:["Clothes or MOP, not linked yet","#cbd5e1"]};
  const PALETTE=["#0f766e","#2563eb","#7c3aed","#d97706","#db2777","#0891b2","#65a30d","#94a3b8"];
  async function loadResults(){
    if(!$("csResultsFrom").value) setPreset("month",false);
    setMessage("Loading results…");
    const r=await rpc("get_customer_service_results_v1",{p_from:$("csResultsFrom").value,p_to:$("csResultsTo").value});
    const t=r.totals||{}, total=Number(t.complaints||0), decided=Number(t.justified||0)+Number(t.not_justified||0);
    $("csResultsTotals").innerHTML=`
      <article class="cs-attention"><span>Complaints</span><strong>${total}</strong><small>${Number(t.customers||0)} customer${Number(t.customers)===1?"":"s"} · ${Number(t.high||0)} high severity</small></article>
      <article class="${Number(t.overdue)?"low":""}"><span>Still open</span><strong>${Number(t.open||0)}</strong><small>${Number(t.overdue||0)} overdue · ${Number(t.resolved||0)} resolved</small></article>
      <article><span>Resolved on time</span><strong>${Number(t.resolved_with_date)?`${Math.round(Number(t.resolved_on_time||0)/Number(t.resolved_with_date)*100)}%`:"—"}</strong><small>${Number(t.resolved_on_time||0)} of ${Number(t.resolved_with_date||0)} by their resolve-by date</small></article>
      <article class="${decided&&Number(t.justified)/decided>0.5?"low":""}"><span>Justified</span><strong>${Number(t.justified||0)}</strong><small>${decided?`${Math.round(Number(t.justified)/decided*100)}% of the decided ones`:"None decided yet"}</small></article>
      <article><span>Average to resolve</span><strong>${t.avg_days_to_resolve==null?"—":`${num(t.avg_days_to_resolve)} days`}</strong><small>From received to resolved</small></article>
      <article><span>Per 100 customers</span><strong>${Number(t.active_customers)?num(total/Number(t.active_customers)*100):"—"}</strong><small>${Number(t.active_customers)?`${Math.round(Number(t.customers||0)/Number(t.active_customers)*1000)/10}% of ${Number(t.active_customers)} customers complained`:"No active customers"}</small></article>
      <article class="planned"><span>Linked to production</span><strong>${Number(t.linked||0)}</strong><small>${total?Math.round(Number(t.linked||0)/total*100):0}% · ${Number(t.tasks_open||0)} tasks open${Number(t.tasks_overdue)?`, ${Number(t.tasks_overdue)} overdue`:""}</small></article>`;
    const periodName={day:"day",week:"week",month:"month"}[r.period]||"day";
    $("csPeriodTitle").textContent=`Complaints per ${periodName}`;
    const periodLabel=(p)=>r.period==="month"?new Intl.DateTimeFormat("en-IE",{month:"short",year:"numeric",timeZone:"UTC"}).format(new Date(`${p}T12:00:00Z`)):r.period==="week"?`Week of ${fmtShort(p)}`:fmtShort(p);
    const per=r.by_period||[], maxP=Math.max(...per.map(x=>Number(x.complaints)),1);
    $("csByPeriod").innerHTML=per.length?`<div class="cs-columns">${per.map(x=>`<div class="cs-column" title="${esc(periodLabel(x.period_start))}: ${Number(x.complaints)} complaint(s), ${Number(x.justified)} justified"><b>${Number(x.complaints)}</b><div><i style="height:${Number(x.complaints)/maxP*100}%"></i><em style="height:${Number(x.justified)/maxP*100}%"></em></div><span>${esc(periodLabel(x.period_start))}</span></div>`).join("")}</div><p class="cs-legend"><i></i> Complaints <em></em> Justified</p>`:'<div class="finish-results-empty">No complaints in this period.</div>';
    $("csByType").innerHTML=bars(r.by_type,x=>x.type_name,"complaints",{extra:x=>Number(x.justified)?`${x.justified} justified`:""});
    $("csByProduct").innerHTML=donut(r.by_product,{label:x=>PRODUCT[x.product_code]?.[0]||x.product_code,color:x=>PRODUCT[x.product_code]?.[1]||"#94a3b8"});
    $("csByResponsible").innerHTML=donut(r.by_responsible,{label:x=>x.department_code==="NOT_SET"?"Not set on the type":(DEPARTMENTS[x.department_code]||x.department_code),color:(x,i)=>x.department_code==="NOT_SET"?"#cbd5e1":PALETTE[i%PALETTE.length]});
    const st=[["Open",Number(t.open||0)-Number(t.investigating||0),"#b91c1c"],["Investigating",Number(t.investigating||0),"#d97706"],["Resolved",Number(t.resolved||0),"#0f766e"]];
    $("csByStatus").innerHTML=total?`${st.map(([n,v,c])=>`<div class="cs-status-row"><span>${n}</span><div><i style="width:${Math.max(v?2:0,v/total*100)}%;background:${c}"></i></div><b>${v}</b><small>${Math.round(v/total*100)}%</small></div>`).join("")}<p class="cs-muted">Average ${t.avg_days_to_resolve==null?"—":`${num(t.avg_days_to_resolve)} days`} from received to resolved · ${Number(t.resolved_with_date)?`${Math.round(Number(t.resolved_on_time||0)/Number(t.resolved_with_date)*100)}% on time`:"none resolved yet"}</p>`:'<div class="finish-results-empty">No complaints in this period.</div>';
    $("csByCustomer").innerHTML=bars(r.by_customer,x=>x.customer_name,"complaints",{extra:x=>Number(x.open)?`${x.open} open`:""});
    const tables=["FINISH_TABLE_1","FINISH_TABLE_2","FINISH_TABLE_3"], cell=(tb,sh)=>Number((r.by_finish_table||[]).find(x=>x.table_code===tb&&x.shift_code===sh)?.complaints||0);
    const otherTables=[...new Set((r.by_finish_table||[]).map(x=>x.table_code).filter(x=>!tables.includes(x)))];
    $("csByTable").innerHTML=(r.by_finish_table||[]).length?`<table><thead><tr><th></th><th>Morning</th><th>Evening</th><th>Total</th></tr></thead><tbody>${[...tables,...otherTables].map(tb=>{const m=cell(tb,"MORNING"),e=cell(tb,"EVENING");return `<tr><th>${esc(tableName(tb))}</th><td class="${m?"hot":""}">${m}</td><td class="${e?"hot":""}">${e}</td><td><b>${m+e}</b></td></tr>`;}).join("")}</tbody></table>`:'<div class="finish-results-empty">No complaint linked to a Finish record in this period.</div>';
    $("csBySorting").innerHTML=bars(r.by_sorting_shift,x=>shiftName(x.shift_code),"complaints",{empty:"No complaint linked to a wash in this period."});
    $("csByOwner").innerHTML=(r.by_owner||[]).length?`<table><thead><tr><th>Person</th><th>Complaints</th><th>Open</th><th>Overdue</th><th>Resolved</th><th>On time</th></tr></thead><tbody>${r.by_owner.map(x=>`<tr><th>${esc(x.owner_name)}</th><td>${Number(x.complaints)}</td><td>${Number(x.open)}</td><td class="${Number(x.overdue)?"hot":""}">${Number(x.overdue||0)}</td><td>${Number(x.resolved)}</td><td>${Number(x.resolved)?`${Number(x.on_time||0)} of ${Number(x.resolved)}`:"—"}</td></tr>`).join("")}</tbody></table>`:'<div class="finish-results-empty">Nothing in this period.</div>';
    $("csByDepartment").innerHTML=(r.by_department||[]).length?`<table><thead><tr><th>Department</th><th>Tasks</th><th>Open</th><th>Overdue</th></tr></thead><tbody>${r.by_department.map(x=>`<tr><th>${esc(DEPARTMENTS[x.department_code]||x.department_code)}</th><td>${Number(x.tasks)}</td><td>${Number(x.open)}</td><td class="${Number(x.overdue)?"hot":""}">${Number(x.overdue)}</td></tr>`).join("")}</tbody></table>`:'<div class="finish-results-empty">No tasks in this period.</div>';
    setMessage(`Results from ${fmtDate(r.from)} to ${fmtDate(r.to)}.`,"success");
  }
  function setPreset(preset,reload=true){
    const t=today(); let from=t;
    if(preset==="month") from=`${t.slice(0,7)}-01`;
    else if(preset==="year") from=`${t.slice(0,4)}-01-01`;
    else from=addDays(t,-Number(preset)+1);
    $("csResultsFrom").value=from; $("csResultsTo").value=t;
    if(reload) loadResults().catch(err=>{ console.error(err); setMessage(errorText(err,"Results could not be loaded."),"error"); });
  }

  // Settings ----------------------------------------------------------------------------
  function renderSettings(){
    const canManage=me().can_manage, agents=state.ws?.agents||[];
    $("csSettingsNote").textContent=canManage?"":"Only the Customer Service manager can change these settings.";
    const owner=state.blockOwner||"";
    $("csBlockOwner").innerHTML=`<option value="">Choose a person…</option>${agents.map(a=>`<option value="${esc(a.auth_user_id)}">${esc(a.display_name)}</option>`).join("")}<option value="__remove">Remove the person (no one)</option>`;
    $("csBlockOwner").value=[...$("csBlockOwner").options].some(o=>o.value===owner)?owner:"";
    $("csBlockFilter").innerHTML=`<option value="">All customers</option><option value="__none">Without a person</option>${agents.map(a=>`<option value="${esc(a.auth_user_id)}">${esc(a.display_name)}</option>`).join("")}`;
    $("csBlockFilter").value=state.blockFilter||"";
    $("csBlockOwner").disabled=!canManage; $("csNewType").disabled=!canManage;
    $("csBlockSteps").hidden=!canManage||!agents.length;
    renderBlockPeople(); renderBlocks(); renderTypes();
    if(!agents.length&&canManage) $("csSettingsNote").textContent="Nobody has Customer Service access yet. Give the job title Customer Service to each person in Staff Master → Accounts & access, then come back to share the customers.";
  }
  function renderBlocks(){
    const q=$("csBlockSearch").value.trim().toLowerCase(), filter=state.blockFilter||"", canManage=me().can_manage;
    const rows=(state.ws?.customers||[]).filter(c=>(!q||`${c.customer_name} ${c.customer_code||""}`.toLowerCase().includes(q))&&(!filter||(filter==="__none"?!c.owner_auth_user_id:c.owner_auth_user_id===filter)));
    $("csBlocks").innerHTML=rows.length?`${canManage?`<label class="cs-block-all"><input type="checkbox" id="csBlockAll"${rows.every(c=>state.blockSelection.has(c.customer_id))?" checked":""}> Select the ${rows.length} customers shown</label>`:""}<div class="cs-block-grid">${rows.map(c=>`<label class="cs-block ${c.owner_auth_user_id?"":"none"}">${canManage?`<input type="checkbox" data-block="${esc(c.customer_id)}"${state.blockSelection.has(c.customer_id)?" checked":""}>`:""}<span><strong>${esc(c.customer_name)}</strong><small>${esc(c.customer_code||"")}</small></span><em>${esc(c.owner_name||"No person")}</em></label>`).join("")}</div>`:'<div class="finish-results-empty">No customers for this filter.</div>';
    updateBlockAssign();
  }
  // One card per person with their number of customers; clicking a card shows only those customers.
  function renderBlockPeople(){
    const customers=state.ws?.customers||[], agents=state.ws?.agents||[], filter=state.blockFilter||"";
    const count=(id)=>customers.filter(c=>id==="__none"?!c.owner_auth_user_id:c.owner_auth_user_id===id).length;
    const cards=[...agents.map(a=>({id:a.auth_user_id,name:a.display_name,n:count(a.auth_user_id)})),{id:"__none",name:"Without a person",n:count("__none")}];
    $("csBlockPeople").innerHTML=cards.map(p=>`<button type="button" class="cs-block-person ${p.id==="__none"?"none":""} ${filter===p.id?"active":""}" data-block-person="${esc(p.id)}"><strong>${esc(p.name)}</strong><span>${p.n} customer${p.n===1?"":"s"}</span></button>`).join("");
  }
  function updateBlockAssign(){
    const n=state.blockSelection.size, owner=$("csBlockOwner").value, canManage=me().can_manage;
    const name=$("csBlockOwner").selectedOptions[0]?.textContent||"";
    const label=!n?"Tick customers first":!owner?"Choose a person":owner==="__remove"?`Remove the person from ${n} customer${n===1?"":"s"}`:`Give ${n} customer${n===1?"":"s"} to ${name}`;
    $("csBlockAssign").textContent=label; $("csBlockAssign").disabled=!canManage||!n||!owner;
  }
  async function assignBlock(){
    const ids=[...state.blockSelection]; if(!ids.length){ setMessage("Select the customers first.","error"); return; }
    const choice=$("csBlockOwner").value; if(!choice){ setMessage("Choose the person in Give to.","error"); return; }
    const owner=choice==="__remove"?null:choice, name=$("csBlockOwner").selectedOptions[0]?.textContent||"";
    try{ const n=await rpc("set_customer_service_customer_owner_v1",{p_customer_ids:ids,p_owner_auth_user_id:owner}); state.blockSelection.clear(); await loadWorkspace(); renderSettings();
      setMessage(owner?`${n} customer${n===1?"":"s"} given to ${name}.`:`${n} customer${n===1?"":"s"} now without a person.`,"success"); }
    catch(err){ console.error(err); setMessage(errorText(err,"The customer block could not be saved."),"error"); }
  }
  function renderTypes(){
    const canManage=me().can_manage;
    $("csTypes").innerHTML=(state.ws?.types||[]).map(t=>`<article class="cs-item ${t.active?"":"inactive"}"><div><strong>${esc(t.type_name)}</strong>${t.active?"":chip("cancelled","Hidden")}<small>${esc(t.default_department_code?`Usually ${DEPARTMENTS[t.default_department_code]}`:"No usual department")} · order ${Number(t.sort_order)}</small></div>${canManage?`<div class="cs-item-actions"><button type="button" class="cs-button secondary" data-edit-type="${esc(t.type_code)}">Edit</button></div>`:""}</article>`).join("");
  }
  function openTypeForm(type=null){
    state.typeEdit=type;
    $("tyTitle").textContent=type?"Edit complaint type":"New complaint type";
    $("tyName").value=type?.type_name||""; $("tyDepartment").innerHTML=departmentOptions(type?.default_department_code||"",{blank:true});
    $("tyOrder").value=type?.sort_order??100; $("tyActive").checked=type?type.active:true;
    formMessage("tyMessage"); $("csTypeDialog").showModal(); $("tyName").focus();
  }
  async function saveType(event){
    event.preventDefault();
    try{
      const types=await rpc("save_customer_service_complaint_type_v1",{p_type_code:state.typeEdit?.type_code||null,p_type_name:$("tyName").value,p_default_department_code:$("tyDepartment").value||null,p_sort_order:Number($("tyOrder").value||100),p_active:$("tyActive").checked});
      state.ws.types=types||[]; $("csTypeDialog").close(); renderTypes(); setMessage("Complaint type saved.","success");
    }catch(err){ console.error(err); formMessage("tyMessage",errorText(err,"The complaint type could not be saved.")); }
  }

  // Events ------------------------------------------------------------------------------
  document.querySelectorAll("dialog [data-close]").forEach(b=>b.addEventListener("click",()=>b.closest("dialog").close()));
  $("csDetailDialog").addEventListener("close",()=>{ state.detail=null; state.trace=null; });
  window.addEventListener("hashchange",()=>showTab(currentTab()));
  $("csRefresh").addEventListener("click",()=>refreshAfterChange().then(()=>state.tab==="settings"&&renderSettings()));
  $("csNewComplaint").addEventListener("click",()=>openComplaintForm());
  $("csComplaintForm").addEventListener("submit",saveComplaint);
  $("csAlertForm").addEventListener("submit",saveAlert);
  $("csTaskForm").addEventListener("submit",saveTask);
  $("csAskForm").addEventListener("submit",confirmAsk);
  $("csTypeForm").addEventListener("submit",saveType);
  $("csNewAlert").addEventListener("click",()=>openAlertForm());
  $("csNewTask").addEventListener("click",()=>openTaskForm());
  $("csNewType").addEventListener("click",()=>openTypeForm());
  ["csFrom","csTo","csStatus","csOnlyMine"].forEach(id=>$(id).addEventListener("change",()=>loadComplaints().catch(err=>setMessage(errorText(err,"Complaints could not be loaded."),"error"))));
  $("csSearch").addEventListener("input",renderComplaints);
  $("cfSaveAnother").addEventListener("click",()=>saveComplaint(null,{another:true}));
  document.querySelectorAll('input[name="cfSeverity"]').forEach(i=>i.addEventListener("change",updateDueHint));
  $("cfReceived").addEventListener("change",updateDueHint);
  ["input","change"].forEach(type=>$("cfCustomer").addEventListener(type,updateCustomerOpen));
  $("csCounts").addEventListener("click",(event)=>{ const card=event.target.closest("[data-quick]"); if(card) setQuick(card.dataset.quick); });
  $("csCounts").addEventListener("keydown",(event)=>{ const card=event.target.closest("[data-quick]"); if(card&&(event.key==="Enter"||event.key===" ")){ event.preventDefault(); setQuick(card.dataset.quick); } });
  $("csComplaints").addEventListener("keydown",(event)=>{ const row=event.target.closest(".cs-crow"); if(row&&event.target===row&&(event.key==="Enter"||event.key===" ")){ event.preventDefault(); openDetail(row.dataset.openComplaint); } });
  $("csAlertsEnded").addEventListener("change",()=>loadAlerts().catch(err=>setMessage(errorText(err,"Alerts could not be loaded."),"error")));
  $("ctPerson").addEventListener("input",personHint);
  ["csTaskStatus","csTaskDepartment","csTaskPerson"].forEach(id=>$(id).addEventListener("change",()=>loadTasks().catch(err=>setMessage(errorText(err,"Tasks could not be loaded."),"error"))));
  ["csResultsFrom","csResultsTo"].forEach(id=>$(id).addEventListener("change",()=>loadResults().catch(err=>setMessage(errorText(err,"Results could not be loaded."),"error"))));
  document.querySelectorAll("[data-preset]").forEach(b=>b.addEventListener("click",()=>setPreset(b.dataset.preset)));
  $("csBlockSearch").addEventListener("input",renderBlocks);
  $("csBlockFilter").addEventListener("change",()=>{ state.blockFilter=$("csBlockFilter").value; renderBlockPeople(); renderBlocks(); });
  $("csBlockPeople").addEventListener("click",(event)=>{ const card=event.target.closest("[data-block-person]"); if(!card) return;
    state.blockFilter=state.blockFilter===card.dataset.blockPerson?"":card.dataset.blockPerson; $("csBlockFilter").value=state.blockFilter; renderBlockPeople(); renderBlocks(); });
  $("csBlockOwner").addEventListener("change",()=>{ state.blockOwner=$("csBlockOwner").value; updateBlockAssign(); });
  $("csBlockAssign").addEventListener("click",assignBlock);
  $("csBlocks").addEventListener("change",(event)=>{
    const box=event.target.closest("input[data-block]");
    if(box){ box.checked?state.blockSelection.add(box.dataset.block):state.blockSelection.delete(box.dataset.block); updateBlockAssign(); return; }
    if(event.target.id==="csBlockAll"){ document.querySelectorAll("#csBlocks input[data-block]").forEach(i=>{ i.checked=event.target.checked; i.checked?state.blockSelection.add(i.dataset.block):state.blockSelection.delete(i.dataset.block); }); updateBlockAssign(); }
  });
  $("cdBody").addEventListener("change",(event)=>{ if(event.target.matches('#cdTrace input[type="radio"]')) syncFlowHighlight(); });
  $("cdBody").addEventListener("keydown",(event)=>{ if(event.key==="Enter"&&event.target.id==="cdNote"){ event.preventDefault(); detailAction("note"); } });
  document.addEventListener("click",(event)=>{
    const quickResolve=event.target.closest("[data-quick-resolve]"); if(quickResolve){ const c=state.complaints.find(x=>x.complaint_id===quickResolve.dataset.quickResolve); if(c) resolveComplaint(c); return; }
    const newFor=event.target.closest("[data-new-for]"); if(newFor){ openComplaintForm(null,{customerId:newFor.dataset.newFor}); return; }
    const open=event.target.closest("[data-open-complaint]"); if(open){ openDetail(open.dataset.openComplaint); return; }
    const act=event.target.closest("[data-detail-action]"); if(act){ detailAction(act.dataset.detailAction); return; }
    const editAlert=event.target.closest("[data-edit-alert]"); if(editAlert){ const a=findAlert(editAlert.dataset.editAlert); if(a) openAlertForm(a); return; }
    const end=event.target.closest("[data-end-alert]"); if(end){ endAlert(end.dataset.endAlert); return; }
    const editTask=event.target.closest("[data-edit-task]"); if(editTask){ const t=findTask(editTask.dataset.editTask); if(t) openTaskForm(t); return; }
    const taskStatus=event.target.closest("[data-task-status]"); if(taskStatus){ setTaskStatus(taskStatus.dataset.task,taskStatus.dataset.taskStatus); return; }
    const editType=event.target.closest("[data-edit-type]"); if(editType){ openTypeForm((state.ws?.types||[]).find(t=>t.type_code===editType.dataset.editType)); }
  });

  // Start ------------------------------------------------------------------------------
  try{
    if(window.ELIS_SUPABASE_ERROR||!client) throw new Error(window.ELIS_SUPABASE_ERROR||"Supabase could not be initialized.");
    const {data:{session},error}=await client.auth.getSession(); if(error) throw error;
    if(!session?.user){ location.href="../index.html"; return; }
    await loadWorkspace();
    $("csTaskDepartment").innerHTML=`<option value="">All departments</option>${departmentOptions("")}`;
    $("csTo").value=today(); $("csFrom").value=addDays(today(),-30);
    $("csOnlyMine").closest("label").hidden=me().scope!=="ALL";
    showTab(currentTab());
  }catch(err){
    console.error(err);
    setMessage(err?.code==="42501"?"This account has no Customer Service access. Ask the administrator to give you the Customer Service permission.":errorText(err,"Customer Service could not be opened."),"error");
    document.querySelectorAll(".cs-view,.cs-tabs,#csCounts").forEach(el=>{ el.hidden=true; });
    $("csNewComplaint").disabled=true;
  }
});
