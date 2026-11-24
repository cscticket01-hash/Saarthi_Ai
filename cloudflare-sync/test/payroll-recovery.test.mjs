import {test} from 'node:test';
import assert from 'node:assert/strict';
import {proposePayrollRecovery} from '../src/payroll-recovery.ts';
const schoolId='vs-'+'a'.repeat(32);
const salary={schoolId,id:'salary-one',staffId:'staff:one',month:'2026-11',basicPaise:2000000,deductionPaise:0,netPaise:2000000,paidPaise:500000,balancePaise:1500000,amount:20000,status:'Part paid',_syncRevision:'live-salary'};
const advance={schoolId,staffId:'staff:one',events:[{id:'loan-one',type:'loan',amountPaise:400000}],balancePaise:400000,_syncRevision:'live-advance'};
const input={schoolId,salaryId:'salary-one',advanceId:'advance-one',salary,advance,amountPaise:100000,eventId:'recovery-one',reference:'Approved salary deduction',at:1795500000000,monthClosed:false};
test('paired recovery derives net salary and advance outstanding with identical event identity',()=>{
 const result=proposePayrollRecovery(input);
 assert.equal(result.salary.netPaise,1900000);
 assert.equal(result.salary.paidPaise,500000);
 assert.equal(result.salary.balancePaise,1400000);
 assert.equal(result.advance.balancePaise,300000);
 assert.equal(result.salary.advanceRecoveries[0].id,result.advance.events.at(-1).salaryRecoveryId);
 assert.equal(salary.netPaise,2000000);assert.equal(advance.balancePaise,400000);
});
test('paired recovery rejects mismatched owner, paid balance, locks and over-recovery',()=>{
 for(const patch of [{amountPaise:400001},{monthClosed:true},{salary:{...salary,salaryLocked:true}},{salary:{...salary,balancePaise:1}},{advance:{...advance,staffId:'staff:two'}},{advance:{...advance,balancePaise:1}},{salary:{...salary,_syncRevision:''}},{amountPaise:0}]){
  assert.throws(()=>proposePayrollRecovery({...input,...patch}),e=>e.code==='PAYROLL_RECOVERY_REVIEW_REQUIRED');
 }
});
test('a previously recovered event cannot be applied again or lose its counterpart',()=>{
 const first=proposePayrollRecovery(input);
 const next={...input,salary:{...first.salary,_syncRevision:'live-next-salary'},advance:{...first.advance,_syncRevision:'live-next-advance'}};
 assert.throws(()=>proposePayrollRecovery(next),e=>e.code==='PAYROLL_RECOVERY_REVIEW_REQUIRED');
 const second=proposePayrollRecovery({...next,eventId:'recovery-two'});
 assert.equal(second.advance.balancePaise,200000);
 assert.equal(second.salary.advanceRecoveries.length,2);
 assert.throws(()=>proposePayrollRecovery({...next,eventId:'recovery-two',advance:{...advance,_syncRevision:'live-other'}}),e=>e.code==='PAYROLL_RECOVERY_REVIEW_REQUIRED');
});
