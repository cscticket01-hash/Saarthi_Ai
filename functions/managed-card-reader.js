'use strict';
const {createHash,createPrivateKey,createPublicKey,sign,verify}=require('node:crypto');
const hash=value=>createHash('sha256').update(value).digest('hex'),TTL=900000;
function deny(status,code){const e=new Error(code);e.status=status;e.code=code;e.publicMessage=true;throw e;}
function claims(token,key,purpose,t){if(typeof token!=='string'||token.length>5000)deny(401,'CARD_RECEIPT_REQUIRED');const p=token.split('.');
 if(p.length!==2||! /^[A-Za-z0-9_-]+$/.test(p[0])||! /^[A-Za-z0-9_-]{86}$/.test(p[1])||!verify(null,Buffer.from(p[0]),key,Buffer.from(p[1],'base64url')))deny(401,'CARD_RECEIPT_INVALID');
 let c;try{c=JSON.parse(Buffer.from(p[0],'base64url').toString());}catch{deny(401,'CARD_RECEIPT_INVALID');}
 if(c.version!==1||c.purpose!==purpose||!Number.isSafeInteger(c.issuedAt)||!Number.isSafeInteger(c.expiresAt)||c.issuedAt>t||c.expiresAt<=t||c.expiresAt<=c.issuedAt)deny(401,'CARD_RECEIPT_EXPIRED');return c;}
/** Inactive until the coordinator verifies ALL readers. verifiedLogin is ONLY a
 * successful signed school-provider response, never a client/admin assertion.
 * Every online authorization re-reads central card status. Offline revocation
 * cannot be instantaneous; signed offline approval is limited to15 minutes.
 */
