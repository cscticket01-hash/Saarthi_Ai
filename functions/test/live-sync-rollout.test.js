'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {liveSyncSchools}=require('../live-sync-rollout');
const {createLiveSync}=require('../live-sync');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32);
test('production live rollout accepts explicit schools independently and remains off by default',async()=>{
 assert.deepEqual(liveSyncSchools({}),[]);
 assert.deepEqual(liveSyncSchools({SAARTHI_LIVE_SYNC_SCHOOLS:` ${A},${B},${A} `}),[A,B]);
 const calls=[],live=createLiveSync({schools:liveSyncSchools({SAARTHI_LIVE_SYNC_SCHOOLS:`${A},${B}`}),edge:{enabled:s=>s!==B,rpc:async(s,l,b)=>{calls.push(s);return {};}}});
 await live.command(A,{command:'head'});
 await assert.rejects(live.command(B,{command:'head'}),e=>e.code==='LIVE_SYNC_DISABLED');
 assert.deepEqual(calls,[A]);
});
test('invalid or unbounded rollout configuration cannot broaden admission',()=>{
 for(const value of ['*',A+',*',A+',school-b',A+',vs-'+'B'.repeat(32)])assert.throws(()=>liveSyncSchools({SAARTHI_LIVE_SYNC_SCHOOLS:value}));
 assert.throws(()=>liveSyncSchools({SAARTHI_LIVE_SYNC_TEST_SCHOOL_ID:A}));
 const ids=Array.from({length:401},(_,i)=>'vs-'+i.toString(16).padStart(32,'0'));
 assert.equal(liveSyncSchools({SAARTHI_LIVE_SYNC_SCHOOLS:ids.slice(0,400).join(',')}).length,400);
 assert.throws(()=>liveSyncSchools({SAARTHI_LIVE_SYNC_SCHOOLS:ids.join(',')}));
 const isolated='vs-db8afb01a3be46a983c8284714d06e5d';
 assert.deepEqual(liveSyncSchools({SAARTHI_LIVE_SYNC_TEST_SCHOOL_ID:isolated,SAARTHI_LIVE_SYNC_SCHOOLS:B}),[B,isolated]);
});
