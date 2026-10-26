'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {reviewedScriptVersion, currentReviewedScriptVersion} = require('./reviewed_script_version.cjs');
test('acceptance follows exact canonical source rather than the obsolete package label', () => {
  assert.equal(reviewedScriptVersion("return {scriptBundleVersion:'2026-10-11.4'};"), '2026-10-11.4');
  assert.notEqual(currentReviewedScriptVersion(), '2026-10-11.2');
});
test('missing malformed and competing version declarations fail closed', () => {
  for (const source of ['', "scriptBundleVersion:'Unknown'", "scriptBundleVersion:'2026-10-11.4',scriptBundleVersion:'2026-10-11.2'"]) {
    assert.throws(() => reviewedScriptVersion(source));
  }
});
