'use strict';
// Offline Apps Script contract tests: do not call a real school or Google API.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../school-backend/managed/SaarthiManagedAll.gs'), 'utf8');
const ctx = vm.createContext({console, Date, JSON});
vm.runInContext(source, ctx, {filename:'SaarthiManagedAll.gs',timeout:10000});
function sheet(cols, rows=[]) {
  const items=rows.map(r=>[...r]);
  return {items, getLastRow(){return items.length+1},
    getRange(row,col){return {
      getValue(){return items[row-2]?.[col-1]||''},
      setValues(values){for(let i=0;i<values.length;i++)items[row-2+i]=[...values[i]];return this;}
    }},
    appendRow(values){assert.equal(values.length,cols);items.push([...values]);},
    getParent(){return {getUrl(){return 'https://docs.google.com/spreadsheets/d/fixture'}};}
  };
}
const fees=sheet(20), exams=sheet(8,[['EX-1','Term','VII',JSON.stringify(['Math','Science']),100,40,'Admin',new Date()]]), results=sheet(15);
ctx.getOrCreateDatabaseSheet=name=>name==='School_Fee_Payments'?fees:name==='School_Exam_Center'?exams:name==='School_Exam_Results'?results:assert.fail('unexpected sheet '+name);
ctx.findFeeReceiptRow=(sh,id)=>{const n=sh.items.findIndex(r=>r[0]===id);return n<0?-1:n+2};
ctx.findExamResultRow=(sh,examId,studentId)=>{const n=sh.items.findIndex(r=>r[0]===examId&&r[2]===studentId);return n<0?-1:n+2};
ctx.jsonResponse=v=>v;
ctx.createExamReportCardPdf=()=>assert.fail('PDF generator was called during save');
ctx.getOrCreateFolder=()=>assert.fail('Drive file upload was called during save');
const feeInput={receiptNo:'F-1',studentName:'Test',studentClass:'VII',rollNo:'01',month:'Nov',expectedAmount:200,totalPaid:100,balance:100};
assert.equal(ctx.saveFeePayment(feeInput).success,true);
assert.equal(fees.items.length,1);
assert.equal(fees.items[0][18],'');
assert.equal(ctx.saveFeePayment({...feeInput,pdfBase64:'obsolete-legacy-PDF',totalPaid:200}).success,true);
assert.equal(fees.items.length,1,'idempotent fee retry');
fees.items[0][18]='https://drive.google.com/file/d/old-receipt/view';
const updated=ctx.saveFeePayment({...feeInput,totalPaid:250});
assert.equal(fees.items[0][18],'https://drive.google.com/file/d/old-receipt/view');
assert.equal(updated.fileUrl,fees.items[0][18]);
const resultInput={examId:'EX-1',studentId:'ST-1',studentName:'Test',studentClass:'VII',rollNo:'01',marks:{Math:85,Science:76}};
assert.equal(ctx.saveExamResult(resultInput).success,true);
assert.equal(results.items.length,1);
assert.equal(results.items[0][12],'');
results.items[0][12]='https://drive.google.com/file/d/old-report/view';
assert.equal(ctx.saveExamResult({...resultInput,marks:{Math:86,Science:77}}).success,true);
assert.equal(results.items.length,1,'idempotent result retry');
assert.equal(results.items[0][12],'https://drive.google.com/file/d/old-report/view');
console.log('PASS GS record-only: no PDF at save; no Drive file upload; old links and row identity retained');
