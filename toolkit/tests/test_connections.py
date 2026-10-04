"""Controlled protocol checks; never a claim of a live cloud connection."""
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from backend.grant_test_admin import SetupError, grant
from saarthi_lab.engine import Engine
from saarthi_lab.server import LabServer
from saarthi_lab.transport import Blocked, RemoteError, School, Transport
from test_engine import Fixture


class FirebaseConnectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.temp = tempfile.TemporaryDirectory()
        self.engine = Engine(Path(self.temp.name), allow_loopback=True)

    def tearDown(self):
        self.fixture.close()
        self.temp.cleanup()

    def candidate(self, config=None, allow_loopback=True, require_script=False):
        school = School(config or {"project_id":"saarthi-lab-test", "api_key":"fixture-key"}, allow_loopback, require_script)
        school.auth_base = self.fixture.url + "/auth/"
        school.refresh_base = self.fixture.url + "/refresh/"
        school.firestore_base = self.fixture.url + "/firestore/documents"
        return school

    def test_firebase_verification_is_independent_of_script_and_contains_no_credentials(self):
        school = self.candidate()
        result = school.connect_firebase("test@example.invalid", "fixture-password")
        self.assertTrue(result["connected"])
        self.assertTrue(result["firestore_read"])
        self.assertFalse(result["google_oauth_required"])
        self.assertFalse(school.public()["connected"])
        self.assertEqual(school.http.counters()["requests"], 2)
        self.assertEqual(self.fixture.profiles, {})
        for secret in (school.id_token, school.refresh_token, school.api_key, "fixture-password"):
            self.assertNotIn(secret, json.dumps(result))
        with self.assertRaisesRegex(Blocked, "Apps Script"):
            school.connect_backend()

    def test_missing_admin_claim_never_verifies(self):
        self.fixture.admin_claim = False
        school = self.candidate()
        with self.assertRaisesRegex(Blocked, "admin:true"):
            school.connect_firebase("test@example.invalid", "fixture-password")
        self.assertFalse(school.firebase_public()["connected"])

    def test_firebase_auth_failures_do_not_verify_or_reach_firestore(self):
        for code, hint in (("OPERATION_NOT_ALLOWED", "Enable Email/Password"), ("INVALID_LOGIN_CREDENTIALS", "Check the test administrator email and password")):
            self.fixture.auth_error = code
            school = self.candidate()
            with self.assertRaisesRegex(RemoteError, hint):
                school.connect_firebase("test@example.invalid", "wrong-password")
            self.assertFalse(school.firebase_public()["connected"])
            self.assertFalse(school.public()["connected"])
            self.assertEqual(school.http.counters()["requests"], 1)

    def test_denied_firestore_and_wrong_probe_do_not_verify(self):
        school = self.candidate()
        self.fixture.admin_claim = True
        self.fixture.deny_firestore = True
        with self.assertRaisesRegex(RemoteError, "Firestore read failed"):
            school.connect_firebase("test@example.invalid", "fixture-password")
        self.assertFalse(school.firebase_public()["connected"])
        self.fixture.deny_firestore = False
        self.fixture.bad_probe = True
        with self.assertRaisesRegex(RemoteError, "did not verify"):
            school.connect_firebase("test@example.invalid", "fixture-password")
        self.assertFalse(school.firebase_public()["connected"])

    def test_local_api_reports_partial_connection_without_enabling_school_tests(self):
        server = LabServer(self.engine, Path(__file__).parent.parent / "saarthi_lab")
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval":.01}, daemon=True)
        thread.start()
        client = Transport(allow_loopback=True)
        headers = {"X-Lab-Token":server.token}
        config = {"project_id":"saarthi-lab-test", "api_key":"fixture-key", "email":"test@example.invalid", "password":"fixture-password", "script_url":self.fixture.url+"/exec"}
        try:
            with patch("saarthi_lab.server.School", side_effect=self.candidate):
                reply = client.request(server.origin+"/api/connect/firebase", "POST", config, headers)
                self.assertEqual(reply.status, 200, reply.body)
                self.assertTrue(reply.json()["connected"])
                self.assertIsNone(self.engine.school)
                self.fixture.backend_unavailable = True
                reply = client.request(server.origin+"/api/connect/school", "POST", config, headers)
                self.assertEqual(reply.status, 409, reply.body)
                self.assertIn("Firebase verified; Apps Script", reply.json()["error"])
                status = client.request(server.origin+"/api/state", headers=headers).json()
                self.assertTrue(status["firebase"]["connected"])
                self.assertFalse(status["school"]["connected"])
                self.assertEqual(status["jobs"], [])
                for secret in (self.engine.firebase.id_token, self.engine.firebase.refresh_token, "fixture-key", "fixture-password"):
                    self.assertNotIn(secret, json.dumps(status))
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)


class OwnerSetupTests(unittest.TestCase):
    def account_fixture(self, ignore_write=False):
        user = {"localId":"test-admin", "email":"test@example.invalid", "customAttributes":json.dumps({"schoolRole":"owner"})}
        calls = []
        def request(project, action, body, token):
            self.assertEqual(project, "saarthi-lab-test")
            self.assertEqual(token, "fixture-owner-token")
            calls.append((action, body))
            if action == "update":
                self.assertEqual(body["localId"], user["localId"])
                if not ignore_write:
                    user["customAttributes"] = body["customAttributes"]
                return {}
            return {"users":[dict(user)]}
        return user, calls, request

    def test_owner_setup_preserves_other_claims_and_verifies_readback(self):
        user, calls, request = self.account_fixture()
        result = grant("saarthi-lab-test", "test@example.invalid", request, lambda:"fixture-owner-token")
        self.assertTrue(result["admin_claim_verified"])
        self.assertEqual(json.loads(user["customAttributes"]), {"schoolRole":"owner", "admin":True})
        self.assertEqual([action for action, _ in calls], ["lookup", "update", "lookup"])
        self.assertNotIn("fixture-owner-token", json.dumps(result))

    def test_owner_setup_does_not_claim_success_when_write_was_not_saved(self):
        _, _, request = self.account_fixture(ignore_write=True)
        with self.assertRaisesRegex(SetupError, "not verified"):
            grant("saarthi-lab-test", "test@example.invalid", request, lambda:"fixture-owner-token")

    def test_non_test_projects_are_rejected_before_owner_credentials_are_read(self):
        def forbidden(*_):
            self.fail("A blocked project must not obtain a credential or make an API call")
        for project in ("saarthi-ai-df12b", "real-school", "saarthi-lab/other"):
            with self.assertRaises(SetupError):
                grant(project, "test@example.invalid", forbidden, forbidden)

    def test_missing_user_is_not_created_or_granted_implicitly(self):
        calls = []
        def request(project, action, body, token):
            calls.append(action)
            return {"users":[]}
        with self.assertRaisesRegex(SetupError, "Create this administrator"):
            grant("saarthi-lab-test", "test@example.invalid", request, lambda:"fixture-owner-token")
        self.assertEqual(calls, ["lookup"])


if __name__ == "__main__":
    unittest.main()
