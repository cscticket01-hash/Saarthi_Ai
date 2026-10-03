'use strict';
const http = require('node:http');
const { exchange, refresh, clientPattern } = require('./exchange.cjs');
const { createHash } = require('node:crypto');
// Deploy behind a managed HTTPS endpoint. No school database or service-account
// SDK is used. Only Google's one-use code + PKCE verifier is exchanged.
function createServer(options = {}) {
  let windowStart = Date.now(), requests = 0;
  return http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const send = (status, body) => {
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    };
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
  let schoolCloud;
  if (process.env.SAARTHI_SCHOOL_CLOUD_ENABLED === 'true') {
    schoolCloud = require('../staging-school-cloud/server.cjs').fromEnvironment(process.env);
  }
  const server = createServer({ clientId: process.env.SAARTHI_GOOGLE_DESKTOP_CLIENT_ID,
    clientSecret: process.env.SAARTHI_GOOGLE_DESKTOP_CLIENT_SECRET, schoolCloud });
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  server.listen(Number(process.env.PORT || 8080), '0.0.0.0');
}
module.exports = { createServer };
