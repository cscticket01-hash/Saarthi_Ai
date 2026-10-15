'use strict';
const crypto=require('node:crypto');
const {storage,A}=require('./managed-storage');
function documentDeleteContracts(){
 return ['absent','existing','replay'].map(name=>{
  const s=storage({bundle:true,recordBackups:true}),id='contract-'+name;
  let base='',revision='';
  if(name==='existing'){
   const write=s.call({action:'managed_records',operation:'write',collection:'documents',id,
    syncProtocol:2,operationId:'contract-original-upload',expectedRecordRevision:'',expectedRevision:'',
    data:{schoolId:A,documentRevision:'original-generation',studentId:'synthetic-person',personId:'stable-synthetic',ownerRole:'student'}});
   if(!write.success)throw Error(JSON.stringify(write));
   base='original-generation';revision=write.recordRevision;
  }
  const payload={action:'delete_student_document',schoolId:A,documentId:id,
   documentRevision:'local-delete-'+name,baseCloudRevision:base};
  payload.deleteOperationId=crypto.createHash('sha256').update(`${id}:${payload.documentRevision}:delete`).digest('hex');
  const request={action:'managed_records',operation:'delete',collection:'documents',id,
   syncProtocol:2,operationId:payload.deleteOperationId,expectedRecordRevision:revision,expectedRevision:base};
  let ack=s.call(request);if(!ack.success)throw Error(JSON.stringify(ack));
  if(name==='replay'){ack=s.call(request);if(!ack.success)throw Error(JSON.stringify(ack));}
  const readback=s.call({action:'managed_records',operation:'read',collection:'documents',syncProtocol:2});
  if(!readback.success)throw Error(JSON.stringify(readback));
  const normalize=value=>JSON.parse(JSON.stringify(value,(key,v)=>
    ['recordRevision','_syncRevision'].includes(key)?'server-delete-revision':key==='collectionRevision'?'server-collection-revision':key==='_syncRequestHash'?'opaque-request-hash':v));
  return {name,payload,deleteResponse:normalize(ack),readback:normalize(readback)};
 });
}
module.exports={documentDeleteContracts};
