(() => {
  'use strict';
  const token = document.querySelector('meta[name="lab-session"]').content;
  const $ = selector => document.querySelector(selector);
  const number = value => value === null || value === undefined ? '—' : Number(value).toLocaleString('en-IN', { maximumFractionDigits: 2 });
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
  const badge = state => `<span class="badge" data-state="${escape(state)}">${escape(state)}</span>`;
  let state = null, selectedRun = null, queue = [], runningQueue = false, stoppedQueue = false, dispatching = false;
  const chosen = new Set(['attendance']);
  async function api(path, data, download = false) {
    const response = await fetch(path, {method: data === undefined ? 'GET' : 'POST',
      headers: {'X-Lab-Token': token, ...(data === undefined ? {} : {'Content-Type':'application/json'})},
      body: data === undefined ? undefined : JSON.stringify(data)});
    if (!response.ok) { const error = await response.json(); throw new Error(error.error || 'Request failed'); }
    return download ? response.blob() : response.json();
  }
  function notice(text, error=false) { const panel = $('#notice'); panel.textContent=text; panel.classList.toggle('error',error); panel.hidden=false; }
  async function download(path, filename) {
    try { const blob = await api(path,undefined,true); const url = URL.createObjectURL(blob); const a = document.createElement('a'); a.href=url; a.download=filename; a.click(); setTimeout(()=>URL.revokeObjectURL(url),1000); }
    catch(error) { notice(error.message,true); }
  }
  function latest(scenario) { return state.jobs.find(job=>job.scenario===scenario); }
  function options() { return {count:Number($('#student-count').value),start:Number($('#start-student').value),concurrency:Number($('#concurrency').value),rate:Number($('#rate').value),timeout:Number($('#timeout').value),max_p95_ms:Number($('#p95').value),gb:Number($('#volume').value),auto_seed:$('#auto-seed').checked}; }
  function render() {
    const base = state.dataset, active = state.jobs.find(j=>j.state==='RUNNING');
    $('#base-count').textContent=number(base.count); $('#base-status').textContent=base.ready?'READY':active?.scenario==='base_generate'?'GENERATING':'NOT GENERATED';
    $('#base-progress').textContent=base.ready?'100,000 persisted unique test identities':`${number(base.count)} / 1,00,000 identities persisted`;
    $('#generate-base').disabled=Boolean(active)||base.ready;
    $('#run-tests').disabled=Boolean(active)||runningQueue;
    $('#stop-test').disabled=!active&&!runningQueue;
    $('#environment').textContent=state.school.connected?state.school.project_id:state.firebase.connected?`${state.firebase.project_id} · Firebase only`:'Test school not connected';
    $('#firebase-state').textContent=state.firebase.connected?`Firebase verified · ${state.firebase.project_id} · Email/Password + admin claim + Firestore read · ${number(state.firebase.connection_ms)} ms`:'Firebase: not checked.';
    $('#school-state').textContent=state.school.connected?`Verified test backend · Licence ${state.school.license_allowed?'active':'required'} · School ${state.school.school_open?'open':'closed'}`:'School backend: not connected. Attendance, student add and fees require the test Apps Script backend.';
    $('#run-progress').hidden=!active;
    if(active){$('#run-phase').textContent=active.phase;$('#run-completed').textContent=`${number(active.completed)} completed · ${number(active.duration_seconds)} s`;$('#progress').max=active.requested||100000;$('#progress').value=Math.min(active.completed,$('#progress').max);}
    $('#test-rows').innerHTML=Object.entries(state.scenarios).map(([key,spec])=>{
      const job=latest(key), metric=job?.metrics||{};
      const quantity=key.startsWith('volume_')?`${number(job?.config.gb??Number($('#volume').value))} GB`:['windows_ui','android_ui'].includes(key)?(job?`${number(job.config.count)} steps`:'Configured UI scenario'):`${number(job?.config.count??Number($('#student-count').value))} ${escape(spec.unit)}`;
      const saved=metric.saved_records??metric.bytes_verified??metric.verified_sessions;
      return `<tr class="${job?.id===selectedRun?'selected-row':''}"><td><input type="checkbox" aria-label="Select ${escape(spec.label)}" data-scenario="${key}" ${chosen.has(key)?'checked':''}></td><td>${escape(spec.label)}<small>${escape(spec.target)}</small></td><td>${quantity}</td><td>${badge(job?.state||'NOT RUN')}</td><td>${job?number(job.duration_seconds)+' s':'—'}</td><td>${job?.avg_ms!=null?number(job.avg_ms)+' / '+number(job.p95_ms)+' ms':'—'}</td><td>${saved!=null?number(saved):'—'} / ${job?number(job.failed):'—'}</td><td><button data-run="${job?.id||''}" ${job?'':'disabled'}>View</button></td></tr>`;
    }).join('');
    $('#base-info').innerHTML=[['Persisted students',number(base.count)],['Target',number(base.target)],['Dataset ID',base.dataset_id],['SQLite size',number(base.bytes)+' bytes'],['State',base.ready?'Ready':'Generation required']].map(([k,v])=>`<div><dt>${escape(k)}</dt><dd>${escape(v)}</dd></div>`).join('');
    $('#report-rows').innerHTML=state.jobs.map(job=>`<tr><td>${escape(state.scenarios[job.scenario]?.label||'Student base generation')}<small>${escape(new Date(job.created_at).toLocaleString())}</small></td><td>${escape(job.target)}</td><td>${badge(job.state)}</td><td>${number(job.duration_seconds)} s</td><td><button data-run="${job.id}" data-report="true">View</button> <button data-download="${job.id}">JSON</button></td></tr>`).join('');
    const job=state.jobs.find(j=>j.id===selectedRun)||state.jobs.find(j=>j.scenario!=='base_generate');
    if(job){renderEvidence(job);renderChart(job);}
    $('#install-browser').disabled=state.browser_setup_running;
    if(runningQueue&&!active&&!dispatching){advanceQueue();}
  }
  function renderEvidence(job) {
    const metrics=job.metrics;
    const pairs=[['Records saved',metrics.saved_records],['Missing records',metrics.missing_records],['Duplicate records',metrics.duplicate_records],['Verified bytes',metrics.bytes_verified],['Actual HTTP requests',metrics.http_requests],['Preparation time',metrics.preparation_seconds],['Verification time',metrics.verification_seconds]];
    $('#verification-empty').hidden=true;
    $('#quick-verification').innerHTML=pairs.filter(([,v])=>v!=null).map(([k,v])=>`<div><dt>${escape(k)}</dt><dd>${number(v)}</dd></div>`).join('')||'<div><dt>Saved-data check</dt><dd>Not applicable / not yet measured</dd></div>';
  }
  function renderChart(job) {
    const values=job.timeline;
    if(!values.length){$('#chart').textContent='No measured time-series samples yet';return;}
    const width=600,height=170,left=45,top=15,right=12,bottom=30;
    const maxX=Math.max(...values.map(v=>v.seconds),1),maxY=Math.max(...values.map(v=>v.per_second),1);
    const x=v=>left+v/maxX*(width-left-right), y=v=>height-bottom-v/maxY*(height-top-bottom);
    const path=values.map((v,i)=>`${i?'L':'M'} ${x(v.seconds).toFixed(2)} ${y(v.per_second).toFixed(2)}`).join(' ');
    $('#chart').innerHTML=`<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="Actual completed journeys per second over elapsed time"><path d="M ${left} ${top} V ${height-bottom} H ${width-right}" fill="none" stroke="#9baac0"/><path d="${path}" fill="none" stroke="#1561f5" stroke-width="2"/><text x="${left}" y="${height-9}" font-size="11" fill="currentColor">0</text><text x="${width-right}" y="${height-9}" text-anchor="end" font-size="11" fill="currentColor">${number(maxX)} s</text><text x="${left-7}" y="${top+4}" text-anchor="end" font-size="11" fill="currentColor">${number(maxY)}</text><text x="${width/2}" y="${height-9}" text-anchor="middle" font-size="11" fill="currentColor">Journeys / second · elapsed time</text></svg>`;
  }
  function details(id, report=false) {
    selectedRun=id;const job=state.jobs.find(j=>j.id===id);if(!job)return;
    const panel=$(report?'#report-details':'#details');panel.hidden=false;
    panel.innerHTML=`<h2>${escape(state.scenarios[job.scenario]?.label||'Student base generation')} ${badge(job.state)}</h2><p class="footnote">${escape(job.target)} · ${escape(job.phase)}</p><div class="table-wrap"><table><thead><tr><th>Check</th><th>Required</th><th>Actually observed</th><th>Result</th></tr></thead><tbody>${job.checks.map(c=>`<tr><td>${escape(c.check)}</td><td>${escape(c.expected)}</td><td>${escape(c.observed)}</td><td>${badge(c.pass?'PASS':'FAIL')}</td></tr>`).join('')||'<tr><td colspan="4">No completed verification checks.</td></tr>'}</tbody></table></div>${job.errors.length?'<h3>Actual errors</h3><pre>'+escape(job.errors.map(e=>(e.student_number?'Student '+e.student_number+': ':'')+e.message).join('\n'))+'</pre>':''}<h3>Measured values</h3><pre>${escape(JSON.stringify(job.metrics,null,2))}</pre><button data-download="${job.id}">Download evidence JSON</button>`;
    renderEvidence(job);renderChart(job);panel.scrollIntoView({behavior:'smooth',block:'nearest'});
  }
  async function refresh(){try{state=await api('/api/state');render();}catch(error){notice(error.message,true);}}
  async function advanceQueue(){
    if(dispatching)return;
    if(stoppedQueue||!queue.length){runningQueue=false;queue=[];return;}
    dispatching=true;
    const scenario=queue.shift();
    try{const job=await api('/api/run',{scenario,options:options()});selectedRun=job.id;notice('Started '+state.scenarios[scenario].label);}
    catch(error){runningQueue=false;queue=[];notice(error.message,true);}
    await refresh();dispatching=false;
  }
  $('#run-tests').addEventListener('click',async()=>{if(!chosen.size){notice('Select at least one test.',true);return;}queue=[...chosen];runningQueue=true;stoppedQueue=false;await advanceQueue();});
  $('#stop-test').addEventListener('click',async()=>{stoppedQueue=true;queue=[];runningQueue=false;const active=state.jobs.find(j=>j.state==='RUNNING');if(active){try{await api('/api/stop',{id:active.id});notice('Stopping; the server may still finish in-flight writes.');}catch(e){notice(e.message,true);}}});
  $('#generate-base').addEventListener('click',async()=>{try{await api('/api/run',{scenario:'base_generate',options:{count:100000}});await refresh();}catch(e){notice(e.message,true);}});
  $('#student-count').addEventListener('input',()=>{$('#student-range').value=$('#student-count').value;if(state)render();});
  $('#student-range').addEventListener('input',()=>{$('#student-count').value=$('#student-range').value;if(state)render();});
  $('#volume').addEventListener('input',()=>{if(state)render();});
  document.addEventListener('change',e=>{if(e.target.dataset.scenario){e.target.checked?chosen.add(e.target.dataset.scenario):chosen.delete(e.target.dataset.scenario);}});
  document.addEventListener('click',e=>{
    const b=e.target.closest('button');if(!b)return;
    if(b.dataset.page){document.querySelectorAll('nav button').forEach(t=>t.classList.toggle('active',t===b));['console','base','connections','reports'].forEach(p=>$('#'+p+'-page').hidden=p!==b.dataset.page);$('#page-title').textContent=b.textContent;}
    if(b.dataset.run)details(b.dataset.run,Boolean(b.dataset.report));
    if(b.dataset.download)download('/api/report/'+b.dataset.download,b.dataset.download+'.json');
    if(b.dataset.export)download('/api/export/'+b.dataset.export,'students.'+b.dataset.export);
  });
  let connecting=false;
  async function connectSchool(firebaseOnly) {
    if(connecting)return;
    const form=$('#school-form'),values=Object.fromEntries(new FormData(form));
    if(!values.project_id||!values.api_key||!values.email||!values.password){notice('Enter the test Firebase project ID, API key, administrator email and password.',true);return;}
    if(!firebaseOnly&&!values.script_url){notice('Enter the separate test Apps Script /exec URL, or use Check Firebase only first.',true);return;}
    connecting=true;$('#check-firebase').disabled=true;form.querySelector('[type="submit"]').disabled=true;
    notice(firebaseOnly?'Checking real Firebase sign-in and Firestore access…':'Checking Firebase and the test Apps Script backend…');
    try{await api(firebaseOnly?'/api/connect/firebase':'/api/connect/school',values);notice(firebaseOnly?'Firebase connection verified. School tests still need the test Apps Script backend.':'Test school backend verified.');}
    catch(error){notice(error.message,true);}
    finally{form.elements.password.value='';connecting=false;$('#check-firebase').disabled=false;form.querySelector('[type="submit"]').disabled=false;await refresh();}
  }
  $('#school-form').addEventListener('submit',e=>{e.preventDefault();connectSchool(false);});
  $('#check-firebase').addEventListener('click',()=>connectSchool(true));
  $('#native-form').addEventListener('submit',async e=>{e.preventDefault();const f=Object.fromEntries(new FormData(e.target));try{await api('/api/connect/native',{web:{url:f.web_url,expected_text:f.web_expected_text,expected_selector:f.web_expected_selector,email:f.web_email,password:f.web_password,login_button:f.web_login_button,steps:JSON.parse(f.web_steps),headless:false},windows:{exe:f.windows_exe,window_title:f.windows_window_title,steps:JSON.parse(f.windows_steps)},android:{adb:f.android_adb,serial:f.android_serial,apk:f.android_apk,component:f.android_component,steps:JSON.parse(f.android_steps)}});e.target.elements.web_password.value='';notice('Runners saved in process memory.');await refresh();}catch(error){notice(error.message,true);}});
  $('#download-backend').addEventListener('click',()=>download('/api/backend','Saarthi-Test-Backend.zip'));
  $('#install-browser').addEventListener('click',async()=>{try{await api('/api/install-browser',{});notice('Browser installation started. It downloads a real browser; see browser-install.log for errors.');await refresh();}catch(e){notice(e.message,true);}});
  $('#exit-app').addEventListener('click',async()=>{try{await api('/api/shutdown',{});notice('Toolkit closed. You can close this tab.');clearInterval(timer);}catch(e){notice(e.message,true);}});
  refresh();const timer=setInterval(refresh,1500);
})();
