// Repository copy of the live legacy-sync-ingest Edge Function (version 2, deployed 2026-10-26,
// JWT verification OFF), taken read-only on 2026-10-27. Not redeployed from here. It compares
// and lands Apps Script rows only in integration.legacy_inbox; it never writes operational V2 data.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.10';
const allowed = new Set(['central','finish','sorting','roster','distribution']);
const send=(status:number,data:unknown)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json','cache-control':'no-store'}});
Deno.serve(async(req)=>{
  if(req.method!=='POST')return send(405,{ok:false,error:'Method not allowed'});
  const token=Deno.env.get('LEGACY_SYNC_TOKEN');
  if(!token||req.headers.get('x-legacy-sync-token')!==token)return send(401,{ok:false,error:'Unauthorized'});
  try {
    const body=await req.json();
    if(!['compare','ingest'].includes(body.operation)||!Array.isArray(body.records)||body.records.length>100||!body.records.length)return send(400,{ok:false,error:'Invalid request'});
    const rows=body.records;
    for(const r of rows){
      if(!allowed.has(r.source)||typeof r.sheet!=='string'||!r.sheet||r.sheet.length>100||typeof r.recordKey!=='string'||!r.recordKey||r.recordKey.length>300||!/^[a-f0-9]{64}$/.test(r.hash))return send(400,{ok:false,error:'Invalid identity'});
      if(body.operation==='ingest'&&(!/^\d{4}-\d{2}-\d{2}$/.test(r.businessDate)||!Number.isInteger(r.rowNumber)||r.rowNumber<2||!r.payload||typeof r.payload!=='object'||Array.isArray(r.payload)))return send(400,{ok:false,error:'Invalid record'});
    }
    const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{db:{schema:'integration'},auth:{persistSession:false}});
    // Compare is scoped to just the small collection of source identities in this request.
    const grouped=new Map<string,typeof rows>();
    for(const r of rows){const key=r.source+'\u0000'+r.sheet;grouped.set(key,[...(grouped.get(key)||[]),r]);}
    const current=new Map<string,string>();
    for(const group of grouped.values()){
      const {data,error}=await db.from('legacy_inbox').select('source,sheet_name,record_key,content_hash').eq('source',group[0].source).eq('sheet_name',group[0].sheet).in('record_key',group.map(r=>r.recordKey));
      if(error)return send(500,{ok:false,error:'Inbox lookup failed; check integration schema API exposure / privileges'});
      for(const r of data||[])current.set(JSON.stringify([r.source,r.sheet_name,r.record_key]),r.content_hash);
    }
    const statusFor=(r:any)=>{const hash=current.get(JSON.stringify([r.source,r.sheet,r.recordKey]));return hash===undefined?'NEW':hash===r.hash?'SAME':'CHANGED'};
    if(body.operation==='compare')return send(200,{ok:true,statuses:rows.map(statusFor)});
    if(typeof body.runId!=='string'||!/^[0-9a-f-]{36}$/i.test(body.runId))return send(400,{ok:false,error:'Invalid run ID'});
    // Race-safe insert-only. Two concurrent calls cannot overwrite prior content.
    const fresh=rows.filter(r=>statusFor(r)==='NEW').map(r=>({source:r.source,sheet_name:r.sheet,record_key:r.recordKey,business_date:r.businessDate,content_hash:r.hash,payload:r.payload,import_run_id:body.runId}));
    if(!fresh.length)return send(200,{ok:true,inserted:0});
    const {data,error}=await db.from('legacy_inbox').upsert(fresh,{onConflict:'source,sheet_name,record_key',ignoreDuplicates:true}).select('id');
    if(error)return send(500,{ok:false,error:'Inbox write failed'});
    return send(200,{ok:true,inserted:(data||[]).length});
  }catch{return send(400,{ok:false,error:'Invalid request'});}
});
