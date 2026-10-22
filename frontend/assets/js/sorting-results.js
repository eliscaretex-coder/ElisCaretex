"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const el = {
    date:$("sortingResultsDate"), prev:$("sortingResultsPrev"), next:$("sortingResultsNext"), today:$("sortingResultsToday"), refresh:$("sortingResultsRefresh"),
    message:$("sortingResultsMessage"), totals:$("sortingResultsTotals"), shifts:$("sortingResultsShifts"), staff:$("sortingResultsStaff"), targets:$("sortingResultsTargets"), runs:$("sortingResultsRuns"), count:$("sortingResultsRunCount")
  };
  const esc=(v)=>String(v??"").replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&#039;");
  const shiftName=(code)=>String(code||"").toUpperCase()==="EVENING"?"Evening":"Morning";
  const modeName=(code)=>({MOP:"MOP",CLOTHES:"Clothes"}[String(code||"").toUpperCase()]||code||"—");
  const typeName=(code)=>({MOP:"MOP",CLOTHES:"Clothes",OTHERS:"Others"}[String(code||"").toUpperCase()]||code||"—");
  const safeRouteColor=(v)=>{const raw=String(v||"").trim(),m=raw.match(/^#?([0-9a-fA-F]{6})$/);return m?`#${m[1]}`:"#0f766e";};
  const fmtTime=(v)=>v?new Intl.DateTimeFormat("en-IE",{hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"Europe/Dublin"}).format(new Date(v)):"—";
  const fmtDate=(v)=>v?new Intl.DateTimeFormat("en-IE",{day:"2-digit",month:"short",year:"numeric",timeZone:"Europe/Dublin"}).format(new Date(`${String(v).slice(0,10)}T12:00:00Z`)):"—";
  const dublinDateKey=()=>{const parts=new Intl.DateTimeFormat("en-CA",{timeZone:"Europe/Dublin",year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(new Date()),m=Object.fromEntries(parts.map(p=>[p.type,p.value]));return `${m.year}-${m.month}-${m.day}`;};
  const efficiencyClass=(v)=>v==null?"":Number(v)>=100?"good":Number(v)>=75?"mid":"low";
  async function rpc(name,args={}){const {data,error}=await client.rpc(name,args);if(error)throw error;return data;}
  function setMessage(text="",type=""){el.message.textContent=text;el.message.className=`finish-results-message ${type}`.trim();}
  function num(v,d=1){return Number(v||0).toFixed(d);}
  function percent(v){return v==null?"—":`${Number(v).toFixed(1)}%`;}
  function hours(minutes){const m=Math.round(Number(minutes||0));return `${Math.floor(m/60)}h${String(m%60).padStart(2,"0")}`;}

  // One line that explains where the hours came from, so staff movements are visible.
  function statusInfo(s){
    const moved=s.moved_to?`${esc(s.moved_to)}${s.moved_at?` at ${esc(s.moved_at)}`:""}`:"";
    switch(s.status){
      case "ACTUAL":return {cls:"actual",label:s.imported?"Recorded":"Actual",detail:`${esc(s.actual_start||"—")}–${esc(s.actual_end||"—")}${s.uses_planned_time?" · planned time used":""}`};
      case "PARTIAL_MOVE":return {cls:"partial",label:"Part shift",detail:`Sorting ${esc(s.actual_start||"—")}–${esc(s.actual_end||"—")} · then ${moved||"another area"}`};
      case "AS_PLANNED":return {cls:"planned",label:"As planned",detail:esc(s.planned_label||"Planned shift")};
      case "ABSENT":return {cls:"absent",label:"Absent",detail:esc(s.absence_reason||"Confirmed absence")};
      case "AUTO_ABSENT":return {cls:"absent",label:"No-show",detail:"No wash activity in the shift"};
      case "MOVED":return {cls:"moved",label:"Moved",detail:`Whole shift in ${moved||"another area"}`};
      case "NO_HOURS":return {cls:"nohours",label:"No hours",detail:"Washes recorded, not planned in Sorting"};
      default:return {cls:"",label:s.status||"—",detail:""};
    }
  }

  // Loads and kg per wash type; Others only appear when a day actually has them.
  function loadsBox(label,loads,kg,cls=""){return `<span class="sorting-results-loads ${cls}"><small>${label}</small><strong>${Number(loads||0)} loads</strong><em>${num(kg)} kg</em></span>`;}
  function typeBoxes(x){return loadsBox("Clothes",x.clothes_loads,x.clothes_kg,"clothes")+loadsBox("MOP",x.mop_loads,x.mop_kg,"mop")+(Number(x.others_loads||0)?loadsBox("Others",x.others_loads,x.others_kg,"others"):"");}

  function renderTotals(data){
    const t=data.total||{};
    el.totals.innerHTML=`
      <article class="produced"><span>Washed</span><strong>${num(t.produced_kg)} kg</strong><small>${Number(t.total_loads||0)} loads</small></article>
      <article><span>Clothes</span><strong>${Number(t.clothes_loads||0)} loads</strong><small>${num(t.clothes_kg)} kg${Number(t.others_loads||0)?` · Others ${Number(t.others_loads)} loads, ${num(t.others_kg)} kg`:""}</small></article>
      <article><span>MOP</span><strong>${Number(t.mop_loads||0)} loads</strong><small>${num(t.mop_kg)} kg</small></article>
      <article class="${efficiencyClass(t.efficiency_percent)}"><span>Efficiency</span><strong>${percent(t.efficiency_percent)}</strong><small>${num(t.kg_per_staff_hour)} kg per staff hour</small></article>
      <article class="planned"><span>Staff hours</span><strong>${num(t.staff_hours,2)}</strong><small>${Number(t.staff_count||0)} staff · ${Number(t.absent_count||0)} absent · ${Number(t.moved_count||0)+Number(t.partial_move_count||0)} moved</small></article>`;
  }

  function renderShifts(data){
    const by=new Map((data.shifts||[]).map(x=>[String(x.shift_code||"").toUpperCase(),x]));
    el.shifts.innerHTML=["MORNING","EVENING"].map(code=>{const s=by.get(code)||{};return `<article class="finish-results-shift-card ${efficiencyClass(s.efficiency_percent)}"><header><strong>${shiftName(code)}</strong><b>${percent(s.efficiency_percent)}</b></header><div class="sorting-results-shift-loads">${typeBoxes(s)}${loadsBox("Total",s.total_loads,s.produced_kg,"total")}</div><footer>${num(s.kg_per_staff_hour)} kg per staff hour · ${num(s.staff_hours,2)} staff hours · ${Number(s.staff_count||0)} staff${Number(s.absent_count||0)?` · ${Number(s.absent_count)} absent`:""}${Number(s.moved_count||0)?` · ${Number(s.moved_count)} moved`:""}${Number(s.partial_move_count||0)?` · ${Number(s.partial_move_count)} part shift`:""}</footer></article>`;}).join("");
  }

  function renderStaff(data){
    const t=data.targets||{};
    el.targets.textContent=`Targets: Clothes ${num(t.clothes_kg_per_staff_hour,0)} kg/h · MOP ${num(t.mop_kg_per_staff_hour,0)} kg/h`;
    const rows=data.staff||[];
    if(!rows.length){el.staff.innerHTML='<div class="finish-results-empty">No Sorting staff for this date.</div>';return;}
    el.staff.innerHTML=`<div class="sorting-results-staff-head"><span>Staff</span><span>Shift / mode</span><span>Time</span><span>Hours</span><span>Clothes</span><span>MOP</span><span>kg / h</span><span>Efficiency</span></div>${rows.map(s=>{const info=statusInfo(s),clothesKg=Number(s.clothes_kg||0)+Number(s.others_kg||0),clothesLoads=Number(s.clothes_loads||0)+Number(s.others_loads||0);return `<article class="sorting-results-staff-row ${efficiencyClass(s.efficiency_percent)} ${info.cls}"><div><strong>${esc(s.display_name)}</strong><small><em class="sorting-results-chip ${info.cls}">${esc(info.label)}</em></small></div><div><strong>${esc(shiftName(s.shift_code))}</strong><small>${esc(modeName(s.work_mode))}</small></div><div class="sorting-results-time">${info.detail}${s.status!=="AS_PLANNED"&&s.planned_label?`<small>Planned ${esc(s.planned_label)}</small>`:""}</div><b>${Number(s.worked_minutes||0)>0?hours(s.worked_minutes):"—"}</b><span>${clothesKg>0?`${num(clothesKg)} kg<small>${clothesLoads} loads</small>`:"—"}</span><span>${Number(s.mop_kg||0)>0?`${num(s.mop_kg)} kg<small>${Number(s.mop_loads||0)} loads</small>`:"—"}</span><span>${s.kg_per_staff_hour==null?"—":num(s.kg_per_staff_hour)}</span><b class="sorting-results-eff">${percent(s.efficiency_percent)}</b></article>`;}).join("")}`;
  }

  function renderRuns(data){
    const rows=data.runs||[];
    el.count.textContent=String(rows.length);
    if(!rows.length){el.runs.innerHTML='<div class="finish-results-empty">No washes recorded on this Business Date.</div>';return;}
    el.runs.innerHTML=`<div class="sorting-results-run-head"><span>Time</span><span>Washer</span><span>Type</span><span>Weight</span><span>Customers</span><span>Operator</span></div>${rows.map(r=>{const customers=(r.customers||[]).map(c=>`<span class="finish-results-batch" style="border-left:4px solid ${safeRouteColor(c.route_color)}"><b>${esc(c.customer_name||"Customer")}</b>${c.route_code?`<em>${esc(c.route_code)}</em>`:""}</span>`).join("")||"—";return `<article class="sorting-results-run ${String(r.wash_type||"").toLowerCase()}"><time>${esc(fmtTime(r.registered_at))}<small>${esc(shiftName(r.shift_code))}</small></time><div><strong>${esc(r.washer_name||"—")}</strong></div><span class="sorting-results-type">${esc(typeName(r.wash_type))}</span><b>${num(r.total_weight_kg)} kg</b><div class="finish-results-batches">${customers}</div><div><strong>${esc(r.operator_name)}</strong></div></article>`;}).join("")}`;
  }

  function render(data){
    if(data?.schema_version!=="SORTING_RESULTS_V1")throw new Error("Sorting Results backend is out of date. Refresh after the latest update.");
    el.date.value=String(data.business_date||"").slice(0,10);
    document.title=`Sorting Results · ${fmtDate(data.business_date)} | ElisCaretex`;
    renderTotals(data);renderShifts(data);renderStaff(data);renderRuns(data);
  }

  async function load(dateValue=null){
    setMessage("Loading Sorting Results…");el.refresh.disabled=true;
    try{const data=await rpc("get_sorting_results_dashboard_v1",{p_business_date:dateValue||null});render(data);setMessage(`Results loaded · ${fmtDate(data.business_date)}`,"success");}
    catch(err){console.error(err);setMessage(err.message||"Sorting Results could not be loaded.","error");}
    finally{el.refresh.disabled=false;}
  }
  function moveDate(days){const value=el.date.value||dublinDateKey(),d=new Date(`${value}T12:00:00Z`);d.setUTCDate(d.getUTCDate()+days);el.date.value=d.toISOString().slice(0,10);load(el.date.value);}

  el.prev.addEventListener("click",()=>moveDate(-1));el.next.addEventListener("click",()=>moveDate(1));
  el.today.addEventListener("click",()=>load(null));el.refresh.addEventListener("click",()=>load(el.date.value||null));el.date.addEventListener("change",()=>load(el.date.value||null));
  try{if(window.ELIS_SUPABASE_ERROR||!client)throw new Error(window.ELIS_SUPABASE_ERROR||"Supabase could not be initialized.");const {data:{session},error}=await client.auth.getSession();if(error)throw error;if(!session?.user){location.href="../index.html";return;}await load(null);}catch(err){console.error(err);setMessage(err.message||"Sorting Results could not be initialized.","error");}
});
