'use strict';
const {createHash}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const {bindOperation}=require('./live-sync-reconciliation');
// A public error code alone never proves that a provider did not write.
// Only verified Script/Cloudflare owner response paths can attest these narrow
// notice precondition rejections. Attestations are private process memory.
const rejected=new WeakMap();
function legacyFingerprint(school,body){
 if(!bindOperation(school,'legacy',body))return null;
 return createHash('sha256').update(canonical(body)).digest('hex');
}
function markNoticeRejection(error,school,body){
 const fingerprint=legacyFingerprint(school,body);
 if(error&&typeof error==='object'&&fingerprint&&error.status===409&&
    ['RECORD_REVISION_CONFLICT','OPERATION_ID_CONFLICT'].includes(error.code)&&
    body.collection==='school_notices'&&body.operation==='write')
  rejected.set(error,{school,fingerprint});
 return error;
}
function isNoticeRejection(error,school,body){
 const proof=error&&typeof error==='object'?rejected.get(error):null;
 return !!proof&&proof.school===school&&proof.fingerprint===legacyFingerprint(school,body);
}
module.exports={legacyFingerprint,markNoticeRejection,isNoticeRejection};
