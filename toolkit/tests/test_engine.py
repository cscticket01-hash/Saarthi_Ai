from __future__ import annotations

import base64
import hashlib
import json
import secrets
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from saarthi_lab.dataset import BASE_SIZE, StudentBase
from saarthi_lab.engine import Engine
from saarthi_lab.jobs import percentile
from saarthi_lab.server import LabServer
from saarthi_lab.transport import Blocked, School, Transport, decode_value, encode_value, validate_url


class Fixture(ThreadingHTTPServer):
    """A controlled test server, not a Saarthi production benchmark."""
    daemon_threads = True
    def __init__(self):
        self.profiles, self.attendance, self.sheets, self.sessions, self.fees, self.results = {}, {}, {}, {}, {}, {}
        self.ignore_attendance = self.ignore_profile = self.wrong_dashboard = False
        self.closed = self.unlicensed = self.duplicate_attendance = False
        self.delay = .002
        self.result_lock = threading.RLock()
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.url = "http://127.0.0.1:" + str(self.server_address[1])
        self.thread = threading.Thread(target=self.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
        self.thread.start()

    def close(self):
        self.shutdown(); self.server_close(); self.thread.join(timeout=2)

    def connect(self):
        school = School({"project_id": "saarthi-lab-test", "script_url": self.url + "/exec", "api_key": "fixture-key"}, True)
        school.auth_base = self.url + "/auth/"
        school.firestore_base = self.url + "/firestore/documents"
        school.connect("test@example.invalid", "fixture-only-password")
        return school


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

    def do_GET(self):
        if self.path.startswith("/result/"):
            with self.server.result_lock:
                result = self.server.results.pop(self.path.rsplit("/", 1)[1])
            self.reply(result)
        else:
            time.sleep(self.server.delay)
            self.reply({"page": "School dashboard ready"})

    def body(self):
        return json.loads(self.rfile.read(int(self.headers["Content-Length"])))

    def do_PATCH(self):
        body = self.body()
        identity = self.path.rsplit("/", 1)[1]
        fields = {k: decode_value(v) for k, v in body["fields"].items()}
        if not self.server.ignore_profile:
            with self.server.result_lock: self.server.profiles[identity] = fields
        self.reply({"name": identity, "fields": body["fields"]})

    def do_POST(self):
        b = self.body()
        if self.path.startswith("/auth/"):
            claims = base64.urlsafe_b64encode(json.dumps({"aud":"saarthi-lab-test","admin":True}).encode()).decode().rstrip("=")
            self.reply({"idToken":"fixture."+claims+".fixture", "refreshToken":"fixture-refresh", "expiresIn":"3600"})
            return
        if self.path.endswith(":batchGet"):
            output=[]
            with self.server.result_lock:
                for name in b["documents"]:
                    collection, identity = name.rsplit("/",2)[-2:]
                    records = self.server.attendance if collection == "attendance_records" else self.server.profiles
                    row=records.get(identity)
                    output.append({"found":{"name":name,"fields":{k:encode_value(v) for k,v in row.items()}}} if row else {"missing":name})
            self.reply(output);return
        time.sleep(self.server.delay)
        action=b["action"]
        result={"success":True,"projectId":"saarthi-lab-test"}
        with self.server.result_lock:
            if action=="toolkit_info":
                result.update(testOnly=True,licenseAllowed=not self.server.unlicensed,schoolOpen=not self.server.closed,
                              day="2026-10-05",location={"latitude":24.8,"longitude":92.8})
            elif action=="toolkit_seed":
                for entry in b["students"]:
                    profile=entry["profile"]
                    self.server.profiles[entry["personId"]]=profile
                    self.server.sheets[(profile["class"],profile["rollNo"])]=profile
                result["verified"]=sum(self.server.profiles.get(s["personId"])==s["profile"] for s in b["students"])
            elif action=="mobile_login":
                person=self.server.profiles.get(b["personId"])
                if not person or person["mobileLinkToken"]!=b["linkToken"] or person["dob"]!=b["dob"]:
                    result.update(success=False,message="Invalid student login")
                else:
                    token=hashlib.sha256((b["personId"]+str(time.time_ns())).encode()).hexdigest()
                    self.server.sessions[token]=b["personId"]
                    result.update(sessionToken=token,personId=b["personId"],expiresAt=int(time.time()*1000)+3600000)
            elif action in ("mobile_session_verify","mobile_dashboard","mobile_mark_attendance"):
                identity=self.server.sessions.get(b.get("sessionToken"))
                if not identity:
                    result.update(success=False,message="Invalid school session")
                elif action=="mobile_session_verify": result["personId"]=identity
                elif action=="mobile_dashboard":
                    result["person"]={"mobileStableId":"someone-else" if self.server.wrong_dashboard else identity}
                else:
                    key=hashlib.sha256(("student/"+identity+"/2026-10-05").encode()).hexdigest()
                    if key in self.server.attendance: result.update(success=False,message="Already checked in")
                    elif not self.server.ignore_attendance:
                        self.server.attendance[key]={"personId":identity,"role":"student","date":"2026-10-05","checkIn":int(time.time()*1000)}
            elif action=="toolkit_audit_attendance":
                result["duplicates"]=1 if self.server.duplicate_attendance else 0
            elif action=="add_student":
                key=(b["studentClass"],b["rollNo"])
                if key in self.server.sheets: result.update(success=False,message="Student already exists")
                else: self.server.sheets[key]={"name":b["name"],"class":b["studentClass"],"rollNo":b["rollNo"],"dob":b["dateOfBirth"]}
            elif action=="toolkit_verify_students":
                result["matched"]=sum(all(self.server.sheets.get((r["class"],r["rollNo"]),{}).get(k)==r[k] for k in ("name","class","rollNo","dob")) for r in b["students"])
            elif action=="save_fee_payment": self.server.fees[b["receiptNo"]]=b["totalPaid"]
            elif action=="toolkit_verify_fees":
                present=[r for r in b["receipts"] if r in self.server.fees]
                result.update(matched=len(present),duplicates=0,paidAmount=sum(self.server.fees[r] for r in present))
            else: result.update(success=False,message="Unsupported fixture action")
            key=secrets.token_hex(16)
            self.server.results[key]=result
        self.send_response(303);self.send_header("Location", "/result/"+key);self.send_header("Content-Length","0");self.end_headers()


class ToolkitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_temp=tempfile.TemporaryDirectory()
        cls.base=StudentBase(Path(cls.base_temp.name))
        cls.base.generate()

    @classmethod
    def tearDownClass(cls):
        cls.base_temp.cleanup()

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.engine=Engine(Path(self.temp.name),allow_loopback=True)
        self.engine.dataset=self.base
        self.fixture=Fixture()
        self.engine.school=self.fixture.connect()

    def tearDown(self):
        for job in self.engine.jobs.values():
            if job.state=="RUNNING": job.stop.set()
        self.fixture.close();self.temp.cleanup()

    def run_job(self,scenario,**options):
        response=self.engine.start(scenario,{"count":12,"concurrency":4,"rate":0,"max_p95_ms":10000,**options})
        job=self.engine.jobs[response["id"]]
        deadline=time.monotonic()+20
        while job.state=="RUNNING" and time.monotonic()<deadline: time.sleep(.01)
        self.assertNotEqual(job.state,"RUNNING",job.snapshot())
        return job.snapshot()

    def test_base_really_has_100000_unique_matching_identities(self):
        self.assertEqual(self.base.stats()["count"],BASE_SIZE)
        with self.base.connect() as db:
            counts=db.execute("SELECT COUNT(DISTINCT person_id),COUNT(DISTINCT link_token) FROM students").fetchone()
            self.assertEqual(tuple(counts),(BASE_SIZE,BASE_SIZE))
        selected=self.base.select(17,99984)
        self.assertEqual(selected[-1]["seq"],100000)
        qr=json.loads(self.base.qr(selected[0],"saarthi-lab-test",self.fixture.url+"/exec"))
        self.assertEqual(qr["linkToken"],selected[0]["link_token"])
        self.assertEqual(qr["personId"],selected[0]["person_id"])
        with self.assertRaises(ValueError): self.base.select(18,99984)

    def test_real_redirect_requests_and_saved_attendance_are_measured(self):
        report=self.run_job("attendance",count=24)
        self.assertEqual(report["state"],"PASS",report)
        self.assertEqual(len(self.fixture.attendance),24)
        self.assertEqual(report["metrics"]["saved_records"],24)
        self.assertEqual(report["metrics"]["duplicate_records"],0)
        self.assertGreater(report["avg_ms"],0)
        self.assertGreater(report["metrics"]["http_requests"],24)
        self.assertGreater(report["metrics"]["preparation_seconds"],0)
        self.assertLessEqual(report["peak_concurrency"],4)

    def test_http_success_without_saved_attendance_fails(self):
        self.fixture.ignore_attendance=True
        report=self.run_job("attendance")
        self.assertEqual(report["succeeded"],12)
        self.assertEqual(report["state"],"FAIL")
        self.assertEqual(report["metrics"]["saved_records"],0)
        self.assertEqual(report["metrics"]["missing_records"],12)

    def test_duplicate_saved_records_fail(self):
        self.fixture.duplicate_attendance=True
        report=self.run_job("attendance")
        self.assertEqual(report["state"],"FAIL")
        self.assertEqual(report["metrics"]["duplicate_records"],1)

    def test_student_add_requires_real_firestore_and_sheet_readback(self):
        good=self.run_job("student_add",count=13)
        self.assertEqual(good["state"],"PASS",good)
        self.assertEqual(good["metrics"]["sheet_records"],13)
        self.fixture.ignore_profile=True
        bad=self.run_job("student_add",count=9)
        self.assertEqual(bad["succeeded"],9)
        self.assertEqual(bad["state"],"FAIL")
        self.assertEqual(bad["metrics"]["saved_records"],0)

    def test_wrong_student_dashboard_does_not_pass(self):
        self.fixture.wrong_dashboard=True
        report=self.run_job("mobile_dashboard",count=4)
        self.assertEqual(report["state"],"FAIL")
        self.assertEqual(report["failed"],4)

    def test_fees_verify_persisted_amount(self):
        report=self.run_job("fees",count=7)
        self.assertEqual(report["state"],"PASS",report)
        self.assertEqual(report["metrics"]["total_paid_amount"],700)

    def test_calendar_and_licence_are_not_bypassed(self):
        self.fixture.closed=True
        closed=self.run_job("attendance")
        self.assertEqual(closed["state"],"BLOCKED")
        self.assertEqual(closed["completed"],0)
        self.fixture.closed=False;self.fixture.unlicensed=True
        self.assertEqual(self.run_job("mobile_login")["state"],"BLOCKED")

    def test_repeat_attendance_is_a_real_failure(self):
        self.assertEqual(self.run_job("attendance",count=3)["state"],"PASS")
        repeated=self.run_job("attendance",count=3)
        self.assertEqual(repeated["state"],"FAIL")
        self.assertEqual(repeated["failed"],3)

    def test_website_content_and_p95_limit_are_real_checks(self):
        self.engine.native_config["web"]={"url":self.fixture.url+"/page","expected_text":"School dashboard ready"}
        report=self.run_job("web_http",count=10)
        self.assertEqual(report["state"],"PASS",report)
        self.engine.native_config["web"]["expected_text"]="Not in this page"
        self.assertEqual(self.run_job("web_http",count=4)["state"],"FAIL")
        self.engine.native_config["web"]["expected_text"]="School dashboard ready"
        slow=self.run_job("web_http",count=3,max_p95_ms=.000001)
        self.assertEqual(slow["state"],"FAIL")

    def test_local_volume_writes_and_reads_actual_non_sparse_bytes(self):
        report=self.run_job("volume_local",gb=.000065536)
        self.assertEqual(report["state"],"PASS",report)
        self.assertEqual(report["metrics"]["bytes_verified"],65536)
        folder=Path(self.temp.name)/"volumes"/report["id"]
        manifest=json.loads((folder/"manifest.json").read_text())
        file=folder/manifest[0]["file"]
        self.assertEqual(file.stat().st_size,65536)
        self.assertEqual(hashlib.sha256(file.read_bytes()).hexdigest(),manifest[0]["sha256"])
        self.assertIn("not Windows",report["target"])

    def test_cancelled_workload_never_passes(self):
        self.fixture.delay=.04
        response=self.engine.start("attendance",{"count":100,"concurrency":2,"rate":0,"max_p95_ms":10000})
        job=self.engine.jobs[response["id"]]
        deadline=time.monotonic()+5
        while job.completed<1 and time.monotonic()<deadline: time.sleep(.005)
        self.engine.cancel(job.id)
        while job.state=="RUNNING" and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(job.state,"CANCELLED")
        self.assertLess(job.completed,100)

    def test_missing_setup_is_blocked_and_report_has_no_credentials(self):
        self.engine.dataset=StudentBase(Path(self.temp.name)/"not-generated")
        self.assertEqual(self.run_job("base_search")["state"],"BLOCKED")
        self.engine.dataset=self.base
        self.engine.school=None
        self.assertEqual(self.run_job("attendance")["state"],"BLOCKED")
        self.engine.school=self.fixture.connect()
        report=self.run_job("attendance",count=2)
        saved=(self.engine.reports/(report["id"]+".json")).read_text()
        for secret in (self.engine.school.id_token,self.engine.school.refresh_token,"fixture-only-password"):
            self.assertNotIn(secret,saved)
        self.assertEqual(self.engine.clean_error(Exception("token="+"a"*64)),"token=[redacted]")

    def test_invalid_concurrency_or_selection_is_rejected(self):
        with self.assertRaises(ValueError): self.engine.start("attendance",{"count":100001})
        with self.assertRaises(ValueError): self.engine.start("attendance",{"concurrency":15000})
        with self.assertRaises(ValueError): self.engine.start("attendance",{"count":15,"start":99990})
        with self.assertRaises(Blocked): School({"project_id":"saarthi-ai-df12b","script_url":self.fixture.url+"/exec"},True)
        self.assertEqual(percentile([1,2,3,4],95),4)
        self.assertIsNone(percentile([],95))

    def test_native_missing_assertions_never_report_pass(self):
        report=self.run_job("android_ui",concurrency=1)
        self.assertEqual(report["state"],"BLOCKED")
        self.assertIsNone(report["avg_ms"])

    def test_local_api_rejects_missing_token_and_invalid_host(self):
        server=LabServer(self.engine,Path(__file__).parent.parent/"saarthi_lab")
        thread=threading.Thread(target=server.serve_forever,kwargs={"poll_interval":.01},daemon=True);thread.start()
        transport=Transport(allow_loopback=True)
        try:
            self.assertEqual(transport.request(server.origin+"/api/state").status,403)
            authenticated=transport.request(server.origin+"/api/state",headers={"X-Lab-Token":server.token})
            self.assertEqual(authenticated.status,200)
            self.assertEqual(authenticated.json()["dataset"]["count"],100000)
            page=transport.request(server.origin+"/",headers={"Host":"malicious.example"})
            self.assertEqual(page.status,403)
        finally:
            server.shutdown();server.server_close();thread.join(timeout=2)


if __name__=="__main__":
    unittest.main()
