// Permanent school-scoped UID reservations. Internal server foundation only.
// Wire to verified person ownership and migration before production activation.
export type PersonCategory = 'student' | 'teacher' | 'officeStaff' | 'otherStaff';
export type UidFamily = 'STU' | 'TCH' | 'STF';
type Scalar = string | number;
export interface UidStorage {
  sql: {exec(query: string, ...values: Scalar[]): {toArray(): unknown[]}};
  transactionSync<T>(callback: () => T): T;
}
type Assignment = {personId: string; uid: string};
type Row = {person_id: string; uid: string};
const families: UidFamily[] = ['STU','TCH','STF'];
function requireUid(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}
function schoolCheck(id: string) {
  requireUid(/^vs-[a-f0-9]{32}$/.test(id), 'Invalid school identity');
}
function personCheck(id: string) {
  requireUid(/^p-[a-f0-9]{32,64}$/.test(id), 'Verified permanent person identity required');
}
export function uidFamily(category: PersonCategory): UidFamily {
  switch (category) {
    case 'student': return 'STU';
    case 'teacher': return 'TCH';
    case 'officeStaff':
    case 'otherStaff': return 'STF';
    default: throw new Error('Invalid person category');
  }
}
export function uidNameCode(name: string): string {
  requireUid(typeof name === 'string' && name.length <= 500, 'Invalid UID name');
  const letters = Array.from(name.normalize('NFKD').toUpperCase()).filter(c => /\p{L}/u.test(c));
  requireUid(letters.length > 0, 'A name containing letters is required');
  return letters.slice(0,4).join('') + 'X'.repeat(Math.max(0,4-letters.length));
}
export function formatUid(family: UidFamily, code: string, name: string, serial: number): string {
  requireUid(families.includes(family), 'Invalid UID family');
  requireUid(/^\p{L}{4}$/u.test(code), 'Invalid school UID code');
  requireUid(Number.isInteger(serial) && serial >= 1 && serial <= 999999, 'UID sequence exhausted or invalid');
  return [family,code,uidNameCode(name),String(serial).padStart(6,'0')].join('-');
}
const key = (uid: string) => uid.trim().normalize('NFKC').toUpperCase();
export class UniversalUidRegistry {
  private readonly storage: UidStorage;
  constructor(storage: UidStorage) {
    this.storage = storage;
    storage.sql.exec('CREATE TABLE IF NOT EXISTS universal_uid_schools(school_id TEXT PRIMARY KEY,school_code TEXT NOT NULL)');
    storage.sql.exec('CREATE TABLE IF NOT EXISTS universal_uid_counters(school_id TEXT NOT NULL,family TEXT NOT NULL,next_number INTEGER NOT NULL,PRIMARY KEY(school_id,family))');
    storage.sql.exec('CREATE TABLE IF NOT EXISTS universal_uid_assignments(school_id TEXT NOT NULL,person_id TEXT NOT NULL,uid TEXT NOT NULL,uid_key TEXT NOT NULL,family TEXT,serial INTEGER,PRIMARY KEY(school_id,person_id),UNIQUE(school_id,uid_key),UNIQUE(school_id,family,serial))');
  }
  private school(id: string) {
    return this.storage.sql.exec('SELECT school_code FROM universal_uid_schools WHERE school_id=?',id).toArray()[0] as {school_code:string}|undefined;
  }
  /** Only a server-verified COMPLETE inventory, including retired reservations,
   * may initialize this ledger. Missing proof must not be replaced with [].
   * Duplicate legacy ownership or serials roll back migration atomically.
   */
  initializeSchool(schoolId: string, schoolName: string, verifiedLegacy: readonly Assignment[]): void {
    schoolCheck(schoolId);
    const code = uidNameCode(schoolName);
    requireUid(Array.isArray(verifiedLegacy) && verifiedLegacy.length <= 100000,'Invalid legacy inventory');
    this.storage.transactionSync(() => {
      requireUid(!this.school(schoolId),'UID registry already initialized');
      const next: Record<UidFamily,number> = {STU:1,TCH:1,STF:1};
      this.storage.sql.exec('INSERT INTO universal_uid_schools VALUES(?,?)',schoolId,code);
      for(const a of verifiedLegacy) {
        personCheck(a.personId);
        requireUid(typeof a.uid==='string' && a.uid.trim().length>0 && a.uid.length<=200,'Invalid legacy UID');
        const parsed = /^(STU|TCH|STF)-\p{L}{4}-\p{L}{4}-(\d{6})$/u.exec(key(a.uid));
        if(parsed){
          const f=parsed[1] as UidFamily,n=Number(parsed[2]);
          requireUid(n>=1,'Invalid legacy serial');
          this.storage.sql.exec('INSERT INTO universal_uid_assignments VALUES(?,?,?,?,?,?)',schoolId,a.personId,a.uid,key(a.uid),f,n);
          next[f]=Math.max(next[f],n+1);
        }else{
          this.storage.sql.exec('INSERT INTO universal_uid_assignments VALUES(?,?,?,?,NULL,NULL)',schoolId,a.personId,a.uid,key(a.uid));
        }
      }
      for(const f of families) this.storage.sql.exec('INSERT INTO universal_uid_counters VALUES(?,?,?)',schoolId,f,next[f]);
    });
  }
  lookup(schoolId: string, personId: string): string|null {
    schoolCheck(schoolId);personCheck(personId);
    const row=this.storage.sql.exec('SELECT person_id,uid FROM universal_uid_assignments WHERE school_id=? AND person_id=?',schoolId,personId).toArray()[0] as Row|undefined;
    return row?.uid??null;
  }
  /** Only authenticated, verified immutable person generations may enter.
   * Retry, rename, role change and retirement never free or regenerate UID.
   */
  reserve(schoolId: string, personId: string, category: PersonCategory, name: string): string {
    schoolCheck(schoolId);personCheck(personId);
    const family=uidFamily(category);
    return this.storage.transactionSync(()=>{
      const school=this.school(schoolId);
      requireUid(school,'UID migration must be verified before allocation');
      const prior=this.lookup(schoolId,personId);
      if(prior)return prior;
      const counter=this.storage.sql.exec('SELECT next_number FROM universal_uid_counters WHERE school_id=? AND family=?',schoolId,family).toArray()[0] as {next_number:number}|undefined;
      requireUid(counter,'UID counter missing; stop for recovery');
      const n=counter.next_number,uid=formatUid(family,school.school_code,name,n);
      this.storage.sql.exec('INSERT INTO universal_uid_assignments VALUES(?,?,?,?,?,?)',schoolId,personId,uid,key(uid),family,n);
      this.storage.sql.exec('UPDATE universal_uid_counters SET next_number=? WHERE school_id=? AND family=?',n+1,schoolId,family);
      return uid;
    });
  }
  /** Permanent ledger export for a separately verified backup/restore path.
   * There is deliberately no reset, delete, release or TTL operation.
   */
  snapshot(schoolId: string) {
    schoolCheck(schoolId);
    const school=this.school(schoolId);
    requireUid(school,'UID registry not initialized');
    const rows=this.storage.sql.exec('SELECT person_id,uid FROM universal_uid_assignments WHERE school_id=? ORDER BY person_id',schoolId).toArray() as Row[];
    const counters=this.storage.sql.exec('SELECT family,next_number FROM universal_uid_counters WHERE school_id=? ORDER BY family',schoolId).toArray() as {family:string;next_number:number}[];
    return {schoolCode:school.school_code,assignments:rows.map(r=>({personId:r.person_id,uid:r.uid})),counters:Object.fromEntries(counters.map(r=>[r.family,r.next_number]))};
  }
}
