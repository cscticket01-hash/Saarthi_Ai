const test=require('node:test'),assert=require('node:assert/strict');
const {createHash}=require('node:crypto'),{mkdtemp,rm}=require('node:fs/promises'),os=require('node:os'),path=require('node:path'),http=require('node:http');
const {createInstallerHandler,selectInstaller}=require('../public-downloads.cjs');
const make=(version='2.1.165')=>({tag_name:'windows-v'+version,assets:[{name:`Vidya_Saarthi_Setup_${version}.exe`,browser_download_url:`https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/windows-v${version}/Vidya_Saarthi_Setup_${version}.exe`}]});
test('rate-limited release lookup uses only verified fallback and still rejects corrupt bytes',async()=>{
 for(const status of [403,429]){
  const directory=await mkdtemp(path.join(os.tmpdir(),'saarthi-fallback-test-'));const urls=[];
  const handler=createInstallerHandler({directory,fetchImpl:async url=>{urls.push(url);return url.includes('api.github.com')?new Response('{}',{status}):new Response('bad file');}});
  const server=http.createServer(async(req,res)=>{await handler(req,res);});await new Promise(r=>server.listen(0,'127.0.0.1',r));
  try{const r=await fetch('http://127.0.0.1:'+server.address().port+'/downloads/windows.exe');assert.equal(r.status,503);assert.equal(r.headers.get('content-disposition'),null);assert.match(urls[1],/^https:\/\/github\.com\/cscticket01-hash\/Saarthi_Ai\/releases\/download\/windows-v2\.1\.270\/Vidya_Saarthi_Setup_2\.1\.270\.exe$/);}
  finally{server.closeAllConnections();await new Promise(r=>server.close(r));await rm(directory,{recursive:true,force:true});}
 }
});
test('numeric selection rejects foreign URLs and drafts',()=>{const bad=make('9.0.0');bad.assets[0].browser_download_url='https://example.com/setup.exe';assert.equal(selectInstaller([make('2.1.99'),make(),{...make('3.0.0'),draft:true},bad],'windows').tag,'windows-v2.1.165');});
test('Windows download ignores unrelated EXE and mismatched release version',()=>{
 const unrelated=make('2.1.999');
 unrelated.assets[0].name='other.exe';
 unrelated.assets[0].browser_download_url='https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/windows-v2.1.999/other.exe';
 const mismatched=make('2.1.998');
 mismatched.assets[0].browser_download_url=mismatched.assets[0].browser_download_url.replace('windows-v2.1.998/','windows-v2.1.997/');
 assert.equal(selectInstaller([unrelated,mismatched,make('2.1.269')],'windows').tag,'windows-v2.1.269');
});
async function serve(corrupt,fn){
 const bytes=Buffer.alloc(12000);bytes.write('MZ');const release=make();release.assets[0].size=bytes.length;release.assets[0].digest='sha256:'+createHash('sha256').update(bytes).digest('hex');
 const directory=await mkdtemp(path.join(os.tmpdir(),'saarthi-download-test-'));let reads=0;
 const handler=createInstallerHandler({directory,fetchImpl:async url=>url.includes('api.github.com')?new Response(JSON.stringify([release])):(reads++,new Response(corrupt?'bad file':bytes))});
 const server=http.createServer(async(req,res)=>{if(!await handler(req,res)){res.writeHead(404);res.end();}});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try{await fn('http://127.0.0.1:'+server.address().port,bytes,()=>reads);}finally{server.closeAllConnections();await new Promise(r=>server.close(r));await rm(directory,{recursive:true,force:true});}
}
test('verified file stays server-side, supports retry/ranges, and never redirects to GitHub',()=>serve(false,async(base,bytes,reads)=>{
 const r=await fetch(base+'/downloads/windows.exe');assert.equal(r.status,200);assert.match(r.headers.get('content-disposition'),/attachment/);assert.equal(r.headers.get('location'),null);assert.deepEqual(Buffer.from(await r.arrayBuffer()),bytes);
 const range=await fetch(base+'/downloads/windows.exe',{headers:{Range:'bytes=0-1'}});assert.equal(range.status,206);assert.equal(await range.text(),'MZ');assert.equal(reads(),1);
 const missing=await fetch(base+'/downloads/unknown');assert.equal(missing.status,404);
}));
test('bad upstream bytes cannot be delivered as an installer',()=>serve(true,async base=>{const r=await fetch(base+'/downloads/windows.exe');assert.equal(r.status,503);assert.equal(r.headers.get('content-disposition'),null);}));


test('website CORS permits only the public login origins and not other sites',()=>serve(false,async(base,bytes)=>{
 const allowed=await fetch(base+'/downloads/windows.exe',{headers:{Origin:'https://vidyasaarthi.web.app'}});
 assert.equal(allowed.status,200);
 assert.equal(allowed.headers.get('access-control-allow-origin'),'https://vidyasaarthi.web.app');
 assert.match(allowed.headers.get('access-control-expose-headers'),/Content-Length/);
 assert.deepEqual(Buffer.from(await allowed.arrayBuffer()),bytes);
 const denied=await fetch(base+'/downloads/windows.exe',{headers:{Origin:'https://malicious.example'}});
 assert.equal(denied.status,200);
 assert.equal(denied.headers.get('access-control-allow-origin'),null);
 const preflight=await fetch(base+'/downloads/windows.exe',{method:'OPTIONS',headers:{Origin:'https://vidyasaarthi.web.app'}});
 assert.equal(preflight.status,204);
 assert.equal(preflight.headers.get('access-control-allow-origin'),'https://vidyasaarthi.web.app');
 const unknownPreflight=await fetch(base+'/downloads/windows.exe',{method:'OPTIONS',headers:{Origin:'https://unknown.example'}});
 assert.equal(unknownPreflight.status,403);
 const unrelated=await fetch(base+'/school-cloud',{headers:{Origin:'https://vidyasaarthi.web.app'}});
 assert.equal(unrelated.status,404);
 assert.equal(unrelated.headers.get('access-control-allow-origin'),null);
}));
