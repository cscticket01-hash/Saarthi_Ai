// Broker transport backoff only. Never interpret an HTTP response as a Google receipt.
// A valid Retry-After is a minimum, even if another lane wakes this school owner.
export function brokerRetryDelay(status, retryAfter, now=Date.now()) {
 if(status>=200&&status<300)return 250;
 const floor=status===429?60000:30000;
 if(typeof retryAfter!=='string'||!retryAfter.trim())return floor;
 const value=retryAfter.trim();
 let delay;
 if(/^\d+$/.test(value))delay=Number(value)*1000;
 else if(/^[A-Za-z]{3}, /.test(value))delay=Date.parse(value)-now;
 else return floor;
 if(!Number.isSafeInteger(delay)||delay<0||!Number.isSafeInteger(now+delay)||now+delay>8640000000000000)return floor;
 return Math.max(floor,delay);
}
