"""Real workload execution and separate persisted-data verification."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import threading
import time
import urllib.parse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import datetime
from pathlib import Path

from .dataset import BASE_SIZE, Cancelled, StudentBase
from .jobs import Job, percentile
from .transport import Blocked, RemoteError, Transport, validate_url

SCENARIOS = {
    "attendance": {"label": "Student attendance", "target": "School backend", "unit": "students"},
    "student_add": {"label": "Student add", "target": "School backend + Firestore", "unit": "students"},
    "mobile_login": {"label": "Student login", "target": "School backend", "unit": "students"},
    "mobile_dashboard": {"label": "Student dashboard", "target": "School backend", "unit": "students"},
    "fees": {"label": "Fees collection", "target": "School Sheets / Drive", "unit": "payments"},
    "web_http": {"label": "Website traffic", "target": "Website HTTP", "unit": "requests"},
    "web_ui": {"label": "Website screen test", "target": "Browser", "unit": "sessions"},
    "windows_ui": {"label": "Windows screen test", "target": "Windows process", "unit": "steps"},
    "android_ui": {"label": "Android screen test", "target": "Android device", "unit": "steps"},
    "volume_local": {"label": "Data volume · local", "target": "Toolkit storage only", "unit": "GB"},
    "volume_drive": {"label": "Data volume · Drive", "target": "Test school Drive", "unit": "GB"},
    "base_search": {"label": "Student-base search", "target": "Toolkit SQLite only", "unit": "queries"},
}


def receipt_pdf(number):
    text = f"BT /F1 14 Tf 40 740 Td (TEST RECEIPT {number}) Tj ET".encode()
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
               b"<< /Length " + str(len(text)).encode() + b" >>\nstream\n" + text + b"\nendstream"]
    output, offsets = bytearray(b"%PDF-1.4\n"), [0]
    for n, obj in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(str(n).encode() + b" 0 obj\n" + obj + b"\nendobj\n")
    xref = len(output)
    output.extend(b"xref\n0 6\n0000000000 65535 f \n")
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode())
    output.extend(f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(output)


class Engine:
    def __init__(self, directory: Path, allow_loopback=False):
        self.directory = Path(directory)
        self.dataset = StudentBase(self.directory / "base")
        self.reports = self.directory / "reports"
        self.reports.mkdir(parents=True, exist_ok=True)
        self.jobs = {}
        self.lock = threading.RLock()
        self.school = None
        self.allow_loopback = allow_loopback
        self.native_config = {"web": {}, "windows": {}, "android": {}}

    def start(self, scenario, options):
        if scenario != "base_generate" and scenario not in SCENARIOS:
            raise ValueError("Unknown test scenario")
        config = {"count": int(options.get("count", BASE_SIZE if scenario == "base_generate" else 100)),
                  "start": int(options.get("start", 1)), "concurrency": int(options.get("concurrency", 10)),
                  "rate": float(options.get("rate", 5)), "timeout": int(options.get("timeout", 30)),
                  "max_p95_ms": float(options.get("max_p95_ms", 5000)),
                  "gb": float(options.get("gb", .01)), "auto_seed": bool(options.get("auto_seed", True))}
        if not 1 <= config["count"] <= BASE_SIZE or not 1 <= config["start"] <= BASE_SIZE:
            raise ValueError("Choose 1–100,000 students/requests")
        if not 1 <= config["concurrency"] <= 512:
            raise ValueError("This local runner supports 1–512 workers. Quantity can still be 100,000")
        if not 0 <= config["rate"] <= 10000 or not 1 <= config["timeout"] <= 180:
            raise ValueError("Invalid rate or timeout")
        if not 0 < config["gb"] <= 10 or int(config["gb"] * 1_000_000_000) < 1 or config["max_p95_ms"] <= 0:
            raise ValueError("Choose up to 10 GB and a positive P95 limit")
        if scenario not in ("web_http", "web_ui", "windows_ui", "android_ui", "volume_local", "volume_drive", "base_generate"):
            if config["start"] + config["count"] - 1 > BASE_SIZE:
                raise ValueError("Student selection extends beyond the 100,000-student base")
        # Do not persist credentials, arbitrary commands or native-scenario input in a report.
        with self.lock:
            if any(j.state == "RUNNING" for j in self.jobs.values()):
                raise ValueError("Another task is running; stop it or wait for its result")
            job = Job(scenario, config, self.reports)
            self.jobs[job.id] = job
            school = self.school
            native = json.loads(json.dumps(self.native_config))
        threading.Thread(target=self._run, args=(job, school, native), daemon=True).start()
        return job.snapshot()

    def snapshots(self):
        with self.lock:
            live = {j.id: j.snapshot() for j in self.jobs.values()}
        for path in sorted(self.reports.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)[:50]:
            if path.stem not in live:
                try:
                    live[path.stem] = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
        return sorted(live.values(), key=lambda j: j["created_at"], reverse=True)[:50]

    def cancel(self, job_id):
        with self.lock:
            job = self.jobs.get(job_id)
            if not job or job.state != "RUNNING":
                raise ValueError("No running task with that ID")
            job.stop.set()
            job.update(phase="Stopping; in-flight requests may still finish")

    @staticmethod
    def clean_error(error, school=None):
        message = str(error)[:500]
        if school:
            for secret in (school.id_token, school.refresh_token, school.api_key):
                if secret:
                    message = message.replace(secret, "[redacted]")
        message = re.sub(r"[A-Za-z0-9_-]{40,}(?:\.[A-Za-z0-9_-]+){0,2}", "[redacted]", message)
        return message[:300]

    def _run(self, job, school, native):
        try:
            if job.scenario == "base_generate":
                job.source = "Toolkit student base · synthetic identities"
                result = self.dataset.generate(lambda n: job.update(completed=n), job.stop)
                job.succeeded = result["count"]
                job.check("Persisted unique student identities", BASE_SIZE, result["count"], result["ready"])
                job.finish(job.verdict())
                return
            if job.scenario.startswith("volume_"):
                job.config["count"] = (int(job.config["gb"] * 1_000_000_000) + 999_999) // 1_000_000
                if job.scenario == "volume_drive" and not school:
                    raise Blocked("Connect the isolated test school before writing to its test Drive")
                self._volume(job, school)
                job.finish(job.verdict())
                return
            if job.scenario in ("web_ui", "windows_ui", "android_ui"):
                from .native import run_native
                if job.scenario != "web_ui":
                    platform = "windows" if job.scenario == "windows_ui" else "android"
                    job.config["count"] = len(native[platform].get("steps", []))
                    if job.config["concurrency"] != 1:
                        raise Blocked("Device UI scenarios use one device/process; set concurrency to 1")
                run_native(job, native, self.directory)
                job.finish(job.verdict())
                return
            if job.scenario == "web_http":
                self._website(job, native["web"])
                job.finish(job.verdict())
                return
            if not self.dataset.stats()["ready"]:
                raise Blocked("Generate or resume the 100,000-student base before running student scenarios")
            rows = self.dataset.select(job.config["count"], job.config["start"])
            if job.scenario == "base_search":
                job.source = "Toolkit SQLite student base; not the Windows app"
                def search(row):
                    with self.dataset.connect() as db:
                        found = db.execute("SELECT person_id, dob FROM students WHERE name=?", (row["name"],)).fetchone()
                    if not found or tuple(found) != (row["person_id"], row["dob"]):
                        raise RemoteError("Search returned the wrong student")
                self._parallel(job, rows, search)
                job.check("Correct student returned", len(rows), job.succeeded, job.succeeded == len(rows))
                self._sla(job)
                job.finish(job.verdict())
                return
            if not school or not school.info:
                raise Blocked("Connect an isolated test-school Firebase and the toolkit Apps Script first")
            job.source = f"{school.project_id} · school backend; not device UI"
            school.http.timeout = job.config["timeout"]
            school.info = school.call("toolkit_info", {}, admin=True)
            if school.info.get("testOnly") is not True:
                raise Blocked("Test mode is not enabled on this backend")
            if job.scenario in ("attendance", "mobile_login", "mobile_dashboard"):
                if not school.info.get("licenseAllowed"):
                    raise Blocked("The test school needs a valid trial/licence; the toolkit does not bypass it")
                if job.scenario == "attendance" and not school.info.get("schoolOpen"):
                    raise Blocked("The test school's calendar is closed today")
                if job.config["auto_seed"]:
                    self._seed(job, school, rows)
            if job.stop.is_set():
                raise Cancelled("Stopped before the traffic phase")
            measured_rows = rows
            if job.scenario == "student_add":
                # Each add run uses a new cohort so repeating an experiment is possible.
                roll_offset = int(job.id[:6], 16) * 10001
                measured_rows = [{**r, "person_id": r["person_id"] + "_" + job.id,
                                  "roll_no": str(roll_offset + int(r["roll_no"]))} for r in rows]
            before = school.http.counters()
            self._parallel(job, measured_rows, lambda row: self._operation(job, school, row))
            after = school.http.counters()
            job.metrics.update(http_requests=after["requests"] - before["requests"],
                               response_bytes=after["bytes"] - before["bytes"],
                               latency_scope="Complete student journey, including login when uncached")
            if job.stop.is_set():
                job.finish("CANCELLED", "Cancelled; writes already accepted by the server remain")
                return
            job.update(phase="Verifying persisted records")
            verification_started = time.perf_counter()
            try:
                self._verify(job, school, measured_rows)
            except Cancelled:
                raise
            except Exception as error:
                job.errors.append({"message": "Verification unavailable: " + self.clean_error(error, school)})
                job.finish("FAIL" if job.failed else "INCONCLUSIVE", "Could not verify all persisted records")
                return
            job.metrics["verification_seconds"] = time.perf_counter() - verification_started
            self._sla(job)
            job.finish(job.verdict())
        except Cancelled as error:
            job.errors.append({"message": str(error)})
            job.finish("CANCELLED", "Stopped")
        except Blocked as error:
            job.errors.append({"message": self.clean_error(error, school)})
            job.finish("BLOCKED", "Setup required")
        except Exception as error:
            job.errors.append({"message": self.clean_error(error, school)})
            job.finish("CANCELLED" if job.stop.is_set() else "FAIL", "Execution failed")

    def _seed(self, job, school, rows):
        job.update(phase="Preparing matching test students; not included in request latency")
        started = time.perf_counter()
        for at in range(0, len(rows), 100):
            if job.stop.is_set():
                raise Cancelled("Stopped during test-school preparation")
            batch = rows[at:at + 100]
            reply = school.call("toolkit_seed", {"students": [{"personId": r["person_id"],
                "profile": self.dataset.profile(r)} for r in batch]}, admin=True)
            if reply.get("verified") != len(batch):
                raise RemoteError("Test-school preparation did not verify all supplied student records")
            job.metrics["prepared_students"] = at + len(batch)
        job.metrics["preparation_seconds"] = time.perf_counter() - started

    def _parallel(self, job, rows, operation):
        job.update(phase="Running measured workload")
        started = time.perf_counter()
        iterator = iter(enumerate(rows))
        def perform(index, row):
            rate = job.config["rate"]
            delay = max(0, started + index / rate - time.perf_counter()) if rate else 0
            if job.stop.wait(delay) or job.stop.is_set():
                return
            with job.lock:
                job.active += 1
                job.peak_concurrency = max(job.peak_concurrency, job.active)
            tick = time.perf_counter()
            success, error = True, ""
            try:
                operation(row)
            except Exception as exc:
                success, error = False, self.clean_error(exc, self.school)
            finally:
                with job.lock:
                    job.active -= 1
            job.record(time.perf_counter() - tick, success, error, row.get("seq"))
        with ThreadPoolExecutor(max_workers=job.config["concurrency"], thread_name_prefix="lab-load") as pool:
            pending = set()
            for _ in range(job.config["concurrency"]):
                item = next(iterator, None)
                if item is None:
                    break
                pending.add(pool.submit(perform, *item))
            while pending:
                done, pending = wait(pending, return_when=FIRST_COMPLETED)
                for future in done:
                    future.result()
                    if not job.stop.is_set():
                        item = next(iterator, None)
                        if item is not None:
                            pending.add(pool.submit(perform, *item))
        seconds = time.perf_counter() - started
        job.metrics.update(traffic_seconds=seconds,
                           journeys_per_second=job.completed / seconds if seconds else None)
        job.check("Completed selected workload", len(rows), job.completed, job.completed == len(rows))
        job.check("Successful journeys", len(rows), job.succeeded, job.succeeded == len(rows))

    def _operation(self, job, school, row):
        scenario = job.scenario
        if scenario == "student_add":
            profile = self.dataset.profile(row)
            school.call("add_student", {"name": row["name"], "studentClass": row["class"],
                       "rollNo": row["roll_no"], "parentName": "TEST Guardian", "dateOfBirth": row["dob"]}, admin=True)
            school.save_profile(row, profile)
            return
        if scenario == "fees":
            receipt = "TK_" + job.id + "_" + str(row["seq"])
            school.call("save_fee_payment", {"receiptNo": receipt, "paymentId": receipt,
                "studentId": row["person_id"], "studentName": row["name"], "studentClass": row["class"],
                "rollNo": row["roll_no"], "month": datetime.now().strftime("%Y-%m"), "amount": 100,
                "paidAmount": 100, "totalPaid": 100, "expectedAmount": 100, "installmentAmount": 100,
                "balance": 0, "status": "PAID", "paymentMode": "TEST", "collectedBy": "TOOLKIT",
                "pdfBase64": base64.b64encode(receipt_pdf(receipt)).decode()}, admin=True)
            return
        token = school.login(row)
        if scenario == "mobile_login":
            school.call("mobile_session_verify", {"sessionToken": token})
        elif scenario == "mobile_dashboard":
            d = school.call("mobile_dashboard", {"sessionToken": token})
            if d.get("person", {}).get("mobileStableId") != row["person_id"]:
                raise RemoteError("Dashboard returned the wrong student's records")
        elif scenario == "attendance":
            loc = school.info.get("location", {})
            if "latitude" not in loc or "longitude" not in loc:
                raise RemoteError("Configure the test-school location before marking attendance")
            school.call("mobile_mark_attendance", {"sessionToken": token, "role": "student",
                "personId": row["person_id"], "linkToken": row["link_token"], "mode": "entry",
                "latitude": loc["latitude"], "longitude": loc["longitude"]})

    def _verify(self, job, school, rows):
        if job.scenario == "attendance":
            day = school.info.get("day")
            if not day:
                raise RemoteError("Backend did not supply its attendance date")
            ids = [hashlib.sha256(f"student/{r['person_id']}/{day}".encode()).hexdigest() for r in rows]
            actual = school.get_documents("attendance_records", ids)
            matched = sum(bool(actual.get(i, {}).get("checkIn")) and
                          actual.get(i, {}).get("personId") == r["person_id"] and
                          actual.get(i, {}).get("date") == day for i, r in zip(ids, rows))
            job.metrics.update(saved_records=matched, missing_records=len(rows) - matched,
                               verification_source="School Firestore :batchGet")
            job.check("Unique correct attendance records persisted", len(rows), matched, matched == len(rows))
            # Check the collection for duplicate logical identities rather than assuming hash keys guarantee it.
            audit = school.call("toolkit_audit_attendance", {"personIds": [r["person_id"] for r in rows], "day": day}, admin=True)
            job.metrics["duplicate_records"] = audit["duplicates"]
            job.check("Duplicate attendance records", 0, audit["duplicates"], audit["duplicates"] == 0)
        elif job.scenario == "student_add":
            actual = school.get_documents("students_directory", [r["person_id"] for r in rows])
            matched = sum(all(actual.get(r["person_id"], {}).get(k) == v for k, v in self.dataset.profile(r).items()) for r in rows)
            sheet_matched = 0
            for at in range(0, len(rows), 500):
                audit = school.call("toolkit_verify_students", {"students": [
                    {"name": r["name"], "class": r["class"], "rollNo": r["roll_no"], "dob": r["dob"]}
                    for r in rows[at:at + 500]]}, admin=True)
                sheet_matched += audit["matched"]
            job.metrics.update(saved_records=matched, sheet_records=sheet_matched, missing_records=len(rows) - matched)
            job.check("Matching Firestore student profiles", len(rows), matched, matched == len(rows))
            job.check("Matching Google Sheets students", len(rows), sheet_matched, sheet_matched == len(rows))
        elif job.scenario == "fees":
            matched, duplicates, amount = 0, 0, 0
            for at in range(0, len(rows), 500):
                receipts = ["TK_" + job.id + "_" + str(r["seq"]) for r in rows[at:at + 500]]
                audit = school.call("toolkit_verify_fees", {"receipts": receipts}, admin=True)
                matched += audit["matched"]
                duplicates += audit["duplicates"]
                amount += audit["paidAmount"]
            job.metrics.update(saved_records=matched, duplicate_records=duplicates, total_paid_amount=amount)
            job.check("Matching receipts persisted", len(rows), matched, matched == len(rows))
            job.check("Duplicate receipts", 0, duplicates, duplicates == 0)
            job.check("Paid amount total", len(rows) * 100, amount, amount == len(rows) * 100)
        elif job.scenario in ("mobile_login", "mobile_dashboard"):
            checked = 0
            for row in rows:
                if job.stop.is_set():
                    raise Cancelled("Stopped during session verification")
                token = school.login(row)
                d = school.call("mobile_session_verify", {"sessionToken": token})
                checked += d.get("personId") == row["person_id"]
            job.metrics["verified_sessions"] = checked
            job.check("School verified student identities", len(rows), checked, checked == len(rows))

    @staticmethod
    def _sla(job):
        observed = percentile(job.latencies, 95)
        if observed is not None:
            job.check("P95 journey time (ms)", "≤ " + str(job.config["max_p95_ms"]), round(observed, 3),
                      observed <= job.config["max_p95_ms"])

    def _website(self, job, config):
        url = validate_url(config.get("url", ""), allow_loopback=self.allow_loopback)
        expected = str(config.get("expected_text", "")).strip()
        if not expected:
            raise Blocked("Set expected response text so an HTTP 200 error/login page cannot be marked PASS")
        http = Transport(job.config["timeout"], self.allow_loopback)
        job.source = url + " · HTTP only; no browser-rendering claim"
        def request(_):
            reply = http.request(url, max_bytes=10_000_000)
            if reply.status != 200 or expected.encode() not in reply.body:
                raise RemoteError(f"HTTP {reply.status}; expected page content was not found")
        self._parallel(job, [{"seq": n} for n in range(1, job.config["count"] + 1)], request)
        job.metrics.update(http_requests=http.counters()["requests"], response_bytes=http.counters()["bytes"])
        self._sla(job)

    def _volume(self, job, school):
        total = int(job.config["gb"] * 1_000_000_000)
        chunk_size = 1_000_000
        written = verified = 0
        job.source = "Toolkit local files; not Windows-app UI" if job.scenario == "volume_local" else school.project_id + " · test Drive files"
        folder = self.directory / "volumes" / job.id
        if job.scenario == "volume_local":
            folder.mkdir(parents=True, exist_ok=True)
            if shutil.disk_usage(folder).free < total * 1.05:
                raise Blocked("Not enough free disk space for real, non-sparse test data")
        else:
            info = school.call("toolkit_info", {}, admin=True)
            if info.get("testOnly") is not True:
                raise Blocked("Drive volume tests require the enabled isolated test backend")
        job.update(phase="Writing and reading back real bytes")
        manifest = []
        try:
            while written < total:
                if job.stop.is_set():
                    raise Cancelled("Stopped during the data-volume test; files are retained")
                data = os.urandom(min(chunk_size, total - written))
                digest = hashlib.sha256(data).hexdigest()
                tick = time.perf_counter()
                index = len(manifest)
                if job.scenario == "volume_local":
                    path = folder / f"part-{index:06d}.bin"
                    with path.open("wb") as stream:
                        stream.write(data)
                        stream.flush()
                        os.fsync(stream.fileno())
                    saved = path.read_bytes()
                    observed_hash, observed_size = hashlib.sha256(saved).hexdigest(), len(saved)
                    reference = path.name
                else:
                    result = school.call("toolkit_volume_chunk", {"runId": job.id, "part": index,
                        "data": base64.b64encode(data).decode(), "sha256": digest}, admin=True)
                    observed_hash, observed_size = result.get("sha256"), result.get("bytes")
                    reference = result.get("fileId")
                ok = observed_hash == digest and observed_size == len(data)
                job.record(time.perf_counter() - tick, ok, "Saved-file read-back mismatch" if not ok else "")
                written += len(data)
                verified += len(data) if ok else 0
                manifest.append({"part": index, "bytes": len(data), "sha256": digest, "file": reference, "verified": ok})
                job.metrics.update(bytes_written=written, bytes_verified=verified, requested_bytes=total,
                                   scope="File-storage read-back only; app search/rendering is a separate scenario")
        finally:
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        job.check("Real bytes written", total, written, written == total)
        job.check("Saved-file bytes verified by SHA-256 read-back", total, verified, verified == total)
        self._sla(job)
