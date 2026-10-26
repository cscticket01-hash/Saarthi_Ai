'use strict';
// One authorized, seven-day complimentary licence for the isolated TEST school.
// This is an administrative operation, never part of the school/API runtime.
const { randomBytes, createHash } = require('node:crypto');
const PROJECT = 'saarthi-ai-df12b';
const SCHOOL = 'vs-db8afb01a3be46a983c8284714d06e5d';
const BRANCH = 'refs/heads/feature/sync3-unified-repair-20261026';
const OPERATION = 'sync3-test-seven-days-20261026';
const DAYS = 7 * 86400000;
function validCredential(raw) {
  let credential;
  try { credential = JSON.parse(raw); } catch { throw Error('Invalid administrative credential'); }
  if (credential.project_id !== PROJECT || credential.type !== 'service_account') throw Error('Unexpected Firebase project or credential type');
  return credential;
}
async function renew(db, { now = Date.now, makeKey = () => 'VS-' + randomBytes(16).toString('hex').toUpperCase() } = {}) {
  const key = makeKey();
  if (!/^VS-[A-F0-9]{32}$/.test(key)) throw Error('Invalid generated licence');
  const licenseHash = createHash('sha256').update(key).digest('hex');
  return db.runTransaction(async tx => {
    const schoolRef = db.doc('platform_schools/' + SCHOOL);
    const entitlementRef = db.doc('school_entitlements/' + SCHOOL);
    const school = await tx.get(schoolRef), entitlement = await tx.get(entitlementRef);
    if (!school.exists || !entitlement.exists) throw Error('Canonical TEST identity missing');
    const s = school.data(), e = entitlement.data();
    if (s.schoolId !== SCHOOL || s.name !== 'TEST Sync V2' || s.managed !== true || !s.authUid || s.blocked === true || s.loginDisabled === true || s.deletedAt || e.active !== true || e.blocked === true) throw Error('Canonical TEST identity or access mismatch');
    const membership = await tx.get(db.doc('school_memberships/' + s.authUid));
    const m = membership.exists && membership.data();
    if (!m || m.schoolId !== SCHOOL || m.active !== true || m.managed !== true || m.role !== 'school_admin') throw Error('Canonical TEST membership mismatch');
    const previous = e.sync3TestRenewal20261026;
    if (previous) {
      if (previous.operation !== OPERATION || previous.schoolId !== SCHOOL || previous.licenseHash !== e.licenseHash || previous.expiresAt !== e.expiresAt || previous.expiresAt - previous.startsAt !== DAYS || e.activated !== true || e.status !== 'licensed') throw Error('Previous TEST renewal changed; review required');
      const status = await tx.get(db.doc('platform_license_status/' + previous.licenseHash));
      const licence = await tx.get(db.doc('platform_licenses/' + previous.licenseHash));
      if (!status.exists || !licence.exists || [status.data(), licence.data()].some(v => v.schoolId !== SCHOOL || v.revoked !== false || v.expiresAt !== previous.expiresAt)) throw Error('Previous TEST licence changed; review required');
      return { renewed: false, expiresAt: previous.expiresAt };
    }
    const t = now();
    if (!Number.isSafeInteger(t) || t <= 0 || Number(e.expiresAt) > t) throw Error('TEST licence is not expired');
    if (e.licenseHash) {
      if (!/^[a-f0-9]{64}$/.test(e.licenseHash)) throw Error('Existing TEST licence identity invalid');
      const oldStatus = await tx.get(db.doc('platform_license_status/' + e.licenseHash));
      if (oldStatus.exists && (oldStatus.data().schoolId !== SCHOOL || Number(oldStatus.data().expiresAt) > t)) throw Error('Existing licence is foreign or unexpired');
    }
    const startsAt = t, expiresAt = t + DAYS;
    const marker = { operation: OPERATION, schoolId: SCHOOL, licenseHash, startsAt, expiresAt };
    tx.create(db.doc('platform_licenses/' + licenseHash), { schoolId: SCHOOL, issuedAt: t, startsAt, expiresAt, revoked: false, paid: false, keyHint: key.slice(-6), issuedBy: OPERATION });
    tx.create(db.doc('platform_license_status/' + licenseHash), { schoolId: SCHOOL, expiresAt, revoked: false });
    tx.set(entitlementRef, { status: 'licensed', startsAt, expiresAt, licenseHash, activated: true, sync3TestRenewal20261026: marker }, { merge: true });
    tx.set(schoolRef, { activeLicenseHash: licenseHash, licenseId: licenseHash, licenseExpiresAt: expiresAt, purchased: false }, { merge: true });
    return { renewed: true, expiresAt };
  });
}
async function main() {
  if (process.env.GITHUB_REPOSITORY !== 'cscticket01-hash/Saarthi_Ai' || process.env.GITHUB_REF !== BRANCH || process.env.GITHUB_EVENT_NAME !== 'push' || process.env.VS_AUTHORIZE_TEST_RENEWAL !== OPERATION) throw Error('Unauthorized TEST renewal execution context');
  const account = validCredential(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
  const fromFunctions = require('node:module').createRequire(require('node:path').resolve(__dirname, '../../functions/package.json'));
  const { initializeApp, cert, deleteApp } = fromFunctions('firebase-admin/app');
  const { getFirestore } = fromFunctions('firebase-admin/firestore');
  const app = initializeApp({ credential: cert(account), projectId: PROJECT });
  try {
    const result = await renew(getFirestore(app));
    console.log(JSON.stringify({ schoolId: SCHOOL, operation: OPERATION, renewed: result.renewed, expiresAt: new Date(result.expiresAt).toISOString() }));
  } finally { await deleteApp(app); }
}
if (require.main === module) main().catch(() => { console.error('TEST licence renewal failed safely; inspect identity, approval context and service-account permissions.'); process.exitCode = 1; });
module.exports = { renew, validCredential, PROJECT, SCHOOL, OPERATION, DAYS };
