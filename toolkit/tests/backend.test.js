/* Execute the real Apps Script bridge and original helpers against controlled
 * persistent Sheets/Firestore/Drive fixtures. These are correctness checks,
 * never a benchmark of Google's services or the user's school. */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const originals = ['SaarthiSchool.gs','SaarthiMobile.gs','SaarthiStorage.gs','SaarthiPlatform.gs']
  .map(name=>fs.readFileSync(path.join(root,'school-backend',name),'utf8')
    .replace(/\bfunction\s+doPost\s*\(/g,'function VS_toolkitOriginalDoPost(')).join('\n');
const bridge = fs.readFileSync(path.join(root,'toolkit/backend/ToolkitBridge.gs'),'utf8');

class Sheet {
  constructor(headers) { this.rows=[Array.from(headers)]; this.ignoreWrites=false; }
  getLastRow() { return this.rows.length; }
  getRange(row,col,count=1,width=1) {
    const sheet=this;
    return {
      getValues() { return Array.from({length:count},(_,r)=>Array.from({length:width},(_,c)=>sheet.rows[row+r-1]?.[col+c-1]??'')); },
      setNumberFormat() { return this; },
      setValues(values) {
        if(!sheet.ignoreWrites) values.forEach((line,r)=>{
          sheet.rows[row+r-1] ||= [];
          line.forEach((value,c)=>sheet.rows[row+r-1][col+c-1]=value);
        }); return this;
      }
    };
  }
}

function fixture() {
  const props=new Map([['VS_FIREBASE_PROJECT_ID','saarthi-lab-school'],['VS_FIREBASE_API_KEY','AIza'+'t'.repeat(30)]]);
  const db=new Map(), sheets=new Map(), cache=new Map(), folders=new Map();
  let expectedToken='', fileNumber=0;
  const f={props,db,sheets,folders,ignoreFirestore:false,corruptDrive:false,forwarded:0};
  const rootFolder={createFolder() {
    const id='folder-'+folders.size;
    const folder={getId:()=>id,createFile(blob) {
      const bytes=Buffer.from(blob.bytes);
      if(f.corruptDrive) bytes[0]^=1;
      const fileId='file-'+(++fileNumber);
      return {getId:()=>fileId,getBlob:()=>({getBytes:()=>Array.from(bytes)})};
    }};
    folders.set(id,folder);return folder;
  }};
  const context=vm.createContext({console,Date,Set,Map,JSON,Number,String,Array,Object,Math,
    PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k)??null,setProperty:(k,v)=>{props.set(k,v);}})},
    CacheService:{getScriptCache:()=>({get:k=>cache.get(k)??null,put:(k,v)=>cache.set(k,v)})},
    LockService:{getScriptLock:()=>({waitLock(){},releaseLock(){}})},
    ContentService:{MimeType:{JSON:'application/json'},createTextOutput:text=>({text,setMimeType(){return this;}})},
    Utilities:{DigestAlgorithm:{SHA_256:'sha256'},
      base64Decode:text=>Array.from(Buffer.from(text,'base64')),
      base64DecodeWebSafe:text=>Array.from(Buffer.from(text,'base64url')),
      newBlob:(bytes,type,name)=>({bytes:Buffer.from(bytes),getDataAsString:()=>Buffer.from(bytes).toString()}),
      computeDigest:(type,value)=>Array.from(crypto.createHash('sha256').update(typeof value==='string'?value:Buffer.from(value)).digest()),
      formatDate:d=>d.toISOString().slice(0,10)},
    UrlFetchApp:{fetch:(url,options)=>{
      assert.match(url,/^https:\/\/identitytoolkit\.googleapis\.com\/v1\/accounts:lookup\?/);
      const valid=JSON.parse(options.payload).idToken===expectedToken;
      return {getResponseCode:()=>valid?200:400,getContentText:()=>JSON.stringify(valid?{users:[{localId:'admin-test',validSince:'0'}]}:{error:'Invalid signature'})};
    }},
    DriveApp:{getFolderById:id=>folders.get(id)},
    testFirestore(method,route,data) {
      if(route===':commit') {
        if(!f.ignoreFirestore) data.writes.forEach(w=>db.set(w.update.name,JSON.parse(JSON.stringify(w.update))));
        return {writeResults:data.writes.map(()=>({}))};
      }
      if(route===':batchGet') return data.documents.map(name=>db.has(name)?{found:db.get(name)}:{missing:name});
      throw Error('Unexpected fixture Firestore route '+route);
    },
    testSheet(name,headers) { if(!sheets.has(name))sheets.set(name,new Sheet(headers));return sheets.get(name); },
    testRoot:rootFolder,
    testForward:()=>{f.forwarded++;return {text:'original-handler'};}
  });
  vm.runInContext(originals+'\n'+bridge,context,{filename:'test-backend.gs'});
  vm.runInContext(`VS_firestore=testFirestore; getOrCreateDatabaseSheet=testSheet;
    VS_schoolDriveRoot=()=>testRoot; VS_toolkitOriginalDoPost=testForward;
    VS_platformStatus=()=>({allowed:true,expiresAt:Date.now()+3600000});
    VS_isOpen=()=>true; VS_get=()=>({latitude:22,longitude:88}); VS_query=()=>[];`,context);
  const claims={aud:'saarthi-lab-school',iss:'https://securetoken.google.com/saarthi-lab-school',
    exp:Math.floor(Date.now()/1000)+3600,auth_time:Math.floor(Date.now()/1000),admin:true,sub:'admin-test'};
  expectedToken='eyJhbGciOiJSUzI1NiJ9.'+Buffer.from(JSON.stringify(claims)).toString('base64url')+'.fixtureSignedProof';
  f.context=context;f.token=expectedToken;
  f.call=(action,body={},token=expectedToken)=>{
    const response=context.doPost({postData:{contents:JSON.stringify({action,schoolProjectId:props.get('VS_FIREBASE_PROJECT_ID'),schoolAdminIdToken:token,...body})}});
    return JSON.parse(response.text);
  };
  f.enable=()=>context.VS_toolkitEnableTestMode();
  f.headers=vm.runInContext('({STUDENT_HEADERS,FEE_HEADERS,STUDENT_SHEET_NAME,FEE_SHEET_NAME})',context);
  return f;
}

