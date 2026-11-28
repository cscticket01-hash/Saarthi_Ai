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

test('source style and unique explicit image label are suggestions without sample values',()=>{
 const {enrichCandidates}=require('../global-id-card-analysis');
 const page={canvasWidth:240,canvasHeight:150,candidates:[{key:'name',x:80,y:40,width:50,height:10}],imageCandidates:[{x:10,y:10,width:30,height:30,role:'unclassified'}]};
 const xml='<page width="240" height="150"><fontspec id="0" size="10" family="ABCDEF+DejaVuSans-Bold" color="#123456"/><text left="80" top="40" width="50" height="10" font="0">Synthetic person</text><text left="10" top="42" width="30" height="8" font="0">Photo</text></page>';
 enrichCandidates(xml,[page]);
 assert.equal(page.candidates[0].sourceFont,'DejaVuSans-Bold');
 assert.equal(page.candidates[0].bold,true);assert.equal(page.candidates[0].textColor,'#123456');
 assert.equal(page.imageCandidates[0].suggestedRole,'photo');
 assert.equal(JSON.stringify(page).includes('Synthetic person'),false);
});

test('reserved sample phrase maps label-free name without exposing the sample string',()=>{
 const xml='<page width="242" height="153"><line><word xMin="10" yMin="20" xMax="30" yMax="30">Sample</word><word xMin="31" yMin="20" xMax="55" yMax="30">Student</word><word xMin="56" yMin="20" xMax="75" yMax="30">Name</word></line></page>';
 const page=parseCandidates(xml)[0];assert.equal(page.candidates[0].key,'name');assert.equal(page.candidates[0].evidence,'reserved_sample_phrase');assert.equal(JSON.stringify(page).includes('Student'),false);
});

test('unique unlabeled layout suggestions stay unclassified and ambiguous roles stay unset',()=>{
 const {enrichCandidates}=require('../global-id-card-analysis');
 const photo={x:20,y:40,width:60,height:70,role:'unclassified',reviewRequired:true};
 const page={canvasWidth:240,canvasHeight:150,candidates:[{key:'name',x:85,y:70,width:50,height:10}],
  imageCandidates:[photo,{x:8,y:8,width:30,height:30},{x:25,y:116,width:62,height:14},
   {x:180,y:103,width:28,height:28},{x:0,y:0,width:240,height:150}]};
 const xml='<page width="240" height="150"><text left="48" top="14" width="65" height="10">Sample School</text></page>';
 enrichCandidates(xml,[page]);
 assert.deepEqual(page.imageCandidates.map(r=>r.suggestedRole),['photo','logo','signature','seal','__static']);
 assert.ok(page.imageCandidates.every(r=>r.roleConfidence==='low'));
 assert.equal(photo.role,'unclassified');
 assert.equal(photo.reviewRequired,true);
 delete photo.suggestedRole;
 page.imageCandidates.push({x:142,y:40,width:60,height:70});
 enrichCandidates(xml,[page]);
 assert.equal(photo.suggestedRole,undefined);
});
