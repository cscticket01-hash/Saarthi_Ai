'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {isolatedRunPrefix}=require('../../.github/scripts/isolated_fixture_identity.cjs');
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
