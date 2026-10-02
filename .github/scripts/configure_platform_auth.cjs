'use strict';
// Existing Firebase Auth configuration only. This never enables Identity
// Platform billing, changes subtype, or changes any existing login provider.
const admin=require('../../functions/node_modules/firebase-admin');
(async()=>{
 const project='saarthi-ai-df12b';
 const access=await admin.credential.applicationDefault().getAccessToken();
 const base='https://identitytoolkit.googleapis.com/admin/v2/projects/'+project+'/config';
 const headers={Authorization:'Bearer '+access.access_token,'Content-Type':'application/json'};
 const current=await fetch(base,{headers,signal:AbortSignal.timeout(30000)});
 if(!current.ok)throw new Error('Firebase Authentication Admin permission is required to verify online trials (HTTP '+current.status+').');
 const config=await current.json();
 if(config.signIn?.anonymous?.enabled!==true){
  const r=await fetch(base+'?updateMask=signIn.anonymous.enabled',{method:'PATCH',headers,
   body:JSON.stringify({name:'projects/'+project+'/config',signIn:{anonymous:{enabled:true}}}),signal:AbortSignal.timeout(30000)});
  if(!r.ok)throw new Error('Enable Anonymous sign-in in the developer Firebase Authentication settings, or grant the deployment account Firebase Authentication Admin (HTTP '+r.status+').');
 }
 console.log('Developer Firebase Anonymous sign-in verified; existing providers and billing unchanged.');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
