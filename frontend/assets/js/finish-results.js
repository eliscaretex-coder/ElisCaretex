"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const el = {
    date:$("finishResultsDate"), prev:$("finishResultsPrev"), next:$("finishResultsNext"), today:$("finishResultsToday"), refresh:$("finishResultsRefresh"),
    message:$("finishResultsMessage"), totals:$("finishResultsTotals"), shifts:$("finishResultsShifts"), matrix:$("finishResultsMatrix"), entries:$("finishResultsEntries"), count:$("finishResultsEntryCount")
  };
  const esc=(v)=>String(v??"").replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&#039;");
  const tableName=(code)=>({FINISH_TABLE_1:"Table 1",FINISH_TABLE_2:"Table 2",FINISH_TABLE_3:"Table 3"}[code]||code||"—");
  const shiftName=(code)=>String(code||"").toUpperCase()==="EVENING"?"Evening":"Morning";
  const safeRouteColor=(v)=>{const raw=String(v||"").trim(),m=raw.match(/^#?([0-9a-fA-F]{6})$/);return m?`#${m[1]}`:"#0f766e";};
  const routeTextColor=(hex)=>{const m=/^#([0-9a-f]{6})$/i.exec(String(hex||""));if(!m)return"#fff";const n=parseInt(m[1],16),r=(n>>16)&255,g=(n>>8)&255,b=n&255;return ((.299*r+.587*g+.114*b)/255)>.62?"#111827":"#fff";};
  const fmtTime=(v)=>v?new Intl.DateTimeFormat("en-IE",{hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"Europe/Dublin"}).format(new Date(v)):"—";
  const fmtDate=(v)=>v?new Intl.DateTimeFormat("en-IE",{day:"2-digit",month:"short",year:"numeric",timeZone:"Europe/Dublin"}).format(new Date(`${String(v).slice(0,10)}T12:00:00Z`)):"—";
  const dublinDateKey=()=>{const parts=new Intl.DateTimeFormat("en-CA",{timeZone:"Europe/Dublin",year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(new Date()),m=Object.fromEntries(parts.map(p=>[p.type,p.value]));return `${m.year}-${m.month}-${m.day}`;};
  const efficiencyClass=(v)=>Number(v)>=100?"good":Number(v)>=75?"mid":"low";
  async function rpc(name,args={}){const {data,error}=await client.rpc(name,args);if(error)throw error;return data;}
  function setMessage(text="",type=""){el.message.textContent=text;el.message.className=`finish-results-message ${type}`.trim();}
  function num(v,d=1){return Number(v||0).toFixed(d);}
  function percent(v){return `${Number(v||0).toFixed(1)}%`;}

  function renderTotals(data){
    const t=data.total||{},target=Number(data.target_kg_per_staff_hour||23.5);
    el.totals.innerHTML=`
      <article class="produced"><span>Produced</span><strong>${num(t.produced_kg)} kg equivalent</strong><small>${num(t.recorded_kg)} kg recorded + ${Math.round(Number(t.produced_units||0))} units (${num(t.units_kg_equivalent)} kg converted)</small></article>
      <article class="planned"><span>Planned</span><strong>${num(t.planned_kg)} kg</strong><small>${num(t.staff_hours,2)} staff hours × ${target.toFixed(1)}</small></article>
      <article class="${efficiencyClass(t.efficiency_percent)}"><span>Efficiency</span><strong>${percent(t.efficiency_percent)}</strong><small>${num(t.missing_kg)} kg missing to plan</small></article>
      <article><span>Staff hours</span><strong>${num(t.staff_hours,2)}</strong><small>${Number(t.staff_count||0)} staff</small></article>
      <article><span>Contributions</span><strong>${Number(t.contribution_count||0)}</strong><small>${(data.entries||[]).length} active records</small></article>`;
    if(data.rewash_separate_metric_supported)el.totals.insertAdjacentHTML("beforeend",`<article class="rewash"><span>ReWash</span><strong>${num(t.rewash_kg)} kg</strong><small>Included in Produced</small></article>`);
  }

  function renderShifts(data){
    const by=new Map((data.shifts||[]).map(x=>[String(x.shift_code||"").toUpperCase(),x]));
    el.shifts.innerHTML=["MORNING","EVENING"].map(code=>{const s=by.get(code)||{};return `<article class="finish-results-shift-card ${efficiencyClass(s.efficiency_percent)}"><header><strong>${shiftName(code)}</strong><b>${percent(s.efficiency_percent)}</b></header><div class="finish-results-shift-main"><span><small>Produced</small><strong>${num(s.produced_kg)} kg</strong></span><span class="rewash"><small>ReWash</small><strong>${num(s.rewash_kg)} kg</strong></span><span><small>Planned</small><strong>${num(s.planned_kg)} kg</strong></span><span><small>Missing</small><strong>${num(s.missing_kg)} kg</strong></span></div><footer>${num(s.staff_hours,2)} staff hours · ${Number(s.staff_count||0)} staff</footer></article>`;}).join("");
  }

  function renderMatrix(data){
    const rows=(data.tables||[]).slice().sort((a,b)=>(String(a.shift_code)==="MORNING"?0:1)-(String(b.shift_code)==="MORNING"?0:1)||String(a.table_code).localeCompare(String(b.table_code)));
    if(!rows.length){el.matrix.innerHTML='<div class="finish-results-empty">No Table results for this date.</div>';return;}
    el.matrix.innerHTML=`<div class="finish-results-matrix-head"><span>Table</span><span>Shift</span><span>Produced</span><span>ReWash</span><span>Planned</span><span>Efficiency</span><span>Staff hours</span><span>Staff</span></div>${rows.map(r=>`<article class="finish-results-matrix-row ${efficiencyClass(r.efficiency_percent)}"><strong>${esc(r.table_name||tableName(r.table_code))}</strong><span>${esc(shiftName(r.shift_code))}</span><b>${num(r.produced_kg)} kg</b><span class="rewash">${num(r.rewash_kg)} kg</span><span>${num(r.planned_kg)} kg</span><b>${percent(r.efficiency_percent)}</b><span>${num(r.staff_hours,2)}</span><span>${Number(r.staff_count||0)}</span></article>`).join("")}`;
  }

  function batchHtml(entry){
    if(String(entry?.entry_type||"").toUpperCase()==="REWASH")return (entry.lines||[]).map(line=>`<span class="finish-results-batch finish-results-rewash-line"><b>${esc(line.customer_name||"Customer")}</b><em>${esc(line.batch_reference||"No batch")} · ${Number(line.quantity||0).toFixed(1)} kg</em></span>`).join("")||"—";
    const groups=new Map();(entry.lines||[]).forEach(line=>{const batch=String(line.batch_reference||"—");if(!groups.has(batch))groups.set(batch,{kg:0,units:0});const g=groups.get(batch),n=Number(line.quantity||0);if(line.unit_code==="KG")g.kg+=n;else if(line.unit_code==="UNIT")g.units+=n;});
    return [...groups.entries()].map(([batch,g])=>`<span class="finish-results-batch"><b>${esc(batch)}</b><em>${g.kg>0?`${g.kg.toFixed(1)} kg`:""}${g.kg>0&&g.units>0?" · ":""}${g.units>0?`${Math.round(g.units)} u`:""}</em></span>`).join("")||"—";
  }

  function renderEntries(data){
    const rows=(data.entries||[]).slice().sort((a,b)=>Number(a.production_order??999999)-Number(b.production_order??999999)||String(a.route_code||"").localeCompare(String(b.route_code||""))||new Date(a.recorded_at||0)-new Date(b.recorded_at||0));
    el.count.textContent=String(rows.length);
    if(!rows.length){el.entries.innerHTML='<div class="finish-results-empty">No customers processed on this Business Date.</div>';return;}
    el.entries.innerHTML=`<div class="finish-results-entry-head"><span>Priority</span><span>Customer / Route</span><span>Table / Shift</span><span>Batch / quantity</span><span>Processed by</span><span>Time</span></div>${rows.map(e=>{const color=safeRouteColor(e.route_color),fg=routeTextColor(color),trolley=(e.trolley_codes||[]).length?(e.trolley_codes||[]).join(", "):String(e.trolley_scan_status||"")==="PENDING"?"Trolley pending":"—";return `<article class="finish-results-entry" style="--route-color:${color};--route-fg:${fg}"><strong class="finish-results-priority">${esc(e.production_order??"—")}</strong><div class="finish-results-customer"><strong>${esc(e.customer_name)}</strong><small><b>${esc(e.route_code||"—")}</b>${esc(e.route_name||"")}</small></div><div><strong>${esc(e.table_name||tableName(e.table_code))}</strong><small>${esc(shiftName(e.shift_code))}</small></div><div class="finish-results-batches">${batchHtml(e)}</div><div><strong>${esc(e.processed_by||"Not recorded")}</strong><small>Recorded by ${esc(e.recorded_by||"—")} · ${esc(trolley)}</small></div><time>${esc(fmtTime(e.recorded_at))}</time></article>`;}).join("")}`;
  }

  function render(data){
    if(data?.schema_version!=="FINISH_RESULTS_V2")throw new Error("Finish Results backend is out of date. Refresh after the latest update.");
    el.date.value=String(data.business_date||"").slice(0,10);
    document.title=`Finish Results · ${fmtDate(data.business_date)} | ElisCaretex`;
    renderTotals(data);renderShifts(data);renderMatrix(data);renderEntries(data);
  }

  async function load(dateValue=null){
    setMessage("Loading Finish Results…");el.refresh.disabled=true;
    try{const data=await rpc("get_finish_results_dashboard",{p_business_date:dateValue||null});render(data);setMessage(`Results loaded · ${fmtDate(data.business_date)}`,"success");}
    catch(err){console.error(err);setMessage(err.message||"Finish Results could not be loaded.","error");}
    finally{el.refresh.disabled=false;}
  }
  function moveDate(days){const value=el.date.value||dublinDateKey(),d=new Date(`${value}T12:00:00Z`);d.setUTCDate(d.getUTCDate()+days);el.date.value=d.toISOString().slice(0,10);load(el.date.value);}

  el.prev.addEventListener("click",()=>moveDate(-1));el.next.addEventListener("click",()=>moveDate(1));
  el.today.addEventListener("click",()=>load(null));el.refresh.addEventListener("click",()=>load(el.date.value||null));el.date.addEventListener("change",()=>load(el.date.value||null));
  try{if(window.ELIS_SUPABASE_ERROR||!client)throw new Error(window.ELIS_SUPABASE_ERROR||"Supabase could not be initialized.");const {data:{session},error}=await client.auth.getSession();if(error)throw error;if(!session?.user){location.href="../index.html";return;}await load(null);}catch(err){console.error(err);setMessage(err.message||"Finish Results could not be initialized.","error");}
});
