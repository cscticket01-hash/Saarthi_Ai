import {boundedBody,demand,digest,signature} from './protocol';
type Policy={schoolId:string;sessionHash:string;expiresAt:number;role:string;personId:string;documentId:string;qrHash:string;day:string;open:boolean;latitude:number;longitude:number;radiusMeters:number;schedule?:{enabled:boolean;startMinute:number;endMinute:number}};
export async function mobileRequest(request:Request,env:Env):Promise<unknown>{
 const raw=await boundedBody(request,20000),body=JSON.parse(raw) as {grant:string;schoolId:string;request:Record<string,unknown>};
 demand(typeof body.grant==='string'&&body.grant.length<12000,'Refresh attendance approval',409);
 const [value,sig]=body.grant.split('.');demand(!!value&&/^[a-f0-9]{64}$/.test(sig||''),'Refresh attendance approval',409);
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(env.EDGE_KEY),{name:'HMAC',hash:'SHA-256'},false,['verify']);
 demand(await crypto.subtle.verify('HMAC',key,new Uint8Array(sig.match(/../g)!.map(x=>parseInt(x,16))),new TextEncoder().encode(value)),'Refresh attendance approval',409);
 const p=JSON.parse(atob(value.replace(/-/g,'+').replace(/_/g,'/'))) as Policy;
 const b=body.request;
 demand(p.schoolId===body.schoolId&&p.expiresAt>Date.now()&&p.sessionHash===await digest(String(b.sessionToken||''))&&p.role===b.role&&p.documentId===b.personId&&p.qrHash===await digest(p.role+'/'+b.personId+'/'+b.linkToken),'Refresh attendance approval',409);
 const school=p.schoolId,action=String(b.action||'');
 if(action==='mobile_notice'||action==='mobile_notice_list'){
  const snapshot=await env.LANES.getByName(school+'/notices').command(school,'notices',{command:'snapshot'}) as {initialized:boolean;records:Record<string,Record<string,unknown>>;revision:string};
  demand(snapshot.initialized,'Notice baseline is pending',503);
  if(action==='mobile_notice'){const notice=snapshot.records[String(b.noticeId||'')];demand(notice&&!notice._syncDeleted,'School notice unavailable',404);return {success:true,schoolId:school,projectId:school,notice};}
  return {success:true,schoolId:school,projectId:school,revision:snapshot.revision,notices:Object.entries(snapshot.records).filter(([,v])=>!v._syncDeleted).map(([id,v])=>({...v,id,_noticeRevision:v._syncRevision})).sort((a,b)=>Number((b as Record<string,unknown>).timestamp||(b as Record<string,unknown>).createdAt||0)-Number((a as Record<string,unknown>).timestamp||(a as Record<string,unknown>).createdAt||0)).slice(0,100)};
 }
 const ids=await Promise.all(['entry','exit'].map(mode=>digest(JSON.stringify([school,p.role,p.personId,p.day,mode]))));
 if(action==='mobile_attendance_status'){
  demand(Array.isArray(b.operationIds)&&b.operationIds.length<=2&&(b.operationIds as unknown[]).every(id=>ids.includes(String(id))));
  const operations=await Promise.all((b.operationIds as string[]).map(async id=>{
   const row=await env.LANES.getByName(school+'/attendance-'+id.slice(0,2)).command(school,'attendance-'+id.slice(0,2),{command:'get',id}) as {state:string;created:number;response:string}|null;
   const receipt=row?.response?JSON.parse(row.response) as {completedAt?:number}:{};
   return {operationId:id,state:row?.state||'unknown',createdAt:row?.created??null,...(row?.state==='completed'?{completedAt:receipt.completedAt}:{})};
  }));return {success:true,schoolId:school,projectId:school,syncProtocol:2,operations};
 }
 demand(action==='mobile_mark_attendance');
 demand(p.open===true,'School is closed today. Attendance is disabled for everyone');
 const captured=b.clientCapturedAt??Date.now();demand(Number.isSafeInteger(captured)&&Number(captured)>0&&Number(captured)<=Date.now()+120000&&new Date(Number(captured)+19800000).toISOString().slice(0,10)===p.day,'Attendance capture date needs school review',409);
 const at=new Date(Number(captured)+19800000),minute=at.getUTCHours()*60+at.getUTCMinutes(),w=p.schedule;
 if(p.role==='student'&&w&&w.enabled!==false)demand(w.enabled===true&&Number.isInteger(w.startMinute)&&Number.isInteger(w.endMinute)&&w.startMinute>=0&&w.endMinute<=1440&&w.startMinute<w.endMinute&&minute>=w.startMinute&&minute<w.endMinute,'Student attendance is outside the school schedule');
 const lat=Number(b.latitude),lng=Number(b.longitude),accuracy=Number(b.accuracy),radius=Number(p.radiusMeters);
 demand(Number.isFinite(lat)&&Number.isFinite(lng)&&Math.abs(lat)<=90&&Math.abs(lng)<=180&&Number.isFinite(accuracy)&&accuracy>=0&&accuracy<=radius&&radius>=25&&radius<=200&&Number.isFinite(p.latitude)&&Number.isFinite(p.longitude),'Accurate school location required');
 const rad=(x:number)=>x*Math.PI/180,h=Math.sin(rad(p.latitude-lat)/2)**2+Math.cos(rad(lat))*Math.cos(rad(p.latitude))*Math.sin(rad(p.longitude-lng)/2)**2;
 demand(6371000*2*Math.atan2(Math.sqrt(h),Math.sqrt(1-h))<=radius,'Attendance can be marked only within the school location');
 const mode=b.mode==='exit'?'exit':'entry',id=ids[mode==='exit'?1:0];
 const aes=await crypto.subtle.importKey('raw',await crypto.subtle.digest('SHA-256',new TextEncoder().encode(env.EDGE_KEY)),{name:'AES-GCM'},false,['encrypt']);
 const iv=crypto.getRandomValues(new Uint8Array(12));const encrypted=await crypto.subtle.encrypt({name:'AES-GCM',iv},aes,new TextEncoder().encode(JSON.stringify({...b,attendancePermit:undefined})));
 const encode=(bytes:Uint8Array)=>btoa(String.fromCharCode(...bytes));
 const row={operationId:id,schoolId:school,day:p.day,mode,payloadTransport:'cloudflare-v1',payload:{iv:encode(iv),body:encode(new Uint8Array(encrypted))},state:'pending',attempts:0,createdAt:Date.now(),nextAttemptAt:Date.now()};
 const created=await env.LANES.getByName(school+'/attendance-'+id.slice(0,2)).command(school,'attendance-'+id.slice(0,2),{command:'create',id,row});
 return {success:true,schoolId:school,projectId:school,syncProtocol:2,accepted:true,operationId:id,duplicate:!created,cloudflareAccepted:true,driveState:'pending',message:'Attendance saved to Cloudflare; Google Drive delivery pending.'};
}
