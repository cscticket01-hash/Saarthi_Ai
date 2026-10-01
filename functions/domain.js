'use strict';
const crypto = require('node:crypto');
const DAY = 86400000;
function hash(value) { return crypto.createHash('sha256').update(String(value)).digest('hex'); }
function safeEqual(a, b) { const x = Buffer.from(String(a)); const y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); }
function schoolId(value) { const id = String(value || '').trim(); if (!/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(id)) throw new Error('Invalid school Firebase project ID'); return id; }
function scriptUrl(value) { const u = new URL(String(value)); if (u.protocol !== 'https:' || u.hostname !== 'script.google.com' || !/^\/macros\/s\/[A-Za-z0-9_-]+\/exec$/.test(u.pathname) || u.search || u.hash || u.username || u.password) throw new Error('Use the school Google Apps Script /exec URL'); return u.toString(); }
function licenseState(school, license, now = Date.now()) {
  if (school.blocked === true) return { allowed: false, status: 'blocked', expiresAt: 0, daysLeft: 0 };
  if (license && license.status === 'active' && Number(license.expiresAt) > now) return { allowed: true, status: 'licensed', expiresAt: Number(license.expiresAt), daysLeft: Math.ceil((license.expiresAt - now) / DAY) };
  const end = Number(school.trialStartedAt || 0) + 5 * DAY;
  return { allowed: end > now && school.blocked !== true, status: school.blocked ? 'blocked' : end > now ? 'trial' : 'expired', expiresAt: end, daysLeft: Math.max(0, Math.ceil((end - now) / DAY)) };
}
function summary(schools, mobile, now = Date.now()) {
  const active = schools.filter(s => Number(s.lastSeenAt || 0) >= now - DAY);
  const enrolled = new Set(mobile.filter(m => m.role === 'student' && Number(m.expiresAt) > now).map(m => `${m.schoolId}/${m.personId}`));
  const online = new Set(mobile.filter(m => m.role === 'student' && Number(m.lastSeenAt || 0) >= now - 5 * 60000 && Number(m.expiresAt) > now).map(m => `${m.schoolId}/${m.personId}`));
  return { totalSchools: schools.length, activeSchools: active.length, inactiveSchools: schools.length - active.length, studentAppUsers: enrolled.size, studentsOnline: online.size, purchasedSchools: schools.filter(s => s.purchased === true).length, expiringSchools: schools.filter(s => s.licenseExpiresAt > now && s.licenseExpiresAt <= now + 14 * DAY).length };
}
function finalOutcome({ classNumber, isFinal, result, force = false, completed = false }) {
  if (!isFinal || !completed) return { action: 'none', classNumber };
  if (!['PASS', 'FAIL'].includes(result)) throw new Error('Final result must be PASS or FAIL');
  if (!Number.isInteger(classNumber) || classNumber < 1 || classNumber > 12) throw new Error('Invalid class');
  if (result === 'FAIL' && !force) return { action: 'retained', classNumber };
  if (classNumber >= 12) return { action: 'graduated', classNumber };
  return { action: force && result === 'FAIL' ? 'force_promoted' : 'promoted', classNumber: classNumber + 1 };
}
function isSchoolOpen(dateKey, override, closedWeekdays = [0]) { if (typeof override?.isOpen === 'boolean') return override.isOpen; const date = new Date(`${dateKey}T12:00:00+05:30`); if (!Number.isFinite(date.getTime())) throw new Error('Invalid calendar date'); return !closedWeekdays.includes(date.getUTCDay()); }
module.exports = { DAY, hash, safeEqual, schoolId, scriptUrl, licenseState, summary, finalOutcome, isSchoolOpen };
