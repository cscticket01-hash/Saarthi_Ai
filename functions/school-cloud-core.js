'use strict';
const {createHash, randomUUID} = require('node:crypto');
const schoolPattern = /^vs-[a-f0-9]{32}$/;
const uidFor = sub => 'g_' + createHash('sha256').update(sub).digest('hex');
function deny(status, message) { const e = new Error(message); e.status = status; throw e; }
function requireSchool(id) { if (!schoolPattern.test(id || '')) deny(400, 'Invalid school identity'); return id; }
// No caller chooses another tenant. The server-owned membership is authoritative.
async function authorizeSchool(auth, db, token, expected) {
  let user;
  try {user = await auth.verifyIdToken(token, true);} catch {deny(401,'School login expired or was revoked');}
  const member = await db.doc('school_memberships/' + user.uid).get();
  if (!member.exists || member.data().active !== true || member.data().role !== 'school_admin') deny(403, 'School membership is inactive');
  const schoolId = requireSchool(member.data().schoolId);
  if (expected && expected !== schoolId) deny(403, 'Another school is not accessible');
  return {uid: user.uid, schoolId};
}
async function verifyGoogle(token, clientIds, fetchImpl = fetch) {
  if (typeof token !== 'string' || token.length < 10 || token.length > 4096 || !clientIds.length) deny(401, 'Google login or developer OAuth configuration is missing');
  const get = async url => {
    const r = await fetchImpl(url, {redirect:'error', headers:{Authorization:'Bearer ' + token}, signal:AbortSignal.timeout(15000)});
    if (!r.ok) deny(401, 'Google permission expired or denied');
    return r.json();
  };
  const info = await get('https://oauth2.googleapis.com/tokeninfo?access_token=' + encodeURIComponent(token));
  if (!clientIds.includes(info.aud || info.issued_to) || Number(info.expires_in) <= 0 ||
      !String(info.scope || '').split(' ').includes('https://www.googleapis.com/auth/drive.file')) deny(401, 'Google token audience or required Drive permission is invalid');
  const user = await get('https://openidconnect.googleapis.com/v1/userinfo');
  if (user.email_verified !== true || typeof user.sub !== 'string' || !/^[0-9]{1,128}$/.test(user.sub) || typeof user.email !== 'string') deny(401, 'Verified Google identity is required');
  if (info.sub && info.sub !== user.sub) deny(401, 'Google identity mismatch');
  return {uid:uidFor(user.sub), email:user.email};
}
function createSchoolCloud({auth, db, projectId, clientIds, fetchImpl = fetch, verifyLegacy}) {
  return async function handle(req) {
    if (req.method !== 'POST') deny(405, 'Use POST');
    const b = req.body;
    if (!b || typeof b !== 'object' || Array.isArray(b) || JSON.stringify(b).length > 262144) deny(400, 'Invalid request');
    if (b.action !== 'migration/import' && JSON.stringify(b).length > 8192) deny(400,'Request is too large');
    if (b.action === 'onboard') {
      if (Object.keys(b).some(k => !['action','googleAccessToken','schoolName','expectedSchoolId'].includes(k))) deny(400, 'Unknown onboarding field');
      const google = await verifyGoogle(b.googleAccessToken, clientIds, fetchImpl);
      const name = String(b.schoolName || '').trim();
      if (name.length < 2 || name.length > 160) deny(400, 'School name is required');
      const ref = db.doc('school_memberships/' + google.uid);
      const schoolId = await db.runTransaction(async tx => {
        const existing = await tx.get(ref);
        if (existing.exists) {
          const m = existing.data();
          if (m.active !== true || m.role !== 'school_admin') deny(403, 'School membership is inactive');
          const id = requireSchool(m.schoolId);
          if (b.expectedSchoolId && b.expectedSchoolId !== id) deny(409, 'Use the original school Google account');
          return id;
        }
        if (b.expectedSchoolId) deny(409, 'Existing school membership is missing; automatic replacement is blocked');
        const id = 'vs-' + randomUUID().replaceAll('-', '');
        tx.create(ref, {schoolId:id, role:'school_admin', active:true, createdAt:Date.now()});
        tx.create(db.doc('platform_schools/' + id), {schoolId:id, schoolName:name, architecture:'central-v2', projectId, registeredAt:Date.now()});
        tx.create(db.doc('schools/' + id), {schoolId:id, schoolName:name, ownerUid:google.uid, schemaVersion:2, createdAt:Date.now()});
        return id;
      });
      // No admin/developer claim: school administrators cannot use platform admin APIs.
      const customToken = await auth.createCustomToken(google.uid, {schoolId, schoolRole:'school_admin'});
      return {success:true, schoolId, projectId, email:google.email, customToken};
    }
    const token = String(req.headers.authorization || '').match(/^Bearer (.+)$/)?.[1];
    if (!token) deny(401, 'School login required');
    const member = await authorizeSchool(auth, db, token, b.schoolId);
    if (b.action === 'status') return {success:true, schoolId:member.schoolId, projectId};
    const milliseconds = value => typeof value?.toMillis === 'function' ? value.toMillis() : Number(value || 0);
    async function licenseStatus() {
      const settings = await db.doc('schools/' + member.schoolId + '/school_config/license').get();
      const hash = settings.exists ? settings.data().licenseHash : '';
      if (hash && !/^[a-f0-9]{64}$/.test(hash)) deny(403,'Saved license reference is invalid');
      const doc = hash ? await db.doc('platform_license_status/' + hash).get() : null;
      const trial = await db.doc('platform_school_trials/' + member.schoolId).get();
      const data = doc?.exists ? doc.data() : null;
      const validOwner = data?.schoolId === member.schoolId;
      const end = hash ? (validOwner ? milliseconds(data.expiresAt) : 0)
        : trial.exists ? milliseconds(trial.data().createdAt) + 5*86400000 : 0;
      const status = hash ? (!validOwner || data.revoked !== false ? 'blocked' : end > Date.now() ? 'licensed':'expired')
        : end > Date.now() ? 'trial':'expired';
      return {success:true,schoolId:member.schoolId,projectId,serverTime:Date.now(),expiresAt:end,
        allowed:['licensed','trial'].includes(status),status,...(hash ? {licenseHash:hash} : {})};
    }
    if (b.action === 'school/bind') {
      if (!/^[a-f0-9]{64}$/.test(b.deviceFingerprint || '')) deny(400,'Verified installation required');
      const device = await db.doc('platform_device_trials/' + b.deviceFingerprint).get();
      if (!device.exists) deny(403,'Verify the existing installation trial first');
      const ref = db.doc('platform_school_trials/' + member.schoolId);
      await db.runTransaction(async tx => {
        const existing = await tx.get(ref);
        if (!existing.exists) tx.create(ref,{createdAt:device.data().createdAt,deviceTrialId:b.deviceFingerprint});
      });
      return licenseStatus();
    }
    if (b.action === 'license/activate') {
      const hash = createHash('sha256').update(String(b.key || '').trim().toUpperCase()).digest('hex');
      const doc = await db.doc('platform_license_status/' + hash).get();
      if (!doc.exists || doc.data().schoolId !== member.schoolId || doc.data().revoked !== false || milliseconds(doc.data().expiresAt) <= Date.now()) deny(403,'License is invalid, expired, revoked or belongs to another school');
      await db.doc('schools/' + member.schoolId + '/school_config/license').set({schoolId:member.schoolId,licenseHash:hash});
      return licenseStatus();
    }
    if (b.action === 'school/heartbeat') {
      const counts = {};
      for (const key of ['studentCount','teacherCount','studentAppUsers','onlineStudents','onlineTeachers']) {
        if (b[key] !== undefined && (!Number.isInteger(b[key]) || b[key] < 0 || b[key] > 1000000)) deny(400,'Invalid aggregate count');
        counts[key] = b[key] || 0;
      }
      await db.doc('platform_schools/' + member.schoolId).set({...counts,lastSeenAt:Date.now(),windowsVersion:String(b.version || '').slice(0,32)}, {merge:true});
      return licenseStatus();
    }
    if (b.action === 'installation/status') return licenseStatus();
    if (b.action === 'complaint/create') {
      const message = String(b.message || '').trim();
      if (message.length < 3 || message.length > 3000) deny(400,'Invalid complaint');
      await db.doc('platform_complaints/' + member.schoolId + '_' + randomUUID().replaceAll('-','')).create({
        schoolId:member.schoolId,source:'windows',role:'admin',message,status:'open',createdAt:Date.now()});
      return {success:true,schoolId:member.schoolId};
    }
    if (b.action === 'school/notice') {
      // Future mobile/web clients subscribe to their own tenant notice collection.
      // Do not claim FCM delivery before the central mobile client is available.
      return {success:true,schoolId:member.schoolId,delivered:0,centralSubscription:true};
    }

    if (b.action === 'profile/initialize') {
      const allowed = new Set(['schoolName','principalName','logoUrl','logoFileId','sealUrl','sealFileId','principalSignatureUrl','principalSignatureFileId']);
      if (!b.profile || Object.keys(b.profile).some(k=>!allowed.has(k)) ||
          Object.values(b.profile).some(v=>typeof v !== 'string' || v.length > 500 || v.startsWith('data:'))) deny(400,'Invalid initial school profile');
      const ref = db.doc('schools/' + member.schoolId + '/school_config/school_profile_cache');
      await db.runTransaction(async tx => {
        const existing = await tx.get(ref);
        if (!existing.exists) tx.create(ref,{...b.profile,schoolId:member.schoolId});
      });
      return {success:true,schoolId:member.schoolId};
    }
    if (b.action === 'migration/import') {
      if (!verifyLegacy || !/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(b.sourceProjectId || '') || b.sourceProjectId === projectId) deny(400,'Verified legacy project is required');
      const source = await verifyLegacy(b.sourceProjectId, b.sourceAdminToken);
      if (source.admin !== true && source.role !== 'admin') deny(403,'Legacy school administrator proof is required');
      const allowed = new Set(['students_directory','teachers_directory','attendance_logs','teacher_attendance',
        'attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary',
        'school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices']);
      if (!Array.isArray(b.records) || b.records.length > 20) deny(400,'Use migration batches of at most 20 documents');
      const records = b.records.map(r => {
        if (!allowed.has(r.collection) || !/^[^/]{1,200}$/.test(r.id || '') || r.id === '.' || r.id === '..' ||
            !r.data || typeof r.data !== 'object' || Array.isArray(r.data)) deny(400,'Invalid migration record');
        function restore(v) {
          if (Array.isArray(v)) return v.map(restore);
          if (v && typeof v === 'object') {
            if (Object.keys(v).length === 1 && typeof v.__vsTimestamp === 'string') {
              const date = new Date(v.__vsTimestamp); if (!Number.isFinite(date.getTime())) deny(400,'Invalid migration timestamp');return date;
            }
            return Object.fromEntries(Object.entries(v).filter(([k,value])=>!(/password|base64|private_key|client_secret|localPath/i.test(k)) && (!/token/i.test(k) || k === 'mobileLinkToken') && !(typeof value === 'string' && value.startsWith('data:'))).map(([k,value])=>[k,restore(value)]));
          }
          return v;
        }
        const data = {...restore(r.data),schoolId:member.schoolId};
        for (const key of Object.keys(data)) if (/password|base64|private_key|client_secret|localPath/i.test(key) || (/token/i.test(key) && key !== 'mobileLinkToken')) delete data[key];
        return {ref:db.doc('schools/' + member.schoolId + '/' + r.collection + '/' + r.id), data};
      });
      if (new Set(records.map(r => r.ref.path)).size !== records.length) deny(400,'Duplicate migration document');
      let copied = 0;
      await db.runTransaction(async tx => {
        copied = 0;
        const sourceRef = db.doc('school_legacy_migrations/' + b.sourceProjectId);
        const binding = await tx.get(sourceRef);
        if (binding.exists && binding.data().schoolId !== member.schoolId) deny(403,'Legacy school is already assigned to another tenant');
        const existing = [];
        for (const record of records) existing.push(await tx.get(record.ref));
        if (!binding.exists) tx.create(sourceRef,{schoolId:member.schoolId,sourceProjectId:b.sourceProjectId,createdAt:Date.now()});
        records.forEach((record,i) => {if (!existing[i].exists) {tx.create(record.ref,record.data);copied++;}});
      });
      return {success:true,schoolId:member.schoolId,copied,skipped:records.length-copied};
    }
    if (b.action === 'drive/link') {
      const google = await verifyGoogle(b.googleAccessToken, clientIds, fetchImpl);
      if (google.uid !== member.uid) deny(403, 'Drive must belong to the same school Google account');
      if (!/^[a-zA-Z0-9_-]{1,200}$/.test(b.folderId || '')) deny(400, 'Invalid Drive folder');
      const r = await fetchImpl('https://www.googleapis.com/drive/v3/files/' + b.folderId + '?fields=id,mimeType,trashed,owners(me),appProperties,capabilities(canAddChildren)',
        {redirect:'error', headers:{Authorization:'Bearer ' + b.googleAccessToken}, signal:AbortSignal.timeout(15000)});
      if (!r.ok) deny(403, 'School Drive folder is not accessible');
      const folder = await r.json();
      if (folder.id !== b.folderId || folder.mimeType !== 'application/vnd.google-apps.folder' || folder.trashed ||
          !folder.owners?.some(o => o.me === true) || folder.capabilities?.canAddChildren !== true || folder.appProperties?.schoolId !== member.schoolId) deny(403, 'Drive ownership or school marker is invalid');
      await db.doc('schools/' + member.schoolId + '/school_config/drive').set({schoolId:member.schoolId, folderId:folder.id, email:google.email, updatedAt:Date.now()});
      return {success:true, schoolId:member.schoolId, folderId:folder.id};
    }
    deny(400, 'Unknown school cloud action');
  };
}
module.exports = {createSchoolCloud, verifyGoogle, authorizeSchool, requireSchool, uidFor};
