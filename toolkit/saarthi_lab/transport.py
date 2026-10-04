"""HTTP transport that follows Apps Script's POST -> GET redirects correctly."""
from __future__ import annotations

import base64
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass


class Blocked(Exception):
    pass


class RemoteError(Exception):
    pass


@dataclass
class Reply:
    status: int
    body: bytes
    seconds: float
    url: str

    def json(self):
        try:
            return json.loads(self.body)
        except (ValueError, UnicodeError) as error:
            raise RemoteError("Server did not return valid JSON") from error


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_url(value, school=False, allow_loopback=False):
    url = urllib.parse.urlsplit(str(value).strip())
    local = url.hostname in ("127.0.0.1", "localhost", "::1")
    if url.username or url.password or url.fragment or not url.hostname:
        raise ValueError("Invalid URL")
    if url.scheme != "https" and not (allow_loopback and local and url.scheme == "http"):
        raise ValueError("Use HTTPS, or an explicitly configured loopback test server")
    if school and not (allow_loopback and local):
        if url.hostname != "script.google.com" or not re.fullmatch(r"/macros/s/[A-Za-z0-9_-]+/exec", url.path) or url.query:
            raise ValueError("Use the test school's Google Apps Script /exec URL")
    return urllib.parse.urlunsplit(url)


class Transport:
    def __init__(self, timeout=30, allow_loopback=False):
        self.timeout = timeout
        self.allow_loopback = allow_loopback
        self.stats_lock = threading.Lock()
        self.stats = {"requests": 0, "responses": 0, "bytes": 0, "statuses": {}}

    def counters(self):
        with self.stats_lock:
            return {**self.stats, "statuses": dict(self.stats["statuses"])}

    def request(self, url, method="GET", data=None, headers=None, school=False, max_bytes=16_000_000):
        current = validate_url(url, school=school, allow_loopback=self.allow_loopback)
        payload = json.dumps(data, separators=(",", ":")).encode() if data is not None else None
        request_headers = {"Accept": "application/json", "User-Agent": "Saarthi-Test-Lab/0.1"}
        request_headers.update(headers or {})
        if payload is not None:
            request_headers.setdefault("Content-Type", "text/plain;charset=utf-8" if school else "application/json")
        started = time.perf_counter()
        opener = urllib.request.build_opener(NoRedirect())
        for _ in range(9):
            remaining = self.timeout - (time.perf_counter() - started)
            if remaining <= 0:
                raise TimeoutError("HTTP deadline exceeded")
            req = urllib.request.Request(current, data=payload, headers=request_headers, method=method)
            with self.stats_lock:
                self.stats["requests"] += 1
            try:
                response = opener.open(req, timeout=remaining)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status = response.code
                with self.stats_lock:
                    self.stats["responses"] += 1
                    key = str(status)
                    self.stats["statuses"][key] = self.stats["statuses"].get(key, 0) + 1
                if status in (301, 302, 303, 307, 308):
                    location = response.headers.get("Location")
                    if not location:
                        raise RemoteError("Redirect did not include a location")
                    destination = urllib.parse.urljoin(current, location)
                    validate_url(destination, allow_loopback=self.allow_loopback)
                    old, new = urllib.parse.urlsplit(current), urllib.parse.urlsplit(destination)
                    if school and new.hostname not in ("script.google.com", "script.googleusercontent.com"):
                        if not (self.allow_loopback and old.hostname == new.hostname and old.port == new.port):
                            raise RemoteError("Apps Script redirected outside Google's school-content hosts")
                    if old.hostname != new.hostname:
                        request_headers.pop("Authorization", None)
                    if status in (301, 302, 303):
                        method, payload = "GET", None
                        request_headers.pop("Content-Type", None)
                    current = destination
                    continue
                body = response.read(max_bytes + 1)
                if len(body) > max_bytes:
                    raise RemoteError("Response exceeds the configured read limit")
                with self.stats_lock:
                    self.stats["bytes"] += len(body)
                if time.perf_counter() - started > self.timeout:
                    raise TimeoutError("HTTP deadline exceeded while reading the response")
                return Reply(status, body, time.perf_counter() - started, current)
        raise RemoteError("Too many HTTP redirects")


def encode_value(value):
    if value is None:
        return {"nullValue": None}
    if isinstance(value, bool):
        return {"booleanValue": value}
    if isinstance(value, int):
        return {"integerValue": str(value)}
    if isinstance(value, float):
        return {"doubleValue": value}
    if isinstance(value, dict):
        return {"mapValue": {"fields": {k: encode_value(v) for k, v in value.items()}}}
    if isinstance(value, list):
        return {"arrayValue": {"values": [encode_value(v) for v in value]}}
    return {"stringValue": str(value)}


def decode_value(value):
    for key in ("stringValue", "booleanValue", "doubleValue", "timestampValue"):
        if key in value:
            return value[key]
    if "integerValue" in value:
        return int(value["integerValue"])
    if "mapValue" in value:
        return {k: decode_value(v) for k, v in value["mapValue"].get("fields", {}).items()}
    if "arrayValue" in value:
        return [decode_value(v) for v in value["arrayValue"].get("values", [])]
    return None


