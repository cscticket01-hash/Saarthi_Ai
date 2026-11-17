export declare const R2_SCHOOL_DATA_BYTES:8000000000;
export declare const R2_SYSTEM_RESERVE_BYTES:2000000000;
export declare const R2_TOTAL_BYTES:10000000000;
export declare const R2_VERIFIED_RETENTION_MS:number;
export declare function checkedR2Admission(usedSchool:number,usedSystem:number,bytes:number,category?:'school'|'system'):
 {accepted:boolean,code?:string,schoolBytes?:number,systemBytes?:number,totalBytes?:number,schoolLimitBytes:number,reservedSystemBytes:number,totalLimitBytes:number};
export declare function verifiedR2PurgeDue(acceptedAt:number,verifiedAt:number):number;
export declare function r2MayPurge(row:{state:string,accepted_at:number,verified_at:number,purge_due:number}|null|undefined,now:number):boolean;
