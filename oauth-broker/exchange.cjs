'use strict';
const errors = new Set(['invalid_grant', 'access_denied', 'temporarily_unavailable', 'server_error']);
const clientPattern = /^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/;
function validInput(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).some(k => !['code', 'code_verifier', 'redirect_uri'].includes(k))) return false;
  if (typeof body.code !== 'string' || !/^[A-Za-z0-9_./~-]{1,4096}$/.test(body.code) ||
      typeof body.code_verifier !== 'string' || !/^[A-Za-z0-9._~-]{43,128}$/.test(body.code_verifier)) return false;
  if (typeof body.redirect_uri !== 'string') return false;
  try {
    const u = new URL(body.redirect_uri);
    return u.protocol === 'http:' && u.hostname === '127.0.0.1' &&
      Number(u.port) >= 1024 && Number(u.port) <= 65535 && u.pathname === '/oauth2/callback' &&
      !u.username && !u.password && !u.search && !u.hash && body.redirect_uri === u.href;
  } catch { return false; }
}
async function exchange(body, { clientId, clientSecret, fetchImpl = fetch }) {
  if (!validInput(body)) return { status: 400, body: { error: 'invalid_request' } };
  if (!clientPattern.test(clientId || '') || typeof clientSecret !== 'string' || !clientSecret.trim()) {
    return { status: 503, body: { error: 'server_configuration_error' } };
  }
  try {
    const response = await fetchImpl('https://oauth2.googleapis.com/token', {
      method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(20000),
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret,
        grant_type: 'authorization_code', ...body }).toString(),
    });
    const data = await response.json();
    if (response.status !== 200) {
      return { status: response.status === 400 ? 400 : 502,
        body: { error: errors.has(data?.error) ? data.error : 'server_configuration_error' } };
    }
    if (typeof data.access_token !== 'string' || !data.access_token ||
        typeof data.scope !== 'string' || !data.scope ||
        String(data.token_type).toLowerCase() !== 'bearer' ||
        !Number.isInteger(data.expires_in) || data.expires_in <= 0) {
      return { status: 502, body: { error: 'invalid_token_response' } };
    }
    // Desktop Drive session tokens go only to the PKCE-authorized native client.
    // It stores them in OS secure storage. Never forward client secrets or ID tokens.
    return { status: 200, body: { access_token: data.access_token, scope: data.scope,
      token_type: 'Bearer', expires_in: data.expires_in,
      ...(data.scope.split(' ').includes('https://www.googleapis.com/auth/drive.file') &&
        typeof data.refresh_token === 'string' ? { refresh_token: data.refresh_token } : {}) } };
  } catch { return { status: 502, body: { error: 'temporarily_unavailable' } }; }
}
async function refresh(body, {clientId, clientSecret, fetchImpl = fetch}) {
  if (!body || Object.keys(body).length !== 1 || typeof body.refresh_token !== 'string' ||
      !/^[A-Za-z0-9_./~-]{10,4096}$/.test(body.refresh_token)) return {status:400,body:{error:'invalid_request'}};
  if (!clientPattern.test(clientId || '') || !clientSecret?.trim()) return {status:503,body:{error:'server_configuration_error'}};
  try {
    const r = await fetchImpl('https://oauth2.googleapis.com/token', {method:'POST',redirect:'manual',signal:AbortSignal.timeout(20000),
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({client_id:clientId,client_secret:clientSecret,grant_type:'refresh_token',refresh_token:body.refresh_token}).toString()});
    const data = await r.json();
    if (r.status !== 200) return {status:400,body:{error:errors.has(data?.error) ? data.error : 'invalid_grant'}};
    if (typeof data.access_token !== 'string' || !data.access_token || !Number.isInteger(data.expires_in) || data.expires_in <= 0)
      return {status:502,body:{error:'invalid_token_response'}};
    return {status:200,body:{access_token:data.access_token,expires_in:data.expires_in,token_type:'Bearer'}};
  } catch {return {status:502,body:{error:'temporarily_unavailable'}};}
}
module.exports = { exchange, refresh, validInput, clientPattern };
