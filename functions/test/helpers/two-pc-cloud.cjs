'use strict';
// Synthetic process-local cloud only. Uses the actual signed Apps Script router;
// no network, credentials or real school access. Dart owns the two SQLite PCs.
const readline=require('node:readline');
const {storage}=require('./managed-storage');
// Virtual server time ages nonce leases under large synthetic workloads.
const RealDate=Date;let serverTime=RealDate.now();
global.Date=class extends RealDate {constructor(...a){super(...(a.length?a:[serverTime]));}static now(){return serverTime;}};
const cloud=storage({lifecycle:true});
readline.createInterface({input:process.stdin}).on('line',line=>{
 try {
  serverTime+=500;
  const request=JSON.parse(line);
  process.stdout.write(JSON.stringify(cloud.call(request))+'\n');
 } catch(error) {
  process.stdout.write(JSON.stringify({success:false,message:error.message})+'\n');
 }
});
