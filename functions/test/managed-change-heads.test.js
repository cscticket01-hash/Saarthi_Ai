'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const {fixture,time}=require('./helpers/managed-school-broker');
const fs=require('node:fs');

test('measure unchanged-school full delta against metadata-only discovery in Script VM',()=>{
 const s=storage({lifecycle:true}),collections=['students_directory','school_config','fee_payments','school_notices'];
 const initial=s.call({action:'managed_delta',collections,knownRevisions:{}});
 assert.equal(initial.success,true);
 const knownRevisions=Object.fromEntries(Object.entries(initial.changes).map(([k,v])=>[k,v.collectionRevision]));
 const originalOpen=s.context.SpreadsheetApp.openById,originalFile=s.context.DriveApp.getFileById;
 let sheetOpens=0,fileReads=0;
 s.context.SpreadsheetApp.openById=(...a)=>{sheetOpens++;return originalOpen(...a);};
 s.context.DriveApp.getFileById=(...a)=>{fileReads++;return originalFile(...a);};
 function measure(headOnly){
  sheetOpens=0;fileReads=0;const times=[];let bytes=0;
  for(let i=0;i<20;i++){
   const start=performance.now(),out=s.call({action:'managed_delta',collections,knownRevisions,...(headOnly?{headOnly:true}:{})});
   times.push(performance.now()-start);assert.equal(out.success,true);bytes+=Buffer.byteLength(JSON.stringify(out));
  }
  times.sort((a,b)=>a-b);return {iterations:20,medianMillis:times[10],sheetOpens,fileReads,responseBytes:bytes};
 }
 const report={environment:'synthetic Apps Script VM; no live network',collections:collections.length,
  before:measure(false),after:measure(true)};
 assert.equal(report.after.sheetOpens,0);assert.equal(report.after.fileReads,0);
 assert(report.before.fileReads>0);
 fs.mkdirSync('../build/multi-pc',{recursive:true});
 fs.writeFileSync('../build/multi-pc/head-discovery-before-after.json',JSON.stringify(report,null,2));
 console.log('CHANGE_DISCOVERY_MEASUREMENTS',JSON.stringify(report));
});

test('signed change discovery opens no Sheets/Drive, mutates no properties and grants no record ACK',()=>{
 const s=storage({lifecycle:true});
 const saved=s.call({action:'managed_records',operation:'write',syncProtocol:2,
  collection:'fee_payments',id:'synthetic',operationId:'head-payment-operation-01',
  expectedRecordRevision:'',data:{schoolId:A,amount:500}});
 assert.equal(saved.success,true);
 const before=JSON.stringify([...s.props]);
 s.context.SpreadsheetApp.openById=()=>{throw Error('Discovery opened a Sheet');};
 s.context.DriveApp.getFileById=()=>{throw Error('Discovery opened Drive');};
 const out=s.call({action:'managed_delta',headOnly:true,collections:['fee_payments','students_directory'],knownRevisions:{}});
 assert.equal(out.success,true);assert.equal(out.headOnly,true);
 assert.equal(out.revisions.fee_payments,s.props.get('VS_RECORD_REV_fee_payments'));
 assert.equal(out.recordRevision,undefined);assert.equal(out.records,undefined);
 // Signed nonce anti-replay protection is allowed; data/checkpoint properties are unchanged.
 assert.equal(JSON.stringify([...s.props].filter(([k])=>!k.startsWith('VS_NONCE_'))),
  JSON.stringify(JSON.parse(before).filter(([k])=>!k.startsWith('VS_NONCE_'))));
});

test('head discovery uses bounded lock and rejects invalid/duplicate collections',()=>{
 const s=storage();let waited;
 s.context.LockService.getScriptLock=()=>({waitLock(ms){waited=ms;throw Error('Lock busy');},releaseLock(){}});
 assert.equal(s.call({action:'managed_delta',headOnly:true,collections:['fee_payments']}).success,false);
 assert.equal(waited,1000);
 for(const collections of [['fee_payments','fee_payments'],['mobile_sessions'],['foreign_school']])
  assert.equal(s.call({action:'managed_delta',headOnly:true,collections}).success,false);
});

test('broker authenticates head hints, validates shape and refuses old Script payloads',async()=>{
 const s=storage();class FixedDate extends Date{constructor(...args){super(...(args.length?args:[time]));}static now(){return time;}}s.context.Date=FixedDate;
 const b=fixture(async(_,opt)=>({ok:true,status:200,text:async()=>JSON.stringify(s.context.VS_managedHandle({postData:{contents:opt.body}}))}));
 const request={action:'managed/changes',headOnly:true,collections:['fee_payments'],knownRevisions:{}};
 const out=await b.call(request);assert.equal(out.headOnly,true);assert.equal(out.revisions.fee_payments,'legacy');
 await assert.rejects(b.call({...request,schoolId:A},'B'),e=>e.status===403);
 await assert.rejects(b.call({...request,headOnly:'true'}),e=>e.status===400);
 for(const result of [
  {headOnly:true,revisions:{}},
  {headOnly:true,revisions:{fee_payments:'r',foreign:'x'}},
  {headOnly:true,revisions:{fee_payments:123}},
  {changes:{fee_payments:{records:{},collectionRevision:'r',syncProtocol:2}}},
 ]){
  const bad=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,syncProtocol:2,...result})}));
  await assert.rejects(bad.call(request),e=>e.status===502);
 }
});
