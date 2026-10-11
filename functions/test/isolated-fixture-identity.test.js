'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {isolatedRunPrefix,isolatedAttendanceDay}=require('../../.github/scripts/isolated_fixture_identity.cjs');
test('isolated TEST fixture identity remains stable for retry within the same hosted attempt',()=>{
 const env={GITHUB_RUN_ID:'37973826645',GITHUB_RUN_ATTEMPT:'1'};
 assert.equal(isolatedRunPrefix(env),'isolated-v2-37973826645-1');
 assert.equal(isolatedRunPrefix({...env}),isolatedRunPrefix(env));
});
test('new TEST run or attempt cannot reuse an old attendance fixture or its capture timestamp',()=>{
 const first=isolatedRunPrefix({GITHUB_RUN_ID:'100',GITHUB_RUN_ATTEMPT:'1'});
 assert.notEqual(isolatedRunPrefix({GITHUB_RUN_ID:'101',GITHUB_RUN_ATTEMPT:'1'}),first);
 assert.notEqual(isolatedRunPrefix({GITHUB_RUN_ID:'100',GITHUB_RUN_ATTEMPT:'2'}),first);
});
test('isolated fixture generation rejects missing and malformed hosted identity',()=>{
 for(const env of [{},{GITHUB_RUN_ID:'production'},{GITHUB_RUN_ID:'1',GITHUB_RUN_ATTEMPT:'../school'}])assert.throws(()=>isolatedRunPrefix(env),/Hosted isolated TEST run identity/);
});

test('TEST calendar fixture uses actual IST capture day on Sunday without changing production policy',()=>{
 assert.equal(isolatedAttendanceDay('vs-db8afb01a3be46a983c8284714d06e5d',Date.parse('2026-10-11T00:44:00Z')),'2026-10-11');
 assert.equal(isolatedAttendanceDay('vs-db8afb01a3be46a983c8284714d06e5d',Date.parse('2026-10-10T19:00:00Z')),'2026-10-11');
 assert.throws(()=>isolatedAttendanceDay('vs-91c848f0c5d342d7b28b5da6187b57ff'),/TEST calendar scope/);
});
