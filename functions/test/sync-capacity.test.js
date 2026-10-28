'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {sharedCloud}=require('./helpers/shared-change-cloud');
const {createSchoolChangeFeed}=require('../school-change-feed');
const school=n=>'vs-'+n.toString(16).padStart(32,'0');
test('400 schools and 2000 PC waiters share only 400 listeners; no cross-school hint delivery',async()=>{
 const cloud=sharedCloud(),feed=createSchoolChangeFeed({db:cloud.db,collections:['students_directory'],waitMillis:1000});
 const cursors=[];
 for(let i=1;i<=400;i++){await feed.publish(school(i),'students_directory','seed');cursors[i]=(await feed.wait(school(i))).cursor;}
 const pending=[];
 for(let i=1;i<=400;i++)for(let pc=0;pc<5;pc++)pending.push(feed.wait(school(i),cursors[i]));
 await new Promise(resolve=>setImmediate(resolve));assert.equal(cloud.listeners.size,400);
 for(let i=1;i<=400;i++)await feed.publish(school(i),'students_directory','school-'+i);
 const events=await Promise.all(pending);
 for(let i=0;i<events.length;i++)assert.deepEqual(events[i].records.students_directory,['school-'+(Math.floor(i/5)+1)]);
 assert.equal(cloud.listeners.size,0);
});
test('100000 student-change hints across 400 schools replay independently to 1–5 PCs with bounded retention', {timeout:120000},async()=>{
 const cloud=sharedCloud(),feed=createSchoolChangeFeed({db:cloud.db,collections:['students_directory'],waitMillis:2});
 const cursors=[],started=performance.now();let changes=0,replayed=0;
 for(let i=1;i<=400;i++){
  const id=school(i);await feed.publish(id,'students_directory','seed');cursors[i]=(await feed.wait(id)).cursor;
 }
 // Same student IDs intentionally recur in different schools. No real records,
 // provider calls, pupils, auth credentials or production writes are involved.
 for(let student=0;student<250;student++)for(let i=1;i<=400;i++){
  await feed.publish(school(i),'students_directory','student-'+student);changes++;
 }
 for(let i=1;i<=400;i++)for(let pc=0;pc<1+(i%5);pc++){
  let cursor=cursors[i];const ids=new Set();
  while(true){const event=await feed.wait(school(i),cursor,{replayVersion:1});assert.equal(event.reset,false);
   for(const id of event.records.students_directory||[])ids.add(id);cursor=event.cursor;
   if(!event.hasMore)break;
  }
  assert.equal(ids.size,250);assert(cursor.endsWith(':251'));replayed++;
 }
 assert.equal(changes,100000);assert.equal(replayed,1200);assert.equal(cloud.listeners.size,0);
 assert.equal(cloud.records.size,400*5); // one head + four 64-event pages/school
 console.log('SYNC3_CAPACITY',JSON.stringify({scope:'synthetic metadata only; not real school storage or provider capacity',schools:400,studentChanges:changes,independentPcCursors:replayed,documents:cloud.records.size,elapsedMillis:performance.now()-started}));
});

test('idle poll renewals reuse one school subscription; the bounded grace expires without queue work',async()=>{
 const cloud=sharedCloud(),feed=createSchoolChangeFeed({db:cloud.db,collections:['students_directory'],waitMillis:5,idleGraceMillis:30});
 const initial=await feed.wait(school(1));const subscriptions=cloud.listeners.get('school_sync_hints/'+school(1));
 for(let i=0;i<3;i++)await feed.wait(school(1),initial.cursor);
 assert.equal(cloud.listeners.get('school_sync_hints/'+school(1)),subscriptions);
 await new Promise(resolve=>setTimeout(resolve,50));assert.equal(cloud.listeners.size,0);
});
