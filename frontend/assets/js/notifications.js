(() => {
  const escapeHtml=(v)=>String(v??"").replace(/[&<>"']/g,(c)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]));
  async function load(){
    const list=document.getElementById("notifyList");
    try{
      const {data:session}=await window.elisSupabase.auth.getSession();
      if(!session.session){location.replace("../index.html");return;}
      const {data,error}=await window.elisSupabase.rpc("get_my_notification_inbox");
      if(error) throw error;
      const items=data?.items||[];
      list.innerHTML=items.length?items.map((item)=>`<a class="notify-item${item.kind==="APPROVAL"?" action":""}" href="${escapeHtml(item.href||"#")}"><i class="notify-dot"></i><span class="notify-copy"><strong>${escapeHtml(item.title)}</strong><span>${escapeHtml(item.message)}</span></span><small class="notify-status">${escapeHtml(String(item.status||"").replaceAll("_"," "))}</small></a>`).join(""):'<p class="notify-empty">You have no notifications at the moment.</p>';
    }catch(error){list.innerHTML=`<p class="notify-empty">${escapeHtml(error.message||"Notifications could not be loaded.")}</p>`;}
  }
  document.addEventListener("DOMContentLoaded",()=>{document.getElementById("notifyReload").addEventListener("click",load);load();});
})();
