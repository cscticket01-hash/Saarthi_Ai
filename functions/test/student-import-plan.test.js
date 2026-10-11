'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {planStudentImport,MAX_ROWS}=require('../student-import-plan');
const row=(id='S1',extra={})=>({schoolId:'school-A',studentId:id,name:'Test Student',class:'VI',section:'A',rollNo:id,expectedRevision:null,...extra});
const plan=(rows,currentRecords=[])=>planStudentImport({schoolId:'school-A',rows,currentRecords});
test('preview is deterministic, school bound, non-executable and does not mutate input',()=>{
 const rows=[row('S2'),row('S1')],before=JSON.stringify(rows);const a=plan(rows),b=plan([...rows].reverse());
 assert.equal(a.valid,true);assert.equal(a.previewOnly,true);assert.equal(a.committable,false);assert.equal(a.planId,b.planId);assert.deepEqual(a.operations,b.operations);assert.equal(JSON.stringify(rows),before);
 assert.notEqual(planStudentImport({schoolId:'school-B',rows:[row('S1',{schoolId:'school-B'})],currentRecords:[]}).operations[0].operationId,a.operations[0].operationId);
});
test('revision-safe updates require exact snapshot revision and no-op records produce no operation',()=>{
 const prior={...row(),revision:'r1'};const before=JSON.stringify(prior);
 assert.equal(plan([row()], [prior]).errors[0].code,'REVISION_CONFLICT');
 assert.equal(plan([row('S1',{expectedRevision:'r1'})],[prior]).operations.length,0);
 const change=row('S1',{expectedRevision:'r1',name:'Changed'});const a=plan([change],[prior]);assert.equal(a.operations[0].kind,'update');
 assert.notEqual(a.operations[0].operationId,plan([{...change,expectedRevision:'r2'}],[{...prior,revision:'r2'}]).operations[0].operationId);assert.equal(JSON.stringify(prior),before);
});
test('invalid batch exposes no partial operations and reports duplicates and foreign school',()=>{
 for(const [rows,code] of [[[row(),row()], 'DUPLICATE_STUDENT_ID'],[[row(),row('S2',{rollNo:'S1'})],'DUPLICATE_CLASS_ROLL'],[[row(),row('S2',{schoolId:'school-B'})],'FOREIGN_SCHOOL']]){const p=plan(rows);assert.equal(p.valid,false);assert.equal(p.errors[0].code,code);assert.deepEqual(p.operations,[]);}
 assert.equal(plan([row('S2',{rollNo:'S1'})],[{...row(),revision:'r1'}]).errors[0].code,'EXISTING_CLASS_ROLL');
});
test('prototype keys, arbitrary internal fields, malformed IDs and unbounded inputs are rejected',()=>{
 assert.equal(plan([JSON.parse('{"__proto__":{}}')]).errors[0].code,'UNSAFE_KEY');
 assert.equal(plan([row('S1',{fees:0})]).errors[0].code,'UNSUPPORTED_FIELD');
 for(const studentId of ['../x','x/y','constructor',' x',''])assert.equal(plan([row(studentId)]).valid,false);
 assert.throws(()=>plan([]));assert.throws(()=>plan(Array(MAX_ROWS+1).fill(row())));assert.throws(()=>planStudentImport({rows:[row()],currentRecords:[]}));
 assert.throws(()=>plan([row()],[{...row(),schoolId:'school-B',revision:'r1'}]));
 assert.throws(()=>plan([row()],[{...row(),revision:'r1'},{...row(),revision:'r2'}]));
 assert.equal(plan([Object.create({schoolId:'school-A'})]).valid,false);
});
