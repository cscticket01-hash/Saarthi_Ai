'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {createHash} = require('node:crypto');
const {setTimeout: delay} = require('node:timers/promises');
const {waitForRuntime} = require('./test_runtime_identity.cjs');
const {canonical} = require('../../functions/live-sync-canonical.js');

const schoolId = 'vs-db8afb01a3be46a983c8284714d06e5d';
const endpoint = 'https://saarthi-sync-v2-test.onrender.com/school-cloud';
const collections = ['documents', 'students_directory', 'teachers_directory'];
const report = {status: 'FAIL', scope: 'isolated TEST synthetic person bundles', cases: []};
const hash = value => createHash('sha256').update(value).digest('hex');
const pdf = Buffer.from('JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyNDIgMTUzXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA0IDAgUiA+PiA+PiAvQ29udGVudHMgNSAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhID4+CmVuZG9iago1IDAgb2JqCjw8IC9MZW5ndGggNTUgPj4Kc3RyZWFtCkJUIC9GMSAxMiBUZiAxNSAxMjAgVGQgKFNhYXJ0aGkgaXNvbGF0ZWQgVEVTVCBJRCkgVGogRVQKZW5kc3RyZWFtCmVuZG9iagp4cmVmCjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAyNDEgMDAwMDAgbiAKMDAwMDAwMDMxMSAwMDAwMCBuIAp0cmFpbGVyCjw8IC9Sb290IDEgMCBSIC9TaXplIDYgPj4Kc3RhcnR4cmVmCjQxNgolJUVPRgo=', 'base64');
const photo = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMwaDgAAAJUAXHIMWMAAAAAAElFTkSuQmCC', 'base64');

async function request(url, body, token) {
  const response = await fetch(url, {
    method: 'POST', headers: {'Content-Type': 'application/json', ...(token ? {Authorization: 'Bearer ' + token} : {})},
    body: JSON.stringify(body), signal: AbortSignal.timeout(120000),
  });
  const result = await response.json();
  if (!response.ok || result.success === false) {
    const code = /^[A-Z_]{1,80}$/.test(result.code || '') ? result.code : 'UNCLASSIFIED';
    throw Object.assign(new Error(`${body.action || 'TEST authentication'} HTTP ${response.status} ${code}`), {code});
  }
  return result;
}

