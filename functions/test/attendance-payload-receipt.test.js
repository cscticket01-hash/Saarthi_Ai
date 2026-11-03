'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createCipheriv,createHash,randomBytes}=require('node:crypto');
const {buildAttendancePayloadReceipt,attendancePayloadFinishValues,attendanceReceiptOwns}=require('../attendance-payload-receipt');
const {createCloudflareSync}=require('../cloudflare-sync');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),key='attendance-payload-test-key-00000001';
function fixture(){
 const operationId=createHash('sha256').update(JSON.stringify([A,'student','stable-generation-different-from-document','2026-11-02','entry'])).digest('hex');
 const request={action:'mobile_mark_attendance',projectId:A,role:'student',personId:'Class_1_Roll_12',mode:'entry',sessionToken:'private-session-not-retained',linkToken:'private-link-not-retained',latitude:24,longitude:92,accuracy:3,clientCapturedAt:Date.parse('2026-11-02T04:30:00Z')};
 const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',createHash('sha256').update(key).digest(),iv),encrypted=Buffer.concat([cipher.update(JSON.stringify(request)),cipher.final(),cipher.getAuthTag()]);
 const row={operationId,schoolId:A,day:'2026-11-02',mode:'entry',state:'processing',payloadTransport:'cloudflare-v1',payload:{iv:iv.toString('base64'),body:encrypted.toString('base64')}};
 const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:[A]});
 return {schoolId:A,operationId,row,request:edge.decryptAttendance(row.payload),verifiedAck:{schoolId:A,operationId,success:true}};
}
test('verified Cloudflare envelope becomes metadata-only receipt preserving document owner across generations',()=>{
 const f=fixture(),values=attendancePayloadFinishValues({...f,values:{state:'completed',completedAt:1234,attempts:1,nextAttemptAt:Number.MAX_SAFE_INTEGER}});
 assert.equal(values.attendancePayloadPurged,true);assert.equal(values.attendanceOwnerReceipt.documentId,f.request.personId);assert.match(values.attendanceOwnerReceipt.payloadHash,/^[a-f0-9]{64}$/);
 const text=JSON.stringify(values);for(const secret of ['latitude','longitude','private-session-not-retained','private-link-not-retained','iv','body'])assert.ok(!text.includes('"'+secret+'"'),secret);
 assert.equal(f.row.payloadTransport,'cloudflare-v1');assert.ok(f.row.payload.body);
 const purged={...f.row,...values,payload:undefined};assert.equal(attendanceReceiptOwns({...f,row:purged,permit:{role:'student',documentId:f.request.personId}}),true);
 for(const permit of [{role:'teacher',documentId:f.request.personId},{role:'student',documentId:'someone-else'}])assert.equal(attendanceReceiptOwns({...f,row:purged,permit}),false);
 assert.equal(attendanceReceiptOwns({...f,schoolId:B,row:purged,permit:{role:'student',documentId:f.request.personId}}),false);
});
test('retry/review payloads are untouched and completion without exact scoped successful ACK is refused',()=>{
 const f=fixture();for(const state of ['retry','needsAttention']){const values={state,nextAttemptAt:1234};assert.equal(attendancePayloadFinishValues({...f,verifiedAck:null,values}),values);}
 for(const ack of [null,{...f.verifiedAck,success:false},{...f.verifiedAck,schoolId:B},{...f.verifiedAck,operationId:'0'.repeat(64)}])assert.throws(()=>buildAttendancePayloadReceipt({...f,verifiedAck:ack}),e=>e.code==='ATTENDANCE_PAYLOAD_RECEIPT_UNVERIFIED');
 for(const patch of [{payloadTransport:undefined,payload:'legacy-protected-string'},{schoolId:B},{operationId:'0'.repeat(64)},{state:'completed'},{mode:'exit'}])assert.throws(()=>buildAttendancePayloadReceipt({...f,row:{...f.row,...patch}}));
 assert.throws(()=>attendancePayloadFinishValues({...f,values:{state:'completed',completedAt:0}}));
});
test('invalid identity/capture and altered receipt cannot grant status access',()=>{
 const f=fixture();for(const patch of [{personId:'../foreign'},{role:'admin'},{schoolId:B},{projectId:B},{action:'mobile_dashboard'},{clientCapturedAt:Date.parse('2026-11-01T04:30:00Z')}])assert.throws(()=>buildAttendancePayloadReceipt({...f,request:{...f.request,...patch}}));
 const receipt=buildAttendancePayloadReceipt(f),permit={role:'student',documentId:f.request.personId},row={...f.row,state:'completed',attendancePayloadPurged:true,attendanceOwnerReceipt:receipt};
 for(const patch of [{state:'retry'},{attendancePayloadPurged:false},{attendanceOwnerReceipt:{...receipt,driveVerified:false}},{attendanceOwnerReceipt:{...receipt,operationId:'0'.repeat(64)}},{attendanceOwnerReceipt:{...receipt,payloadHash:'invalid'}}])assert.equal(attendanceReceiptOwns({...f,row:{...row,...patch},permit}),false);
});

test('broker protect transport in Cloudflare store uses its own metadata format, never EDGE decrypt',()=>{
 const f=fixture(),{protect}=require('../managed-schools'),payload=protect(JSON.stringify(f.request),'a'.repeat(64)),row={...f.row,payloadTransport:undefined,payload};
 const proof=buildAttendancePayloadReceipt({...f,row});assert.equal(proof.documentId,f.request.personId);assert.notEqual(proof.payloadHash,buildAttendancePayloadReceipt(f).payloadHash);
 assert.throws(()=>buildAttendancePayloadReceipt({...f,row:{...row,payloadTransport:'cloudflare-v1'}}));
 assert.throws(()=>buildAttendancePayloadReceipt({...f,row:{...f.row,payloadTransport:undefined}}));
});
