'use strict';
// Read-only. No API activation, IAM mutation, billing or fallback estimates.
function createMonitor({credential,projectId,fetchImpl=fetch,now=Date.now}){
 let cached,inflight;async function read(){
  if(cached&&now()-cached.at<60000)return {...cached.value,cached:true};
  try{
   const token=(await credential.getAccessToken()).access_token;
   const base='https://monitoring.googleapis.com/v3/projects/'+encodeURIComponent(projectId);
   let quotas={available:false,reason:'Project quota read access unavailable'};
   const project=await fetchImpl('https://cloudresourcemanager.googleapis.com/v1/projects/'+encodeURIComponent(projectId),{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(10000)});
   if(project.ok){const number=(await project.json()).projectNumber;if(/^\d+$/.test(String(number))){const q=await fetchImpl('https://serviceusage.googleapis.com/v1beta1/projects/'+number+'/services/firestore.googleapis.com/consumerQuotaMetrics?view=FULL&pageSize=100',{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(10000)});if(q.ok){const data=await q.json();quotas={available:true,metrics:data.metrics||[],partial:!!data.nextPageToken};}else quotas={available:false,reason:'Project quotas unavailable (HTTP '+q.status+')'};}}
   const descriptors=await fetchImpl(base+'/metricDescriptors?filter='+encodeURIComponent('metric.type = starts_with("firestore.googleapis.com/")')+'&pageSize=100',{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(15000)});
   if(!descriptors.ok)return {available:false,quotas,reason:'Cloud Monitoring read access unavailable (HTTP '+descriptors.status+')'};
   const descriptorData=await descriptors.json();
   const all=descriptorData.metricDescriptors||[];
   const chosen=all.filter(d=>/document\/(read|write|delete|count)|storage|total_size|network\/(sent|received)_bytes|request.*latenc/.test(d.type)).slice(0,20);
   const metrics=[];for(const d of chosen){const u=new URL(base+'/timeSeries');u.searchParams.set('filter','metric.type="'+d.type+'"');u.searchParams.set('interval.startTime',new Date(now()-86400000).toISOString());u.searchParams.set('interval.endTime',new Date(now()).toISOString());u.searchParams.set('pageSize','100');const r=await fetchImpl(u.href,{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(10000)});const data=r.ok?await r.json():null;metrics.push({type:d.type,unit:d.unit,kind:d.metricKind,description:d.description,available:r.ok,status:r.status,...(r.ok?{series:data.timeSeries||[],partial:!!data.nextPageToken}:{reason:'Metric access unavailable (HTTP '+r.status+')'})});}
   const value={available:true,cards:summarize(metrics),metrics,quotas,window:'last 24 hours',sampledAt:now(),partial:!!descriptorData.nextPageToken};cached={at:now(),value};return value;
  }catch{return {available:false,reason:'Monitoring unavailable; usage and capacity are not estimated'};}
 }
 return async()=>{
  if(cached&&now()-cached.at<60000)return {...cached.value,cached:true};
  if(!inflight)inflight=read().then(value=>{cached={at:now(),value};return value;}).finally(()=>{inflight=null;});
  return inflight;
 };
}
module.exports={createMonitor,summarize};

// Exact observed samples only. DELTA traffic is bits/sec over the sample interval,
// not a claim about internet connection capacity or disk bandwidth.
function summarize(metrics){
 const cards={};
 function metric(pattern){return metrics.filter(m=>m.available&&!m.partial&&pattern.test(m.type)).sort((a,b)=>Number(b.type.includes('_ops_count'))-Number(a.type.includes('_ops_count')))[0];}
 function sample(m,mode){if(!m)return null;let total=0,count=0,at=0;for(const s of m.series||[]){const p=s.points?.[0];if(!p)continue;const value=p.value||{};let v=Number(value.int64Value??value.doubleValue);if(value.distributionValue){const d=value.distributionValue;v=Number(d.mean);if(!Number(d.count))continue;}if(!Number.isFinite(v))continue;const end=Date.parse(p.interval?.endTime),start=Date.parse(p.interval?.startTime);if(mode==='rate'){if(m.kind==='CUMULATIVE'){const previous=s.points?.[1];const old=Number(previous?.value?.int64Value??previous?.value?.doubleValue);const oldEnd=Date.parse(previous?.interval?.endTime);const sameStart=previous?.interval?.startTime===p.interval?.startTime;if(!sameStart||!Number.isFinite(old)||!Number.isFinite(oldEnd)||end<=oldEnd||v<old)continue;v=(v-old)/((end-oldEnd)/1000);}else{if(!Number.isFinite(end)||!Number.isFinite(start)||end<=start)continue;v/=((end-start)/1000);}}if(mode==='mean'&&value.distributionValue){const weight=Number(value.distributionValue.count);total+=v*weight;count+=weight;}else{total+=v;count++;}if(Number.isFinite(end))at=Math.max(at,end);}return count?{value:mode==='mean'?total/count:total,unit:m.unit,type:m.type,sampledAt:at||null}:null;}
 cards.storageBytes=sample(metric(/storage.*(bytes|size)|total_size/),'sum');
 cards.readsPerSecond=sample(metric(/document\/read(_ops)?_count$/),'rate');
 cards.writesPerSecond=sample(metric(/document\/write(_ops)?_count$/),'rate');
 for(const [key,pattern]of [['outboundBitsPerSecond',/network\/sent_bytes_count$/],['inboundBitsPerSecond',/network\/received_bytes_count$/]]){const p=sample(metric(pattern),'rate');cards[key]=p?{...p,value:p.value*8,unit:'bit/s'}:null;}
 cards.latency=sample(metric(/request.*latenc/),'mean');return cards;
}
