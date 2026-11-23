'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const root='.github/workflows/';
const read=name=>fs.readFileSync(root+name,'utf8');
function condition(src,job){
  const lines=src.split('\n');
  const key=lines.findIndex(l=>l.trim()===job+':');
  assert.ok(key>=0,'missing job: '+job);
  const slice=lines.slice(key+1,key+12).join('\n');
  const line=slice.split('\n').find(l=>/^\s+if:\s/.test(l));
  assert.ok(line,'job '+job+' must have publication guard');
  return line.trim().replace(/^if:\s*/,'');
}
test('unmarked main merge cannot publish a native Windows build',()=>{
 const text=condition(read('build-windows.yml'),'build-windows');
 assert.match(text,/github\.event_name\s*==\s*'workflow_dispatch'/);
 assert.match(text,/contains\(github\.event\.head_commit\.message, '\[windows-release\]'\)/);
 assert.doesNotMatch(text,/github\.ref\s*!=/);
 assert.doesNotMatch(text,/github\.event_name\s*!=\s*'push'/);
});
test('unmarked main merge cannot publish a signed Android APK',()=>{
 const text=condition(read('build-apk.yml'),'build');
 assert.match(text,/github\.event_name\s*==\s*'workflow_dispatch'/);
 assert.match(text,/contains\(github\.event\.head_commit\.message, '\[android-release\]'\)/);
 assert.doesNotMatch(text,/github\.ref\s*!=/);
 assert.doesNotMatch(text,/github\.event_name\s*!=\s*'push'/);
});
test('hosting and Firestore rules do not publish from unmarked source merges',()=>{
 const src=read('web.yml');
 const verify=condition(src,'verify-rules');
 const deploy=condition(src,'build-and-deploy');
 assert.equal(verify,deploy,'website rules/security and hosting must share one gate');
 assert.match(deploy,/\[developer-release\]/);
 assert.match(deploy,/\[hosting-only\]/);
 assert.match(deploy,/\[windows-only\]/);
 assert.match(deploy,/workflow_dispatch/);
 assert.doesNotMatch(deploy,/github\.event_name\s*!=\s*'push'/);
 assert.match(src,/if: "!contains\(github\.event\.head_commit\.message, '\[hosting-only\]'\)"/);
});
