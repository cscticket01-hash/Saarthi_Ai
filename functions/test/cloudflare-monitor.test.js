'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createCloudflareMonitor}=require('../cloudflare-monitor');
const ID='a'.repeat(32),DB='b'.repeat(32);
test('Cloudflare analytics requires dedicated read-only credentials and does not estimate missing values',async()=>{
 const fetchImpl=()=>{throw Error('Should not make network calls')};
 const unavailable=await createCloudflareMonitor({fetchImpl})();
 assert.equal(unavailable.available,false);
 assert.equal(unavailable.requests,undefined);
});
test('only scoped Worker invocations and D1 query counts become verified samples',async()=>{
 const seen=[];
 const fetchImpl=async(url,options)=>{
  assert.equal(url,'https://api.cloudflare.com/client/v4/graphql');
  assert.equal(options.headers.Authorization,'Bearer read-only-token-example');
  const q=JSON.parse(options.body);seen.push(q);
  if(q.query.includes('d1AnalyticsAdaptiveGroups'))
   return {ok:true,json:async()=>({data:{viewer:{accounts:[{d1AnalyticsAdaptiveGroups:[
      {sum:{readQueries:15,writeQueries:4}},
    ]}]}}})};
  return {ok:true,json:async()=>({data:{viewer:{accounts:[{workersInvocationsAdaptive:[
    {sum:{requests:80,errors:2}},
  ]}]}}})};
 };
 const monitor=createCloudflareMonitor({accountId:ID,analyticsToken:'read-only-token-example',
  workerName:'saarthi-school-edge',databaseId:DB,fetchImpl,now:()=>1800000000000});
 const result=await monitor();
 assert.equal(result.requests,80);assert.equal(result.errors,2);
 assert.equal(result.d1.readQueries,15);assert.equal(result.d1.writeQueries,4);
 assert.equal(seen.length,2);
 assert.equal(seen[0].variables.scriptName,'saarthi-school-edge');
 assert.equal(seen[1].variables.databaseId,DB);
 await monitor();
 assert.equal(seen.length,2,'Provider queries cached for at least 60 seconds');
});
test('analytics authorization failure remains unavailable, not zero traffic',async()=>{
 const monitor=createCloudflareMonitor({accountId:ID,workerName:'saarthi',
  analyticsToken:'read-only-token-example',
  fetchImpl:async()=>({ok:false,status:403}),now:()=>1800000000000});
 const r=await monitor();assert.equal(r.available,false);assert.equal(r.requests,undefined);
 assert.match(r.reason,/403/);
});
test('malformed Worker counters are unavailable rather than fabricated zero',async()=>{
 const monitor=createCloudflareMonitor({accountId:ID,workerName:'saarthi',analyticsToken:'read-only-token-example',
  fetchImpl:async()=>({ok:true,json:async()=>({data:{viewer:{accounts:[{workersInvocationsAdaptive:[{sum:{requests:5}}]}]}}})})});
 const r=await monitor();assert.equal(r.available,false);assert.equal(r.requests,undefined);
});
test('optional D1 failure retains valid Worker telemetry',async()=>{
 const monitor=createCloudflareMonitor({accountId:ID,workerName:'saarthi',databaseId:DB,analyticsToken:'read-only-token-example',
  fetchImpl:async(url,options)=>{
   if(JSON.parse(options.body).query.includes('d1Analytics'))throw Error('private transport detail');
   return {ok:true,json:async()=>({data:{viewer:{accounts:[{workersInvocationsAdaptive:[{sum:{requests:5,errors:0}}]}]}}})};
  }});
 const r=await monitor();assert.equal(r.available,true);assert.equal(r.requests,5);assert.equal(r.d1.available,false);
 assert(!JSON.stringify(r).includes('private transport'));
});
