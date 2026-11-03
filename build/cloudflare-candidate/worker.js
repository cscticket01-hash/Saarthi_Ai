var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/protocol.ts
var schoolPattern = /^vs-[a-f0-9]{32}$/;
var operationPattern = /^[a-f0-9]{64}$/;
function demand(ok, message = "Invalid sync request", status = 400) {
  if (!ok) throw Object.assign(new Error(message), { status });
}
__name(demand, "demand");
async function boundedBody(request, limit = 4e5) {
  demand(Number(request.headers.get("content-length") || 0) <= limit, "Request too large", 413);
  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks = [];
  let size = 0;
  try {
    for (; ; ) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      demand(size <= limit, "Request too large", 413);
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const c of chunks) {
    bytes.set(c, offset);
    offset += c.length;
  }
  return new TextDecoder().decode(bytes);
}
__name(boundedBody, "boundedBody");
async function digest(value) {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}
__name(digest, "digest");
function hex(buffer) {
  return [...new Uint8Array(buffer)].map((x) => x.toString(16).padStart(2, "0")).join("");
}
__name(hex, "hex");
async function signature(secret, value) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)));
}
__name(signature, "signature");
async function authenticated(secret, raw, headers, at = Date.now()) {
  const timestamp = headers.get("x-vidya-time") || "", sig = headers.get("x-vidya-signature") || "";
  if (!/^\d{13}$/.test(timestamp) || Math.abs(at - Number(timestamp)) > 6e4 || !/^[a-f0-9]{64}$/.test(sig) || secret.length < 32) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const bytes = new Uint8Array(sig.match(/../g).map((x) => parseInt(x, 16)));
  return crypto.subtle.verify("HMAC", key, bytes, new TextEncoder().encode(timestamp + "\n" + raw));
}
__name(authenticated, "authenticated");

