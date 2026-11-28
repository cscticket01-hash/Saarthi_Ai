'use strict';

const {createHash}=require('node:crypto');
const {MAX_PDF_BYTES}=require('./global-id-card-library');

const CAPACITY_BYTES=2_000_000_000;
const OBJECT_KEY=/^global-id-card-library\/(?:private\/gid-[a-f0-9]{32}\/source\.pdf|verified\/gid-[a-f0-9]{32}\/v[1-9]\d{0,4}\/[a-f0-9]{64}\.json)$/;

function storageError(status,message){
  return Object.assign(new Error(message),{status,publicMessage:true});
}

function createGlobalIdCardR2({db,accountId,bucketName,request}){
  if(!/^[a-f0-9]{32}$/.test(accountId)||!/^saarthi-id-library-(?:staging|prod)$/.test(bucketName))
    throw new Error('A dedicated Global ID Card R2 bucket is required');

  const endpoint='https://'+accountId+'.r2.cloudflarestorage.com/'+bucketName;
  const quota=db.doc('global_id_card_storage/'+accountId);

  async function reserve(key,size){
    const id=createHash('sha256').update(bucketName+'/'+key).digest('hex');
    const object=db.doc(quota.path+'/objects/'+id);
    await db.runTransaction(async tx=>{
      const [counter,existing]=await Promise.all([tx.get(quota),tx.get(object)]);
      const used=counter.exists?counter.data()?.reservedBytes:0;
      if(!Number.isSafeInteger(used)||used<0||used>CAPACITY_BYTES)
        throw storageError(503,'ID Card Library storage accounting is unavailable');
      if(existing.exists){
        if(existing.data()?.size!==size||!counter.exists)
          throw storageError(503,'ID Card Library storage reservation is invalid');
        return;
      }
      if(used+size>CAPACITY_BYTES)throw storageError(507,'ID Card Library 2 GB storage limit reached');
      // Keep reservations after uncertain writes so retries cannot overbook R2.
      tx.create(object,{size});
      tx.set(quota,{reservedBytes:used+size});
    });
  }

  async function verifyPrivateStorage(){
    try{
      const response=await request(endpoint,{method:'HEAD',signal:AbortSignal.timeout(5000)});
      return response.ok
        ? {ready:true,reason:'reviewed_r2_bucket_reachable'}
        : {ready:false,reason:'r2_bucket_permission_or_connectivity'};
    }catch(_){
      return {ready:false,reason:'r2_bucket_permission_or_connectivity'};
    }
  }

  function file(key){
    if(!OBJECT_KEY.test(key))throw storageError(503,'Invalid ID Card Library storage path');
    const url=endpoint+'/'+key;
    return {
      async save(bytes,{metadata}){
        if(!Buffer.isBuffer(bytes)||bytes.length===0||bytes.length>MAX_PDF_BYTES)
          throw storageError(400,'Invalid ID Card Library object size');
        await reserve(key,bytes.length);
        const response=await request(url,{method:'PUT',body:bytes,signal:AbortSignal.timeout(15000),headers:{
          'If-None-Match':'*','Content-Type':metadata.contentType,'Cache-Control':'private,no-store',
        }});
        if(!response.ok){
          await response.body?.cancel();
          if(response.status===412)throw Object.assign(new Error('Object already exists'),{code:412});
          throw storageError(503,'ID Card Library object write failed');
        }
      },
      async download(){
        const response=await request(url,{method:'GET',signal:AbortSignal.timeout(15000)});
        if(!response.ok||!response.body){
          await response.body?.cancel();
          throw storageError(503,'ID Card Library object read failed');
        }
        const reader=response.body.getReader(),chunks=[];
        let length=0;
        try{
          while(true){
            const {done,value}=await reader.read();
            if(done)break;
            length+=value.byteLength;
            if(length>MAX_PDF_BYTES){
              await reader.cancel();
              throw storageError(503,'ID Card Library object exceeds size limit');
            }
            chunks.push(value);
          }
        }finally{reader.releaseLock();}
        return [Buffer.concat(chunks,length)];
      },
    };
  }

  return {file,verifyPrivateStorage};
}

module.exports={createGlobalIdCardR2};
