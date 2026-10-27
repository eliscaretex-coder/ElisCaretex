"use strict";

// Legacy Sync control (temporary, administrators only). The database decides access:
// for anyone else legacy_sync_control_status() fails and the panel stays hidden.
document.addEventListener("DOMContentLoaded", () => {
  const client = window.elisSupabase;
  const root = document.getElementById("legacySyncControl");
  if (!client || !root) return;
  const $ = (id) => document.getElementById(id);
  const el = { state:$("legacySyncState"), toggle:$("legacySyncToggle"), now:$("legacySyncNow"), info:$("legacySyncInfo"), message:$("legacySyncMessage"), runs:$("legacySyncRuns") };
  const esc=(v)=>String(v??"").replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&#039;");
  const fmtWhen=(v)=>v?new Intl.DateTimeFormat("en-IE",{day:"2-digit",month:"short",hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"Europe/Dublin"}).format(new Date(v)):"—";
  const fmtDay=(v)=>v?new Intl.DateTimeFormat("en-IE",{day:"2-digit",month:"short",timeZone:"UTC"}).format(new Date(`${v}T12:00:00Z`)):"—";
  const minutesAgo=(v)=>v?Math.round((Date.now()-new Date(v).getTime())/60000):null;
  const LABELS={IMPORTED:"new",UPDATED:"updated",ADOPTED:"matched",ADOPTED_AND_UPDATED:"matched + updated",BLOCKED:"to review",RUN_LIMIT_REACHED:"run limit"};
  let status=null, timer=null, busy=false;

  function setMessage(text="",type=""){el.message.textContent=text;el.message.className=`legacy-sync-message ${type}`.trim();}

  function resultText(results){
    if(!results||typeof results!=="object")return "";
    return [["normal","Finish"],["rewash","ReWash"]].map(([key,name])=>{
      const counts=results[key]||{};
      const parts=Object.entries(counts).filter(([k,v])=>k!=="refusal"&&Number(v)>0).map(([k,v])=>`${v} ${LABELS[k]||(k.startsWith("REFUSED_")?"refused":k.toLowerCase())}`);
      return parts.length?`${name}: ${parts.join(", ")}`:"";
    }).filter(Boolean).join(" · ")||"Nothing new";
  }

  function reasonText(requestedBy){
    const m=/\((NIGHTLY|REQUEST|MANUAL)\)/.exec(String(requestedBy||""));
    return m?{NIGHTLY:"Nightly",REQUEST:"Sync now",MANUAL:"Manual"}[m[1]]:"Manual";
  }

  function render(){
    const s=status, on=Boolean(s.auto_enabled), pending=Boolean(s.request_pending);
    root.hidden=false;
    el.state.textContent=on?"ON":"OFF";
    el.state.className=`legacy-sync-state ${on?"on":"off"}`;
    el.toggle.textContent=on?"Turn off":"Turn on";
    el.now.disabled=!on||pending||busy;
    el.now.textContent=pending?"Waiting for the sheet…":"Sync now";
    el.toggle.disabled=busy;
    const seen=minutesAgo(s.last_poll_at);
    const seenText=seen===null?"The Apps Script has not checked in yet.":seen>15?`The Apps Script last checked ${seen} minutes ago: check its trigger.`:`The Apps Script checked ${seen<1?"less than a minute":`${seen} min`} ago.`;
    el.info.innerHTML=`<span>${on?`Runs every night between ${esc(s.night_from)} and ${esc(s.night_until)} (Dublin) for the last ${Number(s.window_days||0)} days.`:"Off: nothing is copied from the legacy sheets."}</span><span class="${seen===null||seen>15?"warn":""}">${esc(seenText)}</span><span>${Number(s.open_review_items||0)} record(s) waiting for review.</span>`;
    const runs=s.runs||[];
    el.runs.innerHTML=runs.length?`<div class="legacy-sync-run head"><span>Started</span><span>Type</span><span>Days</span><span>Status</span><span>Result</span></div>${runs.map(r=>{const st=String(r.status||"");return `<div class="legacy-sync-run"><span>${esc(fmtWhen(r.started_at))}</span><span>${esc(reasonText(r.requested_by))}</span><span>${esc(fmtDay(r.date_from))}–${esc(fmtDay(r.date_to))}</span><b class="${esc(st.toLowerCase())}">${esc(st)}</b><small>${esc(r.summary?.error?`Error: ${r.summary.error}`:resultText(r.summary?.results))}</small></div>`;}).join("")}`:'<div class="legacy-sync-empty">No runs yet.</div>';
    clearTimeout(timer);
    if(pending||runs.some(r=>r.status==="RUNNING"))timer=setTimeout(load,30000);
  }

  async function call(name,args){
    const {data,error}=await client.rpc(name,args);
    if(error)throw error;
    return data;
  }

  async function load(){
    try{status=await call("legacy_sync_control_status");render();}
    catch{root.hidden=true;}
  }

  async function act(name,args,done){
    busy=true;render();setMessage("");
    try{status=await call(name,args);setMessage(done,"success");}
    catch(error){setMessage(error?.message||"The request failed.","error");}
    finally{busy=false;render();}
  }

  el.toggle.addEventListener("click",()=>{
    const on=!status?.auto_enabled;
    if(!on&&!window.confirm("Turn the legacy sync off? Nothing will be copied until it is turned on again."))return;
    act("legacy_sync_set_auto",{p_enabled:on},on?"Legacy sync is on.":"Legacy sync is off.");
  });
  el.now.addEventListener("click",()=>act("legacy_sync_request_now",{},"Requested. The sheet is read within 5 minutes."));

  load();
});
