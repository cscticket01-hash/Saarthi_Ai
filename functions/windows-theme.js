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
  async readSchool(schoolId){
   const state=await db.doc('school_theme_state/'+schoolId).get();
   if(state.exists)return theme(state.data().active);
   const published=await ref().get();
   return published.exists?theme(published.data().activationBase||published.data()):{...DEFAULT_THEME};
  },
  async schoolState(schoolId,deviceId,locked,devices){
   if(typeof locked!=='boolean'||!devices.includes(deviceId)||devices.length>5)throw Object.assign(Error('Verified PC lock state required'),{status:400});
   const stateRef=db.doc('school_theme_state/'+schoolId);
   return db.runTransaction(async tx=>{
    const [published,stored,registry]=await Promise.all([tx.get(ref()),tx.get(stateRef),tx.get(db.doc('managed_pc_registries/'+schoolId))]);
    // Watch admission/revocation in the same transaction as activation.
    if(registry.exists){devices=Object.values(registry.data().devices||{}).filter(d=>d.status==='active'&&d.os==='Windows').map(d=>d.deviceIdentity);
     if(!devices.includes(deviceId))throw Object.assign(Error('Active Windows PC required'),{status:403});
    }
    const latest=published.exists?theme(published.data()):{...DEFAULT_THEME};
    const old=stored.exists?stored.data():{};
    const locks=Object.fromEntries(devices.map(id=>[id,old.locks?.[id]||{locked:false,at:0}]));
    // Check the barrier BEFORE opening this PC, and AFTER closing it.
    let active=old.active?theme(old.active):published.exists?theme(published.data().activationBase||published.data()):{...DEFAULT_THEME};
    if(devices.every(id=>locks[id].locked===true && now()-locks[id].at<=65000 && now()>=locks[id].at))active=latest;
    locks[deviceId]={locked,at:now()};
    if(devices.every(id=>locks[id].locked===true && now()-locks[id].at<=65000 && now()>=locks[id].at))active=latest;
    tx.set(stateRef,{active,locks,updatedAt:now()});
    return active;
   });
  },
  async save(input,uid){const next=theme(input);if(typeof input.expectedRevision!=='string')throw Object.assign(Error('Reload theme before saving'),{status:400,publicMessage:true});
   return db.runTransaction(async tx=>{const r=ref(),old=await tx.get(r),revision=old.exists?theme(old.data()).revision:'default';
    if(revision!==input.expectedRevision)throw Object.assign(Error('Theme changed. Reload before saving.'),{status:409,publicMessage:true});
    const saved={...next,activationBase:old.exists?theme(old.data().activationBase||old.data()):{...DEFAULT_THEME},revision:randomUUID(),updatedAt:now(),updatedBy:uid};tx.set(r,saved);return theme(saved);
   });
  }
 };
}
module.exports={createWindowsTheme,theme,DEFAULT_THEME};
