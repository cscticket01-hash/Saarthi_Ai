'use strict';
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d',STUDENT='TEST_DELETE_42842637312_acb196df';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const API='https://saarthi-sync-v2-test.onrender.com/school-cloud';
async function post(url,body,token){
 const res=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(70000)});
 const data=await res.json();return {status:res.status,data};
}
async function main(){
 if(process.env.GITHUB_REPOSITORY!=='cscticket01-hash/Saarthi_Ai'||process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REF!=='refs/heads/test/retained-delete-progress-20261111')throw Error('TEST only');
 if(!process.env.VS_TEST_LOGIN_EMAIL||!process.env.VS_TEST_LOGIN_PASSWORD)throw Error('TEST account unavailable');
 const r=await post(LOGIN,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 if(r.status!==200||!r.data.idToken)throw Error('TEST auth unavailable');
 const reply=await post(API,{action:'managed/records',schoolId:SCHOOL,operation:'read',collection:'students_directory',id:STUDENT,syncProtocol:2},r.data.idToken);
 if(reply.status!==200||reply.data.success!==true||reply.data.schoolId!==SCHOOL||reply.data.pointRead!==true)throw Error('Signed isolated TEST point read unavailable');
 const row=reply.data.records?.[STUDENT];
 if(!row||row.schoolId!==SCHOOL)throw Error('Original TEST fixture missing, do not create a replacement');
 const plan=row._syncErasePlan||{};
 const scan=plan.archiveScan||{};
 const diagnostic={testFixturePresent:true,tombstone:row._syncDeleted===true,erasePlanVersion:plan.version||null,
   operationRetained:typeof row._syncOperationId==='string',
   operationMatchesOriginal:row._syncOperationId==='387ff6d3762e8a21f2341ed9fd7506d3',
   erasePlanComplete:plan.complete===true,
   rootRevisionMatches:plan.targets?.[0]?.revision===row._syncRevision,
   rootTargetMatches:plan.targets?.[0]?.collection==='students_directory'&&plan.targets?.[0]?.id===STUDENT,
   targetsProcessed:plan.cursor??null,targetsTotal:Array.isArray(plan.targets)?plan.targets.length:null,
   filesProcessed:plan.fileCursor??null,filesTotal:Array.isArray(plan.files)?plan.files.length:null,
   archiveComplete:plan.archivesComplete===true,
   archiveIndexed:!!plan.archiveIds,
   archivesIndexed:Array.isArray(plan.archiveIds)?plan.archiveIds.length:null,
   archivesRedacted:plan.archiveCursor??null,
   scanningActive:!!plan.archiveScan,
   scanDepth:Array.isArray(scan.stack)?scan.stack.length:null,
   archiveCandidates:Array.isArray(scan.ids)?scan.ids.length:null,
   scanPhase:Array.isArray(scan.stack)&&scan.stack.length?scan.stack.at(-1).phase:null,
   scanTokensPersisted:Array.isArray(scan.stack)?scan.stack.filter(v=>!!v.token).length:null};
 console.log('DELETE_EVERYWHERE_PENDING_DIAGNOSTIC '+JSON.stringify(diagnostic));
}
main().catch(e=>{console.error('DELETE_EVERYWHERE_DIAGNOSTIC_FAILED '+String(e.message).slice(0,100));process.exitCode=1});
