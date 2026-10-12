'use strict';
// Observe one existing response only. Never replay a request or substitute UI
// status for a verified response body. JSON decoding awaits the complete body.
async function responseJson(response,timeoutMs=60000) {
 if(!Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>60000)throw Error('Invalid response evidence deadline');
 let timer;
 try {
  return await Promise.race([response.json(),new Promise((_,reject)=>{
   timer=setTimeout(()=>reject(Error('TEST response body verification timed out')),timeoutMs);
  })]);
 } finally {clearTimeout(timer);}
}
module.exports={responseJson};
