'use strict';
const fs=require('node:fs');
const pin=require('../acceptance/cloudflare-release.json');
const report={checks:[],expected:pin};
const root='https://saarthi-oauth-staging.onrender.com';
function check(name,ok,info={}){report.checks.push({name,status:ok?'PASS':'FAIL',...info});if(!ok)throw Error(name);}
async function request(url,options={}){
 let error;
 for(let attempt=0;attempt<3;attempt++){
  try{const r=await fetch(url,{...options,redirect:'error',signal:AbortSignal.timeout(180000)});if(r.status!==503||attempt===2)return r;await r.body?.cancel();}
  catch(e){error=e;if(attempt===2)throw e;}
  await new Promise(resolve=>setTimeout(resolve,5000));
 }
 throw error;
}
async function run(){
 for(const url of ['https://vidya-saarthi-sync.vidya-saarthi-cscticket01.workers.dev/healthz',root+'/school-cloud/healthz']){
  const r=await request(url),data=await r.json();
  check('live health '+new URL(url).host,r.status===200&&(url.includes('workers.dev')?data.version===2&&data.edgeDeliveryVersion===1:data.ready===true&&data.projectId==='saarthi-ai-df12b'),{http:r.status});
 }
 const denied=await request(root+'/school-cloud',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'managed/session'})});
 check('unauthenticated school access denied',denied.status===401,{http:denied.status});await denied.body?.cancel();
 const web=await request('https://vidyasaarthi.web.app'),html=await web.text();
 check('website live',web.status===200&&/<html/i.test(html),{http:web.status});
 for(const platform of ['windows','android']){
  const expected=pin[platform];check(platform+' immutable release pin',expected&&/^sha256:[a-f0-9]{64}$/.test(expected.digest)&&Number.isSafeInteger(expected.size)&&expected.size>0);
  const url=root+'/downloads/'+(platform==='windows'?'windows.exe':'android.apk');
  const r=await request(url,{method:'HEAD'});
  check(platform+' exact released download headers',r.status===200&&r.headers.get('x-saarthi-release')===expected.tag&&Number(r.headers.get('content-length'))===expected.size&&r.headers.get('etag')==='"'+expected.digest.slice(7)+'"',{http:r.status,release:r.headers.get('x-saarthi-release'),size:Number(r.headers.get('content-length')),etag:r.headers.get('etag')});
  const range=await request(url,{headers:{Range:'bytes=0-31'}}),bytes=new Uint8Array(await range.arrayBuffer());
  check(platform+' verified ranged binary',range.status===206&&range.headers.get('content-range')==='bytes 0-31/'+expected.size&&bytes.length===32&&(platform==='windows'?bytes[0]===0x4d&&bytes[1]===0x5a:bytes[0]===0x50&&bytes[1]===0x4b),{http:range.status,bytes:bytes.length});
 }
 report.status='PASS';
}
run().catch(error=>{report.status='FAIL';report.failedCheck=error.message;process.exitCode=1;}).finally(()=>{
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/release-public-proof.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
});
