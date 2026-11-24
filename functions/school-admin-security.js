'use strict';

const {randomBytes, createHash, timingSafeEqual, scrypt} = require('node:crypto');
const {promisify} = require('node:util');
const {canonical} = require('./live-sync-canonical');

const derive = promisify(scrypt);
const hash = value => createHash('sha256').update(value).digest('hex');
const ADMIN_WORK_FACTOR = {N:16384, r:8, p:1, maxmem:64*1024*1024};
const PASSWORD_MIN = 4;
const NEW_PASSWORD_MAX = 10;
const PASSWORD_MAX = 128;
const LOCK_AFTER_FAILURES = 5;
const LOCK_DURATION_MS = 15 * 60 * 1000;
const APPROVAL_WINDOW_MS = 2 * 60 * 1000;

function denied(status, code, message) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  error.publicMessage = true;
  throw error;
}

function goodPassword(password) {
  if (typeof password !== 'string' || password.length < PASSWORD_MIN ||
      password.length > NEW_PASSWORD_MAX || password.trim() !== password)
    denied(400, 'ADMIN_PASSWORD_POLICY', 'Admin password must contain 4–10 characters and no surrounding spaces');
}

async function passwordHash(password, salt) {
  const bytes = await derive(password, Buffer.from(salt, 'hex'), 32, ADMIN_WORK_FACTOR);
  return bytes.toString('hex');
}

// A durable approval binds the original immutable business operation. It is
// not an interchangeable password token and carries no credential material.
// The mutation owner must recompute the same binding from its actual request
// and verified revisions; this function alone is not a provider gate.
function mutationBinding(identity, intent) {
  const id = value => typeof value==='string' && /^[^/]{1,200}$/.test(value) &&
    !['.','..','__proto__','constructor','prototype'].includes(value);
  const revision = value => typeof value==='string' && value.length>0 && value.length<=100;
  if(!intent || typeof intent!=='object' || Array.isArray(intent) ||
     !/^vs-[a-f0-9]{32}$/.test(identity.schoolId||'') ||
     typeof identity.uid!=='string'||!identity.uid ||
     !/^[A-Za-z0-9_-]{16,100}$/.test(intent.operationId||'') ||
     !id(intent.id)||!revision(intent.recordRevision) ||
     !/^p-[a-f0-9]{32,64}$/.test(intent.generation||'') ||
     !/^[a-f0-9]{64}$/.test(intent.payloadHash||''))
    denied(400,'ADMIN_MUTATION_INVALID','Exact original record operation required');
  const base=['scope','collection','id','operationId','recordRevision','generation','payloadHash'];
  let target;
  if(intent.scope==='person-delete'){
    if(!['students_directory','teachers_directory'].includes(intent.collection) ||
       Object.keys(intent).some(k=>!base.includes(k)))
      denied(400,'ADMIN_MUTATION_INVALID','Invalid person deletion binding');
    target=intent.collection+'/'+intent.id;
  }else if(intent.scope==='force-promotion'){
    if(intent.collection!=='students_directory'||!id(intent.examId)||
       !revision(intent.examRevision)||!revision(intent.resultRevision)||
       Object.keys(intent).some(k=>![...base,'examId','examRevision','resultRevision'].includes(k)))
      denied(400,'ADMIN_MUTATION_INVALID','Exact final exam and result revisions required');
    target=intent.id+'/'+intent.examId;
  }else denied(400,'ADMIN_MUTATION_INVALID','Unknown protected mutation');
  const fingerprint=hash(canonical({version:1,schoolId:identity.schoolId,uid:identity.uid,intent}));
  return {target,fingerprint};
}

