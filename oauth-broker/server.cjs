'use strict';
const http = require('node:http');
const { exchange, refresh, clientPattern } = require('./exchange.cjs');
const { createHash } = require('node:crypto');
// Deploy behind a managed HTTPS endpoint. No school database or service-account
// SDK is used. Only Google's one-use code + PKCE verifier is exchanged.
function createServer(options = {}) {
  let windowStart = Date.now(), requests = 0;
  const downloads = require('./public-downloads.cjs').createInstallerHandler(options.downloads);
  return http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const send = (status, body) => {
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    if (options.developerRecovery && ['/developer-recovery','/developer-recovery.js'].includes(req.url))
      return options.developerRecovery(req,res);
    if (await downloads(req,res)) return;
    if (req.url === '/school-cloud' || req.url === '/school-cloud/healthz') {
      if (!options.schoolCloud) return send(503, {success:false,message:'Central school staging is not configured'});
      return options.schoolCloud(req,res);
    }
    if (req.method === 'GET' && req.url === '/healthz') {
      const ready = clientPattern.test(options.clientId || '') && Boolean(options.clientSecret?.trim());
      return send(ready ? 200 : 503, { service: 'saarthi-oauth-exchange', version: 1,
        clientIdFingerprint: createHash('sha256').update(options.clientId || '').digest('hex') });
    }
    if (req.method !== 'POST' || !['/oauth/token','/oauth/refresh'].includes(req.url)) return send(404, { error: 'not_found' });
    if (req.headers.origin || !/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] || '')) {
      return send(400, { error: 'invalid_request' });
    }
    // Per-instance cap; also configure host-level request limits/max instances.
    if (Date.now() - windowStart >= 60000) { windowStart = Date.now(); requests = 0; }
    if (++requests > 120) return send(429, { error: 'rate_limited' });
    try {
      let raw = '', bytes = 0;
      for await (const chunk of req) {
        bytes += chunk.length;
        if (bytes > 8192) { send(413, { error: 'invalid_request' }); return; }
        raw += chunk.toString('utf8');
      }
      const result = await (req.url === '/oauth/refresh' ? refresh : exchange)(JSON.parse(raw), options);
      send(result.status, result.body);
    } catch { send(400, { error: 'invalid_request' }); }
  });
}
if (require.main === module) {
  // Staging-only, fixed synthetic diagnostic; no uploaded data or credentials.
  if (process.env.SAARTHI_ID_PDF_STARTUP_PROBE === 'true') {
    const {execFile} = require('node:child_process');
    const {promisify} = require('node:util');
    const execute = promisify(execFile);
    void (async () => {
      const available = {};
      for (const binary of ['pdftotext','pdftohtml','pdftoppm','bwrap','prlimit']) {
        try {
          await execute(binary, [binary.startsWith('pdf') ? '-v' : '--version'], {
            timeout: 3000, maxBuffer: 65536, env: {PATH: '/usr/bin:/bin:/usr/local/bin', LANG:'C'}
          });
          available[binary] = true;
        } catch (_) { available[binary] = false; }
      }
      const configured = ['SAARTHI_GLOBAL_ID_PDFTOTEXT','SAARTHI_GLOBAL_ID_PDFTOHTML','SAARTHI_GLOBAL_ID_PDFTOPPM']
        .map(name => Boolean(process.env[name]));
      // Probe only the fixed, generated fixture; do not enable uploaded PDF analysis.
      const {access} = require('node:fs/promises');
      const {constants} = require('node:fs');
      const executables = [];
      for (const binary of ['pdftotext','pdftohtml','pdftoppm']) {
        let resolved = null;
        for (const dir of ['/usr/bin','/bin','/usr/local/bin']) {
          const candidate = dir+'/'+binary;
          try { await access(candidate,constants.X_OK); resolved=candidate; break; } catch (_) {}
        }
        executables.push(resolved);
      }
      let namespaceIsolation = false;
      try {
        await execute('/usr/bin/unshare',['--user','--map-root-user','--mount','--net','--fork','/bin/true'],{
          timeout:3000,maxBuffer:65536,env:{PATH:'/usr/bin:/bin',LANG:'C'}
        });
        namespaceIsolation = true;
      } catch (_) {}
      // Query Linux sandbox primitives without processing any uploaded PDF.
      try {
        const code = [
          'import ctypes, ctypes.util, json, platform, os',
          'libc=ctypes.CDLL(None,use_errno=True)',
          'abi=libc.syscall(444,0,0,1) if platform.machine() in ("x86_64","aarch64") else -1',
          'print(json.dumps({"landlockAbi":abi,"seccompLibrary":bool(ctypes.util.find_library("seccomp")),"nonRoot":os.getuid()!=0}))'
        ].join('\n');
        const result=await execute('python3',['-I','-c',code],{timeout:4000,maxBuffer:65536,env:{PATH:'/usr/bin:/bin:/usr/local/bin',LANG:'C'}});
        console.info('ID_PDF_SANDBOX_CAPABILITIES '+JSON.stringify(JSON.parse(result.stdout)));
      } catch (_) { console.info('ID_PDF_SANDBOX_CAPABILITIES_UNAVAILABLE'); }
      const {probeRuntime,probeSandbox} = require('../functions/global-id-card-analysis.js');
      if(process.env.SAARTHI_GLOBAL_ID_PDF_SANDBOX==='landlock'){
        try{console.info('ID_PDF_SANDBOX_NEGATIVE '+JSON.stringify(await probeSandbox()));}
        catch(_){console.info('ID_PDF_SANDBOX_NEGATIVE_FAILED');}
      }
      const checks = await probeRuntime(...executables);
      console.info('ID_PDF_HOSTED_SYNTHETIC '+JSON.stringify({executables,checks,namespaceIsolation}));
      console.info('ID_PDF_RUNTIME_INVENTORY '+JSON.stringify({
        available, configured, nonRoot: typeof process.getuid === 'function' && process.getuid() !== 0
      }));
    })().catch(() => console.info('ID_PDF_RUNTIME_INVENTORY_FAILED'));
  }
  // Staging-only targeted existing test files; never runs on the production service.
  if(process.env.SAARTHI_ID_LIBRARY_STAGING==='true' &&
      process.env.RENDER_SERVICE_ID==='srv-dc4skhlg1s2s73flu6q0' &&
      process.env.SAARTHI_ID_LIBRARY_MAPPING_TEST==='20261128-v2'){
    const {execFile}=require('node:child_process');
    const {resolve}=require('node:path');
    const tests=['global-id-card-analysis.test.js','global-id-card-library.test.js','global-id-card-package.test.js','global-id-card-integration.test.js'];
    execFile(process.execPath,['--test',...tests.map(n=>resolve(__dirname,'../functions/test',n))],
      {timeout:60000,maxBuffer:512*1024,env:{PATH:'/usr/bin:/bin',LANG:'C'}},
      (error,stdout)=>{
        const safe=stdout.split('\n').filter(l=>/^# (tests|pass|fail|cancelled|skipped) \d+/.test(l)||/^not ok \d+ - /.test(l));
        console.info('ID_MAPPING_TARGETED_TESTS '+JSON.stringify({passed:!error,results:safe}));
      });
  }
  let schoolCloud;
  if (process.env.SAARTHI_SCHOOL_CLOUD_ENABLED === 'true') {
    schoolCloud = require('../staging-school-cloud/server.cjs').fromEnvironment(process.env);
  }
  const server = createServer({ clientId: process.env.SAARTHI_GOOGLE_DESKTOP_CLIENT_ID,
    clientSecret: process.env.SAARTHI_GOOGLE_DESKTOP_CLIENT_SECRET, schoolCloud,
    developerRecovery: require('./developer-recovery-handler.cjs').fromEnvironment(process.env) });
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  server.listen(Number(process.env.PORT || 8080), '0.0.0.0');
}
module.exports = { createServer };
