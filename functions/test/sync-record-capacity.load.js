'use strict';
// Actual reviewed Apps Script record/CAS/Sheet code in isolated VMs. NOT a
// provider throughput benchmark, real users/devices or a production write.
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {storage}=require('./helpers/managed-storage');
test('400 isolated school Script VMs commit/read 100000 synthetic student records without duplicate ACKs or cross-school rows', {timeout:900000},async()=>{
 const started=performance.now(),cpu=process.cpuUsage(),samples=[];
 let committed=0,readback=0,duplicates=0,peakRss=0;
 for(let index=1;index<=400;index++){
  const school='vs-'+index.toString(16).padStart(32,'0'),s=storage({lifecycle:true,schoolId:school});
  let original;
  for(let row=0;row<250;row++){
   const request={action:'managed_records',operation:'write',collection:'students_directory',id:'student-'+row,syncProtocol:2,
    operationId:'capacity-'+index.toString().padStart(4,'0')+'-'+row.toString().padStart(6,'0'),expectedRecordRevision:'',
    data:{schoolId:school,name:'Synthetic '+row,class:'Class '+(row%10+1),rollNo:String(Math.floor(row/10)+1),mobileStableId:'person-'+row}};
   const receipt=s.call(request);assert.equal(receipt.success,true,JSON.stringify({school:index,row,code:receipt.code}));
   assert.equal(typeof receipt.recordRevision,'string');assert(receipt.recordRevision);committed++;
   if(row===0)original={request,revision:receipt.recordRevision};
  }
  const duplicate=s.call(original.request);assert.equal(duplicate.success,true);assert.equal(duplicate.recordRevision,original.revision);duplicates++;
  const result=s.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2});
  assert.equal(result.success,true);assert.equal(result.schoolId,school);assert.equal(Object.keys(result.records).length,250);
  assert(Object.values(result.records).every(row=>row.schoolId===school&&typeof row._syncRevision==='string'&&row._syncRevision));
  readback+=Object.keys(result.records).length;
  // A caller cannot smuggle another school's record through an otherwise valid signature.
  const foreign=s.call({...original.request,operationId:'foreign-capacity-'+index,expectedRecordRevision:original.revision,
   data:{...original.request.data,schoolId:'vs-'+'f'.repeat(32)}});assert.equal(foreign.success,false);
  peakRss=Math.max(peakRss,process.memoryUsage().rss);
  if([4,20,60,300,400].includes(index)){
   const sample={schools:index,committed,verifiedReadback:readback,duplicateReceipts:duplicates,elapsedMillis:performance.now()-started,peakRssBytes:peakRss};samples.push(sample);console.log('SYNC3_RECORD_CAPACITY',JSON.stringify(sample));
  }
  await new Promise(resolve=>setImmediate(resolve));
 }
 assert.equal(committed,100000);assert.equal(readback,100000);assert.equal(duplicates,400);
 const report={scope:'synthetic isolated Apps Script VM/Sheet fixtures; no live provider calls; sequential schools, not peak concurrent traffic',schools:400,students:committed,verifiedReadback:readback,duplicatesPrevented:duplicates,peakRssBytes:peakRss,totalMillis:performance.now()-started,cpuUsageMicros:process.cpuUsage(cpu),samples};
 fs.mkdirSync('../build/sync3-capacity',{recursive:true});fs.writeFileSync('../build/sync3-capacity/records.json',JSON.stringify(report,null,2));
});