// src/spool.ts
import { Buffer as Buffer2 } from "node:buffer";
var verifiedPayloadTtlMs = 24 * 60 * 60 * 1e3;
var verifiedPayloadExpired = /* @__PURE__ */ __name((state, verifiedAt, purgeDue, now) => state === "completed" && verifiedAt > 0 && purgeDue >= verifiedAt + verifiedPayloadTtlMs && now >= purgeDue, "verifiedPayloadExpired");
var spoolLane = /* @__PURE__ */ __name((lane) => lane === "records" || /^file-[a-f0-9]{64}$/.test(lane), "spoolLane");
var collections = /* @__PURE__ */ new Set(["students_directory", "teachers_directory", "attendance_logs", "teacher_attendance", "attendance_records", "teacher_schedules", "school_calendar", "exam_results", "teacher_salary", "school_config", "school_settings", "fee_settings", "fee_ledger", "fee_payments", "school_expenses", "student_scan_index", "scanner_devices", "documents", "backups", "exams", "exam_center_results"]);
function canonical(value) {
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  if (value && typeof value === "object") return "{" + Object.keys(value).sort().map((k) => JSON.stringify(k) + ":" + canonical(value[k])).join(",") + "}";
  return JSON.stringify(value);
}
__name(canonical, "canonical");
function initSpool(storage) {
  storage.sql.exec("CREATE TABLE IF NOT EXISTS edge_ops(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,fingerprint TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,due INTEGER NOT NULL,claim TEXT NOT NULL DEFAULT '',claim_until INTEGER NOT NULL DEFAULT 0,response TEXT)");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS edge_chunks(offset INTEGER PRIMARY KEY,size INTEGER NOT NULL,sha256 TEXT NOT NULL,body BLOB NOT NULL)");
  const columns = storage.sql.exec("PRAGMA table_info(edge_ops)").toArray();
  if (!columns.some((c) => c.name === "resources")) storage.sql.exec("ALTER TABLE edge_ops ADD COLUMN resources TEXT");
  if (!columns.some((c) => c.name === "created")) storage.sql.exec("ALTER TABLE edge_ops ADD COLUMN created INTEGER NOT NULL DEFAULT 0");
  if (!columns.some((c) => c.name === "verified_at")) storage.sql.exec("ALTER TABLE edge_ops ADD COLUMN verified_at INTEGER NOT NULL DEFAULT 0");
  if (!columns.some((c) => c.name === "purge_due")) storage.sql.exec("ALTER TABLE edge_ops ADD COLUMN purge_due INTEGER NOT NULL DEFAULT 0");
}
__name(initSpool, "initSpool");
var independent = /* @__PURE__ */ new Set(["school_expenses", "attendance_records", "attendance_logs", "teacher_attendance"]);
var recordIdentity = /* @__PURE__ */ __name((request) => request.action === "managed_records_batch" ? { action: request.action, operations: request.operations.map(recordIdentity) } : Object.fromEntries(["action", "collection", "id", "operation", "syncProtocol", "operationId", "expectedRecordRevision"].filter((key) => request[key] !== void 0).map((key) => [key, request[key]])), "recordIdentity");
function resources(request) {
  const ops = request.action === "managed_records_batch" ? request.operations : [request];
  if (ops.some((op) => !independent.has(String(op.collection)))) return "*";
  return JSON.stringify([...new Set(ops.map((op) => JSON.stringify([op.collection, op.id])))].sort());
}
__name(resources, "resources");
function schedule(storage, limit, at) {
  const rows = storage.sql.exec("SELECT id,state,due,claim_until,resources FROM edge_ops WHERE state IN ('pending','retry','processing') ORDER BY seq LIMIT 512").toArray();
  const blocked = /* @__PURE__ */ new Set(), result = [];
  let due = null;
  for (const row of rows) {
    const keys = row.resources && row.resources !== "*" ? JSON.parse(row.resources) : ["*"];
    const barrier = keys.includes("*");
    const availableAt = Math.max(row.due, row.state === "processing" ? row.claim_until : 0);
    if ((!barrier || blocked.size === 0) && !keys.some((k) => blocked.has(k))) {
      due = due === null ? availableAt : Math.min(due, availableAt);
      if (availableAt <= at) {
        result.push(row.id);
        if (result.length >= limit) break;
      }
    }
    if (barrier) break;
    for (const key of keys) blocked.add(key);
  }
  return { ids: result, due };
}
__name(schedule, "schedule");
function recordRequest(request, school) {
  demand(request.action === "managed_records" && collections.has(String(request.collection)) && ["write", "delete"].includes(String(request.operation)) && request.syncProtocol === 2 && typeof request.id === "string" && request.id.length > 0 && request.id.length <= 200 && !request.id.includes("/") && ![".", "..", "__proto__", "prototype", "constructor"].includes(request.id) && /^[A-Za-z0-9_-]{16,100}$/.test(String(request.operationId)) && typeof request.expectedRecordRevision === "string" && request.expectedRecordRevision.length <= 100, "Invalid versioned record");
  if (request.operation === "write") demand(request.data && typeof request.data === "object" && request.data.schoolId === school, "Foreign record", 403);
}
__name(recordRequest, "recordRequest");
async function spoolCommand(storage, school, lane, b, wake) {
  const get = /* @__PURE__ */ __name((id2) => storage.sql.exec("SELECT * FROM edge_ops WHERE id=?", id2).toArray()[0], "get");
  const action = String(b.command || ""), id = String(b.id || "");
  async function seal(id2) {
    const latest = get(id2);
    const manifest = JSON.parse(latest.payload);
    if (manifest.received === manifest.sizeBytes && latest.state === "receiving" && Number(manifest.verifyingUntil || 0) <= Date.now()) {
      storage.sql.exec("UPDATE edge_ops SET payload=? WHERE id=?", JSON.stringify({ ...manifest, verifyingUntil: Date.now() + 3e4 }), id2);
      const stream = new crypto.DigestStream("SHA-256"), writer = stream.getWriter();
      let received = 0;
      for (const chunk of storage.sql.exec("SELECT offset,size,body FROM edge_chunks ORDER BY offset")) {
        demand(chunk.offset === received, "File chunk gap", 409);
        await writer.write(new Uint8Array(chunk.body));
        received += chunk.size;
      }
      await writer.close();
      const actual = [...new Uint8Array(await stream.digest)].map((x) => x.toString(16).padStart(2, "0")).join("");
      demand(received === manifest.sizeBytes && actual === manifest.sha256, "File hash mismatch", 409);
      if (get(id2).state === "receiving") storage.sql.exec("UPDATE edge_ops SET state='pending',due=? WHERE id=?", Date.now(), id2);
      await wake(Date.now() + 250);
    }
  }
  __name(seal, "seal");
  const receipt = /* @__PURE__ */ __name((row2) => ({ id: row2.id, state: row2.state, due: row2.due, response: row2.response ? JSON.parse(row2.response) : null }), "receipt");
  if (action === "expireVerified") {
    return storage.transactionSync(() => {
      const eligible = storage.sql.exec("SELECT * FROM edge_ops WHERE state='completed' AND verified_at>0 AND purge_due>0 AND purge_due<=? AND (payload!='' OR ?=1) ORDER BY seq LIMIT 200", Date.now(), lane.startsWith("file-") ? 1 : 0).toArray();
      let cleared = 0;
      for (const row2 of eligible) {
        if (!verifiedPayloadExpired(row2.state, row2.verified_at, row2.purge_due, Date.now())) continue;
        if (lane.startsWith("file-")) {
          storage.sql.exec("UPDATE edge_chunks SET body=x''");
          storage.sql.exec("UPDATE edge_ops SET purge_due=0 WHERE id=? AND state='completed'", row2.id);
        } else {
          storage.sql.exec("UPDATE edge_ops SET payload='',purge_due=0 WHERE id=? AND state='completed' AND verified_at=?", row2.id, row2.verified_at);
        }
        cleared++;
      }
      const next = storage.sql.exec("SELECT min(purge_due) AS due FROM edge_ops WHERE state='completed' AND verified_at>0 AND purge_due>0").toArray()[0]?.due;
      return { expired: cleared, nextCleanupAt: next ?? null };
    });
  }
  if (action === "retention") {
    const next = storage.sql.exec("SELECT min(purge_due) AS due FROM edge_ops WHERE state='completed' AND verified_at>0 AND purge_due>0").toArray()[0]?.due;
    return { retentionHours: 24, nextCleanupAt: next ?? null };
  }
  if (action === "capabilities") return { edgeDeliveryVersion: 1, recordSchedulingVersion: 1, maxFileBytes: 20 * 1024 * 1024, chunkBytes: 512 * 1024 };
  if (action === "stats") return { ...storage.sql.exec("SELECT count(*) AS pending,min(due) AS due FROM edge_ops WHERE state IN ('pending','retry','processing')").toArray()[0], ...lane === "records" ? { due: schedule(storage, 512, Date.now()).due } : {}, ...storage.sql.exec("SELECT count(*) AS needsAttention FROM edge_ops WHERE state='needsAttention'").toArray()[0] };
  if (action === "pending") {
    demand(b.limit === 1 || lane === "records" && b.limit === 2);
    if (lane === "records") return schedule(storage, Number(b.limit), Date.now()).ids.map(get);
    const row2 = storage.sql.exec("SELECT * FROM edge_ops WHERE state IN ('pending','retry','processing') ORDER BY seq LIMIT 1").toArray()[0];
    return row2 && row2.due <= Date.now() ? [row2] : [];
  }
  if (action === "enqueue") {
    demand(lane === "records" && operationPattern.test(id) && b.request && typeof b.request === "object");
    const request = b.request;
    demand(JSON.stringify(request).length <= 3e5, "Record request too large", 413);
    if (request.action === "managed_records_batch") {
      demand(Array.isArray(request.operations) && request.operations.length > 0 && request.operations.length <= 10);
      const ids = /* @__PURE__ */ new Set();
      for (const op of request.operations) {
        recordRequest(op, school);
        demand(!ids.has(op.operationId));
        ids.add(op.operationId);
      }
    } else recordRequest(request, school);
    const identity = request.action === "managed_records_batch" ? request.operations.map((op) => [op.collection, op.id, op.operationId]) : [request.collection, request.id, request.operationId];
    demand(await digest(JSON.stringify([school, request.action, identity])) === id, "Operation identity mismatch");
    const fingerprint = await digest(canonical(request));
    const old = get(id);
    if (old) {
      demand(old.fingerprint === fingerprint, "Sync operation ID conflict", 409);
      if (["pending", "retry", "processing"].includes(old.state)) await wake(Math.max(Date.now() + 250, old.due));
      return receipt(old);
    }
    const count = storage.sql.exec("SELECT count(*) AS n FROM edge_ops WHERE state!='completed'").toArray()[0].n;
    demand(count < 512, "School delivery backlog full; local work retained", 503);
    const at = Date.now();
    storage.sql.exec("INSERT INTO edge_ops(id,fingerprint,payload,state,due,resources,created) VALUES(?,?,?,'pending',?,?,?)", id, fingerprint, JSON.stringify(request), at, resources(request), at);
    await wake(at + 250);
    return receipt(get(id));
  }
  if (action === "putSmall") {
    demand(lane.startsWith("file-") && operationPattern.test(id) && lane === "file-" + id && b.manifest && typeof b.manifest === "object");
    const m = b.manifest;
    demand(typeof m.uploadKey === "string" && /^[A-Za-z0-9_-]{1,150}$/.test(m.uploadKey) && await digest(JSON.stringify([school, m.uploadKey])) === id && typeof m.sha256 === "string" && operationPattern.test(m.sha256) && Number.isSafeInteger(m.sizeBytes) && Number(m.sizeBytes) > 0 && Number(m.sizeBytes) <= 256 * 1024 && typeof m.name === "string" && m.name.length > 0 && m.name.length <= 200 && typeof m.mime === "string" && /^[-\w.+]+\/[-\w.+]+$/.test(m.mime) && !m.mime.startsWith("application/vnd.google-apps."), "Invalid small file manifest");
    demand(typeof b.base64 === "string" && b.base64.length > 0 && b.base64.length <= 349528 && /^[A-Za-z0-9+/]*={0,2}$/.test(b.base64), "Invalid small file encoding");
    const bytes = new Uint8Array(Buffer2.from(b.base64, "base64"));
    demand(bytes.length === m.sizeBytes && Buffer2.from(bytes).toString("base64") === b.base64, "Small file byte length mismatch");
    const actual = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((x) => x.toString(16).padStart(2, "0")).join("");
    demand(actual === m.sha256, "Small file hash mismatch", 409);
    const fingerprint = await digest(canonical(m)), old = get(id);
    if (old) {
      demand(old.fingerprint === fingerprint, "Sync operation ID conflict", 409);
      demand(old.state !== "receiving", "Resumable upload must keep its existing chunk owner", 409);
      if (["pending", "retry", "processing"].includes(old.state)) await wake(Math.max(Date.now() + 250, old.due));
      return { ...receipt(old), manifest: JSON.parse(old.payload) };
    }
    const at = Date.now(), manifest = JSON.stringify({ ...m, received: bytes.length, driveOffset: 0 });
    storage.transactionSync(() => {
      storage.sql.exec("INSERT INTO edge_ops(id,fingerprint,payload,state,due,created) VALUES(?,?,?,'pending',?,?)", id, fingerprint, manifest, at, at);
      storage.sql.exec("INSERT INTO edge_chunks(offset,size,sha256,body) VALUES(?,?,?,?)", 0, bytes.length, actual, bytes.buffer);
    });
    await wake(at + 250);
    return { ...receipt(get(id)), manifest: JSON.parse(get(id).payload) };
  }
  if (action === "begin") {
    demand(lane.startsWith("file-") && operationPattern.test(id) && lane === "file-" + id && b.manifest && typeof b.manifest === "object");
    const m = b.manifest;
    demand(typeof m.uploadKey === "string" && /^[A-Za-z0-9_-]{1,150}$/.test(m.uploadKey) && await digest(JSON.stringify([school, m.uploadKey])) === id && typeof m.sha256 === "string" && operationPattern.test(m.sha256) && Number.isSafeInteger(m.sizeBytes) && Number(m.sizeBytes) > 0 && Number(m.sizeBytes) <= 20 * 1024 * 1024 && typeof m.name === "string" && m.name.length > 0 && m.name.length <= 200 && typeof m.mime === "string" && /^[-\w.+]+\/[-\w.+]+$/.test(m.mime) && !m.mime.startsWith("application/vnd.google-apps."), "Invalid file manifest");
    const fingerprint = await digest(canonical(m)), old = get(id);
    if (old) {
      demand(old.fingerprint === fingerprint, "Sync operation ID conflict", 409);
      if (["pending", "retry", "processing"].includes(old.state)) await wake(Math.max(Date.now() + 250, old.due));
      return { ...receipt(old), manifest: JSON.parse(old.payload) };
    }
    storage.sql.exec("INSERT INTO edge_ops(id,fingerprint,payload,state,due) VALUES(?,?,?,'receiving',?)", id, fingerprint, JSON.stringify({ ...m, received: 0, driveOffset: 0 }), Number.MAX_SAFE_INTEGER);
    return { ...receipt(get(id)), manifest: JSON.parse(get(id).payload) };
  }
  demand(operationPattern.test(id), "Invalid receipt ID");
  const row = get(id);
  demand(row, "Delivery receipt unavailable", 404);
  if (action === "status") {
    if (lane.startsWith("file-")) await seal(id);
    const current = get(id);
    return { ...receipt(current), ...lane.startsWith("file-") ? { manifest: JSON.parse(current.payload) } : {} };
  }
  if (action === "projection") {
    demand(lane === "records", "Record projection unavailable", 400);
    const saved = row.response ? JSON.parse(row.response) : {};
    return { id: row.id, state: row.state, due: row.due, authoritative: false, ...["pending", "retry", "processing"].includes(row.state) ? { request: JSON.parse(row.payload) } : { identity: saved.identity || (row.payload ? recordIdentity(JSON.parse(row.payload)) : null) } };
  }
  if (action === "part") {
    demand(lane === "file-" + id && Number.isSafeInteger(b.offset) && Number(b.offset) >= 0 && typeof b.base64 === "string" && b.base64.length > 0 && b.base64.length <= 699052 && /^[A-Za-z0-9+/]*={0,2}$/.test(b.base64) && typeof b.chunkSha256 === "string" && operationPattern.test(b.chunkSha256));
    const bytes = new Uint8Array(Buffer2.from(b.base64, "base64"));
    demand(bytes.length > 0 && bytes.length <= 512 * 1024 && Buffer2.from(bytes).toString("base64") === b.base64);
    const hash2 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((x) => x.toString(16).padStart(2, "0")).join("");
    demand(hash2 === b.chunkSha256, "Chunk hash mismatch", 409);
    const m = JSON.parse(get(id).payload);
    const offset = Number(b.offset);
    demand(offset + bytes.length <= Number(m.sizeBytes) && (offset + bytes.length === m.sizeBytes || bytes.length % (256 * 1024) === 0));
    const prior = storage.sql.exec("SELECT sha256,size FROM edge_chunks WHERE offset=?", offset).toArray()[0];
    if (prior) demand(prior.sha256 === hash2 && prior.size === bytes.length, "Chunk replay conflict", 409);
    else {
      demand(row.state === "receiving" && offset === m.received, "Upload offset conflict", 409);
      storage.transactionSync(() => {
        storage.sql.exec("INSERT INTO edge_chunks(offset,size,sha256,body) VALUES(?,?,?,?)", offset, bytes.length, hash2, bytes.buffer);
        storage.sql.exec("UPDATE edge_ops SET payload=? WHERE id=?", JSON.stringify({ ...m, received: offset + bytes.length }), id);
      });
    }
    const latest = get(id), manifest = JSON.parse(latest.payload);
    await seal(id);
    return { ...receipt(get(id)), manifest: JSON.parse(get(id).payload) };
  }
  if (action === "readPart") {
    demand(lane === "file-" + id && Number.isSafeInteger(b.offset));
    const manifest = JSON.parse(row.payload);
    const offset = Number(b.offset);
    demand(offset >= 0 && offset < Number(manifest.sizeBytes));
    const end = Math.min(Number(manifest.sizeBytes), offset + 512 * 1024);
    const bytes = new Uint8Array(end - offset);
    let copied = 0;
    for (const chunk of storage.sql.exec("SELECT offset,size,body FROM edge_chunks WHERE offset+size>? AND offset<? ORDER BY offset", offset, end)) {
      demand(chunk.body.byteLength === chunk.size, "Staged bytes unavailable", 409);
      const from = Math.max(offset, chunk.offset), to = Math.min(end, chunk.offset + chunk.size);
      const slice = new Uint8Array(chunk.body).subarray(from - chunk.offset, to - chunk.offset);
      bytes.set(slice, from - offset);
      copied += slice.length;
    }
    demand(copied === bytes.length, "Staged file gap", 409);
    const hash2 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((x) => x.toString(16).padStart(2, "0")).join("");
    return { offset, sizeBytes: bytes.length, sha256: hash2, base64: Buffer2.from(bytes).toString("base64") };
  }
  if (action === "claim") {
    if (!["pending", "retry", "processing"].includes(row.state) || row.due > Date.now() || row.state === "processing" && row.claim_until > Date.now()) return false;
    if (lane === "records" && !schedule(storage, 512, Date.now()).ids.includes(id)) return false;
    demand(typeof b.claim === "string" && b.claim.length > 0 && b.claim.length <= 100 && Number.isSafeInteger(b.expires) && Number(b.expires) > Date.now() && Number(b.expires) <= Date.now() + 18e4);
    storage.sql.exec("UPDATE edge_ops SET state='processing',claim=?,claim_until=?,due=? WHERE id=?", b.claim, Number(b.expires), Number(b.expires), id);
    return true;
  }
  if (action === "finish") {
    if (row.claim !== b.claim || !row.claim) return false;
    const values = b.values;
    demand(values && ["completed", "retry", "needsAttention"].includes(String(values.state)) && Number.isSafeInteger(values.nextAttemptAt));
    if (values.state === "completed" || values.result) {
      const result = values.result;
      demand(result && typeof result === "object" && result.success === true && result.schoolId === school, "Verified Drive result required");
      const original = JSON.parse(row.payload);
      if (lane.startsWith("file-")) demand(result.uploadResumableVersion === 1 && result.uploadKey === original.uploadKey && result.sha256 === original.sha256 && result.sizeBytes === original.sizeBytes && result.committed === true && result.offset === original.sizeBytes && /^[A-Za-z0-9_-]{1,200}$/.test(String(result.fileId || "")), "Unverified Drive file receipt");
      else if (original.action === "managed_records_batch") {
        demand(result.syncProtocol === 2 && result.recordWriteBatchVersion === 1 && Array.isArray(result.acknowledgements) && result.acknowledgements.length === original.operations.length, "Unverified batch receipt");
        const seen = /* @__PURE__ */ new Set();
        for (const ack of result.acknowledgements) {
          demand(original.operations.some((op) => op.operationId === ack.operationId) && !seen.has(ack.operationId) && typeof ack.success === "boolean" && (!ack.success || typeof ack.recordRevision === "string" && !!ack.recordRevision && !/^(live-|cf-)/.test(ack.recordRevision)), "Unverified operation receipt");
          seen.add(ack.operationId);
        }
      } else demand(result.syncProtocol === 2 && typeof result.recordRevision === "string" && !!result.recordRevision && !/^(live-|cf-)/.test(result.recordRevision), "Unverified record receipt");
    }
    if (values.payloadPurged === true) {
      demand(lane === "records" && values.state === "completed", "Only verified record delivery may purge payloads");
      const original = JSON.parse(row.payload), result = values.result;
      demand(canonical(values.identity) === canonical(recordIdentity(original)), "Payload cleanup identity mismatch");
      const requests = original.action === "managed_records_batch" ? original.operations : [original];
      const receipts = original.action === "managed_records_batch" ? result.acknowledgements : [result];
      demand(receipts.length === requests.length && receipts.every((receipt2, index) => {
        const request = requests[index], source = receipt2.recordSource;
        return receipt2.success === true && receipt2.schoolId === school && receipt2.syncProtocol === 2 && receipt2.record === null && source?.version === 1 && source.collection === request.collection && source.id === request.id && source.operationId === request.operationId && source.recordRevision === receipt2.recordRevision && typeof source.recordRevision === "string" && source.recordRevision.length > 0 && source.recordRevision.length <= 100 && !/^(live-|cf-)/.test(source.recordRevision) && typeof source.payloadHash === "string" && operationPattern.test(source.payloadHash);
      }), "Verified canonical source metadata required");
    }
    storage.transactionSync(() => {
      const stored = values.payloadPurged === true ? { ...values, partial: {} } : values;
      const verified = values.state === "completed" && (values.payloadPurged === true || lane.startsWith("file-"));
      const verifiedAt = verified ? Date.now() : 0, expiry = verified ? verifiedAt + verifiedPayloadTtlMs : 0;
      storage.sql.exec("UPDATE edge_ops SET state=?,due=?,claim='',claim_until=0,response=?,verified_at=?,purge_due=? WHERE id=?", String(values.state), Number(values.nextAttemptAt), JSON.stringify(stored), verifiedAt, expiry, id);
    });
    if (values.state === "retry") await wake(Number(values.nextAttemptAt));
    if (values.state === "completed" && (values.payloadPurged === true || lane.startsWith("file-"))) await wake(Date.now() + verifiedPayloadTtlMs);
    return true;
  }
  throw Object.assign(Error("Unknown delivery command"), { status: 400 });
}
__name(spoolCommand, "spoolCommand");

