var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/broker-retry.mjs
function brokerRetryDelay(status, retryAfter, now = Date.now()) {
  if (status >= 200 && status < 300) return 250;
  const floor = status === 429 ? 6e4 : 3e4;
  if (typeof retryAfter !== "string" || !retryAfter.trim()) return floor;
  const value = retryAfter.trim();
  let delay;
  if (/^\d+$/.test(value)) delay = Number(value) * 1e3;
  else if (/^[A-Za-z]{3}, /.test(value)) delay = Date.parse(value) - now;
  else return floor;
  if (!Number.isSafeInteger(delay) || delay < 0 || !Number.isSafeInteger(now + delay) || now + delay > 864e13) return floor;
  return Math.max(floor, delay);
}
__name(brokerRetryDelay, "brokerRetryDelay");

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
var verifiedPayloadExpired = /* @__PURE__ */ __name((state, verifiedAt, purgeDue, now, acceptedAt = verifiedAt) => state === "completed" && [acceptedAt, verifiedAt, purgeDue, now].every(Number.isSafeInteger) && acceptedAt > 0 && verifiedAt >= acceptedAt && purgeDue >= Math.max(acceptedAt + verifiedPayloadTtlMs, verifiedAt) && now >= purgeDue, "verifiedPayloadExpired");
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
      if (get(id2).state === "receiving") {
        const accepted = Date.now();
        storage.sql.exec("UPDATE edge_ops SET state='pending',due=?,created=? WHERE id=?", accepted, accepted, id2);
      }
      await wake(Date.now() + 250);
    }
  }
  __name(seal, "seal");
  const receipt = /* @__PURE__ */ __name((row2) => ({ id: row2.id, state: row2.state, due: row2.due, response: row2.response ? JSON.parse(row2.response) : null }), "receipt");
  if (action === "expireVerified") {
    return storage.transactionSync(() => {
      const eligible = storage.sql.exec("SELECT * FROM edge_ops WHERE state='completed' AND verified_at>0 AND created>0 AND verified_at>=created AND purge_due>0 AND purge_due<=? AND (payload!='' OR ?=1) ORDER BY seq LIMIT 200", Date.now(), lane.startsWith("file-") ? 1 : 0).toArray();
      let cleared = 0;
      for (const row2 of eligible) {
        if (!verifiedPayloadExpired(row2.state, row2.verified_at, row2.purge_due, Date.now(), row2.created)) continue;
        if (lane.startsWith("file-")) {
          storage.sql.exec("UPDATE edge_chunks SET body=x''");
          storage.sql.exec("UPDATE edge_ops SET purge_due=0 WHERE id=? AND state='completed'", row2.id);
        } else {
          storage.sql.exec("UPDATE edge_ops SET payload='',purge_due=0 WHERE id=? AND state='completed' AND verified_at=?", row2.id, row2.verified_at);
        }
        cleared++;
      }
      const next = storage.sql.exec("SELECT min(purge_due) AS due FROM edge_ops WHERE state='completed' AND verified_at>0 AND created>0 AND verified_at>=created AND purge_due>0").toArray()[0]?.due;
      return { expired: cleared, nextCleanupAt: next ?? null };
    });
  }
  if (action === "retention") {
    const next = storage.sql.exec("SELECT min(purge_due) AS due FROM edge_ops WHERE state='completed' AND verified_at>0 AND created>0 AND verified_at>=created AND purge_due>0").toArray()[0]?.due;
    return { retentionHours: 24, nextCleanupAt: next ?? null };
  }
  if (action === "capabilities") return { edgeDeliveryVersion: 1, recordSchedulingVersion: 1, maxFileBytes: 20 * 1024 * 1024, chunkBytes: 512 * 1024 };
  if (action === "stats") return { ...storage.sql.exec("SELECT count(*) AS pending,min(due) AS due FROM edge_ops WHERE state IN ('pending','retry','processing')").toArray()[0], ...lane === "records" ? { due: schedule(storage, 512, Date.now()).due } : {}, ...storage.sql.exec("SELECT count(*) AS needsAttention FROM edge_ops WHERE state='needsAttention'").toArray()[0] };
  if (action === "settleTestStudentSlotReview") {
    const successorId = String(b.successorId || "");
    demand(
      lane === "records" && operationPattern.test(id) && operationPattern.test(successorId) && id !== successorId,
      "Invalid student slot review receipts"
    );
    const failed = get(id), accepted = get(successorId);
    demand(failed && accepted && accepted.seq > failed.seq && accepted.state === "completed" && ["needsAttention", "superseded"].includes(failed.state), "Original and successor receipts required", 409);
    const original = JSON.parse(failed.payload), next = JSON.parse(accepted.payload);
    const failure = JSON.parse(failed.response || "{}"), ack = JSON.parse(accepted.response || "{}").result;
    const validCreate = /* @__PURE__ */ __name((request) => request.action === "managed_records" && request.collection === "students_directory" && request.operation === "write" && request.syncProtocol === 2 && request.expectedRecordRevision === "" && request.id === b.recordId && request.data?.schoolId === school && request.data?.syntheticTest === true && request.data?.mobileStableId === b.generation, "validCreate");
    demand(
      validCreate(original) && validCreate(next) && /^p-[a-f0-9]{32,64}$/.test(String(b.generation)) && original.operationId !== next.operationId && next.operationId === b.operationId && failure.failureCode === "STUDENT_SLOT_CONFLICT" && failure.failureStatus === 409 && ack?.success === true && ack.schoolId === school && ack.syncProtocol === 2 && ack.recordRevision === b.revision && ack.record?._syncOperationId === b.operationId && ack.record?._syncRevision === b.revision,
      "Verified synthetic student slot successor required",
      409
    );
    const { rollNo: oldRoll, ...oldIdentity } = original.data;
    const { rollNo: newRoll, ...newIdentity } = next.data;
    demand(
      oldRoll !== void 0 && newRoll !== void 0 && oldRoll !== newRoll && canonical(oldIdentity) === canonical(newIdentity),
      "Successor must be the same synthetic student with a corrected roll number",
      409
    );
    for (const row2 of [failed, accepted]) {
      const request = JSON.parse(row2.payload);
      demand(
        await digest(canonical(request)) === row2.fingerprint && await digest(JSON.stringify([school, request.action, [request.collection, request.id, request.operationId]])) === row2.id,
        "Immutable student slot receipt mismatch",
        409
      );
    }
    return storage.transactionSync(() => {
      const current = get(id), successor = get(successorId);
      demand(
        current?.fingerprint === failed.fingerprint && successor?.state === "completed" && successor.fingerprint === accepted.fingerprint && successor.response === accepted.response,
        "Student slot successor changed",
        409
      );
      if (current.state === "superseded") {
        demand(JSON.parse(current.response || "{}").supersededBy === successorId, "Student slot review successor changed", 409);
      } else {
        demand(current.state === "needsAttention" && current.response === failed.response, "Student slot review changed", 409);
        storage.sql.exec(
          "UPDATE edge_ops SET state='superseded',response=? WHERE id=?",
          JSON.stringify({ ...failure, supersededBy: successorId }),
          id
        );
      }
      return { schoolId: school, id, successorId, state: "superseded" };
    });
  }
  if (action === "diagnoseDeleteReview") {
    demand(lane === "records" && operationPattern.test(id), "Invalid delete review receipt");
    const row2 = get(id);
    demand(row2, "Original delete receipt unavailable", 404);
    const request = JSON.parse(row2.payload);
    demand(
      request.action === "managed_records" && request.collection === "students_directory" && request.operation === "delete" && request.operationId === b.operationId && request.id === b.recordId && request.expectedRecordRevision === b.expectedRecordRevision && request.deletedStudentGeneration === b.deletedStudentGeneration,
      "Original delete review identity mismatch",
      409
    );
    const previous = row2.response ? JSON.parse(row2.response) : {};
    const count = Number(previous.reviewRetryCount || 0);
    const immutable = await digest(JSON.stringify([
      school,
      request.action,
      [request.collection, request.id, request.operationId]
    ])) === id && await digest(canonical(request)) === row2.fingerprint;
    const known = /* @__PURE__ */ new Set([
      "DELETE_EVERYWHERE_ACK_UNVERIFIED",
      "DELETE_EVERYWHERE_FIREBASE_PERMISSION_DENIED"
    ]);
    return {
      state: row2.state,
      retryCount: Number.isInteger(count) && count >= 0 ? count : -1,
      failureClass: typeof previous.failureCode === "string" && known.has(previous.failureCode) ? previous.failureCode : "OTHER",
      failureStatus: Number.isInteger(previous.failureStatus) ? previous.failureStatus : 0,
      sameRuntimeCredential: typeof previous.reviewCredentialFingerprint === "string" && previous.reviewCredentialFingerprint === b.credentialFingerprint,
      previousCredentialBound: typeof previous.reviewCredentialFingerprint === "string",
      immutable
    };
  }
  if (action === "retryDeleteReview") {
    demand(lane === "records" && operationPattern.test(id), "Invalid delete review receipt");
    const row2 = get(id);
    demand(row2, "Original delete receipt unavailable", 404);
    demand(row2.state === "needsAttention", "Only a review-needed delete may be reopened", 409);
    const request = JSON.parse(row2.payload);
    const previous = row2.response ? JSON.parse(row2.response) : {};
    demand(
      request.action === "managed_records" && request.collection === "students_directory" && request.operation === "delete" && request.syncProtocol === 2 && request.deleteEverywhereVersion === 1 && request.operationId === b.operationId && request.id === b.recordId && request.expectedRecordRevision === b.expectedRecordRevision && request.deletedStudentGeneration === b.deletedStudentGeneration && typeof request.deletedStudentGeneration === "string" && /^p-[a-f0-9]{32,64}$/.test(request.deletedStudentGeneration),
      "Original delete identity does not match the review request",
      409
    );
    const retryCount = Number(previous.reviewRetryCount || 0);
    const credentialFingerprint = b.credentialFingerprint;
    demand(
      typeof credentialFingerprint === "string" && /^[a-f0-9]{64}$/.test(credentialFingerprint),
      "Verified Render Firebase credential fingerprint required for review retry",
      409
    );
    const firstAckReview = previous.failureCode === "DELETE_EVERYWHERE_ACK_UNVERIFIED" && previous.failureStatus === 409 && retryCount === 0;
    const repairedCredentialReview = previous.failureCode === "DELETE_EVERYWHERE_FIREBASE_PERMISSION_DENIED" && previous.failureStatus === 503 && (retryCount === 0 && !previous.reviewCredentialFingerprint || retryCount === 1 && (!previous.reviewCredentialFingerprint || previous.reviewCredentialFingerprint !== credentialFingerprint));
    demand(
      firstAckReview || repairedCredentialReview,
      "Only the original ACK retry or one retry after a changed Firebase credential is allowed",
      409
    );
    demand(
      await digest(JSON.stringify([
        school,
        request.action,
        [request.collection, request.id, request.operationId]
      ])) === id && await digest(canonical(request)) === row2.fingerprint,
      "Original immutable delete receipt fingerprint mismatch",
      409
    );
    const at = Date.now(), response = { ...previous, reviewRetryCount: retryCount + 1, reviewRetryAt: at, reviewCredentialFingerprint: credentialFingerprint };
    storage.sql.exec(
      "UPDATE edge_ops SET state='retry',due=?,claim='',claim_until=0,response=? WHERE id=? AND state='needsAttention'",
      at,
      JSON.stringify(response),
      id
    );
    const reopened = get(id);
    demand(
      reopened.state === "retry" && reopened.payload === row2.payload && reopened.fingerprint === row2.fingerprint && JSON.parse(reopened.response || "{}").reviewRetryCount === retryCount + 1 && JSON.parse(reopened.response || "{}").reviewCredentialFingerprint === credentialFingerprint,
      "Original delete review retry was not durably committed",
      409
    );
    await wake(at + 250);
    return receipt(reopened);
  }
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
    const count = storage.sql.exec("SELECT count(*) AS n FROM edge_ops WHERE state NOT IN ('completed','superseded')").toArray()[0].n;
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
  if (action === "bundleProof") {
    demand(lane === "file-" + id, "File proof requires the original file owner", 400);
    await seal(id);
    const current = get(id), manifest = JSON.parse(current.payload);
    demand(["pending", "retry", "processing", "completed"].includes(current.state), "Staged file is not durable", 412);
    const size = Number(manifest.sizeBytes);
    const mediaMax = manifest.mime === "application/pdf" ? 150 * 1024 : ["image/jpeg", "image/png", "image/webp"].includes(String(manifest.mime)) ? 40 * 1024 : 0;
    demand(Number.isSafeInteger(size) && size > 0 && size <= mediaMax && manifest.received === size && typeof manifest.sha256 === "string" && operationPattern.test(manifest.sha256) && typeof manifest.uploadKey === "string" && await digest(JSON.stringify([school, manifest.uploadKey])) === id, "Staged file manifest incomplete", 412);
    const result = current.response ? JSON.parse(current.response).result : null;
    const driveVerified = current.state === "completed" && current.verified_at > 0 && result?.success === true && result.schoolId === school && result.uploadResumableVersion === 1 && result.uploadKey === manifest.uploadKey && result.sha256 === manifest.sha256 && result.sizeBytes === size && result.committed === true && result.offset === size && typeof result.fileId === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(result.fileId);
    const chunks = storage.sql.exec(
      "SELECT offset,size,body FROM edge_chunks ORDER BY offset"
    ).toArray();
    const purged = chunks.length === 1 && chunks[0].offset === 0 && chunks[0].size === size && chunks[0].body.byteLength === 0 && current.purge_due === 0 && current.verified_at > 0;
    if (purged) {
      demand(
        b.requireDrive === true && driveVerified,
        "Temporary Cloudflare bytes expired; signed Drive proof required",
        412
      );
      return {
        version: 1,
        schoolId: school,
        id,
        uploadKey: manifest.uploadKey,
        sha256: manifest.sha256,
        sizeBytes: size,
        mime: manifest.mime,
        staged: false,
        driveVerified: true,
        fileId: result.fileId
      };
    }
    demand(chunks.length === 1 && chunks[0].offset === 0 && chunks[0].size === size && chunks[0].body.byteLength === size, "Staged file bytes unavailable", 412);
    const bytes = new Uint8Array(chunks[0].body);
    const actual = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((x) => x.toString(16).padStart(2, "0")).join("");
    demand(actual === manifest.sha256, "Staged file SHA-256 mismatch", 409);
    if (manifest.mime === "application/pdf") {
      demand(
        bytes.length >= 16 && [37, 80, 68, 70, 45].every((v, i) => bytes[i] === v) && Buffer2.from(bytes.subarray(Math.max(0, bytes.length - 2048))).toString("latin1").includes("%%EOF"),
        "Staged ID PDF is incomplete",
        412
      );
    } else if (manifest.mime === "image/jpeg") {
      demand(size >= 6 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 && bytes[size - 2] === 255 && bytes[size - 1] === 217, "Staged JPEG is incomplete", 412);
    } else if (manifest.mime === "image/png") {
      demand(
        size >= 20 && [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => bytes[i] === v) && [73, 69, 78, 68, 174, 66, 96, 130].every((v, i) => bytes[size - 8 + i] === v),
        "Staged PNG is incomplete",
        412
      );
    } else if (manifest.mime === "image/webp") {
      demand(
        size >= 20 && Buffer2.from(bytes.subarray(0, 4)).toString("ascii") === "RIFF" && Buffer2.from(bytes.subarray(8, 12)).toString("ascii") === "WEBP" && new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(4, true) + 8 === size,
        "Staged WebP is incomplete",
        412
      );
    } else demand(false, "Unsupported atomic bundle media type", 412);
    if (b.requireDrive === true) demand(driveVerified, "Google Drive verified media receipt required", 412);
    return {
      version: 1,
      schoolId: school,
      id,
      uploadKey: manifest.uploadKey,
      sha256: manifest.sha256,
      sizeBytes: size,
      mime: manifest.mime,
      staged: true,
      driveVerified,
      ...driveVerified ? { fileId: result.fileId } : {}
    };
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
      const previousResponse = row.response ? JSON.parse(row.response) : {};
      const reviewMetadata = Number.isSafeInteger(previousResponse.reviewRetryCount) && Number(previousResponse.reviewRetryCount) >= 0 ? {
        reviewRetryCount: Number(previousResponse.reviewRetryCount),
        ...Number.isSafeInteger(previousResponse.reviewRetryAt) ? { reviewRetryAt: Number(previousResponse.reviewRetryAt) } : {},
        ...typeof previousResponse.reviewCredentialFingerprint === "string" && /^[a-f0-9]{64}$/.test(previousResponse.reviewCredentialFingerprint) ? { reviewCredentialFingerprint: previousResponse.reviewCredentialFingerprint } : {}
      } : {};
      const nextValues = { ...values, ...reviewMetadata };
      const stored = nextValues.payloadPurged === true ? { ...nextValues, partial: {} } : nextValues;
      const verified = values.state === "completed" && (values.payloadPurged === true || lane.startsWith("file-"));
      const verifiedAt = verified ? Date.now() : 0, expiry = verified && Number.isSafeInteger(row.created) && row.created > 0 && row.created <= verifiedAt ? Math.max(row.created + verifiedPayloadTtlMs, verifiedAt) : 0;
      storage.sql.exec("UPDATE edge_ops SET state=?,due=?,claim='',claim_until=0,response=?,verified_at=?,purge_due=? WHERE id=?", String(values.state), Number(values.nextAttemptAt), JSON.stringify(stored), verifiedAt, expiry, id);
    });
    if (values.state === "retry") await wake(Number(values.nextAttemptAt));
    if (values.state === "completed") {
      const due = get(id).purge_due;
      if (due > 0) await wake(Math.max(Date.now() + 1e3, due));
    }
    return true;
  }
  throw Object.assign(Error("Unknown delivery command"), { status: 400 });
}
__name(spoolCommand, "spoolCommand");

