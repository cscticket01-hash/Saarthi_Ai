import {Buffer} from 'node:buffer';
import {demand,schoolPattern} from './protocol';
export type LiveSocketGrant={schoolId:string;uid:string;expiresAt:number;version:1};
export async function liveSocketGrant(request:Request,secret:string,now=Date.now()):Promise<LiveSocketGrant>{
 const protocols=(request.headers.get('Sec-WebSocket-Protocol')||'').split(',').map(x=>x.trim());
 demand(request.headers.get('Upgrade')?.toLowerCase()==='websocket'&&protocols.includes('vidya-live-v1'),'WebSocket protocol required',400);
 const token=protocols.find(x=>x.startsWith('grant.'))?.slice(6)||'';
 demand(token.length<4000,'Invalid live grant',401);const [body,sig,...extra]=token.split('.');
 demand(extra.length===0&&/^[A-Za-z0-9_-]+$/.test(body||'')&&/^[a-f0-9]{64}$/.test(sig||''),'Live grant required',401);
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
 demand(await crypto.subtle.verify('HMAC',key,new Uint8Array(Buffer.from(sig,'hex')),new TextEncoder().encode('live-v1\n'+body)),'Live grant rejected',401);
 const value=JSON.parse(Buffer.from(body,'base64url').toString('utf8')) as LiveSocketGrant;
 demand(value.version===1&&schoolPattern.test(value.schoolId)&&typeof value.uid==='string'&&value.uid.length>0&&Number.isSafeInteger(value.expiresAt)&&value.expiresAt>now&&value.expiresAt<=now+60000,'Live grant expired',401);
 return value;
}
