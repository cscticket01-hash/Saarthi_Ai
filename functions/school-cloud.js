'use strict';
const {onRequest} = require('firebase-functions/v2/https');
const {getApp,getApps,initializeApp} = require('firebase-admin/app');
const {getAuth} = require('firebase-admin/auth');
const {getFirestore} = require('firebase-admin/firestore');
const {createSchoolCloud} = require('./school-cloud-core');
// Uses the managed runtime identity (ADC). No service-account JSON in clients.
exports.schoolCloudApi = onRequest({region:'asia-south1', maxInstances:3, concurrency:20, cors:false}, async (req,res) => {
  res.set('Cache-Control','no-store');
  res.set('X-Content-Type-Options','nosniff');
  const origin = req.headers.origin;
  const allowed = (process.env.SAARTHI_SCHOOL_WEB_ORIGINS || '').split(',').filter(Boolean);
  if (origin && !allowed.includes(origin)) return res.status(403).json({success:false,message:'Origin is not allowed'});
  if (origin) { res.set('Access-Control-Allow-Origin',origin); res.set('Vary','Origin'); }
  if (req.method === 'OPTIONS') { res.set('Access-Control-Allow-Methods','POST');res.set('Access-Control-Allow-Headers','Authorization,Content-Type');return res.status(204).send(''); }
  try {
    const handle = createSchoolCloud({auth:getAuth(),db:getFirestore(),
      projectId:process.env.GCLOUD_PROJECT || getApp().options.projectId,
      clientIds:(process.env.SAARTHI_GOOGLE_OAUTH_CLIENT_IDS || '').split(',').filter(Boolean),
      verifyLegacy:async (projectId,token) => {
        const name = 'legacy-proof-' + projectId;
        const app = getApps().find(a=>a.name === name) || initializeApp({projectId},name);
        return getAuth(app).verifyIdToken(String(token || ''));
      }});
    return res.json(await handle(req));
  } catch(e) {
    // No token, Google error payload, profile or credential is logged/returned.
    const status = [400,401,403,405,409].includes(e.status) ? e.status : 503;
    return res.status(status).json({success:false,message:status === 503 ? 'School cloud is unavailable or developer configuration is incomplete. Retry the same school.' : e.message});
  }
});
