'use strict';
// Runs only on the verified isolated TEST branch in GitHub Actions.
// The Firebase private key is never printed, committed or posted to Render.
// Only an authenticated ciphertext addressed to the existing Render RSA key
// leaves the runner; the connected Render tool applies ciphertext as an env var.
const crypto=require('node:crypto');
const fs=require('node:fs');
const {wrapCredential}=require('../../staging-school-cloud/test-firebase-credential-envelope.cjs');
const PROJECT='saarthi-ai-df12b';
const RENDER='https://saarthi-sync-v2-test.onrender.com/school-cloud/healthz';
const TEST_BRANCH='refs/heads/feature/smart-sync-3';
async function main(){
 if(process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REF!==TEST_BRANCH)
  throw Error('Isolated GitHub TEST branch required');
 const raw=process.env.SCHOOL_SERVICE_ACCOUNT_JSON;
 if(!raw||raw.length>12000)throw Error('Verified CI Firebase Admin credential unavailable');
 let credential;
 try{credential=JSON.parse(raw)}catch{throw Error('Invalid CI service-account JSON')}
 if(credential.project_id!==PROJECT||credential.type!=='service_account'||
   !credential.client_email?.endsWith('@'+PROJECT+'.iam.gserviceaccount.com')||
   !credential.private_key)throw Error('CI credential belongs to another project');
 const res=await fetch(RENDER,{signal:AbortSignal.timeout(25000)});
 if(!res.ok)throw Error('Exact TEST Render health unavailable: HTTP '+res.status);
 const health=await res.json();
 if(health.ready!==true||health.projectId!==PROJECT||
    health.service!=='vidya-saarthi-central-staging'||
    !/^[a-f0-9]{40}$/.test(health.runtimeCommit||'')||
    typeof health.wrappingPublicKey!=='string'||
    !/^[a-f0-9]{64}$/.test(health.wrappingKeyFingerprint||'')) {
  throw Error('TEST health/project/runtime/wrapping identity unverified');
 }
 const envelope=wrapCredential(credential,health.wrappingPublicKey,health.wrappingKeyFingerprint);
 const encoded=Buffer.from(JSON.stringify(envelope),'utf8').toString('base64url');
 const digest=crypto.createHash('sha256').update(encoded).digest('hex');
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
 fs.writeFileSync('build/cloud-prerequisites/test-render-credential-envelope.json',JSON.stringify({
  status:'ENCRYPTED',projectId:PROJECT,serviceId:envelope.serviceId,
  wrappingKeyFingerprint:envelope.wrappingKeyFingerprint,
  ciphertextSha256:digest,providerCredentialHash:crypto.createHash('sha256').update(credential.client_email).digest('hex'),
  envelopeB64:encoded
 },null,2));
 console.log('TEST_FIREBASE_ENVELOPE_SHA256='+digest);
 // Ciphertext is AES-256-GCM protected with an RSA-OAEP-encrypted random key.
 // No plaintext service-account data, key or email appears in this output.
 console.log('TEST_FIREBASE_ENVELOPE_B64='+encoded);
 console.log('TEST_FIREBASE_ENVELOPE_PREPARED');
}
main().catch(e=>{console.error('TEST_FIREBASE_ENVELOPE_FAILED '+String(e.message).slice(0,160));process.exitCode=1});
