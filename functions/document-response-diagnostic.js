'use strict';
const {createHmac}=require('node:crypto');
// Contract metadata only. Never log row values, IDs, credentials or file content.
function documentResponseDiagnostic(request,response,school,key){
 if(request.action!=='managed_records'||request.collection!=='documents')return null;
 const text=v=>typeof v==='string'&&v.length>0;
 const fingerprint=id=>createHmac('sha256',key).update(school+'\n'+id).digest('hex');
 const shape=row=>({object:!!row&&typeof row==='object'&&!Array.isArray(row),
  sameSchool:row?.schoolId===school,tombstone:row?._syncDeleted===true,
  documentRevision:text(row?.documentRevision),serverRevision:text(row?._syncRevision),
  operationId:text(row?._syncOperationId),contentHash:text(row?.contentHash),
  fileUrl:text(row?.fileUrl),owner:typeof row?.studentId==='string'});
 const result={event:'document_response_contract',version:1,
  operation:['read','write','delete'].includes(request.operation)?request.operation:'unknown',
  requestProtocol2:request.syncProtocol===2,responseProtocol2:response?.syncProtocol===2,
  success:response?.success===true,sameSchool:response?.schoolId===school,
  acknowledgedRevision:text(response?.recordRevision)};
 if(request.operation==='read'){
  const records=response?.records;
  result.recordMap=!!records&&typeof records==='object'&&!Array.isArray(records);
  const ids=result.recordMap?Object.keys(records):[];
  result.recordCount=ids.length;
  result.sampleLimited=ids.length>10;
  result.records=ids.slice(0,10).map(id=>({fingerprint:fingerprint(id),...shape(records[id])}));
 }else{
  result.fingerprint=fingerprint(typeof request.id==='string'?request.id:'');
  result.expectedDocumentRevisionEmpty=request.expectedRevision==='';
  result.expectedServerRevisionEmpty=request.expectedRecordRevision==='';
 }
 return result;
}
module.exports={documentResponseDiagnostic};
