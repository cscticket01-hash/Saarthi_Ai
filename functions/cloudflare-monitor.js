'use strict';
// Read-only Cloudflare account telemetry. Dedicated Analytics Read token; never
// reuse the data-sync secret or expose credentials to the developer browser.
// These are provider samples, not instantaneous rates or Drive acknowledgements.
function createCloudflareMonitor({
  accountId, analyticsToken, workerName, databaseId,
  fetchImpl=fetch, now=Date.now,
}={}) {
  let previous=null, inflight=null;
  const enabled=/^[a-f0-9]{32}$/.test(accountId||'') &&
    typeof analyticsToken==='string' && analyticsToken.length>15 &&
    /^[A-Za-z0-9_-]{1,120}$/.test(workerName||'');
  async function read() {
    if(!enabled)return {available:false,reason:'Cloudflare Analytics Read token, account ID or Worker name not configured'};
    const end=new Date(now()),start=new Date(end.getTime()-5*60000);
    const query=`query WorkerUsage($accountTag: string!, $scriptName: string!, $start: Time!, $end: Time!) {
      viewer { accounts(filter:{accountTag:$accountTag}) {
        workersInvocationsAdaptive(limit:1,filter:{scriptName:$scriptName,datetime_geq:$start,datetime_leq:$end}) {
          sum { requests errors }
        }
      }}
    }`;
    const req=async(query,variables)=>{
      const response=await fetchImpl('https://api.cloudflare.com/client/v4/graphql',{
        method:'POST',
        headers:{Authorization:'Bearer '+analyticsToken,'Content-Type':'application/json'},
        body:JSON.stringify({query,variables}),
        signal:AbortSignal.timeout(12000),
      });
      if(!response.ok)return {available:false,reason:'Cloudflare Analytics read HTTP '+response.status};
      const result=await response.json();
      if(result.errors?.length||!Array.isArray(result.data?.viewer?.accounts))
        return {available:false,reason:'Cloudflare Analytics query unavailable'};
      return {available:true,accounts:result.data.viewer.accounts};
    };
    const w=await req(query,{accountTag:accountId,scriptName:workerName,
      start:start.toISOString(),end:end.toISOString()});
    if(!w.available)return w;
    const account=w.accounts[0];
    if(!account||!Array.isArray(account.workersInvocationsAdaptive))
      return {available:false,reason:'Cloudflare Worker measurements not reported'};
    const groups=account.workersInvocationsAdaptive;
    const count=(field)=>groups.reduce((n,row)=>n+(Number.isSafeInteger(row?.sum?.[field])&&row.sum[field]>=0?row.sum[field]:0),0);
    const result={available:true,window:'Last 5 minutes (provider sampled)',sampledAt:end.getTime(),
      workerName,requests:count('requests'),errors:count('errors'),d1:{available:false,reason:'D1 database ID not configured'}};
    if(typeof databaseId==='string'&&/^[a-f0-9-]{32,40}$/.test(databaseId)) {
      const day=new Date(end.getTime()-86400000).toISOString().slice(0,10);
      const d1Query=`query D1Usage($accountTag: string!, $start: Date!, $end: Date!, $databaseId: string!) {
        viewer { accounts(filter:{accountTag:$accountTag}) {
          d1AnalyticsAdaptiveGroups(limit:10000,filter:{date_geq:$start,date_leq:$end,databaseId:$databaseId}) {
            sum { readQueries writeQueries }
          }
        }}
      }`;
      const response=await req(d1Query,{accountTag:accountId,start:day,
        end:end.toISOString().slice(0,10),databaseId});
      if(response.available){
        const rows=response.accounts[0]?.d1AnalyticsAdaptiveGroups;
        if(Array.isArray(rows)){
          const total=key=>rows.reduce((n,v)=>n+
            (Number.isSafeInteger(v?.sum?.[key])&&v.sum[key]>=0?v.sum[key]:0),0);
          result.d1={available:true,readQueries:total('readQueries'),
            writeQueries:total('writeQueries'),window:'Current and previous UTC day'};
        }else result.d1={available:false,reason:'D1 analytics dataset not reported'};
      }else result.d1={available:false,reason:response.reason};
    }
    return result;
  }
  return async()=>{
    if(previous&&now()-previous.at<60000)return previous.value;
    if(!inflight)inflight=read().catch(()=>({available:false,reason:'Cloudflare Analytics unavailable'}))
      .then(value=>{previous={at:now(),value};return value;})
      .finally(()=>{inflight=null;});
    return inflight;
  };
}
module.exports={createCloudflareMonitor};
