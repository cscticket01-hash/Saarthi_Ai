'use strict';
const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const crypto = require('node:crypto');
const { DAY, hash, safeEqual, schoolId, scriptUrl, licenseState, summary } = require('./domain');
const db = () => admin.firestore();
const collection = name => db().collection(`platform_${name}`);
const secret = () => crypto.randomBytes(32).toString('base64url');
const stamp = () => Date.now();
const str = (v, max = 1000) => String(v ?? '').trim().slice(0, max);
function fail(code, message) { const e = new Error(message); e.status = code; throw e; }
async function developer(req) {
  const bearer = String(req.headers.authorization || '').match(/^Bearer (.+)$/)?.[1];
  if (!bearer) fail(401, 'Developer login required');
  const user = await admin.auth().verifyIdToken(bearer, true);
  if (user.admin !== true && user.developer !== true) fail(403, 'Only the website developer can perform this action');
  return user;
}
async function installation(body) {
  const id = str(body.installationId, 128);
  const doc = await collection('installations').doc(hash(id)).get();
  if (!doc.exists || !safeEqual(doc.data().secretHash, hash(body.installationSecret || ''))) fail(401, 'Installation verification failed');
  return { id: doc.id, ref: doc.ref, ...doc.data() };
}
async function mobile(body) {
  const doc = await collection('mobile_sessions').doc(hash(body.mobileToken || '')).get();
  if (!doc.exists || doc.data().expiresAt <= stamp()) fail(401, 'Mobile session expired. Please scan your school ID again');
  return { id: doc.id, ref: doc.ref, ...doc.data() };
}
async function schoolState(id) {
  const s = await collection('schools').doc(id).get();
  if (!s.exists) fail(404, 'This school has not connected its Windows app yet');
  const data = s.data();
  const lic = data.licenseId ? await collection('licenses').doc(data.licenseId).get() : null;
  return { school: data, state: licenseState(data, lic?.exists ? lic.data() : null) };
}
async function verifySchoolAdmin(projectId, token) {
  const name = `school-${projectId}`;
  const app = admin.apps.find(a => a.name === name) || admin.initializeApp({ projectId }, name);
  const user = await app.auth().verifyIdToken(String(token || ''));
  if (user.admin !== true && user.role !== 'admin') fail(403, 'The linked school Firebase account needs its admin claim');
  return user;
}
async function verifyMobileAtSchool(school, token) {
  const url = scriptUrl(school.googleScriptUrl);
  const response = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'text/plain;charset=utf-8' }, body: JSON.stringify({ action: 'mobile_session_verify', sessionToken: token }), signal: AbortSignal.timeout(15000) });
  const result = await response.json();
  if (!result.success || result.projectId !== school.schoolId || !['student', 'teacher'].includes(result.role) || !result.personId) fail(403, 'School mobile session verification failed');
  return result;
}
async function handler(req) {
  if (req.method !== 'POST') fail(405, 'Use POST');
  const b = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
  const action = str(b.action, 80);
  const now = stamp();
  if (action === 'school/public_status') { const { state } = await schoolState(schoolId(b.projectId)); return { ...state, serverTime: now }; }
  if (action === 'installation/register') {
    const id = str(b.installationId, 128);
    const fingerprint = str(b.deviceFingerprint, 128);
    if (id.length < 20 || !/^[a-f0-9]{64}$/.test(fingerprint)) fail(400, 'Installation identity missing');
    const ref = collection('installations').doc(hash(id));
    const key = secret();
    const started = await db().runTransaction(async tx => {
      const doc = await tx.get(ref);
      if (doc.exists) fail(409, 'This installation is already registered');
      const deviceRef = collection('devices').doc(fingerprint);
      const device = await tx.get(deviceRef);
      const trialStartedAt = device.exists ? device.data().trialStartedAt : now;
      tx.set(deviceRef, { trialStartedAt }, { merge: true });
      tx.create(ref, { secretHash: hash(key), trialStartedAt, createdAt: now, lastSeenAt: now, schoolId: null });
      return trialStartedAt;
    });
    return { installationSecret: key, serverTime: now, trialStartedAt: started, expiresAt: started + 5 * DAY };
  }
  if (action === 'school/bind') {
    const i = await installation(b);
    const id = schoolId(b.projectId);
    const url = scriptUrl(b.googleScriptUrl);
    await verifySchoolAdmin(id, b.schoolIdToken);
    const backend = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'text/plain;charset=utf-8' }, body: JSON.stringify({ action: 'mobile_project_info' }), signal: AbortSignal.timeout(15000) });
    const identity = await backend.json();
    if (!identity.success || identity.projectId !== id) fail(403, 'Install the mobile integration in this school’s own Google Script and configure its matching Firebase project');
    const ref = collection('schools').doc(id);
    await db().runTransaction(async tx => {
      const existing = await tx.get(ref);
      const s = existing.exists ? existing.data() : {};
      const trialStartedAt = Math.min(Number(s.trialStartedAt || now), Number(i.trialStartedAt));
      if (existing.exists && s.googleScriptUrl && s.googleScriptUrl !== url) fail(409, 'This Firebase project is already paired with a different school backend. Developer review required');
      tx.set(ref, { schoolId: id, name: str(b.schoolName || id, 160), googleScriptUrl: url, trialStartedAt, lastSeenAt: now, windowsVersion: str(b.version, 32), createdAt: s.createdAt || now }, { merge: true });
      tx.update(i.ref, { schoolId: id });
    });
    return { serverTime: now, ...(await schoolState(id)).state, schoolId: id };
  }
  if (action === 'installation/status' || action === 'school/heartbeat') {
    const i = await installation(b);
    await i.ref.update({ lastSeenAt: now });
    if (!i.schoolId) return { serverTime: now, ...licenseState(i, null) };
    const { state } = await schoolState(i.schoolId);
    if (action === 'school/heartbeat') await collection('schools').doc(i.schoolId).set({ lastSeenAt: now, windowsVersion: str(b.version, 32), studentCount: Math.max(0, Math.min(1000000, Number(b.studentCount) || 0)), teacherCount: Math.max(0, Math.min(100000, Number(b.teacherCount) || 0)) }, { merge: true });
    return { ...state, serverTime: now, schoolId: i.schoolId };
  }
  if (action === 'license/activate') {
    const i = await installation(b);
    if (!i.schoolId) fail(400, 'Connect school Firebase and Google Script before activating a license');
    const ref = collection('licenses').doc(hash(str(b.key, 128).toUpperCase()));
    await db().runTransaction(async tx => {
      const lic = await tx.get(ref);
      if (!lic.exists || lic.data().schoolId !== i.schoolId || lic.data().status !== 'active' || lic.data().expiresAt <= now) fail(403, 'This key is invalid, expired, or belongs to another school');
      tx.update(collection('schools').doc(i.schoolId), { licenseId: ref.id, licenseExpiresAt: lic.data().expiresAt, purchased: lic.data().paid === true });
      tx.update(ref, { activatedAt: now });
    });
    return { serverTime: now, ...(await schoolState(i.schoolId)).state, schoolId: i.schoolId };
  }
  if (action === 'license/issue') {
    const user = await developer(req);
    const id = schoolId(b.schoolId);
    const days = Number(b.days);
    if (!Number.isInteger(days) || days < 1 || days > 1825) fail(400, 'License duration must be 1–1825 days');
    await schoolState(id);
    const key = `VS-${crypto.randomBytes(18).toString('hex').toUpperCase().match(/.{1,6}/g).join('-')}`;
    const doc = { schoolId: id, status: 'active', expiresAt: now + days * DAY, createdAt: now, createdBy: user.uid, paid: b.paid === true, amount: Math.max(0, Number(b.amount) || 0), currency: 'INR', keySuffix: key.slice(-6) };
    await collection('licenses').doc(hash(key)).create(doc);
    await collection('audit').add({ action, schoolId: id, userId: user.uid, at: now });
    return { key, ...doc };
  }
  if (action === 'license/revoke') {
    const user = await developer(req);
    const id = str(b.licenseId, 64);
    if (!/^[a-f0-9]{64}$/.test(id)) fail(400, 'Invalid license ID');
    await collection('licenses').doc(id).update({ status: 'revoked', revokedAt: now, revokedBy: user.uid });
    await collection('audit').add({ action, licenseId: id, userId: user.uid, at: now });
    return { revoked: true };
  }
  if (action === 'mobile/register') {
    const id = schoolId(b.projectId);
    const { school, state } = await schoolState(id);
    if (!state.allowed) fail(403, 'School trial/license expired. Please contact the school');
    const verified = await verifyMobileAtSchool(school, b.schoolSessionToken);
    if (str(b.deviceId, 160).length < 32) fail(400, 'Secure mobile device identity required');
    const token = secret();
    const data = { schoolId: id, personId: str(verified.personId, 160), role: verified.role, deviceId: hash(str(b.deviceId, 160)), schoolSessionToken: String(b.schoolSessionToken), lastSeenAt: now, expiresAt: Math.min(now + 30 * DAY, Number(verified.expiresAt) || now + DAY), fcmToken: str(b.fcmToken, 4096), mobileVersion: str(b.version, 32) };
    // Switching schools must stop the old school from addressing this phone.
    const stale = await collection('mobile_sessions').where('deviceId', '==', data.deviceId).get();
    for (const old of stale.docs) await old.ref.delete();
    await collection('mobile_sessions').doc(hash(token)).create(data);
    return { mobileToken: token, schoolName: school.name, expiresAt: data.expiresAt };
  }
  if (action === 'mobile/heartbeat') {
    const m = await mobile(b);
    const { state } = await schoolState(m.schoolId);
    await m.ref.update({ lastSeenAt: now, ...(b.fcmToken ? { fcmToken: str(b.fcmToken, 4096) } : {}) });
    return { serverTime: now, ...state };
  }
  if (action === 'mobile/logout') {
    const m = await mobile(b); await m.ref.delete(); return { loggedOut: true };
  }
  if (action === 'complaint/create') {
    const actor = b.mobileToken ? await mobile(b) : await installation(b);
    if (!actor.schoolId) fail(400, 'Link a school before sending a complaint');
    const message = str(b.message, 3000);
    if (message.length < 10) fail(400, 'Describe the problem in at least 10 characters');
    const id = secret().slice(0, 20);
    await collection('complaints').doc(id).create({ schoolId: actor.schoolId, source: b.mobileToken ? 'android' : 'windows', role: actor.role || 'admin', personId: actor.personId || '', message, createdAt: now, status: 'open', version: str(b.version, 32) });
    return { complaintId: id };
  }
  if (action === 'complaint/update') {
    const u = await developer(req);
    if (!['open', 'in_progress', 'resolved'].includes(b.status)) fail(400, 'Invalid complaint status');
    await collection('complaints').doc(str(b.complaintId, 64)).update({ status: b.status, developerNote: str(b.note, 2000), updatedAt: now, updatedBy: u.uid });
    return { updated: true };
  }
  if (action === 'school/notice') {
    const i = await installation(b);
    const { state } = await schoolState(i.schoolId);
    if (!state.allowed) fail(403, 'School license expired');
    const id = hash(`${i.schoolId}/${str(b.noticeId, 160)}`);
    const noticeRef = collection('notice_queue').doc(id);
    const claimed = await db().runTransaction(async tx => { const n = await tx.get(noticeRef); if (n.exists && (n.data().status === 'sent' || n.data().leaseUntil > now)) return false; tx.set(noticeRef, { schoolId: i.schoolId, status: 'sending', leaseUntil: now + 120000 }, { merge: true }); return true; });
    if (!claimed) return { duplicate: true };
    const sessions = await collection('mobile_sessions').where('schoolId', '==', i.schoolId).get();
    const tokens = [...new Set(sessions.docs.filter(d => d.data().expiresAt > now).map(d => d.data().fcmToken).filter(Boolean))];
    const title = str(b.title, 100); const text = str(b.message, 180);
    for (let offset = 0; offset < tokens.length; offset += 500) await admin.messaging().sendEachForMulticast({ tokens: tokens.slice(offset, offset + 500), notification: { title, body: text }, data: { schoolId: i.schoolId, type: 'school_notice', noticeId: str(b.noticeId, 160) }, android: { priority: 'high', notification: { sound: 'default' } } });
    await noticeRef.set({ status: 'sent', sentAt: now, recipients: tokens.length }, { merge: true });
    return { sent: tokens.length };
  }
  if (action === 'developer/dashboard') {
    await developer(req);
    const [s, m, l, c] = await Promise.all(['schools', 'mobile_sessions', 'licenses', 'complaints'].map(n => collection(n).get()));
    const schools = s.docs.map(d => ({ id: d.id, ...d.data(), googleScriptUrl: undefined }));
    const sessions = m.docs.map(d => d.data());
    const licenses = l.docs.map(d => ({ id: d.id, ...d.data() }));
    const complaints = c.docs.map(d => ({ id: d.id, ...d.data() })).sort((a, b) => b.createdAt - a.createdAt).slice(0, 250);
    return { serverTime: now, summary: summary(schools, sessions, now), schools, licenses, complaints };
  }
  if (action === 'updates/latest') {
    const platform = str(b.platform, 20);
    if (!['android', 'windows'].includes(platform)) fail(400, 'Unknown platform');
    const doc = await db().collection('app_config').doc(`${platform}_update`).get();
    return { update: doc.exists ? doc.data() : null };
  }
  fail(404, 'Unknown platform action');
}
exports.platformApi = onRequest({ region: 'asia-south1', cors: ['https://vidyasaarthi.web.app', 'https://vidyasaarthi.firebaseapp.com'], timeoutSeconds: 60, maxInstances: 5 }, async (req, res) => {
  res.set('Cache-Control', 'no-store');
  try { res.json({ success: true, ...await handler(req) }); }
  catch (e) { const status = e.status || (String(e.code || '').startsWith('auth/') ? 401 : 400); res.status(status).json({ success: false, message: status >= 500 ? 'Platform service unavailable' : e.message }); }
});
