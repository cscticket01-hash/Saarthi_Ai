'use strict';
const {createSchoolCloud} = require('../functions/school-cloud-core');
const PROJECT = 'saarthi-ai-df12b';
function createHandler({handle,health,allowedOrigins=[]}) {
  let windowStart=Date.now(), requests=0;
  let healthCache;
  return async (req,res) => {
    res.setHeader('Cache-Control','no-store');
    res.setHeader('X-Content-Type-Options','nosniff');
    const send=(status,body)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(body));};
    const origin=req.headers.origin;
    if(origin && !allowedOrigins.includes(origin)) return send(403,{success:false,message:'Origin is not allowed'});
    if(origin){res.setHeader('Access-Control-Allow-Origin',origin);res.setHeader('Vary','Origin');}
    if(req.method==='OPTIONS' && req.url==='/school-cloud'){
      res.setHeader('Access-Control-Allow-Methods','POST');res.setHeader('Access-Control-Allow-Headers','Authorization,Content-Type');res.writeHead(204);return res.end();
    }
    if(Date.now()-windowStart>=60000){windowStart=Date.now();requests=0;}
    if(++requests>120) return send(429,{success:false,message:'Retry school setup shortly'});
    if(req.method==='GET' && req.url==='/school-cloud/healthz'){
      try{
        if(!healthCache || Date.now()-healthCache.at>30000){await health();healthCache={at:Date.now()};}
        return send(200,{service:'vidya-saarthi-central-staging',projectId:PROJECT,architecture:'central-v2',ready:true});
      }catch{return send(503,{service:'vidya-saarthi-central-staging',ready:false});}
    }
    if(req.method!=='POST' || req.url!=='/school-cloud') return send(405,{success:false,message:'POST required'});
    if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] || '')) return send(400,{success:false,message:'JSON request required'});
    try{
      let bytes=0;const chunks=[];
      for await(const chunk of req){bytes+=chunk.length;if(bytes>256*1024)return send(413,{success:false,message:'Request is too large'});chunks.push(chunk);}
      let body;
      try{body=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{return send(400,{success:false,message:'Invalid JSON'});}
      return send(200,await handle({method:'POST',headers:req.headers,body}));
    }catch(e){
      const status=[400,401,403,405,409].includes(e.status)?e.status:503;
      return send(status,{success:false,message:status===503?'School cloud is unavailable. Retry the same school.':e.message});
    }
  };
}
function fromEnvironment(env) {
  const admin=require('../functions/node_modules/firebase-admin');
  const key=JSON.parse(env.SAARTHI_FIREBASE_ADMIN_JSON || '{}');
  if(key.project_id!==PROJECT || !key.client_email?.endsWith('@'+PROJECT+'.iam.gserviceaccount.com') || !key.private_key) throw new Error('Invalid central staging credential configuration');
  const app=admin.initializeApp({credential:admin.credential.cert(key),projectId:PROJECT},'central-render-staging');
  const auth=app.auth(),db=app.firestore();
  db.settings({ignoreUndefinedProperties:true});
  const clientIds=(env.SAARTHI_GOOGLE_OAUTH_CLIENT_IDS || env.SAARTHI_GOOGLE_DESKTOP_CLIENT_ID || '').split(',').filter(Boolean);
  if(!clientIds.length) throw new Error('Missing central OAuth audience configuration');
  const handle=createSchoolCloud({auth,db,projectId:PROJECT,clientIds,verifyLegacy:async(projectId,token)=>{
    const name='legacy-proof-'+projectId;
    const legacy=admin.apps.find(a=>a.name===name) || admin.initializeApp({projectId},name);
    return legacy.auth().verifyIdToken(String(token || ''));
  }});
  return createHandler({handle,allowedOrigins:(env.SAARTHI_SCHOOL_WEB_ORIGINS || '').split(',').filter(Boolean),health:async()=>{
    await db.doc('_central_staging_health/runtime').get();
    try{await auth.getUser('__saarthi_staging_health__');}catch(e){if(e.code!=='auth/user-not-found')throw e;}
  }});
}
module.exports={createHandler,fromEnvironment};
