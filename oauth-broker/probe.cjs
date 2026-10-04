'use strict';
const fs = require('node:fs');
const { createHash } = require('node:crypto');
const { clientPattern } = require('./exchange.cjs');
async function probe({ clientId, clientSecret, brokerUrl = '', fetchImpl = fetch }) {
  if (!clientPattern.test(clientId || '') || !clientSecret) throw new Error('OAuth repository configuration missing');
  async function attempt(secret) {
    const body = new URLSearchParams({ client_id: clientId,
      code: 'saarthi-deliberately-invalid-probe-code', code_verifier: 'a'.repeat(64),
      redirect_uri: 'http://127.0.0.1:54321/oauth2/callback', grant_type: 'authorization_code',
      ...(secret ? { client_secret: clientSecret } : {}) });
    const response = await fetchImpl('https://oauth2.googleapis.com/token', {
      method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(20000), body,
    });
    const data = await response.json();
    // A real code is NEVER used. Only classify fixed error values; never log data.
    return { status: response.status, error: data.error,
      missingSecret: data.error === 'invalid_request' &&
        typeof data.error_description === 'string' && /client_secret.*missing/i.test(data.error_description) };
  }
  const publicResult = await attempt(false), serverResult = await attempt(true);
  if (serverResult.status !== 400 || serverResult.error !== 'invalid_grant') {
    throw new Error('Google did not accept the configured client credentials for the safe invalid-code probe');
  }
  if (!publicResult.missingSecret && !(publicResult.status === 400 && publicResult.error === 'invalid_grant')) {
    throw new Error('Unexpected public-client probe result; inspect Google configuration securely');
  }
  if (brokerUrl) {
    const url = new URL(brokerUrl);
    if (url.protocol !== 'https:' || url.pathname !== '/oauth/token' || url.username ||
        url.password || url.search || url.hash || (url.port && url.port !== '443')) throw new Error('Invalid broker URL');
    const health = await fetchImpl(new URL('/healthz', url), { redirect: 'manual', signal: AbortSignal.timeout(90000) });
    const info = await health.json();
    if (health.status !== 200 || info.service !== 'saarthi-oauth-exchange' ||
        info.clientIdFingerprint !== createHash('sha256').update(clientId).digest('hex')) throw new Error('Broker client mismatch');
    const check = await fetchImpl(url, { method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(20000),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: 'saarthi-deliberately-invalid-probe-code', code_verifier: 'a'.repeat(64),
        redirect_uri: 'http://127.0.0.1:54321/oauth2/callback' }) });
    const result = await check.json();
    if (check.status !== 400 || result.error !== 'invalid_grant') throw new Error('Broker exchange configuration failed');
  }
  return { requiresSecret: publicResult.missingSecret, brokerVerified: Boolean(brokerUrl) };
}
if (require.main === module) {
  probe({ clientId: process.env.SAARTHI_GOOGLE_DESKTOP_CLIENT_ID,
    clientSecret: process.env.SAARTHI_GOOGLE_DESKTOP_CLIENT_SECRET,
    brokerUrl: process.env.SAARTHI_GOOGLE_OAUTH_BROKER_URL || '' }).then(({ requiresSecret, brokerVerified }) => {
    console.log(`Google client credentials accepted for invalid-code probe: yes. Server-side secret exchange required: ${requiresSecret}. Hosted broker verified: ${brokerVerified}.`);
    if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `requires_secret=${requiresSecret}\n`);
    if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `OAuth probe: configured credentials accepted; server-side secret exchange required: **${requiresSecret}**. No live school login, tokens or resources were created.\n`);
  }).catch(() => { console.error('Safe Google OAuth configuration probe failed; no credential or Google response was logged.'); process.exitCode = 1; });
}
module.exports = { probe };
