export const schoolPattern = /^vs-[a-f0-9]{32}$/;
export const operationPattern = /^[a-f0-9]{64}$/;
export function demand(ok: unknown, message='Invalid sync request', status=400): asserts ok {
 if(!ok) throw Object.assign(new Error(message),{status});
}
export async function boundedBody(request: Pick<Request, 'headers' | 'body'>, limit=400_000): Promise<string> {
 demand(Number(request.headers.get('content-length')||0)<=limit,'Request too large',413);
 const reader=request.body?.getReader(); if(!reader)return '';
 const chunks:Uint8Array[]=[];let size=0;
 try {for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;demand(size<=limit,'Request too large',413);chunks.push(value);}}
 finally {reader.releaseLock();}
 const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
 return new TextDecoder().decode(bytes);
}
export async function digest(value:string):Promise<string>{return hex(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)));}
function hex(buffer:ArrayBuffer):string{return [...new Uint8Array(buffer)].map(x=>x.toString(16).padStart(2,'0')).join('');}
export async function signature(secret:string,value:string):Promise<string>{
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 return hex(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(value)));
}
export async function authenticated(secret:string,raw:string,headers:Headers,at=Date.now()):Promise<boolean>{
 const timestamp=headers.get('x-vidya-time')||'',sig=headers.get('x-vidya-signature')||'';
 if(!/^\d{13}$/.test(timestamp)||Math.abs(at-Number(timestamp))>60000||!/^[a-f0-9]{64}$/.test(sig)||secret.length<32)return false;
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
 const bytes=new Uint8Array(sig.match(/../g)!.map(x=>parseInt(x,16)));
 return crypto.subtle.verify('HMAC',key,bytes,new TextEncoder().encode(timestamp+'\n'+raw));
}
