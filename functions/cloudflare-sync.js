'use strict';
const {createHmac,timingSafeEqual,createHash,createDecipheriv}=require('node:crypto');
const {createProviderPressure,retryAfterMillis,quotaError}=require('./provider-pressure');
const SCHOOL=/^vs-[a-f0-9]{32}$/;
function createCloudflareSync({url,key,schools=[],fetchImpl=fetch,now=Date.now,providerPressureJournal=null}) {
 if(!url&&!key)return null;
 const endpoint=new URL(url);if(endpoint.protocol!=='https:'||endpoint.username||endpoint.password||endpoint.pathname!=='/'||endpoint.search||endpoint.hash||!key||key.length<32)throw Error('Invalid Cloudflare sync configuration');
 const scope=new Set(schools);if([...scope].some(s=>s!=='*'&&!SCHOOL.test(s)))throw Error('Invalid Cloudflare rollout school');
 const enabled=school=>SCHOOL.test(school)&&(scope.has(school)||scope.has('*'));
 const sign=raw=>{const timestamp=String(now());return {'X-Vidya-Time':timestamp,'X-Vidya-Signature':createHmac('sha256',key).update(timestamp+'\n'+raw).digest('hex')};};
 const verify=(body,headers)=>{const raw=JSON.stringify(body),timestamp=String(headers['x-vidya-time']||''),sig=String(headers['x-vidya-signature']||'');return /^\d{13}$/.test(timestamp)&&Math.abs(now()-Number(timestamp))<=60000&&/^[a-f0-9]{64}$/.test(sig)&&timingSafeEqual(createHmac('sha256',key).update(timestamp+'\n'+raw).digest(),Buffer.from(sig,'hex'));};
 const pressure=createProviderPressure({now,journal:providerPressureJournal});
 async function rpc(school,lane,body){if(!enabled(school))throw Error('Cloudflare school not enabled');return pressure.run(endpoint.origin,'CLOUDFLARE_QUOTA_EXCEEDED',()=>rpcRaw(school,lane,body));}
 async function rpcRaw(school,lane,body){
  if(!enabled(school))throw Error('Cloudflare school not enabled');
  const raw=JSON.stringify({...body,schoolId:school,lane});
  if(Buffer.byteLength(raw)>(/^file-[a-f0-9]{64}$/.test(lane)?800000:400000))throw Object.assign(Error('Sync request too large'),{status:413});
  const r=await fetchImpl(new URL('/internal',endpoint),{method:'POST',headers:{'Content-Type':'application/json','User-Agent':'Vidya-Saarthi-Sync/1',...sign(raw)},body:raw,signal:AbortSignal.timeout(15000)});
  if(r.status===429){await r.body?.cancel();throw quotaError('CLOUDFLARE_QUOTA_EXCEEDED',retryAfterMillis(r.headers?.get('retry-after'),now())||60000);}
  const reader=r.body?.getReader();let length=0;const parts=[];
  if(reader){try{for(;;){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>8*1024*1024){await reader.cancel();throw Error('Cloudflare response too large');}parts.push(Buffer.from(value));}}finally{reader.releaseLock();}}
  const result=JSON.parse(Buffer.concat(parts).toString('utf8'));
  if(!r.ok||result.success!==true||result.schoolId!==school){const message=result.message;throw Object.assign(Error(message==='Record revision conflict'||message==='Sync operation ID conflict'?message:'Cloudflare sync unavailable; pending work retained'),{status:r.status===409?409:503,code:message==='Record revision conflict'?'RECORD_REVISION_CONFLICT':message==='Sync operation ID conflict'?'OPERATION_ID_CONFLICT':'CLOUDFLARE_SYNC_UNAVAILABLE',publicMessage:true});}
  return result.value;
 }
 const lane=id=>'attendance-'+id.slice(0,2);
 const row=value=>{if(!value)return null;const original=JSON.parse(value.payload);return {...original,state:value.state,nextAttemptAt:value.due,claim:value.claim,claimExpiresAt:value.claim_until,...(value.response?JSON.parse(value.response):{})};};
 function attendanceStore(school,partition){return {
  create:async(id,value)=>{if(value.schoolId!==school)throw Error('Foreign attendance school');return rpc(school,lane(id),{command:'create',id,row:value});},
  get:async id=>row(await rpc(school,lane(id),{command:'get',id})),
  pending:async limit=>(await rpc(school,partition,{command:'pending',limit})).map(row),
  claim:async(id,claim,at,expires)=>rpc(school,lane(id),{command:'claim',id,claim,expires}),
  finish:async(id,claim,values)=>rpc(school,lane(id),{command:'finish',id,claim,values})
 };}
 async function notices(school,readDrive){let snapshot=await rpc(school,'notices',{command:'snapshot'});if(!snapshot.initialized){const baseline=await readDrive();if(baseline.syncProtocol!==2||!baseline.records||Object.values(baseline.records).some(r=>r.schoolId!==school))throw Error('Verified notice baseline required');await rpc(school,'notices',{command:'seed',records:baseline.records,revision:baseline.collectionRevision});snapshot=await rpc(school,'notices',{command:'snapshot'});}return snapshot;}
 async function writeNotice(school,request,readDrive){await notices(school,readDrive);return rpc(school,'notices',{command:'write',request});}
 async function drainNotices(school,deliver){
  const [job]=await rpc(school,'notices',{command:'pending',limit:1});if(!job)return {processed:0};
  const claim=require('node:crypto').randomUUID();if(!await rpc(school,'notices',{command:'claim',id:job.id,claim,expires:now()+120000}))return {processed:0};
  const payload=JSON.parse(job.payload),request={...payload.request};let expected=payload.baseRevision;
  try{
   if(String(expected).startsWith('cf-')){const parent=await rpc(school,'notices',{command:'receipt',revision:expected});if(parent?.state==='needsAttention')throw Object.assign(Error('Earlier notice requires school review'),{code:'RECORD_REVISION_CONFLICT'});if(parent?.state!=='completed'||typeof parent.response?.driveRevision!=='string')throw Error('Earlier notice delivery pending');expected=parent.response.driveRevision;}
   request.expectedRecordRevision=expected;
   if(request.operation==='write'){request.data=Object.fromEntries(Object.entries(payload.record).filter(([k])=>k!=='id'&&!k.startsWith('_sync')));}
   const ack=await deliver({...request,action:'managed_records',collection:'school_notices'});
   if(ack.syncProtocol!==2||typeof ack.recordRevision!=='string'||!ack.recordRevision)throw Error('Verified Drive receipt required');
   await rpc(school,'notices',{command:'finish',id:job.id,claim,values:{state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,completedAt:now(),driveRevision:ack.recordRevision}});return {processed:1};
  }catch(e){const attention=e.code==='RECORD_REVISION_CONFLICT';await rpc(school,'notices',{command:'finish',id:job.id,claim,values:{state:attention?'needsAttention':'retry',nextAttemptAt:attention?Number.MAX_SAFE_INTEGER:now()+Math.max(30000,Math.min(86400000,Number(e.retryAfterMs)||0)),lastError:attention?'Drive notice changed; school review required':'Drive delivery pending'}});return {processed:0};}
 }
 function grant(policy){if(!enabled(policy.schoolId)||!Number.isSafeInteger(policy.expiresAt)||policy.expiresAt<=now())return undefined;const expiresAt=Math.min(policy.expiresAt,now()+900000);const value=Buffer.from(JSON.stringify({...policy,expiresAt})).toString('base64url');return {endpoint:new URL('/mobile',endpoint).href,schoolId:policy.schoolId,expiresAt,grant:value+'.'+createHmac('sha256',key).update(value).digest('hex')};}
 function decryptAttendance(payload){const cipher=Buffer.from(payload.body,'base64'),iv=Buffer.from(payload.iv,'base64');if(iv.length!==12||cipher.length<17||cipher.length>20000)throw Error('Invalid edge attendance envelope');const decoder=createDecipheriv('aes-256-gcm',createHash('sha256').update(key).digest(),iv);decoder.setAuthTag(cipher.subarray(-16));return JSON.parse(Buffer.concat([decoder.update(cipher.subarray(0,-16)),decoder.final()]).toString('utf8'));}
 return {enabled,verify,rpc,attendanceStore,notices,writeNotice,drainNotices,grant,decryptAttendance};
}
module.exports={createCloudflareSync};