function students() {
  return [1,2].map(i=>{
    const personId='tk_1234567890abcdef_'+String(i).padStart(6,'0');
    return {personId,profile:{name:'TEST Student '+i,class:'1',rollNo:String(i),dob:'2012-01-02',
      dateOfBirth:'2012-01-02',mobileStableId:personId,mobileLinkToken:'a'.repeat(64),studentUid:personId}};
  });
}

let checks=0;
function test(name,action) { action();checks++;console.log('PASS '+name); }
test('Test mode and real administrator proof are required',()=>{
  const f=fixture();assert.equal(f.call('toolkit_info').success,false);
  f.enable();assert.equal(f.call('toolkit_info').success,true);
  assert.equal(f.call('toolkit_info',{},f.token+'tampered').success,false);
  f.props.set('VS_FIREBASE_PROJECT_ID','saarthi-ai-df12b');assert.throws(f.enable,/separate Firebase/);
  assert.equal(f.call('toolkit_info').success,false);
});
test('Non-toolkit traffic is forwarded to the original router',()=>{
  const f=fixture();const response=f.context.doPost({postData:{contents:'{"action":"mobile_login"}'}});
  assert.equal(response.text,'original-handler');assert.equal(f.forwarded,1);
});
test('Seed counts come from persistent Firestore and Sheets read-back',()=>{
  const f=fixture();f.enable();const input=students();
  let result=f.call('toolkit_seed',{students:input});assert.equal(result.verified,2);assert.equal(result.sheetsVerified,2);
  result=f.call('toolkit_seed',{students:input});assert.equal(result.verified,2);
  assert.equal(f.sheets.get(f.headers.STUDENT_SHEET_NAME).getLastRow(),3);
  const bad=students();bad[0].profile.name='Actual student';
  assert.equal(f.call('toolkit_seed',{students:bad}).success,false);
  const other=students();other[0].profile.dob='2011-01-02';
  assert.equal(f.call('toolkit_seed',{students:other}).success,false);
});
test('Successful write acknowledgement cannot invent saved documents',()=>{
  const f=fixture();f.enable();f.ignoreFirestore=true;
  const result=f.call('toolkit_seed',{students:students()});assert.equal(result.verified,0);assert.equal(f.db.size,0);
  const g=fixture();g.enable();g.context.getOrCreateDatabaseSheet(g.headers.STUDENT_SHEET_NAME,g.headers.STUDENT_HEADERS).ignoreWrites=true;
  assert.equal(g.call('toolkit_seed',{students:students()}).success,false);
});
test('Duplicate sheet rows are not verified as one correct student',()=>{
  const f=fixture();f.enable();f.call('toolkit_seed',{students:students()});
  const sheet=f.sheets.get(f.headers.STUDENT_SHEET_NAME);sheet.rows.push(sheet.rows[1].slice());
  assert.equal(f.call('toolkit_verify_students',{students:students().map(s=>s.profile)}).matched,1);
});
test('Attendance audit detects duplicate logical identities',()=>{
  const f=fixture();f.enable();f.context.VS_query=()=>[
    {personId:'p1',role:'student'},{personId:'p1',role:'student'},
    {personId:'p1',role:'teacher'},{personId:'other',role:'student'}];
  const result=f.call('toolkit_audit_attendance',{day:'2026-10-05',personIds:['p1']});
  assert.equal(result.duplicates,1);assert.equal(result.auditedPeople,1);
});
test('Fee verification uses the actual Total Paid schema and duplicate receipts',()=>{
  const f=fixture();f.enable();const h=f.headers.FEE_HEADERS;
  const sheet=f.context.getOrCreateDatabaseSheet(f.headers.FEE_SHEET_NAME,h), id='TK_1234567890abcdef_1';
  const row=Array(h.length).fill('');row[h.indexOf('Receipt No')]=id;
  row[h.indexOf('Expected Amount')]=999;row[h.indexOf('Total Paid')]=100;
  sheet.rows.push(row);assert.equal(f.call('toolkit_verify_fees',{receipts:[id]}).paidAmount,100);
  sheet.rows.push(row.slice());const result=f.call('toolkit_verify_fees',{receipts:[id]});
  assert.equal(result.duplicates,1);assert.equal(result.paidAmount,200);
});
test('Drive checksum reads saved bytes and detects corruption instead of echoing input',()=>{
  const f=fixture();f.enable();const bytes=crypto.randomBytes(65536), digest=crypto.createHash('sha256').update(bytes).digest('hex');
  const request={runId:'1234567890abcdef',part:0,data:bytes.toString('base64'),sha256:digest};
  let result=f.call('toolkit_volume_chunk',request);assert.equal(result.bytes,bytes.length);assert.equal(result.sha256,digest);
  f.corruptDrive=true;result=f.call('toolkit_volume_chunk',{...request,part:1});assert.notEqual(result.sha256,digest);
  assert.equal(f.call('toolkit_volume_chunk',{...request,data:Buffer.alloc(1000001).toString('base64')}).success,false);
});
console.log(checks+' actual adapter checks passed');
