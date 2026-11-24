import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const require=createRequire(import.meta.url);
const {createLiveSync}=require('../../functions/live-sync');
const {createCloudflareSync}=require('../../functions/cloudflare-sync');
const {storage}=require('../../functions/test/helpers/managed-storage');
const school='vs-'+'a'.repeat(32),key='payroll-delivery-synthetic-test-secret-0001';

test('seeded payroll pair: verified Drive baseline, lost ACK, grouped peer replay and both signed Script readbacks',async()=>{
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{
  name:'payroll-recovery-delivery',modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,LIVE_SYNC_TEST_SCHOOL_ID:school,BROKER_URL:'https://broker.invalid/school-cloud'}
 }]}));
 try{
  const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
  const live=createLiveSync({edge,schools:[school]});
  const gs=storage({lifecycle:true,bundle:true});
  const deliver=body=>gs.call(body);
  const health=deliver({action:'managed_health'});
  assert.equal(health.payrollLedgerVersion,2);assert.equal(health.payrollLeaveVersion,1);assert.equal(health.payrollRecoveryBackupVersion,1);
  const teacherId='payroll-delivery-teacher',staffId='teacher:'+teacherId,
   salaryId='payroll-delivery-salary',advanceId='payroll_advance_'+createHash('sha256').update(staffId).digest('hex');
  const generation='p-'+'4'.repeat(64);
  const write=(collection,id,data,op)=>gs.call({action:'managed_records',operation:'write',syncProtocol:2,collection,id,
   operationId:op,expectedRecordRevision:'',data:{schoolId:school,id,...data}});
  const parent=write('teachers_directory',teacherId,{name:'Synthetic payroll teacher',teacherId,mobileStableId:generation},'payroll-delivery-teacher-init');
  assert.equal(parent.success,true,JSON.stringify(parent));
  const salary=write('teacher_salary',salaryId,{staffId,teacherId,employeeId:teacherId,personId:generation,month:'2026-11',
   basicPaise:2000000,allowancePaise:0,bonusPaise:0,overtimePaise:0,deductionPaise:0,
   netPaise:2000000,paidPaise:0,balancePaise:2000000,amount:20000,status:'Pending'},'payroll-delivery-salary-init');
  assert.equal(salary.success,true,JSON.stringify(salary));
  const advance=write('school_settings',advanceId,{staffId,balancePaise:400000,events:[
   {id:'original-loan',type:'loan',amountPaise:400000,reference:'Synthetic loan',recordedAt:1795500000000}
  ]},'payroll-delivery-advance-init');
  assert.equal(advance.success,true,JSON.stringify(advance));
  for(const collection of ['teachers_directory','teacher_salary','school_settings'])
   assert.equal((await live.prepare(school,collection,deliver)).state,'active');
  assert.equal((await live.command(school,{command:'read',collection:'teacher_salary',id:salaryId})).source,'drive');
  const request={command:'payrollRecoveryPreview',bundleId:'payroll-delivery-bundle-0001',eventId:'payroll-delivery-event-0001',
   salaryId,advanceId,salaryOperationId:'payroll-delivery-salary-operation',advanceOperationId:'payroll-delivery-advance-operation',
   amountPaise:100000,reference:'Approved synthetic deduction'};
  const preview=await live.payrollRecovery(school,request,deliver);
  assert.equal(preview.preview,true);
  assert.equal(preview.operations[0].data.netPaise,1900000);
  assert.equal(preview.operations[1].data.balancePaise,300000);
  const head=(await live.command(school,{command:'head'})).cursor;
  const wire={bundleId:request.bundleId,operations:preview.operations};
  assert.equal((await live.command(school,{command:'bundleReceipt',...wire})).found,false);
  const commit={command:'bundleCommit',...wire};
  for(const op of wire.operations){
   const direct=deliver({action:'managed_records',collection:op.collection,id:op.id,operation:'write',syncProtocol:2,
    operationId:op.operationId+'-direct',expectedRecordRevision:op.expectedRevision,data:op.data});
   assert.equal(direct.success,false,'Independent signed write must not invent linked recovery');
  }
  // A wrong readback must fail before publishing either half.
  await assert.rejects(live.payrollRecovery(school,commit,body=>{
   const result=deliver(body);
   if(body.id===advanceId&&body.operation==='read')result.records[advanceId].balancePaise++;
   return result;
  }));
  assert.equal((await live.command(school,{command:'head'})).cursor,head);
  const accepted=await live.payrollRecovery(school,commit,deliver);
  assert.equal(accepted.cloudState,'committed');assert.equal(accepted.backupState,'pending');
  // Original HTTP ACK can be lost. Replay exact immutable wire after the
  // authority has changed; it must not read or deduct against new balances.
  const replay=await live.payrollRecovery(school,commit,()=>{throw Error('Lost-ACK retry must not read Drive');});
  assert.deepEqual(replay,accepted);
  const peers=await live.replay(school,{command:'changes',after:head},deliver);
  const group=peers.events.filter(e=>e.bundleId===request.bundleId);
  assert.equal(group.length,2);assert.deepEqual(group.map(e=>e.bundleSize),[2,2]);
  assert.equal(group[0].record.netPaise,1900000);assert.equal(group[1].record.balancePaise,300000);
  let proof=await live.command(school,{command:'bundleReceipt',...wire});
  assert.equal(proof.driveVerified,false);
  // Only the broker and signed Script VM are involved here, not a client.
  assert.equal((await live.drain(school,deliver)).processed,1);
  proof=await live.command(school,{command:'bundleReceipt',...wire});
  assert.equal(proof.driveVerified,false);assert.equal(proof.backups[0].driveVerified,true);assert.equal(proof.backups[1].driveVerified,false);
  assert.equal((await live.drain(school,deliver)).processed,1);
  proof=await live.command(school,{command:'bundleReceipt',...wire});
  assert.equal(proof.driveVerified,true);
  const savedSalary=deliver({action:'managed_records',operation:'read',syncProtocol:2,collection:'teacher_salary',id:salaryId}).records[salaryId];
  const savedAdvance=deliver({action:'managed_records',operation:'read',syncProtocol:2,collection:'school_settings',id:advanceId}).records[advanceId];
  assert.equal(savedSalary.netPaise,1900000);assert.equal(savedAdvance.balancePaise,300000);
  assert.equal(savedSalary.advanceRecoveries[0].id,savedAdvance.events.at(-1).salaryRecoveryId);
  assert.equal(savedSalary._syncOperationId,request.salaryOperationId);
  assert.equal(savedAdvance._syncOperationId,request.advanceOperationId);
  assert.equal((await live.drain(school,deliver)).processed,0);
 }finally{await mf.dispose();}
});
