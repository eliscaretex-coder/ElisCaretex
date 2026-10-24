"use strict";

// Production Intelligence for managers: one period (day, week, month, year) drives the
// Overview, Customers, Shifts & tables and Staff tabs through
// get_production_intelligence_manager_view. The Daily report tab has its own date and
// uses get_production_daily_report. Planning keeps the forward capacity, seasonality and
// forecast RPCs. All numbers come from permission-guarded RPCs.
document.addEventListener("DOMContentLoaded",async()=>{
  const client=window.elisSupabase,$=id=>document.getElementById(id);
  const TABS=["overview","daily","customers","performance","staff","planning"];
  const state={tab:"overview",period:"MONTH",anchor:null,manager:null,daily:null,dailyDate:null,dailyFilter:"PENDING",planningLoaded:false,loadToken:0,dailyToken:0};

  const esc=v=>String(v??"").replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&#039;");
  const num=(v,d=0)=>Number(v||0).toLocaleString("en-IE",{minimumFractionDigits:d,maximumFractionDigits:d});
  const kg=v=>`${num(v,1)} kg`;
  const pct=v=>v==null?"—":`${num(v,1)}%`;
  const iso=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;
  const parse=v=>{const [y,m,d]=String(v).slice(0,10).split("-").map(Number);return new Date(y,m-1,d);};
  const addDays=(d,n)=>{const x=new Date(d);x.setDate(x.getDate()+n);return x;};
  const fmt=(v,opts={day:"2-digit",month:"short",year:"numeric"})=>v?new Intl.DateTimeFormat("en-IE",opts).format(parse(v)):"—";
  const weekday=v=>["","Mon","Tue","Wed","Thu","Fri","Sat","Sun"][Number(v)]||"—";
  const shiftName=v=>({MORNING:"Morning",EVENING:"Evening"}[v]||v||"—");
  const effClass=v=>v==null?"":Number(v)>=95?"good":Number(v)>=85?"watch":"low";
  const empty=text=>`<div class="production-insights-empty">${esc(text)}</div>`;

  function setMessage(text="",type=""){$("insightsMessage").textContent=text;$("insightsMessage").className=`production-insights-message ${type}`.trim();}

  // Period ------------------------------------------------------------------------------
  function periodRange(period,anchor){
    const today=new Date();today.setHours(0,0,0,0);
    let from,to,prevFrom,granularity="DAY";
    if(period==="DAY"){from=new Date(anchor);to=new Date(anchor);prevFrom=addDays(from,-7);}
    else if(period==="WEEK"){const dow=(anchor.getDay()+6)%7;from=addDays(anchor,-dow);to=addDays(from,6);prevFrom=addDays(from,-7);}
    else if(period==="MONTH"){from=new Date(anchor.getFullYear(),anchor.getMonth(),1);to=new Date(anchor.getFullYear(),anchor.getMonth()+1,0);prevFrom=new Date(anchor.getFullYear(),anchor.getMonth()-1,1);}
    else{from=new Date(anchor.getFullYear(),0,1);to=new Date(anchor.getFullYear(),11,31);prevFrom=new Date(anchor.getFullYear()-1,0,1);granularity="MONTH";}
    // A period that is still running is compared with the same number of days before it.
    if(to>today&&from<=today)to=today;
    const length=Math.round((to-from)/86400000);
    return {from,to,compareFrom:prevFrom,compareTo:addDays(prevFrom,length),granularity};
  }
  function periodLabel(period,r){
    if(period==="DAY")return `${fmt(iso(r.from),{weekday:"long",day:"2-digit",month:"long",year:"numeric"})} · compared with the same day last week`;
    if(period==="WEEK")return `Week of ${fmt(iso(r.from))} · compared with the previous week`;
    if(period==="MONTH")return `${fmt(iso(r.from),{month:"long",year:"numeric"})}${r.to.getDate()!==new Date(r.from.getFullYear(),r.from.getMonth()+1,0).getDate()?` (to ${fmt(iso(r.to),{day:"2-digit",month:"short"})})`:""} · compared with the same days of the previous month`;
    return `${r.from.getFullYear()}${r.to.getMonth()!==11||r.to.getDate()!==31?` (to ${fmt(iso(r.to),{day:"2-digit",month:"short"})})`:""} · compared with the same period of ${r.from.getFullYear()-1}`;
  }
  function shiftAnchor(direction){
    const a=new Date(state.anchor);
    if(state.period==="DAY")a.setDate(a.getDate()+direction);
    else if(state.period==="WEEK")a.setDate(a.getDate()+7*direction);
    else if(state.period==="MONTH"){a.setDate(1);a.setMonth(a.getMonth()+direction);}
    else a.setFullYear(a.getFullYear()+direction);
    state.anchor=a;$("insightsAnchor").value=iso(a);loadManager();
  }

  // Tabs ------------------------------------------------------------------------------
  function setTab(tab,push=true){
    state.tab=TABS.includes(tab)?tab:"overview";
    document.querySelectorAll("[data-tab]").forEach(b=>{const on=b.dataset.tab===state.tab;b.classList.toggle("active",on);b.setAttribute("aria-selected",String(on));});
    document.querySelectorAll("[data-panel]").forEach(p=>{p.hidden=p.dataset.panel!==state.tab;});
    $("insightsPeriodControls").hidden=state.tab==="daily"||state.tab==="planning";
    $("dailyControls").hidden=state.tab!=="daily";
    $("insightsPeriodLabel").hidden=state.tab==="daily"||state.tab==="planning";
    if(push){const url=new URL(location.href);url.searchParams.set("view",state.tab);history.replaceState(null,"",url);}
    setMessage("");
    if(state.tab==="daily"&&!state.daily)loadDaily();
    if(state.tab==="planning"&&!state.planningLoaded)loadPlanning();
    if(["overview","customers","performance","staff"].includes(state.tab)&&!state.manager)loadManager();
  }

  // Manager view ----------------------------------------------------------------------
  async function loadManager(){
    const token=++state.loadToken,r=periodRange(state.period,state.anchor);
    $("insightsPeriodLabel").textContent=periodLabel(state.period,r);
    document.querySelectorAll("[data-period]").forEach(b=>b.classList.toggle("active",b.dataset.period===state.period));
    setMessage("Loading production…");
    try{
      const {data,error}=await client.rpc("get_production_intelligence_manager_view",{p_from_date:iso(r.from),p_to_date:iso(r.to),p_granularity:r.granularity,p_compare_from:iso(r.compareFrom),p_compare_to:iso(r.compareTo)});
      if(error)throw error;if(token!==state.loadToken)return;
      state.manager=data||{};renderOverview();renderCustomers();renderPerformance();renderStaff();
      setMessage("");
    }catch(error){console.error(error);if(token===state.loadToken)setMessage(error.message||"Production Intelligence could not be loaded.","error");}
  }

  function delta(current,previous,{inverse=false,unit="%"}={}){
    const c=Number(current||0),p=Number(previous||0);
    if(!p)return '<small class="production-insights-delta">No comparison</small>';
    const change=unit==="pt"?c-p:(c-p)/p*100,up=change>=0,good=inverse?!up:up;
    return `<small class="production-insights-delta ${Math.abs(change)<0.05?"":good?"up":"down"}">${up?"▲":"▼"} ${num(Math.abs(change),1)}${unit==="pt"?" pt":"%"} vs ${num(p,unit==="pt"?1:0)}${unit==="pt"?"%":""}</small>`;
  }

  function renderOverview(){
    const d=state.manager||{},s=d.summary||{},c=d.compare||{},a=d.areas||{},f=a.finish||{},so=a.sorting||{},m=a.mop||{};
    $("overviewKpis").innerHTML=[
      ["Official production",kg(s.total_kg),delta(s.total_kg,c.total_kg)],
      ["Finish (Clothes)",kg(s.finish_kg),delta(s.finish_kg,c.finish_kg)],
      ["MOP",kg(s.mop_kg),delta(s.mop_kg,c.mop_kg)],
      ["KG per production day",kg(s.kg_per_production_day),delta(s.kg_per_production_day,c.kg_per_production_day)],
      ["Production days",num(s.production_days),delta(s.production_days,c.production_days)],
      ["Customers served",num(s.customers),delta(s.customers,c.customers)],
      ["Trolleys out",num(s.trolleys_out),delta(s.trolleys_out,c.trolleys_out)],
      ["Finish efficiency",pct(f.efficiency_percent),`<small class="production-insights-delta">${f.kg_per_hour==null?"No staff hours":`${num(f.kg_per_hour,1)} kg/h · target ${num(f.target_kg_per_hour,1)}`}</small>`]
    ].map(([label,value,extra])=>`<article><span>${label}</span><strong>${value}</strong>${extra}</article>`).join("");

    const trend=d.trend||[],gran=d.period?.granularity||"DAY",max=Math.max(1,...trend.map(t=>Number(t.total_kg||0)));
    $("overviewTrendTitle").textContent=gran==="MONTH"?"Official production by month":"Official production by day";
    $("overviewTrendHint").textContent=state.period==="DAY"?"Single day: see Shifts & tables and the Daily report for the detail.":"Finish and MOP. Hover a bar for the values.";
    $("overviewTrend").innerHTML=trend.length?trend.map(t=>{const label=gran==="MONTH"?fmt(t.bucket_start,{month:"short"}):fmt(t.bucket_start,{day:"2-digit",month:"short"});return `<article title="${esc(label)}: Finish ${kg(t.finish_kg)} · MOP ${kg(t.mop_kg)} · ${num(t.customers)} customers"><div class="production-insights-stack"><i class="mop" style="height:${Number(t.mop_kg||0)/max*120}px"></i><i style="height:${Number(t.finish_kg||0)/max*120}px"></i></div><small><b>${num(Number(t.total_kg||0)/1000,1)}t</b>${esc(label)}</small></article>`;}).join(""):empty("No official production in this period.");

    $("overviewAreas").innerHTML=`
      <article class="production-insights-area sorting"><header><span>Sorting</span><b class="${effClass(so.efficiency_percent)}">${pct(so.efficiency_percent)}</b></header><strong>${kg(so.approximate_kg)}</strong><small>approximate washed weight</small><dl><div><dt>Loads</dt><dd>${num(so.loads)}</dd></div><div><dt>Staff hours</dt><dd>${num(so.staff_hours,1)}</dd></div><div><dt>Targets</dt><dd>${num(so.clothes_target_kg_per_hour)} / ${num(so.mop_target_kg_per_hour)} kg/h</dd></div></dl></article>
      <article class="production-insights-area finish"><header><span>Finish</span><b class="${effClass(f.efficiency_percent)}">${pct(f.efficiency_percent)}</b></header><strong>${kg(f.produced_kg)}</strong><small>produced (KG + units + ReWash)</small><dl><div><dt>Staff hours</dt><dd>${num(f.staff_hours,1)}</dd></div><div><dt>KG / staff hour</dt><dd>${f.kg_per_hour==null?"—":num(f.kg_per_hour,1)}</dd></div><div><dt>Target</dt><dd>${num(f.target_kg_per_hour,1)} kg/h</dd></div></dl></article>
      <article class="production-insights-area mop"><header><span>MOP Production</span><b>${num(m.batches)} batches</b></header><strong>${kg(m.kg)}</strong><small>official MOP weight</small><dl><div><dt>Units</dt><dd>${num(m.units)}</dd></div><div><dt>Trolleys received</dt><dd>${num(a.trolleys_received)}</dd></div><div><dt>Trolleys out</dt><dd>${num(s.trolleys_out)}</dd></div></dl></article>`;

    $("overviewHighlights").innerHTML=highlights(d).map(h=>`<li class="${h.type}"><b>${esc(h.title)}</b><span>${esc(h.text)}</span></li>`).join("")||'<li><span>No highlights for this period.</span></li>';
  }

  function highlights(d){
    const out=[],s=d.summary||{},c=d.compare||{},shifts=d.shifts||[],tables=(d.tables||[]).filter(t=>t.efficiency_percent!=null),customers=d.customers||[],t=d.turnover||{};
    if(Number(c.total_kg)>0){const ch=(Number(s.total_kg)-Number(c.total_kg))/Number(c.total_kg)*100;out.push({type:ch>=0?"good":"warn",title:`Production ${ch>=0?"up":"down"} ${num(Math.abs(ch),1)}%`,text:`${kg(s.total_kg)} against ${kg(c.total_kg)} in the comparison period.`});}
    const fin=shifts.filter(x=>x.finish_efficiency_percent!=null).sort((a,b)=>b.finish_efficiency_percent-a.finish_efficiency_percent);
    if(fin.length===2)out.push({type:"info",title:`${shiftName(fin[0].shift_code)} shift led Finish`,text:`${pct(fin[0].finish_efficiency_percent)} efficiency against ${pct(fin[1].finish_efficiency_percent)} on ${shiftName(fin[1].shift_code)}.`});
    if(tables.length){const sorted=[...tables].sort((a,b)=>b.efficiency_percent-a.efficiency_percent),best=sorted[0],worst=sorted[sorted.length-1];out.push({type:"good",title:`Best table: ${best.table_name} ${shiftName(best.shift_code)}`,text:`${pct(best.efficiency_percent)} · ${num(best.kg_per_hour,1)} kg per staff hour.`});if(worst!==best&&worst.efficiency_percent<90)out.push({type:"warn",title:`${worst.table_name} ${shiftName(worst.shift_code)} below target`,text:`${pct(worst.efficiency_percent)} · ${num(worst.kg_per_hour,1)} kg per staff hour.`});}
    const growth=customers.filter(x=>Number(x.compare_kg)>=100&&x.change_percent!=null).sort((a,b)=>a.change_percent-b.change_percent);
    if(growth.length){const down=growth[0],up=growth[growth.length-1];if(down.change_percent<=-20)out.push({type:"warn",title:`${down.customer_name} (${down.product_code}) dropped ${num(Math.abs(down.change_percent),0)}%`,text:`${kg(down.kg)} against ${kg(down.compare_kg)}.`});if(up.change_percent>=20)out.push({type:"info",title:`${up.customer_name} (${up.product_code}) grew ${num(up.change_percent,0)}%`,text:`${kg(up.kg)} against ${kg(up.compare_kg)}.`});}
    if(customers[0])out.push({type:"info",title:`Largest customer: ${customers[0].customer_name}`,text:`${kg(customers[0].kg)} (${pct(customers[0].share_percent)} of official production).`});
    if(Number(t.leavers)>0)out.push({type:Number(t.turnover_percent)>=5?"warn":"info",title:`${num(t.leavers)} staff left · turnover ${pct(t.turnover_percent)}`,text:`Production headcount ${num(t.headcount_start)} → ${num(t.headcount_end)}.`});
    return out;
  }

  // Customers -------------------------------------------------------------------------
  function renderCustomers(){
    const rows=(state.manager?.customers||[]),needle=$("customersSearch").value.trim().toLowerCase(),product=$("customersProduct").value;
    const list=rows.filter(r=>(!product||r.product_code===product)&&(!needle||String(r.customer_name).toLowerCase().includes(needle)));
    const cp=state.manager?.compare_period;$("customersHint").textContent=cp?`Change compared with ${fmt(cp.from)} – ${fmt(cp.to)}.`:"Compared with the previous period.";
    $("customersCount").textContent=`${list.length} customer${list.length===1?"":"s"}`;
    $("customersTable").innerHTML=list.length?`<table class="production-insights-table"><thead><tr><th>Customer</th><th>Product</th><th class="n">KG</th><th class="n">Share</th><th class="n">Days</th><th class="n">Avg KG / day</th><th class="n">Trolleys out</th><th class="n">Avg trolleys / day</th><th class="n">Trolleys received</th><th class="n">Previous KG</th><th class="n">Change</th><th></th></tr></thead><tbody>${list.map(r=>`<tr><td><strong>${esc(r.customer_name)}</strong></td><td><span class="production-insights-source ${r.product_code==="MOP"?"mop":""}">${esc(r.product_code)}</span></td><td class="n"><strong>${num(r.kg,1)}</strong></td><td class="n">${pct(r.share_percent)}</td><td class="n">${num(r.production_days)}</td><td class="n">${r.average_kg_per_day==null?"—":num(r.average_kg_per_day,1)}</td><td class="n">${num(r.trolleys)}</td><td class="n"><strong>${r.average_trolleys_per_day==null?"—":num(r.average_trolleys_per_day,1)}</strong></td><td class="n">${r.trolleys_received==null?"—":num(r.trolleys_received)}</td><td class="n">${num(r.compare_kg,1)}</td><td class="n ${r.change_percent==null?"":r.change_percent>=0?"up":"down"}">${r.change_percent==null?"New":`${r.change_percent>=0?"+":""}${num(r.change_percent,1)}%`}</td><td><button type="button" class="production-insights-history-button" data-customer-history-id="${esc(r.customer_id)}" data-customer-history-name="${esc(r.customer_name)}">History</button></td></tr>`).join("")}</tbody></table>`:empty("No customers match this filter.");
  }

  async function loadCustomerHistory(customerId,customerName){
    const r=periodRange(state.period,state.anchor);
    $("insightsCustomerHistoryCard").hidden=false;$("insightsCustomerHistoryTitle").textContent=customerName||"Customer";$("insightsCustomerSuggestions").innerHTML=empty("Calculating weekday averages…");$("insightsCustomerHistory").innerHTML="";$("insightsCustomerHistoryCard").scrollIntoView({behavior:"smooth",block:"start"});
    try{const {data,error}=await client.rpc("get_customer_kg_history",{p_customer_id:customerId,p_from_date:iso(r.from),p_to_date:iso(r.to),p_recent_limit:3});if(error)throw error;renderCustomerHistory(data||{});}catch(error){console.error(error);$("insightsCustomerSuggestions").innerHTML=empty(error.message||"Customer history could not be loaded.");}
  }
  function renderCustomerHistory(data){
    const suggestions=data.suggestions||[],history=data.history||[],day=v=>["","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"][Number(v)]||"Day";
    $("insightsCustomerSuggestions").innerHTML=[1,2,3,4,5,6].map(n=>{const rows=suggestions.filter(row=>Number(row.production_weekday)===n);return `<article><span>${day(n)}</span>${rows.length?rows.map(row=>`<div><b>${esc(row.product_code)}</b><strong>${row.status==="READY"?kg(row.suggested_kg):"Learning"}</strong><small>${Number(row.history_points||0)}/3 matching days${row.status==="READY"?` | ${kg(row.minimum_kg)}-${kg(row.maximum_kg)}`:""}</small></div>`).join(""):"<small>No official records</small>"}</article>`;}).join("");
    $("insightsCustomerHistory").innerHTML=history.length?`<div class="production-insights-history-head"><span>Date</span><span>Day</span><span>Product</span><span>Official KG</span><span>Source</span></div>${history.map(row=>`<article><span><strong>${fmt(row.actual_date)}</strong></span><span>${day(row.production_weekday)}</span><span>${esc(row.product_code)}</span><span><strong>${kg(row.actual_kg)}</strong></span><span><span class="production-insights-source ${row.production_source==="MOP"?"mop":""}">${esc(row.production_source)}</span></span></article>`).join("")}`:empty("No official Finish or MOP KG exists for this customer in the selected period.");
  }

  // Shifts & tables -------------------------------------------------------------------
  function renderPerformance(){
    const d=state.manager||{},shifts=d.shifts||[],tables=d.tables||[],target=d.targets?.finish_kg_per_staff_hour;
    $("performancePolicy").textContent=`Finish uses the Finish Results basis (KG, units converted and ReWash) against ${num(target,1)} KG per staff hour. Sorting uses ${num(d.targets?.sorting_clothes_kg_per_staff_hour)} kg/h for Clothes and ${num(d.targets?.sorting_mop_kg_per_staff_hour)} kg/h for MOP. Only days with staff hours count towards efficiency.`;
    const best=(key)=>{const valid=shifts.filter(s=>s[key]!=null&&Number(s[key])>0);if(valid.length<2)return null;return valid.reduce((a,b)=>Number(b[key])>Number(a[key])?b:a).shift_code;};
    const bf=best("finish_efficiency_percent"),bs=best("sorting_efficiency_percent"),bm=best("mop_kg");
    $("performanceShifts").innerHTML=shifts.length?shifts.map(s=>`<article><header><strong>${shiftName(s.shift_code)}</strong></header>
      <div class="${bf===s.shift_code?"winner":""}"><span>Finish</span><b class="${effClass(s.finish_efficiency_percent)}">${pct(s.finish_efficiency_percent)}</b><small>${kg(s.finish_kg)} · ${num(s.finish_hours,1)} h · ${s.finish_kg_per_hour==null?"—":num(s.finish_kg_per_hour,1)} kg/h</small></div>
      <div class="${bs===s.shift_code?"winner":""}"><span>Sorting</span><b class="${effClass(s.sorting_efficiency_percent)}">${pct(s.sorting_efficiency_percent)}</b><small>${kg(s.sorting_kg)} approx. · ${num(s.sorting_loads)} loads · ${num(s.sorting_hours,1)} h</small></div>
      <div class="${bm===s.shift_code?"winner":""}"><span>MOP</span><b>${kg(s.mop_kg)}</b><small>${num(s.mop_batches)} batches · ${num(s.mop_units)} units</small></div></article>`).join(""):empty("No shift data in this period.");
    const valid=tables.filter(t=>t.efficiency_percent!=null),top=valid.length?valid.reduce((a,b)=>b.efficiency_percent>a.efficiency_percent?b:a):null;
    $("performanceBest").textContent=top?`Best: ${top.table_name} ${shiftName(top.shift_code)}`:"—";
    $("performanceTables").innerHTML=tables.length?["MORNING","EVENING"].map(shift=>`<div class="production-insights-table-row"><span>${shiftName(shift)}</span>${tables.filter(t=>t.shift_code===shift).map(t=>`<article class="${top===t?"winner":""}"><header><strong>${esc(t.table_name)}</strong><b class="${effClass(t.efficiency_percent)}">${pct(t.efficiency_percent)}</b></header><div class="production-insights-meter"><i class="${effClass(t.efficiency_percent)}" style="width:${Math.min(100,Number(t.efficiency_percent||0))}%"></i></div><dl><div><dt>KG</dt><dd>${num(t.kg,1)}</dd></div><div><dt>Staff hours</dt><dd>${num(t.hours,1)}</dd></div><div><dt>KG / h</dt><dd>${t.kg_per_hour==null?"—":num(t.kg_per_hour,1)}</dd></div><div><dt>Avg staff</dt><dd>${num(t.average_staff,1)}</dd></div><div><dt>Days</dt><dd>${num(t.production_days)}</dd></div></dl></article>`).join("")}</div>`).join(""):empty("No Finish table production in this period.");
  }

  // Staff -----------------------------------------------------------------------------
  function renderStaff(){
    const t=state.manager?.turnover||{},months=t.monthly||[],leavers=t.leavers_list||[];
    $("staffKpis").innerHTML=[["Headcount at start",num(t.headcount_start)],["Headcount at end",num(t.headcount_end)],["Leavers",num(t.leavers),delta(t.leavers,t.compare_leavers,{inverse:true})],["Joiners",num(t.joiners)],["Turnover",pct(t.turnover_percent)]].map(([l,v,x])=>`<article><span>${l}</span><strong>${v}</strong>${x||""}</article>`).join("");
    const max=Math.max(1,...months.map(m=>Number(m.leavers||0)));
    $("staffMonthly").innerHTML=months.length?months.map(m=>`<article title="${fmt(m.month_start,{month:"long",year:"numeric"})}: ${num(m.leavers)} leavers, ${num(m.joiners)} joiners, headcount ${num(m.headcount_end)}"><div class="production-insights-stack"><i class="leavers" style="height:${Number(m.leavers||0)/max*110}px"></i></div><small><b>${pct(m.turnover_percent)}</b>${fmt(m.month_start,{month:"short"})} · ${num(m.leavers)}</small></article>`).join(""):empty("No staff history.");
    $("staffNote").textContent=t.joiners_note||"";$("staffLeaversCount").textContent=String(leavers.length);
    $("staffLeavers").innerHTML=leavers.length?`<table class="production-insights-table"><thead><tr><th>Name</th><th>Left on</th><th>Started</th><th>Reason</th></tr></thead><tbody>${leavers.map(x=>`<tr><td><strong>${esc(x.display_name)}</strong></td><td>${fmt(x.deactivated_on)}</td><td>${x.start_on?fmt(x.start_on):"—"}</td><td>${esc(x.reason||"—")}</td></tr>`).join("")}</tbody></table>`:empty("Nobody left in this period.");
  }

  // Daily report ----------------------------------------------------------------------
  async function loadDaily(){
    const token=++state.dailyToken;setMessage("Loading daily report…");
    try{
      const {data,error}=await client.rpc("get_production_daily_report",{p_business_date:state.dailyDate||null});
      if(error)throw error;if(token!==state.dailyToken)return;
      state.daily=data||{};state.dailyDate=state.daily.business_date;$("dailyDate").value=state.dailyDate;renderDaily();setMessage("");
    }catch(error){console.error(error);if(token===state.dailyToken)setMessage(error.message||"The daily report could not be loaded.","error");}
  }

  const STATUS_LABEL={PRODUCED:"Produced",WASHED_NOT_FINISHED:"Washed, not finished",NOT_STARTED:"Not started",ACKNOWLEDGED:"Acknowledged not processed"};
  function renderDaily(){
    const d=state.daily||{},customers=d.customers||[],so=d.sorting||{},fi=d.finish||{},mop=d.mop||{},st=so.total||{},ft=fi.total||{},mt=mop.total||{};
    const produced=customers.filter(c=>c.status==="PRODUCED").length,pending=customers.filter(c=>c.status!=="PRODUCED"),late=customers.filter(c=>c.late);
    const ratio=customers.length?produced/customers.length*100:0,complete=customers.length>0&&pending.length===0;
    $("dailyBanner").className=`production-insights-daily-banner ${complete?"good":ratio>=90?"watch":"low"}`;
    $("dailyBanner").innerHTML=`<div><span>${fmt(d.business_date,{weekday:"long",day:"2-digit",month:"long",year:"numeric"})}</span><strong>${complete?"Production complete for delivery":customers.length?`${num(pending.length)} scheduled service${pending.length===1?"":"s"} not produced`:"No customers scheduled"}</strong><small>${num(produced)} of ${num(customers.length)} scheduled services produced (${num(ratio,0)}%)${late.length?` · ${num(late.length)} finished late (after the day)`:""}</small></div><div class="production-insights-meter big"><i class="${complete?"good":ratio>=90?"watch":"low"}" style="width:${Math.min(100,ratio)}%"></i></div>`;

    const denied='<small class="production-insights-denied">No access to this area\'s results.</small>';
    $("dailyAreas").innerHTML=`
      <article class="production-insights-area sorting"><header><span>Sorting</span><b class="${effClass(st.efficiency_percent)}">${so.access==="DENIED"?"—":pct(st.efficiency_percent)}</b></header>${so.access==="DENIED"?denied:`<strong>${kg(st.produced_kg)}</strong><small>approximate washed weight</small><dl><div><dt>Loads</dt><dd>${num(st.total_loads)}</dd></div><div><dt>Clothes / MOP</dt><dd>${num(st.clothes_kg)} / ${num(st.mop_kg)} kg</dd></div><div><dt>Staff · hours</dt><dd>${num(st.staff_count)} · ${num(st.staff_hours,1)}</dd></div><div><dt>Absent</dt><dd>${num(st.absent_count)}</dd></div></dl>`}</article>
      <article class="production-insights-area finish"><header><span>Finish</span><b class="${effClass(ft.efficiency_percent)}">${fi.access==="DENIED"?"—":pct(ft.efficiency_percent)}</b></header>${fi.access==="DENIED"?denied:`<strong>${kg(ft.produced_kg)}</strong><small>produced against ${kg(ft.planned_kg)} planned</small><dl><div><dt>Missing</dt><dd>${kg(ft.missing_kg)}</dd></div><div><dt>ReWash</dt><dd>${kg(ft.rewash_kg)}</dd></div><div><dt>Staff · hours</dt><dd>${num(ft.staff_count)} · ${num(ft.staff_hours,1)}</dd></div><div><dt>Units</dt><dd>${num(ft.produced_units)}</dd></div></dl>`}</article>
      <article class="production-insights-area mop"><header><span>MOP Production</span><b>${num(mt.batches)} batches</b></header><strong>${kg(mt.kg)}</strong><small>official MOP weight</small><dl><div><dt>Customers</dt><dd>${num(mt.customers)}</dd></div><div><dt>Units</dt><dd>${num(mt.units)}</dd></div><div><dt>Trolleys</dt><dd>${num(mt.trolleys)}</dd></div><div><dt>Late entries</dt><dd>${num(mt.late_entries)}</dd></div></dl></article>`;

    const alerts=[];
    const notStarted=pending.filter(c=>c.status==="NOT_STARTED"),washed=pending.filter(c=>c.status==="WASHED_NOT_FINISHED");
    if(notStarted.length)alerts.push({type:"bad",title:`${notStarted.length} service${notStarted.length===1?"":"s"} not started`,text:notStarted.slice(0,8).map(c=>`${c.customer_name} (${c.product_code})`).join(", ")+(notStarted.length>8?"…":"")});
    if(washed.length)alerts.push({type:"warn",title:`${washed.length} washed but not finished`,text:washed.slice(0,8).map(c=>`${c.customer_name} (${c.product_code})`).join(", ")+(washed.length>8?"…":"")});
    if(late.length)alerts.push({type:"warn",title:`${late.length} customer${late.length===1?"":"s"} finished after the day`,text:late.slice(0,8).map(c=>c.customer_name).join(", ")});
    (fi.shifts||[]).forEach(s=>{if(Number(s.planned_kg)>0&&Number(s.efficiency_percent)<85)alerts.push({type:"warn",title:`Finish ${shiftName(s.shift_code)} at ${pct(s.efficiency_percent)}`,text:`${kg(s.produced_kg)} produced against ${kg(s.planned_kg)} planned (${kg(s.missing_kg)} missing).`});});
    (fi.tables||[]).forEach(t=>{if(Number(t.planned_kg)>0&&Number(t.efficiency_percent)<80)alerts.push({type:"info",title:`${t.table_name} ${shiftName(t.shift_code)} at ${pct(t.efficiency_percent)}`,text:`${num(t.kg_per_staff_hour,1)} kg per staff hour with ${num(t.staff_count)} staff.`});});
    (so.shifts||[]).forEach(s=>{if(Number(s.staff_hours)>0&&Number(s.efficiency_percent)<85)alerts.push({type:"warn",title:`Sorting ${shiftName(s.shift_code)} at ${pct(s.efficiency_percent)}`,text:`${kg(s.produced_kg)} washed in ${num(s.staff_hours,1)} staff hours.`});});
    if(Number(st.absent_count)>0)alerts.push({type:"info",title:`${num(st.absent_count)} absent in Sorting`,text:(so.staff||[]).filter(x=>x.attendance_status==="ABSENT").map(x=>`${x.display_name}${x.absence_reason?` (${x.absence_reason})`:""}`).join(", ")});
    if((d.unscheduled||[]).length)alerts.push({type:"info",title:`${d.unscheduled.length} production${d.unscheduled.length===1?"":"s"} without a schedule`,text:"See Extra production below."});
    $("dailyAlerts").innerHTML=alerts.length?alerts.map(a=>`<li class="${a.type}"><b>${esc(a.title)}</b><span>${esc(a.text)}</span></li>`).join(""):'<li class="good"><b>No problems found</b><span>All scheduled services were produced and every area is on target.</span></li>';

    renderDailyCustomers();

    const shiftRows=["MORNING","EVENING"].map(code=>{const s=(so.shifts||[]).find(x=>x.shift_code===code)||{},f=(fi.shifts||[]).find(x=>x.shift_code===code)||{},m=(mop.shifts||[]).find(x=>x.shift_code===code)||{};
      return `<tr><td><strong>${shiftName(code)}</strong></td><td class="n">${so.access==="DENIED"?"—":kg(s.produced_kg)}</td><td class="n">${so.access==="DENIED"?"—":num(s.staff_hours,1)}</td><td class="n ${effClass(s.efficiency_percent)}">${so.access==="DENIED"?"—":pct(s.efficiency_percent)}</td><td class="n">${fi.access==="DENIED"?"—":kg(f.produced_kg)}</td><td class="n">${fi.access==="DENIED"?"—":kg(f.planned_kg)}</td><td class="n">${fi.access==="DENIED"?"—":num(f.staff_hours,1)}</td><td class="n ${effClass(f.efficiency_percent)}">${fi.access==="DENIED"?"—":pct(f.efficiency_percent)}</td><td class="n">${kg(m.kg)}</td><td class="n">${num(m.batches)}</td></tr>`;}).join("");
    const tableRows=(fi.tables||[]).map(t=>`<tr><td>${esc(t.table_name)} · ${shiftName(t.shift_code)}</td><td class="n">${kg(t.produced_kg)}</td><td class="n">${kg(t.planned_kg)}</td><td class="n">${num(t.staff_count)} · ${num(t.staff_hours,1)} h</td><td class="n">${num(t.kg_per_staff_hour,1)}</td><td class="n ${effClass(t.efficiency_percent)}">${pct(t.efficiency_percent)}</td></tr>`).join("");
    $("dailyShifts").innerHTML=`<table class="production-insights-table"><thead><tr><th>Shift</th><th class="n">Sorting KG</th><th class="n">Sorting hours</th><th class="n">Sorting eff.</th><th class="n">Finish KG</th><th class="n">Finish planned</th><th class="n">Finish hours</th><th class="n">Finish eff.</th><th class="n">MOP KG</th><th class="n">MOP batches</th></tr></thead><tbody>${shiftRows}</tbody></table>${tableRows?`<table class="production-insights-table"><thead><tr><th>Finish table</th><th class="n">Produced</th><th class="n">Planned</th><th class="n">Staff · hours</th><th class="n">KG / h</th><th class="n">Efficiency</th></tr></thead><tbody>${tableRows}</tbody></table>`:""}`;

    const extra=d.unscheduled||[];$("dailyUnscheduledCard").hidden=!extra.length;$("dailyUnscheduledCount").textContent=String(extra.length);
    $("dailyUnscheduled").innerHTML=extra.length?`<table class="production-insights-table"><thead><tr><th>Customer</th><th>Product</th><th class="n">Produced</th><th class="n">Trolleys</th></tr></thead><tbody>${extra.map(x=>`<tr><td><strong>${esc(x.customer_name)}</strong></td><td>${esc(x.product_code)}</td><td class="n">${kg(x.produced_kg)}</td><td class="n">${num(x.trolleys)}</td></tr>`).join("")}</tbody></table>`:"";
  }

  function renderDailyCustomers(){
    const all=state.daily?.customers||[],f=state.dailyFilter;
    document.querySelectorAll("#dailyFilter [data-filter]").forEach(b=>b.classList.toggle("active",b.dataset.filter===f));
    const list=all.filter(c=>f==="ALL"||(f==="PENDING"&&c.status!=="PRODUCED")||(f==="LATE"&&c.late));
    $("dailyCustomers").innerHTML=list.length?`<table class="production-insights-table"><thead><tr><th>Route</th><th>Customer</th><th>Product</th><th>Delivery</th><th class="n">Washed (approx.)</th><th class="n">Produced</th><th class="n">Trolleys</th><th>Status</th></tr></thead><tbody>${list.map(c=>`<tr><td>${c.route_code?`<span class="production-insights-route" style="--route:${esc(c.route_color||"#64748b")}">${esc(c.route_code)}</span>`:"—"}</td><td><strong>${esc(c.customer_name)}</strong></td><td><span class="production-insights-source ${c.product_code==="MOP"?"mop":""}">${esc(c.product_code)}</span></td><td>${weekday(c.delivery_weekday)}</td><td class="n">${Number(c.washed_kg)>0?kg(c.washed_kg):"—"}</td><td class="n"><strong>${Number(c.produced_kg)>0?kg(c.produced_kg):"—"}</strong></td><td class="n">${num(c.trolleys)}</td><td><i class="production-insights-status-pill ${c.status.toLowerCase()}">${STATUS_LABEL[c.status]||c.status}</i>${c.late?`<small class="production-insights-late">Finished ${fmt(c.last_production_date,{day:"2-digit",month:"short"})}</small>`:""}</td></tr>`).join("")}</tbody></table>`:empty(f==="PENDING"?"Every scheduled service was produced.":"No customers in this view.");
  }

  // Planning --------------------------------------------------------------------------
  async function loadPlanning(){
    state.planningLoaded=true;setMessage("Loading planning…");
    const today=new Date(),from=new Date(today.getFullYear(),today.getMonth()-11,1);
    try{
      const [dashboard,seasonality,capacity]=await Promise.all([
        client.rpc("get_production_intelligence_dashboard",{p_from_date:iso(addDays(today,-84)),p_to_date:iso(today),p_customer_id:null}),
        client.rpc("get_production_intelligence_customer_seasonality",{p_from_date:iso(from),p_to_date:iso(today)}),
        client.rpc("get_production_intelligence_forward_capacity",{p_week_start:null,p_weeks:6})]);
      if(dashboard.error)throw dashboard.error;if(seasonality.error)throw seasonality.error;if(capacity.error)throw capacity.error;
      renderForecasts(dashboard.data||{});renderSeasonality(seasonality.data||{});renderCapacity(capacity.data||{});setMessage("");
    }catch(error){console.error(error);state.planningLoaded=false;setMessage(error.message||"Planning could not be loaded.","error");}
  }
  function renderForecasts(data){
    const forecasts=data.forecasts||[];$("insightsForecastCount").textContent=`${forecasts.length} customer${forecasts.length===1?"":"s"}`;
    $("insightsForecasts").innerHTML=forecasts.length?`<div class="production-insights-forecast-head"><span>Customer</span><span>Last actual</span><span>4-week average</span><span>Next estimate</span><span>Confidence</span></div>${forecasts.map(f=>`<article class="production-insights-forecast"><span><strong>${esc(f.customer_name)}</strong><small>${esc(f.product_code)} · ${Number(f.history_points||0)} records</small></span><span><strong>${kg(f.last_actual_kg)}</strong><small>${fmt(f.last_actual_date)}</small></span><span>${f.four_week_average_kg==null?"—":kg(f.four_week_average_kg)}</span><span><strong>${f.forecast_kg==null?"Learning":kg(f.forecast_kg)}</strong></span><span class="production-insights-status ${f.status==="READY"?"ready":""}">${esc(f.confidence)}</span></article>`).join("")}`:empty("The learning model will start when official production records are available.");
  }
  function renderSeasonality(data){
    const months=data.monthly||[];$("insightsSeasonalityStatus").textContent=data.seasonality_status==="BASELINE_READY"?"Baseline ready":`Learning · ${Number(data.recorded_months||0)}/6 months`;
    const max=Math.max(1,...months.map(row=>Number(row.total_kg||0)));
    $("insightsMonthly").innerHTML=months.length?months.map(row=>`<article class="production-insights-month ${row.data_status==="NO_DATA"?"no-data":""}"><div class="production-insights-month-bars"><i style="height:${Math.max(2,Number(row.finish_kg||0)/max*110)}px" title="Finish ${kg(row.finish_kg)}"></i><i class="mop" style="height:${Math.max(2,Number(row.mop_kg||0)/max*110)}px" title="MOP ${kg(row.mop_kg)}"></i></div><small><b>${kg(row.total_kg)}</b>${fmt(row.month_start,{month:"short",year:"2-digit"})}</small></article>`).join(""):empty("No monthly history is available.");
  }
  function renderCapacity(data){
    const weeks=data.weeks||[],days=data.days||[],labels={LEARNING:"Learning",ROSTER_NOT_PUBLISHED:"Roster not published",AT_RISK:"At risk",WATCH:"Watch",COVERED:"Covered"};
    const learningDays=days.filter(row=>row.capacity_status==="LEARNING").length,riskDays=days.filter(row=>row.capacity_status==="AT_RISK").length,unpublishedDays=days.filter(row=>row.capacity_status==="ROSTER_NOT_PUBLISHED").length;
    $("insightsCapacityStatus").textContent=learningDays?`${learningDays} learning day${learningDays===1?"":"s"}`:riskDays?`${riskDays} day${riskDays===1?"":"s"} at risk`:unpublishedDays?`${unpublishedDays} roster day${unpublishedDays===1?"":"s"} missing`:"Capacity view ready";
    $("insightsCapacityWeeks").innerHTML=weeks.length?weeks.map(week=>`<article class="production-insights-capacity-week"><span>Week of ${fmt(week.week_start)}</span><strong>${kg(week.finish_forecast_kg)} ${Number(week.finish_learning_services||0)?"known ":""}Finish</strong><small>${kg(week.mop_forecast_kg)} known MOP (separate)</small><small>${week.finish_capacity_kg==null?"Finish roster not published":`${kg(week.finish_capacity_kg)} Finish capacity`}</small><small>${Number(week.learning_services||0)} services learning${Number(week.risk_days||0)?` · ${Number(week.risk_days)} risk day(s)`:""}</small></article>`).join(""):empty("No forward schedule is available.");
    $("insightsCapacityDays").innerHTML=days.length?`<div class="production-insights-capacity-head"><span>Date</span><span>Finish demand</span><span>MOP demand</span><span>Finish capacity</span><span>Finish staff</span><span>Learning</span><span>Status</span></div>${days.map(day=>`<article class="production-insights-capacity-day"><span><strong>${fmt(day.work_date)}</strong><small>${Number(day.scheduled_services||0)} scheduled services</small></span><span><strong>${kg(day.finish_forecast_kg)}</strong>${Number(day.finish_learning_services||0)?"<small>Known demand only</small>":""}</span><span>${kg(day.mop_forecast_kg)}<small>Not counted as Finish load</small></span><span>${day.finish_capacity_kg==null?"—":`<strong>${kg(day.finish_capacity_kg)}</strong><small>${Number(day.finish_staff_hours||0).toFixed(1)} staff hours</small>`}</span><span>${Number(day.finish_staff||0)}</span><span>${Number(day.learning_services||0)}<small>${Number(day.learned_services||0)} learned</small></span><span><i class="production-insights-capacity-pill ${String(day.capacity_status||"").toLowerCase()}">${esc(labels[day.capacity_status]||day.capacity_status)}</i>${day.capacity_status==="LEARNING"?"<small>Demand is not complete yet</small>":""}</span></article>`).join("")}`:empty("No forward schedule is available.");
  }

  // Events ----------------------------------------------------------------------------
  document.querySelectorAll("[data-tab]").forEach(b=>b.addEventListener("click",()=>setTab(b.dataset.tab)));
  document.querySelectorAll("[data-period]").forEach(b=>b.addEventListener("click",()=>{state.period=b.dataset.period;loadManager();}));
  $("insightsPrev").addEventListener("click",()=>shiftAnchor(-1));
  $("insightsNext").addEventListener("click",()=>shiftAnchor(1));
  $("insightsToday").addEventListener("click",()=>{state.anchor=new Date();state.anchor.setHours(0,0,0,0);$("insightsAnchor").value=iso(state.anchor);loadManager();});
  $("insightsAnchor").addEventListener("change",()=>{if(!$("insightsAnchor").value)return;state.anchor=parse($("insightsAnchor").value);loadManager();});
  $("customersSearch").addEventListener("input",renderCustomers);
  $("customersProduct").addEventListener("change",renderCustomers);
  $("customersTable").addEventListener("click",event=>{const button=event.target.closest("[data-customer-history-id]");if(button)loadCustomerHistory(button.dataset.customerHistoryId,button.dataset.customerHistoryName);});
  $("insightsCustomerHistoryClose").addEventListener("click",()=>{$("insightsCustomerHistoryCard").hidden=true;});
  const moveDaily=n=>{const base=state.dailyDate?parse(state.dailyDate):new Date();state.dailyDate=iso(addDays(base,n));$("dailyDate").value=state.dailyDate;loadDaily();};
  $("dailyPrev").addEventListener("click",()=>moveDaily(-1));
  $("dailyNext").addEventListener("click",()=>moveDaily(1));
  $("dailyToday").addEventListener("click",()=>{state.dailyDate=null;loadDaily();});
  $("dailyDate").addEventListener("change",()=>{if(!$("dailyDate").value)return;state.dailyDate=$("dailyDate").value;loadDaily();});
  $("dailyPrint").addEventListener("click",()=>window.print());
  $("dailyFilter").addEventListener("click",event=>{const b=event.target.closest("[data-filter]");if(!b)return;state.dailyFilter=b.dataset.filter;renderDailyCustomers();});

  try{
    if(window.ELIS_SUPABASE_ERROR||!client)throw new Error(window.ELIS_SUPABASE_ERROR||"Supabase could not be initialized.");
    const {data:{session},error}=await client.auth.getSession();if(error)throw error;
    if(!session?.user){location.href="../index.html";return;}
    const params=new URLSearchParams(location.search);
    state.anchor=new Date();state.anchor.setHours(0,0,0,0);$("insightsAnchor").value=iso(state.anchor);
    if(params.get("date")){state.dailyDate=params.get("date");}
    setTab(params.get("view")||"overview",false);
  }catch(error){console.error(error);setMessage(error.message||"Production Intelligence could not be initialized.","error");}
});
