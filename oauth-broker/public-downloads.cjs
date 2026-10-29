'use strict';
const {createHash,randomUUID}=require('node:crypto');
const fs=require('node:fs');
const fsp=require('node:fs/promises');
const os=require('node:os');
const path=require('node:path');
const {pipeline}=require('node:stream/promises');
const repo='cscticket01-hash/Saarthi_Ai';
// Verified release fallback keeps downloads available when GitHub rate-limits shared hosting IPs.
const verifiedReleases=[{"tag_name":"windows-v2.1.199","assets":[{"name":"Vidya_Saarthi_Setup_2.1.199.exe","size":19479280,"digest":"sha256:dc021e64bd20b569ba7afb9e280628084c03fcd07b58e5b016cdbb05eeba92e7","browser_download_url":"https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/windows-v2.1.199/Vidya_Saarthi_Setup_2.1.199.exe"}]},{"tag_name":"android-v1.0.636","assets":[{"name":"Vidya-Saarthi-v1.0.636.apk","size":70962001,"digest":"sha256:9ba82c885a841511c1652e0fa463bb2e457373cb0d892d55c0863d787dd54cbb","browser_download_url":"https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/android-v1.0.636/Vidya-Saarthi-v1.0.636.apk"}]}];
function selectInstaller(releases,platform){
 const re=new RegExp(`^${platform}-v(\\d+)\\.(\\d+)\\.(\\d+)$`);
 return releases.filter(r=>!r.draft&&!r.prerelease&&re.test(r.tag_name)).sort((a,b)=>{
  const x=a.tag_name.match(re).slice(1).map(Number),y=b.tag_name.match(re).slice(1).map(Number);
  for(let i=0;i<3;i++)if(x[i]!==y[i])return y[i]-x[i];return 0;
 }).flatMap(r=>(r.assets||[]).filter(a=>a.name.endsWith(platform==='windows'?'.exe':'.apk')).map(a=>({...a,tag:r.tag_name})))
 .find(a=>{try{const u=new URL(a.browser_download_url);return u.protocol==='https:'&&u.host==='github.com'&&u.pathname.startsWith(`/${repo}/releases/download/${a.tag}/`);}catch{return false;}});
}
function createInstallerHandler({fetchImpl=fetch,directory=path.join(os.tmpdir(),'saarthi-public-installers'),now=Date.now}={}){
 let releaseCache,releaseUntil=0,lookup;
 const pending=new Map(),cached=new Map();
 async function releases(){
  if(releaseCache&&now()<releaseUntil)return releaseCache;
  if(!lookup)lookup=(async()=>{const r=await fetchImpl(`https://api.github.com/repos/${repo}/releases?per_page=100`,{signal:AbortSignal.timeout(30000),headers:{Accept:'application/vnd.github+json','User-Agent':'Vidya-Saarthi-Downloads'}});if(r.status===403||r.status===429){releaseCache=releaseCache||verifiedReleases;releaseUntil=now()+300000;return releaseCache;}if(!r.ok)throw Error('release_lookup_'+r.status);const list=await r.json();if(!Array.isArray(list))throw Error('release_lookup');releaseCache=list;releaseUntil=now()+300000;return list;})().finally(()=>lookup=null);
  return lookup;
 }
 async function installer(platform){
  const asset=selectInstaller(await releases(),platform);
  if(!asset||!/^sha256:[a-f0-9]{64}$/.test(asset.digest)||!Number.isSafeInteger(asset.size)||asset.size<10000||asset.size>150000000)throw Error('invalid_release');
  const hash=asset.digest.slice(7),key=platform+':'+hash;
  if(cached.get(platform)?.hash===hash)return cached.get(platform);
  if(!pending.has(key))pending.set(key,(async()=>{
   await fsp.mkdir(directory,{recursive:true});const file=path.join(directory,platform+'-'+hash),temp=file+'.'+randomUUID()+'.part';
   try{
    const r=await fetchImpl(asset.browser_download_url,{signal:AbortSignal.timeout(180000)});if(!r.ok||!r.body)throw Error('download_failed_'+r.status);
    const handle=await fsp.open(temp,'wx',0o600),digest=createHash('sha256');let size=0,prefix=Buffer.alloc(0);
    try{for await(const raw of r.body){const chunk=Buffer.from(raw);size+=chunk.length;if(size>asset.size)throw Error('size_mismatch');digest.update(chunk);if(prefix.length<2)prefix=Buffer.concat([prefix,chunk.subarray(0,2-prefix.length)]);await handle.writeFile(chunk);}}finally{await handle.close();}
    if(size!==asset.size||digest.digest('hex')!==hash||!(platform==='windows'?prefix.equals(Buffer.from('MZ')):prefix.equals(Buffer.from('PK'))))throw Error('integrity_failure');
    await fsp.rename(temp,file);const previous=cached.get(platform);const item={file,size,hash,tag:asset.tag};cached.set(platform,item);
    if(previous&&previous.file!==file)await fsp.unlink(previous.file).catch(()=>{});
    return item;
   }catch(e){await fsp.unlink(temp).catch(()=>{});throw e;}
  })().finally(()=>pending.delete(key)));
  return pending.get(key);
 }
 return async function(req,res){
  const platform={'/downloads/windows.exe':'windows','/downloads/android.apk':'android'}[req.url?.split('?')[0]];
  if(!platform)return false;
  if(!['GET','HEAD'].includes(req.method)){res.writeHead(405,{Allow:'GET, HEAD'});res.end();return true;}
  try{
   const item=await installer(platform);let start=0,end=item.size-1,status=200;
   if(req.headers.range){const m=/^bytes=(\d+)-(\d*)$/.exec(req.headers.range);if(!m||(+m[1])>=item.size||m[2]&&(+m[2])<(+m[1])){res.writeHead(416,{'Content-Range':`bytes */${item.size}`});res.end();return true;}start=+m[1];end=m[2]?Math.min(+m[2],end):end;status=206;}
   const headers={'Content-Type':'application/octet-stream','Content-Disposition':`attachment; filename="${platform==='windows'?'Vidya_Saarthi_Setup.exe':'Vidya_Saarthi_Student.apk'}"`,'Content-Length':end-start+1,'X-Content-Type-Options':'nosniff','Cache-Control':'no-cache','Accept-Ranges':'bytes',ETag:`"${item.hash}"`,'X-Saarthi-Release':item.tag};
   if(status===206)headers['Content-Range']=`bytes ${start}-${end}/${item.size}`;
   res.writeHead(status,headers);if(req.method==='HEAD'){res.end();return true;}
   await pipeline(fs.createReadStream(item.file,{start,end}),res);
  }catch(error){console.error(JSON.stringify({event:'public_download_failure',platform,code:/^(release_lookup_\d{3}|download_failed_\d{3}|invalid_release|integrity_failure|size_mismatch)$/.test(error.message)?error.message:'download_internal'}));if(!res.headersSent){res.writeHead(503,{'Content-Type':'text/plain','Retry-After':'30','X-Download-Error':/^(release_lookup_\d{3}|download_failed_\d{3}|invalid_release|integrity_failure|size_mismatch)$/.test(error.message)?error.message:'download_internal'});res.end('Download temporarily unavailable. Please try again shortly.');}else res.destroy();}
  return true;
 };
}
module.exports={createInstallerHandler,selectInstaller};
