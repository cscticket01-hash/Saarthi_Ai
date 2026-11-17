// Limits are decimal GB, matching Cloudflare R2's GB-month billing unit.
// 8 GB is the maximum school-data staging budget; the next 2 GB is not
// available to school uploads. Neither is a Cloudflare billing stop switch.
export const R2_SCHOOL_DATA_BYTES=8_000_000_000;
export const R2_SYSTEM_RESERVE_BYTES=2_000_000_000;
export const R2_TOTAL_BYTES=R2_SCHOOL_DATA_BYTES+R2_SYSTEM_RESERVE_BYTES;
export const R2_VERIFIED_RETENTION_MS=24*60*60*1000;
export function checkedR2Admission(usedSchool,usedSystem,bytes,category='school'){
 const counts=[usedSchool,usedSystem,bytes];
 if(!counts.every(n=>Number.isSafeInteger(n)&&n>=0)||bytes===0||
    !['school','system'].includes(category))throw new RangeError('Invalid R2 quota request');
 const used=usedSchool+usedSystem,next=used+bytes;
 if(!Number.isSafeInteger(next))throw new RangeError('Invalid R2 usage');
 const school=category==='school'?usedSchool+bytes:usedSchool;
 const system=category==='system'?usedSystem+bytes:usedSystem;
 if(school>R2_SCHOOL_DATA_BYTES||system>R2_SYSTEM_RESERVE_BYTES||
    next>R2_TOTAL_BYTES) return {accepted:false,code:'R2_CAPACITY_EXCEEDED',
      schoolLimitBytes:R2_SCHOOL_DATA_BYTES,reservedSystemBytes:R2_SYSTEM_RESERVE_BYTES,totalLimitBytes:R2_TOTAL_BYTES};
 return {accepted:true,schoolBytes:school,systemBytes:system,totalBytes:next,
   schoolLimitBytes:R2_SCHOOL_DATA_BYTES,reservedSystemBytes:R2_SYSTEM_RESERVE_BYTES,totalLimitBytes:R2_TOTAL_BYTES};
}
export function verifiedR2PurgeDue(acceptedAt,verifiedAt){
 if(![acceptedAt,verifiedAt].every(n=>Number.isSafeInteger(n)&&n>0)||verifiedAt<acceptedAt)
  throw new RangeError('Original and verified receipt timestamps required');
 return Math.max(acceptedAt+R2_VERIFIED_RETENTION_MS,verifiedAt);
}
export function r2MayPurge(row,now){
 return row?.state==='verified'&&Number.isSafeInteger(now)&&
    Number.isSafeInteger(row.accepted_at)&&row.accepted_at>0&&
    Number.isSafeInteger(row.verified_at)&&row.verified_at>=row.accepted_at&&
    Number.isSafeInteger(row.purge_due)&&row.purge_due>=row.accepted_at+R2_VERIFIED_RETENTION_MS&&
    row.purge_due<=now;
}