// src/r2-capacity.mjs
var R2_SCHOOL_DATA_BYTES = 8e9;
var R2_SYSTEM_RESERVE_BYTES = 2e9;
var R2_TOTAL_BYTES = R2_SCHOOL_DATA_BYTES + R2_SYSTEM_RESERVE_BYTES;
var R2_VERIFIED_RETENTION_MS = 24 * 60 * 60 * 1e3;
function checkedR2Admission(usedSchool, usedSystem, bytes, category = "school") {
  const counts = [usedSchool, usedSystem, bytes];
  if (!counts.every((n) => Number.isSafeInteger(n) && n >= 0) || bytes === 0 || !["school", "system"].includes(category)) throw new RangeError("Invalid R2 quota request");
  const used = usedSchool + usedSystem, next = used + bytes;
  if (!Number.isSafeInteger(next)) throw new RangeError("Invalid R2 usage");
  const school = category === "school" ? usedSchool + bytes : usedSchool;
  const system = category === "system" ? usedSystem + bytes : usedSystem;
  if (school > R2_SCHOOL_DATA_BYTES || system > R2_SYSTEM_RESERVE_BYTES || next > R2_TOTAL_BYTES) return {
    accepted: false,
    code: "R2_CAPACITY_EXCEEDED",
    schoolLimitBytes: R2_SCHOOL_DATA_BYTES,
    reservedSystemBytes: R2_SYSTEM_RESERVE_BYTES,
    totalLimitBytes: R2_TOTAL_BYTES
  };
  return {
    accepted: true,
    schoolBytes: school,
    systemBytes: system,
    totalBytes: next,
    schoolLimitBytes: R2_SCHOOL_DATA_BYTES,
    reservedSystemBytes: R2_SYSTEM_RESERVE_BYTES,
    totalLimitBytes: R2_TOTAL_BYTES
  };
}
__name(checkedR2Admission, "checkedR2Admission");
function verifiedR2PurgeDue(acceptedAt, verifiedAt) {
  if (![acceptedAt, verifiedAt].every((n) => Number.isSafeInteger(n) && n > 0) || verifiedAt < acceptedAt)
    throw new RangeError("Original and verified receipt timestamps required");
  return Math.max(acceptedAt + R2_VERIFIED_RETENTION_MS, verifiedAt);
}
__name(verifiedR2PurgeDue, "verifiedR2PurgeDue");
function r2MayPurge(row, now) {
  return row?.state === "verified" && Number.isSafeInteger(now) && Number.isSafeInteger(row.accepted_at) && row.accepted_at > 0 && Number.isSafeInteger(row.verified_at) && row.verified_at >= row.accepted_at && Number.isSafeInteger(row.purge_due) && row.purge_due >= row.accepted_at + R2_VERIFIED_RETENTION_MS && row.purge_due <= now;
}
__name(r2MayPurge, "r2MayPurge");

