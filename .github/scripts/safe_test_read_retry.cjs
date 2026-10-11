'use strict';
// Only repeat explicit read operations. Never replay an uncertain mutation.
module.exports = async function safeRead(post, url, body, token, report, options = {}) {
  const read = body.action === 'managed/records' && body.operation === 'read';
  const wait = options.wait || (ms => new Promise(resolve => setTimeout(resolve, ms)));
  const random = options.random || Math.random;
  let elapsedMs = 0;
  for (let attempt = 0; ; attempt++) {
    const result = await post(url, body, token);
    elapsedMs += result.elapsedMs || 0;
    if (!read || ![429, 502, 503, 504].includes(result.http) || attempt === 2) {
      return {...result, elapsedMs};
    }
    report.readRetries ||= [];
    report.readRetries.push({attempt: attempt + 1, http: result.http,
      reference: result.data?.requestId || null});
    const delay = Math.round((result.http === 429 ? 15000 : 5000) * 2 ** attempt * (0.8 + random() * 0.4));
    await wait(delay);
    elapsedMs += delay;
  }
};
