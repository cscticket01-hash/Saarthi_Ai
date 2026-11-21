'use strict';

const {createHash, createHmac, randomBytes, timingSafeEqual} = require('node:crypto');
const minute = 60_000;
const idleMillis = 30 * minute;
const idPattern = /^[a-f0-9]{64}$/;
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = (status, message, code) => {
  throw Object.assign(new Error(message), {status, publicMessage: true, code});
};
const expired = () => fail(401, 'Developer session expired. Sign in again.', 'DEVELOPER_SESSION_EXPIRED');

async function requireDeveloper(auth, db, identity, now = Date.now, operation = 'read') {
  const sessionId = identity.developerSessionId;
  if (!identity.uid || !(identity.developer === true || identity.admin === true && !identity.schoolId))
    fail(403, 'Developer access required');
  if (!idPattern.test(sessionId || '') || identity.firebase?.sign_in_provider !== 'custom') expired();
  const [membership, account] = await Promise.all([
    db.doc('school_memberships/' + identity.uid).get(),
    auth.getUser(identity.uid),
  ]);
  if (membership.exists || account.disabled || !isDeveloper(account)) fail(403, 'Developer access required');
  const ref = db.doc('developer_sessions/' + sessionId);
  const check = async (snapshot, tx) => {
    const row = snapshot.data();
    const time = now();
    if (row?.uid !== identity.uid || !Number.isSafeInteger(row.expiresAt) || row.expiresAt <= time) expired();
    if (operation === 'end') {
      tx.delete(ref);
    } else if (operation === 'touch' && row.expiresAt - time <= idleMillis - 5_000) {
      row.expiresAt = time + idleMillis;
      tx.set(ref, {expiresAt: row.expiresAt, purgeAt: new Date(row.expiresAt)}, {merge:true});
    }
    return {success: true, expiresAt: row.expiresAt, serverTime: time};
  };
  if (operation === 'read') return check(await ref.get());
  return db.runTransaction(async tx => check(await tx.get(ref), tx));
}

function isDeveloper(account) {
  const claims = account.customClaims;
  return claims?.developer === true || claims?.admin === true && !claims.schoolId;
}

