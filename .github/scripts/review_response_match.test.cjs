'use strict';
const {test} = require('node:test'), assert = require('node:assert/strict');
const {requestBody, matchesNoticeWrite, matchesNoticeRead} = require('./review_response_match.cjs');
const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud',school='vs-db8afb01a3be46a983c8284714d06e5d';
function response(body, method='POST', url=endpoint) {
  return {url:()=>url,request:()=>({method:()=>method,postData:()=>body})};
}
test('CORS preflight with null postData cannot crash or satisfy a write/read waiter',()=>{
  const preflight=response(null,'OPTIONS');
  assert.equal(JSON.parse(null),null); // Reproduces the previous parser failure.
  assert.deepEqual(requestBody(preflight),{});
  assert.equal(matchesNoticeWrite(preflight,endpoint,school,'notice'),false);
  assert.equal(matchesNoticeRead(preflight,endpoint,school),false);
});
test('null primitive array malformed and non-array collection bodies remain unmatched',()=>{
  for(const raw of [null,'null','true','42','[]','bad-json',JSON.stringify({schoolId:school,action:'managed/changes',collections:'school_notices'})]) {
    const r=response(raw);assert.equal(matchesNoticeWrite(r,endpoint,school,'notice'),false);assert.equal(matchesNoticeRead(r,endpoint,school),false);
  }
});
test('only exact own-school POST notice writes and reads match; ACK assertions stay separate',()=>{
  const write={schoolId:school,action:'managed/records',operation:'write',collection:'school_notices',id:'notice'};
  const read={schoolId:school,action:'managed/changes',collections:['school_notices']};
  assert.equal(matchesNoticeWrite(response(JSON.stringify(write)),endpoint,school,'notice'),true);
  assert.equal(matchesNoticeRead(response(JSON.stringify(read)),endpoint,school),true);
  for(const body of [{...write,schoolId:'foreign'},{...write,id:'other'},{...write,operation:'read'}])assert.equal(matchesNoticeWrite(response(JSON.stringify(body)),endpoint,school,'notice'),false);
  assert.equal(matchesNoticeRead(response(JSON.stringify({...read,schoolId:'foreign'})),endpoint,school),false);
  assert.equal(matchesNoticeRead(response(JSON.stringify(read),'GET'),endpoint,school),false);
  assert.equal(matchesNoticeRead(response(JSON.stringify(read),'POST','https://foreign.example'),endpoint,school),false);
});
