// Trusted project-owner machine only. Never ship credentials with the Windows app.
// npm install firebase-admin
// GOOGLE_APPLICATION_CREDENTIALS must point to this school's service-account JSON.
// node scripts/set_school_admin.cjs PROJECT_ID ADMIN_UID
const { initializeApp, applicationDefault } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
(async () => {
  const [projectId, uid] = process.argv.slice(2);
  if (!projectId || !uid) throw new Error('Usage: node scripts/set_school_admin.cjs PROJECT_ID ADMIN_UID');
  initializeApp({ credential: applicationDefault(), projectId });
  const auth = getAuth();
  const user = await auth.getUser(uid);
  await auth.setCustomUserClaims(uid, { ...(user.customClaims || {}), admin: true });
  console.log('Admin claim enabled. Sign in again in the Windows app.');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