// src/r2-stage.ts
var schoolPattern2 = /^vs-[a-f0-9]{32}$/;
var hex2 = /^[a-f0-9]{64}$/;
var lanePattern = /^(?:records|notices|live|attendance-[a-f0-9]{2}|file-[a-f0-9]{64})$/;
var fail = /* @__PURE__ */ __name((message, status = 503) => {
  throw Object.assign(Error(message), { status });
}, "fail");
function init(storage) {
  storage.sql.exec("CREATE TABLE IF NOT EXISTS r2_staged (key TEXT PRIMARY KEY,school TEXT NOT NULL,lane TEXT NOT NULL,receipt_id TEXT NOT NULL,bytes INTEGER NOT NULL,sha256 TEXT NOT NULL,category TEXT NOT NULL,state TEXT NOT NULL,accepted_at INTEGER NOT NULL,verified_at INTEGER NOT NULL DEFAULT 0,purge_due INTEGER NOT NULL DEFAULT 0)");
  if (!storage.sql.exec("PRAGMA table_info(r2_staged)").toArray().some((c) => c.name === "accepted_final"))
    storage.sql.exec("ALTER TABLE r2_staged ADD COLUMN accepted_final INTEGER NOT NULL DEFAULT 0");
  storage.sql.exec("CREATE INDEX IF NOT EXISTS r2_verified_cleanup ON r2_staged(state,purge_due)");
  storage.sql.exec("CREATE INDEX IF NOT EXISTS r2_original_receipt ON r2_staged(school,lane,receipt_id)");
}
__name(init, "init");
function usage(storage) {
  const rows = storage.sql.exec("SELECT category,coalesce(sum(bytes),0) AS used FROM r2_staged WHERE state!='purged' GROUP BY category").toArray();
  return { schoolBytes: rows.find((r) => r.category === "school")?.used ?? 0, systemBytes: rows.find((r) => r.category === "system")?.used ?? 0 };
}
__name(usage, "usage");
function r2BudgetStatus(storage) {
  init(storage);
  const u = usage(storage);
  const states = storage.sql.exec("SELECT state,sum(bytes) AS bytes,count(*) AS objects FROM r2_staged GROUP BY state").toArray();
  return { ...u, reservedBytes: states.find((r) => r.state === "reserved")?.bytes ?? 0, storedBytes: states.find((r) => r.state === "stored")?.bytes ?? 0, verifiedBytes: states.find((r) => r.state === "verified")?.bytes ?? 0, purgedObjects: states.find((r) => r.state === "purged")?.objects ?? 0, schoolLimitBytes: R2_SCHOOL_DATA_BYTES, reservedSystemBytes: R2_SYSTEM_RESERVE_BYTES, totalLimitBytes: R2_TOTAL_BYTES, storageClass: "Standard", scope: "private-R2-staging-bucket" };
}
__name(r2BudgetStatus, "r2BudgetStatus");
async function stageR2Unlocked(storage, bucket, school, lane, receiptId, segment, buffer, category = "school") {
  demand(
    schoolPattern2.test(school) && lanePattern.test(lane) && hex2.test(receiptId) && Number.isSafeInteger(segment) && segment >= 0 && segment <= 20 * 1024 * 1024 && buffer instanceof ArrayBuffer && buffer.byteLength > 0 && buffer.byteLength <= 512 * 1024,
    "Invalid private R2 staging identity",
    400
  );
  if (!bucket) throw Object.assign(Error("Private R2 bucket unavailable"), { status: 503 });
  init(storage);
  const key = "saarthi-v1/" + school + "/" + lane + "/" + receiptId + "/" + segment;
  const bytes = new Uint8Array(buffer), sha256 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", buffer))].map((x) => x.toString(16).padStart(2, "0")).join("");
  let existing = storage.sql.exec("SELECT * FROM r2_staged WHERE key=?", key).toArray()[0];
  if (existing) {
    demand(
      existing.school === school && existing.lane === lane && existing.receipt_id === receiptId && existing.sha256 === sha256 && existing.bytes === bytes.byteLength && existing.category === category,
      "Immutable R2 operation ID conflict",
      409
    );
    if (["stored", "verified", "purged"].includes(existing.state)) return { accepted: true, receiptId, lane, bytes: bytes.byteLength, alreadyStaged: true, driveVerified: existing.state !== "stored" };
  } else {
    storage.transactionSync(() => {
      const check = usage(storage), status = checkedR2Admission(check.schoolBytes, check.systemBytes, bytes.byteLength, category);
      if (!status.accepted) fail("School R2 capacity reached; local work retained", 507);
      storage.sql.exec(
        "INSERT INTO r2_staged(key,school,lane,receipt_id,bytes,sha256,category,state,accepted_at) VALUES(?,?,?,?,?,?,?,'reserved',?)",
        key,
        school,
        lane,
        receiptId,
        bytes.byteLength,
        sha256,
        category,
        Date.now()
      );
    });
    existing = storage.sql.exec("SELECT * FROM r2_staged WHERE key=?", key).toArray()[0];
  }
  try {
    const current = await bucket.head(key);
    if (!current || current.size !== bytes.byteLength || current.customMetadata?.sha256 !== sha256) {
      const stored = await bucket.put(key, buffer, { customMetadata: { schema: "saarthi-r2-stage-v1", sha256 } });
      if (!stored || stored.size !== bytes.byteLength) fail("R2 staging did not confirm bytes");
    }
    storage.sql.exec("UPDATE r2_staged SET state='stored',accepted_at=? WHERE key=? AND state='reserved'", Date.now(), key);
  } catch (error) {
    fail("Private R2 staging unavailable; local work retained");
  }
  return { accepted: true, receiptId, lane, bytes: bytes.byteLength, alreadyStaged: existing.state !== "reserved", driveVerified: false };
}
__name(stageR2Unlocked, "stageR2Unlocked");
var objectLocks = /* @__PURE__ */ new WeakMap();
async function withObjectLock(storage, key, work) {
  let locks = objectLocks.get(storage);
  if (!locks) {
    locks = /* @__PURE__ */ new Map();
    objectLocks.set(storage, locks);
  }
  const prior = locks.get(key) || Promise.resolve();
  const pending = prior.catch(() => {
  }).then(work);
  locks.set(key, pending);
  try {
    return await pending;
  } finally {
    if (locks.get(key) === pending) locks.delete(key);
  }
}
__name(withObjectLock, "withObjectLock");
async function stageR2(storage, bucket, school, lane, receiptId, segment, buffer, category = "school") {
  const key = "saarthi-v1/" + school + "/" + lane + "/" + receiptId + "/" + segment;
  return withObjectLock(storage, key, () => stageR2Unlocked(storage, bucket, school, lane, receiptId, segment, buffer, category));
}
__name(stageR2, "stageR2");
function acceptR2Original(storage, school, lane, receiptId) {
  demand(schoolPattern2.test(school) && lanePattern.test(lane) && hex2.test(receiptId), "Invalid original acceptance", 400);
  init(storage);
  const at = Date.now();
  storage.transactionSync(() => {
    const rows = storage.sql.exec("SELECT * FROM r2_staged WHERE school=? AND lane=? AND receipt_id=? AND accepted_final=0 AND state IN ('stored','verified')", school, lane, receiptId).toArray();
    for (const row of rows) {
      const verified = row.verified_at ? Math.max(row.verified_at, at) : 0;
      storage.sql.exec(
        "UPDATE r2_staged SET accepted_at=?,accepted_final=1,verified_at=?,purge_due=? WHERE key=?",
        at,
        verified,
        verified ? verifiedR2PurgeDue(at, verified) : 0,
        row.key
      );
    }
  });
  return { accepted: true };
}
__name(acceptR2Original, "acceptR2Original");
async function markR2Verified(storage, school, lane, receiptId, verifiedAt = Date.now()) {
  demand(schoolPattern2.test(school) && lanePattern.test(lane) && hex2.test(receiptId) && Number.isSafeInteger(verifiedAt) && verifiedAt > 0, "Invalid original receipt", 400);
  init(storage);
  const rows = storage.sql.exec("SELECT * FROM r2_staged WHERE school=? AND lane=? AND receipt_id=? AND state IN ('stored','verified')", school, lane, receiptId).toArray();
  let due = null;
  storage.transactionSync(() => {
    for (const row of rows) {
      const at = row.verified_at || verifiedAt;
      const expire = row.accepted_final === 1 ? verifiedR2PurgeDue(row.accepted_at, at) : 0;
      storage.sql.exec("UPDATE r2_staged SET state='verified',verified_at=?,purge_due=? WHERE key=? AND state IN ('stored','verified')", at, expire, row.key);
      if (expire > 0) due = due === null ? expire : Math.min(due, expire);
    }
  });
  return { verifiedObjects: rows.length, nextCleanupAt: due };
}
__name(markR2Verified, "markR2Verified");
async function sweepR2Verified(storage, bucket, now = Date.now()) {
  if (!bucket) throw Object.assign(Error("Private R2 bucket unavailable"), { status: 503 });
  init(storage);
  const rows = storage.sql.exec("SELECT * FROM r2_staged WHERE state='verified' AND purge_due>0 AND purge_due<=? ORDER BY purge_due LIMIT 100", now).toArray();
  let removed = 0, cleanupFailed = false;
  for (const row of rows) {
    if (!r2MayPurge(row, now)) continue;
    try {
      await withObjectLock(storage, row.key, async () => {
        await bucket.delete(row.key);
        storage.sql.exec("UPDATE r2_staged SET state='purged' WHERE key=? AND state='verified' AND verified_at=? AND purge_due=?", row.key, row.verified_at, row.purge_due);
      });
      removed++;
    } catch {
      cleanupFailed = true;
      break;
    }
  }
  const next = storage.sql.exec("SELECT min(purge_due) AS due FROM r2_staged WHERE state='verified' AND purge_due>0").toArray()[0]?.due ?? null;
  return { removed, nextCleanupAt: cleanupFailed ? now + 6e4 : next, more: !cleanupFailed && rows.length === 100, cleanupFailed };
}
__name(sweepR2Verified, "sweepR2Verified");

// src/r2-scoped-admission.mjs
function r2StagingForSchool(env, school) {
  if (env?.R2_STAGING_ENABLED !== "true" || typeof school !== "string" || !/^vs-[a-f0-9]{32}$/.test(school)) return false;
  const raw = env?.R2_STAGING_SCHOOLS;
  if (raw === void 0) return env.LIVE_SYNC_TEST_SCHOOL_ID === school;
  if (typeof raw !== "string") return false;
  if (raw.trim() === "*") return env.R2_STAGING_ALL_SCHOOLS_ENABLED === "true";
  const scopes = raw.split(",").map((s) => s.trim());
  if (scopes.some((s) => s !== "" && !/^vs-[a-f0-9]{32}$/.test(s))) return false;
  return scopes.includes(school);
}
__name(r2StagingForSchool, "r2StagingForSchool");

