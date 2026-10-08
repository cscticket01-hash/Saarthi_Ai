'use strict';
// Enable only the existing Firebase Anonymous provider; never change billing,
// Identity Platform subtype, existing passwords or other login providers.
const {createRequire}=require('node:module');
const requireFunctions=createRequire(require.resolve('../../functions/package.json'));
const {applicationDefault}=requireFunctions('firebase-admin/app');
const project='saarthi-ai-df12b',apiKey='AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
async function anonymousWorks(request){
 const r=await request('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key='+apiKey,
  {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({returnSecureToken:true}),signal:AbortSignal.timeout(30000)});
 const d=await r.json();
 if(r.ok&&d.idToken){
  const cleanup=await request('https://identitytoolkit.googleapis.com/v1/accounts:delete?key='+apiKey,
   {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({idToken:d.idToken}),signal:AbortSignal.timeout(30000)});
  if(!cleanup.ok)throw new Error('Could not remove the temporary online-trial verification identity.');
  return true;
 }
 if(d.error?.message==='OPERATION_NOT_ALLOWED'||d.error?.message==='ADMIN_ONLY_OPERATION')return false;
 throw new Error('Developer Firebase Anonymous sign-in verification failed (HTTP '+r.status+'). Check Auth/API-key permissions and quota.');
}
async function configureAnonymous({request=fetch,credential=applicationDefault,log=console.log}={}){
 if(await anonymousWorks(request)){log('Online trial sign-in verified; temporary identity removed.');return;}
 const access=await credential().getAccessToken();
 const base='https://identitytoolkit.googleapis.com/admin/v2/projects/'+project+'/config';
 const r=await request(base+'?updateMask=signIn.anonymous.enabled',{method:'PATCH',
  headers:{Authorization:'Bearer '+access.access_token,'Content-Type':'application/json'},
  body:JSON.stringify({name:'projects/'+project+'/config',signIn:{anonymous:{enabled:true}}}),signal:AbortSignal.timeout(30000)});
 if(!r.ok)throw new Error('Enable Anonymous sign-in in the developer Firebase Authentication settings, or grant the deployment account Firebase Authentication Admin (HTTP '+r.status+').');
 if(!await anonymousWorks(request))throw new Error('Anonymous sign-in is still disabled.');
 log('Online trials enabled and verified; existing providers and billing unchanged.');
}
module.exports={configureAnonymous};
if(require.main===module)configureAnonymous().catch(e=>{console.error(e.message);process.exitCode=1;});
