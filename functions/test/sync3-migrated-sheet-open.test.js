'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A,B}=require('./helpers/managed-storage');

test('completed Sheet migration stops accessing unused legacy folders while preserving workbook identity checks',()=>{
 const s=storage({lifecycle:true}),c=s.context;
 const store=c.VS_legacySheet('school_notices');
 assert.equal(s.props.get('VS_SHEET_MIGRATED_school_notices'),'1');
 let legacyCalls=0;
 c.VS_managedCollection=()=>{legacyCalls++;throw Error('legacy folder must not be accessed');};
 assert.equal(c.VS_legacySheet('school_notices').sheet,store.sheet);
 assert.equal(legacyCalls,0);
 s.all.get(s.props.get('VS_MANAGED_SHEET_ID')).setDescription('VIDYA_SCHOOL_DATA:'+B);
 assert.throws(()=>c.VS_legacySheet('school_notices'),/School workbook identity mismatch/);
 assert.equal(legacyCalls,0);
});

test('unfinished migration still imports and verifies original JSON records',()=>{
 const s=storage({lifecycle:true}),c=s.context;
 const legacy=s.roots[A].createFolder('records_school_notices');
 const data={schoolId:A,title:'Retained original',_syncRevision:'original-revision'};
 legacy.createFile('original.json',JSON.stringify({id:'original',schoolId:A,data}),'application/json');
 const store=c.VS_legacySheet('school_notices');
 assert.deepEqual(JSON.parse(JSON.stringify(c.VS_sheetItem(store,'original').data)),data);
 assert.equal(s.props.get('VS_SHEET_MIGRATED_school_notices'),'1');
 assert.equal(legacy.files.length,1);
});

test('unfinished migration still rejects duplicate legacy folders without marking migration complete',()=>{
 const s=storage({lifecycle:true});
 s.roots[A].createFolder('records_school_notices');
 s.roots[A].createFolder('records_school_notices');
 assert.throws(()=>s.context.VS_legacySheet('school_notices'),/Duplicate collection folders/);
 assert.equal(s.props.has('VS_SHEET_MIGRATED_school_notices'),false);
});
