/** Native Drive resumable sessions stay private to this school Script.
 * The existing durable uploadKey remains the owner; offsets never certify ACKs.
 */
function VS_uploadDigest(bytes){return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');}
function VS_uploadHeaders(response){const out={};Object.keys(response.getAllHeaders()).forEach(k=>out[k.toLowerCase()]=String(response.getAllHeaders()[k]));return out;}
function VS_uploadFetch(url,options){
 if(!/^https:\/\/www\.googleapis\.com\/(?:upload\/)?drive\/v3\//.test(url))throw new Error('Invalid private upload endpoint');
 const response=UrlFetchApp.fetch(url,Object.assign({muteHttpExceptions:true,followRedirects:false},options,{headers:Object.assign({},options.headers||{},{Authorization:'Bearer '+ScriptApp.getOAuthToken()})}));
 const status=response.getResponseCode();
 if(status===429)throw new Error('Upload quota exceeded');
 if(status===401||status===403)throw new Error('Upload permission denied');
 if(status>=500)throw new Error('Upload timeout; retain upload key');
 return response;
}
function VS_uploadVerified(state){
 const response=VS_uploadFetch('https://www.googleapis.com/drive/v3/files/'+state.fileId+'?fields=id,parents,size,sha256Checksum,mimeType,description,trashed',{method:'get'});
 if(response.getResponseCode()===404)return null;
 if(response.getResponseCode()!==200)throw new Error('Upload metadata verification unavailable');
 const file=JSON.parse(response.getContentText());
 if(file.id!==state.fileId||file.trashed||Number(file.size)!==state.sizeBytes||file.mimeType!==state.mime||file.description!==state.marker||!Array.isArray(file.parents)||!file.parents.includes(state.parent))throw new Error('Upload identity verification failed');
 const digest=file.sha256Checksum||VS_uploadDigest(VS_managedFile(file.id).getBlob().getBytes());
 if(digest!==state.sha256)throw new Error('Upload content verification failed');
 return {uploadResumableVersion:1,committed:true,offset:state.sizeBytes,sizeBytes:state.sizeBytes,sha256:state.sha256,uploadKey:state.uploadKey,fileId:file.id,fileUrl:'https://drive.google.com/file/d/'+file.id+'/view'};
}
function VS_uploadPosition(response,state){
 const code=response.getResponseCode();
 if(code===200||code===201)return state.sizeBytes;
 if(code!==308)throw new Error('Upload session status unavailable');
 const range=VS_uploadHeaders(response).range;
 if(!range)return 0;
 if(!/^bytes=0-\d+$/.test(range))throw new Error('Invalid provider upload range');
 const next=Number(range.slice(8))+1;
 if(!Number.isSafeInteger(next)||next<1||next>=state.sizeBytes)throw new Error('Invalid provider upload offset');
 return next;
}
function VS_managedResumableUpload(b){
 if(PropertiesService.getScriptProperties().getProperty('VS_NATIVE_RESUMABLE_UPLOAD')!=='1')throw new Error('Native upload provider requires owner opt-in');
 if(!['begin','status','part'].includes(b.operation)||!/^[A-Za-z0-9_-]{1,150}$/.test(b.uploadKey||'')||!/^[a-f0-9]{64}$/.test(b.sha256||'')||!Number.isSafeInteger(b.sizeBytes)||b.sizeBytes<1||b.sizeBytes>20*1024*1024||typeof b.name!=='string'||!b.name||b.name.length>200||!/^[-\w.+]+\/[-\w.+]+$/.test(b.mime||'')||b.mime.indexOf('application/vnd.google-apps.')===0)throw new Error('Invalid resumable upload');
 let bytes=null;
 if(b.operation==='part'){
  if(!Number.isSafeInteger(b.offset)||b.offset<0||b.offset>=b.sizeBytes||typeof b.base64!=='string'||b.base64.length>700000||!/^[a-f0-9]{64}$/.test(b.chunkSha256||''))throw new Error('Invalid upload chunk');
  bytes=Utilities.base64Decode(b.base64);
  if(!bytes.length||bytes.length>512*1024||b.offset+bytes.length>b.sizeBytes||(b.offset+bytes.length<b.sizeBytes&&bytes.length%(256*1024)!==0)||VS_uploadDigest(bytes)!==b.chunkSha256)throw new Error('Upload chunk verification failed');
 }
 const lock=LockService.getScriptLock();lock.waitLock(30000);
 try{
  const props=PropertiesService.getScriptProperties(),school=props.getProperty('VS_MANAGED_SCHOOL_ID'),root=VS_managedRoot();
  const key='VS_UPLOAD_SESSION_'+VS_uploadDigest(school+'\n'+b.uploadKey),marker='VIDYA_UPLOAD:'+school+':'+b.uploadKey+':'+b.sha256;
  const stored=props.getProperty(key);let state=stored?JSON.parse(stored):null;
  if(state&&(state.schoolId!==school||state.rootId!==root.getId()||state.uploadKey!==b.uploadKey||state.name!==b.name||state.mime!==b.mime||state.sha256!==b.sha256||state.sizeBytes!==b.sizeBytes))throw new Error('Upload key collision; existing file retained');
  if(!state){
   const target=props.getProperty('VS_LAYOUT_JOB')?VS_managedFolder(root,'Other_Files'):VS_managedFolder(VS_managedFolder(root,'Files'),b.mime.indexOf('image/')===0?'Photos':'Documents');
   let existing=null;
   for(const folder of VS_layoutUploadFolders(root,target)){
    const matches=folder.getFilesByName(b.name);
    while(matches.hasNext()){
     const file=matches.next();if(file.getDescription()!==marker||(existing&&existing.getId()!==file.getId()))throw new Error('Upload key collision; existing file retained');existing=file;
    }
   }
   state={schoolId:school,rootId:root.getId(),parent:target.getId(),uploadKey:b.uploadKey,name:b.name,mime:b.mime,sha256:b.sha256,sizeBytes:b.sizeBytes,marker};
   if(existing){state.fileId=existing.getId();state.parent=VS_managedFile(existing.getId()).getParents().next().getId();return VS_uploadVerified(state);}
   if(Object.keys(props.getProperties()).filter(k=>k.indexOf('VS_UPLOAD_SESSION_')===0).length>=64)throw new Error('Upload session capacity reached; retain pending');
   const allocated=VS_uploadFetch('https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive&type=files',{method:'get'});
   if(allocated.getResponseCode()!==200)throw new Error('Upload allocation unavailable');
   const id=JSON.parse(allocated.getContentText()).ids?.[0];if(!/^[A-Za-z0-9_-]{1,200}$/.test(id||''))throw new Error('Invalid allocated upload identity');
   state.fileId=id;props.setProperty(key,JSON.stringify(state));
  }
  // A fixed preallocated file ID resolves a lost init/final ACK without duplicates.
  const completed=VS_uploadVerified(state);if(completed){props.deleteProperty(key);return completed;}
  const persist=()=>props.setProperty(key,JSON.stringify(state));
  const begin=()=>{
   const response=VS_uploadFetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id',{method:'post',contentType:'application/json',headers:{'X-Upload-Content-Type':state.mime,'X-Upload-Content-Length':String(state.sizeBytes)},payload:JSON.stringify({id:state.fileId,name:state.name,mimeType:state.mime,parents:[state.parent],description:state.marker,appProperties:{schoolId:school}})});
   if(response.getResponseCode()!==200)throw new Error('Upload session initialization unavailable');
   const url=VS_uploadHeaders(response).location;
   if(typeof url!=='string'||url.length>3000||!/^https:\/\/www\.googleapis\.com\/upload\/drive\/v3\/files(?:\/[A-Za-z0-9_-]+)?\?[^#\s]+$/.test(url))throw new Error('Invalid private upload session');
   state.url=url;persist();
  };
  if(!state.url)begin();
  let response=VS_uploadFetch(state.url,{method:'put',headers:{'Content-Range':'bytes */'+state.sizeBytes},payload:''});
  if(response.getResponseCode()===404){delete state.url;persist();begin();response=VS_uploadFetch(state.url,{method:'put',headers:{'Content-Range':'bytes */'+state.sizeBytes},payload:''});}
  let offset=VS_uploadPosition(response,state);
  if(offset===state.sizeBytes){const out=VS_uploadVerified(state);if(!out)throw new Error('Upload completion unverified');props.deleteProperty(key);return out;}
  if(b.operation==='part'&&offset===b.offset){
   response=VS_uploadFetch(state.url,{method:'put',contentType:state.mime,headers:{'Content-Range':'bytes '+offset+'-'+(offset+bytes.length-1)+'/'+state.sizeBytes},payload:bytes});
   offset=VS_uploadPosition(response,state);
   if(offset===state.sizeBytes){const out=VS_uploadVerified(state);if(!out)throw new Error('Upload completion unverified');props.deleteProperty(key);return out;}
  }
  return {uploadResumableVersion:1,committed:false,uploadKey:state.uploadKey,sha256:state.sha256,sizeBytes:state.sizeBytes,offset};
 }finally{lock.releaseLock();}
}
