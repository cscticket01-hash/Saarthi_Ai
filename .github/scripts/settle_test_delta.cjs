'use strict';
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
// A verified handoff can legitimately advance a head between two reads. Follow
// only returned checkpoints, boundedly; never excuse records at an equal head.
async function settleTestDelta(admin, initial, report, maxReads = 4) {
 let known = {...initial};
 const collections = Object.keys(known);
 assert.ok(collections.length > 0);
 report.deltaCheckpointTransitions = [];
 let reply;
 for (let attempt = 0; attempt < maxReads; attempt++) {
  reply = await admin({action:'managed/changes',collections,knownRevisions:known});
  if (reply.http !== 200) return reply;
  const changes = reply.data.changes;
  assert.ok(changes && Object.keys(changes).length === collections.length);
  let stable = true;
  const next = {};
  const shapes = [];
  for (const collection of collections) {
   const group = changes[collection];
   assert.ok(group && group.syncProtocol === 2 && typeof group.collectionRevision === 'string' && group.collectionRevision &&
     group.records && typeof group.records === 'object' && !Array.isArray(group.records));
   const same = group.collectionRevision === known[collection];
   const count = Object.keys(group.records).length;
   shapes.push({collection,sameCheckpoint:same,unchanged:group.unchanged === true,recordCount:count,
     checkpointHash:createHash('sha256').update(group.collectionRevision).digest('hex').slice(0,16)});
   // Record sanitized evidence before assertions, including a broken contract.
   report.deltaCheckpointTransitions[attempt] = shapes;
   if (same) assert.ok(group.unchanged === true && count === 0, 'Equal checkpoint returned changed data');
   else { assert.notEqual(group.unchanged, true, 'Changed checkpoint claimed unchanged'); stable = false; }
   next[collection] = group.collectionRevision;
  }
  if (stable) return reply;
  known = next;
 }
 return reply; // Caller still requires a genuinely unchanged, empty response.
}
module.exports = {settleTestDelta};
