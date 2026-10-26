'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
function rig(){
 const f=storage({lifecycle:true});let n=0;
 const read=(col='teachers_directory',id='Teacher_9999999999')=>f.call({action:'managed_records',operation:'read',collection:col,syncProtocol:2}).records[id];
 const write=(data,expected='',col='teachers_directory',id='Teacher_9999999999',operationId='fixture-operation-'+ ++n)=>f.call({action:'managed_records',operation:'write',collection:col,id,syncProtocol:2,operationId,expectedRecordRevision:expected,data:{schoolId:A,...data}});
 const patch=(base,set,remove=[],col='teachers_directory',id='Teacher_9999999999',op)=>{
  const before={};for(const key of new Set([...Object.keys(set),...remove]))if(key!=='updatedAt')before[key]={exists:Object.hasOwn(base,key),revision:base._syncFieldRevisions?.[key]||(Object.hasOwn(base,key)?base._syncRevision:'absent')};
  return {data:{_syncFieldPatch:{version:1,set,remove,before,...(base.teacherId?{identity:{teacherId:base.teacherId}}:{})}},expected:base._syncRevision,col,id,op};
 };
 const send=p=>write(p.data,p.expected,p.col,p.id,p.op);
 return {f,read,write,patch,send};
}
test('name/photo field patches retain every untouched field and update the same row on any later date',()=>{
 const r=rig();assert.equal(r.write({teacherId:'T1',name:'Mahit Das',phone:'9999999999',photoUrl:'',createdAt:{__vsTimestamp:'2000-01-01T00:00:00.000Z'}}).success,true);
 const base=r.read();assert.equal(r.send(r.patch(base,{name:'Mohit Das'})).success,true);
 const named=r.read();assert.equal(named.name,'Mohit Das');assert.equal(named.phone,'9999999999');
 const p=r.patch(named,{photoUrl:'https://drive.google.com/file/d/own-photo/view',photoFileId:'own-photo'});
 assert.equal(r.send(p).success,true);assert.equal(r.read().name,'Mohit Das');
 assert.equal(r.read().createdAt.__vsTimestamp,'2000-01-01T00:00:00.000Z');
 assert.equal(r.f.call({action:'managed_health'}).recordFieldPatchVersion,1);
});
test('independent field edits from two PCs merge; stale same-field changes and ABA remain protected',()=>{
 const r=rig();r.write({teacherId:'T1',name:'Before',subject:'Math'});const base=r.read();
 assert.equal(r.send(r.patch(base,{name:'Correct'})).success,true);
 assert.equal(r.send(r.patch(base,{subject:'Science'})).success,true);
 assert.equal(r.read().name,'Correct');assert.equal(r.read().subject,'Science');
 assert.equal(r.send(r.patch(base,{name:'Old offline name'})).success,false);
 const now=r.read();assert.equal(r.send(r.patch(now,{name:'Before'})).success,true);
 assert.equal(r.send(r.patch(base,{name:'Stale ABA edit'})).success,false);
});
test('a lost response replays exact frozen patch; modified same operation is rejected',()=>{
 const r=rig();r.write({teacherId:'T1',name:'Before'});const p=r.patch(r.read(),{name:'After'},[],undefined,undefined,'same-patch-operation-123');
 const first=r.send(p);assert.equal(first.success,true);r.f.restart();
 const retry=r.send(p);assert.equal(retry.success,true);assert.equal(retry.recordRevision,first.recordRevision);
 const changed={...p,data:{_syncFieldPatch:{...p.data._syncFieldPatch,set:{name:'Different'}}}};
 assert.equal(r.send(changed).success,false);assert.equal(r.read().name,'After');
});
test('patch cannot create, resurrect, change identity or remove school profile identity',()=>{
 const r=rig();r.write({teacherId:'T1',name:'Before'});const base=r.read();
 assert.equal(r.send(r.patch(base,{teacherId:'T2'})).success,false);
 assert.equal(r.send({...r.patch(base,{name:'Wrong person'}),data:{_syncFieldPatch:{...r.patch(base,{name:'Wrong person'}).data._syncFieldPatch,identity:{teacherId:'T2'}}}}).success,false);
 assert.equal(r.send({...r.patch(base,{name:'No parent'}),id:'absent'}).success,false);
 r.f.call({action:'managed_records',operation:'delete',collection:'teachers_directory',id:'Teacher_9999999999',syncProtocol:2,operationId:'delete-operation-123',expectedRecordRevision:base._syncRevision});
 assert.equal(r.send(r.patch(base,{name:'Resurrect'})).success,false);
 assert.equal(r.write({schoolName:'School',principalName:'Principal',schoolContactNo:'9999999999'},'','school_config','school_profile_cache').success,true);
 const profile=r.read('school_config','school_profile_cache');
 assert.equal(r.send(r.patch(profile,{schoolName:'Corrected School'},[],'school_config','school_profile_cache')).success,true);
 assert.equal(r.send(r.patch(r.read('school_config','school_profile_cache'),{schoolName:''},[],'school_config','school_profile_cache')).success,false);
});
