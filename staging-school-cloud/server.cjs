'use strict';
const {createSchoolCloud} = require('../functions/school-cloud-core');
const {randomUUID}=require('node:crypto');
const ACTIONS=new Set(['onboard','status','migration/import','drive/link','profile/initialize','school/bind','license/activate','school/heartbeat','installation/status','school/notice','setup/diagnostic']);
const PROJECT = 'saarthi-ai-df12b';
function isolatedTestSchool(env) {
  if(env.SAARTHI_ISOLATED_TEST_MODE===undefined||env.SAARTHI_ISOLATED_TEST_MODE==='false')return null;
  if(env.SAARTHI_ISOLATED_TEST_MODE!=='true'||!/^vs-[a-f0-9]{32}$/.test(env.SAARTHI_ISOLATED_TEST_SCHOOL_ID||''))throw Error('Isolated TEST school configuration required');
  return env.SAARTHI_ISOLATED_TEST_SCHOOL_ID;
}
function createHandler({handle,health,allowedOrigins=[],testSchoolId=null,logger=entry=>console.info(JSON.stringify(entry))}) {
  if(testSchoolId!==null&&!/^vs-[a-f0-9]{32}$/.test(testSchoolId))throw Error('Invalid isolated TEST school');
  let windowStart=Date.now(), requests=0,anonymousRequests=0;
  let healthCache;
  return async (req,res) => {
    res.setHeader('Cache-Control','no-store');
    res.setHeader('X-Content-Type-Options','nosniff');
    const requestId=randomUUID();
    let action='UNKNOWN',operation;
    const send=(status,body)=>{
      if(req.url==='/school-cloud' && req.method==='POST') logger({event:'central_request',endpoint:'/school-cloud',action,status,requestId});
      res.setHeader('X-Saarthi-Request-Id',requestId);
      body={...body,requestId};
      res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(body));};
    const origin=req.headers.origin;
    if(origin && !allowedOrigins.includes(origin)) return send(403,{success:false,message:'Origin is not allowed'});
    if(origin){res.setHeader('Access-Control-Allow-Origin',origin);res.setHeader('Vary','Origin');}
    if(req.method==='OPTIONS' && req.url==='/school-cloud'){
      res.setHeader('Access-Control-Allow-Methods','POST');res.setHeader('Access-Control-Allow-Headers','Authorization,Content-Type');res.writeHead(204);return res.end();
    }
    if(Date.now()-windowStart>=60000){windowStart=Date.now();requests=0;anonymousRequests=0;}
    if(++requests>6000 || !req.headers.authorization&&++anonymousRequests>1200) return send(429,{success:false,message:'Retry school setup shortly'});
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
      for await(const chunk of req){bytes+=chunk.length;if(bytes>28*1024*1024 || bytes>256*1024&&!req.headers.authorization)return send(413,{success:false,message:'Request is too large'});chunks.push(chunk);}
      let body;
      try{body=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{return send(bytes>256*1024?413:400,{success:false,message:bytes>256*1024?'Request is too large':'Invalid JSON'});}
      if(bytes>256*1024&&body?.action!=='managed/file/upload')return send(413,{success:false,message:'Request is too large'});
      operation=/^(managed\/|developer\/managed\/)[a-zA-Z0-9_/-]{1,80}$/.test(body?.action||'')?body.action:undefined;
      action=ACTIONS.has(body?.action)?body.action:/^(managed\/|developer\/managed\/)/.test(body?.action||'')?'MANAGED':'UNKNOWN';
      // Additional TEST fence only; the existing authenticated handler still
      // verifies membership, licence, school identity and signed storage access.
      if(testSchoolId && (body?.schoolId!==testSchoolId ||
        !(body?.action?.startsWith('managed/')||body?.action==='developer/managed/view')))
        return send(403,{success:false,code:'ISOLATED_TEST_SCOPE_REQUIRED',message:'This service accepts only its configured isolated TEST school.'});
      return send(200,await handle({method:'POST',headers:req.headers,body}));
    }catch(e){
      const code=typeof e.code==='string'&&/^[a-zA-Z0-9_/-]{1,100}$/.test(e.code)?e.code:'UNKNOWN';
      const authErrors={
        'auth/email-already-exists':'This email already has a Firebase login. No new school was created. Use another email or ask the developer to inspect its existing account mapping.',
        'auth/invalid-email':'Enter a valid school login email.',
        'auth/invalid-password':'Use a valid initial password of 12–128 characters.',
        'auth/insufficient-permission':'School creation is blocked by backend Firebase Auth permissions. The developer must grant the existing backend account permission to manage Firebase users.'
      };
      const status=code==='auth/email-already-exists'?409:[400,401,403,405,409,429,502,503,504].includes(e.status)?e.status:503;
      // Log every failure without exception text, request payloads or credentials.
      // Upstream Script failures must not masquerade as a central-service outage.
      const context=e.syncDiagnostic;
      const diagnostic=status===409&&['RECORD_REVISION_CONFLICT','OPERATION_ID_CONFLICT','SCHOOL_STORAGE_NOT_CONNECTED'].includes(code)
        &&context&&/^vs-[a-f0-9]{32}$/.test(context.schoolId)&&[1,2].includes(context.syncProtocol)
        ?{schoolId:context.schoolId,syncProtocol:context.syncProtocol,
          ...(typeof context.operationId==='string'&&/^[A-Za-z0-9_-]{16,100}$/.test(context.operationId)?{operationId:context.operationId}:{})}:{};
      logger({event:'central_failure',action,...(operation?{operation}:{}),status,code,requestId,...diagnostic});
      return send(status,{success:false,code,...diagnostic,message:authErrors[code]||(e.publicMessage===true?e.message:'School cloud is unavailable. Retry the same school.')});
    }
  };
}
function fromEnvironment(env) {
  const testSchoolId=isolatedTestSchool(env);
  const runtimeRequire=require('node:module').createRequire(require.resolve('../oauth-broker/package.json'));
  const {initializeApp,getApps,cert}=runtimeRequire('firebase-admin/app');
  const {getAuth}=runtimeRequire('firebase-admin/auth');
  const {getFirestore}=runtimeRequire('firebase-admin/firestore');
  const {getMessaging}=runtimeRequire('firebase-admin/messaging');
  const key=JSON.parse(env.SAARTHI_FIREBASE_ADMIN_JSON || '{}');
  if(key.project_id!==PROJECT || !key.client_email?.endsWith('@'+PROJECT+'.iam.gserviceaccount.com') || !key.private_key) throw new Error('Invalid central staging credential configuration');
  const app=initializeApp({credential:cert(key),projectId:PROJECT},'central-render-staging');
  const auth=getAuth(app),db=getFirestore(app);
  db.settings({ignoreUndefinedProperties:true});
  const clientIds=(env.SAARTHI_GOOGLE_OAUTH_CLIENT_IDS || env.SAARTHI_GOOGLE_DESKTOP_CLIENT_ID || '').split(',').filter(Boolean);
  if(!clientIds.length) throw new Error('Missing central OAuth audience configuration');
  const legacyHandle=createSchoolCloud({auth,db,projectId:PROJECT,clientIds,allowNewSchools:env.SAARTHI_MANAGED_ONLY!=='true',diagnostics:entry=>console.info(JSON.stringify(entry)),verifyLegacy:async(projectId,token)=>{
    const name='legacy-proof-'+projectId;
    const legacy=getApps().find(a=>a.name===name) || initializeApp({projectId},name);
    return getAuth(legacy).verifyIdToken(String(token || '')); 
  }});
  const managed=require('../functions/managed-schools').createManagedSchools({auth,db,messaging:getMessaging(app),projectId:PROJECT,encryptionKey:env.SAARTHI_MANAGED_STORAGE_KEY,
    ...(testSchoolId?{attendanceCollection:'attendance_test_outbox',attendanceStore:require('../functions/attendance-queue').firestoreAttendanceStore(db,{schoolId:testSchoolId,collectionName:'attendance_test_outbox'})}:{}),
    monitor:require('../functions/managed-monitor').createMonitor({credential:app.options.credential,projectId:PROJECT})});
  if(env.SAARTHI_ATTENDANCE_QUEUE_ENABLED!=='false'){
    const worker=require('../functions/attendance-queue').createAttendanceWorker({drain:async()=>{await verifyTest();return managed.drainAttendance();},onError:()=>console.info(JSON.stringify({event:'attendance_retry_pending'}))});
    managed.setAttendanceWake(worker.wake);
  }
  const verifyTest=async()=>{if(testSchoolId){const school=await db.doc('schools/'+testSchoolId).get();if(!school.exists||!/^TEST\b/i.test(school.data().schoolName||''))throw Object.assign(Error('Verified TEST school required'),{status:403,code:'ISOLATED_TEST_SCOPE_REQUIRED'});}};
  const handle=async req => {await verifyTest();return /^(managed\/|developer\/managed\/)/.test(req.body?.action || '') ? managed(req) : legacyHandle(req);};
  return createHandler({handle,testSchoolId,allowedOrigins:(env.SAARTHI_SCHOOL_WEB_ORIGINS || '').split(',').filter(Boolean),health:async()=>{
    await verifyTest();
    await db.doc('_central_staging_health/runtime').get();
    try{await auth.getUser('__saarthi_staging_health__');}catch(e){if(e.code!=='auth/user-not-found')throw e;}
  }});
}
module.exports={createHandler,fromEnvironment,isolatedTestSchool};
