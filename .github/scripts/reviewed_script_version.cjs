'use strict';
const fs = require('node:fs');
const path = require('node:path');

// Acceptance metadata comes from the exact checked-out source, never a caller
// override or a previously published package label.
function reviewedScriptVersion(source) {
  const declarations = [...source.matchAll(/scriptBundleVersion\s*:\s*'([^']+)'/g)];
  if (declarations.length !== 1 || !/^20\d{2}-\d{2}-\d{2}\.\d{1,3}$/.test(declarations[0][1])) {
    throw new Error('Canonical Script version is missing, ambiguous or malformed');
  }
  return declarations[0][1];
}
function currentReviewedScriptVersion() {
  return reviewedScriptVersion(fs.readFileSync(path.resolve(__dirname, '../../school-backend/managed/SaarthiManagedAll.gs'), 'utf8'));
}
module.exports = { reviewedScriptVersion, currentReviewedScriptVersion };