function createManagedCardReader({db,enforced=false,privateKey,now=Date.now}){
 let signingKey,publicKey;
 if(enforced){signingKey=typeof privateKey==='string'?createPrivateKey(privateKey):privateKey;if(signingKey?.type!=='private'||signingKey.asymmetricKeyType!=='ed25519')throw Error('Card reader Ed25519 signing key required');publicKey=createPublicKey(signingKey);}
 function bound(input){if(!/^vs-[a-f0-9]{32}$/.test(input.schoolId||'')||!['student','teacher'].includes(input.role)||typeof input.personId!=='string'||!input.personId||input.personId.length>200||input.personId.includes('/')||typeof input.linkToken!=='string'||input.linkToken.length<20||input.linkToken.length>128||typeof input.deviceId!=='string'||! /^[A-Za-z0-9_-]{32,160}$/.test(input.deviceId)||typeof input.sessionToken!=='string'||input.sessionToken.length<40)deny(400,'CARD_IDENTITY_INVALID');}
 async function registry(school,role,person,document){const ids=[...new Set([person,document].filter(Boolean))],rows=await Promise.all(ids.map(async id=>{
  const snapshot=await db.doc('school_card_issue_registry/'+hash(JSON.stringify([school,role,id]))).get();return snapshot.exists?{id,...snapshot.data()}:null;}));
 const found=rows.filter(Boolean);if(found.length>1)deny(409,'CARD_IDENTITY_AMBIGUOUS');const row=found[0];
 if(row&&(row.schoolId!==school||row.role!==role||!ids.includes(row.personId)))deny(403,'CARD_SCHOOL_MISMATCH');return row;}
 function state(row,issue,qr,t){if(!row){if(issue)deny(403,'CARD_ISSUE_UNKNOWN');return 'legacy_unregistered';}
  if(!issue||row.currentIssueId!==issue||row.qrHash!==qr||row.state!=='active'||!Number.isSafeInteger(row.expiresAt)||row.expiresAt<=t)deny(403,'CARD_ISSUE_NOT_AUTHORIZED');return 'active';}
 function token(payload){const value=Buffer.from(JSON.stringify(payload)).toString('base64url');return value+'.'+sign(null,Buffer.from(value),signingKey).toString('base64url');}
 function output(c,cardState,t,limit){return {cardReaderEnforced:true,cardIssueId:c.cardIssueId||null,cardState,
  cardAuthorizationToken:token({...c,purpose:'card-online-session',issuedAt:t,expiresAt:Math.min(limit,t+30*86400000)}),
  cardOfflineLease:token({...c,purpose:'card-offline',issuedAt:t,expiresAt:Math.min(limit,t+TTL)}),cardOfflineExpiresAt:Math.min(limit,t+TTL)};}
 return {
  async verifyLogin(input,verifiedLogin){if(!enforced){if(input.cardIssueId)deny(503,'CARD_READER_DISABLED');return {cardReaderEnforced:false};}
   const t=now();if(!Number.isSafeInteger(t)||t<0)deny(503,'CARD_SERVER_CLOCK_INVALID');const sessionToken=verifiedLogin?.sessionToken;bound({...input,sessionToken});
   if(verifiedLogin.role!==input.role||verifiedLogin.personId!==input.personId||verifiedLogin.projectId!==input.schoolId||verifiedLogin.schoolId!==input.schoolId||!verifiedLogin.person||!Number.isSafeInteger(verifiedLogin.expiresAt)||verifiedLogin.expiresAt<=t)deny(403,'CARD_PROVIDER_IDENTITY_MISMATCH');
   if(input.cardIssueId&&! /^[a-f0-9]{64}$/.test(input.cardIssueId))deny(400,'CARD_ISSUE_INVALID');
   const qrHash=hash(input.role+'/'+input.personId+'/'+input.linkToken),row=await registry(input.schoolId,input.role,input.personId,verifiedLogin.person.id);
   const cardState=state(row,input.cardIssueId,qrHash,t),limit=Math.min(verifiedLogin.expiresAt,row?.expiresAt||verifiedLogin.expiresAt);
   const c={version:1,schoolId:input.schoolId,role:input.role,personId:input.personId,registryPersonId:row?.personId||input.personId,documentId:verifiedLogin.person.id||input.personId,cardIssueId:input.cardIssueId||null,qrHash,sessionHash:hash(sessionToken),deviceHash:hash(input.deviceId)};
   return output(c,cardState,t,limit);
  },
  async authorizeOnline({schoolId,deviceId,sessionToken,cardAuthorizationToken,role,personId,linkToken,cardIssueId}){
   if(!enforced)return {cardReaderEnforced:false};
   const t=now();if(!Number.isSafeInteger(t)||t<0)deny(503,'CARD_SERVER_CLOCK_INVALID');const c=claims(cardAuthorizationToken,publicKey,'card-online-session',t);
   if(c.schoolId!==schoolId||c.deviceHash!==hash(String(deviceId))||c.sessionHash!==hash(String(sessionToken)))deny(403,'CARD_SESSION_BINDING_MISMATCH');
   if(role!==undefined&&role!==c.role||personId!==undefined&&personId!==c.personId||linkToken!==undefined&&hash(c.role+'/'+c.personId+'/'+String(linkToken))!==c.qrHash||cardIssueId!==undefined&&cardIssueId!==c.cardIssueId)deny(403,'CARD_PERSON_BINDING_MISMATCH');
   const row=await registry(schoolId,c.role,c.registryPersonId,c.documentId),cardState=state(row,c.cardIssueId,c.qrHash,t);
   // Original session expiry remains the upper bound, never extended by refresh.
   return output(c,cardState,t,Math.min(c.expiresAt,row?.expiresAt||c.expiresAt));
  },
  verifyCapture({schoolId,request,acceptedAt}) {
   if(!enforced)return {cardReaderEnforced:false};
   const t=now(),captured=request?.clientCapturedAt;
   if(!Number.isSafeInteger(captured)||captured<=0||captured>t+120000||typeof request.originalAttendancePermit!=='string'||request.originalPermitHash!==hash(request.originalAttendancePermit)||request.attendancePermit!==request.originalAttendancePermit)deny(409,'CARD_CAPTURE_APPROVAL_INVALID');
   const c=claims(request.originalCardOfflineLease,publicKey,'card-offline',captured);
   const received=acceptedAt===undefined?t:acceptedAt;
   if(!Number.isSafeInteger(received)||received>t||received>=c.expiresAt||c.expiresAt-c.issuedAt>TTL||c.schoolId!==schoolId||c.role!==request.role||c.personId!==request.personId||c.cardIssueId!==(request.cardIssueId||null)||c.deviceHash!==hash(String(request.deviceId))||c.sessionHash!==hash(String(request.sessionToken))||c.qrHash!==hash(request.role+'/'+request.personId+'/'+request.linkToken))deny(409,'CARD_CAPTURE_APPROVAL_EXPIRED');
   return {cardReaderEnforced:true,originalApprovedUntil:c.expiresAt};
  },
  publicKeyRaw(){return publicKey?publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64url'):null;},
 };
}
module.exports={createManagedCardReader};
