'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');
const src=readFileSync('lib/main_dashboard_screen_windows.dart','utf8');
test('analytics exam list remains read-only and never starts a second cloud upload',()=>{
 const needle="final localExams=await WindowsBackendBridge.localExamAction({'action':'list_exam_center'});";
 const start=src.indexOf(needle);
 assert.ok(start>0,'expected original local exam read');
 const end=src.indexOf('} catch (e) {',start);
 assert.ok(end>start&&end-start<2500,'bounded original analytics read');
 const block=src.slice(start,end);
 assert.ok(block.includes('_ExamCenterSnapshot'),'analytics still consumes list results');
 assert.ok(!block.includes('scheduleSoon('),'a read-only analytics fetch must not enqueue another sync');
 assert.ok(src.includes('WindowsSyncEngine.instance.scheduleSoon()'),
  'explicit business Save paths must retain their upload wakeups');
});