function createDeveloperLogin({auth, db, env = process.env, now = Date.now, fetchImpl = fetch}) {
  async function rateLimit(scope, key, limit, window, spacing = 0) {
    const ref = db.doc('developer_auth_limits/' + hash(scope + '\n' + key));
    const accepted = await db.runTransaction(async tx => {
      const time = now();
      const row = (await tx.get(ref)).data();
      const attempts = (row?.attempts || []).filter(at => at > time - window);
      if (attempts.length >= limit || attempts.some(at => at > time - spacing)) return false;
      tx.set(ref, {attempts: [...attempts, time], purgeAt: new Date(time + window)});
      return true;
    });
    return accepted;
  }

  async function passwordIdentity(email, password) {
    const key = env.SAARTHI_DEVELOPER_FIREBASE_API_KEY;
    if (!key) fail(503, 'Developer sign-in is unavailable');
    if (typeof password !== 'string' || !password || password.length > 4096)
      fail(401, 'Check your email and password');
    const url = new URL('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword');
    url.searchParams.set('key', key);
    const response = await fetchImpl(url, {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({email, password, returnSecureToken: true}), signal: AbortSignal.timeout(10000),
    });
    if (response.status === 429) fail(429, 'Too many attempts. Try again later.');
    if (response.status >= 500) fail(503, 'Developer sign-in is unavailable');
    if (!response.ok) fail(401, 'Check your email and password');
    const {idToken} = await response.json();
    if (typeof idToken !== 'string') fail(401, 'Check your email and password');
    return auth.verifyIdToken(idToken, true);
  }

  async function eligible(account) {
    return account && !account.disabled && account.emailVerified === true && isDeveloper(account) &&
      !(await db.doc('school_memberships/' + account.uid).get()).exists;
  }

  function totpSecret(uid) {
    let secret;
    try {
      const entries = JSON.parse(env.SAARTHI_DEVELOPER_TOTP_SECRETS || '{}');
      if (Object.hasOwn(entries, uid)) secret = entries[uid];
    } catch {}
    if (typeof secret !== 'string' || !/^[A-Z2-7]{32}$/.test(secret))
      fail(503, 'Developer authenticator setup is required');
    let buffer = 0, bits = 0;
    const bytes = [];
    for (const digit of secret) {
      buffer = (buffer << 5) | 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(digit);
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes.push((buffer >>> bits) & 255);
      }
    }
    return Buffer.from(bytes);
  }

  async function confirm(body) {
    if (!idPattern.test(body.challenge || '') || typeof body.otp !== 'string' || !/^\d{6}$/.test(body.otp))
      fail(400, 'Enter the six-digit authenticator code');
    const ref = db.doc('developer_login_challenges/' + hash(body.challenge));
    const challenge = (await ref.get()).data();
    if (!challenge || challenge.expiresAt <= now()) fail(403, 'Sign-in challenge expired');
    const account = await auth.getUser(challenge.uid);
    if (!await eligible(account) || String(account.tokensValidAfterTime || '') !== challenge.validAfter)
      fail(403, 'Sign-in challenge expired');
    const secret = totpSecret(account.uid);
    const replay = db.doc('developer_totp_state/' + account.uid);
    const sessionId = randomBytes(32).toString('hex');
    const accepted = await db.runTransaction(async tx => {
      const [snapshot, used] = await Promise.all([tx.get(ref), tx.get(replay)]);
      const row = snapshot.data();
      const time = now();
      if (!row || row.expiresAt <= time || row.attempts >= 5) return false;
      const step = Math.floor(time / 30000);
      const lastStep = used.data()?.step ?? -1;
      const matched = [step, step - 1, step + 1].find(candidate => {
        if (candidate <= lastStep || candidate < 0) return false;
        const counter = Buffer.alloc(8);
        counter.writeBigUInt64BE(BigInt(candidate));
        const digest = createHmac('sha1', secret).update(counter).digest();
        const code = ((digest.readUInt32BE(digest[19] & 15) & 0x7fffffff) % 1000000)
          .toString().padStart(6, '0');
        return timingSafeEqual(Buffer.from(code), Buffer.from(body.otp));
      });
      if (matched === undefined) {
        tx.set(ref, {attempts: row.attempts + 1}, {merge:true});
        return false;
      }
      tx.delete(ref);
      tx.set(replay, {step: matched});
      tx.set(db.doc('developer_sessions/' + sessionId), {
        uid: account.uid, expiresAt: time + idleMillis, purgeAt: new Date(time + idleMillis),
      });
      return true;
    });
    if (!accepted) fail(403, 'Incorrect or expired authenticator code');
    return {success: true, customToken: await auth.createCustomToken(account.uid, {developerSessionId: sessionId})};
  }

  async function handle(action, body) {
    if (action === 'confirm') return confirm(body);
    const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
    if (email.length > 254 || !/^\S+@\S+\.\S+$/.test(email)) fail(400, 'Enter a valid email address');
    if (action === 'start') {
      if (!await rateLimit('login', email, 5, 15 * minute)) fail(429, 'Too many attempts. Try again later.');
      const identity = await passwordIdentity(email, body.password);
      const account = await auth.getUser(identity.uid);
      if (!await eligible(account)) fail(401, 'Check your email and password');
      totpSecret(account.uid);
      const challenge = randomBytes(32).toString('hex');
      const expiresAt = now() + 5 * minute;
      await db.doc('developer_login_challenges/' + hash(challenge)).set({
        uid: account.uid, validAfter: String(account.tokensValidAfterTime || ''), attempts: 0,
        expiresAt, purgeAt: new Date(expiresAt),
      });
      return {success: true, challenge};
    }
    if (action === 'recover') {
      const neutral = {success: true};
      if (!await rateLimit('recovery', email, 2, 24 * 60 * minute, 10 * minute)) return neutral;
      const apiKey = env.SAARTHI_DEVELOPER_OTP_RESEND_API_KEY;
      const from = env.SAARTHI_DEVELOPER_OTP_FROM;
      if (!apiKey || !from) fail(503, 'Password recovery is unavailable');
      let account;
      try { account = await auth.getUserByEmail(email); }
      catch (error) { if (error.code === 'auth/user-not-found') return neutral; throw error; }
      if (!await eligible(account)) return neutral;
      try {
        const link = await auth.generatePasswordResetLink(account.email);
        const response = await fetchImpl('https://api.resend.com/emails', {
          method: 'POST', headers: {Authorization: 'Bearer ' + apiKey, 'Content-Type': 'application/json'},
          body: JSON.stringify({from, to: [account.email], subject: 'Saarthi AI developer password reset',
            text: 'Use this link to reset your developer password: ' + link}),
          signal: AbortSignal.timeout(12000),
        });
        if (!response.ok) console.warn('Developer recovery email was rejected by the provider');
      } catch {
        console.warn('Developer recovery email could not be sent');
      }
      return neutral;
    }
    fail(400, 'Unknown developer authentication action');
  }

  async function verifyCurrentPassword(account, password) {
    if (!await rateLimit('current-password', account.uid, 5, 15 * minute))
      fail(429, 'Too many attempts. Try again later.');
    if ((await passwordIdentity(account.email, password)).uid !== account.uid)
      fail(401, 'Check your current password');
  }

  return {handle, verifyCurrentPassword};
}

module.exports = {createDeveloperLogin, requireDeveloper, idleMillis};