async function run() {
  assert.equal(process.env.GITHUB_REPOSITORY, 'cscticket01-hash/Saarthi_Ai');
  assert.equal(process.env.GITHUB_ACTIONS, 'true');
  assert.equal(process.env.VS_TEST_CONNECT_CONFIRM, schoolId);
  const runId = process.env.GITHUB_RUN_ID, attempt = process.env.GITHUB_RUN_ATTEMPT;
  assert.match(runId || '', /^\d+$/);
  assert.match(attempt || '', /^\d+$/);
  assert.ok(process.env.VS_TEST_LOGIN_EMAIL && process.env.VS_TEST_LOGIN_PASSWORD);
  await waitForRuntime(process.env.VS_EXPECTED_TEST_RUNTIME);
  const apiKey = fs.readFileSync('lib/platform/platform_config.dart', 'utf8')
    .match(/const platformApiKey = '([A-Za-z0-9_-]+)'/)[1];
  const {idToken} = await request(
    'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + apiKey,
    {email: process.env.VS_TEST_LOGIN_EMAIL, password: process.env.VS_TEST_LOGIN_PASSWORD, returnSecureToken: true});
  assert.ok(idToken, 'Isolated TEST authentication required');
  const admin = async (action, body = {}) => {
    const r = await request(endpoint, {...body, schoolId, action}, idToken);
    assert.equal(r.schoolId, schoolId);
    return r;
  };
  const live = (operation, body) => admin('managed/live/' + operation, {liveProtocol: 1, ...body});
  report.stage = 'preflight';
  const profile = await admin('managed/profile', {operation: 'read'});
  assert.equal(profile.profile?.schoolName, 'TEST Sync V2');
  const status = await live('rollout-status');
  assert.ok(status.configured && status.workerVerified && status.scriptVerified && status.queuesVerified);
  assert.equal(status.pending, 0);
  assert.equal(status.needsAttention, 0);
  assert.equal(status.unsettledWrites, 0);
  assert.ok(collections.every(name => status.collections[name] === 'legacy'), 'A clean isolated cohort is required');
  const gs = await admin('managed/storage/check');
  assert.equal(gs.scriptBundleVersion, '2026-11-04.4');
  assert.equal(gs.uploadResumableVersion, 1);
  const confirmation = {confirmIsolatedBundleTest: true};
  let active = false;
  const archives = [];
  try {
    report.stage = 'prepare';
    for (let n = 0; n < 25; n++) {
      try {
        const result = await live('prepare-person-bundle', confirmation);
        assert.equal(result.state, 'active');
        assert.deepEqual(result.collections, collections);
        active = true;
        break;
      } catch (error) {
        if (error.code !== 'LIVE_LEGACY_DRAIN_GRACE') throw error;
        await delay(6000);
      }
    }
    assert.ok(active, 'Isolated cohort activation was not verified');
    for (const withPhoto of [true, false]) {
      const prefix = `atomic-test-${runId}-${attempt}-${withPhoto ? 'photo' : 'no-photo'}`;
      const bundleId = prefix + '-bundle';
      const personId = 'p-' + hash(prefix).slice(0, 32);
      const id = prefix + '-person';
      const docId = prefix + '-card';
      const cardRevision = prefix + '-card-write';
      const inputs = [{kind: 'idCard', bytes: pdf, mime: 'application/pdf', extension: 'pdf'}];
      if (withPhoto) inputs.push({kind: 'photo', bytes: photo, mime: 'image/png', extension: 'png'});
      report.stage = 'stage';
      const started = performance.now();
      const media = await Promise.all(inputs.map(async ({kind, bytes, mime, extension}) => {
        const uploadKey = prefix + '-' + kind;
        const expected = {kind, id: hash(JSON.stringify([schoolId, uploadKey])),
          uploadKey, sha256: hash(bytes), sizeBytes: bytes.length, mime};
        const {id, ...payload} = expected;
        const r = await live('bundle-stage', {...payload, name: uploadKey + '.' + extension, base64: bytes.toString('base64')});
        assert.equal(r.cloudflareAccepted, true);
        assert.deepEqual(r.media, expected);
        return expected;
      }));
      const operations = [{
        collection: 'students_directory', id, operation: 'write', createIntent: true,
        operationId: prefix + '-person-write', expectedRevision: '',
        data: {schoolId, syntheticTest: true, name: 'Synthetic Atomic TEST Student',
          class: '1', section: prefix, rollNo: '1', dob: '2015-01-01',
          mobileStableId: personId, mobileLinkToken: hash(prefix + '/link')},
      }, {
        collection: 'documents', id: docId, operation: 'write', createIntent: true,
        operationId: cardRevision, expectedRevision: '',
        data: {schoolId, syntheticTest: true, studentId: id, personId, ownerRole: 'student',
          documentKind: 'idCard', documentId: docId, documentRevision: cardRevision,
          documentName: 'Synthetic Atomic TEST ID', contentHash: hash(pdf), mimeType: 'application/pdf', sizeBytes: pdf.length},
      }];
      const wire = {bundleId, operations, media,
        mediaManifestHash: hash(canonical({schoolId, bundleId, media}))};
      report.stage = 'publish';
      const ack = await live('bundle-publish', {...wire, ...confirmation});
      assert.equal(ack.cloudState, 'committed');
      assert.equal(ack.mediaReady, true);
      assert.deepEqual(ack.acknowledgements.map(row => row.operationId), operations.map(row => row.operationId));
      const cloudAckMs = Math.round(performance.now() - started);
      const [person, document] = await Promise.all(operations.map(op => live('read', {collection: op.collection, id: op.id})));
      assert.equal(person.record.mobileStableId, personId);
      assert.equal(Boolean(person.record.atomicPortrait), withPhoto);
      assert.equal(document.record.bundleId, bundleId);
      assert.equal(document.record.contentHash, hash(pdf));
      const peerReadMs = Math.round(performance.now() - started);
      report.stage = 'drive-readback';
      let verified = false;
      for (let n = 0; n < 36; n++) {
        const result = await live('bundle-receipt', wire);
        if (result.backups.some(item => item.backupState === 'needsAttention')) throw Error('A TEST bundle backup requires review');
        if (result.driveVerified === true) { verified = true; break; }
        await delay(5000);
      }
      assert.ok(verified, 'Verified Google Drive and Sheets receipt still pending');
      const archive = await live('bundle-preflight', {bundleId, media, requireDrive: true});
      assert.equal(archive.archiveReady, true);
      for (const item of media) {
        const proof = archive.proofs.find(value => value.id === item.id);
        assert.ok(proof?.driveVerified && proof.fileId);
        archives.push({fileId: proof.fileId, sha256: item.sha256});
      }
      report.cases.push({withPhoto, cloudAckMs, peerReadMs, driveVerifiedMs: Math.round(performance.now() - started)});
    }
  } finally {
    if (active) {
      try {
        const result = await live('rollback-person-bundle', confirmation);
        assert.equal(result.state, 'legacy');
        report.restoredLegacy = true;
      } catch (error) {
        report.rollbackCode = error.code || 'ROLLBACK_UNVERIFIED';
        throw error;
      }
    }
  }
  report.stage = 'archive-bytes-after-rollback';
  for (const file of archives) {
    const reply = await admin('managed/file/read', {fileId: file.fileId});
    assert.equal(hash(Buffer.from(reply.base64, 'base64')), file.sha256);
  }
  report.verifiedDriveFiles = archives.length;
  report.status = 'PASS';
}

run().catch(error => {
  report.code = typeof error.code === 'string' ? error.code : 'ATOMIC_LIVE_CHECK_FAILED';
  process.exitCode = 1;
}).finally(() => console.log(JSON.stringify(report)));
