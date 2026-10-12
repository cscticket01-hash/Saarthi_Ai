'use strict';

const {createHash}=require('node:crypto');
const digest=(text)=>createHash('sha256').update(text).digest('hex');
const IDENT=/^[A-Za-z0-9_-]{1,120}$/, OP=/^[A-Za-z0-9_-]{16,100}$/;
function deny(status,message){const e=new Error(message);e.status=status;e.publicMessage=true;throw e;}
function validInput(request) {
  if (!request || !['issue','reissue','revoke','status','verify'].includes(request.operation) ||
      !['student','teacher'].includes(request.role) ||
      !IDENT.test(request.personId||'') ||
      request.schoolId!==undefined && !/^vs-[a-f0-9]{32}$/.test(request.schoolId)) {
    deny(400,'Invalid school card identity');
  }
  if (['issue','reissue','revoke'].includes(request.operation) && !OP.test(request.operationId||'')) {
    deny(400,'An idempotent card operation ID is required');
  }
  if (request.operation==='revoke' || request.operation==='reissue' ||
      request.operation==='verify') {
    if (!/^[a-f0-9]{64}$/.test(request.cardIssueId||'')) deny(400,'Exact card issue ID required');
  }
  if (['issue','reissue'].includes(request.operation)) {
    if (!Number.isSafeInteger(request.expiresAt)) deny(400,'Card expiration required');
  }
  if (request.operation==='verify' && !/^[a-f0-9]{64}$/.test(request.qrHash||'')) {
    deny(400,'QR fingerprint required');
  }
}

/// Server-authoritative state. Only call AFTER verified Firebase membership,
/// active licence and device authorization. The client-supplied admin boolean
/// is never consulted. Direct client Firestore access must remain denied.
///
/// This module intentionally does NOT mint offline credentials or make older
/// Android/Windows QR readers enforce revocations until they are upgraded.
function createManagedCardIssueAuthority({db, now=Date.now}) {
  return async function cardIssue({request,identity,readPerson}) {
    validInput(request);
    const schoolId=identity?.schoolId,actor=identity?.uid;
    if(!/^vs-[a-f0-9]{32}$/.test(schoolId||'') || !actor ||
       request.schoolId!==undefined&&request.schoolId!==schoolId) {
      deny(403,'Verified same-school administrator required');
    }
    const role=request.role,personId=request.personId;
    const key=digest(JSON.stringify([schoolId,role,personId]));
    const registry=db.doc('school_card_issue_registry/'+key);
    const publicEntry=(data)=>({
      success:true,schoolId,role,personId,
      currentIssueId:data?.currentIssueId||null,
      state:data?.state||'not_issued',
      expiresAt:data?.expiresAt||null,
      version:data?.version||0,
    });
    if (request.operation==='status' || request.operation==='verify') {
      const snapshot=await registry.get(),data=snapshot.exists?snapshot.data():null;
      if(data && (data.schoolId!==schoolId||data.personId!==personId||data.role!==role)) {
        deny(403,'Card registry belongs to a different identity');
      }
      if(request.operation==='status')return publicEntry(data);
      const valid=!!data && data.state==='active' &&
        data.currentIssueId===request.cardIssueId &&
        data.qrHash===request.qrHash && data.expiresAt>now();
      return {...publicEntry(data),valid,reason:valid?'active':'not_authorized'};
    }
    // Emergency revocation must work even when the original person record
    // was deleted, moved or the school-owned Script is temporarily offline.
    // Issuance/reissuance still require authoritative Script readback.
    let qrHash=null;
    if(request.operation!=='revoke'){
      if(typeof readPerson!=='function')deny(503,'Card identity verification unavailable');
      const person=await readPerson(schoolId,role,personId);
      if(!person || person.schoolId!==schoolId ||
          person._syncDeleted===true || person.deleted===true ||
          typeof person.mobileLinkToken!=='string' ||
          person.mobileLinkToken.length<20) {
        deny(409,'Sync a verified school person and QR before issuing a card');
      }
      qrHash=digest(role+'/'+(person.mobileStableId||personId)+'/'+person.mobileLinkToken);
    }
    const operationId=request.operationId;
    const commandHash=digest(JSON.stringify([
      request.operation,schoolId,role,personId,request.cardIssueId||null,
      request.expiresAt||null,operationId,
    ]));
    const opKey=digest(JSON.stringify([schoolId,operationId]));
    const event=db.doc('school_card_issue_events/'+opKey);
    return db.runTransaction(async tx=>{
      const [existing,prior]=await Promise.all([tx.get(registry),tx.get(event)]);
      if(prior.exists){
        const row=prior.data();
        if(row.schoolId!==schoolId||row.actor!==actor||row.commandHash!==commandHash) {
          deny(409,'Card operation replay does not match original command');
        }
        return row.result;
      }
      const prev=existing.exists?existing.data():null;
      if(prev && (prev.schoolId!==schoolId||prev.role!==role||prev.personId!==personId)) {
        deny(403,'Foreign school card registry');
      }
      const when=now();
      let result;
      let updated;
      if(request.operation==='revoke'){
        if(!prev || prev.state!=='active'||prev.currentIssueId!==request.cardIssueId) {
          deny(409,'Card was changed or already revoked');
        }
        updated={...prev,state:'revoked',revokedAt:when,updatedAt:when,
          version:prev.version+1,updatedBy:actor};
        result={...publicEntry(updated),revoked:true};
      }else{
        if(request.expiresAt<=when+60000||request.expiresAt>when+2*365*86400000) {
          deny(400,'Card expiry must be in the next two years');
        }
        if(request.operation==='issue' && prev)deny(409,'Existing card identity requires reissue');
        if(request.operation==='reissue' &&
          (!prev||prev.currentIssueId!==request.cardIssueId)) {
          deny(409,'Previous card issue changed; explicit review required');
        }
        const currentIssueId=digest(JSON.stringify([schoolId,role,personId,operationId]));
        updated={schoolId,role,personId,currentIssueId,qrHash,
          state:'active',issuedAt:when,expiresAt:request.expiresAt,
          version:(prev?.version||0)+1,updatedAt:when,updatedBy:actor,
          ...(prev?{previousIssueId:prev.currentIssueId}:{}),
        };
        result={...publicEntry(updated),issued:true};
      }
      tx.set(registry,updated);
      tx.create(event,{schoolId,actor,commandHash,at:when,operationId,
        action:request.operation,result});
      return result;
    });
  };
}

module.exports={createManagedCardIssueAuthority};
