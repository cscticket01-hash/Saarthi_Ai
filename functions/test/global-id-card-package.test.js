'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {validatePackage}=require('../global-id-card-package');
const id='gid-'+'a'.repeat(32);
// Synthetic one-pixel PNG. The fixture checks geometry and package schema,
// not print resolution, visual acceptance, or sample removal.
const front='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMwaDgAAAJUAXHIMWMAAAAAAElFTkSuQmCC';
function fixture(){
 return {manifest:{id,version:1,canvasWidth:300,canvasHeight:300,printWidthMm:54,printHeightMm:54,
  regions:[{key:'name',side:'front',kind:'text',x:10,y:10,width:190,height:22},
           {key:'qr',side:'front',kind:'qr',x:10,y:100,width:80,height:80}]},backgrounds:{front}};
}
test('clean package validates and hashes deterministic canonical bytes',()=>{
 const p=validatePackage(fixture(),id),q=validatePackage(fixture(),id);
 assert.equal(p.sha256,q.sha256);assert.equal(p.sha256.length,64);
 assert.equal(p.clean.manifest.id,id);assert.deepEqual(Object.keys(p.clean.backgrounds),['front']);
});
test('reject foreign identity, dynamic sample labels, wrong sides, invalid artwork and region collisions',()=>{
 for(const change of [
  p=>p.manifest.id='gid-'+'b'.repeat(32),
  p=>p.manifest.regions[0].label='Sample person',
  p=>p.manifest.regions[1].y=10,
  p=>p.manifest.regions[1].width=30,
  p=>p.manifest.regions[0].key='arbitrarySample',
  p=>p.backgrounds.back=front,
  p=>p.backgrounds.front='eA==',
  p=>p.manifest.printWidthMm=85.6,
  p=>p.manifest.regions[0].x=-1,
 ]){const p=fixture();change(p);assert.throws(()=>validatePackage(p,id));}
});