// src/mobile.ts
async function mobileRequest(request, env) {
  const raw = await boundedBody(request, 2e4), body = JSON.parse(raw);
  demand(typeof body.grant === "string" && body.grant.length < 12e3, "Refresh attendance approval", 409);
  const [value, sig] = body.grant.split(".");
  demand(!!value && /^[a-f0-9]{64}$/.test(sig || ""), "Refresh attendance approval", 409);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.EDGE_KEY), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  demand(await crypto.subtle.verify("HMAC", key, new Uint8Array(sig.match(/../g).map((x) => parseInt(x, 16))), new TextEncoder().encode(value)), "Refresh attendance approval", 409);
  const p = JSON.parse(atob(value.replace(/-/g, "+").replace(/_/g, "/")));
  const b = body.request;
  demand(p.schoolId === body.schoolId && p.expiresAt > Date.now() && p.sessionHash === await digest(String(b.sessionToken || "")) && p.role === b.role && p.documentId === b.personId && p.qrHash === await digest(p.role + "/" + b.personId + "/" + b.linkToken), "Refresh attendance approval", 409);
  const school = p.schoolId, action = String(b.action || "");
  if (action === "mobile_notice" || action === "mobile_notice_list") {
    const snapshot = await env.LANES.getByName(school + "/notices").command(school, "notices", { command: "snapshot" });
    demand(snapshot.initialized, "Notice baseline is pending", 503);
    if (action === "mobile_notice") {
      const notice = snapshot.records[String(b.noticeId || "")];
      demand(notice && !notice._syncDeleted, "School notice unavailable", 404);
      return { success: true, schoolId: school, projectId: school, notice };
    }
    return { success: true, schoolId: school, projectId: school, revision: snapshot.revision, notices: Object.entries(snapshot.records).filter(([, v]) => !v._syncDeleted).map(([id2, v]) => ({ ...v, id: id2, _noticeRevision: v._syncRevision })).sort((a, b2) => Number(b2.timestamp || b2.createdAt || 0) - Number(a.timestamp || a.createdAt || 0)).slice(0, 100) };
  }
  const ids = await Promise.all(["entry", "exit"].map((mode2) => digest(JSON.stringify([school, p.role, p.personId, p.day, mode2]))));
  if (action === "mobile_attendance_status") {
    demand(Array.isArray(b.operationIds) && b.operationIds.length <= 2 && b.operationIds.every((id2) => ids.includes(String(id2))));
    const operations = await Promise.all(b.operationIds.map(async (id2) => {
      const row2 = await env.LANES.getByName(school + "/attendance-" + id2.slice(0, 2)).command(school, "attendance-" + id2.slice(0, 2), { command: "get", id: id2 });
      const receipt = row2?.response ? JSON.parse(row2.response) : {};
      return { operationId: id2, state: row2?.state || "unknown", createdAt: row2?.created ?? null, ...row2?.state === "completed" ? { completedAt: receipt.completedAt } : {} };
    }));
    if (operations.some((row2) => row2.state === "unknown") && typeof b.attendancePermit === "string") {
      const response = await fetch(env.BROKER_URL, { method: "POST", headers: { "Content-Type": "application/json", "User-Agent": "Vidya-Saarthi-Sync/1" }, body: JSON.stringify({ action: "managed/mobile", schoolId: school, request: b }), signal: AbortSignal.timeout(2e4) });
      const legacy = JSON.parse(await boundedBody(response, 256e3));
      demand(response.ok && legacy.success === true && legacy.schoolId === school && legacy.projectId === school, "Attendance confirmation unavailable; capture retained", 503);
      return legacy;
    }
    return { success: true, schoolId: school, projectId: school, syncProtocol: 2, operations };
  }
  demand(action === "mobile_mark_attendance");
  demand(p.open === true, "School is closed today. Attendance is disabled for everyone");
  const captured = b.clientCapturedAt ?? Date.now();
  demand(Number.isSafeInteger(captured) && Number(captured) > 0 && Number(captured) <= Date.now() + 12e4 && new Date(Number(captured) + 198e5).toISOString().slice(0, 10) === p.day, "Attendance capture date needs school review", 409);
  const at = new Date(Number(captured) + 198e5), minute = at.getUTCHours() * 60 + at.getUTCMinutes(), w = p.schedule;
  if (p.role === "student" && w && w.enabled !== false) demand(w.enabled === true && Number.isInteger(w.startMinute) && Number.isInteger(w.endMinute) && w.startMinute >= 0 && w.endMinute <= 1440 && w.startMinute < w.endMinute && minute >= w.startMinute && minute < w.endMinute, "Student attendance is outside the school schedule");
  const lat = Number(b.latitude), lng = Number(b.longitude), accuracy = Number(b.accuracy), radius = Number(p.radiusMeters);
  demand(Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && Number.isFinite(accuracy) && accuracy >= 0 && accuracy <= radius && radius >= 25 && radius <= 200 && Number.isFinite(p.latitude) && Number.isFinite(p.longitude), "Accurate school location required");
  const rad = /* @__PURE__ */ __name((x) => x * Math.PI / 180, "rad"), h = Math.sin(rad(p.latitude - lat) / 2) ** 2 + Math.cos(rad(lat)) * Math.cos(rad(p.latitude)) * Math.sin(rad(p.longitude - lng) / 2) ** 2;
  demand(6371e3 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h)) <= radius, "Attendance can be marked only within the school location");
  const mode = b.mode === "exit" ? "exit" : "entry", id = ids[mode === "exit" ? 1 : 0];
  const aes = await crypto.subtle.importKey("raw", await crypto.subtle.digest("SHA-256", new TextEncoder().encode(env.EDGE_KEY)), { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, aes, new TextEncoder().encode(JSON.stringify({ ...b, attendancePermit: void 0 })));
  const encode = /* @__PURE__ */ __name((bytes) => btoa(String.fromCharCode(...bytes)), "encode");
  const row = { operationId: id, schoolId: school, day: p.day, mode, payloadTransport: "cloudflare-v1", payload: { iv: encode(iv), body: encode(new Uint8Array(encrypted)) }, state: "pending", attempts: 0, createdAt: Date.now(), nextAttemptAt: Date.now() };
  const created = await env.LANES.getByName(school + "/attendance-" + id.slice(0, 2)).command(school, "attendance-" + id.slice(0, 2), { command: "create", id, row });
  return { success: true, schoolId: school, projectId: school, syncProtocol: 2, accepted: true, operationId: id, duplicate: !created, cloudflareAccepted: true, driveState: "pending", message: "Attendance saved to Cloudflare; Google Drive delivery pending." };
}
__name(mobileRequest, "mobileRequest");

// src/domain-policy.ts
var domainCollections = /* @__PURE__ */ new Set([
  "fee_settings",
  "fee_ledger",
  "fee_payments",
  "teacher_salary",
  "attendance_records",
  "attendance_logs",
  "teacher_attendance",
  "teacher_schedules",
  "exams",
  "exam_results",
  "exam_center_results",
  "documents",
  "student_scan_index"
]);
function reject(code, status = 409) {
  throw Object.assign(new Error("Domain lifecycle validation failed; original work retained."), { status, code });
}
__name(reject, "reject");
function boundedJson(value, depth = 0, budget = { left: 1e4 }) {
  if (--budget.left < 0 || depth > 12) reject("DOMAIN_RECORD_TOO_LARGE", 413);
  if (typeof value === "number" && !Number.isFinite(value)) reject("DOMAIN_INVALID_VALUE", 400);
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") return;
  if (Array.isArray(value)) {
    for (const entry of value) boundedJson(entry, depth + 1, budget);
    return;
  }
  if (typeof value !== "object" || value === void 0) reject("DOMAIN_INVALID_VALUE", 400);
  for (const [key, entry] of Object.entries(value)) {
    if (["__proto__", "prototype", "constructor"].includes(key)) reject("DOMAIN_INVALID_FIELD", 400);
    boundedJson(entry, depth + 1, budget);
  }
}
__name(boundedJson, "boundedJson");
var nonempty = /* @__PURE__ */ __name((value) => typeof value === "string" && value.length > 0 && value.length <= 200, "nonempty");
function generation(owner) {
  return owner.mobileStableId || owner.generation || owner._syncDeletedOwner || owner.id;
}
__name(generation, "generation");
function owned(school, owner) {
  if (!owner) reject("DOMAIN_PARENT_NOT_READY", 412);
  if (owner.schoolId !== school) reject("DOMAIN_FOREIGN_OWNER", 403);
  return owner;
}
__name(owned, "owned");
function validateDomainCandidate(input) {
  const { schoolId, collection, id, operation, current, next, readOwner } = input;
  if (!domainCollections.has(collection)) reject("DOMAIN_COLLECTION_NOT_ADMITTED", 412);
  if (!/^vs-[a-f0-9]{32}$/.test(schoolId) || !nonempty(id) || id.includes("/") || [".", "..", "__proto__", "prototype", "constructor"].includes(id)) reject("DOMAIN_IDENTITY_INVALID", 400);
  if (!["write", "patch", "delete"].includes(operation) || next.schoolId !== schoolId || current && current.schoolId !== schoolId) reject("DOMAIN_SCHOOL_MISMATCH", 403);
  boundedJson(next);
  if (operation === "delete") {
    if (next._syncDeleted !== true) reject("DOMAIN_DELETE_UNVERIFIED", 400);
    return;
  }
  if (next._syncDeleted === true) reject("DOMAIN_INVALID_WRITE", 400);
  if (current && !current._syncDeleted && ["fee_payments", "fee_ledger", "teacher_salary"].includes(collection)) {
    const keys = collection === "teacher_salary" ? ["teacherId", "personId", "staffId", "employeeId"] : ["personId"];
    for (const key of keys) if (current[key] != null && next[key] !== current[key]) {
      if (key === "employeeId" && !String(current[key]).trim() && current.staffId === next.staffId && nonempty(next.staffId)) {
        const staff = owned(schoolId, readOwner("staff_payroll_directory", next.staffId));
        if (staff.employeeId === next.employeeId) continue;
      }
      reject("DOMAIN_HISTORY_OWNER_IMMUTABLE");
    }
  }
  const studentRole = next.ownerRole === "student" || next.role === "student";
  const teacherRole = next.ownerRole === "teacher" || next.role === "teacher" || ["teacher_salary", "teacher_attendance", "teacher_schedules"].includes(collection);
  if (studentRole && teacherRole) reject("DOMAIN_OWNER_ROLE_CONFLICT");
  if (nonempty(next.studentId) && !teacherRole) {
    const parent = owned(schoolId, readOwner("students_directory", next.studentId));
    if (parent._syncDeleted === true || parent.deleted === true) reject("DOMAIN_STUDENT_GENERATION_DELETED");
    const retired = parent._syncRetiredStudentGenerations || parent.retiredGenerations;
    if (nonempty(next.personId) && (generation(parent) !== next.personId || Array.isArray(retired) && retired.includes(next.personId))) reject("DOMAIN_STUDENT_GENERATION_DELETED");
  }
  if (!studentRole && (nonempty(next.teacherId) || teacherRole && nonempty(next.personId))) {
    const history = collection === "teacher_salary" && current && !current._syncDeleted && ["teacherId", "personId", "staffId", "employeeId"].every((key) => current[key] === next[key]);
    if (!history) {
      const owner = owned(schoolId, readOwner("teachers_directory", String(next.teacherId || next.personId)));
      if (owner._syncDeleted === true || owner.deleted === true || owner.active === false) reject("DOMAIN_TEACHER_RETIRED");
      if (nonempty(next.teacherId) && String(owner.teacherId || owner._syncRetiredTeacherId || owner.id) !== next.teacherId) reject("DOMAIN_TEACHER_IDENTITY_MISMATCH");
      if (teacherRole && nonempty(next.personId) && generation(owner) !== next.personId) reject("DOMAIN_TEACHER_RETIRED");
    }
  }
  if (collection === "teacher_salary" && nonempty(next.staffId)) {
    const history = current && !current._syncDeleted && ["staffId", "employeeId", "personId", "teacherId"].every((key) => current[key] === next[key]);
    if (!history) {
      const staff = owned(schoolId, readOwner("staff_payroll_directory", next.staffId));
      if (staff.active === false || staff.deleted === true || staff._syncDeleted === true) reject("DOMAIN_STAFF_RETIRED");
      if (nonempty(staff.employeeId) && staff.employeeId !== next.employeeId) reject("DOMAIN_STAFF_IDENTITY_MISMATCH");
    }
  }
  if (nonempty(next.personId) && studentRole && !nonempty(next.studentId)) reject("DOMAIN_PARENT_NOT_READY", 412);
}
__name(validateDomainCandidate, "validateDomainCandidate");
var personCollections = /* @__PURE__ */ new Set(["students_directory", "teachers_directory"]);
function slot(data) {
  if (!data || data._syncDeleted || data.deleted) return null;
  const cls = data.studentClass === void 0 ? data.class : data.studentClass, section = data.section === void 0 ? "" : data.section, roll = data.rollNo;
  if (typeof cls !== "string" || !cls.trim() || typeof section !== "string" || !(typeof roll === "string" || typeof roll === "number") || typeof roll === "number" && (!Number.isSafeInteger(roll) || roll < 0) || !String(roll).trim()) return null;
  return JSON.stringify([cls.trim(), section.trim(), String(roll).trim()]);
}
__name(slot, "slot");
function validatePersonCandidate(input) {
  const { schoolId, collection, id, operation, current, next, readPeers } = input;
  if (!personCollections.has(collection)) reject("PERSON_COLLECTION_NOT_ADMITTED", 412);
  if (!/^vs-[a-f0-9]{32}$/.test(schoolId) || !nonempty(id) || id.includes("/") || [".", "..", "__proto__", "prototype", "constructor"].includes(id)) reject("PERSON_IDENTITY_INVALID", 400);
  if (next.schoolId !== schoolId || current && current.schoolId !== schoolId || next.id !== void 0 && next.id !== id) reject("PERSON_FOREIGN_RECORD", 403);
  if (!["write", "patch", "delete"].includes(operation)) reject("PERSON_OPERATION_INVALID", 400);
  boundedJson(next);
  if (operation === "delete") {
    if (next._syncDeleted !== true) reject("PERSON_DELETE_UNVERIFIED", 400);
    return;
  }
  if (next._syncDeleted === true) reject("PERSON_INVALID_WRITE", 400);
  const oldGeneration = current ? generation(current) || id : null;
  if (collection === "students_directory") {
    if (typeof next.mobileStableId !== "string" || !/^p-[a-f0-9]{32,64}$/.test(next.mobileStableId)) reject("PERSON_GENERATION_INVALID", 400);
    if (current && oldGeneration !== next.mobileStableId && next.replacesStudentGeneration !== oldGeneration) reject("PERSON_GENERATION_REPLACEMENT_REQUIRED");
    const retired = current?._syncRetiredStudentGenerations || current?.retiredGenerations;
    if (Array.isArray(retired) && retired.includes(next.mobileStableId)) reject("PERSON_GENERATION_RETIRED");
    if (current && (current._syncDeleted === true || current.deleted === true) && oldGeneration === next.mobileStableId) reject("PERSON_GENERATION_RETIRED");
    const nextSlot = slot(next), oldSlot = slot(current);
    for (const peer of readPeers("students_directory")) {
      if (peer.schoolId !== schoolId) reject("PERSON_FOREIGN_OWNER", 403);
      if (peer.id !== id && nextSlot !== null && slot(peer) === nextSlot && nextSlot !== oldSlot) reject("PERSON_STUDENT_SLOT_CONFLICT");
    }
  } else {
    const employee = String(next.teacherId || id).trim().toLowerCase(), nextGeneration = next.mobileStableId || id;
    if (!employee || employee.length > 200 || !nonempty(nextGeneration)) reject("PERSON_GENERATION_INVALID", 400);
    if (current && (oldGeneration !== nextGeneration || String(current.teacherId || current._syncRetiredTeacherId || id) !== String(next.teacherId || id))) reject("PERSON_TEACHER_REASSIGNMENT_REQUIRES_REVIEW");
    for (const peer of readPeers("teachers_directory")) {
      if (peer.schoolId !== schoolId) reject("PERSON_FOREIGN_OWNER", 403);
      if (peer.id !== id && String(peer.teacherId || peer._syncRetiredTeacherId || peer.id).trim().toLowerCase() === employee) reject("PERSON_PAYROLL_IDENTITY_CONFLICT");
    }
    for (const peer of readPeers("staff_payroll_directory")) {
      if (peer.schoolId !== schoolId) reject("PERSON_FOREIGN_OWNER", 403);
      if (String(peer.employeeId || "").trim().toLowerCase() === employee) reject("PERSON_PAYROLL_IDENTITY_CONFLICT");
    }
  }
}
__name(validatePersonCandidate, "validatePersonCandidate");

