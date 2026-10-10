/** Isolated TEST disaster rehearsal. Never activates storage or changes source.
 * Each resume copies/verifies one binary or 25 rows. Immutable checkpoints and
 * stable operation IDs permit lost-response retry without duplicate copies.
 * Scope: managed records/tombstones and owned uploaded bytes; not Firebase
 * credentials, active local queues or Google-native documents.
 */
function VS_disasterGuard() {
  if(!VS_testBackupRecoveryEnabled())throw new Error('Isolated TEST backup authorization required');
  return PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
}
function VS_disasterInventory() {
  const queue=[VS_managedRoot()],seen={},out=[];let visited=0;
  while(queue.length){const folder=queue.shift(),id=folder.getId(),name=folder.getName();
    if(seen[id]||++visited>5000)throw new Error('Disaster inventory requires review');seen[id]=true;
    if(['Backups','Backup_And_Recovery'].includes(name)||name.indexOf('records_')===0)continue;
    const children=folder.getFolders();while(children.hasNext())queue.push(children.next());
    const files=folder.getFiles();while(files.hasNext()){const file=files.next(),mime=file.getMimeType();
      if(mime==='application/vnd.google-apps.spreadsheet')continue;
      if(mime.indexOf('application/vnd.google-apps.')===0||file.getSize()>20*1024*1024||out.length>=1000)throw new Error('Disaster binary scope requires review');
      out.push({id:file.getId(),name:file.getName(),mime:mime,size:file.getSize()});
    }
  }return out.sort((a,b)=>a.id.localeCompare(b.id));
}
function VS_disasterRead(id) {
  const school=VS_disasterGuard(),file=VS_managedFile(id);
  if(file.getSize()>20*1024*1024)throw new Error('Disaster checkpoint requires review');
  const text=file.getBlob().getDataAsString();
  if(file.getDescription()!=='VIDYA_DISASTER:'+school+':'+VS_layoutHash(text))throw new Error('Disaster checkpoint integrity requires review');
  const state=JSON.parse(text);if(state.schoolId!==school||state.version!==5)throw new Error('Foreign disaster checkpoint');return state;
}
function VS_disasterSave(folder,state) {
  const text=JSON.stringify(state);if(text.length>20*1024*1024)throw new Error('Disaster checkpoint requires review');
  const file=folder.createFile('checkpoint_'+Utilities.getUuid()+'.json',text,'application/json');
  file.setDescription('VIDYA_DISASTER:'+state.schoolId+':'+VS_layoutHash(text));
  if(JSON.stringify(VS_disasterRead(file.getId()))!==text)throw new Error('Disaster checkpoint verification failed');return file.getId();
}
function VS_disasterCopy(folder,source,hash) {
  const name='binary_'+source.getId(),found=folder.getFilesByName(name);let copy;
  if(found.hasNext()){copy=found.next();if(found.hasNext())throw new Error('Disaster copy collision');}
  else copy=folder.createFile(Utilities.newBlob(source.getBlob().getBytes(),source.getMimeType(),name));
  if(VS_layoutBytesHash(copy.getBlob().getBytes())!==hash)throw new Error('Disaster binary verification failed');
  copy.setDescription('VIDYA_DISASTER_BINARY:'+VS_disasterGuard()+':'+hash);return copy.getId();
}
function VS_disasterHeads(backup) {
  const p=PropertiesService.getScriptProperties(),current=p.getProperties();
  if(VS_disasterCollections(current).length!==Object.keys(backup.collectionRevisions).length||
    Object.keys(backup.collectionRevisions).some(col=>(p.getProperty('VS_RECORD_REV_'+col)||'legacy')!==backup.collectionRevisions[col]))throw new Error('Disaster source changed; retry a new backup generation');
}
function VS_disasterCollections(properties) {
  const folders=VS_managedRoot().getFolders();while(folders.hasNext()){const folder=folders.next(),name=folder.getName();
    if(name.indexOf('records_')===0&&properties['VS_SHEET_MIGRATED_'+name.slice(8)]!=='1'&&folder.getFiles().hasNext())throw new Error('Legacy disaster record scope requires operator review');
  }
  return VS_LAYOUT_COLLECTIONS.filter(col=>properties['VS_RECORD_REV_'+col]||properties['VS_SHEET_MIGRATED_'+col]==='1'||properties['VS_LAYOUT_'+col]);
}
function VS_managedDisaster(b) {
  VS_BACKUP_READ_CACHE=null;
  const school=VS_disasterGuard(),p=PropertiesService.getScriptProperties();
  if(!/^[a-f0-9]{64}$/.test(b.operationId||'')||!['backup','rehearse'].includes(b.operation))throw new Error('Invalid disaster operation');
  const key='VS_DISASTER_'+b.operation+'_'+b.operationId,leaseKey=key+'_LEASE',token=Utilities.getUuid(),lock=LockService.getScriptLock();
  lock.waitLock(5000);try{if(Number(p.getProperty(leaseKey)||0)>Date.now())throw new Error('Disaster job busy; retry shortly');p.setProperty(leaseKey,String(Date.now()+120000));p.setProperty(leaseKey+'_TOKEN',token);}finally{lock.releaseLock();}
  try {
    const parent=VS_managedFolder(VS_managedRoot(),'Backups'),folder=VS_managedFolder(parent,'Disaster_'+b.operation+'_'+b.operationId);
    let pointer=p.getProperty(key),state=pointer?VS_disasterRead(pointer):null;const wasComplete=state&&state.complete===true;
    if(state&&(state.operationId!==b.operationId||state.operation!==b.operation||state.sourceId!==(b.fileId||'')))throw new Error('Disaster operation ID conflict');
    if(!state){
      if(b.operation==='backup'){
        state={version:5,schoolId:school,operation:'backup',operationId:b.operationId,sourceId:'',
          inventory:[],copies:[],cursor:0,phase:'capturing',complete:false,createdAt:Date.now(),records:{},collectionRevisions:{}};
        const properties=p.getProperties();VS_disasterCollections(properties).forEach(col=>state.collectionRevisions[col]=properties['VS_RECORD_REV_'+col]||'legacy');
      }else{
        const source=VS_disasterRead(b.fileId);if(source.operation!=='backup'||source.complete!==true)throw new Error('Verified complete disaster backup required');
        VS_verifiedRecordBackup(source.recordBackupId);
        state={version:5,schoolId:school,operation:'rehearse',operationId:b.operationId,sourceId:b.fileId,recordBackupId:source.recordBackupId,
          inventory:source.copies,copies:[],cursor:0,rowCursor:0,phase:'copying',complete:false,createdAt:Date.now()};
      }
    }else if(!state.complete){
      const backup=state.phase==='capturing'?state:VS_verifiedRecordBackup(state.recordBackupId);
      if(state.phase==='capturing'){
        const collections=Object.keys(state.collectionRevisions);VS_disasterHeads(state);
        if(state.cursor<collections.length){const col=collections[state.cursor],result=VS_managedRecord({collection:col,operation:'read',syncProtocol:2});
          if(result.collectionRevision!==state.collectionRevisions[col])throw new Error('Disaster source changed; retry a new backup generation');state.records[col]=result.records;state.cursor++;}
        else{VS_disasterHeads(state);const recordBackup={schemaVersion:4,schoolId:school,createdAt:state.createdAt,records:state.records,collectionRevisions:state.collectionRevisions,scope:'records_and_tombstones',documentBinariesIncluded:false};
          const text=JSON.stringify(recordBackup);if(text.length>20*1024*1024)throw new Error('Disaster checkpoint requires review');const file=folder.createFile('Verified_Records.json',text,'application/json');
          file.setDescription('VIDYA_RECORD_BACKUP:'+school+':'+VS_layoutHash(text));state.recordBackupId=file.getId();VS_BACKUP_READ_CACHE=null;VS_verifiedRecordBackup(file.getId());
          delete state.records;delete state.collectionRevisions;state.inventory=VS_disasterInventory();state.phase='copying';state.cursor=0;}
      }else if(state.phase==='copying'&&state.cursor<state.inventory.length){
        const entry=state.inventory[state.cursor],source=VS_managedFile(state.operation==='backup'?entry.id:entry.copyId),bytes=source.getBlob().getBytes(),hash=VS_layoutBytesHash(bytes);
        if(source.getSize()>20*1024*1024||(state.operation==='backup'&&(source.getSize()!==entry.size||source.getName()!==entry.name||source.getMimeType()!==entry.mime))||(entry.hash&&hash!==entry.hash))throw new Error('Disaster source integrity requires review');
        const copyId=VS_disasterCopy(folder,source,hash);state.copies.push(Object.assign({},entry,{copyId:copyId,hash:hash}));state.cursor++;
      }else if(state.phase==='copying'){state.phase=state.operation==='backup'?'verifying':'records';state.cursor=0;}
      else if(state.phase==='records'){
        // A new private workbook only. Source/active school sheet IDs never change.
        let book;if(state.workbookId)book=SpreadsheetApp.openById(VS_managedFile(state.workbookId).getId());
        else{const matches=folder.getFilesByName('Disaster_Rehearsal_Records');if(matches.hasNext()){const f=matches.next();if(matches.hasNext()||f.getDescription()!=='VIDYA_DISASTER_SHEET:'+school+':'+b.operationId)throw new Error('Disaster workbook collision');book=SpreadsheetApp.openById(f.getId());}
          else{book=SpreadsheetApp.create('Disaster_Rehearsal_Records');const f=DriveApp.getFileById(book.getId());f.setDescription('VIDYA_DISASTER_SHEET:'+school+':'+b.operationId);f.moveTo(folder);}state.workbookId=book.getId();}
        let sheet=book.getSheetByName('ArchiveRecords');if(!sheet){sheet=book.insertSheet('ArchiveRecords');sheet.getRange(1,1,1,4).setValues([['Collection','Record ID JSON','JSON part','Verified original JSON prefixed json:']]);}
        const rows=VS_disasterRows(backup);const recordCount=Object.keys(backup.records).reduce((sum,col)=>sum+Object.keys(backup.records[col]).length,0);
        const batch=rows.slice(state.rowCursor,state.rowCursor+25);if(batch.length){const required=state.rowCursor+batch.length+1;if(required>sheet.getMaxRows())sheet.insertRowsAfter(sheet.getMaxRows(),required-sheet.getMaxRows());sheet.getRange(state.rowCursor+2,1,batch.length,4).setValues(batch);SpreadsheetApp.flush();
          if(JSON.stringify(sheet.getRange(state.rowCursor+2,1,batch.length,4).getValues())!==JSON.stringify(batch))throw new Error('Disaster Sheets readback failed');state.rowCursor+=batch.length;}
        if(state.rowCursor===rows.length){state.recordCount=recordCount;state.phase='recordsVerification';state.cursor=0;}
      }else if(state.phase==='recordsVerification'){
        const rows=VS_disasterRows(backup),sheet=SpreadsheetApp.openById(VS_managedFile(state.workbookId).getId()).getSheetByName('ArchiveRecords');
        const batch=rows.slice(state.cursor,state.cursor+25);
        if(!sheet||JSON.stringify(sheet.getRange(state.cursor+2,1,batch.length||1,4).getValues().slice(0,batch.length))!==JSON.stringify(batch)||sheet.getLastRow()!==rows.length+1)throw new Error('Disaster Sheets readback failed');
        state.cursor+=batch.length;if(state.cursor===rows.length){state.phase='verifying';state.cursor=0;}
      }else if(state.phase==='verifying'){
        if(state.cursor<state.copies.length){const entry=state.copies[state.cursor],copy=VS_managedFile(entry.copyId);if(VS_layoutBytesHash(copy.getBlob().getBytes())!==entry.hash)throw new Error('Disaster binary verification failed');state.cursor++;}
        else{if(state.operation==='backup'){VS_disasterHeads(backup);if(JSON.stringify(VS_disasterInventory())!==JSON.stringify(state.inventory))throw new Error('Disaster source changed; retry a new backup generation');}
          state.complete=true;state.phase='verified';state.verifiedAt=Date.now();state.activeStorageChanged=false;}
      }else throw new Error('Disaster checkpoint requires review');
    }
    if(!wasComplete){
      pointer=VS_disasterSave(folder,state);
      const commit=LockService.getScriptLock();commit.waitLock(5000);try{if(p.getProperty(leaseKey+'_TOKEN')!==token)throw new Error('Disaster lease expired; copies retained');p.setProperty(key,pointer);}finally{commit.releaseLock();}
    }
    return {disasterVersion:5,operation:state.operation,operationId:state.operationId,fileId:pointer,phase:state.phase,complete:state.complete,
      verified:state.complete,verifiedAt:state.verifiedAt||0,binaryCount:state.inventory.length,copied:state.copies.length,recordCount:state.recordCount||0,
      activeStorageChanged:false,scope:'managed_records_and_uploaded_bytes',firebaseCredentialsIncluded:false,localPendingQueuesIncluded:false};
  }finally{const release=LockService.getScriptLock();release.waitLock(5000);try{if(p.getProperty(leaseKey+'_TOKEN')===token){p.deleteProperty(leaseKey);p.deleteProperty(leaseKey+'_TOKEN');}}finally{release.releaseLock();}}
}
function VS_disasterRows(backup) {
  const rows=[];Object.keys(backup.records).sort().forEach(col=>Object.keys(backup.records[col]).sort().forEach(id=>{const text=JSON.stringify(backup.records[col][id]);
    for(let n=0;n<text.length;n+=40000)rows.push([col,JSON.stringify(id),n/40000,'json:'+text.slice(n,n+40000)]);
  }));return rows;
}
