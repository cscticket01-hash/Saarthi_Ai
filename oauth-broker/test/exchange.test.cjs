'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { exchange, validInput } = require('../exchange.cjs');
const { probe } = require('../probe.cjs');
const { createServer } = require('../server.cjs');
const input = { code: '4/approved-code', code_verifier: 'v'.repeat(64), redirect_uri: 'http://127.0.0.1:54321/oauth2/callback' };
const options = { clientId: 'test.apps.googleusercontent.com', clientSecret: 'server-only-secret' };
const response = (body, status = 200) => ({ status, json: async () => body });
test('exchange fixes client/upstream, preserves PKCE and returns only required access fields', async () => {
  const result = await exchange(input, { ...options, fetchImpl: async (url, request) => {
    assert.equal(url, 'https://oauth2.googleapis.com/token');
    assert.equal(request.redirect, 'manual');
    const form = new URLSearchParams(request.body);
    assert.equal(form.get('client_id'), options.clientId);
    assert.equal(form.get('client_secret'), options.clientSecret);
    assert.equal(form.get('code_verifier'), input.code_verifier);
    assert.equal(form.get('redirect_uri'), input.redirect_uri);
    return response({ access_token: 'access-only', scope: 'openid email', expires_in: 3600,
      token_type: 'Bearer', refresh_token: 'must-not-return', id_token: 'must-not-return' });
  }});
  assert.deepEqual(result, { status: 200, body: { access_token: 'access-only', scope: 'openid email', token_type: 'Bearer', expires_in: 3600 } });
});
test('rejects attacker redirects, client override, missing PKCE and oversized codes before contacting Google', async () => {
  for (const body of [null, { ...input, client_id: 'attacker' }, { ...input, client_secret: 'attacker' },
    { ...input, redirect_uri: 'https://attacker.test/oauth2/callback' },
    { ...input, redirect_uri: 'http://127.0.0.1:54321/oauth2/callback?code=evil' },
    { ...input, redirect_uri: 'http://attacker@127.0.0.1:54321/oauth2/callback' },
    { ...input, redirect_uri: 'http://127.0.0.1:80/oauth2/callback' },
    { ...input, code_verifier: 'short' }, { ...input, code: 'x'.repeat(4097) }]) {
    assert.equal(validInput(body), false);
    assert.equal((await exchange(body, { ...options, fetchImpl: () => { throw Error('must not call'); }})).status, 400);
  }
});
test('missing configuration fails without forwarding credentials', async () => {
  assert.deepEqual(await exchange(input, { ...options, clientSecret: '' }), { status: 503, body: { error: 'server_configuration_error' } });
});
test('Google errors/redirects/malformed responses never leak secrets or raw descriptions', async () => {
  for (const mock of [async () => response({ error: 'invalid_client', error_description: 'server-only-secret' }, 400),
    async () => response({ error: 'new-error', access_token: 'private-token' }, 302),
    async () => { throw Error('server-only-secret'); },
    async () => response({ access_token: 'private-token', scope: 'openid', token_type: 'Wrong', expires_in: 3600 })]) {
    const result = await exchange(input, { ...options, fetchImpl: mock });
    assert.notEqual(result.status, 200);
    assert.doesNotMatch(JSON.stringify(result), /server-only-secret|private-token/);
  }
  assert.equal((await exchange(input, { ...options, fetchImpl: async () => response({ error: 'invalid_grant' }, 400) })).body.error, 'invalid_grant');
});
test('probe identifies Google requirement using only invalid codes', async () => {
  for (const requiresSecret of [true, false]) {
    const result = await probe({ ...options, fetchImpl: async (url, request) => {
      const form = new URLSearchParams(request.body);
      assert.equal(form.get('code'), 'saarthi-deliberately-invalid-probe-code');
      assert.equal(request.redirect, 'manual');
      return response(!form.has('client_secret') && requiresSecret
        ? { error: 'invalid_request', error_description: 'client_secret is missing.' }
        : { error: 'invalid_grant' }, 400);
    }});
    assert.equal(result.requiresSecret, requiresSecret);
  }
});
test('probe rejects wrong client credentials', async () => {
  await assert.rejects(probe({ ...options, fetchImpl: async () => response({ error: 'invalid_client' }, 400) }));
});
test('HTTP route bounds body, blocks browser origins and never follows arbitrary routes', async () => {
  const server = createServer({ ...options, fetchImpl: async () => response({ error: 'invalid_grant' }, 400) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await fetch(base + '/healthz')).status, 200);
    for (const [path, body, headers, expected] of [
      ['/oauth/token', input, { 'Content-Type': 'application/json' }, 400],
      ['/oauth/token', input, { 'Content-Type': 'application/json', Origin: 'https://evil.test' }, 400],
      ['/oauth/token', { code: 'x'.repeat(9000) }, { 'Content-Type': 'application/json' }, 413],
      ['/evil', input, { 'Content-Type': 'application/json' }, 404]]) {
      const res = await fetch(base + path, { method: 'POST', headers, body: JSON.stringify(body) });
      assert.equal(res.status, expected);
      assert.equal(res.headers.get('cache-control'), 'no-store');
      assert.doesNotMatch(await res.text(), /server-only-secret/);
    }
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
});
test('Drive offline token reaches only native PKCE client and refresh uses fixed Google client',async()=>{
 const {refresh}=require('../exchange.cjs');
 const result=await exchange(input,{...options,fetchImpl:async()=>response({access_token:'access',refresh_token:'drive-refresh',
   scope:'openid email https://www.googleapis.com/auth/drive.file',expires_in:3600,token_type:'Bearer',client_secret:'must-not-return',id_token:'must-not-return'})});
 assert.equal(result.body.refresh_token,'drive-refresh');assert.equal(result.body.client_secret,undefined);assert.equal(result.body.id_token,undefined);
 const renewed=await refresh({refresh_token:'drive-refresh-token'},{...options,fetchImpl:async(url,req)=>{
  assert.equal(url,'https://oauth2.googleapis.com/token');assert.equal(req.redirect,'manual');
  const form=new URLSearchParams(req.body);assert.equal(form.get('client_id'),options.clientId);assert.equal(form.get('grant_type'),'refresh_token');
  return response({access_token:'new-access',expires_in:3600,client_secret:'must-not-return'});
 }});
 assert.deepEqual(renewed.body,{access_token:'new-access',expires_in:3600,token_type:'Bearer'});
 for(const input of [{refresh_token:'short'},{refresh_token:'drive-refresh-token',client_id:'attacker'},null])
  assert.equal((await refresh(input,options)).status,400);
 const denied=await refresh({refresh_token:'drive-refresh-token'},{...options,fetchImpl:async()=>response({error:'invalid_grant',error_description:'private-token'},400)});
 assert.equal(denied.body.error,'invalid_grant');assert.doesNotMatch(JSON.stringify(denied),/private-token/);
});
