'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {parseCandidates}=require('../global-id-card-analysis');
test('text mapping provides geometry only and no sample values',()=>{
 const xml='<page width="242" height="153"><line><word xMin="10" yMin="20" xMax="30" yMax="30">Name:</word><word xMin="32" yMin="20" xMax="70" yMax="30">Synthetic</word></line></page>';
 const pages=parseCandidates(xml);assert.equal(pages[0].candidates[0].key,'name');assert.equal(pages[0].candidates[0].x,32);
 assert.equal(JSON.stringify(pages).includes('Synthetic'),false);
 assert.throws(()=>parseCandidates(xml.repeat(3)));
});

test('image geometry is scaled to design units and never includes extracted sample filenames',()=>{
 const {parseImageCandidates}=require('../global-id-card-analysis');
 const pages=[{side:'front',canvasWidth:240,canvasHeight:150}];
 const xml='<page number="1" width="480" height="300"><image top="20" left="40" width="80" height="100" src="sample-person.png"/><image top="0" left="-10" width="20" height="20" src="invalid.png"/></page>';
 const result=parseImageCandidates(xml,pages);
 assert.deepEqual(result,[[{side:'front',x:20,y:10,width:40,height:50,kind:'image',role:'unclassified',reviewRequired:true}]]);
 assert.equal(JSON.stringify(result).includes('sample-person'),false);
 assert.throws(()=>parseImageCandidates(xml,[{...pages[0],canvasHeight:300}]));
});

test('separate PDF text objects and multiple fields on one row map without leaking values',()=>{
 const word=(x,right,value)=>'<word xMin="'+x+'" yMin="40" xMax="'+right+'" yMax="50">'+value+'</word>';
 const xml='<page width="242" height="153">'+
  '<line>'+word(10,30,'Class')+'</line><line>'+word(32,34,':')+word(36,50,'Demo')+'</line>'+
  '<line>'+word(80,95,'Roll')+word(98,110,'No:')+'</line><line>'+word(112,132,'Hidden')+'</line></page>';
 const result=parseCandidates(xml)[0].candidates;
 assert.deepEqual(result.map(r=>[r.key,r.x,r.width]),[['class',36,14],['rollNo',112,20]]);
 assert.equal(JSON.stringify(result).includes('Hidden'),false);
});
