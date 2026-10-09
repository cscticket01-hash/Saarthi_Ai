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
 context.on('response',response=>{const url=new URL(response.url());if(['saarthi-sync-v2-test.onrender.com','identitytoolkit.googleapis.com','securetoken.googleapis.com'].includes(url.hostname))network.push({host:url.hostname,path:url.pathname,http:response.status()});});
 context.on('requestfailed',request=>{const url=new URL(request.url());if(['saarthi-sync-v2-test.onrender.com','identitytoolkit.googleapis.com','securetoken.googleapis.com'].includes(url.hostname))network.push({host:url.hostname,path:url.pathname,http:0});});
 const page=await context.newPage();
 const proof={scope:'Hosted Chromium actual TEST school review UI, locally intercepted static build; authenticated TEST backend',schoolId:school,status:'RUNNING',stage:'load UI'};
 try {
  await page.goto('https://vidyasaarthi.web.app/',{waitUntil:'domcontentloaded'});
  proof.stage='TEST login';
  await page.getByRole('textbox',{name:'TEST email',exact:true}).fill(process.env.VS_TEST_LOGIN_EMAIL);
  await page.getByRole('textbox',{name:'TEST password',exact:true}).fill(process.env.VS_TEST_LOGIN_PASSWORD);
  await page.getByRole('button',{name:'Connect TEST school',exact:true}).click();
  await page.getByText('Cloud records verified',{exact:true}).waitFor({timeout:150000});
  await page.getByText(`synthetic-hosted-notice-${run} | Actual Windows local-first TEST notice`,{exact:true}).waitFor({timeout:30000});
  proof.windowsNoticeReadOnWebsite=true;
  const id=`synthetic-web-notice-${run}`,title=`Synthetic website exchange ${run}`;
  await page.getByRole('textbox',{name:'Synthetic notice ID',exact:true}).fill(id);
  await page.getByRole('textbox',{name:'Synthetic notice title',exact:true}).fill(title);
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
  await page.getByRole('button',{name:'Publish TEST notice',exact:true}).click();
  await page.getByText('Website ACK and readback verified',{exact:true}).waitFor({timeout:180000});
  await page.getByText(`${id} | ${title}`,{exact:true}).waitFor();
  proof.websiteWriteAndReadbackMs=Math.round(performance.now()-clock);
  proof.stage='duplicate replay';
  await page.getByRole('button',{name:'Publish TEST notice',exact:true}).click();
  await page.getByText('Website ACK and readback verified',{exact:true}).waitFor({timeout:180000});
  if(await page.getByText(`${id} | ${title}`,{exact:true}).count()!==1)throw Error('Duplicate TEST row');
  proof.duplicateReplayAndReadback=true;
  proof.websiteNoticeId=id;proof.websiteNoticeTitle=title;proof.status='PASS';proof.stage='complete';
  await page.screenshot({path:'build/cloud-prerequisites/website-ui.png',fullPage:true});
 } catch(e){
  proof.status='FAIL';proof.network=network;
  proof.uiDiagnostic=await page.getByText(/^TEST diagnostic: /).allTextContents();
  // Never capture login credentials in failure screenshots.
  await page.getByRole('textbox',{name:'TEST password',exact:true}).fill('').catch(()=>{});
  await page.getByRole('textbox',{name:'TEST email',exact:true}).fill('').catch(()=>{});
  await page.screenshot({path:'build/cloud-prerequisites/website-ui.png',fullPage:true}).catch(()=>{});
  console.log(JSON.stringify(proof));throw e;
 }
 finally {
  fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
  fs.writeFileSync('build/cloud-prerequisites/website-ui.json',JSON.stringify(proof));
  await context.close();await browser.close();
 }
})().catch(()=>{console.error('Isolated TEST website UI acceptance failed. No success claimed.');process.exitCode=1;});