function createSchoolAdminSecurity({db, auth, now=Date.now}) {
  const credentialRef = school => db.doc('school_admin_security/' + school);
  const approvalRef = (school, uid, token) =>
    db.doc('school_admin_action_approvals/' + hash(school + '/' + uid + '/' + token));

  const mutationRef = (school, operationId) =>
    db.doc('school_admin_mutation_approvals/'+hash(school+'/'+operationId));

  async function freshSchoolLogin(proof, identity) {
    if (typeof proof !== 'string' || proof.length < 100 || proof.length > 10000)
      denied(401, 'FRESH_SCHOOL_LOGIN_REQUIRED', 'Re-enter the school login password');
    let verified;
    try { verified = await auth.verifyIdToken(proof, true); }
    catch (_) { denied(401, 'FRESH_SCHOOL_LOGIN_REQUIRED', 'Fresh school login verification failed'); }
    const age = Math.floor(now()/1000) - Number(verified.auth_time);
    if (verified.uid !== identity.uid || !Number.isFinite(age) || age < -30 || age > 300)
      denied(403, 'FRESH_SCHOOL_LOGIN_REQUIRED', 'Use a fresh login to the same school account');
  }

  async function checkPassword(identity, password) {
    const ref = credentialRef(identity.schoolId);
    const snapshot = await ref.get();
    if (!snapshot.exists) denied(409, 'ADMIN_PASSWORD_NOT_CONFIGURED', 'Set the independent Admin Password first');
    const current = snapshot.data();
    if (Number(current.lockUntil || 0) > now())
      denied(429, 'ADMIN_PASSWORD_LOCKED', 'Admin password temporarily locked. Retry later');
    if (typeof password !== 'string' || password.length > PASSWORD_MAX)
      denied(401, 'ADMIN_PASSWORD_INVALID', 'Admin password is incorrect');
    if (!/^[a-f0-9]{32}$/.test(current.salt || '') ||
        !/^[a-f0-9]{64}$/.test(current.passwordHash || '') ||
        current.hashVersion !== 1)
      denied(503, 'ADMIN_PASSWORD_RECOVERY_REQUIRED', 'School Admin Password needs verified recovery');
    const derived = await passwordHash(password, current.salt);
    const matches = timingSafeEqual(Buffer.from(derived, 'hex'),
      Buffer.from(current.passwordHash, 'hex'));
    const result = await db.runTransaction(async tx => {
      const latest = await tx.get(ref);
      if (!latest.exists || latest.data().passwordHash !== current.passwordHash ||
          latest.data().salt !== current.salt)
        denied(409, 'ADMIN_PASSWORD_CHANGED', 'Admin Password changed. Re-enter it');
      const row = latest.data();
      if (Number(row.lockUntil || 0) > now())
        denied(429, 'ADMIN_PASSWORD_LOCKED', 'Admin password temporarily locked. Retry later');
      const failures = Number(row.failedAttempts || 0);
      const next = (row.lockUntil && row.lockUntil <= now()) ? 1 : failures + 1;
      if (matches) tx.update(ref, {failedAttempts:0, lockUntil:0});
      else tx.update(ref, {
        failedAttempts: next >= LOCK_AFTER_FAILURES ? 0 : next,
        lockUntil: next >= LOCK_AFTER_FAILURES ? now() + LOCK_DURATION_MS : 0
      });
      return matches;
    });
    if (!result) denied(401, 'ADMIN_PASSWORD_INVALID', 'Admin password is incorrect');
    return current.passwordHash;
  }

  async function handle(body, identity) {
    const operation = body.operation;
    const ref = credentialRef(identity.schoolId);
    if (operation === 'status') {
      const existing = await ref.get();
      return {success:true, schoolId:identity.schoolId, configured:existing.exists,
        passwordPolicyVersion:1, updatedAt:existing.exists?Number(existing.data().updatedAt || 0):null};
    }
    if (operation === 'enroll' || operation === 'recover') {
      goodPassword(body.newPassword);
      if (operation === 'recover') await freshSchoolLogin(body.freshIdToken, identity);
      const salt = randomBytes(16).toString('hex');
      const nextHash = await passwordHash(body.newPassword, salt);
      const auditRef = db.doc('platform_audit/'+randomBytes(16).toString('hex'));
      await db.runTransaction(async tx => {
        const previous = await tx.get(ref);
        if (operation === 'enroll' && previous.exists)
          denied(409, 'ADMIN_PASSWORD_ALREADY_CONFIGURED', 'Admin Password is already configured');
        if (operation === 'recover' && !previous.exists)
          denied(409, 'ADMIN_PASSWORD_NOT_CONFIGURED', 'Set the Admin Password first');
        tx.set(ref, {
          schoolId:identity.schoolId, salt, passwordHash:nextHash,
          hashVersion:1, failedAttempts:0, lockUntil:0,
          updatedAt:now(), updatedBy:identity.uid
        });
        tx.set(auditRef, {
          action:operation === 'enroll'?'school_admin_password_enrolled':'school_admin_password_recovered',
          schoolId:identity.schoolId, actor:identity.uid, at:now()
        });
      });
      return {success:true, schoolId:identity.schoolId, configured:true};
    }
    if (operation === 'change') {
      goodPassword(body.newPassword);
      const verifiedHash = await checkPassword(identity, body.password);
      if (body.password === body.newPassword)
        denied(400, 'ADMIN_PASSWORD_REUSE', 'Choose a different Admin Password');
      const salt = randomBytes(16).toString('hex');
      const nextHash = await passwordHash(body.newPassword, salt);
      const auditRef = db.doc('platform_audit/'+randomBytes(16).toString('hex'));
      await db.runTransaction(async tx => {
        const current = await tx.get(ref);
        if (!current.exists) denied(409, 'ADMIN_PASSWORD_NOT_CONFIGURED', 'Set the Admin Password first');
        if(current.data().passwordHash !== verifiedHash)
          denied(409, 'ADMIN_PASSWORD_CHANGED', 'Admin Password changed during the request');
        tx.update(ref, {
          salt, passwordHash:nextHash, hashVersion:1, failedAttempts:0,
          lockUntil:0, updatedAt:now(), updatedBy:identity.uid
        });
        tx.set(auditRef, {
          action:'school_admin_password_changed', schoolId:identity.schoolId,
          actor:identity.uid, at:now()
        });
      });
      return {success:true, schoolId:identity.schoolId, configured:true};
    }
    if (operation === 'unlock') {
      await checkPassword(identity, body.password);
      return {success:true, schoolId:identity.schoolId,
        verified:true, scope:'admin-panel', verifiedAt:now()};
    }
    if (operation === 'authorize') {
      const scope = body.scope;
      const target = body.target;
      if (!['drive-connection','person-delete','force-promotion','protected-settings'].includes(scope) ||
          typeof target !== 'string' || target.length < 1 || target.length > 1000)
        denied(400, 'ADMIN_APPROVAL_INVALID', 'Invalid protected action');
      const verifiedHash = await checkPassword(identity, body.password);
      const token = randomBytes(32).toString('hex');
      const grantRef = approvalRef(identity.schoolId, identity.uid, token);
      const auditRef = db.doc('platform_audit/'+randomBytes(16).toString('hex'));
      const expiresAt = now()+APPROVAL_WINDOW_MS;
      await db.runTransaction(async tx => {
        const latest = await tx.get(ref);
        if (!latest.exists || latest.data().passwordHash !== verifiedHash)
          denied(409, 'ADMIN_PASSWORD_CHANGED', 'Admin Password changed. Re-enter it');
        tx.create(grantRef, {
          schoolId:identity.schoolId, uid:identity.uid, scope, targetHash:hash(target),
          credentialFingerprint:verifiedHash,
          issuedAt:expiresAt-APPROVAL_WINDOW_MS, expiresAt,
          ttlAt:new Date(expiresAt), usedAt:0
        });
        tx.set(auditRef, {
          action:'school_admin_action_authorized', scope, targetHash:hash(target),
          schoolId:identity.schoolId, actor:identity.uid, at:now()
        });
      });
      return {success:true, schoolId:identity.schoolId, authorized:true,
        approvalToken:token, expiresAt};
    }
    if(operation==='bind-mutation') {
      return bindMutation(identity,body.approvalToken,body.intent);
    }
    if(operation==='consume') {
      const scope=body.scope, target=body.target;
      if(!['person-delete','force-promotion','protected-settings'].includes(scope) ||
          typeof target!=='string'||target.length<1||target.length>1000) {
        denied(400,'ADMIN_APPROVAL_INVALID','Invalid protected action');
      }
      const result=await consumeApproval(identity,body.approvalToken,scope,target);
      if(result.authorized!==true)
        denied(403,'ADMIN_APPROVAL_REQUIRED','Verify Admin Password for this action');
      return {success:true,schoolId:identity.schoolId,authorized:true};
    }
    denied(400, 'ADMIN_SECURITY_OPERATION_INVALID', 'Unknown school Admin Security operation');
  }

  async function consumeApproval(identity, token, scope, target) {
    const credential = await credentialRef(identity.schoolId).get();
    // Existing schools keep their original operational workflows until an
    // administrator explicitly enrolls a separate credential. Enrollment
    // is the upgrade boundary; never invent an App Lock password on the server.
    if (!credential.exists) return {legacy:true};
    if (typeof token !== 'string' || !/^[a-f0-9]{64}$/.test(token))
      denied(403, 'ADMIN_APPROVAL_REQUIRED', 'Verify the independent Admin Password for this action');
    const ref = approvalRef(identity.schoolId, identity.uid, token);
    const auditRef = db.doc('platform_audit/'+randomBytes(16).toString('hex'));
    await db.runTransaction(async tx => {
      // Re-read the active credential together with this grant. A password
      // rotation on another PC must invalidate pending approvals atomically.
      const currentCredential = await tx.get(credentialRef(identity.schoolId));
      const existing = await tx.get(ref);
      const record = existing.exists ? existing.data() : null;
      if (!currentCredential.exists || !record ||
          record.schoolId !== identity.schoolId ||
          record.uid !== identity.uid || record.scope !== scope ||
          record.targetHash !== hash(target) ||
          record.credentialFingerprint !== currentCredential.data().passwordHash ||
          record.usedAt !== 0 || record.expiresAt <= now())
        denied(403, 'ADMIN_APPROVAL_EXPIRED', 'Admin approval expired or does not match this action');
      const consumedAt=now();
      tx.update(ref, {usedAt:consumedAt});
      tx.set(auditRef, {
        action:'school_admin_action_consumed',
        schoolId:identity.schoolId,actor:identity.uid,
        scope,targetHash:hash(target),at:consumedAt
      });
    });
    return {authorized:true};
  }
  async function bindMutation(identity, token, intent) {
    const {target,fingerprint}=mutationBinding(identity,intent);
    const durable=mutationRef(identity.schoolId,intent.operationId);
    const auditRef=db.doc('platform_audit/'+randomBytes(16).toString('hex'));
    // Consume the short-lived approval and write the immutable retry binding
    // together. A lost response can replay the identical original operation.
    const credential=credentialRef(identity.schoolId);
    await db.runTransaction(async tx=>{
      const current=await tx.get(credential),existing=await tx.get(durable);
      if(existing.exists){
        const row=existing.data();
        if(row.fingerprint!==fingerprint||row.uid!==identity.uid||
           row.schoolId!==identity.schoolId)
          denied(409,'ADMIN_MUTATION_CONFLICT','Original admin-approved operation differs');
        return;
      }
      if(!current.exists||typeof token!=='string'||!/^[a-f0-9]{64}$/.test(token))
        denied(403,'ADMIN_APPROVAL_REQUIRED','Verify the independent Admin Password');
      const grantRef=approvalRef(identity.schoolId,identity.uid,token);
      const snapshot=await tx.get(grantRef),grant=snapshot.exists?snapshot.data():null;
      if(!grant||grant.schoolId!==identity.schoolId||grant.uid!==identity.uid||
         grant.scope!==intent.scope||grant.targetHash!==hash(target)||
         grant.credentialFingerprint!==current.data().passwordHash||
         grant.usedAt!==0||grant.expiresAt<=now())
        denied(403,'ADMIN_APPROVAL_EXPIRED','Admin approval expired or does not match this action');
      const acceptedAt=now();
      tx.update(grantRef,{usedAt:acceptedAt});
      tx.create(durable,{version:1,schoolId:identity.schoolId,uid:identity.uid,
        operationId:intent.operationId,scope:intent.scope,fingerprint,acceptedAt});
      tx.set(auditRef,{action:'school_admin_mutation_bound',schoolId:identity.schoolId,
        actor:identity.uid,scope:intent.scope,operationId:intent.operationId,
        fingerprint,at:acceptedAt});
    });
    return {success:true,schoolId:identity.schoolId,authorized:true,operationId:intent.operationId};
  }

  async function assertMutationApproval(identity,intent) {
    const {fingerprint}=mutationBinding(identity,intent);
    const snapshot=await mutationRef(identity.schoolId,intent.operationId).get();
    const row=snapshot.exists?snapshot.data():null;
    if(!row||row.version!==1||row.schoolId!==identity.schoolId||
       row.uid!==identity.uid||row.operationId!==intent.operationId||
       row.scope!==intent.scope||row.fingerprint!==fingerprint)
      denied(403,'ADMIN_MUTATION_APPROVAL_REQUIRED','Original Admin Password approval required');
    return {authorized:true,operationId:intent.operationId};
  }
  return {handle, consumeApproval, assertMutationApproval};
}

module.exports = {createSchoolAdminSecurity};
