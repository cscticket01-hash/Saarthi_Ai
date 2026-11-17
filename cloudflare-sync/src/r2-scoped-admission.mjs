/**
 * Fail closed for production school targeting, preserving existing isolated
 * TEST installations that pre-date R2_STAGING_SCHOOLS.
 */
export function r2StagingForSchool(env, school) {
  if (env?.R2_STAGING_ENABLED !== 'true' ||
      typeof school !== 'string' ||
      !/^vs-[a-f0-9]{32}$/.test(school)) return false;
  const raw = env?.R2_STAGING_SCHOOLS;
  // An older isolated TEST Worker has a single secret school ID. Production
  // has no such secret and therefore fails closed until explicitly scoped.
  if (raw === undefined) return env.LIVE_SYNC_TEST_SCHOOL_ID === school;
  if (typeof raw !== 'string') return false;
  if (raw.trim() === '*') return env.R2_STAGING_ALL_SCHOOLS_ENABLED === 'true';
  const scopes = raw.split(',').map(s => s.trim());
  if (scopes.some(s => s !== '' && !/^vs-[a-f0-9]{32}$/.test(s))) return false;
  return scopes.includes(school);
}
