import {test} from 'node:test';
import assert from 'node:assert/strict';
import {brokerRetryDelay} from '../src/broker-retry.mjs';
const now=Date.UTC(2026,10,14,12);
test('broker quota and temporary failures honor numeric and HTTP-date Retry-After minimum',()=>{
 assert.equal(brokerRetryDelay(429,'120',now),120000);
 assert.equal(brokerRetryDelay(503,new Date(now+180000).toUTCString(),now),180000);
 assert.equal(brokerRetryDelay(429,'172800',now),172800000);
 assert.equal(brokerRetryDelay(429,'0',now),60000);
 assert.equal(brokerRetryDelay(504,null,now),30000);
});
test('malformed provider hints cannot create invalid alarms or falsely acknowledge delivery',()=>{
 for(const value of ['', '-1','NaN','Infinity','9999999999999999999999','1e3','0.5','yesterday'])
  assert.equal(brokerRetryDelay(503,value,now),30000);
 assert.equal(brokerRetryDelay(503,new Date(now-1000).toUTCString(),now),30000);
 assert.equal(brokerRetryDelay(200,'120',now),250);
});