// src/live-records.ts
import { createHash, randomUUID } from "node:crypto";
var liveCollections = /* @__PURE__ */ new Set(["school_expenses", "school_calendar", "school_notices", "school_settings", ...domainCollections, ...personCollections, "documents", "student_scan_index", "scanner_devices", "school_config"]);
var hash = /* @__PURE__ */ __name((v) => createHash("sha256").update(canonical(v)).digest("hex"), "hash");
var business = /* @__PURE__ */ __name((v) => Object.fromEntries(Object.entries(v).filter(([k]) => !k.startsWith("_sync"))), "business");
var payloadHash = /* @__PURE__ */ __name((v) => hash({ deleted: v._syncDeleted === true, data: business(v) }), "payloadHash");
var byteLength = /* @__PURE__ */ __name((v) => new TextEncoder().encode(v).byteLength, "byteLength");
var cloudflareVerifiedRetentionMs = 24 * 60 * 60 * 1e3;
var validId = /* @__PURE__ */ __name((v) => typeof v === "string" && v.length > 0 && v.length <= 200 && !v.includes("/") && ![".", "..", "__proto__", "prototype", "constructor"].includes(v), "validId");
var opId = /* @__PURE__ */ __name((v) => typeof v === "string" && /^[A-Za-z0-9_-]{16,100}$/.test(v), "opId");
function clean(v, depth = 0) {
  demand(depth <= 12, "Record too deeply nested");
  if (Array.isArray(v)) {
    for (const x of v) clean(x, depth + 1);
    return;
  }
  if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) {
    demand(!["__proto__", "prototype", "constructor"].includes(k) && !(/password|token|secret|private_key|base64|localpath/i.test(k) && k !== "mobileLinkToken"), "Invalid record field");
    clean(x, depth + 1);
  }
  if (typeof v === "string") demand(!v.startsWith("data:"), "Media uses the existing file pipeline");
}
__name(clean, "clean");
function initLive(storage) {
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_collections(collection TEXT PRIMARY KEY,state TEXT NOT NULL,fingerprint TEXT NOT NULL,expected_count INTEGER NOT NULL,source_revision TEXT NOT NULL)");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_records(collection TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,revision TEXT NOT NULL,drive_revision TEXT NOT NULL,PRIMARY KEY(collection,id))");
  if (!storage.sql.exec("PRAGMA table_info(live_records)").toArray().some((c) => c.name === "payload_hash")) {
    storage.sql.exec("ALTER TABLE live_records ADD COLUMN payload_hash TEXT NOT NULL DEFAULT ''");
    for (const row of storage.sql.exec("SELECT * FROM live_records WHERE body!=''").toArray()) storage.sql.exec("UPDATE live_records SET payload_hash=? WHERE collection=? AND id=?", payloadHash(JSON.parse(row.body)), row.collection, row.id);
  }
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_events(seq INTEGER PRIMARY KEY AUTOINCREMENT,collection TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,operation_id TEXT UNIQUE NOT NULL,fingerprint TEXT NOT NULL,receipt TEXT NOT NULL)");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_operations(operation_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,receipt TEXT NOT NULL)");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_backup(seq INTEGER PRIMARY KEY,collection TEXT NOT NULL,id TEXT NOT NULL,operation_id TEXT NOT NULL,operation TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,due INTEGER NOT NULL,claim TEXT NOT NULL DEFAULT '',claim_until INTEGER NOT NULL DEFAULT 0,drive_revision TEXT)");
  storage.sql.exec("CREATE INDEX IF NOT EXISTS live_backup_owner ON live_backup(collection,id,seq)");
  if (!storage.sql.exec("PRAGMA table_info(live_backup)").toArray().some((c) => c.name === "accepted_at")) storage.sql.exec("ALTER TABLE live_backup ADD COLUMN accepted_at INTEGER NOT NULL DEFAULT 0");
  if (!storage.sql.exec("PRAGMA table_info(live_backup)").toArray().some((c) => c.name === "verified_at")) storage.sql.exec("ALTER TABLE live_backup ADD COLUMN verified_at INTEGER NOT NULL DEFAULT 0");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_record_owners(collection TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(collection,id))");
  if (!storage.sql.exec("PRAGMA table_info(live_backup)").toArray().some((c) => c.name === "request_metadata")) storage.sql.exec("ALTER TABLE live_backup ADD COLUMN request_metadata TEXT NOT NULL DEFAULT '{}'");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_backup_dependencies(sequence INTEGER NOT NULL,predecessor INTEGER NOT NULL,PRIMARY KEY(sequence,predecessor))");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_device_receipts(device TEXT PRIMARY KEY,cursor INTEGER NOT NULL,observed_at INTEGER NOT NULL)");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_collection_cursors(collection TEXT PRIMARY KEY,cursor INTEGER NOT NULL)");
  storage.sql.exec("INSERT OR IGNORE INTO live_collection_cursors SELECT collection,max(seq) FROM live_events GROUP BY collection");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_retention(id INTEGER PRIMARY KEY,floor INTEGER NOT NULL)");
  storage.sql.exec("INSERT OR IGNORE INTO live_retention VALUES(1,0)");
}
__name(initLive, "initLive");
var ownerFields = /* @__PURE__ */ new Set(["schoolId", "id", "mobileStableId", "teacherId", "personId", "studentId", "studentDocId", "studentDocumentId", "teacherDocId", "teacherDocumentId", "documentId", "oldStudentId", "previousStudentId", "previousStudentIds", "employeeId", "staffId", "role", "ownerRole", "active", "inactive", "status", "class", "studentClass", "section", "rollNo", "roll", "replacesStudentGeneration", "_syncDeleted", "_syncDeletedOwner", "_syncRetiredTeacherId", "_syncRetiredStudentGenerations", "_syncRetiredTeacherGenerations"]);
function ownerMetadata(data, id) {
  return { ...Object.fromEntries(Object.entries(data).filter(([key]) => ownerFields.has(key))), id };
}
__name(ownerMetadata, "ownerMetadata");
function saveOwner(storage, col, id, data) {
  storage.sql.exec("INSERT INTO live_record_owners VALUES(?,?,?) ON CONFLICT(collection,id) DO UPDATE SET body=excluded.body", col, id, canonical(ownerMetadata(data, id)));
}
__name(saveOwner, "saveOwner");
function findOwner(storage, col, id) {
  const exact = storage.sql.exec("SELECT body FROM live_record_owners WHERE collection=? AND id=?", col, id).toArray()[0];
  if (exact) return JSON.parse(exact.body);
  const matches = storage.sql.exec("SELECT body FROM live_record_owners WHERE collection=? AND (json_extract(body,'$.mobileStableId')=? OR json_extract(body,'$.teacherId')=? OR json_extract(body,'$._syncDeletedOwner')=?) LIMIT 2", col, id, id, id).toArray();
  demand(matches.length <= 1, "Ambiguous parent identity", 409);
  return matches.length ? JSON.parse(matches[0].body) : null;
}
__name(findOwner, "findOwner");
function appendLive(storage, school, col, id, operationId, operation, data, now, fingerprint, metadata = {}) {
  const sql = storage.sql, current = sql.exec("SELECT * FROM live_records WHERE collection=? AND id=?", col, id).toArray()[0];
  const revision = "live-" + randomUUID(), lifecycle = Object.fromEntries(Object.entries(data).filter(([key]) => ["_syncDeletedOwner", "_syncRetiredTeacherId", "_syncRetiredStudentGenerations", "_syncRetiredTeacherGenerations"].includes(key)));
  data = { ...business(data), ...lifecycle, ...operation === "delete" ? { _syncDeleted: true } : {}, schoolId: school, _syncRevision: revision, _syncOperationId: operationId };
  const body = canonical(data);
  sql.exec("INSERT INTO live_events(collection,id,body,operation_id,fingerprint,receipt) VALUES(?,?,?,?,?,?)", col, id, body, operationId, fingerprint, "");
  const seq = sql.exec("SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name='live_events'),0) AS n").toArray()[0].n;
  const receipt = { liveProtocol: 1, schoolId: school, cloudState: "committed", backupState: "pending", recordRevision: revision, operationId, cursor: seq, record: data };
  sql.exec("INSERT INTO live_collection_cursors VALUES(?,?) ON CONFLICT(collection) DO UPDATE SET cursor=excluded.cursor", col, seq);
  sql.exec("UPDATE live_events SET receipt=? WHERE seq=?", JSON.stringify(receipt), seq);
  sql.exec("INSERT INTO live_operations VALUES(?,?,?)", operationId, fingerprint, JSON.stringify(receipt));
  sql.exec("INSERT INTO live_records(collection,id,body,revision,drive_revision,payload_hash) VALUES(?,?,?,?,?,?) ON CONFLICT(collection,id) DO UPDATE SET body=excluded.body,revision=excluded.revision,payload_hash=excluded.payload_hash", col, id, body, revision, current?.drive_revision || "", payloadHash(data));
  sql.exec("INSERT INTO live_backup(seq,collection,id,operation_id,operation,body,state,due,accepted_at,request_metadata) VALUES(?,?,?,?,?,?,'pending',?,?,?)", seq, col, id, operationId, operation === "delete" ? "delete" : "write", body, now, now, canonical(metadata));
  saveOwner(storage, col, id, data);
  return { seq, receipt };
}
__name(appendLive, "appendLive");
function ownsChild(kind, parentId, parent, col, id, row) {
  const generation2 = String(parent.mobileStableId || parent.teacherId || parentId), teacher = row.role === "teacher" || row.ownerRole === "teacher";
  if (row._syncDeleted) return false;
  if (kind === "students_directory") {
    if (row.personId != null) return row.personId === generation2 && !teacher;
    if (teacher) return false;
    const aliases = [parentId, ...Array.isArray(parent.previousStudentIds) ? parent.previousStudentIds : []];
    return ["studentId", "studentDocId", "studentDocumentId", "documentId", "oldStudentId", "previousStudentId"].some((key) => typeof row[key] === "string" && aliases.includes(row[key])) || col === "student_scan_index" && aliases.includes(id);
  }
  if (row.personId != null) return row.personId === generation2 && (teacher || typeof row.teacherId === "string");
  return typeof row.teacherId === "string" && [parent.teacherId, parentId].includes(row.teacherId) || ["teacherDocId", "teacherDocumentId"].some((key) => row[key] === parentId);
}
__name(ownsChild, "ownsChild");
function retireChildren(storage, school, col, id, parent, operationId, now) {
  const targets = [];
  for (const row of storage.sql.exec("SELECT collection,id,body FROM live_record_owners WHERE collection NOT IN ('students_directory','teachers_directory','staff_payroll_directory')")) {
    const data = JSON.parse(row.body);
    if (!ownsChild(col, id, parent, row.collection, row.id, data)) continue;
    demand(targets.length < 5e3, "Person cascade exceeds atomic limit; original work retained", 413);
    demand(storage.sql.exec("SELECT state FROM live_collections WHERE collection=?", row.collection).toArray()[0]?.state === "active", "Person dependency baseline required", 412);
    targets.push({ collection: row.collection, id: row.id, data });
  }
  const predecessors = [];
  for (const target of targets) {
    const childId = "cascade-" + hash([operationId, target.collection, target.id]);
    const data = { schoolId: school, _syncDeleted: true, _syncDeletedOwner: String(parent.mobileStableId || parent.teacherId || id) };
    const appended = appendLive(storage, school, target.collection, target.id, childId, "delete", data, now, hash([operationId, target.collection, target.id, "delete"]), { deleteEverywhereVersion: 1 });
    predecessors.push(appended.seq);
  }
  return predecessors;
}
__name(retireChildren, "retireChildren");
function liveCommand(storage, school, b, now = Date.now()) {
  demand(schoolPattern.test(school), "Invalid school");
  const sql = storage.sql, command = b.command, col = String(b.collection || "");
  const collection = /* @__PURE__ */ __name(() => demand(liveCollections.has(col), "Collection not admitted to live authority", 412), "collection");
  const head = /* @__PURE__ */ __name(() => sql.exec("SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name='live_events'),0) AS n").toArray()[0].n, "head");
  const state = /* @__PURE__ */ __name(() => sql.exec("SELECT * FROM live_collections WHERE collection=?", col).toArray()[0], "state");
  const row = /* @__PURE__ */ __name((id) => sql.exec("SELECT * FROM live_records WHERE collection=? AND id=?", col, id).toArray()[0], "row");
  if (command === "seedBegin") {
    collection();
    demand(typeof b.fingerprint === "string" && /^[a-f0-9]{64}$/.test(b.fingerprint) && Number.isSafeInteger(b.count) && Number(b.count) >= 0 && Number(b.count) <= 1e5 && typeof b.sourceRevision === "string" && b.sourceRevision.length > 0 && b.sourceRevision.length <= 100, "Invalid seed");
    const old = state();
    if (old) {
      if (old.fingerprint === b.fingerprint && old.expected_count === b.count && old.source_revision === b.sourceRevision) return { state: old.state };
      demand(old.state === "seeding" && b.replaceSeeding === true, "Seed identity changed; retain existing state", 409);
      return storage.transactionSync(() => {
        demand(sql.exec("SELECT count(*) AS n FROM live_events WHERE collection=?", col).toArray()[0].n === 0 && sql.exec("SELECT count(*) AS n FROM live_backup WHERE collection=?", col).toArray()[0].n === 0, "Committed collection cannot reseed", 409);
        sql.exec("DELETE FROM live_records WHERE collection=?", col);
        sql.exec("UPDATE live_collections SET fingerprint=?,expected_count=?,source_revision=? WHERE collection=?", b.fingerprint, Number(b.count), b.sourceRevision, col);
        return { state: "seeding" };
      });
    }
    sql.exec("INSERT INTO live_collections VALUES(?,'seeding',?,?,?)", col, b.fingerprint, Number(b.count), b.sourceRevision);
    return { state: "seeding" };
  }
  if (command === "seedPage") {
    collection();
    const s = state();
    demand(s?.state === "seeding" && s.fingerprint === b.fingerprint, "Seed not writable", 409);
    demand(Array.isArray(b.rows) && b.rows.length <= 100, "Seed page too large");
    storage.transactionSync(() => {
      for (const entry of b.rows) {
        demand(validId(entry.id) && entry.data && typeof entry.data === "object" && !Array.isArray(entry.data), "Invalid seed row");
        const data = entry.data;
        clean(data);
        demand(data.schoolId === school && typeof data._syncRevision === "string" && data._syncRevision.length > 0 && !/^(live-|cf-)/.test(data._syncRevision), "Unverified source row");
        const body = canonical(data), old = row(entry.id);
        demand(!old || old.body === body, "Seed replay differs", 409);
        if (!old) sql.exec("INSERT INTO live_records(collection,id,body,revision,drive_revision,payload_hash) VALUES(?,?,?,?,?,?)", col, entry.id, body, data._syncRevision, data._syncRevision, payloadHash(data));
        saveOwner(storage, col, entry.id, data);
        demand(col !== "school_settings" || entry.id !== "staff_payroll_directory", "Staff lifecycle has its own owner", 412);
      }
      demand(sql.exec("SELECT count(*) AS n FROM live_records WHERE collection=?", col).toArray()[0].n <= s.expected_count, "Seed count exceeded", 409);
    });
    return { state: "seeding" };
  }
  if (command === "seedSeal") {
    collection();
    return storage.transactionSync(() => {
      const s = state();
      demand(s && s.fingerprint === b.fingerprint, "Seed identity mismatch", 409);
      if (s.state === "active") return { state: "active" };
      const records = {};
      for (const r of sql.exec("SELECT * FROM live_records WHERE collection=? ORDER BY id", col)) records[r.id] = JSON.parse(r.body);
      demand(Object.keys(records).length === s.expected_count && hash(records) === s.fingerprint, "Incomplete or changed seed", 409);
      sql.exec("UPDATE live_collections SET state='active' WHERE collection=?", col);
      sql.exec("UPDATE live_records SET body='' WHERE collection=?", col);
      return { state: "active" };
    });
  }
  if (command === "read") {
    demand(col !== "school_settings" || b.id !== "staff_payroll_directory", "Staff lifecycle has its own owner", 412);
    collection();
    demand(state()?.state === "active", "Verified baseline required", 412);
    demand(validId(b.id), "Invalid record ID");
    const r = row(b.id);
    return { liveProtocol: 1, schoolId: school, record: r && r.body ? JSON.parse(r.body) : null, cursor: head(), ...r ? { recordRevision: r.revision, driveRevision: r.drive_revision, payloadHash: r.payload_hash, source: r.body ? "cloudflare" : "drive" } : { source: "missing" } };
  }
  if (command === "commit") {
    demand(col !== "school_settings" || b.id !== "staff_payroll_directory", "Staff lifecycle has its own owner", 412);
    collection();
    demand(state()?.state === "active", "Verified baseline required", 412);
    demand(validId(b.id) && opId(b.operationId) && ["write", "delete", "patch"].includes(String(b.operation)) && typeof b.expectedRevision === "string" && b.expectedRevision.length <= 100, "Invalid live operation");
    clean(b.data);
    demand(byteLength(JSON.stringify(b)) <= 256e3, "Live record too large", 413);
    demand(b.createIntent === void 0 || typeof b.createIntent === "boolean", "Invalid create intent");
    const fingerprint = hash({ collection: col, id: b.id, operation: b.operation, operationId: b.operationId, expectedRevision: b.expectedRevision, data: b.data ?? null, ...b.deleteEverywhereVersion === 1 ? { deleteEverywhereVersion: 1 } : {}, ...b.createIntent === true ? { createIntent: true } : {} });
    return storage.transactionSync(() => {
      const prior = sql.exec("SELECT fingerprint,receipt FROM live_operations WHERE operation_id=?", String(b.operationId)).toArray()[0];
      if (prior) {
        demand(prior.fingerprint === fingerprint, "Sync operation ID conflict", 409);
        return JSON.parse(prior.receipt);
      }
      const current = row(String(b.id));
      const baseline = b.baseline;
      if (current && !current.body) demand(baseline && baseline.schoolId === school && baseline._syncRevision === current.drive_revision && payloadHash(baseline) === current.payload_hash, "Verified Drive baseline required", 428);
      const old = current ? current.body ? JSON.parse(current.body) : { ...baseline, _syncRevision: current.revision } : {};
      let data;
      if (current && !domainCollections.has(col) && b.createIntent === true && b.operation === "write" && b.expectedRevision === "") {
        demand(b.data && typeof b.data === "object" && !Array.isArray(b.data) && b.data.schoolId === school && old._syncDeleted !== true && payloadHash(b.data) === current.payload_hash, "Offline create differs; retain both versions for review", 409);
        const backup = sql.exec("SELECT state FROM live_backup WHERE collection=? AND id=? ORDER BY seq DESC LIMIT 1", col, String(b.id)).toArray()[0];
        const backedUp = !backup || backup.state === "verified";
        const receipt = { liveProtocol: 1, schoolId: school, cloudState: "committed", backupState: backedUp ? "verified" : "pending", recordRevision: current.revision, operationId: b.operationId, cursor: head(), record: current.body ? old : null, duplicate: true, resolution: "cloudRetained", reconcileRequired: true, ...backedUp ? { source: current.body ? "cloudflare" : "drive", driveRevision: current.drive_revision, payloadHash: current.payload_hash } : {} };
        sql.exec("INSERT INTO live_operations VALUES(?,?,?)", String(b.operationId), fingerprint, JSON.stringify(receipt));
        return receipt;
      }
      demand((current?.revision || "") === b.expectedRevision, "Record revision conflict", 409);
      if (b.operation === "delete") data = { schoolId: school, _syncDeleted: true };
      else {
        demand(b.data && typeof b.data === "object" && !Array.isArray(b.data) && b.data.schoolId === school, "Foreign record", 403);
        demand(!old._syncDeleted || personCollections.has(col), "Explicit lifecycle recovery required", 409);
        if (b.operation === "patch") {
          const patch = b.data;
          demand(current && patch.set && typeof patch.set === "object" && !Array.isArray(patch.set) && Array.isArray(patch.remove), "Patch baseline required");
          const keys = [...Object.keys(patch.set), ...patch.remove];
          demand(keys.length <= 256 && keys.every((k) => typeof k === "string" && k.length > 0 && k.length <= 200 && !["id", "schoolId", "createdAt"].includes(k) && !k.startsWith("_sync")), "Invalid patch");
          demand(patch.remove.every((k) => !Object.hasOwn(patch.set, k)), "Overlapping patch");
          data = { ...old, ...patch.set };
          for (const k of patch.remove) delete data[k];
        } else data = { ...b.data };
        demand(!Object.keys(b.data).some((k) => k.startsWith("_sync")), "Client cannot set sync metadata");
      }
      const readOwner = /* @__PURE__ */ __name((collection2, id) => findOwner(storage, collection2, id), "readOwner");
      const readPeers = /* @__PURE__ */ __name((collection2) => storage.sql.exec("SELECT body FROM live_record_owners WHERE collection=?", collection2).toArray().map((row2) => JSON.parse(row2.body)), "readPeers");
      if (domainCollections.has(col)) validateDomainCandidate({ schoolId: school, collection: col, id: String(b.id), operation: String(b.operation), current: current ? old : null, next: data, readOwner });
      if (personCollections.has(col)) validatePersonCandidate({ schoolId: school, collection: col, id: String(b.id), operation: String(b.operation), current: current ? old : null, next: data, readPeers });
      if (current && (b.operation === "delete" && old._syncDeleted === true || b.operation !== "delete" && old._syncDeleted !== true && canonical(business(old)) === canonical(business(data)))) {
        const backup = sql.exec("SELECT state FROM live_backup WHERE collection=? AND id=? ORDER BY seq DESC LIMIT 1", col, String(b.id)).toArray()[0];
        const backedUp = !backup || backup.state === "verified";
        const receipt = { liveProtocol: 1, schoolId: school, cloudState: "committed", backupState: backedUp ? "verified" : "pending", recordRevision: current.revision, operationId: b.operationId, cursor: head(), record: current.body ? old : null, unchanged: true, ...backedUp ? { source: current.body ? "cloudflare" : "drive", driveRevision: current.drive_revision, payloadHash: current.payload_hash, reconcileRequired: true } : {} };
        sql.exec("INSERT INTO live_operations VALUES(?,?,?)", String(b.operationId), fingerprint, JSON.stringify(receipt));
        return receipt;
      }
      demand(sql.exec("SELECT count(*) AS n FROM live_events").toArray()[0].n < 1e6, "Live history capacity reached; retain local work", 503);
      const parentGeneration = String(old.mobileStableId || old.teacherId || b.id), nextGeneration = String(data.mobileStableId || data.teacherId || b.id);
      const retiring = personCollections.has(col) && current && (b.operation === "delete" || nextGeneration !== parentGeneration);
      const dependencies = retiring ? retireChildren(storage, school, col, String(b.id), old, String(b.operationId), now) : [];
      if (personCollections.has(col)) {
        const retiredKey = col === "students_directory" ? "_syncRetiredStudentGenerations" : "_syncRetiredTeacherGenerations";
        const retired = new Set(Array.isArray(old[retiredKey]) ? old[retiredKey] : []);
        if (retiring) retired.add(parentGeneration);
        if (retired.size) data[retiredKey] = [...retired];
        if (b.operation === "delete") {
          data._syncDeletedOwner = parentGeneration;
          if (col === "teachers_directory") data._syncRetiredTeacherId = old.teacherId || b.id;
        }
      }
      const appended = appendLive(storage, school, col, String(b.id), String(b.operationId), String(b.operation), data, now, fingerprint, { ...b.deleteEverywhereVersion === 1 ? { deleteEverywhereVersion: 1 } : {}, ...col === "students_directory" && b.operation === "delete" ? { deletedStudentGeneration: parentGeneration } : {} });
      for (const predecessor of dependencies) sql.exec("INSERT OR IGNORE INTO live_backup_dependencies VALUES(?,?)", appended.seq, predecessor);
      if (!personCollections.has(col) && b.operation !== "delete") {
        const teacher = data.role === "teacher" || data.ownerRole === "teacher" || ["teacher_salary", "teacher_attendance", "teacher_schedules"].includes(col);
        const ownerId = String(teacher ? data.teacherId || data.personId || "" : data.studentId || "");
        const ownerCol = teacher ? "teachers_directory" : "students_directory", owner = ownerId ? readOwner(ownerCol, ownerId) : null;
        if (owner) {
          const parent = sql.exec("SELECT seq FROM live_backup WHERE collection=? AND id=? AND state!='verified' ORDER BY seq DESC LIMIT 1", ownerCol, String(owner.id)).toArray()[0];
          if (parent) sql.exec("INSERT OR IGNORE INTO live_backup_dependencies VALUES(?,?)", appended.seq, parent.seq);
        }
      }
      return appended.receipt;
    });
  }
  if (command === "changes") {
    demand(Number.isSafeInteger(b.after) && Number(b.after) >= 0 && Number(b.after) <= head(), "Invalid cursor; snapshot required", 409);
    demand(Number(b.after) >= sql.exec("SELECT floor FROM live_retention WHERE id=1").toArray()[0].floor, "Replay history compacted; snapshot required", 409);
    const events = [];
    let bytes = 0;
    for (const r of sql.exec("SELECT seq,collection,id,body FROM live_events WHERE seq>? ORDER BY seq LIMIT 100", Number(b.after))) {
      const size = byteLength(r.body);
      if (bytes + size > 3e5 && events.length) break;
      bytes += size;
      events.push({ sequence: r.seq, collection: r.collection, id: r.id, ...r.body ? { record: JSON.parse(r.body) } : { source: "drive", record: null } });
    }
    const cursor = events.length ? Number(events[events.length - 1].sequence) : Number(b.after);
    return { liveProtocol: 1, schoolId: school, events, cursor, head: head(), more: cursor < head() };
  }
  if (command === "snapshot" || command === "rollbackSnapshot") {
    collection();
    demand(state()?.state === "active" || command === "rollbackSnapshot" && state()?.state === "legacy", "Verified baseline required", 412);
    demand((b.after === void 0 || typeof b.after === "string") && Number.isSafeInteger(b.at) && b.at === head(), "Snapshot changed; restart snapshot", 409);
    const records = [];
    let bytes = 0;
    for (const r of sql.exec("SELECT * FROM live_records WHERE collection=? AND id>? ORDER BY id LIMIT 100", col, String(b.after || ""))) {
      const size = byteLength(r.body);
      if (bytes + size > 3e5 && records.length) break;
      bytes += size;
      records.push({ id: r.id, record: r.body ? JSON.parse(r.body) : null, source: r.body ? "cloudflare" : "drive", driveRevision: r.drive_revision, recordRevision: r.revision, payloadHash: r.payload_hash });
    }
    return { liveProtocol: 1, schoolId: school, cursor: b.at, records, next: records.length ? records[records.length - 1].id : null };
  }
  if (command === "rollbackSeal") {
    collection();
    return storage.transactionSync(() => {
      demand(Number.isSafeInteger(b.cursor) && b.cursor === head(), "Rollback snapshot changed", 409);
      demand(typeof b.fingerprint === "string" && /^[a-f0-9]{64}$/.test(b.fingerprint), "Invalid rollback proof");
      const current = state();
      demand(current && ["active", "legacy"].includes(current.state), "Rollback state unavailable", 409);
      demand(sql.exec("SELECT count(*) AS n FROM live_backup WHERE collection=? AND state!='verified'", col).toArray()[0].n === 0, "Drive backup still pending", 409);
      const rows = sql.exec("SELECT * FROM live_records WHERE collection=? ORDER BY id", col).toArray();
      demand(rows.every((r) => r.drive_revision.length > 0), "Drive storage not verified", 409);
      const fingerprint = hash(rows.map((r) => ({ id: r.id, recordRevision: r.revision, driveRevision: r.drive_revision, payloadHash: r.payload_hash })));
      demand(fingerprint === b.fingerprint, "Rollback verification differs", 409);
      sql.exec("UPDATE live_events SET body='',receipt=json_set(receipt,'$.record',null,'$.source','drive') WHERE collection=?", col);
      sql.exec("UPDATE live_backup SET body='' WHERE collection=? AND state='verified'", col);
      sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.record',null,'$.source','drive','$.backupState','verified') WHERE json_extract(receipt,'$.recordRevision') IN (SELECT json_extract(receipt,'$.recordRevision') FROM live_events WHERE collection=?)", col);
      sql.exec("UPDATE live_records SET body='' WHERE collection=? AND drive_revision!=''", col);
      sql.exec("UPDATE live_collections SET state='legacy' WHERE collection=?", col);
      return { liveProtocol: 1, schoolId: school, collection: col, state: "legacy", cursor: head(), fingerprint, driveVerified: true, pending: 0, needsAttention: 0 };
    });
  }
  if (command === "capabilities") return { liveProtocol: 1, schoolId: school, domainCapabilities: 1, personCapabilities: 1, collections: [...liveCollections] };
  if (command === "head") return { liveProtocol: 1, schoolId: school, cursor: head(), collections: sql.exec("SELECT c.collection,c.state,coalesce(e.cursor,0) AS cursor FROM live_collections c LEFT JOIN live_collection_cursors e ON e.collection=c.collection").toArray() };
  if (command === "operationReceipt") {
    demand(opId(b.operationId), "Invalid operation identity");
    const saved = sql.exec("SELECT fingerprint,receipt FROM live_operations WHERE operation_id=?", String(b.operationId)).toArray()[0];
    const receipt = saved ? JSON.parse(saved.receipt) : null;
    const backup = receipt ? sql.exec("SELECT b.state,b.verified_at,b.drive_revision FROM live_backup b JOIN live_events e ON e.seq=b.seq WHERE json_extract(e.receipt,'$.recordRevision')=? ORDER BY b.seq DESC LIMIT 1", String(receipt.recordRevision)).toArray()[0] : null;
    return { liveProtocol: 1, schoolId: school, operationId: b.operationId, found: !!saved, ...saved ? { fingerprint: saved.fingerprint, receipt, deliveryState: backup?.state || (receipt?.backupState === "verified" ? "verified" : "pending"), verifiedAt: backup?.verified_at || 0 } : {} };
  }
  if (command === "expireVerified") return storage.transactionSync(() => {
    const stale = sql.exec(
      "SELECT b.seq,b.collection,b.id,b.operation_id,b.drive_revision,e.receipt FROM live_backup b JOIN live_events e ON e.seq=b.seq WHERE b.state='verified' AND b.verified_at>0 AND b.verified_at<=? AND b.body!='' ORDER BY b.seq LIMIT 200",
      now - cloudflareVerifiedRetentionMs
    ).toArray();
    for (const job of stale) {
      const rec = JSON.parse(job.receipt);
      demand(typeof job.drive_revision === "string" && job.drive_revision.length > 0 && rec.recordRevision && rec.operationId === job.operation_id, "Unverified retention receipt", 409);
      const original = sql.exec("SELECT body FROM live_backup WHERE seq=?", job.seq).toArray()[0]?.body;
      demand(!!original && payloadHash(JSON.parse(original)) === rec.payloadHash, "Backup payload changed; retain", 409);
      sql.exec("UPDATE live_events SET body='',receipt=json_set(receipt,'$.record',null,'$.source','drive') WHERE seq=? AND operation_id=?", job.seq, job.operation_id);
      sql.exec("UPDATE live_backup SET body='' WHERE seq=? AND state='verified' AND verified_at>0", job.seq);
      sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.record',null,'$.source','drive','$.backupState','verified') WHERE json_extract(receipt,'$.recordRevision')=?", rec.recordRevision);
      sql.exec(
        "UPDATE live_records SET body='' WHERE collection=? AND id=? AND revision=? AND drive_revision=?",
        job.collection,
        job.id,
        rec.recordRevision,
        job.drive_revision
      );
    }
    const next = sql.exec(
      "SELECT min(verified_at+?) AS due FROM live_backup WHERE state='verified' AND verified_at>0 AND body!=''",
      cloudflareVerifiedRetentionMs
    ).toArray()[0]?.due;
    return { expired: stale.length, nextCleanupAt: next ?? null };
  });
  if (command === "retention") return {
    retentionHours: 24,
    ...sql.exec("SELECT min(verified_at+?) AS nextCleanupAt FROM live_backup WHERE state='verified' AND verified_at>0 AND body!=''", cloudflareVerifiedRetentionMs).toArray()[0]
  };
  if (command === "compact") return storage.transactionSync(() => {
    demand(Number.isSafeInteger(b.before) && Number(b.before) >= 0 && Number(b.before) <= head(), "Invalid retention boundary");
    const floor = sql.exec("SELECT floor FROM live_retention WHERE id=1").toArray()[0].floor;
    const rows = sql.exec("SELECT e.seq,e.body,b.state FROM live_events e LEFT JOIN live_backup b ON b.seq=e.seq WHERE e.seq>? AND e.seq<=? ORDER BY e.seq LIMIT 1000", floor, Number(b.before)).toArray();
    let next = floor;
    for (const row2 of rows) {
      if (row2.state !== "verified" || row2.body !== "") break;
      next = row2.seq;
    }
    if (next > floor) {
      sql.exec("DELETE FROM live_events WHERE seq<=? AND body=''", next);
      sql.exec("DELETE FROM live_backup WHERE seq<=? AND state='verified' AND body=''", next);
      sql.exec("UPDATE live_retention SET floor=? WHERE id=1", next);
    }
    return { liveProtocol: 1, schoolId: school, cursor: head(), floor: next, snapshotRequiredBefore: next };
  });
  if (command === "received") {
    demand(typeof b.device === "string" && /^[a-f0-9]{64}$/.test(b.device) && Number.isSafeInteger(b.cursor) && Number(b.cursor) >= 0 && Number(b.cursor) <= head(), "Invalid device receipt");
    sql.exec("INSERT INTO live_device_receipts VALUES(?,?,?) ON CONFLICT(device) DO UPDATE SET cursor=max(cursor,excluded.cursor),observed_at=excluded.observed_at", b.device, Number(b.cursor), now);
    return { received: true };
  }
  if (command === "backupClaim") return storage.transactionSync(() => {
    const job = sql.exec("SELECT b.* FROM live_backup b WHERE b.state IN ('pending','retry','processing') AND b.due<=? AND NOT EXISTS(SELECT 1 FROM live_backup earlier WHERE earlier.collection=b.collection AND earlier.id=b.id AND earlier.seq<b.seq AND earlier.state!='verified') AND NOT EXISTS(SELECT 1 FROM live_backup_dependencies d JOIN live_backup previous ON previous.seq=d.predecessor WHERE d.sequence=b.seq AND previous.state!='verified') ORDER BY b.seq LIMIT 1", now).toArray()[0];
    if (!job) return { job: null };
    const claim = randomUUID();
    sql.exec("UPDATE live_backup SET state='processing',claim=?,claim_until=?,due=? WHERE seq=?", claim, now + 12e4, now + 12e4, job.seq);
    const current = sql.exec("SELECT * FROM live_records WHERE collection=? AND id=?", job.collection, job.id).toArray()[0];
    const data = JSON.parse(job.body);
    for (const k of Object.keys(data)) if (k.startsWith("_sync")) delete data[k];
    return { job: { seq: job.seq, claim, request: { action: "managed_records", collection: job.collection, id: job.id, operation: job.operation, syncProtocol: 2, operationId: job.operation_id, expectedRecordRevision: current.drive_revision, ...JSON.parse(job.request_metadata || "{}"), ...job.operation === "write" ? { data } : {} } } };
  });
  if (command === "backupFinish") return storage.transactionSync(() => {
    demand(Number.isSafeInteger(b.sequence) && typeof b.claim === "string", "Invalid backup receipt");
    const job = sql.exec("SELECT * FROM live_backup WHERE seq=?", Number(b.sequence)).toArray()[0];
    if (!job || job.state !== "processing" || job.claim !== b.claim || job.claim_until <= now) return { accepted: false };
    if (b.verified === true) {
      demand(typeof b.driveRevision === "string" && b.driveRevision.length > 0 && b.driveRevision.length <= 100 && !b.driveRevision.startsWith("live-") && !b.driveRevision.startsWith("cf-"), "Unverified backup revision");
      sql.exec("UPDATE live_backup SET state='verified',drive_revision=?,claim='',claim_until=0,due=?,verified_at=? WHERE seq=?", b.driveRevision, Number.MAX_SAFE_INTEGER, now, job.seq);
      sql.exec("UPDATE live_records SET drive_revision=? WHERE collection=? AND id=?", b.driveRevision, job.collection, job.id);
      const event = sql.exec("SELECT receipt FROM live_events WHERE seq=?", job.seq).toArray()[0];
      const receipt = JSON.parse(event.receipt);
      const reference = { ...receipt, backupState: "verified", source: "cloudflare", driveRevision: b.driveRevision, payloadHash: payloadHash(JSON.parse(job.body)), reconcileRequired: true, retainedUntil: now + cloudflareVerifiedRetentionMs };
      sql.exec("UPDATE live_events SET receipt=? WHERE seq=?", JSON.stringify(reference), job.seq);
      sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.backupState','verified','$.driveRevision',?,'$.payloadHash',?,'$.retainedUntil',?,'$.reconcileRequired',json('true')) WHERE json_extract(receipt,'$.recordRevision')=?", String(b.driveRevision), String(reference.payloadHash), now + cloudflareVerifiedRetentionMs, String(receipt.recordRevision));
      const metadata = JSON.parse(job.request_metadata || "{}");
      if (job.operation === "delete" && metadata.deleteEverywhereVersion === 1) {
        sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.record',null,'$.source','drive') WHERE json_extract(receipt,'$.recordRevision') IN (SELECT json_extract(receipt,'$.recordRevision') FROM live_events WHERE collection=? AND id=? AND seq<?)", job.collection, job.id, job.seq);
        sql.exec("UPDATE live_events SET body='',receipt=json_set(receipt,'$.record',null,'$.source','drive') WHERE collection=? AND id=? AND seq<?", job.collection, job.id, job.seq);
        sql.exec("UPDATE live_backup SET body='' WHERE collection=? AND id=? AND seq<? AND state='verified'", job.collection, job.id, job.seq);
      }
    } else {
      demand(Number.isSafeInteger(b.retryAt) && Number(b.retryAt) > now && Number(b.retryAt) <= now + 864e5, "Invalid backup retry");
      sql.exec("UPDATE live_backup SET state=?,due=?,claim='',claim_until=0 WHERE seq=?", b.review === true ? "review" : "retry", b.review === true ? Number.MAX_SAFE_INTEGER : Number(b.retryAt), job.seq);
    }
    return { accepted: true };
  });
  if (command === "backupHistory") {
    const entries = sql.exec("SELECT b.seq,b.collection,b.id,b.operation_id,b.state,b.accepted_at,b.verified_at,b.drive_revision,e.receipt FROM live_backup b JOIN live_events e ON e.seq=b.seq ORDER BY b.seq DESC LIMIT 25").toArray().map((row2) => ({ operationId: row2.operation_id, collection: row2.collection, id: row2.id, state: row2.state, sequence: row2.seq, acceptedAt: row2.accepted_at, verifiedAt: row2.verified_at, completedAt: row2.state === "verified" ? row2.verified_at : 0, recordRevision: String(JSON.parse(row2.receipt).recordRevision || ""), ...row2.state === "verified" ? { driveRevision: row2.drive_revision } : {} }));
    return { liveProtocol: 1, schoolId: school, entries };
  }
  if (command === "stats") return { liveProtocol: 1, schoolId: school, cursor: head(), backups: sql.exec("SELECT state,count(*) AS count,min(due) AS due FROM live_backup GROUP BY state").toArray(), payloadCopies: sql.exec("SELECT (SELECT count(*) FROM live_records WHERE body!='') AS records,(SELECT count(*) FROM live_events WHERE body!='') AS events,(SELECT count(*) FROM live_backup WHERE body!='') AS backups,(SELECT count(*) FROM live_operations WHERE json_type(receipt,'$.record')='object') AS operations").toArray()[0] };
  throw Object.assign(Error("Unknown live command"), { status: 400 });
}
__name(liveCommand, "liveCommand");

