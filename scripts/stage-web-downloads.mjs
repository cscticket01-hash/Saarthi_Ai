import {createHash} from 'node:crypto';
import {mkdir,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

const repo='cscticket01-hash/Saarthi_Ai';
export function selectInstaller(releases,platform) {
  const pattern=new RegExp(`^${platform}-v(\\d+)\\.(\\d+)\\.(\\d+)$`);
  return releases.filter(r=>!r.draft&&!r.prerelease&&pattern.test(r.tag_name))
    .sort((a,b)=>{const x=a.tag_name.match(pattern).slice(1).map(Number),y=b.tag_name.match(pattern).slice(1).map(Number);for(let i=0;i<3;i++){if(x[i]!==y[i])return y[i]-x[i];}return 0;})
    .flatMap(r=>(r.assets??[]).filter(a=>a.name.endsWith(platform==='windows'?'.exe':'.apk')).map(a=>({...a,tag:r.tag_name})))
    .find(a=>{try{const u=new URL(a.browser_download_url);return u.protocol==='https:'&&u.host==='github.com'&&u.pathname.startsWith(`/${repo}/releases/download/${a.tag}/`);}catch{return false;}});
}
export function verifyInstaller(asset,bytes,platform) {
  const sha=createHash('sha256').update(bytes).digest('hex');
  if(bytes.length!==asset.size||bytes.length<10000||asset.digest!==`sha256:${sha}`)throw Error(`${platform}: release size/hash verification failed`);
  if(platform==='windows'?(bytes[0]!==0x4d||bytes[1]!==0x5a):(bytes[0]!==0x50||bytes[1]!==0x4b))throw Error(`${platform}: invalid installer signature`);
  return sha;
}
async function main() {
  const releases=[];
  for(let page=1;page<=5;page++){
    const response=await fetch(`https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}`,{headers:{Accept:'application/vnd.github+json',...(process.env.GH_TOKEN?{Authorization:`Bearer ${process.env.GH_TOKEN}`}:{})},signal:AbortSignal.timeout(30000)});
    if(!response.ok)throw Error(`Release lookup failed: ${response.status}`);
    const batch=await response.json();releases.push(...batch);if(batch.length<100)break;
  }
  const directory=process.argv[2]??'build/web/downloads';await mkdir(directory,{recursive:true});
  const manifest={};
  for(const platform of ['windows','android']){
    const asset=selectInstaller(releases,platform);if(!asset)throw Error(`No production ${platform} installer`);
    const response=await fetch(asset.browser_download_url,{signal:AbortSignal.timeout(180000)});
    if(!response.ok)throw Error(`${platform}: download failed: ${response.status}`);
    const bytes=Buffer.from(await response.arrayBuffer()),sha256=verifyInstaller(asset,bytes,platform);
    const filename=platform==='windows'?'windows.exe':'android.apk';
    await writeFile(`${directory}/${filename}`,bytes);
    manifest[platform]={version:asset.tag,filename:asset.name,url:`/downloads/${filename}`,size:bytes.length,sha256};
    console.log(`Verified ${asset.tag}: ${bytes.length} bytes (${sha256})`);
  }
  await writeFile(`${directory}/releases.json`,JSON.stringify(manifest,null,2)+'\n');
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await main();
