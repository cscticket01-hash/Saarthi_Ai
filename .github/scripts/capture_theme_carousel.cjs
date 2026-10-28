'use strict';
// Local fixture only: no developer login, live school, or external network is used.
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),http=require('node:http'),path=require('node:path');
const assert=require('node:assert/strict');
const root=path.resolve('build/web'),out=path.resolve('assets');
const pages=['dashboard','students','fees','settings'];
const presets=[['neon-teal',0,217,192,'dark'],['electric-blue',22,139,255,'dark'],['mint-light',0,140,120,'light'],['sunset-ember',255,112,91,'dark'],['aurora-violet',139,92,255,'dark'],['emerald-gold',216,187,101,'dark']];
(async()=>{
 await fs.mkdir(out,{recursive:true});
 const harness='<!doctype html><html><body style="margin:0"><iframe id="app" title="Windows preview" src="/windows-preview/" style="border:0;width:1440px;height:1000px"></iframe><script>window.previewReady=false;window.addEventListener("message",e=>{if(e.origin===location.origin&&e.source===document.querySelector("iframe").contentWindow&&typeof e.data==="string"){const data=JSON.parse(e.data);if(data.type==="vidya-preview-ready")window.previewReady=true;if(data.type==="vidya-preview-applied")window.previewApplied=data;}});</script></body></html>';
 const types={'.html':'text/html','.js':'text/javascript','.json':'application/json','.wasm':'application/wasm','.png':'image/png','.ttf':'font/ttf'};
 const config=JSON.parse(await fs.readFile('firebase.json','utf8'));const csp=config.hosting.headers.find(h=>h.source==='/windows-preview/**').headers.find(h=>h.key==='Content-Security-Policy').value;
 const server=http.createServer(async(req,res)=>{try{
  if(req.url==='/preview-harness.html'){res.setHeader('Content-Type','text/html');res.end(harness);return;}
  const clean=decodeURIComponent(new URL(req.url,'http://localhost').pathname);const file=path.resolve(root,'.'+clean+(clean.endsWith('/')?'index.html':''));
  if(!file.startsWith(root+path.sep))throw Error('path');res.setHeader('Content-Type',types[path.extname(file)]||'application/octet-stream');
  if(clean.startsWith('/windows-preview/'))res.setHeader('Content-Security-Policy',csp);
  res.end(await fs.readFile(file));
 }catch(_){res.writeHead(404);res.end('Not found');}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin='http://127.0.0.1:'+server.address().port;
 const browser=await chromium.launch({headless:true});
 const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
 const errors=[],external=[];const page=await context.newPage();
 page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error'&&/Exception|Unsupported operation|RenderFlex|FlutterError|Error:/.test(m.text()))errors.push(m.text());});
 await context.route('**/*',route=>{if(new URL(route.request().url()).origin!==origin){external.push(route.request().url());return route.abort();}return route.continue();});
 try{
  await page.goto(origin+'/preview-harness.html');await page.waitForFunction(()=>window.previewReady,null,{timeout:120000});
  let navigation=0;
  for(const [presetId,red,green,blue,mode] of presets)for(const name of pages){
   await page.evaluate(({name,mode,navigation,presetId,red,green,blue})=>document.querySelector('iframe').contentWindow.postMessage(JSON.stringify({type:'vidya-preview-theme',red,green,blue,presetId,mode,page:name,navigation}),location.origin),{name,mode,navigation:++navigation,presetId,red,green,blue});
   await page.waitForFunction(({name,mode,navigation})=>window.previewApplied?.page===name&&window.previewApplied?.mode===mode&&window.previewApplied?.navigation===navigation,{name,mode,navigation},{timeout:15000});
   await page.waitForTimeout(700);await page.screenshot({path:path.join(out,`theme_preview_${presetId}_${name}.png`),clip:{x:0,y:44,width:1440,height:956}});
  }
  await fs.writeFile('build/theme-carousel-report.json',JSON.stringify({pages:pages.length,presets:presets.length,screenshots:pages.length*presets.length,errors,external},null,2));
  assert.deepEqual(external,[],'Preview must not contact a school/backend or external service');assert.deepEqual(errors,[],'Every preview page must render without runtime errors');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(e=>{console.error(e);process.exitCode=1;});
