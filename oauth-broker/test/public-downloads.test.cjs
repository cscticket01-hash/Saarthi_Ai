const test=require('node:test'),assert=require('node:assert/strict');
const {createHash}=require('node:crypto'),{mkdtemp,rm}=require('node:fs/promises'),os=require('node:os'),path=require('node:path'),http=require('node:http');
const {createInstallerHandler,selectInstaller}=require('../public-downloads.cjs');
const make=(version='2.1.165')=>({tag_name:'windows-v'+version,assets:[{name:'Setup.exe',browser_download_url:`https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/windows-v${version}/Setup.exe`}]});
test('numeric selection rejects foreign URLs and drafts',()=>{const bad=make('9.0.0');bad.assets[0].browser_download_url='https://example.com/setup.exe';assert.equal(selectInstaller([make('2.1.99'),make(),{...make('3.0.0'),draft:true},bad],'windows').tag,'windows-v2.1.165');});
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
