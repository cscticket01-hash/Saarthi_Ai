'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createHash,generateKeyPairSync,verify}=require('node:crypto');
const {createManagedCardReader}=require('../managed-card-reader');
const hash=v=>createHash('sha256').update(v).digest('hex'),A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),keys=generateKeyPairSync('ed25519');
function fixture(){let time=1000000;const rows=new Map();const db={doc:path=>({get:async()=>({exists:rows.has(path),data:()=>structuredClone(rows.get(path))})})};
 const input={schoolId:A,role:'student',personId:'synthetic-student',linkToken:'s'.repeat(43),deviceId:'d'.repeat(43),cardIssueId:'a'.repeat(64)};
 const login={schoolId:A,projectId:A,role:input.role,personId:input.personId,sessionToken:'t'.repeat(64),expiresAt:time+86400000,person:{id:'synthetic-student'}};
 const key='school_card_issue_registry/'+hash(JSON.stringify([A,input.role,input.personId]));
 rows.set(key,{schoolId:A,role:input.role,personId:input.personId,currentIssueId:input.cardIssueId,qrHash:hash(input.role+'/'+input.personId+'/'+input.linkToken),expiresAt:time+86400000,state:'active'});
 const reader=createManagedCardReader({db,enforced:true,privateKey:keys.privateKey,now:()=>time});
 return {db,rows,key,input,login,reader,time:()=>time,setTime:v=>time=v};}
