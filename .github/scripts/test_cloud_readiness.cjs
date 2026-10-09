'use strict';
// Read-only live protocol prerequisites; not app UI or physical-device acceptance.
const fs = require('node:fs');
const schoolId = 'vs-db8afb01a3be46a983c8284714d06e5d';
const endpoint = 'https://saarthi-sync-v2-test.onrender.com/school-cloud';
const apiKey = 'AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const report = {scope: `${process.env.GITHUB_ACTIONS === 'true' ? 'GitHub hosted runner' : 'local automation environment'}, real cloud, read-only protocol prerequisites`, schoolId, checks: []};
async function request(url, body, token) {
  const start = performance.now();
  const response = await fetch(url, {method: body ? 'POST' : 'GET', headers: {
    'Content-Type': 'application/json', ...(token ? {Authorization: `Bearer ${token}`} : {}),
  }, ...(body ? {body: JSON.stringify(body)} : {}), signal: AbortSignal.timeout(60000)});
  const data = await response.json();
  return {status: response.status, data, elapsedMs: Math.round(performance.now() - start)};
}
function check(name, result, ok) {
  report.checks.push({name, status: ok ? 'PASS' : 'FAIL', http: result.status,
    elapsedMs: result.elapsedMs, reference: result.data.requestId || null});
  if (!ok) throw new Error(name);
}
async function run() {
  let r = await request(endpoint + '/healthz');
  check('Firebase readiness', r, r.status === 200 && r.data.ready === true && r.data.projectId === 'saarthi-ai-df12b');
  r = await request(endpoint, {action: 'managed/session', schoolId});
  check('Authentication required', r, r.status === 401);
  r = await request(endpoint, {action: 'managed/session', schoolId: 'vs-' + '0'.repeat(32)});
  check('Foreign school refused', r, r.status === 403 && r.data.code === 'ISOLATED_TEST_SCOPE_REQUIRED');
  const email = process.env.VS_TEST_LOGIN_EMAIL, password = process.env.VS_TEST_LOGIN_PASSWORD;
  if (!email || !password) {
    report.status = 'BLOCKED'; report.blocker = 'Owner must configure TEST-only login secrets in GitHub Actions.'; return;
  }
  r = await request('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + apiKey,
    {email, password, returnSecureToken: true});
  // Never include Firebase response bodies, credentials, tokens or user IDs in reports.
  check('Authorized Firebase password login', r, r.status === 200 && typeof r.data.idToken === 'string' && typeof r.data.localId === 'string');
  const token = r.data.idToken, uid = r.data.localId;
  r = await request(endpoint, {action: 'managed/session', schoolId}, token);
  check('Authenticated TEST school identity', r, r.status === 200 && r.data.success === true && r.data.schoolId === schoolId && r.data.uid === uid);
  r = await request(endpoint, {action: 'managed/profile', schoolId}, token);
  check('Authenticated TEST profile response', r, r.status === 200 && r.data.success === true && r.data.schoolId === schoolId);
  if (r.data.profile && r.data.profile.schoolName !== 'TEST Sync V2') throw new Error('TEST profile name mismatch');
  report.registrationState = r.data.registrationState || 'unknown';
  report.registrationProfileReady = Boolean(r.data.profile);
  r = await request(endpoint, {action: 'managed/storage/check', schoolId}, token);
  if (r.status !== 200 || r.data.success !== true || r.data.schoolId !== schoolId || r.data.storageReady !== true) {
    report.checks.push({name: 'Owner-connected TEST storage', status: 'BLOCKED', http: r.status, reference: r.data.requestId || null});
    report.status = 'BLOCKED'; report.blocker = 'Authorized isolated TEST Apps Script storage connection is not ready.'; return;
  }
  check('Owner-connected TEST storage', r, true);
  report.status = 'PASS';
  report.remaining = 'No mutations, attendance ACK, migration or application UI acceptance performed by this harness.';
}
run().catch(() => {report.status = 'FAIL'; report.blocker = 'Live prerequisite check failed; inspect safe check results.'; process.exitCode = 1;})
  .finally(() => {
    fs.mkdirSync('build/cloud-prerequisites', {recursive: true});
    fs.writeFileSync('build/cloud-prerequisites/report.json', JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report));
    if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `\nLive TEST prerequisites: **${report.status}**\n\n${report.checks.map(c => `- ${c.name}: ${c.status}`).join('\n')}\n\n${report.blocker || report.remaining || ''}\n`);
  });
