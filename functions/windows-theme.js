'use strict';
const {randomUUID}=require('node:crypto');
const DEFAULT_THEME=Object.freeze({schemaVersion:1,red:0,green:140,blue:120,revision:'default'});
function theme(value){
 if(!value||value.schemaVersion!==1||!['red','green','blue'].every(k=>Number.isInteger(value[k])&&value[k]>=0&&value[k]<=255))throw Object.assign(Error('Use whole RGB values from 0 to 255'),{status:400,publicMessage:true});
 return {schemaVersion:1,red:value.red,green:value.green,blue:value.blue,revision:typeof value.revision==='string'?value.revision:'default'};
}
function createWindowsTheme({db,now=Date.now}){
 const ref=()=>db.doc('platform_configuration/windows_theme');
 return {
  async read(){const row=await ref().get();return row.exists?theme(row.data()):{...DEFAULT_THEME};},
  async save(input,uid){const next=theme(input);if(typeof input.expectedRevision!=='string')throw Object.assign(Error('Reload theme before saving'),{status:400,publicMessage:true});
   return db.runTransaction(async tx=>{const r=ref(),old=await tx.get(r),revision=old.exists?theme(old.data()).revision:'default';
    if(revision!==input.expectedRevision)throw Object.assign(Error('Theme changed. Reload before saving.'),{status:409,publicMessage:true});
    const saved={...next,revision:randomUUID(),updatedAt:now(),updatedBy:uid};tx.set(r,saved);return theme(saved);
   });
  }
 };
}
module.exports={createWindowsTheme,theme,DEFAULT_THEME};
