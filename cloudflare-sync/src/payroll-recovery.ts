// Pure proposal builder for a future *paired* authoritative payroll commit.
// This is not a delivery route and must never be used for two separate writes.
type Json=Record<string,unknown>;
function invalid():never {throw Object.assign(new Error('Payroll recovery needs verified salary and advance baselines; originals retained'),{status:409,code:'PAYROLL_RECOVERY_REVIEW_REQUIRED'});}
function paise(value:unknown):number{
 if(typeof value!=='number'||!Number.isSafeInteger(value)||value<0)invalid();
 return value;
}
function events(value:unknown):Json[]{
 if(value===undefined||value===null)return [];
 if(!Array.isArray(value)||value.some(e=>!e||typeof e!=='object'||Array.isArray(e)))invalid();
 return value as Json[];
}
export function proposePayrollRecovery(input:{
 schoolId:string;salaryId:string;advanceId:string;salary:Json;advance:Json;
 amountPaise:number;eventId:string;reference:string;at:number;monthClosed:boolean;
}):{salary:Json;advance:Json}{
 const {schoolId,salaryId,advanceId,salary,advance,eventId,at,monthClosed}=input;
 const amount=paise(input.amountPaise),reference=input.reference.trim();
 if(!/^vs-[a-f0-9]{32}$/.test(schoolId)||!salaryId||!advanceId||!eventId||eventId.length>200||!reference||reference.length>500||
  !Number.isSafeInteger(at)||at<=0||!amount||monthClosed||salary.salaryLocked===true||
  salary._syncDeleted===true||advance._syncDeleted===true||salary.schoolId!==schoolId||advance.schoolId!==schoolId||
  typeof salary.staffId!=='string'||!salary.staffId||advance.staffId!==salary.staffId||
  typeof salary.month!=='string'||!/^\d{4}-(0[1-9]|1[0-2])$/.test(salary.month)||
  typeof salary._syncRevision!=='string'||!salary._syncRevision||typeof advance._syncRevision!=='string'||!advance._syncRevision||
  salary.id!==undefined&&salary.id!==salaryId)invalid();
 const net=paise(salary.netPaise),paid=paise(salary.paidPaise),deduction=paise(salary.deductionPaise);
 if(paid>net||salary.balancePaise!==net-paid||amount>net-paid||
  salary.status!==(paid===net?'Paid':paid===0?'Pending':'Part paid')||
  paise(salary.basicPaise)+paise(salary.allowancePaise??0)+paise(salary.bonusPaise??0)+paise(salary.overtimePaise??0)-deduction!==net)invalid();
 if(salary.amount!==undefined&&(typeof salary.amount!=='number'||Math.round(salary.amount*100)!==net))invalid();
 const old=events(advance.events),recoveries=events(salary.advanceRecoveries);
 let outstanding=0;const ids=new Set<string>();
 for(const e of old){
  if(typeof e.id!=='string'||!e.id||ids.has(e.id))invalid();
  ids.add(e.id);const n=paise(e.amountPaise);
  if(!n)invalid();
  if(e.type==='advance'||e.type==='loan')outstanding+=n;
  else if(e.type==='repayment')outstanding-=n;
  else invalid();
  paise(outstanding);
 }
 if(outstanding!==paise(advance.balancePaise)||amount>outstanding||ids.has(eventId)||recoveries.some(e=>e.id===eventId))invalid();
 const recoveryIds=new Set<string>();
 for(const r of recoveries){
  if(typeof r.id!=='string'||recoveryIds.has(r.id)||r.advanceId!==advanceId||r.salaryId!==salaryId||r.month!==salary.month||!paise(r.amountPaise))invalid();
  recoveryIds.add(r.id);
  const match=old.filter(e=>e.id===r.id&&e.type==='repayment'&&e.salaryRecoveryId===r.id&&e.salaryId===salaryId&&e.month===salary.month&&e.amountPaise===r.amountPaise);
  if(match.length!==1)invalid();
 }
 const nextNet=net-amount,nextDeduction=paise(deduction+amount);
 const business=(r:Json)=>Object.fromEntries(Object.entries(r).filter(([k])=>!k.startsWith('_sync')));
 const link={id:eventId,amountPaise:amount,salaryId,advanceId,month:salary.month,reference,at};
 return {
  salary:{...business(salary),advanceRecoveries:[...recoveries,link],deductionPaise:nextDeduction,netPaise:nextNet,amount:nextNet/100,
    paidPaise:paid,balancePaise:nextNet-paid,status:paid===nextNet?'Paid':paid===0?'Pending':'Part paid',updatedAt:at},
  advance:{...business(advance),events:[...old,{id:eventId,type:'repayment',amountPaise:amount,reference,recordedAt:at,
    salaryRecoveryId:eventId,salaryId,month:salary.month}],balancePaise:outstanding-amount,updatedAt:at},
 };
}
