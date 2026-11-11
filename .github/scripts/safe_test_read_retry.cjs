'use strict';
// Only repeat explicit read operations. Never replay an uncertain mutation.
module.exports = async function safeRead(post, url, body, token, report, options = {}) {
  const read = body.action === 'managed/records' && body.operation === 'read';
  const wait = options.wait || (ms => new Promise(resolve => setTimeout(resolve, ms)));
  const random = options.random || Math.random;
  let elapsedMs = 0;
  for (let attempt = 0; ; attempt++) {
    const result = await post(url, body, token);
    elapsedMs += result.elapsedMs || 0;
    if (!read || ![429, 502, 503, 504].includes(result.http) || attempt === 2) {
      return {...result, elapsedMs};
    }
    report.readRetries ||= [];
    report.readRetries.push({attempt: attempt + 1, http: result.http,
      reference: result.data?.requestId || null});
    const delay = Math.round((result.http === 429 ? 15000 : 5000) * 2 ** attempt * (0.8 + random() * 0.4));
    await wait(delay);
    elapsedMs += delay;
  }
};

// Shared signed TEST response check. Only the explicit record-read operation
// above can be retried; uncertain writes and deletes are submitted once.
module.exports.schoolCall=async function({post,url,schoolId,token,report,label='TEST request',retryOptions},body){
 const assert=require('node:assert/strict');
 assert.match(schoolId,/^vs-[a-f0-9]{32}$/);
 const adapted=async(...args)=>{const r=await post(...args);return {...r,http:r.http??r.status};};
 const r=await module.exports(adapted,url,{...body,schoolId},token,report,retryOptions);
 if(r.http!==200||r.data?.success!==true||r.data.schoolId!==schoolId){
  const code=/^[A-Z_]{2,90}$/.test(r.data?.code||'')?r.data.code:'SCHOOL_SCOPE_UNVERIFIED';
  throw Object.assign(Error(label+' HTTP '+r.http+' '+code),{http:r.http,status:r.http,code,category:code});
 }
 return r.data;
};