// src/worker.ts
import { Buffer as Buffer4 } from "node:buffer";

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
  for (const [name, definition] of [["bundle_id", "TEXT"], ["bundle_size", "INTEGER NOT NULL DEFAULT 0"], ["bundle_index", "INTEGER NOT NULL DEFAULT -1"]]) {
    if (!storage.sql.exec("PRAGMA table_info(live_events)").toArray().some((c) => c.name === name))
      storage.sql.exec("ALTER TABLE live_events ADD COLUMN " + name + " " + definition);
  }
  storage.sql.exec("CREATE INDEX IF NOT EXISTS live_events_bundle ON live_events(bundle_id) WHERE bundle_id IS NOT NULL");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_operations(operation_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,receipt TEXT NOT NULL)");
  storage.sql.exec("CREATE TABLE IF NOT EXISTS live_bundles(bundle_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,receipt TEXT NOT NULL)");
  storage.sql.exec("CREATE INDEX IF NOT EXISTS live_bundles_mobile_owner ON live_bundles(json_extract(receipt,'$.owner.role'),json_extract(receipt,'$.owner.personId'))");
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
function appendLive(storage, school, col, id, operationId, operation, data, now, fingerprint, metadata = {}, bundleId = null, bundleSize = 0, bundleIndex = -1) {
  const sql = storage.sql, current = sql.exec("SELECT * FROM live_records WHERE collection=? AND id=?", col, id).toArray()[0];
  const revision = "live-" + randomUUID(), lifecycle = Object.fromEntries(Object.entries(data).filter(([key]) => ["_syncDeletedOwner", "_syncRetiredTeacherId", "_syncRetiredStudentGenerations", "_syncRetiredTeacherGenerations"].includes(key)));
  data = { ...business(data), ...lifecycle, ...operation === "delete" ? { _syncDeleted: true } : {}, schoolId: school, _syncRevision: revision, _syncOperationId: operationId };
  const body = canonical(data);
  sql.exec("INSERT INTO live_events(collection,id,body,operation_id,fingerprint,receipt,bundle_id,bundle_size,bundle_index) VALUES(?,?,?,?,?,?,?,?,?)", col, id, body, operationId, fingerprint, "", bundleId, bundleSize, bundleIndex);
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
function liveCommand(storage, school, b, now = Date.now(), withinBundle = false, verifiedMedia, bundleId, bundleSize = 0, bundleIndex = -1) {
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
  const currentBundleDocument = /* @__PURE__ */ __name((receipt, bundleId2) => {
    const refs = sql.exec(
      "SELECT r.id,r.revision,r.body,e.bundle_index FROM live_events e JOIN live_records r ON r.collection=e.collection AND r.id=e.id WHERE e.bundle_id=? AND e.collection='documents' LIMIT 2",
      bundleId2
    ).toArray();
    const a = receipt.acknowledgements;
    return refs.length === 1 && Array.isArray(a) && a.length >= 2 && a.length <= 3 && refs[0].bundle_index === a.length - 1 && refs[0].revision === a[a.length - 1].recordRevision && (!refs[0].body || JSON.parse(refs[0].body)._syncDeleted !== true);
  }, "currentBundleDocument");
  if (command === "ownerBundle") {
    demand(
      ["student", "teacher"].includes(String(b.role)) && typeof b.personId === "string" && validId(b.personId),
      "Invalid mobile bundle owner",
      400
    );
    const row2 = sql.exec(
      "SELECT receipt FROM live_bundles WHERE json_extract(receipt,'$.owner.role')=? AND json_extract(receipt,'$.owner.personId')=? ORDER BY rowid DESC LIMIT 1",
      String(b.role),
      String(b.personId)
    ).toArray()[0];
    if (!row2) return { bundleProtocol: 1, schoolId: school, found: false };
    const saved = JSON.parse(row2.receipt), files = saved.files;
    demand(saved.cloudState === "committed" && saved.mediaReady === true && saved.owner && Array.isArray(files), "Published mobile bundle unavailable", 412);
    if (!currentBundleDocument(saved, String(saved.bundleId)))
      return { bundleProtocol: 1, schoolId: school, found: false };
    const card = files.filter((f) => f.kind === "idCard");
    demand(card.length === 1 && typeof card[0].id === "string" && /^[a-f0-9]{64}$/.test(card[0].id), "Published ID card proof unavailable", 412);
    const photos = files.filter((f) => f.kind === "photo");
    demand(
      photos.length <= 1 && photos.every((p) => typeof p.id === "string" && /^[a-f0-9]{64}$/.test(p.id) && typeof p.sha256 === "string" && /^[a-f0-9]{64}$/.test(p.sha256) && ["image/jpeg", "image/png", "image/webp"].includes(String(p.mime)) && Number.isSafeInteger(p.sizeBytes) && Number(p.sizeBytes) > 0 && Number(p.sizeBytes) <= 40 * 1024),
      "Published school portrait proof unavailable",
      412
    );
    return {
      bundleProtocol: 1,
      schoolId: school,
      found: true,
      bundleId: saved.bundleId,
      id: card[0].id,
      sha256: card[0].sha256,
      sizeBytes: card[0].sizeBytes,
      mime: card[0].mime,
      archiveReady: saved.archiveReady === true,
      noPhoto: photos.length === 0,
      ...photos.length === 1 ? { portrait: {
        id: photos[0].id,
        sha256: photos[0].sha256,
        mime: photos[0].mime,
        sizeBytes: photos[0].sizeBytes
      } } : {}
    };
  }
  if (command === "ownerFinancialBundle") {
    demand(
      ["feeReceipt", "marksheet"].includes(String(b.role)) && typeof b.personId === "string" && validId(b.personId) && typeof b.documentId === "string" && validId(b.documentId),
      "Invalid authenticated financial document identity",
      400
    );
    const row2 = sql.exec(
      "SELECT b.receipt FROM live_bundles b JOIN live_events e ON e.bundle_id=b.bundle_id WHERE json_extract(b.receipt,'$.owner.role')=? AND json_extract(b.receipt,'$.owner.personId')=? AND e.collection='documents' AND e.id=? ORDER BY b.rowid DESC LIMIT 1",
      String(b.role),
      String(b.personId),
      String(b.documentId)
    ).toArray()[0];
    if (!row2) return { bundleProtocol: 1, schoolId: school, found: false };
    const saved = JSON.parse(row2.receipt), files = saved.files;
    if (saved.schoolId !== school || saved.cloudState !== "committed" || saved.mediaReady !== true || !Array.isArray(files) || !currentBundleDocument(saved, String(saved.bundleId)))
      return { bundleProtocol: 1, schoolId: school, found: false };
    const kind = b.role === "feeReceipt" ? "receipt" : "marksheet";
    const pdf = files.filter((f) => f.kind === kind);
    demand(
      pdf.length === 1 && pdf[0].mime === "application/pdf" && typeof pdf[0].id === "string" && /^[a-f0-9]{64}$/.test(pdf[0].id) && typeof pdf[0].sha256 === "string" && /^[a-f0-9]{64}$/.test(pdf[0].sha256) && Number.isSafeInteger(pdf[0].sizeBytes) && Number(pdf[0].sizeBytes) > 0 && Number(pdf[0].sizeBytes) <= (kind === "receipt" ? 30 * 1024 : 150 * 1024),
      "Authenticated financial PDF proof unavailable",
      412
    );
    return {
      bundleProtocol: 1,
      schoolId: school,
      found: true,
      bundleId: saved.bundleId,
      documentId: b.documentId,
      kind,
      id: pdf[0].id,
      sha256: pdf[0].sha256,
      sizeBytes: pdf[0].sizeBytes,
      mime: pdf[0].mime,
      archiveReady: saved.archiveReady === true
    };
  }
  if (command === "bundleArchiveManifest") {
    demand(opId(b.bundleId), "Invalid bundle archive identity", 400);
    const saved = sql.exec(
      "SELECT receipt FROM live_bundles WHERE bundle_id=?",
      String(b.bundleId)
    ).toArray()[0];
    demand(saved, "Published bundle required before archive handoff", 404);
    const receipt = JSON.parse(saved.receipt);
    demand(receipt.schoolId === school && receipt.cloudState === "committed" && receipt.mediaReady === true && Array.isArray(receipt.files) && receipt.files.length >= 1, "Invalid published archive manifest", 412);
    return {
      bundleProtocol: 1,
      schoolId: school,
      bundleId: b.bundleId,
      mediaManifestHash: receipt.mediaManifestHash,
      files: receipt.files.map((f) => ({
        kind: f.kind,
        id: f.id,
        sha256: f.sha256,
        sizeBytes: f.sizeBytes,
        mime: f.mime
      }))
    };
  }
  if (command === "bundleMedia") {
    demand(
      opId(b.bundleId) && ["idCard", "photo", "receipt", "marksheet"].includes(String(b.kind)) && typeof b.id === "string" && /^[a-f0-9]{64}$/.test(b.id),
      "Invalid atomic media lookup",
      400
    );
    const row2 = sql.exec(
      "SELECT receipt FROM live_bundles WHERE bundle_id=?",
      String(b.bundleId)
    ).toArray()[0];
    demand(row2, "Atomic media bundle is not published", 404);
    const receipt = JSON.parse(row2.receipt);
    demand(
      receipt.schoolId === school && receipt.cloudState === "committed" && receipt.mediaReady === true && Array.isArray(receipt.files),
      "Atomic media bundle is unavailable",
      412
    );
    demand(
      currentBundleDocument(receipt, String(b.bundleId)),
      "The published ID was replaced or deleted",
      409
    );
    const found = receipt.files.filter((f) => f.id === b.id && f.kind === b.kind);
    demand(
      found.length === 1 && /^[a-f0-9]{64}$/.test(String(found[0].sha256 || "")) && Number.isSafeInteger(found[0].sizeBytes) && Number(found[0].sizeBytes) > 0 && Number(found[0].sizeBytes) <= (b.kind === "photo" ? 40 * 1024 : b.kind === "receipt" ? 30 * 1024 : b.kind === "marksheet" ? 150 * 1024 : 85 * 1024),
      "Requested media is not part of the published atomic group",
      403
    );
    return {
      bundleProtocol: 1,
      schoolId: school,
      bundleId: b.bundleId,
      id: b.id,
      kind: b.kind,
      sha256: found[0].sha256,
      sizeBytes: found[0].sizeBytes,
      mime: found[0].mime,
      archiveReady: receipt.archiveReady === true,
      ownerRole: receipt.owner?.role,
      personId: receipt.owner?.personId,
      ...typeof found[0].fileId === "string" ? { fileId: found[0].fileId } : {}
    };
  }
  if (command === "bundleReceipt") {
    demand(opId(b.bundleId) && Array.isArray(b.operations) && Array.isArray(b.media) && typeof b.mediaManifestHash === "string", "Invalid bundle replay identity");
    const fingerprint = hash({
      schoolId: school,
      bundleId: b.bundleId,
      operations: b.operations,
      media: b.media,
      mediaManifestHash: b.mediaManifestHash
    });
    const prior = sql.exec(
      "SELECT fingerprint,receipt FROM live_bundles WHERE bundle_id=?",
      String(b.bundleId)
    ).toArray()[0];
    if (!prior) return { found: false, bundleProtocol: 1, schoolId: school };
    demand(prior.fingerprint === fingerprint, "Atomic bundle replay changed", 409);
    const receipt = JSON.parse(prior.receipt);
    const listed = receipt.acknowledgements;
    demand(
      Array.isArray(listed) && listed.length === b.operations.length,
      "Atomic receipt lost operation boundary",
      412
    );
    const states = listed.map((ack, index) => {
      const expected = b.operations[index];
      demand(ack.operationId === expected.operationId && typeof ack.recordRevision === "string", "Atomic operation identity changed", 409);
      const backup = sql.exec(
        "SELECT state,drive_revision,verified_at FROM live_backup WHERE operation_id=? AND collection=? AND id=? ORDER BY seq DESC LIMIT 1",
        String(expected.operationId),
        String(expected.collection),
        String(expected.id)
      ).toArray()[0];
      demand(backup, "Atomic operation has no durable backup job", 412);
      return {
        operationId: expected.operationId,
        recordRevision: ack.recordRevision,
        collection: expected.collection,
        id: expected.id,
        backupState: backup.state,
        driveVerified: backup.state === "verified" && typeof backup.drive_revision === "string" && backup.drive_revision.length > 0,
        ...backup.state === "verified" && typeof backup.drive_revision === "string" ? { driveRevision: backup.drive_revision, verifiedAt: backup.verified_at } : {}
      };
    });
    return {
      found: true,
      bundleProtocol: 1,
      schoolId: school,
      receipt,
      backups: states,
      driveVerified: states.every((r) => r.driveVerified === true),
      cloudState: receipt.cloudState,
      mediaReady: receipt.mediaReady === true
    };
  }
  if (command === "bundleCommit") {
    demand(!withinBundle, "Nested bundle rejected");
    demand(opId(b.bundleId) && Array.isArray(b.operations) && b.operations.length >= 2 && b.operations.length <= 5, "Invalid atomic bundle");
    demand(b.files === void 0 && b.fileReferences === void 0, "Unverified media references", 412);
    if (verifiedMedia) {
      demand(
        Array.isArray(b.media) && b.media.length >= 1 && b.media.length <= 2 && verifiedMedia.mediaReady === true && verifiedMedia.manifestHash === b.mediaManifestHash && Array.isArray(verifiedMedia.proofs) && verifiedMedia.proofs.length === b.media.length,
        "Immutable staged media proof required",
        412
      );
    } else demand(
      b.media === void 0 && b.mediaManifestHash === void 0,
      "Media bundle staging not yet verified",
      412
    );
    demand(byteLength(JSON.stringify(b)) <= 256e3, "Atomic bundle too large", 413);
    const allowed = verifiedMedia ? /* @__PURE__ */ new Set(["students_directory", "teachers_directory", "fee_payments", "fee_ledger", "exam_results", "exam_center_results", "documents"]) : /* @__PURE__ */ new Set(["school_notices", "school_calendar", "school_settings", "school_expenses"]);
    let archiveFiles = [], bundleOwner;
    if (verifiedMedia) {
      const ops = b.operations;
      const kind = String(verifiedMedia.proofs[0]?.kind || "");
      const personKind = kind === "idCard", feeKind = kind === "receipt", examKind = kind === "marksheet";
      const count = feeKind ? 3 : 2;
      demand(
        (personKind || feeKind || examKind) && ops.length === count && ops.every((op) => op.operation === "write") && ops[count - 1].collection === "documents",
        "Original business record and PDF must commit in one complete group",
        412
      );
      const first = ops[0], last = ops[count - 1], head2 = first.data, child = last.data;
      demand(
        head2 && child && head2.schoolId === school && child.schoolId === school && [head2, child].every((d) => !Object.hasOwn(d, "bundleMedia") && !Object.hasOwn(d, "bundleId")),
        "Client cannot supply verified media metadata",
        403
      );
      const proofs = verifiedMedia.proofs;
      demand(
        proofs[0].kind === kind && proofs.every((p) => typeof p.sha256 === "string" && /^[a-f0-9]{64}$/.test(p.sha256) && (p.driveVerified !== true || typeof p.fileId === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(p.fileId))) && (personKind ? proofs.length === 1 || proofs.length === 2 && proofs[1].kind === "photo" : proofs.length === 1 && proofs[0].mime === "application/pdf"),
        "Original media proof does not match bundle type",
        412
      );
      if (personKind) {
        const unstagedPortrait = /* @__PURE__ */ __name((value, depth = 0) => {
          if (depth > 12) return true;
          if (typeof value === "string") return value.trimStart().startsWith("data:image/");
          if (Array.isArray(value)) return value.some((item) => unstagedPortrait(item, depth + 1));
          if (value && typeof value === "object") {
            for (const [key, item] of Object.entries(value)) {
              if (/^(?:photo(?:url|base64|fileid|path|uri|mimetype|sourcehash)|portrait(?:url|base64|fileid|path|uri)|imagebase64)$/i.test(key) && item !== null && item !== void 0 && (typeof item !== "string" || item.trim().length > 0)) return true;
              if (unstagedPortrait(item, depth + 1)) return true;
            }
          }
          return false;
        }, "unstagedPortrait");
        demand(
          personCollections.has(String(first.collection)) && !Object.hasOwn(head2, "atomicPortrait") && !unstagedPortrait(head2),
          "Person photo must be staged with the original atomic portrait",
          412
        );
        const teacher = first.collection === "teachers_directory";
        demand(
          typeof head2.mobileStableId === "string" && /^p-[a-f0-9]{32,64}$/.test(head2.mobileStableId),
          "Original person generation required for an ID bundle",
          409
        );
        const generation2 = String(head2.mobileStableId);
        demand(
          child.personId === generation2 && child.ownerRole === (teacher ? "teacher" : "student") && child.studentId === first.id && (teacher ? child.teacherId === first.id : child.teacherId === void 0) && child.documentKind === "idCard" && child.documentId === last.id && child.documentRevision === last.operationId && child.contentHash === proofs[0].sha256 && child.mimeType === "application/pdf" && child.sizeBytes === proofs[0].sizeBytes,
          "ID document must match the exact owner generation and staged PDF",
          409
        );
        bundleOwner = { role: teacher ? "teacher" : "student", personId: generation2 };
      } else {
        demand(
          head2.studentId !== void 0 && typeof head2.studentId === "string" && head2.studentId.length > 0 && head2.studentId.length <= 200 && typeof child.personId === "string" && child.personId.length > 0 && (head2.personId === void 0 || head2.personId === child.personId) && child.studentId === head2.studentId && child.ownerRole === "student" && child.contentHash === proofs[0].sha256 && child.mimeType === "application/pdf",
          "School receipt/marksheet has no matching student or byte hash",
          409
        );
        if (feeKind) {
          const ledger = ops[1].data;
          demand(
            first.collection === "fee_payments" && ops[1].collection === "fee_ledger" && head2.paymentId === first.id && head2.receiptDocumentId === last.id && child.documentKind === "feeReceipt" && ledger && ledger.schoolId === school && ledger.studentId === head2.studentId && (ledger.personId === void 0 || ledger.personId === child.personId) && ledger.lastPaymentId === first.id && ledger.month === head2.month && typeof head2.month === "string" && head2.month.length > 0 && typeof head2.totalPaid === "number" && Number.isFinite(head2.totalPaid) && typeof head2.expectedAmount === "number" && Number.isFinite(head2.expectedAmount) && typeof head2.installmentAmount === "number" && Number.isFinite(head2.installmentAmount) && head2.installmentAmount > 0 && head2.totalPaid <= head2.expectedAmount && ledger.totalPaid === head2.totalPaid && ledger.expectedAmount === head2.expectedAmount && !Object.hasOwn(ledger, "bundleMedia") && !Object.hasOwn(ledger, "bundleId"),
            "Fee ledger, original payment and receipt must agree",
            409
          );
        } else {
          demand(
            ["exam_results", "exam_center_results"].includes(String(first.collection)) && child.documentKind === "marksheet" && (child.examResultId === first.id || head2.marksheetDocumentId === last.id) && typeof first.id === "string" && first.id.length > 0,
            "Exam result and original marksheet must agree",
            409
          );
        }
        bundleOwner = { role: feeKind ? "feeReceipt" : "marksheet", personId: child.personId };
      }
      archiveFiles = proofs.map((p) => ({
        kind: p.kind,
        id: p.id,
        ...p.driveVerified === true ? { fileId: p.fileId } : {},
        sha256: p.sha256,
        sizeBytes: p.sizeBytes,
        mime: p.mime
      }));
      demand(
        child.fileId === void 0 || proofs[0].driveVerified === true && child.fileId === proofs[0].fileId,
        "Original PDF fileId cannot be invented before Drive ACK",
        409
      );
    }
    const operationIds = /* @__PURE__ */ new Set(), recordKeys = /* @__PURE__ */ new Set();
    for (const item of b.operations) {
      demand(item && typeof item === "object" && !Array.isArray(item), "Invalid bundled record");
      demand(Object.keys(item).every((k) => ["collection", "id", "operation", "operationId", "expectedRevision", "data", "createIntent", "deleteEverywhereVersion"].includes(k)), "Unknown bundle operation field");
      demand(typeof item.collection === "string" && allowed.has(item.collection), "Unverified person, document or financial bundle", 412);
      demand(validId(item.id) && opId(item.operationId) && typeof item.expectedRevision === "string" && ["write", "delete", "patch"].includes(String(item.operation)), "Invalid bundled operation");
      const key = item.collection + "/" + item.id;
      demand(!recordKeys.has(key) && !operationIds.has(item.operationId), "Duplicate bundle record/operation", 409);
      recordKeys.add(key);
      operationIds.add(String(item.operationId));
    }
    const fingerprint = hash({
      schoolId: school,
      bundleId: b.bundleId,
      operations: b.operations,
      ...verifiedMedia ? { media: b.media, mediaManifestHash: b.mediaManifestHash } : {}
    });
    return storage.transactionSync(() => {
      const prior = sql.exec("SELECT fingerprint,receipt FROM live_bundles WHERE bundle_id=?", String(b.bundleId)).toArray()[0];
      if (prior) {
        demand(prior.fingerprint === fingerprint, "Atomic bundle replay changed", 409);
        return JSON.parse(prior.receipt);
      }
      for (const id of operationIds) demand(
        sql.exec("SELECT operation_id FROM live_operations WHERE operation_id=?", id).toArray().length === 0,
        "An existing operation cannot be repackaged as an atomic bundle",
        409
      );
      const acknowledgements = b.operations.map((item, index) => liveCommand(
        storage,
        school,
        {
          ...item,
          command: "commit",
          ...verifiedMedia && ["students_directory", "teachers_directory"].includes(String(b.operations[0].collection)) && index === 0 && archiveFiles.length === 2 ? {
            data: { ...item.data, atomicPortrait: {
              bundleId: b.bundleId,
              documentId: b.operations[1].id,
              role: bundleOwner?.role,
              id: archiveFiles[1].id,
              sha256: archiveFiles[1].sha256,
              mime: archiveFiles[1].mime,
              sizeBytes: archiveFiles[1].sizeBytes
            } }
          } : {},
          ...verifiedMedia && index === b.operations.length - 1 ? { data: {
            ...item.data,
            bundleMedia: archiveFiles,
            bundleManifestHash: b.mediaManifestHash,
            bundleId: b.bundleId,
            ...archiveFiles[0].fileId ? { fileId: archiveFiles[0].fileId } : {}
          } } : {}
        },
        now,
        true,
        void 0,
        String(b.bundleId),
        b.operations.length,
        index
      ));
      demand(
        acknowledgements.every((r) => r.unchanged !== true && r.duplicate !== true),
        "Atomic bundle contains a no-op or duplicate; reconcile before publishing",
        409
      );
      const receipt = {
        bundleProtocol: 1,
        liveProtocol: 1,
        schoolId: school,
        bundleId: b.bundleId,
        cloudState: "committed",
        backupState: acknowledgements.every((r) => r.backupState === "verified") ? "verified" : "pending",
        cursor: head(),
        manifestHash: fingerprint,
        ...verifiedMedia ? {
          mediaReady: true,
          archiveReady: verifiedMedia.archiveReady === true,
          mediaManifestHash: b.mediaManifestHash,
          files: archiveFiles,
          owner: bundleOwner
        } : {},
        acknowledgements: acknowledgements.map((r) => ({
          operationId: r.operationId,
          recordRevision: r.recordRevision,
          cloudState: r.cloudState,
          backupState: r.backupState,
          cursor: r.cursor,
          unchanged: r.unchanged === true
        }))
      };
      sql.exec("INSERT INTO live_bundles VALUES(?,?,?)", String(b.bundleId), fingerprint, JSON.stringify(receipt));
      return receipt;
    });
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
    const commitOne = /* @__PURE__ */ __name(() => {
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
      if (withinBundle && personCollections.has(col) && current)
        demand(
          nextGeneration === parentGeneration,
          "Person generation replacement requires separate lifecycle repair",
          412
        );
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
      const appended = appendLive(storage, school, col, String(b.id), String(b.operationId), String(b.operation), data, now, fingerprint, { ...b.deleteEverywhereVersion === 1 ? { deleteEverywhereVersion: 1 } : {}, ...col === "students_directory" && b.operation === "delete" ? { deletedStudentGeneration: parentGeneration } : {} }, bundleId || null, bundleSize, bundleIndex);
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
    }, "commitOne");
    return withinBundle ? commitOne() : storage.transactionSync(commitOne);
  }
  if (command === "changes") {
    demand(Number.isSafeInteger(b.after) && Number(b.after) >= 0 && Number(b.after) <= head(), "Invalid cursor; snapshot required", 409);
    demand(Number(b.after) >= sql.exec("SELECT floor FROM live_retention WHERE id=1").toArray()[0].floor, "Replay history compacted; snapshot required", 409);
    const rows = sql.exec(
      "SELECT seq,collection,id,body,bundle_id,bundle_size,bundle_index FROM live_events WHERE seq>? ORDER BY seq LIMIT 105",
      Number(b.after)
    ).toArray();
    const events = [];
    let bytes = 0;
    for (let i = 0; i < rows.length; ) {
      const first = rows[i], count = first.bundle_id ? first.bundle_size : 1;
      demand(
        Number.isSafeInteger(count) && count >= 1 && count <= 5 && (!first.bundle_id || first.bundle_index === 0) && i + count <= rows.length,
        "Atomic replay boundary invalid; recover a verified snapshot",
        409
      );
      const group = rows.slice(i, i + count);
      if (first.bundle_id) for (let j = 0; j < count; j++)
        demand(
          group[j].bundle_id === first.bundle_id && group[j].bundle_size === count && group[j].bundle_index === j && group[j].seq === first.seq + j,
          "Atomic replay group incomplete; recover a verified snapshot",
          409
        );
      const groupBytes = group.reduce((total, r) => total + byteLength(r.body), 0);
      demand(groupBytes <= 3e5, "Atomic replay group exceeds the delivery budget", 413);
      if (events.length && (events.length + count > 100 || bytes + groupBytes > 3e5)) break;
      bytes += groupBytes;
      for (const r of group) events.push({
        sequence: r.seq,
        collection: r.collection,
        id: r.id,
        ...r.bundle_id ? { bundleId: r.bundle_id, bundleSize: r.bundle_size, bundleIndex: r.bundle_index } : {},
        ...r.body ? { record: JSON.parse(r.body) } : { source: "drive", record: null }
      });
      i += count;
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
      "SELECT b.seq,b.collection,b.id,b.operation_id,b.drive_revision,e.receipt FROM live_backup b JOIN live_events e ON e.seq=b.seq WHERE b.state='verified' AND b.verified_at>0 AND b.accepted_at>0 AND b.verified_at>=b.accepted_at AND b.accepted_at<=? AND b.body!='' ORDER BY b.seq LIMIT 200",
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
      "SELECT min(max(accepted_at+?,verified_at)) AS due FROM live_backup WHERE state='verified' AND verified_at>0 AND accepted_at>0 AND verified_at>=accepted_at AND body!=''",
      cloudflareVerifiedRetentionMs
    ).toArray()[0]?.due;
    return { expired: stale.length, nextCleanupAt: next ?? null };
  });
  if (command === "retention") return {
    retentionHours: 24,
    ...sql.exec("SELECT min(max(accepted_at+?,verified_at)) AS nextCleanupAt FROM live_backup WHERE state='verified' AND verified_at>0 AND accepted_at>0 AND verified_at>=accepted_at AND body!=''", cloudflareVerifiedRetentionMs).toArray()[0]
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
      const event = sql.exec("SELECT receipt FROM live_events WHERE seq=?", job.seq).toArray()[0];
      demand(event && event.receipt, "Live backup event receipt missing", 412);
      const receipt = JSON.parse(event.receipt);
      let finalBody = JSON.parse(job.body);
      if (b.archiveFiles !== void 0) {
        demand(
          job.collection === "documents" && job.operation === "write" && Array.isArray(b.archiveFiles) && Array.isArray(finalBody.bundleMedia),
          "Archive applies only to a staged document",
          412
        );
        const old = finalBody.bundleMedia, next = b.archiveFiles;
        demand(
          old.length === next.length && old.length >= 1 && old.length <= 2,
          "Published file set differs from Drive receipt",
          409
        );
        for (let i = 0; i < old.length; i++) {
          demand(
            old[i].kind === next[i].kind && old[i].id === next[i].id && old[i].sha256 === next[i].sha256 && old[i].sizeBytes === next[i].sizeBytes && old[i].mime === next[i].mime && typeof next[i].fileId === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(String(next[i].fileId)) && (old[i].fileId === void 0 || old[i].fileId === next[i].fileId),
            "Archive cannot replace staged bytes or original Drive identity",
            409
          );
        }
        demand(
          finalBody.fileId === void 0 || finalBody.fileId === next[0].fileId,
          "Archive card ID differs from original staging",
          409
        );
        finalBody = { ...finalBody, bundleMedia: next, fileId: next[0].fileId };
        sql.exec(
          "UPDATE live_records SET body=?,payload_hash=? WHERE collection=? AND id=? AND revision=?",
          canonical(finalBody),
          payloadHash(finalBody),
          job.collection,
          job.id,
          receipt.recordRevision
        );
        sql.exec("UPDATE live_backup SET body=? WHERE seq=?", canonical(finalBody), job.seq);
      } else {
        demand(
          !Array.isArray(finalBody.bundleMedia) || finalBody.bundleMedia.every((f) => typeof f.fileId === "string"),
          "Unarchived media cannot be marked Drive verified",
          412
        );
      }
      sql.exec("UPDATE live_backup SET state='verified',drive_revision=?,claim='',claim_until=0,due=?,verified_at=? WHERE seq=?", b.driveRevision, Number.MAX_SAFE_INTEGER, now, job.seq);
      sql.exec("UPDATE live_records SET drive_revision=? WHERE collection=? AND id=?", b.driveRevision, job.collection, job.id);
      const retentionStart = Number.isSafeInteger(job.accepted_at) && job.accepted_at > 0 && job.accepted_at <= now ? job.accepted_at : now;
      const retainedUntil = Math.max(retentionStart + cloudflareVerifiedRetentionMs, now);
      const reference = {
        ...receipt,
        ...b.archiveFiles !== void 0 ? { record: finalBody } : {},
        backupState: "verified",
        source: "cloudflare",
        driveRevision: b.driveRevision,
        payloadHash: payloadHash(finalBody),
        reconcileRequired: true,
        retainedUntil
      };
      sql.exec("UPDATE live_events SET receipt=? WHERE seq=?", JSON.stringify(reference), job.seq);
      if (b.archiveFiles !== void 0) {
        sql.exec(
          "UPDATE live_operations SET receipt=json_set(receipt,'$.record',json(?)) WHERE json_extract(receipt,'$.recordRevision')=?",
          canonical(finalBody),
          String(receipt.recordRevision)
        );
      }
      sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.backupState','verified','$.driveRevision',?,'$.payloadHash',?,'$.retainedUntil',?,'$.reconcileRequired',json('true')) WHERE json_extract(receipt,'$.recordRevision')=?", String(b.driveRevision), String(reference.payloadHash), retainedUntil, String(receipt.recordRevision));
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

// src/live-rollout.ts
function liveSchoolEnabled(env, school) {
  if (!schoolPattern.test(school)) return false;
  const parts = [env.LIVE_SYNC_SCHOOLS, env.LIVE_SYNC_SCHOOLS_2, env.LIVE_SYNC_SCHOOLS_3, env.LIVE_SYNC_SCHOOLS_4];
  if (parts.some((part) => part && part.length > 5120)) return false;
  const schools = parts.flatMap((part) => (part || "").split(",").map((s) => s.trim()).filter(Boolean));
  if (env.LIVE_SYNC_TEST_SCHOOL_ID) schools.push(env.LIVE_SYNC_TEST_SCHOOL_ID);
  if (schools.length > 401 || schools.some((s) => !schoolPattern.test(s)) || new Set(schools).size > 400) return false;
  return schools.includes(school);
}
__name(liveSchoolEnabled, "liveSchoolEnabled");

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
      ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS r2_verification_pending (school TEXT NOT NULL,lane TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(school,lane,id))");
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
  // One account-wide Durable Object coordinates all TEST bucket reservations.
  // These are internal Durable Object RPC methods, never public HTTP routes.
  async stageR2Object(school, lane, id, offset, bytes) {
    demand(!this.meta("identity"), "R2 budget actor cannot be a school data lane", 403);
    demand(!this.meta("r2BudgetActor") || this.meta("r2BudgetActor") === "v1", "R2 budget identity rejected", 403);
    this.setMeta("r2BudgetActor", "v1");
    return stageR2(this.ctx.storage, this.env.R2_STAGE, school, lane, id, offset, bytes);
  }
  async r2OriginalAccepted(school, lane, id) {
    demand(!this.meta("identity"), "R2 budget actor is unavailable", 403);
    this.setMeta("r2BudgetActor", "v1");
    return acceptR2Original(this.ctx.storage, school, lane, id);
  }
  async r2OriginalVerified(school, lane, id) {
    demand(!this.meta("identity"), "R2 budget actor is unavailable", 403);
    this.setMeta("r2BudgetActor", "v1");
    const result = await markR2Verified(this.ctx.storage, school, lane, id);
    if (result.nextCleanupAt !== null) await this.wake(result.nextCleanupAt);
    return result;
  }
  async r2CapacityStatus() {
    demand(!this.meta("identity"), "R2 budget actor is unavailable", 403);
    this.setMeta("r2BudgetActor", "v1");
    return r2BudgetStatus(this.ctx.storage);
  }
  async queueR2Verification(school, lane, id) {
    this.ctx.storage.sql.exec("INSERT OR IGNORE INTO r2_verification_pending VALUES(?,?,?)", school, lane, id);
    await this.wake(Date.now() + 6e4);
    await this.flushR2Verifications();
  }
  async flushR2Verifications() {
    const rows = this.ctx.storage.sql.exec(
      "SELECT * FROM r2_verification_pending LIMIT 25"
    ).toArray();
    for (const row of rows) {
      try {
        await this.env.LANES.getByName("saarthi-account-r2-staging-budget-v1").r2OriginalVerified(row.school, row.lane, row.id);
        this.ctx.storage.sql.exec("DELETE FROM r2_verification_pending WHERE school=? AND lane=? AND id=?", row.school, row.lane, row.id);
      } catch {
        break;
      }
    }
  }
  async command(school, lane, b) {
    demand(schoolPattern.test(school) && (/^(?:attendance-[a-f0-9]{2}|notices|delivery|live)$/.test(lane) || spoolLane(lane)));
    const identity = school + "/" + lane;
    demand(!this.meta("identity") || this.meta("identity") === identity, "School scope rejected", 403);
    this.setMeta("identity", identity);
    if (lane === "live") {
      demand(liveSchoolEnabled(this.env, school), "Live authority is not enabled for this school", 412);
      initLive(this.ctx.storage);
      const staged = r2StagingForSchool(this.env, school);
      const budget2 = /* @__PURE__ */ __name(() => this.env.LANES.getByName("saarthi-account-r2-staging-budget-v1"), "budget");
      if (staged && b.command === "commit") {
        demand(this.env.R2_STAGE !== void 0, "Private R2 bucket binding required", 503);
        demand(typeof b.operationId === "string" && /^[A-Za-z0-9_-]{16,100}$/.test(b.operationId) && typeof b.collection === "string" && typeof b.id === "string" && b.id.length > 0 && ["write", "delete", "patch"].includes(String(b.operation)) && typeof b.expectedRevision === "string", "Invalid original live R2 admission", 400);
        const active = this.ctx.storage.sql.exec(
          "SELECT state FROM live_collections WHERE collection=?",
          String(b.collection)
        ).toArray()[0];
        demand(active?.state === "active", "Verified live collection not active", 412);
        const prior = this.ctx.storage.sql.exec(
          "SELECT state FROM live_backup WHERE operation_id=? AND collection=? AND id=? ORDER BY seq DESC LIMIT 1",
          String(b.operationId),
          String(b.collection),
          String(b.id)
        ).toArray()[0];
        if (prior?.state !== "verified") {
          const encoded = new TextEncoder().encode(JSON.stringify(b));
          demand(encoded.byteLength > 0 && encoded.byteLength <= 256e3, "Original live record too large", 413);
          await budget2().stageR2Object(
            school,
            "live",
            await digest(JSON.stringify([school, "live", b.operationId])),
            0,
            encoded.buffer
          );
        }
      }
      const verifiedLive = b.command === "backupFinish" && b.verified === true && Number.isSafeInteger(b.sequence) && Number(b.sequence) > 0;
      const verifiedOp = verifiedLive ? this.ctx.storage.sql.exec(
        "SELECT operation_id FROM live_backup WHERE seq=? AND state='processing'",
        Number(b.sequence)
      ).toArray()[0]?.operation_id : null;
      if (b.command === "bundlePrepare") {
        demand(/^[A-Za-z0-9_-]{16,100}$/.test(String(b.bundleId || "")) && Array.isArray(b.media) && b.media.length >= 1 && b.media.length <= 2 && (b.requireDrive === void 0 || typeof b.requireDrive === "boolean"), "Invalid media bundle manifest");
        const media = b.media, seen = /* @__PURE__ */ new Set(), ids = /* @__PURE__ */ new Set(), proofs = [];
        const primary = String(media[0]?.kind || "");
        demand(
          ["idCard", "receipt", "marksheet"].includes(primary) && (primary === "idCard" || media.length === 1),
          "Only an ID with optional photo, or one original financial PDF is allowed",
          412
        );
        for (const item of media) {
          demand(
            item && typeof item === "object" && !Array.isArray(item) && Object.keys(item).every((k) => ["kind", "id", "uploadKey", "sha256", "sizeBytes", "mime"].includes(k)),
            "Invalid media proof request"
          );
          const kind = String(item.kind || ""), id2 = String(item.id || "");
          demand((kind === primary || primary === "idCard" && kind === "photo") && !seen.has(kind) && operationPattern.test(id2) && typeof item.uploadKey === "string" && /^[A-Za-z0-9_-]{1,150}$/.test(item.uploadKey) && id2 === await digest(JSON.stringify([school, item.uploadKey])), "Untrusted staged file identity", 409);
          const limit = kind === "idCard" ? 85 * 1024 : kind === "receipt" ? 30 * 1024 : kind === "marksheet" ? 150 * 1024 : 40 * 1024;
          const allowed = (kind === "photo" ? ["image/jpeg", "image/png", "image/webp"].includes(String(item.mime)) : item.mime === "application/pdf") && Number.isSafeInteger(item.sizeBytes) && Number(item.sizeBytes) > 0 && Number(item.sizeBytes) <= limit;
          demand(allowed && typeof item.sha256 === "string" && operationPattern.test(item.sha256) && !ids.has(id2), "Media size, kind or digest rejected", 413);
          seen.add(kind);
          ids.add(id2);
          const proof = await this.env.LANES.getByName(school + "/file-" + id2).command(school, "file-" + id2, { command: "bundleProof", id: id2, requireDrive: b.requireDrive === true });
          demand(
            proof.staged === true && proof.version === 1 && proof.schoolId === school && proof.id === id2 && proof.uploadKey === item.uploadKey && proof.sha256 === item.sha256 && proof.sizeBytes === item.sizeBytes && proof.mime === item.mime && (b.requireDrive !== true || proof.driveVerified === true && typeof proof.fileId === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(proof.fileId)),
            "Staged file bytes or Drive receipt do not match bundle manifest",
            409
          );
          proofs.push({
            kind,
            id: id2,
            sha256: proof.sha256,
            sizeBytes: proof.sizeBytes,
            mime: proof.mime,
            driveVerified: proof.driveVerified === true,
            ...proof.driveVerified === true ? { fileId: proof.fileId } : {}
          });
        }
        demand(seen.has(primary), "Original PDF proof is required for atomic bundle", 412);
        const manifestHash = await digest(canonical({ schoolId: school, bundleId: b.bundleId, media }));
        return {
          bundleProtocol: 1,
          schoolId: school,
          bundleId: b.bundleId,
          mediaReady: true,
          archiveReady: proofs.every((p) => p.driveVerified === true),
          manifestHash,
          proofs
        };
      }
      if (b.command === "bundleArchive") {
        const manifest = liveCommand(
          this.ctx.storage,
          school,
          { command: "bundleArchiveManifest", bundleId: b.bundleId }
        );
        const archived = [];
        for (const item of manifest.files) {
          const id2 = String(item.id);
          const proof = await this.env.LANES.getByName(school + "/file-" + id2).command(school, "file-" + id2, { command: "bundleProof", id: id2, requireDrive: true });
          demand(
            proof.schoolId === school && proof.version === 1 && typeof proof.staged === "boolean" && proof.driveVerified === true && proof.id === item.id && proof.sha256 === item.sha256 && proof.sizeBytes === item.sizeBytes && proof.mime === item.mime && typeof proof.fileId === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(proof.fileId),
            "Archive has no matching immutable Drive file receipt",
            412
          );
          archived.push({ ...item, fileId: proof.fileId });
        }
        return {
          bundleProtocol: 1,
          schoolId: school,
          bundleId: b.bundleId,
          mediaManifestHash: manifest.mediaManifestHash,
          archiveReady: true,
          files: archived
        };
      }
      let verifiedMedia;
      if (b.command === "bundlePublish") {
        demand(
          Object.keys(b).every((k) => [
            "command",
            "schoolId",
            "lane",
            "bundleId",
            "operations",
            "media",
            "mediaManifestHash"
          ].includes(k)) && typeof b.mediaManifestHash === "string" && /^[a-f0-9]{64}$/.test(b.mediaManifestHash),
          "Invalid atomic person bundle request"
        );
        const prior = liveCommand(this.ctx.storage, school, {
          command: "bundleReceipt",
          bundleId: b.bundleId,
          operations: b.operations,
          media: b.media,
          mediaManifestHash: b.mediaManifestHash
        });
        if (prior.found === true) {
          if (staged) await budget2().r2OriginalAccepted(school, "live", await digest(JSON.stringify([school, "bundle", b.bundleId])));
          return prior.receipt;
        }
        verifiedMedia = await this.command(school, "live", {
          command: "bundlePrepare",
          bundleId: b.bundleId,
          media: b.media,
          requireDrive: false
        });
        demand(verifiedMedia.mediaReady === true && verifiedMedia.manifestHash === b.mediaManifestHash, "Staged media manifest changed", 409);
        b = { ...b, command: "bundleCommit" };
      }
      if (staged && b.command === "bundleCommit") {
        demand(
          typeof b.bundleId === "string" && /^[A-Za-z0-9_-]{16,100}$/.test(b.bundleId) && Array.isArray(b.operations) && b.operations.length >= 2 && b.operations.length <= 5,
          "Invalid original R2 bundle",
          400
        );
        const encoded = new TextEncoder().encode(canonical({
          bundleId: b.bundleId,
          operations: b.operations,
          media: b.media ?? [],
          mediaManifestHash: b.mediaManifestHash ?? null
        }));
        demand(encoded.byteLength <= 3e5, "Original R2 bundle too large", 413);
        await budget2().stageR2Object(
          school,
          "live",
          await digest(JSON.stringify([school, "bundle", b.bundleId])),
          0,
          encoded.buffer
        );
      }
      if (b.command === "commit" || b.command === "bundleCommit" || b.command === "backupFinish") await this.wake(Date.now() + 250);
      const result = liveCommand(this.ctx.storage, school, b, Date.now(), false, verifiedMedia);
      if (staged && b.command === "commit") await budget2().r2OriginalAccepted(
        school,
        "live",
        await digest(JSON.stringify([school, "live", b.operationId]))
      );
      if (staged && b.command === "bundleCommit") await budget2().r2OriginalAccepted(
        school,
        "live",
        await digest(JSON.stringify([school, "bundle", b.bundleId]))
      );
      if (staged && verifiedLive && verifiedOp && result.accepted === true) {
        await this.queueR2Verification(
          school,
          "live",
          await digest(JSON.stringify([school, "live", verifiedOp]))
        );
        const event = this.ctx.storage.sql.exec(
          "SELECT bundle_id FROM live_events WHERE seq=?",
          Number(b.sequence)
        ).toArray()[0];
        if (event?.bundle_id) {
          const rows = this.ctx.storage.sql.exec(
            "SELECT b.state FROM live_backup b JOIN live_events e ON e.seq=b.seq WHERE e.bundle_id=?",
            event.bundle_id
          ).toArray();
          if (rows.length >= 2 && rows.every((row) => row.state === "verified"))
            await this.queueR2Verification(
              school,
              "live",
              await digest(JSON.stringify([school, "bundle", event.bundle_id]))
            );
        }
      }
      if (b.command === "backupFinish" && b.verified === true && result.accepted === true) {
        const head = liveCommand(this.ctx.storage, school, { command: "head" });
        if (Number(head.cursor) > 1e4) liveCommand(this.ctx.storage, school, { command: "compact", before: Number(head.cursor) - 1e4 });
      }
      if (b.command === "commit" || b.command === "bundleCommit") for (const socket of this.ctx.getWebSockets()) {
        const grant = socket.deserializeAttachment();
        try {
          if (grant.schoolId !== school || grant.expiresAt <= Date.now()) socket.close(1008, "Refresh school authorization");
          else socket.send(JSON.stringify({ liveProtocol: 1, schoolId: school, cursor: result.cursor }));
        } catch {
        }
      }
      return result;
    }
    if (spoolLane(lane)) {
      const cmd = String(b.command || ""), id2 = String(b.id || "");
      const staged = r2StagingForSchool(this.env, school);
      const budget2 = /* @__PURE__ */ __name(() => this.env.LANES.getByName("saarthi-account-r2-staging-budget-v1"), "budget");
      if (staged) {
        demand(this.env.R2_STAGE !== void 0, "Private R2 bucket binding required", 503);
        if (lane === "records" && cmd === "enqueue") {
          const request = b.request;
          demand(request && typeof request === "object" && ["managed_records", "managed_records_batch"].includes(String(request.action)) && /^[a-f0-9]{64}$/.test(id2), "Invalid original record R2 admission", 400);
          const ops = request.action === "managed_records_batch" ? request.operations : [request];
          demand(
            Array.isArray(ops) && ops.length > 0 && ops.length <= 10 && ops.every((op) => op && op.syncProtocol === 2 && ["write", "delete"].includes(String(op.operation)) && typeof op.id === "string" && typeof op.collection === "string" && /^[A-Za-z0-9_-]{16,100}$/.test(String(op.operationId)) && (op.operation !== "write" || op.data?.schoolId === school)),
            "Invalid original school record",
            400
          );
          const identity2 = request.action === "managed_records_batch" ? ops.map((op) => [op.collection, op.id, op.operationId]) : [request.collection, request.id, request.operationId];
          demand(await digest(JSON.stringify([school, request.action, identity2])) === id2, "Original R2 identity mismatch", 409);
          const encoded = new TextEncoder().encode(JSON.stringify(request));
          demand(encoded.byteLength > 0 && encoded.byteLength <= 3e5, "Original record too large", 413);
          await budget2().stageR2Object(school, lane, id2, 0, encoded.buffer);
        }
        if (lane.startsWith("file-") && (cmd === "putSmall" || cmd === "part")) {
          demand(/^file-[a-f0-9]{64}$/.test(lane) && lane === "file-" + id2 && typeof b.base64 === "string" && b.base64.length > 0 && b.base64.length <= 699052 && /^[A-Za-z0-9+/]*={0,2}$/.test(b.base64), "Invalid original file R2 chunk", 400);
          const bytes = Buffer4.from(b.base64, "base64");
          demand(
            bytes.length > 0 && bytes.length <= 512 * 1024 && bytes.toString("base64") === b.base64,
            "Invalid original file bytes",
            400
          );
          const offset = cmd === "putSmall" ? 0 : Number(b.offset);
          demand(Number.isSafeInteger(offset) && offset >= 0, "Invalid original file offset", 400);
          const hash2 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((x) => x.toString(16).padStart(2, "0")).join("");
          if (cmd === "putSmall") {
            const manifest = b.manifest;
            demand(
              manifest && typeof manifest.uploadKey === "string" && id2 === await digest(JSON.stringify([school, manifest.uploadKey])) && hash2 === manifest.sha256 && bytes.length === manifest.sizeBytes && bytes.length <= 256 * 1024,
              "Small original file digest mismatch",
              409
            );
          } else {
            const original = this.ctx.storage.sql.exec(
              "SELECT payload,state FROM edge_ops WHERE id=?",
              id2
            ).toArray()[0];
            demand(original && original.state === "receiving" && hash2 === b.chunkSha256, "Original file part rejected", 409);
            const manifest = JSON.parse(original.payload);
            demand(
              offset + bytes.length <= Number(manifest.sizeBytes),
              "Original file chunk exceeds manifest",
              409
            );
          }
          await budget2().stageR2Object(
            school,
            lane,
            id2,
            offset,
            bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
          );
        }
      }
      const result = await spoolCommand(this.ctx.storage, school, lane, b, (at) => this.wake(at));
      if (staged && (lane === "records" && cmd === "enqueue" || lane.startsWith("file-") && ["part", "putSmall", "status", "bundleProof"].includes(cmd) && this.ctx.storage.sql.exec("SELECT state FROM edge_ops WHERE id=?", id2).toArray()[0]?.state !== "receiving"))
        await budget2().r2OriginalAccepted(school, lane, id2);
      if (staged && cmd === "finish" && result === true && b.values?.state === "completed") {
        const values = b.values, ack = values.result;
        const allAccepted = lane === "records" && ack?.success === true && ack.schoolId === school && (ack.recordWriteBatchVersion !== 1 || Array.isArray(ack.acknowledgements) && ack.acknowledgements.every((x) => x.success === true));
        const fileAccepted = lane.startsWith("file-") && ack?.success === true && ack.schoolId === school && ack.committed === true && typeof ack.fileId === "string";
        if (allAccepted || fileAccepted) await this.queueR2Verification(school, lane, id2);
      }
      return result;
    }
    const action = String(b.command || ""), id = String(b.id || "");
    const stageOther = r2StagingForSchool(this.env, school) && (lane === "notices" && action === "write" || lane.startsWith("attendance-") && action === "create");
    const budget = /* @__PURE__ */ __name(() => this.env.LANES.getByName("saarthi-account-r2-staging-budget-v1"), "budget");
    if (stageOther) {
      demand(this.env.R2_STAGE !== void 0, "Private R2 bucket binding required", 503);
      if (lane === "notices") {
        const request = b.request;
        demand(
          !this.meta("retired") && !!this.meta("initialized") && request && request.action === "managed_records" && request.collection === "school_notices" && ["write", "delete"].includes(String(request.operation)) && request.syncProtocol === 2 && typeof request.id === "string" && request.id.length > 0 && request.id.length <= 200 && !request.id.includes("/") && typeof request.operationId === "string" && /^[A-Za-z0-9_-]{16,100}$/.test(request.operationId) && typeof request.expectedRecordRevision === "string" && (request.operation === "delete" || request.data?.schoolId === school),
          "Invalid original notice R2 admission",
          400
        );
        const key = await digest(JSON.stringify([school, request.operationId]));
        const prior = this.job(key);
        if (prior) {
          const saved = JSON.parse(prior.payload);
          demand(
            saved.fingerprint === await digest(JSON.stringify(request)),
            "Sync operation ID conflict",
            409
          );
        }
        const encoded = new TextEncoder().encode(JSON.stringify(request));
        demand(encoded.byteLength > 0 && encoded.byteLength <= 3e5, "Original notice too large", 413);
        if (prior?.state !== "completed" || !(prior.response && typeof JSON.parse(prior.response)?.driveRevision === "string"))
          await budget().stageR2Object(school, lane, key, 0, encoded.buffer);
      } else {
        const row = b.row;
        demand(
          row && row.schoolId === school && row.operationId === id && /^[a-f0-9]{64}$/.test(id) && id.slice(0, 2) === lane.slice(-2),
          "Invalid original attendance R2 admission",
          400
        );
        const prior = this.job(id);
        if (prior) {
          const original = JSON.parse(prior.payload);
          demand(
            prior.kind === "attendance" && original.schoolId === school && original.operationId === id && original.day === row.day && original.mode === row.mode,
            "Attendance original identity conflict",
            409
          );
        } else {
          const original = JSON.stringify(row), size = new TextEncoder().encode(original).byteLength;
          demand(size > 0 && size <= 3e5, "Original attendance request too large", 413);
          this.ctx.storage.sql.exec(
            "INSERT INTO jobs(id,kind,payload,state,due,created) VALUES(?,'attendance',?,'staging',?,?)",
            id,
            original,
            Number.MAX_SAFE_INTEGER,
            Number(row.createdAt)
          );
        }
        const staged = this.job(id);
        if (staged?.state === "staging") {
          const encoded = new TextEncoder().encode(staged.payload);
          await budget().stageR2Object(school, lane, id, 0, encoded.buffer);
        }
      }
    }
    if (action === "retireNoticeCache") {
      demand(lane === "notices" && liveSchoolEnabled(this.env, school), "Isolated live notice owner required", 412);
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
      if (this.env.R2_STAGING_ENABLED === "true" && values.state === "completed") {
        const verifiedAttendance = lane.startsWith("attendance-") && values.attendancePayloadPurged === true && values.attendanceOwnerReceipt?.driveVerified === true;
        const revision = String(values.driveRevision || "");
        const verifiedNotice = lane === "notices" && revision.length > 0 && !/^(live-|cf-)/.test(revision) && typeof values.completedAt === "number" && Number.isSafeInteger(values.completedAt);
        if (verifiedAttendance || verifiedNotice)
          await this.queueR2Verification(school, lane, id);
      }
      return true;
    }
    if (action === "create") {
      demand(lane.startsWith("attendance-") && operationPattern.test(id));
      const row = b.row;
      demand(row && row.schoolId === school && row.operationId === id && id.slice(0, 2) === lane.slice(-2));
      const prior = this.job(id);
      if (prior) {
        const firstAccepted = stageOther && prior.state === "staging";
        if (firstAccepted) this.ctx.storage.sql.exec("UPDATE jobs SET state='pending',due=? WHERE id=? AND state='staging'", Date.now(), id);
        if (stageOther) await budget().r2OriginalAccepted(school, lane, id);
        if (firstAccepted) await this.wake(Date.now() + 250);
        return firstAccepted;
      }
      this.ctx.storage.sql.exec("INSERT INTO jobs(id,kind,payload,state,due,created) VALUES(?,'attendance',?,'pending',?,?)", id, JSON.stringify(row), Date.now(), Number(row.createdAt));
      if (stageOther) await budget().r2OriginalAccepted(school, lane, id);
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
        if (stageOther) await budget().r2OriginalAccepted(school, lane, key);
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
      if (stageOther) await budget().r2OriginalAccepted(school, lane, key);
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
    demand(liveSchoolEnabled(this.env, grant.schoolId) && grant.expiresAt > Date.now(), "Live stream unavailable", 412);
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
    try {
      await this.flushR2Verifications();
      if (this.meta("r2BudgetActor") === "v1") {
        try {
          const result = await sweepR2Verified(this.ctx.storage, this.env.R2_STAGE);
          if (result.nextCleanupAt !== null) await this.wake(result.more ? Date.now() + 1e3 : result.nextCleanupAt);
        } catch {
          await this.wake(Date.now() + 6e4);
        }
        return;
      }
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
        delay = brokerRetryDelay(response.status, response.headers.get("retry-after"), Date.now());
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
    } finally {
      if (this.ctx.storage.sql.exec("SELECT count(*) AS n FROM r2_verification_pending").toArray()[0].n > 0)
        await this.wake(Date.now() + 6e4);
    }
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
        demand(liveSchoolEnabled(env, grant.schoolId), "Live authority is not enabled", 412);
        return env.LANES.getByName(grant.schoolId + "/live").fetch(request);
      }
      if (request.method === "POST" && url.pathname === "/mobile") return Response.json(await mobileRequest(request, env), { headers });
      demand(request.method === "POST" && url.pathname === "/internal", "Not found", 404);
      const raw = await boundedBody(request, 8e5);
      demand(await authenticated(env.EDGE_KEY, raw, request.headers), "Sync authorization rejected", 401);
      const body = JSON.parse(raw), school = String(body.schoolId || ""), lane = String(body.lane || "");
      demand(schoolPattern.test(school) && (/^(?:attendance-[a-f0-9]{2}|notices|delivery|live)$/.test(lane) || spoolLane(lane)));
      demand(raw.length <= (/^file-[a-f0-9]{64}$/.test(lane) ? 8e5 : 4e5), "Request too large", 413);
      try {
        const value = await env.LANES.getByName(school + "/" + lane).command(school, lane, body);
        return Response.json({ success: true, schoolId: school, value }, { headers });
      } catch (error) {
        const e = error, notice = body.request;
        if (lane === "notices" && body.command === "write" && notice?.collection === "school_notices" && notice.operation === "write" && e.status === 409 && ["Record revision conflict", "Sync operation ID conflict"].includes(e.message))
          return Response.json({ success: false, schoolId: school, message: e.message }, { status: 409, headers });
        throw error;
      }
    } catch (error) {
      const e = error;
      const status = e.status || 503;
      if (status === 507) return Response.json({
        success: false,
        code: "R2_CAPACITY_EXCEEDED",
        message: "Cloudflare 8 GB school data capacity reached; local work retained."
      }, { status: 507, headers });
      return Response.json({ success: false, message: status < 500 ? e.message : "Cloudflare sync unavailable; pending work retained." }, { status, headers });
    }
  }
};
export {
  SyncLane,
  worker_default as default
};
//# sourceMappingURL=worker.js.map
