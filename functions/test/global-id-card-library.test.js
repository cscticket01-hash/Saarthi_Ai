'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {parseSource,accessDecision,publicEntry}=require('../global-id-card-library');
const pdf=Buffer.from('%PDF-1.7\nsynthetic\n%%EOF\n').toString('base64');
test('only confirmed synthetic PDF source with permitted category is accepted',()=>{
 const body={name:'Demo',kind:'studentId',syntheticSampleConfirmed:true,pdfBase64:pdf};
 const value=parseSource(body);assert.equal(value.kind,'studentId');assert.equal(value.sourceSha256.length,64);
 for(const patch of [{kind:'unknown'},{syntheticSampleConfirmed:false},{pdfBase64:'YWJj'},{pdfBase64:pdf+'!'}])
   assert.throws(()=>parseSource({...body,...patch}));
});
test('draft or unverified package never unlocks, even for free or grant',()=>{
 const row={id:'gid-demo',version:1,state:'draft',mappingState:'awaiting_analysis',accessType:'free',pricePaise:0};
 assert.equal(accessDecision(row,null,'school'),false);
 const ready={...row,state:'published',mappingState:'verified',packageVerified:true,packageSha256:'a'.repeat(64)};
 assert.equal(accessDecision(ready,null,'school'),true);
 const paid={...ready,accessType:'premium',pricePaise:100};
 assert.equal(accessDecision(paid,null,'school'),false);
 const grant={schoolId:'school',templateId:row.id,version:1,active:true,source:'developer_grant'};
 assert.equal(accessDecision(paid,grant,'school'),true);
 assert.equal(accessDecision(paid,grant,'another'),false);
 assert.equal(accessDecision({...paid,version:2},grant,'school'),false);
});
test('catalog projection never exposes source path, sample or storage credentials',()=>{
 const result=publicEntry({id:'gid-demo',sourcePath:'private/file.pdf',sourceSha256:'x',sampleName:'do not expose'});
 assert.equal('sourcePath' in result,false);assert.equal('sampleName' in result,false);
});
