'use strict';
const {createRequire}=require('node:module');
const {createDeveloperRecovery}=require('./developer-recovery.cjs');

function fromEnvironment(env){
 if(env.SAARTHI_STAGING_DEVELOPER_RECOVERY!=='true')return null;
 const key=JSON.parse(env.SAARTHI_RECOVERY_TEST_FIREBASE_ADMIN_JSON||'{}');
 const project=env.SAARTHI_RECOVERY_TEST_PROJECT;
 const uid=env.SAARTHI_RECOVERY_TEST_DEVELOPER_UID;
 const pepper=env.SAARTHI_DEVELOPER_OTP_PEPPER;
 const apiKey=env.SAARTHI_DEVELOPER_OTP_RESEND_API_KEY;
 const from=env.SAARTHI_DEVELOPER_OTP_FROM;
 const website=new URL(env.SAARTHI_RECOVERY_TEST_WEBSITE_ORIGIN);
 const broker=new URL(env.SAARTHI_RECOVERY_TEST_BROKER_ORIGIN);
 const validOrigin=url=>url.protocol==='https:'&&url.href===url.origin+'/';
 if(!project||project==='saarthi-ai-df12b'||key.project_id!==project||
    !uid||!pepper||pepper.length<32||!apiKey||!from||!validOrigin(website)||!validOrigin(broker))
  throw Error('Isolated developer recovery staging configuration required');
 const runtimeRequire=createRequire(require.resolve('./package.json'));
 const {initializeApp,cert}=runtimeRequire('firebase-admin/app');
 const {getAuth}=runtimeRequire('firebase-admin/auth');
 const {getFirestore}=runtimeRequire('firebase-admin/firestore');
 const app=initializeApp({credential:cert(key),projectId:project},'developer-recovery-test');
 const resetUrl=new URL('/developer-recovery',broker);
 const recover=createDeveloperRecovery({auth:getAuth(app),db:getFirestore(app),uid,pepper,apiKey,from,resetUrl});
 return createRecoveryHandler({recover,origins:[website.origin,broker.origin]});
}

function createRecoveryHandler({recover,origins}){
 let windowStart=0,requests=0;
 return async (req,res)=>{
  const respond=(status,body,type='application/json')=>{
   res.writeHead(status,{'Content-Type':type,'Referrer-Policy':'no-referrer'});
   res.end(type==='application/json'?JSON.stringify(body):body);
  };
  const origin=req.headers.origin;
  if(origin&&!origins.includes(origin))return respond(403,{success:false});
  if(origin){res.setHeader('Access-Control-Allow-Origin',origin);res.setHeader('Vary','Origin');}
  if(req.method==='GET'&&req.url==='/developer-recovery'){
   res.setHeader('Content-Security-Policy',"default-src 'none'; script-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
   return respond(200,resetPage,'text/html; charset=utf-8');
  }
  if(req.method==='GET'&&req.url==='/developer-recovery.js')
   return respond(200,resetScript,'text/javascript; charset=utf-8');
  if(req.url!=='/developer-recovery')return respond(404,{success:false});
  if(req.method==='OPTIONS'){
   res.writeHead(204,{'Access-Control-Allow-Methods':'POST','Access-Control-Allow-Headers':'Content-Type'});
   return res.end();
  }
  if(req.method!=='POST'||!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']||''))
   return respond(400,{success:false});
  const time=Date.now();
  if(time-windowStart>=60000){windowStart=time;requests=0;}
  if(++requests>30)return respond(429,{success:false});
  try{
   const chunks=[];
   let bytes=0;
   for await(const chunk of req){
    bytes+=chunk.length;
    if(bytes>4096)return respond(413,{success:false});
    chunks.push(chunk);
   }
   return respond(200,await recover(JSON.parse(Buffer.concat(chunks).toString('utf8'))));
  }catch(error){
   return respond(error.publicMessage?error.status:503,{success:false,message:error.publicMessage?error.message:'Recovery is temporarily unavailable.'});
  }
 };
}

const resetPage='<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Reset developer password</title><h1>Reset developer password</h1><form id="reset"><label>New password <input id="password" type="password" autocomplete="new-password" minlength="12" maxlength="128" required></label><br><label>Confirm password <input id="confirm" type="password" autocomplete="new-password" minlength="12" maxlength="128" required></label><br><button>Reset password</button></form><p id="status" role="status"></p><script src="/developer-recovery.js" defer></script></html>';
const resetScript=`
const token=new URLSearchParams(location.hash.slice(1)).get('reset');
history.replaceState(null,'',location.pathname);
const form=document.querySelector('#reset');
const status=document.querySelector('#status');
if(!/^[a-f0-9]{64}$/.test(token||'')){form.hidden=true;status.textContent='Reset link is invalid or expired.';}
form.addEventListener('submit',async event=>{
 event.preventDefault();
 const password=document.querySelector('#password').value;
 if(password!==document.querySelector('#confirm').value){status.textContent='Passwords must match.';return;}
 const button=form.querySelector('button');
 button.disabled=true;
 try{
  const response=await fetch('/developer-recovery',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({action:'developer/recovery/confirm',token,password})});
  const result=await response.json();
  if(!response.ok||!result.passwordChanged){status.textContent=result.message||'Reset unavailable.';return;}
  form.reset();
  form.hidden=true;
  status.textContent='Password changed. Return to the developer website to sign in.';
 }catch{status.textContent='Reset unavailable.';}finally{button.disabled=false;}
});
`;
module.exports={fromEnvironment,createRecoveryHandler};