const call=(f,response,patch={})=>f.reader.authorizeOnline({schoolId:A,deviceId:f.input.deviceId,sessionToken:f.login.sessionToken,cardAuthorizationToken:response.cardAuthorizationToken,...patch});
test('reader rollout default preserves unissued legacy but rejects issued identity',async()=>{
 const f=fixture(),reader=createManagedCardReader({db:f.db});
 assert.deepEqual(await reader.verifyLogin({...f.input,cardIssueId:undefined},f.login),{cardReaderEnforced:false});
 await assert.rejects(reader.verifyLogin(f.input,f.login),{code:'CARD_READER_DISABLED'});
 assert.throws(()=>createManagedCardReader({db:f.db,enforced:true}),/signing key/);
});
test('provider verified identity plus exact active issue produces signed session/device-bound approval',async()=>{
 const f=fixture(),result=await f.reader.verifyLogin(f.input,f.login);
 assert.equal(result.cardState,'active');assert.equal(result.cardIssueId,f.input.cardIssueId);
 const [payload,signature]=result.cardOfflineLease.split('.');assert(verify(null,Buffer.from(payload),keys.publicKey,Buffer.from(signature,'base64url')));
 const claims=JSON.parse(Buffer.from(payload,'base64url'));assert.equal(claims.expiresAt-claims.issuedAt,900000);
 assert.equal(claims.sessionHash,hash(f.login.sessionToken));assert.equal(claims.deviceHash,hash(f.input.deviceId));
 assert.equal((await call(f,result)).cardState,'active');
});
test('foreign provider identity, unknown issue, legacy downgrade and QR mismatch fail closed',async()=>{
 const f=fixture();await assert.rejects(f.reader.verifyLogin(f.input,{...f.login,schoolId:B}),{code:'CARD_PROVIDER_IDENTITY_MISMATCH'});
 await assert.rejects(f.reader.verifyLogin({...f.input,cardIssueId:'b'.repeat(64)},f.login),{code:'CARD_ISSUE_NOT_AUTHORIZED'});
 await assert.rejects(f.reader.verifyLogin({...f.input,cardIssueId:undefined},f.login),{code:'CARD_ISSUE_NOT_AUTHORIZED'});
 await assert.rejects(f.reader.verifyLogin({...f.input,linkToken:'z'.repeat(43)},f.login),{code:'CARD_ISSUE_NOT_AUTHORIZED'});
 f.rows.clear();await assert.rejects(f.reader.verifyLogin(f.input,f.login),{code:'CARD_ISSUE_UNKNOWN'});
});
test('every online use reads revocation and old issue remains rejected after reissue',async()=>{
 const f=fixture(),result=await f.reader.verifyLogin(f.input,f.login);
 f.rows.get(f.key).state='revoked';await assert.rejects(call(f,result),{code:'CARD_ISSUE_NOT_AUTHORIZED'});
 f.rows.get(f.key).state='active';f.rows.get(f.key).currentIssueId='b'.repeat(64);
 await assert.rejects(call(f,result),{code:'CARD_ISSUE_NOT_AUTHORIZED'});
});
test('signed receipt replay cannot move to another session, device or school',async()=>{
 const f=fixture(),result=await f.reader.verifyLogin(f.input,f.login);
 for(const patch of [{schoolId:B},{deviceId:'x'.repeat(43)},{sessionToken:'x'.repeat(64)}])await assert.rejects(call(f,result,patch),{code:'CARD_SESSION_BINDING_MISMATCH'});
 await assert.rejects(call(f,result,{cardAuthorizationToken:result.cardAuthorizationToken.split('.')[0]+'.'+(result.cardAuthorizationToken.split('.')[1][0]==='A'?'B':'A')+result.cardAuthorizationToken.split('.')[1].slice(1)}),{code:'CARD_RECEIPT_INVALID'});
 f.setTime(f.login.expiresAt);await assert.rejects(call(f,result),{code:'CARD_RECEIPT_EXPIRED'});
});
test('legacy receipt remains non-active and cannot bypass newly registered/revoked card',async()=>{
 const f=fixture();f.rows.clear();const result=await f.reader.verifyLogin({...f.input,cardIssueId:undefined},f.login);
 assert.equal(result.cardState,'legacy_unregistered');assert.equal((await call(f,result)).cardState,'legacy_unregistered');
 f.rows.set(f.key,{schoolId:A,role:f.input.role,personId:f.input.personId,state:'revoked',currentIssueId:'b'.repeat(64),expiresAt:f.login.expiresAt});
 await assert.rejects(call(f,result),{code:'CARD_ISSUE_NOT_AUTHORIZED'});
});
test('registry aliases are provider-bound and ambiguous/foreign entries rejected',async()=>{
 const f=fixture();const otherKey='school_card_issue_registry/'+hash(JSON.stringify([A,f.input.role,'provider-doc-id']));
 f.rows.set(otherKey,{...f.rows.get(f.key),personId:'provider-doc-id'});
 await assert.rejects(f.reader.verifyLogin(f.input,{...f.login,person:{id:'provider-doc-id'}}),{code:'CARD_IDENTITY_AMBIGUOUS'});
 f.rows.delete(otherKey);f.rows.get(f.key).schoolId=B;
 await assert.rejects(f.reader.verifyLogin(f.input,f.login),{code:'CARD_SCHOOL_MISMATCH'});
});
test('original capture approval cannot be replaced, expired-replayed or moved to another device',async()=>{
 const f=fixture(),approval=await f.reader.verifyLogin(f.input,f.login),permit='synthetic-original-permit';
 const request={...f.input,sessionToken:f.login.sessionToken,clientCapturedAt:f.time(),attendancePermit:permit,originalAttendancePermit:permit,originalPermitHash:hash(permit),originalCardOfflineLease:approval.cardOfflineLease};
 assert.equal(f.reader.verifyCapture({schoolId:A,request}).cardReaderEnforced,true);
 assert.throws(()=>f.reader.verifyCapture({schoolId:A,request:{...request,attendancePermit:'fresh-replacement'}}),{code:'CARD_CAPTURE_APPROVAL_INVALID'});
 assert.throws(()=>f.reader.verifyCapture({schoolId:A,request:{...request,deviceId:'x'.repeat(43)}}),{code:'CARD_CAPTURE_APPROVAL_EXPIRED'});
 const acceptedAt=f.time();f.setTime(acceptedAt+900000);
 assert.throws(()=>f.reader.verifyCapture({schoolId:A,request}),{code:'CARD_CAPTURE_APPROVAL_EXPIRED'});
 assert.equal(f.reader.verifyCapture({schoolId:A,request,acceptedAt}).cardReaderEnforced,true);
});
