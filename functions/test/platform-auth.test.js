'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {configureAnonymous}=require('../../.github/scripts/configure_platform_auth.cjs');
const reply=(status,data)=>({ok:status>=200&&status<300,status,json:async()=>data});
const disabled=()=>reply(400,{error:{message:'OPERATION_NOT_ALLOWED'}});
const signedIn=()=>reply(200,{idToken:'temporary-trial-token'});
const quiet=()=>{};
test('already enabled Anonymous Auth needs no deployment IAM config access',async()=>{
 const calls=[];
 await configureAnonymous({log:quiet,credential:()=>{throw Error('Must not request deployment credentials');},
  request:async(url,options)=>{calls.push({url,options});return url.includes('accounts:signUp')?signedIn():reply(200,{});}});
 assert.equal(calls.length,2);assert.equal(calls[1].url.includes('accounts:delete'),true);
});
test('disabled Anonymous Auth changes only that provider and verifies cleanup',async()=>{
 const calls=[];let signup=0;
 await configureAnonymous({log:quiet,credential:()=>({getAccessToken:async()=>({access_token:'deployment-token'})}),
  request:async(url,options)=>{calls.push({url,options});return url.includes('accounts:signUp')?(signup++?signedIn():disabled()):reply(200,{});}});
 const patch=calls.find(c=>c.options.method==='PATCH');
 assert.equal(patch.url.endsWith('?updateMask=signIn.anonymous.enabled'),true);
 assert.deepEqual(JSON.parse(patch.options.body),{name:'projects/saarthi-ai-df12b/config',signIn:{anonymous:{enabled:true}}});
 assert.equal(calls.some(c=>c.options.method==='GET'),false);assert.equal(calls.at(-1).url.includes('accounts:delete'),true);
});
test('missing Firebase Auth IAM permission returns the exact manual remedy',async()=>{
 await assert.rejects(configureAnonymous({log:quiet,credential:()=>({getAccessToken:async()=>({access_token:'deployment-token'})}),
  request:async(url)=>url.includes('accounts:signUp')?disabled():reply(403,{})}),/enable Anonymous|Enable Anonymous.*Firebase Authentication Admin.*HTTP 403/);
});
test('an API key or quota failure is not mistaken for a disabled provider',async()=>{
 await assert.rejects(configureAnonymous({log:quiet,credential:()=>{throw Error('Must not patch project config');},
  request:async()=>reply(403,{error:{message:'API_KEY_HTTP_REFERRER_BLOCKED'}})}),/verification failed \(HTTP 403\)/);
});
test('a temporary Auth verification identity must be removed',async()=>{
 await assert.rejects(configureAnonymous({log:quiet,request:async(url)=>url.includes('accounts:signUp')?signedIn():reply(403,{})}),/remove the temporary/);
});
