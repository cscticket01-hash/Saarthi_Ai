'use strict';
const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');
const config=JSON.parse(readFileSync('firebase.json','utf8'));
const redirects=config.hosting.redirects||[];
const expected={
  '/downloads/windows.exe':/^https:\/\/github\.com\/cscticket01-hash\/Saarthi_Ai\/releases\/download\/windows-v\d+\.\d+\.\d+\/Vidya_Saarthi_Setup_\d+\.\d+\.\d+\.exe$/,
  '/downloads/android.apk':/^https:\/\/github\.com\/cscticket01-hash\/Saarthi_Ai\/releases\/download\/android-v\d+\.\d+\.\d+\/Vidya-Saarthi-v\d+\.\d+\.\d+\.apk$/,
};
for(const [route,pattern] of Object.entries(expected)){
 const matches=redirects.filter(x=>x.source===route);
 assert.equal(matches.length,1,'Exactly one redirect for '+route);
 assert.equal(matches[0].type,302);
 assert.match(matches[0].destination,pattern);
 assert(!matches[0].destination.includes('onrender.com'),'No sleeping Render downloader');
}
console.log('Both direct download routes bypass Render and target official immutable releases');
