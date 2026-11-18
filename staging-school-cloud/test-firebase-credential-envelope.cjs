'use strict';
// Isolated TEST Render only. An authenticated GitHub runner encrypts its
// existing verified Firebase Admin credential for this Render instance's
// existing RSA private key. Plaintext NEVER enters GitHub source/logs,
// connector replies, or public HTTP. The Render environment holds ciphertext.
// This is credential transport, not a second sync engine or Firebase owner.
const {createHash,createPublicKey,publicEncrypt,privateDecrypt,randomBytes,
  createCipheriv,createDecipheriv,constants}=require('node:crypto');
const PROJECT='saarthi-ai-df12b';
const SERVICE='srv-db3tgfu7bikc73abm7a0';
const PURPOSE='vidya-saarthi-isolated-test-firebase-credential-v1';
const AAD=Buffer.from([PURPOSE,PROJECT,SERVICE].join('\n'));
const hex=b=>createHash('sha256').update(b).digest('hex');
function validCredential(key){
 return key&&key.type==='service_account'&&key.project_id===PROJECT&&
  typeof key.private_key==='string'&&key.private_key.includes('BEGIN PRIVATE KEY')&&
  typeof key.client_email==='string'&&
  key.client_email.endsWith('@'+PROJECT+'.iam.gserviceaccount.com');
}
function publicWrappingKey(old){
 if(!validCredential(old))throw Error('Invalid isolated TEST wrapping credential');
 const publicDer=createPublicKey(old.private_key).export({format:'der',type:'spki'});
 return {wrappingPublicKey:publicDer.toString('base64'),wrappingKeyFingerprint:hex(publicDer)};
}
function wrapCredential(verified,wrappingPublicKey,fingerprint){
 if(!validCredential(verified))throw Error('Verified CI Firebase credential must belong to TEST project');
 if(typeof wrappingPublicKey!=='string'||wrappingPublicKey.length>1500||
    typeof fingerprint!=='string'||!/^[a-f0-9]{64}$/.test(fingerprint))
  throw Error('TEST wrapping public key identity required');
 const der=Buffer.from(wrappingPublicKey,'base64');
 if(hex(der)!==fingerprint)throw Error('TEST wrapping public key fingerprint mismatch');
 const key=createPublicKey({key:der,format:'der',type:'spki'});
 if(key.asymmetricKeyType!=='rsa'||(key.asymmetricKeyDetails?.modulusLength||0)<2048)
  throw Error('TEST wrapping key requires RSA-2048 or stronger');
 const aesKey=randomBytes(32),iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',aesKey,iv);
 cipher.setAAD(AAD);
 const ciphertext=Buffer.concat([cipher.update(JSON.stringify(verified),'utf8'),cipher.final()]);
 const tag=cipher.getAuthTag();
 const encryptedKey=publicEncrypt({key,padding:constants.RSA_PKCS1_OAEP_PADDING,oaepHash:'sha256'},aesKey);
 aesKey.fill(0);
 return {version:1,purpose:PURPOSE,projectId:PROJECT,serviceId:SERVICE,
  wrappingKeyFingerprint:fingerprint,
  encryptedKey:encryptedKey.toString('base64'),iv:iv.toString('base64'),
  tag:tag.toString('base64'),ciphertext:ciphertext.toString('base64')};
}
function unwrapCredential(old,envelope){
 if(!validCredential(old))throw Error('Invalid old TEST credential');
 if(!envelope||envelope.version!==1||envelope.purpose!==PURPOSE||
    envelope.projectId!==PROJECT||envelope.serviceId!==SERVICE)
  throw Error('Encrypted TEST credential envelope scope mismatch');
 const {wrappingKeyFingerprint}=publicWrappingKey(old);
 if(envelope.wrappingKeyFingerprint!==wrappingKeyFingerprint)
  throw Error('Encrypted TEST credential is not addressed to this Render key');
 const base64=value=>{
  if(typeof value!=='string'||value.length>12000||!value.length||
     !/^[A-Za-z0-9+/]+={0,2}$/.test(value))throw Error('Malformed encrypted TEST credential');
  return Buffer.from(value,'base64');
 };
 const iv=base64(envelope.iv),tag=base64(envelope.tag),encryptedKey=base64(envelope.encryptedKey);
 const payload=base64(envelope.ciphertext);
 if(iv.length!==12||tag.length!==16||payload.length<250||payload.length>8192)
  throw Error('Invalid encrypted TEST credential sizes');
 let aes;
 try{
  aes=privateDecrypt({key:old.private_key,padding:constants.RSA_PKCS1_OAEP_PADDING,
   oaepHash:'sha256'},encryptedKey);
  const decipher=createDecipheriv('aes-256-gcm',aes,iv);
  decipher.setAAD(AAD);decipher.setAuthTag(tag);
  const parsed=JSON.parse(Buffer.concat([decipher.update(payload),decipher.final()]).toString('utf8'));
  if(!validCredential(parsed))throw Error('Decrypted TEST credential project mismatch');
  return parsed;
 }finally{if(aes)aes.fill(0);}
}
module.exports={publicWrappingKey,wrapCredential,unwrapCredential,validCredential};