// src/live-socket.ts
import { Buffer as Buffer3 } from "node:buffer";
async function liveSocketGrant(request, secret, now = Date.now()) {
  const protocols = (request.headers.get("Sec-WebSocket-Protocol") || "").split(",").map((x) => x.trim());
  demand(request.headers.get("Upgrade")?.toLowerCase() === "websocket" && protocols.includes("vidya-live-v1"), "WebSocket protocol required", 400);
  const token = protocols.find((x) => x.startsWith("grant."))?.slice(6) || "";
  demand(token.length < 4e3, "Invalid live grant", 401);
  const [body, sig, ...extra] = token.split(".");
  demand(extra.length === 0 && /^[A-Za-z0-9_-]+$/.test(body || "") && /^[a-f0-9]{64}$/.test(sig || ""), "Live grant required", 401);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  demand(await crypto.subtle.verify("HMAC", key, new Uint8Array(Buffer3.from(sig, "hex")), new TextEncoder().encode("live-v1\n" + body)), "Live grant rejected", 401);
  const value = JSON.parse(Buffer3.from(body, "base64url").toString("utf8"));
  demand(value.version === 1 && schoolPattern.test(value.schoolId) && typeof value.uid === "string" && value.uid.length > 0 && Number.isSafeInteger(value.expiresAt) && value.expiresAt > now && value.expiresAt <= now + 6e4, "Live grant expired", 401);
  return value;
}
__name(liveSocketGrant, "liveSocketGrant");

