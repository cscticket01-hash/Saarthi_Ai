'use strict';
// The existing GitHub deployment secret stays in this runner. This script
// exports no credentials, writes no school data and changes no IAM or billing.
const fs=require('node:fs'),crypto=require('node:crypto');
const {cert}=require('node:module').createRequire(require.resolve('../../functions/package.json'))('firebase-admin/app');
const PROJECT='saarthi-ai-df12b';
const EXPECTED_RULES='1969bf436853166997dea19e69b6c877062368dd9d5b6ef01f354e6b3228d146';
async function main(){
 const key=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT || '{}');
 if(key.project_id!==PROJECT)throw Error('Wrong or missing developer project credential');
 const {access_token:token}=await cert(key).getAccessToken();console.log('::add-mask::'+token);
 const api=async(path,method='GET',body)=>{
  const r=await fetch('https://firebaserules.googleapis.com/v1/'+path,{method,redirect:'error',signal:AbortSignal.timeout(20000),headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
  if(!r.ok)throw Error('Rules management HTTP '+r.status);return r.json();
 };
 const releasePath='projects/'+PROJECT+'/releases/cloud.firestore';
 const old=await api(releasePath);const source=await api(old.rulesetName);
 const current=source.source.files.map(f=>f.content).join('\n');
 if(crypto.createHash('sha256').update(current).digest('hex')!==EXPECTED_RULES)throw Error('Deployed rules changed since review; refusing to overwrite');
 fs.mkdirSync('staging-rules',{recursive:true});fs.writeFileSync('staging-rules/firestore-before.rules',current);
 const rules=fs.readFileSync('firestore.platform.rules','utf8');
 const created=await api('projects/'+PROJECT+'/rulesets','POST',{source:{files:[{name:'firestore.rules',content:rules}]}});
 const latest=await api(releasePath);
 if(latest.rulesetName!==old.rulesetName)throw Error('Concurrent rules deployment detected; not updating release');
 const updated=await api(releasePath,'PATCH',{release:{name:releasePath,rulesetName:created.name},updateMask:'ruleset_name'});
 if(updated.rulesetName!==created.name)throw Error('Rules release verification failed');
 const verified=await api(updated.rulesetName);
 if(verified.source.files[0].content!==rules)throw Error('Deployed rules content differs');
 fs.writeFileSync('staging-rules/deployment.json',JSON.stringify({projectId:PROJECT,previousRuleset:old.rulesetName,rulesetName:updated.rulesetName,rulesSha256:crypto.createHash('sha256').update(rules).digest('hex'),billingChanged:false,dataChanged:false}));
 console.log('Reviewed central Firestore rules deployed and verified; data, credentials, IAM and billing untouched');
}
main().catch(e=>{const safe=/^(Wrong or missing|Rules management HTTP|Deployed rules changed|Concurrent rules|Rules release verification|Deployed rules content)/.test(String(e.message));console.error(safe?e.message:'Central rules deployment failed; credential details withheld');process.exit(1);});
