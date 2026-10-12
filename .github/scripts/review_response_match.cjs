'use strict';
function requestBody(response) {
  if (response.request().method() !== 'POST') return {};
  try {
    const body = JSON.parse(response.request().postData());
    return body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  } catch (_) { return {}; }
}
function matchesNoticeWrite(response, endpoint, school, id) {
  if (response.url() !== endpoint) return false;
  const body = requestBody(response);
  return body.schoolId === school && body.action === 'managed/records' &&
    body.operation === 'write' && body.collection === 'school_notices' && body.id === id;
}
function matchesNoticeRead(response, endpoint, school) {
  if (response.url() !== endpoint) return false;
  const body = requestBody(response);
  return body.schoolId === school && body.action === 'managed/changes' &&
    Array.isArray(body.collections) && body.collections.includes('school_notices');
}
module.exports = { requestBody, matchesNoticeWrite, matchesNoticeRead };
