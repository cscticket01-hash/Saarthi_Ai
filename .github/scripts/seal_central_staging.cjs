'use strict';
// Explicitly authorized transfer: existing GitHub FIREBASE_SERVICE_ACCOUNT
// to server-only SAARTHI_FIREBASE_ADMIN_JSON on saarthi-oauth-staging.
// Only authenticated AES ciphertext and a RSA-wrapped one-time key are exported.
const fs=require('node:fs'),crypto=require('node:crypto');
const PUBLIC_KEY='LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUFoRk05N2J5ZUlBMlhkaGwwODVqMgp1Rno4OXl6cWg2SllkdDFEcXRzcmF1QW9BbTgxZDRMREJyUkZiSnlDR2tSK0xBUnQwQ2I5czhhQng4RWdZYlhKCi8xZnRkbWJsWU5hT1oyQ1hHeXNCVEtzZVFYOEd6WmUvVUE5TTZGWlUvK3MzcjBCb0pQV09DaHd1MENHbjhDdVEKWTlZNHhkNWIveHcweGRLMExlTGEzcUpNa0VDeHlwNGNZdkJ4YmtJdCtOTklDcXAyMEI4RG55TUZZSFZ4S0g1OQpyM3FlZnpabTFDS3FhSG02VmFoUWVoZDdhTDlKYVhCVFZHcTNmYkpzNnI1U0xXVVFWT3FDKy8veUZYc3pYM25JCml5WTRvVCtUR2Nwb3V3NG9Xb0pkSHI5L0dtQ2hzQWFiNnlSTDUwKzJEdEFTTEFOWkw1U3A4TzRsUkw1dVFIdDIKZFhNVGUxcFl4M3AyUlRIT1J5ckxYQkVnanMxRlBWdWliSVNNMFFlcjhUL043aW9kWW1CbXdwQWYzaGxxSjFkQgozSHpMNm5ESFZMNnlsc2NsQTZrTmlSZ3NlOG10czZyV2VwYnBadHNKaTlCdlFySU1xV0FPZy9ZUVJWVzJIa3RNCkVYcFNIL1owQkgwR1ZkNDNQUXRkL3drRmxESUtrYWhlWEI4bjhBdjRwcDZSTzZndTZkTTBCaUpqaW43MkRITGMKWmMzQ2p3RjBUbS9SRFF6dU54cDNIK1VNdmZzZ0I3UjBCc21HZ3U2T05vYVZNSnhWWEM0NzBpUCsvbkdWK2lkWgpVZ2liR0lpaVRtdy9UL1dtRnpCd0FVczdpaUwxK000VTFlVmoxeHRsaGFBVGlKOEsvd2pKZU5KWHE1TmdtUS9NClp4aXBwRlhuSTZJUHJINGcreUNuQjZrQ0F3RUFBUT09Ci0tLS0tRU5EIFBVQkxJQyBLRVktLS0tLQo=';
const credential=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT || '{}');
if(credential.project_id!=='saarthi-ai-df12b' || !credential.private_key || !credential.client_email)throw Error('Wrong or missing existing central credential');
if(!/^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/.test(process.env.GOOGLE_CLIENT_ID || ''))throw Error('Missing configured OAuth audience');
const data=Buffer.from(JSON.stringify({projectId:'saarthi-ai-df12b',firebaseAdmin:credential,clientId:process.env.GOOGLE_CLIENT_ID,nonce:'approved-central-staging-20261003-v2'}));
const aes=crypto.randomBytes(32),iv=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',aes,iv);
const ciphertext=Buffer.concat([cipher.update(data),cipher.final()]);
const wrapped=crypto.publicEncrypt({key:Buffer.from(PUBLIC_KEY,'base64'),oaepHash:'sha256',padding:crypto.constants.RSA_PKCS1_OAEP_PADDING},aes);
fs.mkdirSync('staging-transfer',{recursive:true});
fs.writeFileSync('staging-transfer/sealed.json',JSON.stringify({wrappedKey:wrapped.toString('base64'),iv:iv.toString('base64'),tag:cipher.getAuthTag().toString('base64'),ciphertext:ciphertext.toString('base64')}));
data.fill(0);aes.fill(0);
console.log('Approved central credential sealed for existing Render staging; no plaintext credential was logged or uploaded');
