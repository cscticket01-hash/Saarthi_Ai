'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createMonitor}=require('../managed-monitor');
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
