'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {generateKeyPairSync}=require('node:crypto');
const {publicWrappingKey,wrapCredential,unwrapCredential}=require('./test-firebase-credential-envelope.cjs');
const rsa=()=>generateKeyPairSync('rsa',{modulusLength:2048,publicKeyEncoding:{format:'pem',type:'spki'},privateKeyEncoding:{format:'pem',type:'pkcs8'}}).privateKey;
const make=(name,private_key)=>({
 type:'service_account',project_id:'saarthi-ai-df12b',
 client_email:name+'@saarthi-ai-df12b.iam.gserviceaccount.com',
 private_key
});
test('TEST Firebase credential ciphertext survives verified encrypt/decrypt with no plaintext in envelope',()=>{
 const old=make('render-old',rsa()),correct=make('github-verified',rsa());
 const pub=publicWrappingKey(old);
 const envelope=wrapCredential(correct,pub.wrappingPublicKey,pub.wrappingKeyFingerprint);
 assert.equal(envelope.version,1);
 assert(!JSON.stringify(envelope).includes(correct.private_key));
 assert(!JSON.stringify(envelope).includes(correct.client_email));
 const decoded=unwrapCredential(old,envelope);
 assert.deepEqual(decoded,correct);
 assert.equal(Object.keys(envelope).length,9);
});
test('TEST Firebase credential is scoped to exact existing Render key and project',()=>{
 const old=make('render-old',rsa()),other=make('different-render',rsa());
 const good=make('github-verified',rsa());
 const pub=publicWrappingKey(old);
 assert.throws(()=>unwrapCredential(other,wrapCredential(good,pub.wrappingPublicKey,pub.wrappingKeyFingerprint)),/not addressed/);
 assert.throws(()=>wrapCredential({...good,project_id:'foreign'},pub.wrappingPublicKey,pub.wrappingKeyFingerprint),/TEST project/);
 assert.throws(()=>wrapCredential(good,pub.wrappingPublicKey,'a'.repeat(64)),/fingerprint mismatch/);
});
test('TEST Firebase envelope rejects mutation, identity replay and ciphertext tampering',()=>{
 const old=make('render-old',rsa()),correct=make('github-verified',rsa());
 const pub=publicWrappingKey(old),envelope=wrapCredential(correct,pub.wrappingPublicKey,pub.wrappingKeyFingerprint);
 for(const next of [
  {...envelope,serviceId:'srv-unrelated'},
  {...envelope,projectId:'other-project'},
  {...envelope,version:2},
  {...envelope,wrappingKeyFingerprint:'b'.repeat(64)},
  {...envelope,tag:Buffer.alloc(16,0).toString('base64')},
  {...envelope,ciphertext:Buffer.alloc(400,255).toString('base64')}
 ])assert.throws(()=>unwrapCredential(old,next));
});