class School:
    """Credentials and session tokens stay in this process, not in reports/config."""
    def __init__(self, config, allow_loopback=False):
        self.project_id = str(config.get("project_id", "")).strip()
        if not re.fullmatch(r"[a-z][a-z0-9-]{4,61}[a-z0-9]", self.project_id):
            raise ValueError("Enter the test school's Firebase project ID")
        if self.project_id == "saarthi-ai-df12b" or not re.search(r"(^|[-_])(test|lab)([-_]|$)", self.project_id):
            raise Blocked("School load tests require a separate Firebase project with 'test' or 'lab' in its ID")
        self.script_url = validate_url(config.get("script_url", ""), school=True, allow_loopback=allow_loopback)
        self.api_key = str(config.get("api_key", "")).strip()
        self.http = Transport(int(config.get("timeout", 30)), allow_loopback)
        self.id_token = ""
        self.refresh_token = ""
        self.expires = 0.0
        self.token_lock = threading.Lock()
        self.sessions = {}
        self.session_lock = threading.Lock()
        self.info = {}
        self.auth_base = "https://identitytoolkit.googleapis.com/v1/"
        self.firestore_base = f"https://firestore.googleapis.com/v1/projects/{self.project_id}/databases/(default)/documents"

    def connect(self, email, password):
        if not email or not password or not self.api_key:
            raise Blocked("Test-school API key and administrator email/password are required")
        r = self.http.request(self.auth_base + "accounts:signInWithPassword?key=" + urllib.parse.quote(self.api_key),
                              "POST", {"email": email, "password": password, "returnSecureToken": True})
        d = r.json()
        if r.status != 200 or "idToken" not in d:
            raise RemoteError("Firebase administrator sign-in failed")
        claims = json.loads(base64.urlsafe_b64decode(d["idToken"].split(".")[1] + "===").decode())
        if claims.get("aud") != self.project_id or not (claims.get("admin") is True or claims.get("role") == "admin"):
            raise Blocked("Use the administrator account with an admin claim in this test-school project")
        self.id_token, self.refresh_token = d["idToken"], d["refreshToken"]
        self.expires = time.monotonic() + int(d.get("expiresIn", 3600)) - 90
        self.info = self.call("toolkit_info", {}, admin=True)
        if self.info.get("projectId") != self.project_id or self.info.get("testOnly") is not True:
            raise Blocked("The Apps Script is not the isolated, enabled toolkit test backend")
        return self.public()

    def public(self):
        return {"connected": bool(self.id_token and self.info), "project_id": self.project_id,
                "script_url": self.script_url, "test_only": self.info.get("testOnly", False),
                "license_allowed": self.info.get("licenseAllowed", False),
                "day": self.info.get("day"), "school_open": self.info.get("schoolOpen"),
                "location": self.info.get("location", {})}

    def token(self):
        with self.token_lock:
            if time.monotonic() >= self.expires:
                data = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": self.refresh_token}).encode()
                req = urllib.request.Request("https://securetoken.googleapis.com/v1/token?key=" + urllib.parse.quote(self.api_key),
                                             data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
                try:
                    with urllib.request.urlopen(req, timeout=self.http.timeout) as response:
                        refreshed = json.load(response)
                except Exception as error:
                    raise RemoteError("Firebase administrator token refresh failed") from error
                if refreshed.get("project_id") != self.project_id:
                    raise RemoteError("Refreshed token belongs to another Firebase project")
                self.id_token, self.refresh_token = refreshed["id_token"], refreshed["refresh_token"]
                self.expires = time.monotonic() + int(refreshed["expires_in"]) - 90
            return self.id_token

    def call(self, action, body=None, admin=False):
        payload = {"action": action, "projectId": self.project_id, **(body or {})}
        if admin:
            payload.update(schoolProjectId=self.project_id, schoolAdminIdToken=self.token())
            if self.info.get("schoolSyncId"):
                payload["_windowsSchoolSyncId"] = self.info["schoolSyncId"]
        reply = self.http.request(self.script_url, "POST", payload, school=True)
        d = reply.json()
        if reply.status != 200 or not isinstance(d, dict) or d.get("success") is not True:
            message = d.get("message", "School request rejected") if isinstance(d, dict) else "Invalid school response"
            raise RemoteError(str(message)[:240])
        if d.get("projectId") not in (None, self.project_id):
            raise RemoteError("Server returned a different school identity")
        return d

    def login(self, row):
        with self.session_lock:
            cached = self.sessions.get(row["person_id"])
            if cached and cached[1] > time.time() * 1000 + 60_000:
                return cached[0]
        d = self.call("mobile_login", {"role": "student", "personId": row["person_id"],
                    "linkToken": row["link_token"], "studentClass": row["class"],
                    "rollNo": row["roll_no"], "dob": row["dob"]})
        if d.get("personId") != row["person_id"] or not d.get("sessionToken"):
            raise RemoteError("Login did not return the expected student identity")
        with self.session_lock:
            self.sessions[row["person_id"]] = (d["sessionToken"], int(d.get("expiresAt", 0)))
        return d["sessionToken"]

    def firestore(self, method, suffix, data=None):
        r = self.http.request(self.firestore_base + suffix, method, data,
                              {"Authorization": "Bearer " + self.token()})
        if r.status not in (200, 201):
            raise RemoteError(f"School Firestore operation failed (HTTP {r.status})")
        return r.json()

    def save_profile(self, row, profile):
        return self.firestore("PATCH", "/students_directory/" + urllib.parse.quote(row["person_id"]),
                              {"fields": {k: encode_value(v) for k, v in profile.items()}})

    def get_documents(self, collection, ids):
        result = {}
        for at in range(0, len(ids), 200):
            names = [self.firestore_base.removeprefix("https://firestore.googleapis.com/v1/") +
                     "/" + collection + "/" + i for i in ids[at:at + 200]]
            data = self.firestore("POST", ":batchGet", {"documents": names})
            if not isinstance(data, list):
                raise RemoteError("Firestore verification returned an unexpected format")
            for item in data:
                doc = item.get("found")
                if doc:
                    result[doc["name"].rsplit("/", 1)[1]] = {
                        k: decode_value(v) for k, v in doc.get("fields", {}).items()}
        return result
