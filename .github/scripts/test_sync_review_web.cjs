// Actual Chromium UI against the isolated authenticated TEST cloud. Static
// review files are intercepted locally under the configured allowed web origin;
// no hosting deployment, production app request or production data is used.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path');
(async()=>{
 const school='vs-db8afb01a3be46a983c8284714d06e5d',run=process.env.GITHUB_RUN_ID;
 if(process.env.VS_TEST_CONNECT_CONFIRM!==school||process.env.GITHUB_ACTIONS!=='true')throw Error('Isolated hosted TEST runner required');
 const browser=await chromium.launch({headless:true});
 const context=await browser.newContext();
 const base=path.resolve('build/sync-review-web');
 await context.route('https://vidyasaarthi.web.app/**',async route=>{
  const relative=decodeURIComponent(new URL(route.request().url()).pathname).replace(/^\//,'')||'index.html';
  const file=path.resolve(base,relative);
  if(!file.startsWith(base+path.sep))throw Error('Invalid asset path');
  if(!fs.existsSync(file)){await route.fulfill({status:404,body:''});return;}
  const ext=path.extname(file),types={'.html':'text/html','.js':'application/javascript','.json':'application/json','.wasm':'application/wasm','.png':'image/png','.woff2':'font/woff2'};
  await route.fulfill({status:200,contentType:types[ext]||'application/octet-stream',body:fs.readFileSync(file)});
 });
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
 const network=[];
 context.on('request',request=>{const url=new URL(request.url());if(url.hostname==='identitytoolkit.googleapis.com'&&url.pathname.endsWith('signInWithPassword')){try{const body=JSON.parse(request.postData());network.push({stage:'auth-input-validation',emailMatches:body.email===process.env.VS_TEST_LOGIN_EMAIL.trim(),passwordMatches:body.password===process.env.VS_TEST_LOGIN_PASSWORD});}catch(_){network.push({stage:'auth-input-validation',validJson:false});}}});
 context.on('response',async response=>{const url=new URL(response.url());if(['saarthi-sync-v2-test.onrender.com','identitytoolkit.googleapis.com','securetoken.googleapis.com'].includes(url.hostname)){const entry={host:url.hostname,path:url.pathname,http:response.status()};if(url.hostname==='identitytoolkit.googleapis.com'&&response.status()>=400){try{const message=(await response.json()).error?.message;const allowed=['INVALID_LOGIN_CREDENTIALS','INVALID_EMAIL','MISSING_PASSWORD','MISSING_EMAIL','INVALID_PASSWORD','EMAIL_NOT_FOUND','TOO_MANY_ATTEMPTS_TRY_LATER','OPERATION_NOT_ALLOWED','API_KEY_HTTP_REFERRER_BLOCKED','API_KEY_INVALID','QUOTA_EXCEEDED'];entry.code=allowed.find(code=>typeof message==='string'&&(message===code||message.startsWith(code+' :')))||'OTHER_AUTH_ERROR';}catch(_){entry.code='UNREADABLE_AUTH_ERROR';}}network.push(entry);}});
 context.on('requestfailed',request=>{const url=new URL(request.url());if(['saarthi-sync-v2-test.onrender.com','identitytoolkit.googleapis.com','securetoken.googleapis.com'].includes(url.hostname))network.push({host:url.hostname,path:url.pathname,http:0});});
 const page=await context.newPage();
 async function typeField(label,value){
  const input=page.getByRole('textbox',{name:label,exact:true});
  await input.click();await input.press('ControlOrMeta+A');
  await input.pressSequentially(value,{delay:5});await input.press('Tab');
 }
 async function publishAndReadback(id){
  function requestBody(response){try{return JSON.parse(response.request().postData());}catch(_){return {};}}
  const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
  const writePromise=page.waitForResponse(response=>{const body=requestBody(response);return response.url()===endpoint&&body.action==='managed/records'&&body.operation==='write'&&body.collection==='school_notices'&&body.id===id;},{timeout:180000});
  const readPromise=page.waitForResponse(response=>{const body=requestBody(response);return response.url()===endpoint&&body.action==='managed/changes'&&body.collections?.includes('school_notices');},{timeout:180000});
  await page.getByRole('button',{name:'Publish TEST notice',exact:true}).click();
  const response=await writePromise,ack=await response.json(),body=requestBody(response);
  if(response.status()!==200||ack.success!==true||ack.schoolId!==school||ack.syncProtocol!==2||typeof ack.recordRevision!=='string'||!ack.recordRevision)throw Error('Verified TEST write ACK required');
  const read=await readPromise,reply=await read.json();
  if(read.status()!==200||reply.schoolId!==school||reply.syncProtocol!==2||!reply.changes?.school_notices)throw Error('Verified TEST post-write readback required');
  await page.getByText('Website ACK and readback verified',{exact:true}).waitFor({timeout:180000});
  return {operationId:body.operationId,recordRevision:ack.recordRevision,readbackVerified:true};
 }
 const proof={scope:'Hosted Chromium actual TEST school review UI, locally intercepted static build; authenticated TEST backend',schoolId:school,status:'RUNNING',stage:'load UI'};
 try {
  await page.goto('https://vidyasaarthi.web.app/',{waitUntil:'domcontentloaded'});
  proof.stage='TEST login';
  await typeField('TEST email',process.env.VS_TEST_LOGIN_EMAIL);
  await typeField('TEST password',process.env.VS_TEST_LOGIN_PASSWORD);
  await page.getByRole('button',{name:'Connect TEST school',exact:true}).click();
  await page.getByText('Cloud records verified',{exact:true}).waitFor({timeout:150000});
  await page.getByText(`synthetic-hosted-notice-${run} | Actual Windows local-first TEST notice`,{exact:true}).waitFor({timeout:30000});
  proof.windowsNoticeReadOnWebsite=true;
  const id=`synthetic-web-notice-${run}`,title=`Synthetic website exchange ${run}`;
  await typeField('Synthetic notice ID',id);
  await typeField('Synthetic notice title',title);
  proof.stage='offline draft save';
  proof.syntheticInputBeforeSave={id:await page.getByRole('textbox',{name:'Synthetic notice ID',exact:true}).inputValue(),title:await page.getByRole('textbox',{name:'Synthetic notice title',exact:true}).inputValue()};
  await context.setOffline(true);
  await page.getByRole('button',{name:'Publish TEST notice',exact:true}).click();
  await page.getByText('Cloud unavailable or verification failed; Sync pending. Retry unchanged; no ACK claimed.',{exact:true}).waitFor({timeout:90000});
  proof.offlineDiagnostic=await page.getByText(/^TEST diagnostic: /).allTextContents();
  proof.draftPersisted=await page.evaluate(()=>localStorage.getItem('flutter.isolated_sync_review_v1')!==null);
  proof.stage='reload draft recovery';
  await context.setOffline(false);
  await page.reload({waitUntil:'domcontentloaded'});
  await page.getByText('Local TEST session restored; refresh or retry pending sync',{exact:true}).waitFor({timeout:30000});
  proof.draftPersistedAfterReload=await page.evaluate(()=>localStorage.getItem('flutter.isolated_sync_review_v1')!==null);
  await page.getByRole('textbox',{name:'Synthetic notice ID',exact:true}).click();
  proof.restoredSyntheticId=await page.getByRole('textbox',{name:'Synthetic notice ID',exact:true}).inputValue();
  if(proof.restoredSyntheticId!==id)throw Error('Durable TEST draft mismatch');
  proof.offlineDraftAndReload=true;
  proof.stage='cloud retry ACK';
  const clock=performance.now();
  const first=await publishAndReadback(id);
  await page.getByText(`${id} | ${title}`,{exact:true}).waitFor();
  proof.websiteWriteAndReadbackMs=Math.round(performance.now()-clock);
  proof.stage='duplicate replay';
  const replay=await publishAndReadback(id);
  if(replay.operationId!==first.operationId||replay.recordRevision!==first.recordRevision)throw Error('Duplicate TEST operation identity/revision changed');
  proof.actualDuplicateAckAndReadback=true;
  if(await page.getByText(`${id} | ${title}`,{exact:true}).count()!==1)throw Error('Duplicate TEST row');
  proof.duplicateReplayAndReadback=true;
  proof.websiteNoticeId=id;proof.websiteNoticeTitle=title;proof.status='PASS';proof.stage='complete';
  await page.screenshot({path:'build/cloud-prerequisites/website-ui.png',fullPage:true});
 } catch(e){
  proof.status='FAIL';proof.network=network;
  proof.uiDiagnostic=await page.getByText(/^TEST diagnostic: /).allTextContents();
  // Never capture login credentials in failure screenshots.
  let cleared=true;
  for(const label of ['TEST password','TEST email']){const input=page.getByRole('textbox',{name:label,exact:true});if(await input.count())await input.fill('',{timeout:1000}).catch(()=>{cleared=false;});}
  if(cleared)await page.screenshot({path:'build/cloud-prerequisites/website-ui.png',fullPage:true}).catch(()=>{});
  console.log(JSON.stringify(proof));throw e;
 }
 finally {
  fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
  fs.writeFileSync('build/cloud-prerequisites/website-ui.json',JSON.stringify(proof));
  await context.close();await browser.close();
 }
})().catch(()=>{console.error('Isolated TEST website UI acceptance failed. No success claimed.');process.exitCode=1;});
