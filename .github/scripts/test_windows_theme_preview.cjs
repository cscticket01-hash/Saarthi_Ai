'use strict';
// Local fixture only: no developer login, live school, or external network is used.
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),http=require('node:http'),path=require('node:path');
const assert=require('node:assert/strict');
const root=path.resolve('build/web'),out=path.resolve('build/windows-theme-preview-review');
const pages=['dashboard','analytics','students','add-student','teachers','add-teacher','fees','fee-settings','salary','salary-history','fee-history','expenses','attendance','exams','exam-history','templates','school','admin','settings','advanced','support','devices','recycle','sync'];
(async()=>{
 await fs.mkdir(out,{recursive:true});
 const harness='<!doctype html><html><body style="margin:0"><iframe id="app" title="Windows preview" src="/windows-preview/" style="border:0;width:1440px;height:1000px"></iframe><script>window.previewReady=false;window.addEventListener("message",e=>{if(e.origin===location.origin&&e.source===document.querySelector("iframe").contentWindow&&JSON.parse(e.data).type==="vidya-preview-ready")window.previewReady=true;});</script></body></html>';
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
  for(const mode of ['dark','light'])for(const name of pages){
   await page.evaluate(({name,mode,navigation})=>document.querySelector('iframe').contentWindow.postMessage(JSON.stringify({type:'vidya-preview-theme',red:0,green:140,blue:120,mode,page:name,navigation}),location.origin),{name,mode,navigation:++navigation});
   await page.waitForTimeout(900);await page.screenshot({path:path.join(out,name+'-'+mode+'.png')});
  }
  await fs.writeFile(path.join(out,'report.json'),JSON.stringify({pages:pages.length,modes:2,screenshots:pages.length*2,errors,external},null,2));
  assert.deepEqual(external,[],'Preview must not contact a school/backend or external service');assert.deepEqual(errors,[],'Every preview page must render without runtime errors');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(e=>{console.error(e);process.exitCode=1;});
