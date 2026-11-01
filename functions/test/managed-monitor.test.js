'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createMonitor}=require('../managed-monitor');
test('concurrent refreshes share a read and permission failures are cached for one sampling interval',async()=>{
 let calls=0,time=0;
 const monitor=createMonitor({projectId:'own',now:()=>time,credential:{getAccessToken:async()=>({access_token:'private'})},fetchImpl:async()=>{calls++;return {ok:false,status:403};}});
 const [a,b]=await Promise.all([monitor(),monitor()]);
 assert.equal(a.available,false);assert.equal(b.available,false);assert.equal(calls,2);
 await monitor();assert.equal(calls,2);
 time=60001;await monitor();assert.equal(calls,4);
});
test('cumulative counters use adjacent observations, not lifetime averages',()=>{
 const {summarize}=require('../managed-monitor');
 const point=(value,end,start='2026-10-01T00:00:00Z')=>({value:{int64Value:String(value)},interval:{startTime:start,endTime:end}});
 const m={available:true,type:'firestore.googleapis.com/document/read_count',kind:'CUMULATIVE',unit:'1',series:[{points:[point(1120,'2026-10-06T00:01:00Z'),point(1000,'2026-10-06T00:00:00Z')]}]};
 assert.equal(summarize([m]).readsPerSecond.value,2);
 assert.equal(summarize([{...m,series:[{points:[m.series[0].points[0]]}]}]).readsPerSecond,null);
 assert.equal(summarize([{...m,partial:true}]).readsPerSecond,null);
 m.series[0].points[0]=point(20,'2026-10-06T00:01:00Z','2026-10-06T00:00:30Z');
 assert.equal(summarize([m]).readsPerSecond,null);
});
test('zero is a real sample and incomplete paginated metrics are disclosed',async()=>{
 const monitor=createMonitor({projectId:'project',credential:{getAccessToken:async()=>({access_token:'private'})},fetchImpl:async url=>({ok:true,status:200,json:async()=>url.includes('cloudresourcemanager')?{}:url.includes('metricDescriptors')?{metricDescriptors:[{type:'firestore.googleapis.com/storage/total_size',unit:'By',metricKind:'GAUGE'}],nextPageToken:'more'}:{timeSeries:[{points:[{value:{int64Value:'0'}}]}],nextPageToken:'more-series'}})});
 const result=await monitor();assert.equal(result.partial,true);assert.equal(result.metrics[0].partial,true);assert.equal(result.cards.storageBytes,null);
 const {summarize}=require('../managed-monitor');assert.equal(summarize([{available:true,type:'firestore.googleapis.com/storage/total_size',unit:'By',series:[{points:[{value:{int64Value:'0'}}]}]}]).storageBytes.value,0);
});
test('monitor only performs reads, reports missing permission and never enables APIs',async()=>{const calls=[];const monitor=createMonitor({projectId:'project',credential:{getAccessToken:async()=>({access_token:'private'})},fetchImpl:async(url,options)=>{calls.push({url,options});return {ok:false,status:403}}});const r=await monitor();assert.equal(r.available,false);assert.match(r.reason,/403/);assert(calls.every(c=>!c.options.method||c.options.method==='GET'));assert(!JSON.stringify(r).includes('private'));assert(!calls.some(c=>/enable|setIamPolicy|billing/.test(c.url)));});
test('monitor preserves actual metric units and quota values; caches read-only results',async()=>{let count=0;const monitor=createMonitor({projectId:'project',credential:{getAccessToken:async()=>({access_token:'private'})},fetchImpl:async url=>{count++;return {ok:true,json:async()=>url.includes('cloudresourcemanager')?{projectNumber:'123'}:url.includes('consumerQuota')?{metrics:[{metric:'storage',consumerQuotaLimits:[{quotaBuckets:[{effectiveLimit:'123456'}]}]}]}:url.includes('metricDescriptors')?{metricDescriptors:[{type:'firestore.googleapis.com/document/read_count',unit:'1',metricKind:'DELTA'}]}:{timeSeries:[{points:[{value:{int64Value:'99'}}]}]}}}});const r=await monitor();assert.equal(r.metrics[0].unit,'1');assert.equal(r.metrics[0].series[0].points[0].value.int64Value,'99');assert.equal(r.quotas.metrics[0].consumerQuotaLimits[0].quotaBuckets[0].effectiveLimit,'123456');const reads=count;assert((await monitor()).cached);assert.equal(count,reads);});

test('monitor converts real interval bytes to bits/second, distinguishes ops/sec and leaves missing samples unavailable',()=>{
 const {summarize}=require('../managed-monitor');const interval={startTime:'2026-10-04T00:00:00Z',endTime:'2026-10-04T00:01:00Z'};
 const m=(type,value,unit='1')=>({available:true,type:'firestore.googleapis.com/'+type,unit,series:[{points:[{interval,value:{int64Value:String(value)}}]}]});
 const c=summarize([m('network/sent_bytes_count',15000,'By'),m('document/read_ops_count',120),m('document/write_ops_count',60)]);
 assert.equal(c.outboundBitsPerSecond.value,2000);assert.equal(c.readsPerSecond.value,2);assert.equal(c.writesPerSecond.value,1);assert.equal(c.storageBytes,null);assert.equal(c.inboundBitsPerSecond,null);
 const missing=summarize([{available:true,type:'firestore.googleapis.com/document/read_count',unit:'1',series:[{points:[{value:{int64Value:'10'}}]}]}]);assert.equal(missing.readsPerSecond,null);
});
test('quota service outage does not hide measured Firestore storage',async()=>{
 const monitor=createMonitor({projectId:'project',credential:{getAccessToken:async()=>({access_token:'private'})},fetchImpl:async url=>{
  if(url.includes('cloudresourcemanager'))throw Error('quota outage');
  return {ok:true,json:async()=>url.includes('metricDescriptors')?{metricDescriptors:[{type:'firestore.googleapis.com/storage/total_size',unit:'By',metricKind:'GAUGE'}]}:{timeSeries:[{points:[{value:{int64Value:'123'}}]}]}};
 }});
 const r=await monitor();assert.equal(r.available,true);assert.equal(r.quotas.available,false);assert.equal(r.cards.storageBytes.value,123);
});
test('metric reads run with bounded concurrency and retain other metrics after a timeout',async()=>{
 let active=0,peak=0;
 const monitor=createMonitor({projectId:'project',credential:{getAccessToken:async()=>({access_token:'private'})},fetchImpl:async url=>{
  if(url.includes('cloudresourcemanager'))return {ok:false,status:403};
  if(url.includes('metricDescriptors'))return {ok:true,json:async()=>({metricDescriptors:Array.from({length:7},(_,i)=>({type:'firestore.googleapis.com/storage/size'+i,unit:'By'}))})};
  active++;peak=Math.max(peak,active);await new Promise(resolve=>setImmediate(resolve));active--;
  if(decodeURIComponent(url).includes('size0'))throw Error('private timeout');
  return {ok:true,status:200,json:async()=>({timeSeries:[{points:[{value:{int64Value:'123'}}]}]})};
 }});
 const r=await monitor();assert.equal(r.available,true);assert.equal(peak,4);assert.equal(r.metrics.length,7);
 assert.equal(r.metrics[0].available,false);assert.equal(r.metrics.filter(m=>m.available).length,6);
 assert(!JSON.stringify(r).includes('private timeout'));
});
