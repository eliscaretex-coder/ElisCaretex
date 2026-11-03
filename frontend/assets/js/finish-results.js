"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;
  const $ = (id) => document.getElementById(id);
  const el = {
    date:$("finishResultsDate"), prev:$("finishResultsPrev"), next:$("finishResultsNext"), today:$("finishResultsToday"), refresh:$("finishResultsRefresh"),
    message:$("finishResultsMessage"), totals:$("finishResultsTotals"), shifts:$("finishResultsShifts"), matrix:$("finishResultsMatrix"), staff:$("finishResultsStaff"), staffCount:$("finishResultsStaffCount"), entries:$("finishResultsEntries"), count:$("finishResultsEntryCount"),
    trolleyPeriod:$("finishResultsTrolleyPeriod"), trolley:$("finishResultsTrolley"),
    ranking:$("finishRanking"), rankingTitle:$("finishRankingTitle"), rankingPeriod:$("finishRankingPeriod"), rankingPrev:$("finishRankingPrev"), rankingNext:$("finishRankingNext")
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

  // Every person and time slice behind the staff hours, so moves and table changes can be checked.
  function renderStaff(data){
    const rows=data.staff||[];
    el.staffCount.textContent=String(new Set(rows.map(r=>`${r.shift_code}|${r.staff_id}`)).size);
    if(!rows.length){el.staff.innerHTML='<div class="finish-results-empty">No Finish staff hours for this date.</div>';return;}
    const sourceText=(r)=>r.hours_source==="PLANNED"?"Planned (no Actual)":r.session_source==="SORTING_TO_FINISH_TRANSFER"?"Moved from Sorting":r.session_source==="APPS_SCRIPT_IMPORT"?"Recorded":r.uses_planned_time?"Actual · planned time used":"Actual";
    el.staff.innerHTML=`<div class="finish-results-staff-head"><span>Staff</span><span>Table / Shift</span><span>Time</span><span>Hours</span><span>Source</span></div>${rows.map(r=>`<article class="finish-results-staff-row ${r.hours_source==="PLANNED"?"planned":""}"><strong>${esc(r.display_name)}</strong><span>${esc(r.table_name||tableName(r.table_code))} · ${esc(shiftName(r.shift_code))}</span><span>${esc(r.start_time||"—")}–${esc(r.end_time||"—")}</span><b>${num(r.staff_hours,2)}</b><small>${esc(sourceText(r))}</small></article>`).join("")}`;
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
    el.entries.innerHTML=`<div class="finish-results-entry-head"><span>Priority</span><span>Customer / Route</span><span>Table / Shift</span><span>Batch / quantity</span><span>Processed by</span><span>Time</span></div>${rows.map(e=>{const color=safeRouteColor(e.route_color),fg=routeTextColor(color),trolley=(e.trolley_codes||[]).length?(e.trolley_codes||[]).join(", "):String(e.trolley_scan_status||"")==="PENDING"?"Trolley pending":"—",trolleyError=String(e.trolley_scan_status||"")==="MISMATCH";return `<article class="finish-results-entry${trolleyError?" trolley-error":""}" style="--route-color:${color};--route-fg:${fg}"><strong class="finish-results-priority">${esc(e.production_order??"—")}</strong><div class="finish-results-customer"><strong>${esc(e.customer_name)}</strong><small><b>${esc(e.route_code||"—")}</b>${esc(e.route_name||"")}</small>${trolleyError?'<span class="finish-results-trolley-flag">⚠ Wrong trolley qty/size</span>':""}</div><div><strong>${esc(e.table_name||tableName(e.table_code))}</strong><small>${esc(shiftName(e.shift_code))}</small></div><div class="finish-results-batches">${batchHtml(e)}</div><div><strong>${esc(e.processed_by||"Not recorded")}</strong><small>Recorded by ${esc(e.recorded_by||"—")} · ${esc(trolley)}</small></div><time>${esc(fmtTime(e.recorded_at))}</time></article>`;}).join("")}`;
  }

  // Trolley errors: Finish records saved with "Use with mismatch", counted per person, Table and Shift.
  function trolleyGroupHtml(title,rows,nameOf,empty="No checked trolleys."){
    if(!rows.length)return `<div class="finish-results-trolley-group"><h3>${esc(title)}</h3><div class="finish-results-empty">${esc(empty)}</div></div>`;
    return `<div class="finish-results-trolley-group"><h3>${esc(title)}</h3><div class="finish-results-trolley-head"><span></span><span>Errors</span><span>Checked</span><span>%</span></div>${rows.map(r=>`<article class="finish-results-trolley-row${Number(r.error_count||0)>0?" has-errors":""}"><strong>${esc(nameOf(r))}</strong><b>${Number(r.error_count||0)}</b><span>${Number(r.checked_count||0)}</span><span>${percent(r.error_percent)}</span></article>`).join("")}</div>`;
  }
  function renderTrolleyErrors(data){
    if(data?.schema_version!=="FINISH_TROLLEY_ERRORS_V1")throw new Error("Trolley error backend is out of date. Refresh after the latest update.");
    const t=data.total||{},period=data.date_from===data.date_to?fmtDate(data.date_to):`${fmtDate(data.date_from)} – ${fmtDate(data.date_to)}`;
    const staff=(data.by_staff||[]).filter(r=>Number(r.error_count||0)>0||Number(r.plan_reported_count||0)>0);
    const summary=`<div class="finish-results-trolley-summary"><article class="${Number(t.error_count||0)>0?"bad":"good"}"><span>Trolley errors</span><strong>${Number(t.error_count||0)}</strong><small>${percent(t.error_percent)} of ${Number(t.checked_count||0)} checked · ${esc(period)}</small></article><article><span>Still wrong</span><strong>${Number(t.still_wrong_count||0)}</strong><small>${Number(t.fixed_later_count||0)} fixed later with Edit</small></article><article><span>Plan reported</span><strong>${Number(t.plan_reported_count||0)}</strong><small>Not counted: team reported the published plan as wrong</small></article></div>`;
    const groups=`<div class="finish-results-trolley-groups">${trolleyGroupHtml("By person",staff,r=>r.display_name||"Not recorded","No one saved a wrong trolley.")}${trolleyGroupHtml("By Table",data.by_table||[],r=>r.table_name||tableName(r.table_code))}${trolleyGroupHtml("By Shift",data.by_shift||[],r=>shiftName(r.shift_code))}</div>`;
    const entries=data.entries||[];
    const list=entries.length?`<div class="finish-results-trolley-entries"><h3>Records with wrong trolley</h3>${entries.map(e=>{const color=safeRouteColor(e.route_color),fg=routeTextColor(color),state=e.plan_reported?'<em class="reported">Plan reported</em>':e.still_wrong?'<em class="wrong">Still wrong</em>':'<em class="fixed">Fixed later</em>';return `<article style="--route-color:${color};--route-fg:${fg}"><div class="finish-results-trolley-customer"><strong>${esc(e.customer_name)}</strong><small><b>${esc(e.route_code||"—")}</b>${esc(fmtDate(e.business_date))} · ${esc(fmtTime(e.recorded_at))}</small></div><div><strong>${esc(e.processed_by||"Not recorded")}</strong><small>${esc(e.table_name||tableName(e.table_code))} · ${esc(shiftName(e.shift_code))}</small></div><div><strong>Planned ${esc(e.planned_summary||"—")}</strong><small>Scanned ${esc(e.scanned_summary||"None")}${(e.scanned_codes||[]).length?` · ${esc(e.scanned_codes.join(", "))}`:""}</small></div>${state}</article>`;}).join("")}</div>`:"";
    el.trolley.innerHTML=summary+groups+list;
  }
  async function loadTrolleyErrors(dateValue){
    if(!el.trolley)return;
    const days=Math.max(1,Number(el.trolleyPeriod?.value||1)),to=new Date(`${dateValue}T12:00:00Z`),from=new Date(to);from.setUTCDate(from.getUTCDate()-(days-1));
    try{renderTrolleyErrors(await rpc("get_finish_trolley_errors_v1",{p_date_from:from.toISOString().slice(0,10),p_date_to:dateValue}));}
    catch(err){console.error(err);el.trolley.innerHTML=`<div class="finish-results-empty">${esc(err.message||"Trolley errors could not be loaded.")}</div>`;}
  }


  // Ranking: closed week or month, Table x Shift teams (or Tables), score = efficiency - trolley penalty.
  const ranking={period:"WEEK",level:"TEAM",anchor:null,data:null,req:0};
  const ordinal=(n)=>{const v=n%100;return n+(v>=11&&v<=13?"th":({1:"st",2:"nd",3:"rd"}[n%10]||"th"));};
  const teamName=(r)=>r.shift_code?`${r.table_name||tableName(r.table_code)} · ${shiftName(r.shift_code)}`:(r.table_name||tableName(r.table_code));
  const fmtShortDate=(v)=>new Intl.DateTimeFormat("en-IE",{day:"numeric",month:"short",timeZone:"UTC"}).format(new Date(`${String(v).slice(0,10)}T12:00:00Z`));
  const fmtMonth=(v)=>new Intl.DateTimeFormat("en-IE",{month:"long",year:"numeric",timeZone:"UTC"}).format(new Date(`${String(v).slice(0,10)}T12:00:00Z`));
  const fmtKg=(v)=>`${Math.round(Number(v||0)).toLocaleString("en-IE")} kg`;
  function periodLabel(d){return d.period==="MONTH"?fmtMonth(d.date_from):`${fmtShortDate(d.date_from)} – ${fmtShortDate(d.date_to)} ${String(d.date_to).slice(0,4)}`;}
  function moveHtml(r){
    if(!r.eligible)return '<span class="move none">—</span>';
    if(r.previous_rank==null)return '<span class="move new" title="Not ranked in the previous period">New</span>';
    const c=Number(r.rank_change||0);
    if(c>0)return `<span class="move up" title="Was ${ordinal(r.previous_rank)}">▲ ${c}</span>`;
    if(c<0)return `<span class="move down" title="Was ${ordinal(r.previous_rank)}">▼ ${Math.abs(c)}</span>`;
    return `<span class="move same" title="Same position as the previous period">=</span>`;
  }
  function chaseHtml(r,rows){
    if(!r.eligible)return `<small>Not ranked: ${num(r.staff_hours)} of ${num(ranking.data?.min_staff_hours,0)} staff hours needed</small>`;
    if(r.zone==="LEADER")return "<small>Leader</small>";
    const ahead=rows.find(x=>x.rank===r.rank-1);
    if(r.zone==="RELEGATION"&&r.points_to_safety!=null)return `<small class="danger">${num(r.points_to_safety)} pts to leave the zone</small>`;
    return ahead?`<small>${num(r.points_to_next)} pts behind ${esc(teamName(ahead))}</small>`:"";
  }
  function rankingRowHtml(r,rows){
    const eff=Math.max(0,Number(r.efficiency_percent||0)),bar=Math.min(eff,130)/130*100,target=100/130*100;
    const trolley=Number(r.trolley_checked_count||0)>0?`<b class="${Number(r.trolley_error_count||0)>0?"bad":""}">${Number(r.trolley_error_count||0)} wrong</b><small>of ${Number(r.trolley_checked_count||0)} checked${Number(r.penalty_points||0)>0?` · −${num(r.penalty_points)} pts`:""}</small>`:'<b class="muted">—</b><small>No trolley check</small>';
    return `<article class="finish-results-rank-row zone-${esc(String(r.zone||"").toLowerCase())}">
      <strong class="finish-results-rank-pos" aria-label="Position">${r.rank?r.rank:"–"}</strong>
      <div class="finish-results-rank-team"><strong>${esc(teamName(r))}</strong><small>${Number(r.worked_days||0)} days · ${num(r.staff_hours)} staff h · ${fmtKg(r.produced_kg)}</small></div>
      ${moveHtml(r)}
      <div class="finish-results-rank-eff"><span><b>${percent(r.efficiency_percent)}</b><small>${num(r.kg_per_staff_hour)} kg/h</small></span><i><em style="width:${bar.toFixed(1)}%"></em><u style="left:${target.toFixed(1)}%"></u></i></div>
      <div class="finish-results-rank-trolley">${trolley}</div>
      <div class="finish-results-rank-score"><strong>${r.eligible?num(r.score):"—"}</strong>${chaseHtml(r,rows)}</div>
    </article>`;
  }
  function renderRanking(){
    const d=ranking.data;if(!d)return;
    const rows=(ranking.level==="TABLE"?d.tables:d.teams)||[];
    el.rankingTitle.textContent=`${d.period==="MONTH"?"Closed month":"Closed week"} · ${ranking.level==="TABLE"?"Table":"Table × Shift"}`;
    el.rankingPeriod.textContent=periodLabel(d);
    el.rankingNext.disabled=!!d.is_latest_closed;
    document.querySelectorAll("[data-ranking-period]").forEach(b=>b.setAttribute("aria-pressed",String(b.dataset.rankingPeriod===ranking.period)));
    document.querySelectorAll("[data-ranking-level]").forEach(b=>b.setAttribute("aria-pressed",String(b.dataset.rankingLevel===ranking.level)));
    const ranked=rows.filter(r=>r.eligible);
    if(!ranked.length){el.ranking.innerHTML=`<div class="finish-results-empty">No Table has enough staff hours in this period to be ranked.</div>${rankingNoteHtml(d,rows)}`;return;}
    let html='<div class="finish-results-rank-head"><span>#</span><span>Team</span><span>Move</span><span>Efficiency</span><span>Trolley</span><span>Score</span></div>',zoneShown=false;
    rows.forEach(r=>{if(r.zone==="RELEGATION"&&!zoneShown){zoneShown=true;html+='<div class="finish-results-rank-divider"><span>Relegation zone</span></div>';}html+=rankingRowHtml(r,rows);});
    el.ranking.innerHTML=html+rankingNoteHtml(d,rows);
  }
  function rankingNoteHtml(d,rows){
    const unmeasured=rows.reduce((s,r)=>s+Number(r.unmeasured_kg||0),0);
    return `<p class="finish-results-rank-note"><b>Score</b> = Efficiency % (kg equivalent ÷ staff hours × ${num(d.target_kg_per_staff_hour)}) − ${num(d.trolley_error_penalty_per_percent,0)} pts for each 1% of contributions saved with a wrong trolley. Ranked from ${num(d.min_staff_hours,0)} staff hours in the ${d.period==="MONTH"?"month":"week"}. Movement compares with the ${d.period==="MONTH"?"previous month":"previous week"}.${unmeasured>0?` ${fmtKg(unmeasured)} on days without staff hours is left out.`:""}</p>`;
  }
  async function loadRanking(){
    if(!el.ranking)return;
    const req=++ranking.req;el.ranking.classList.add("loading");
    try{
      const data=await rpc("get_finish_table_ranking_v1",{p_period:ranking.period,p_anchor:ranking.anchor});
      if(req!==ranking.req)return;
      if(data?.schema_version!=="FINISH_TABLE_RANKING_V1")throw new Error("Ranking backend is out of date. Refresh after the latest update.");
      ranking.data=data;ranking.anchor=String(data.date_from).slice(0,10);renderRanking();
    }catch(err){if(req!==ranking.req)return;console.error(err);el.ranking.innerHTML=`<div class="finish-results-empty">${esc(err.message||"Ranking could not be loaded.")}</div>`;}
    finally{if(req===ranking.req)el.ranking.classList.remove("loading");}
  }
  function shiftRanking(step){
    const d=ranking.data;if(!d)return;
    const from=new Date(`${String(d.date_from).slice(0,10)}T12:00:00Z`);
    if(d.period==="MONTH")from.setUTCMonth(from.getUTCMonth()+step);else from.setUTCDate(from.getUTCDate()+7*step);
    ranking.anchor=from.toISOString().slice(0,10);loadRanking();
  }
  if(el.ranking){
    document.querySelectorAll("[data-ranking-period]").forEach(b=>b.addEventListener("click",()=>{if(ranking.period===b.dataset.rankingPeriod)return;ranking.period=b.dataset.rankingPeriod;ranking.anchor=null;loadRanking();}));
    document.querySelectorAll("[data-ranking-level]").forEach(b=>b.addEventListener("click",()=>{ranking.level=b.dataset.rankingLevel;renderRanking();}));
    el.rankingPrev.addEventListener("click",()=>shiftRanking(-1));el.rankingNext.addEventListener("click",()=>shiftRanking(1));
  }

  function render(data){
    if(data?.schema_version!=="FINISH_RESULTS_V2")throw new Error("Finish Results backend is out of date. Refresh after the latest update.");
    el.date.value=String(data.business_date||"").slice(0,10);
    document.title=`Finish Results · ${fmtDate(data.business_date)} | ElisCaretex`;
    renderTotals(data);renderShifts(data);renderMatrix(data);renderStaff(data);renderEntries(data);
  }

  async function load(dateValue=null){
    setMessage("Loading Finish Results…");el.refresh.disabled=true;
    try{const data=await rpc("get_finish_results_dashboard",{p_business_date:dateValue||null});render(data);await loadTrolleyErrors(String(data.business_date||"").slice(0,10));setMessage(`Results loaded · ${fmtDate(data.business_date)}`,"success");}
    catch(err){console.error(err);setMessage(err.message||"Finish Results could not be loaded.","error");}
    finally{el.refresh.disabled=false;}
  }
  function moveDate(days){const value=el.date.value||dublinDateKey(),d=new Date(`${value}T12:00:00Z`);d.setUTCDate(d.getUTCDate()+days);el.date.value=d.toISOString().slice(0,10);load(el.date.value);}

  el.prev.addEventListener("click",()=>moveDate(-1));el.next.addEventListener("click",()=>moveDate(1));
  el.today.addEventListener("click",()=>load(null));el.refresh.addEventListener("click",()=>load(el.date.value||null));el.date.addEventListener("change",()=>load(el.date.value||null));
  if(el.trolleyPeriod)el.trolleyPeriod.addEventListener("change",()=>{if(el.date.value)loadTrolleyErrors(el.date.value);});
  try{if(window.ELIS_SUPABASE_ERROR||!client)throw new Error(window.ELIS_SUPABASE_ERROR||"Supabase could not be initialized.");const {data:{session},error}=await client.auth.getSession();if(error)throw error;if(!session?.user){location.href="../index.html";return;}loadRanking();await load(null);}catch(err){console.error(err);setMessage(err.message||"Finish Results could not be initialized.","error");}
});
