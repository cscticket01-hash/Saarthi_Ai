import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {Worker} from 'node:worker_threads';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {UniversalUidRegistry,uidNameCode,formatUid} from '../src/universal-uid.ts';
const school='vs-'+'a'.repeat(32),other='vs-'+'b'.repeat(32);
const p=n=>'p-'+n.toString(16).padStart(64,'0');
function storage(db){
  return {sql:{exec(q,...a){
    const stmt=db.prepare(q);
    if(/^\s*SELECT/i.test(q))return {toArray:()=>stmt.all(...a)};
    stmt.run(...a);return {toArray:()=>[]};
  }},transactionSync(fn){
    db.exec('BEGIN IMMEDIATE');
    try{const result=fn();db.exec('COMMIT');return result;}
    catch(e){db.exec('ROLLBACK');throw e;}
  }};
}
function registry(t){const db=new DatabaseSync(':memory:');t.after(()=>db.close());return new UniversalUidRegistry(storage(db));}
test('approved UID format and three counters, four categories, independent schools',t=>{
  const r=registry(t);
  assert.throws(()=>r.reserve(school,p(1),'student','Rahul'),/migration/);
  r.initializeSchool(school,'Sunshine Public School',[]);
  r.initializeSchool(other,'Sunshine Public School',[]);
  assert.equal(r.reserve(school,p(1),'student','Rahul Sharma'),'STU-SUNS-RAHU-000001');
  assert.equal(r.reserve(school,p(2),'student','Priya Das'),'STU-SUNS-PRIY-000002');
  assert.equal(r.reserve(school,p(3),'teacher','Amit Kumar'),'TCH-SUNS-AMIT-000001');
  assert.equal(r.reserve(school,p(4),'officeStaff','Suman Das'),'STF-SUNS-SUMA-000001');
  assert.equal(r.reserve(school,p(5),'otherStaff','Bikash Roy'),'STF-SUNS-BIKA-000002');
  assert.equal(r.reserve(other,p(1),'student','Rahul Sharma'),'STU-SUNS-RAHU-000001');
  assert.equal(r.lookup(other,p(5)),null);
  assert.deepEqual(r.snapshot(school).counters,{STF:3,STU:3,TCH:2});
});
test('short and multilingual names, validation and boundaries',()=>{
  assert.equal(uidNameCode('Om'),'OMXX');
  assert.equal(uidNameCode(' É-l O 9 n '),'ELON');
  assert.equal(Array.from(uidNameCode('学校教师')).length,4);
  assert.throws(()=>uidNameCode('123 !'),/letters/);
  assert.throws(()=>formatUid('STU','SUNS','Rahul',1000000),/exhausted/);
  assert.throws(()=>formatUid('STU','SUNS','Rahul',0),/invalid/);
});
test('legacy values preserved; high-water mark, rename and role change',t=>{
  const r=registry(t);
  r.initializeSchool(school,'Sunshine',[{personId:p(1),uid:'TEST-000012'},{personId:p(2),uid:'STU-SUNS-RAHU-000102'},{personId:p(3),uid:'STF-SUNS-SUMA-000010'}]);
  assert.equal(r.reserve(school,p(1),'student','Changed Name'),'TEST-000012');
  assert.equal(r.reserve(school,p(4),'student','Ravi'),'STU-SUNS-RAVI-000103');
  assert.equal(r.reserve(school,p(5),'officeStaff','Om'),'STF-SUNS-OMXX-000011');
  assert.equal(r.reserve(school,p(5),'otherStaff','Renamed'),'STF-SUNS-OMXX-000011');
  assert.throws(()=>r.initializeSchool(school,'New name',[]),/already initialized/);
});
test('duplicate migration rolls back completely',t=>{
  const r=registry(t);
  assert.throws(()=>r.initializeSchool(school,'Sunshine',[{personId:p(1),uid:'STU-SUNS-RAHU-000010'},{personId:p(2),uid:'STU-SUNS-RAKE-000010'}]));
  assert.throws(()=>r.snapshot(school),/not initialized/);
  assert.throws(()=>r.initializeSchool(school,'Sunshine',[{personId:p(1),uid:'legacy-1'},{personId:p(2),uid:'LEGACY-1'}]));
  assert.throws(()=>r.reserve(school,p(3),'teacher','Ravi'),/migration/);
  r.initializeSchool(school,'Sunshine',[]);
  assert.equal(r.reserve(school,p(3),'teacher','Ravi'),'TCH-SUNS-RAVI-000001');
});
test('persistent reservations survive restart; 1000 people across two DB handles',t=>{
  const dir=mkdtempSync(join(tmpdir(),'uid-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const path=join(dir,'registry.sqlite');
  let db=new DatabaseSync(path),r=new UniversalUidRegistry(storage(db));
  r.initializeSchool(school,'Sunshine',[]);
  const first=r.reserve(school,p(1),'teacher','Same Name');db.close();
  db=new DatabaseSync(path);r=new UniversalUidRegistry(storage(db));
  const peerDb=new DatabaseSync(path);
  try{
    const peer=new UniversalUidRegistry(storage(peerDb)),values=new Set([first]);
    for(let i=2;i<=1000;i++)values.add((i%2?peer:r).reserve(school,p(i),'teacher','Same Name'));
    assert.equal(values.size,1000);
    assert.equal(peer.snapshot(school).counters.TCH,1001);
    assert.equal(peer.reserve(school,p(1),'teacher','New name'),first);
  }finally{peerDb.close();db.close();}
});
test('bad inputs and exhaustion do not advance or reuse sequence',t=>{
  const r=registry(t);
  r.initializeSchool(school,'Sunshine',[{personId:p(1),uid:'TCH-SUNS-RAHU-999999'}]);
  assert.throws(()=>r.reserve(school,p(2),'teacher','New'),/exhausted/);
  assert.equal(r.snapshot(school).counters.TCH,1000000);
  assert.equal(r.lookup(school,p(2)),null);
  assert.throws(()=>r.reserve(school,'Teacher_123','student','Name'),/identity/);
  assert.throws(()=>r.reserve('wrong-school',p(2),'teacher','Name'),/school/);
  assert.throws(()=>r.reserve(school,p(2),'student','123'),/letters/);
  assert.equal(r.snapshot(school).counters.STU,1);
});

test('verified recovery preserves reservations and counter gaps without overwriting a ledger', t => {
  const original = registry(t);
  const restored = registry(t);
  original.initializeSchool(school, 'Sunshine', [
    {personId: p(1), uid: 'LEGACY-001'},
    {personId: p(2), uid: 'TCH-SUNS-AMIT-000020'},
  ]);
  const backup = original.snapshot(school);
  assert.throws(() => restored.restoreSchool(other, backup), /another school/);
  assert.throws(() => restored.restoreSchool(school, {
    ...backup, counters: {...backup.counters, TCH: 20},
  }), /high-water mark/);
  assert.throws(() => restored.snapshot(school), /not initialized/);

  const verifiedBackup = {...backup, counters: {...backup.counters, TCH: 30}};
  restored.restoreSchool(school, verifiedBackup);
  assert.deepEqual(restored.snapshot(school), verifiedBackup);
  assert.equal(restored.reserve(school, p(1), 'teacher', 'Renamed'), 'LEGACY-001');
  assert.equal(restored.reserve(school, p(3), 'teacher', 'Ravi'), 'TCH-SUNS-RAVI-000030');
  assert.throws(() => restored.restoreSchool(school, verifiedBackup), /already initialized/);
  assert.equal(restored.snapshot(school).counters.TCH, 31);
});

test('concurrent writers retain one UID per person and allocate unique serials', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'uid-concurrent-'));
  t.after(() => rmSync(dir, {recursive: true, force: true}));
  const path = join(dir, 'registry.sqlite');
  const db = new DatabaseSync(path, {timeout: 5000});
  t.after(() => db.close());
  const registry = new UniversalUidRegistry(storage(db));
  registry.initializeSchool(school, 'Sunshine', []);
  const moduleUrl = new URL('../src/universal-uid.ts', import.meta.url).href;
  const start = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
  const gate = new Int32Array(start);
  function allocate(first) {
    return new Promise((resolve, reject) => {
      const worker = new Worker(`
        const {parentPort, workerData} = require('node:worker_threads');
        const {DatabaseSync} = require('node:sqlite');
        (async () => {
          const {UniversalUidRegistry} = await import(workerData.moduleUrl);
          const {path, school, first, start} = workerData;
          const db = new DatabaseSync(path, {timeout: 5000});
          try {
            const registry = new UniversalUidRegistry((${storage})(db));
            const gate = new Int32Array(start);
            Atomics.add(gate, 0, 1);
            Atomics.notify(gate, 0);
            if (Atomics.load(gate, 0) < 2 && Atomics.wait(gate, 0, 1, 5000) === 'timed-out') {
              throw new Error('Second allocator did not start');
            }
            const ids = [1, ...Array.from({length: 25}, (_, index) => first + index)];
            parentPort.postMessage(ids.map(id => registry.reserve(
              school, (${p})(id), 'teacher', 'Same Name')));
          } finally {
            db.close();
          }
        })().catch(error => { throw error; });
      `, {eval: true, workerData: {moduleUrl, path, school, first, start}});
      t.after(() => worker.terminate());
      worker.once('message', resolve);
      worker.once('error', reject);
      worker.once('exit', code => {
        if (code !== 0) reject(new Error('Allocator exited with code ' + code));
      });
    });
  }
  const [first, second] = await Promise.all([allocate(2), allocate(27)]);
  assert.equal(Atomics.load(gate, 0), 2);
  assert.equal(first[0], second[0]);
  assert.equal(new Set([...first, ...second]).size, 51);
  assert.equal(registry.snapshot(school).counters.TCH, 52);
});
