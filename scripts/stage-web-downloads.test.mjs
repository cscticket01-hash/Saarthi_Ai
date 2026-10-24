import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {selectInstaller,verifyInstaller} from './stage-web-downloads.mjs';
const release=(tag,extra={})=>({tag_name:tag,assets:[{name:tag.startsWith('windows')?'Setup.exe':'Student.apk',browser_download_url:`https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/${tag}/asset`}],...extra});
test('numeric production selection is separate for each platform and rejects external links',()=>{
  const bad=release('windows-v9.0.0');bad.assets[0].browser_download_url='https://example.com/file.exe';
  const rows=[release('android-v1.0.597'),release('windows-v2.1.99'),release('windows-v2.1.165'),release('windows-v3.0.0',{draft:true}),bad];
  assert.equal(selectInstaller(rows,'windows').tag,'windows-v2.1.165');
  assert.equal(selectInstaller(rows,'android').tag,'android-v1.0.597');
});
test('staging rejects corrupt, incomplete and non-installer downloads',()=>{
  const bytes=Buffer.alloc(12000);bytes.write('MZ');const digest='sha256:'+createHash('sha256').update(bytes).digest('hex');const asset={size:bytes.length,digest};
  assert.equal(verifyInstaller(asset,bytes,'windows'),digest.slice(7));
  assert.throws(()=>verifyInstaller({...asset,size:1},bytes,'windows'));
  assert.throws(()=>verifyInstaller(asset,Buffer.from('error page'),'windows'));
  assert.throws(()=>verifyInstaller(asset,bytes,'android'));
});
