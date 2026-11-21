'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {createHmac} = require('node:crypto');
const {createDeveloperLogin, requireDeveloper, idleMillis} = require('../developer-login');

function fixture() {
  let time = 1_800_000_000_000;
  let passwordCalls = 0, mailCalls = 0;
  const docs = new Map();
  const db = {doc: path => ({
    path, get: async () => ({exists: docs.has(path), data: () => structuredClone(docs.get(path))}),
    set: async data => docs.set(path, data),
  })};
  let pending = Promise.resolve();
  db.runTransaction = callback => {
    const execution = pending.then(async () => {
      const writes = [];
      const result = await callback({
        get: ref => ref.get(),
        set: (ref, data, options) => writes.push(() => docs.set(ref.path,
          options?.merge ? {...docs.get(ref.path), ...data} : data)),
        delete: ref => writes.push(() => docs.delete(ref.path)),
      });
      writes.forEach(write => write());
      return result;
    });
    pending = execution.catch(() => {});
    return execution;
  };
  const account = {uid: 'dev', email: 'dev@example.com', emailVerified: true, customClaims: {developer: true}};
  const auth = {
    verifyIdToken: async () => ({uid: account.uid}),
    getUser: async () => account,
    getUserByEmail: async email => {
      if (email !== account.email) throw Object.assign(Error('missing'), {code:'auth/user-not-found'});
      return account;
    },
    createCustomToken: async (_, claims) => claims.developerSessionId,
    generatePasswordResetLink: async () => 'https://example.com/reset',
  };
  const now = () => time;
  const {handle} = createDeveloperLogin({auth, db, now, env: {
    SAARTHI_DEVELOPER_FIREBASE_API_KEY:'test',
    SAARTHI_DEVELOPER_TOTP_SECRETS: JSON.stringify({dev:'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'}),
    SAARTHI_DEVELOPER_OTP_RESEND_API_KEY:'test',
    SAARTHI_DEVELOPER_OTP_FROM:'sender@example.com',
  }, fetchImpl: async (url, options) => {
    if (String(url).startsWith('https://api.resend.com/')) {
      mailCalls++;
      return {ok: true};
    }
    passwordCalls++;
    if (JSON.parse(options.body).password !== 'valid') return {ok: false, status: 400};
    return {ok: true, status: 200, json: async () => ({idToken:'checked'})};
  }});
  function otp() {
    const counter = Buffer.alloc(8);
    counter.writeBigUInt64BE(BigInt(Math.floor(time / 30000)));
    const bytes = createHmac('sha1', Buffer.from('12345678901234567890')).update(counter).digest();
    return String((bytes.readUInt32BE(bytes[19] & 15) & 0x7fffffff) % 1000000).padStart(6, '0');
  }
  return {
    handle, docs, otp, account, calls: () => ({passwordCalls, mailCalls}),
    advance: delta => { time += delta; },
    start: password => handle('start', {email:' Dev@Example.com ', password}),
    session: (developerSessionId, action) => requireDeveloper(auth, db, {
      uid: 'dev', developer: true, developerSessionId, firebase:{sign_in_provider:'custom'},
    }, now, action),
  };
}

test('only a valid authenticator code issues a session and a time step cannot be replayed', async () => {
  const f = fixture();
  const one = await f.start('valid');
  const two = await f.start('valid');
  assert.equal(one.customToken, undefined);
  await assert.rejects(f.session(undefined), {status:401});
  const results = await Promise.allSettled([one, two].map(({challenge}) =>
    f.handle('confirm', {challenge, otp:f.otp()})));
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  const {customToken} = results.find(result => result.status === 'fulfilled').value;
  assert.equal((await f.session(customToken)).success, true);
  await f.session(customToken, 'end');
  await assert.rejects(f.session(customToken), {status:401});
});

test('five bad codes or a five-minute old challenge are rejected', async () => {
  const f = fixture();
  const {challenge} = await f.start('valid');
  const wrong = f.otp() === '000000' ? '111111' : '000000';
  for (let i = 0; i < 5; i++) await assert.rejects(f.handle('confirm', {challenge, otp:wrong}), {status:403});
  await assert.rejects(f.handle('confirm', {challenge, otp:f.otp()}), {status:403});
  const fresh = await f.start('valid');
  f.advance(300000);
  await assert.rejects(f.handle('confirm', {...fresh, otp:f.otp()}), {status:403});
});

test('session reads do not renew idle expiry, and activity cannot revive an expired session', async () => {
  const f = fixture();
  const {challenge} = await f.start('valid');
  const {customToken} = await f.handle('confirm', {challenge, otp:f.otp()});
  const initial = await f.session(customToken);
  f.advance(idleMillis - 1);
  assert.equal((await f.session(customToken)).expiresAt, initial.expiresAt);
  assert.equal((await f.session(customToken, 'touch')).expiresAt, initial.expiresAt + idleMillis - 1);
  f.advance(idleMillis);
  await assert.rejects(f.session(customToken, 'touch'), {status:401});
});

test('login budget is shared by concurrent requests and expires after 15 minutes', async () => {
  const f = fixture();
  const results = await Promise.allSettled(Array.from({length:8}, () => f.start('wrong')));
  assert.equal(results.filter(result => result.reason.status === 429).length, 3);
  assert.equal(f.calls().passwordCalls, 5);
  f.advance(900000);
  assert.ok((await f.start('valid')).challenge);
});

test('forgot password response is neutral and allows two sends per rolling day with ten-minute spacing', async () => {
  const f = fixture();
  const recover = (email = f.account.email) => f.handle('recover', {email});
  assert.deepEqual(await recover('unknown@example.com'), await recover());
  assert.deepEqual(await recover(' DEV@example.com '), {success:true});
  assert.equal(f.calls().mailCalls, 1);
  f.advance(600000);
  await recover();
  f.advance(600000);
  await recover();
  assert.equal(f.calls().mailCalls, 2);
  f.advance(86400000);
  await recover();
  assert.equal(f.calls().mailCalls, 3);
});
