'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createLiveSync}=require('../live-sync'),{createLiveGateway}=require('../live-sync-gateway');
const {storage}=require('./helpers/managed-storage');
const school='vs-'+'a'.repeat(32),collection='school_settings',id='staff_payroll_directory';
test('staff payroll retains its GS lifecycle owner while independent settings use live authority',async()=>{
 const gs=storage({lifecycle:true,bundle:true}),read=async body=>gs.call(body);
 const saved=gs.call({action:'managed_records',collection,id,operation:'write',syncProtocol:2,operationId:'staff-partition-original-0001',expectedRecordRevision:'',data:{schoolId:school,staff:[]}});assert.equal(saved.success,true,JSON.stringify(saved));
 const commands=[],head={liveProtocol:1,schoolId:school,cursor:0,collections:[{collection,state:'active',cursor:0}]};
 const live=createLiveSync({schools:[school],edge:{enabled:()=>true,rpc:async(s,l,b)=>{commands.push(b);if(b.command==='head')return head;if(b.command==='snapshot')return {liveProtocol:1,schoolId:school,cursor:0,records:[],next:null};return {state:b.command==='seedSeal'?'active':'seeding'};}}});
 await live.prepare(school,collection,read);
 assert.equal(commands.find(c=>c.command==='seedBegin').count,0);assert(!commands.some(c=>c.command==='seedPage'));
 const gateway=createLiveGateway({liveSync:live,migration:{}}),request={operation:'read',collection,syncProtocol:2,liveProtocol:1};
 const first=await gateway.records(school,request,read);assert.deepEqual(JSON.parse(JSON.stringify(first.records[id].staff)),[]);assert.match(first.collectionRevision,/^live:school_settings:0:/);
 assert.equal((await gateway.records(school,{...request,knownRevision:first.collectionRevision},read)).unchanged,true);
 const changed=gs.call({action:'managed_records',collection,id,operation:'write',syncProtocol:2,operationId:'staff-partition-updated-0001',expectedRecordRevision:saved.recordRevision,data:{schoolId:school,staff:[],lastReviewed:'today'}});assert.equal(changed.success,true,JSON.stringify(changed));
 const next=await gateway.records(school,{...request,knownRevision:first.collectionRevision},read);assert.notEqual(next.collectionRevision,first.collectionRevision);assert.equal(next.records[id].lastReviewed,'today');
 assert.equal((await gateway.head(school,collection,read)).collectionRevision,next.collectionRevision);
});
