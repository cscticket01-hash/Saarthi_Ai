'use strict';
// Read-only. No API activation, IAM mutation, billing or fallback estimates.
function createMonitor({credential,projectId,fetchImpl=fetch,now=Date.now}){
 let cached;return async()=>{
  if(cached&&now()-cached.at<300000)return {...cached.value,cached:true};
  try{
   const token=(await credential.getAccessToken()).access_token;
   const base='https://monitoring.googleapis.com/v3/projects/'+encodeURIComponent(projectId);
   let quotas={available:false,reason:'Project quota read access unavailable'};
   const project=await fetchImpl('https://cloudresourcemanager.googleapis.com/v1/projects/'+encodeURIComponent(projectId),{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(10000)});
   if(project.ok){const number=(await project.json()).projectNumber;if(/^\d+$/.test(String(number))){const q=await fetchImpl('https://serviceusage.googleapis.com/v1beta1/projects/'+number+'/services/firestore.googleapis.com/consumerQuotaMetrics?view=FULL&pageSize=100',{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(10000)});if(q.ok){const data=await q.json();quotas={available:true,metrics:data.metrics||[],partial:!!data.nextPageToken};}else quotas={available:false,reason:'Project quotas unavailable (HTTP '+q.status+')'};}}
   const descriptors=await fetchImpl(base+'/metricDescriptors?filter='+encodeURIComponent('metric.type = starts_with("firestore.googleapis.com/")')+'&pageSize=100',{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(15000)});
   if(!descriptors.ok)return {available:false,quotas,reason:'Cloud Monitoring read access unavailable (HTTP '+descriptors.status+')'};
   const all=(await descriptors.json()).metricDescriptors||[];
   const chosen=all.filter(d=>/document\/(read|write|delete|count)|storage|total_size|request.*latency/.test(d.type)).slice(0,12);
   const metrics=[];for(const d of chosen){const u=new URL(base+'/timeSeries');u.searchParams.set('filter','metric.type="'+d.type+'"');u.searchParams.set('interval.startTime',new Date(now()-86400000).toISOString());u.searchParams.set('interval.endTime',new Date(now()).toISOString());u.searchParams.set('pageSize','100');const r=await fetchImpl(u.href,{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(10000)});metrics.push({type:d.type,unit:d.unit,kind:d.metricKind,description:d.description,available:r.ok,...(r.ok?{series:(await r.json()).timeSeries||[]}:{reason:'Metric access unavailable'})});}
   const value={available:true,metrics,quotas,window:'last 24 hours',sampledAt:now(),partial:!!(all.length===100)};cached={at:now(),value};return value;
  }catch{return {available:false,reason:'Monitoring unavailable; usage and capacity are not estimated'};}
 };
}
module.exports={createMonitor};
