import {mobileRequest} from './mobile';
import {DurableObject} from 'cloudflare:workers';
import {authenticated,boundedBody,demand,digest,operationPattern,schoolPattern,signature} from './protocol';
type Json=Record<string,unknown>;
type Job={id:string;kind:string;payload:string;state:string;due:number;claim:string;claim_until:number;created:number;response:string|null;revision:string|null};
export class SyncLane extends DurableObject<Env>{
 constructor(ctx:DurableObjectState,env:Env){super(ctx,env);ctx.blockConcurrencyWhile(async()=>{
  ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)');
  ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS jobs (seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,kind TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,due INTEGER NOT NULL,claim TEXT NOT NULL DEFAULT \'\',claim_until INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL,response TEXT,revision TEXT)');
  ctx.storage.sql.exec('CREATE INDEX IF NOT EXISTS due_jobs ON jobs(state,due,seq)');
  ctx.storage.sql.exec('CREATE INDEX IF NOT EXISTS revision_jobs ON jobs(revision)');
  ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS lanes (name TEXT PRIMARY KEY,due INTEGER NOT NULL,attention INTEGER NOT NULL DEFAULT 0)');
  if(!ctx.storage.sql.exec<{name:string}>('PRAGMA table_info(lanes)').toArray().some(c=>c.name==='attention'))ctx.storage.sql.exec('ALTER TABLE lanes ADD COLUMN attention INTEGER NOT NULL DEFAULT 0');
  ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY,body TEXT NOT NULL)');
 });}
 private meta(key:string):string|undefined{return this.ctx.storage.sql.exec<{value:string}>('SELECT value FROM metadata WHERE key=?',key).toArray()[0]?.value;}
 private setMeta(key:string,value:string){this.ctx.storage.sql.exec('INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',key,value);}
 private job(id:string):Job|undefined{return this.ctx.storage.sql.exec<Job>('SELECT * FROM jobs WHERE id=?',id).toArray()[0];}
 async command(school:string,lane:string,b:Json):Promise<unknown>{
  demand(schoolPattern.test(school)&&/^(?:attendance-[a-f0-9]{2}|notices|delivery)$/.test(lane));
  const identity=school+'/'+lane;demand(!this.meta('identity')||this.meta('identity')===identity,'School scope rejected',403);this.setMeta('identity',identity);
  const action=String(b.command||''),id=String(b.id||'');
  if(action==='schedule'){demand(lane==='delivery'&&typeof b.sourceLane==='string'&&/^(?:attendance-[a-f0-9]{2}|notices)$/.test(b.sourceLane));this.ctx.storage.sql.exec('INSERT INTO lanes(name,due) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET due=min(lanes.due,excluded.due)',b.sourceLane,Date.now());await this.wake(Date.now()+250);return true;}
  if(action==='stats'&&lane==='delivery')return this.ctx.storage.sql.exec<{pendingPartitions:number;needsAttention:number}>('SELECT count(*) AS pendingPartitions,coalesce(sum(attention),0) AS needsAttention FROM lanes').toArray()[0];
  if(action==='stats'){const stats=this.ctx.storage.sql.exec<{pending:number;due:number}>('SELECT count(*) AS pending,min(due) AS due FROM jobs WHERE state IN (\'pending\',\'retry\',\'processing\')').toArray()[0];const attention=this.ctx.storage.sql.exec<{needsAttention:number}>('SELECT count(*) AS needsAttention FROM jobs WHERE state=\'needsAttention\'').toArray()[0];return {...stats,...attention};}
  if(action==='get'){demand(operationPattern.test(id));return this.job(id)||null;}
  if(action==='pending'){
   const limit=Number(b.limit);demand(Number.isInteger(limit)&&limit>=1&&limit<=200);
   // Preserve FIFO notice revisions; a retry cannot be overtaken by a newer edit.
   const rows=this.ctx.storage.sql.exec<Job>('SELECT * FROM jobs WHERE state IN (\'pending\',\'retry\',\'processing\') ORDER BY seq LIMIT ?',limit).toArray();
   return lane==='notices'?rows.slice(0,1).filter(r=>r.due<=Date.now()):rows.filter(r=>r.due<=Date.now());
  }
  if(action==='claim'){
   const row=this.job(id);if(!row||!['pending','retry','processing'].includes(row.state)||row.due>Date.now()||row.state==='processing'&&row.claim_until>Date.now())return false;
   demand(typeof b.claim==='string'&&b.claim.length<=100&&Number.isSafeInteger(b.expires)&&Number(b.expires)>Date.now()&&Number(b.expires)<=Date.now()+180000);
   this.ctx.storage.sql.exec('UPDATE jobs SET state=\'processing\',claim=?,claim_until=?,due=? WHERE id=?',b.claim,Number(b.expires),Number(b.expires),id);return true;
  }
  if(action==='finish'){
   const row=this.job(id);if(!row||row.claim!==b.claim||!row.claim)return false;
   const values=b.values as Json;demand(values&&['completed','retry','needsAttention'].includes(String(values.state))&&Number.isSafeInteger(values.nextAttemptAt));
   this.ctx.storage.sql.exec('UPDATE jobs SET state=?,due=?,claim=\'\',claim_until=0,response=? WHERE id=?',String(values.state),Number(values.nextAttemptAt),JSON.stringify(values),id);
   if(values.state==='retry')await this.wake(Number(values.nextAttemptAt));return true;
  }
  if(action==='create'){
   demand(lane.startsWith('attendance-')&&operationPattern.test(id));const row=b.row as Json;demand(row&&row.schoolId===school&&row.operationId===id&&id.slice(0,2)===lane.slice(-2));
   if(this.job(id))return false;
   this.ctx.storage.sql.exec('INSERT INTO jobs(id,kind,payload,state,due,created) VALUES(?,\'attendance\',?,\'pending\',?,?)',id,JSON.stringify(row),Date.now(),Number(row.createdAt));await this.wake(Date.now()+250);return true;
  }
  demand(lane==='notices');
  if(action==='seed'){
   if(this.meta('initialized'))return {seeded:false};const records=b.records as Record<string,Json>;demand(records&&typeof records==='object'&&Object.keys(records).length<=10000);
   this.ctx.storage.transactionSync(()=>{for(const [key,value]of Object.entries(records)){demand(key.length>0&&key.length<=200&&!key.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(key)&&value.schoolId===school);this.ctx.storage.sql.exec('INSERT INTO records(id,body) VALUES(?,?)',key,JSON.stringify(value));}this.setMeta('revision',String(b.revision||'legacy'));this.setMeta('initialized','1');});return {seeded:true};
  }
  if(action==='snapshot'){
   const initialized=!!this.meta('initialized'),records:Record<string,Json>={};
   for(const row of this.ctx.storage.sql.exec<{id:string;body:string}>('SELECT id,body FROM records LIMIT 10001'))records[row.id]=JSON.parse(row.body) as Json;
   demand(Object.keys(records).length<=10000,'Notice snapshot too large',413);return {initialized,records,revision:this.meta('revision')||'legacy'};
  }
  if(action==='receipt'){
   demand(typeof b.revision==='string');const row=this.ctx.storage.sql.exec<Job>('SELECT * FROM jobs WHERE revision=?',b.revision).toArray()[0];
   return row?{state:row.state,response:row.response?JSON.parse(row.response):null}:null;
  }
  if(action==='write'){
   demand(this.meta('initialized'),'Notice baseline required',409);const request=b.request as Json;demand(request&&['write','delete'].includes(String(request.operation))&&request.syncProtocol===2&&typeof request.id==='string'&&request.id.length>0&&request.id.length<=200&&!request.id.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(request.id)&&/^[A-Za-z0-9_-]{16,100}$/.test(String(request.operationId)));
   const key=await digest(JSON.stringify([school,request.operationId]));const fingerprint=await digest(JSON.stringify(request));const prior=this.job(key);
   if(prior){const saved=JSON.parse(prior.payload) as Json;demand(saved.fingerprint===fingerprint,'Sync operation ID conflict',409);return saved.ack;}
   const revision='cf-'+crypto.randomUUID(),collectionRevision='cf-'+crypto.randomUUID();
   const ack=this.ctx.storage.transactionSync(()=>{
    const currentRow=this.ctx.storage.sql.exec<{body:string}>('SELECT body FROM records WHERE id=?',String(request.id)).toArray()[0];const current=currentRow?JSON.parse(currentRow.body) as Json:null;
    demand((current?String(current._syncRevision||''):'')===request.expectedRecordRevision,'Record revision conflict',409);
    let data=request.operation==='delete'?{schoolId:school,_syncDeleted:true}:structuredClone(request.data) as Json;
    demand(data&&data.schoolId===school);const patch=data._syncFieldPatch as Json|undefined;
    if(patch){demand(current&&!current._syncDeleted&&patch.version===1&&patch.set&&typeof patch.set==='object'&&!Array.isArray(patch.set)&&Array.isArray(patch.remove)&&Object.keys(patch.set).length+patch.remove.length<=256);for(const field of [...Object.keys(patch.set),...patch.remove as string[]]){demand(typeof field==='string'&&field.length>0&&field.length<=200&&!['id','schoolId','createdAt','__proto__','prototype','constructor'].includes(field)&&!field.startsWith('_sync'));}data={...current,...patch.set as Json};for(const field of patch.remove as string[]){demand(typeof field==='string'&&!['id','schoolId','createdAt','__proto__','prototype','constructor'].includes(field)&&!field.startsWith('_sync'));delete data[field];}}
    delete data._syncFieldPatch;const fields={...(current?._syncFieldRevisions as Record<string,string>||{})};
    for(const field of new Set([...Object.keys(current||{}),...Object.keys(data)])){if(field.startsWith('_sync')||field==='id'||field==='schoolId')continue;if(JSON.stringify(current?.[field])!==JSON.stringify(data[field]))fields[field]=revision;}
    const record={...data,id:request.id,schoolId:school,_syncRevision:revision,_syncOperationId:request.operationId,_syncFieldRevisions:fields};
    const result={success:true,schoolId:school,syncProtocol:2,recordRevision:revision,collectionRevision,record:record,cloudflareAccepted:true,driveState:'pending'};
    const payload={request,fingerprint,ack:result,record,baseRevision:request.expectedRecordRevision};
    this.ctx.storage.sql.exec('INSERT INTO jobs(id,kind,payload,state,due,created,revision) VALUES(?,\'notice\',?,\'pending\',?,?,?)',key,JSON.stringify(payload),Date.now(),Date.now(),revision);
    this.ctx.storage.sql.exec('INSERT INTO records(id,body) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',String(request.id),JSON.stringify(record));this.setMeta('revision',collectionRevision);return result;
   });await this.wake(Date.now()+250);return ack;
  }
  throw Object.assign(new Error('Unknown sync command'),{status:400});
 }
 private async wake(at:number){const existing=await this.ctx.storage.getAlarm();if(existing===null||existing>at)await this.ctx.storage.setAlarm(Math.max(Date.now()+100,at));}
 async alarm(){
  const identity=this.meta('identity');if(!identity)return;const [school,lane]=identity.split('/');
  if(lane!=='delivery'){await this.env.LANES.getByName(school+'/delivery').command(school,'delivery',{command:'schedule',sourceLane:lane});return;}
  const next=this.ctx.storage.sql.exec<{name:string;due:number}>('SELECT name,due FROM lanes WHERE due < 9007199254740991 ORDER BY due,name LIMIT 1').toArray()[0];
  const backoff=Number(this.meta('deliveryBackoff')||0);if(backoff>Date.now()){await this.ctx.storage.setAlarm(backoff);return;}
  if(!next)return;if(next.due>Date.now()){await this.ctx.storage.setAlarm(next.due);return;}
  const raw=JSON.stringify({action:'managed/cloudflare/drain',schoolId:school,lane:next.name}),time=String(Date.now());
  let delay=30_000;
  try{const response=await fetch(this.env.BROKER_URL,{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer cloudflare-delivery','X-Vidya-Time':time,'X-Vidya-Signature':await signature(this.env.EDGE_KEY,time+'\n'+raw)},body:raw,signal:AbortSignal.timeout(110000)});if(response.ok)delay=250;await response.body?.cancel();}catch{ /* Durable rows remain; retry after broker outage. */ }
  if(delay>=30000)this.setMeta('deliveryBackoff',String(Date.now()+delay));else this.setMeta('deliveryBackoff','0');
  const stats=await this.env.LANES.getByName(school+'/'+next.name).command(school,next.name,{command:'stats'}) as {pending:number;due:number;needsAttention:number};
  if(stats.pending===0&&stats.needsAttention===0)this.ctx.storage.sql.exec('DELETE FROM lanes WHERE name=?',next.name);
  else this.ctx.storage.sql.exec('UPDATE lanes SET due=?,attention=? WHERE name=?',stats.pending===0?Number.MAX_SAFE_INTEGER:Math.max(Date.now()+delay,stats.due),stats.needsAttention,next.name);
  const due=this.ctx.storage.sql.exec<{due:number}>('SELECT min(due) AS due FROM lanes WHERE due < 9007199254740991').toArray()[0]?.due;
  if(due!==null&&due!==undefined)await this.ctx.storage.setAlarm(Math.max(Date.now()+100,due));
 }

}
export default {
 async fetch(request:Request,env:Env):Promise<Response>{
  const headers={'Cache-Control':'no-store','Content-Type':'application/json','X-Content-Type-Options':'nosniff'};
  try{
   const url=new URL(request.url);if(url.pathname==='/healthz'&&request.method==='GET')return Response.json({service:'vidya-saarthi-cloudflare-sync',version:1,attendancePartitions:256},{headers});
   if(request.method==='POST'&&url.pathname==='/mobile')return Response.json(await mobileRequest(request,env),{headers});
   demand(request.method==='POST'&&url.pathname==='/internal','Not found',404);const raw=await boundedBody(request);
   demand(await authenticated(env.EDGE_KEY,raw,request.headers),'Sync authorization rejected',401);
   const body=JSON.parse(raw) as Json,school=String(body.schoolId||''),lane=String(body.lane||'');demand(schoolPattern.test(school)&&/^(?:attendance-[a-f0-9]{2}|notices|delivery)$/.test(lane));
   const value=await env.LANES.getByName(school+'/'+lane).command(school,lane,body);
   return Response.json({success:true,schoolId:school,value},{headers});
  }catch(error){const e=error as Error&{status?:number};const status=e.status||503;return Response.json({success:false,message:status<500?e.message:'Cloudflare sync unavailable; pending work retained.'},{status,headers});}
 }
} satisfies ExportedHandler<Env>;