// src/worker.ts
import { DurableObject } from "cloudflare:workers";
var SyncLane = class extends DurableObject {
  static {
    __name(this, "SyncLane");
  }
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      initSpool(ctx.storage);
      ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)");
      ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS jobs (seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,kind TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,due INTEGER NOT NULL,claim TEXT NOT NULL DEFAULT '',claim_until INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL,response TEXT,revision TEXT)");
      ctx.storage.sql.exec("CREATE INDEX IF NOT EXISTS due_jobs ON jobs(state,due,seq)");
      ctx.storage.sql.exec("CREATE INDEX IF NOT EXISTS revision_jobs ON jobs(revision)");
      ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS lanes (name TEXT PRIMARY KEY,due INTEGER NOT NULL,attention INTEGER NOT NULL DEFAULT 0)");
      if (!ctx.storage.sql.exec("PRAGMA table_info(lanes)").toArray().some((c) => c.name === "attention")) ctx.storage.sql.exec("ALTER TABLE lanes ADD COLUMN attention INTEGER NOT NULL DEFAULT 0");
      ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY,body TEXT NOT NULL)");
    });
  }
  meta(key) {
    return this.ctx.storage.sql.exec("SELECT value FROM metadata WHERE key=?", key).toArray()[0]?.value;
  }
  setMeta(key, value) {
    this.ctx.storage.sql.exec("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value);
  }
  job(id) {
    return this.ctx.storage.sql.exec("SELECT * FROM jobs WHERE id=?", id).toArray()[0];
  }
  async command(school, lane, b) {
    demand(schoolPattern.test(school) && (/^(?:attendance-[a-f0-9]{2}|notices|delivery|live)$/.test(lane) || spoolLane(lane)));
    const identity = school + "/" + lane;
    demand(!this.meta("identity") || this.meta("identity") === identity, "School scope rejected", 403);
    this.setMeta("identity", identity);
    if (lane === "live") {
      demand(this.env.LIVE_SYNC_TEST_SCHOOL_ID === school, "Live authority is not enabled for this school", 412);
      initLive(this.ctx.storage);
      if (b.command === "commit" || b.command === "backupFinish") await this.wake(Date.now() + 250);
      const result = liveCommand(this.ctx.storage, school, b);
      if (b.command === "backupFinish" && b.verified === true && result.accepted === true) {
        const head = liveCommand(this.ctx.storage, school, { command: "head" });
        if (Number(head.cursor) > 1e4) liveCommand(this.ctx.storage, school, { command: "compact", before: Number(head.cursor) - 1e4 });
      }
      if (b.command === "commit") for (const socket of this.ctx.getWebSockets()) {
        const grant = socket.deserializeAttachment();
        try {
          if (grant.schoolId !== school || grant.expiresAt <= Date.now()) socket.close(1008, "Refresh school authorization");
          else socket.send(JSON.stringify({ liveProtocol: 1, schoolId: school, cursor: result.cursor }));
        } catch {
        }
      }
      return result;
    }
    if (spoolLane(lane)) return spoolCommand(this.ctx.storage, school, lane, b, (at) => this.wake(at));
    const action = String(b.command || ""), id = String(b.id || "");
    if (action === "retireNoticeCache") {
      demand(lane === "notices" && this.env.LIVE_SYNC_TEST_SCHOOL_ID === school, "Isolated live notice owner required", 412);
      const owner = await this.env.LANES.getByName(school + "/live").command(school, "live", { command: "head" });
      demand(owner.collections.some((row) => row.collection === "school_notices" && row.state === "active"), "Verified live notice baseline required", 409);
      demand(this.ctx.storage.sql.exec("SELECT count(*) AS n FROM jobs WHERE state!='completed'").toArray()[0].n === 0, "Legacy notice delivery pending", 409);
      this.ctx.storage.transactionSync(() => {
        this.ctx.storage.sql.exec("DELETE FROM records");
        this.ctx.storage.sql.exec("UPDATE jobs SET payload='' WHERE state='completed'");
        this.setMeta("retired", "drive");
      });
      return { retired: true };
    }
    if (action === "schedule") {
      demand(lane === "delivery" && typeof b.sourceLane === "string" && (/^(?:attendance-[a-f0-9]{2}|notices)$/.test(b.sourceLane) || spoolLane(b.sourceLane)));
      this.ctx.storage.sql.exec("INSERT INTO lanes(name,due) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET due=min(lanes.due,excluded.due)", b.sourceLane, Date.now());
      await this.wake(Date.now() + 250);
      return true;
    }
    if (action === "stats" && lane === "delivery") return this.ctx.storage.sql.exec("SELECT count(*) AS pendingPartitions,coalesce(sum(attention),0) AS needsAttention FROM lanes").toArray()[0];
    if (action === "stats") {
      const stats = this.ctx.storage.sql.exec("SELECT count(*) AS pending,min(due) AS due FROM jobs WHERE state IN ('pending','retry','processing')").toArray()[0];
      const attention = this.ctx.storage.sql.exec("SELECT count(*) AS needsAttention FROM jobs WHERE state='needsAttention'").toArray()[0];
      return { ...stats, ...attention };
    }
    if (action === "get") {
      demand(operationPattern.test(id));
      return this.job(id) || null;
    }
    if (action === "pending") {
      const limit = Number(b.limit);
      demand(Number.isInteger(limit) && limit >= 1 && limit <= 200);
      const rows = this.ctx.storage.sql.exec("SELECT * FROM jobs WHERE state IN ('pending','retry','processing') ORDER BY seq LIMIT ?", limit).toArray();
      return lane === "notices" ? rows.slice(0, 1).filter((r) => r.due <= Date.now()) : rows.filter((r) => r.due <= Date.now());
    }
    if (action === "claim") {
      const row = this.job(id);
      if (!row || !["pending", "retry", "processing"].includes(row.state) || row.due > Date.now() || row.state === "processing" && row.claim_until > Date.now()) return false;
      demand(typeof b.claim === "string" && b.claim.length <= 100 && Number.isSafeInteger(b.expires) && Number(b.expires) > Date.now() && Number(b.expires) <= Date.now() + 18e4);
      this.ctx.storage.sql.exec("UPDATE jobs SET state='processing',claim=?,claim_until=?,due=? WHERE id=?", b.claim, Number(b.expires), Number(b.expires), id);
      return true;
    }
    if (action === "finish") {
      const row = this.job(id);
      if (!row || row.claim !== b.claim || !row.claim) return false;
      const values = b.values;
      demand(values && ["completed", "retry", "needsAttention"].includes(String(values.state)) && Number.isSafeInteger(values.nextAttemptAt));
      let clearedPayload;
      if (values.attendancePayloadPurged === true) {
        const original = JSON.parse(row.payload), receipt = values.attendanceOwnerReceipt;
        demand(lane.startsWith("attendance-") && values.state === "completed" && receipt?.version === 1 && receipt.driveVerified === true && receipt.schoolId === school && receipt.operationId === id && receipt.day === original.day && receipt.mode === original.mode && ["student", "teacher"].includes(String(receipt.role)) && typeof receipt.documentId === "string" && receipt.documentId.length > 0 && receipt.documentId.length <= 200 && !receipt.documentId.includes("/") && operationPattern.test(String(receipt.requestHash)) && operationPattern.test(String(receipt.payloadHash)), "Verified attendance owner required");
        demand(Object.keys(receipt).every((key) => ["version", "schoolId", "operationId", "role", "documentId", "day", "mode", "requestHash", "payloadHash", "driveVerified"].includes(key)), "Unexpected attendance receipt payload");
        demand(await digest(canonical(original.payload)) === receipt.payloadHash, "Attendance payload proof mismatch", 409);
        demand(this.job(id)?.claim === b.claim && row.claim_until > Date.now(), "Attendance claim changed", 409);
        clearedPayload = JSON.stringify({ schoolId: school, operationId: id, day: original.day, mode: original.mode, payload: null, createdAt: original.createdAt });
      }
      this.ctx.storage.transactionSync(() => {
        this.ctx.storage.sql.exec("UPDATE jobs SET state=?,due=?,claim='',claim_until=0,response=? WHERE id=?", String(values.state), Number(values.nextAttemptAt), JSON.stringify(values), id);
        if (clearedPayload !== void 0) this.ctx.storage.sql.exec("UPDATE jobs SET payload=? WHERE id=?", clearedPayload, id);
      });
      if (values.state === "retry") await this.wake(Number(values.nextAttemptAt));
      return true;
    }
    if (action === "create") {
      demand(lane.startsWith("attendance-") && operationPattern.test(id));
      const row = b.row;
      demand(row && row.schoolId === school && row.operationId === id && id.slice(0, 2) === lane.slice(-2));
      if (this.job(id)) return false;
      this.ctx.storage.sql.exec("INSERT INTO jobs(id,kind,payload,state,due,created) VALUES(?,'attendance',?,'pending',?,?)", id, JSON.stringify(row), Date.now(), Number(row.createdAt));
      await this.wake(Date.now() + 250);
      return true;
    }
    demand(lane === "notices");
    demand(!this.meta("retired") || !["seed", "snapshot", "write"].includes(action), "Legacy notice cache retired; use verified school owner", 412);
    if (action === "seed") {
      if (this.meta("initialized")) return { seeded: false };
      const records = b.records;
      demand(records && typeof records === "object" && Object.keys(records).length <= 1e4);
      this.ctx.storage.transactionSync(() => {
        for (const [key, value] of Object.entries(records)) {
          demand(key.length > 0 && key.length <= 200 && !key.includes("/") && ![".", "..", "__proto__", "prototype", "constructor"].includes(key) && value.schoolId === school);
          this.ctx.storage.sql.exec("INSERT INTO records(id,body) VALUES(?,?)", key, JSON.stringify(value));
        }
        this.setMeta("revision", String(b.revision || "legacy"));
        this.setMeta("initialized", "1");
      });
      return { seeded: true };
    }
    if (action === "snapshot") {
      const initialized = !!this.meta("initialized"), records = {};
      for (const row of this.ctx.storage.sql.exec("SELECT id,body FROM records LIMIT 10001")) records[row.id] = JSON.parse(row.body);
      demand(Object.keys(records).length <= 1e4, "Notice snapshot too large", 413);
      return { initialized, records, revision: this.meta("revision") || "legacy" };
    }
    if (action === "receipt") {
      demand(typeof b.revision === "string");
      const row = this.ctx.storage.sql.exec("SELECT * FROM jobs WHERE revision=?", b.revision).toArray()[0];
      return row ? { state: row.state, response: row.response ? JSON.parse(row.response) : null } : null;
    }
    if (action === "write") {
      demand(this.meta("initialized"), "Notice baseline required", 409);
      const request = b.request;
      demand(request && ["write", "delete"].includes(String(request.operation)) && request.syncProtocol === 2 && typeof request.id === "string" && request.id.length > 0 && request.id.length <= 200 && !request.id.includes("/") && ![".", "..", "__proto__", "prototype", "constructor"].includes(request.id) && /^[A-Za-z0-9_-]{16,100}$/.test(String(request.operationId)));
      const key = await digest(JSON.stringify([school, request.operationId]));
      const fingerprint = await digest(JSON.stringify(request));
      const prior = this.job(key);
      if (prior) {
        const saved = JSON.parse(prior.payload);
        demand(saved.fingerprint === fingerprint, "Sync operation ID conflict", 409);
        return saved.ack;
      }
      const revision = "cf-" + crypto.randomUUID(), collectionRevision = "cf-" + crypto.randomUUID();
      const ack = this.ctx.storage.transactionSync(() => {
        const currentRow = this.ctx.storage.sql.exec("SELECT body FROM records WHERE id=?", String(request.id)).toArray()[0];
        const current = currentRow ? JSON.parse(currentRow.body) : null;
        demand((current ? String(current._syncRevision || "") : "") === request.expectedRecordRevision, "Record revision conflict", 409);
        let data = request.operation === "delete" ? { schoolId: school, _syncDeleted: true } : structuredClone(request.data);
        demand(data && data.schoolId === school);
        const patch = data._syncFieldPatch;
        if (patch) {
          demand(current && !current._syncDeleted && patch.version === 1 && patch.set && typeof patch.set === "object" && !Array.isArray(patch.set) && Array.isArray(patch.remove) && Object.keys(patch.set).length + patch.remove.length <= 256);
          for (const field of [...Object.keys(patch.set), ...patch.remove]) {
            demand(typeof field === "string" && field.length > 0 && field.length <= 200 && !["id", "schoolId", "createdAt", "__proto__", "prototype", "constructor"].includes(field) && !field.startsWith("_sync"));
          }
          data = { ...current, ...patch.set };
          for (const field of patch.remove) {
            demand(typeof field === "string" && !["id", "schoolId", "createdAt", "__proto__", "prototype", "constructor"].includes(field) && !field.startsWith("_sync"));
            delete data[field];
          }
        }
        delete data._syncFieldPatch;
        const fields = { ...current?._syncFieldRevisions || {} };
        for (const field of /* @__PURE__ */ new Set([...Object.keys(current || {}), ...Object.keys(data)])) {
          if (field.startsWith("_sync") || field === "id" || field === "schoolId") continue;
          if (JSON.stringify(current?.[field]) !== JSON.stringify(data[field])) fields[field] = revision;
        }
        const record = { ...data, id: request.id, schoolId: school, _syncRevision: revision, _syncOperationId: request.operationId, _syncFieldRevisions: fields };
        const result = { success: true, schoolId: school, syncProtocol: 2, recordRevision: revision, collectionRevision, record, cloudflareAccepted: true, driveState: "pending" };
        const payload = { request, fingerprint, ack: result, record, baseRevision: request.expectedRecordRevision };
        this.ctx.storage.sql.exec("INSERT INTO jobs(id,kind,payload,state,due,created,revision) VALUES(?,'notice',?,'pending',?,?,?)", key, JSON.stringify(payload), Date.now(), Date.now(), revision);
        this.ctx.storage.sql.exec("INSERT INTO records(id,body) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body", String(request.id), JSON.stringify(record));
        this.setMeta("revision", collectionRevision);
        return result;
      });
      await this.wake(Date.now() + 250);
      return ack;
    }
    throw Object.assign(new Error("Unknown sync command"), { status: 400 });
  }
  async wake(at) {
    const existing = await this.ctx.storage.getAlarm();
    if (existing === null || existing > at) await this.ctx.storage.setAlarm(Math.max(Date.now() + 100, at));
  }
  async fetch(request) {
    return this.connectLive(await liveSocketGrant(request, this.env.EDGE_KEY));
  }
  async connectLive(grant) {
    demand(grant.schoolId === this.env.LIVE_SYNC_TEST_SCHOOL_ID && grant.expiresAt > Date.now(), "Live stream unavailable", 412);
    const identity = grant.schoolId + "/live";
    demand(!this.meta("identity") || this.meta("identity") === identity, "School scope rejected", 403);
    this.setMeta("identity", identity);
    initLive(this.ctx.storage);
    for (const socket of this.ctx.getWebSockets()) {
      const old = socket.deserializeAttachment();
      if (old.expiresAt <= Date.now()) socket.close(1008, "Refresh school authorization");
    }
    demand(this.ctx.getWebSockets().length < 100, "Live connection limit", 429);
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].serializeAttachment(grant);
    pair[1].send(JSON.stringify(liveCommand(this.ctx.storage, grant.schoolId, { command: "head" })));
    return new Response(null, { status: 101, webSocket: pair[0], headers: { "Sec-WebSocket-Protocol": "vidya-live-v1" } });
  }
  webSocketMessage(socket, message) {
    const grant = socket.deserializeAttachment();
    if (grant.expiresAt <= Date.now()) {
      socket.close(1008, "Refresh school authorization");
      return;
    }
    if (typeof message !== "string" || message !== "head") {
      socket.close(1008, "Unsupported live message");
      return;
    }
    socket.send(JSON.stringify(liveCommand(this.ctx.storage, grant.schoolId, { command: "head" })));
  }
  async alarm() {
    const identity = this.meta("identity");
    if (!identity) return;
    const [school, lane] = identity.split("/");
    if (lane === "live") {
      const raw2 = JSON.stringify({ action: "managed/live/drain", schoolId: school }), time2 = String(Date.now());
      try {
        const response = await fetch(this.env.BROKER_URL, { method: "POST", headers: { "Content-Type": "application/json", "Authorization": "Bearer cloudflare-delivery", "X-Vidya-Time": time2, "X-Vidya-Signature": await signature(this.env.EDGE_KEY, time2 + "\n" + raw2) }, body: raw2, signal: AbortSignal.timeout(11e4) });
        await response.body?.cancel();
      } catch {
      }
      let cleanupDue = null;
      try {
        const sweep = liveCommand(this.ctx.storage, school, { command: "expireVerified" });
        cleanupDue = sweep.nextCleanupAt;
        if (sweep.expired >= 200) cleanupDue = Date.now() + 1e3;
      } catch {
        cleanupDue = Date.now() + 6e4;
      }
      const rows = this.ctx.storage.sql.exec("SELECT min(b.due) AS due FROM live_backup b WHERE b.state IN ('pending','retry','processing') AND NOT EXISTS(SELECT 1 FROM live_backup earlier WHERE earlier.collection=b.collection AND earlier.id=b.id AND earlier.seq<b.seq AND earlier.state!='verified')").toArray();
      const pendingDue = rows[0]?.due ?? null;
      const due2 = pendingDue === null ? cleanupDue : cleanupDue === null ? pendingDue : Math.min(pendingDue, cleanupDue);
      if (due2 !== null) await this.ctx.storage.setAlarm(Math.max(Date.now() + 1e3, due2));
      return;
    }
    if (lane !== "delivery") {
      if (spoolLane(lane)) {
        try {
          const expired = await spoolCommand(this.ctx.storage, school, lane, { command: "expireVerified" }, (at) => this.wake(at));
          if (expired.nextCleanupAt !== null) await this.wake(expired.expired >= 200 ? Date.now() + 1e3 : expired.nextCleanupAt);
        } catch {
          await this.wake(Date.now() + 6e4);
        }
      }
      await this.env.LANES.getByName(school + "/delivery").command(school, "delivery", { command: "schedule", sourceLane: lane });
      return;
    }
    const next = this.ctx.storage.sql.exec("SELECT name,due FROM lanes WHERE due < 9007199254740991 ORDER BY due,name LIMIT 1").toArray()[0];
    const backoff = Number(this.meta("deliveryBackoff") || 0);
    if (backoff > Date.now()) {
      await this.ctx.storage.setAlarm(backoff);
      return;
    }
    if (!next) return;
    if (next.due > Date.now()) {
      await this.ctx.storage.setAlarm(next.due);
      return;
    }
    const raw = JSON.stringify({ action: "managed/cloudflare/drain", schoolId: school, lane: next.name }), time = String(Date.now());
    let delay = 3e4;
    try {
      const response = await fetch(this.env.BROKER_URL, { method: "POST", headers: { "Content-Type": "application/json", "Authorization": "Bearer cloudflare-delivery", "X-Vidya-Time": time, "X-Vidya-Signature": await signature(this.env.EDGE_KEY, time + "\n" + raw) }, body: raw, signal: AbortSignal.timeout(11e4) });
      if (response.ok) delay = 250;
      await response.body?.cancel();
    } catch {
    }
    if (delay >= 3e4) this.setMeta("deliveryBackoff", String(Date.now() + delay));
    else this.setMeta("deliveryBackoff", "0");
    const stats = await this.env.LANES.getByName(school + "/" + next.name).command(school, next.name, { command: "stats" });
    if (stats.pending === 0 && stats.needsAttention === 0) this.ctx.storage.sql.exec("DELETE FROM lanes WHERE name=?", next.name);
    else this.ctx.storage.sql.exec("UPDATE lanes SET due=?,attention=? WHERE name=?", stats.pending === 0 ? Number.MAX_SAFE_INTEGER : Math.max(Date.now() + delay, stats.due), stats.needsAttention, next.name);
    const due = this.ctx.storage.sql.exec("SELECT min(due) AS due FROM lanes WHERE due < 9007199254740991").toArray()[0]?.due;
    if (due !== null && due !== void 0) await this.ctx.storage.setAlarm(Math.max(Date.now() + 100, due));
  }
};
var worker_default = {
  async fetch(request, env) {
    const headers = { "Cache-Control": "no-store", "Content-Type": "application/json", "X-Content-Type-Options": "nosniff" };
    try {
      const url = new URL(request.url);
      if (url.pathname === "/healthz" && request.method === "GET") return Response.json({ service: "vidya-saarthi-cloudflare-sync", version: 2, edgeDeliveryVersion: 1, attendancePartitions: 256 }, { headers });
      if (url.pathname === "/live" && request.method === "GET") {
        const grant = await liveSocketGrant(request, env.EDGE_KEY);
        demand(grant.schoolId === env.LIVE_SYNC_TEST_SCHOOL_ID, "Live authority is not enabled", 412);
        return env.LANES.getByName(grant.schoolId + "/live").fetch(request);
      }
      if (request.method === "POST" && url.pathname === "/mobile") return Response.json(await mobileRequest(request, env), { headers });
      demand(request.method === "POST" && url.pathname === "/internal", "Not found", 404);
      const raw = await boundedBody(request, 8e5);
      demand(await authenticated(env.EDGE_KEY, raw, request.headers), "Sync authorization rejected", 401);
      const body = JSON.parse(raw), school = String(body.schoolId || ""), lane = String(body.lane || "");
      demand(schoolPattern.test(school) && (/^(?:attendance-[a-f0-9]{2}|notices|delivery|live)$/.test(lane) || spoolLane(lane)));
      demand(raw.length <= (/^file-[a-f0-9]{64}$/.test(lane) ? 8e5 : 4e5), "Request too large", 413);
      const value = await env.LANES.getByName(school + "/" + lane).command(school, lane, body);
      return Response.json({ success: true, schoolId: school, value }, { headers });
    } catch (error) {
      const e = error;
      const status = e.status || 503;
      return Response.json({ success: false, message: status < 500 ? e.message : "Cloudflare sync unavailable; pending work retained." }, { status, headers });
    }
  }
};
export {
  SyncLane,
  worker_default as default
};
//# sourceMappingURL=worker.js.map
