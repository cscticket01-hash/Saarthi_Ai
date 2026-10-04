from __future__ import annotations

import csv
import io
import json
import re
import secrets
import shutil
import subprocess
import sys
import threading
import urllib.parse
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .engine import Engine, SCENARIOS
from .transport import Blocked, School


class LabServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, engine: Engine, resources: Path, port=0):
        self.engine, self.resources = engine, Path(resources)
        self.token = secrets.token_urlsafe(32)
        self.browser_install = None
        super().__init__(("127.0.0.1", port), Handler)

    @property
    def origin(self):
        return "http://127.0.0.1:" + str(self.server_address[1])


class Handler(BaseHTTPRequestHandler):
    server_version = "SaarthiTestLab/0.1"

    def log_message(self, *_):
        pass  # Request bodies, secrets and browser URLs are never logged.

    def send(self, code, body, mime="application/json; charset=utf-8", name=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        if name:
            self.send_header("Content-Disposition", 'attachment; filename="' + name + '"')
        self.end_headers()
        self.wfile.write(body)

    def authenticated(self):
        host = self.headers.get("Host", "")
        valid = {"127.0.0.1:" + str(self.server.server_address[1]), "localhost:" + str(self.server.server_address[1])}
        if host not in valid:
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in {"http://" + h for h in valid}:
            return False
        return secrets.compare_digest(self.headers.get("X-Lab-Token", ""), self.server.token)

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        port = self.server.server_address[1]
        if self.headers.get("Host") not in {"127.0.0.1:" + str(port), "localhost:" + str(port)}:
            self.send(403, {"error": "Invalid local host"})
            return
        if path in ("/", "/app.js", "/styles.css"):
            file = self.server.resources / "static" / ({"/": "index.html"}.get(path, path[1:]))
            text = file.read_text(encoding="utf-8").replace("__LAB_TOKEN__", self.server.token)
            mime = {"/": "text/html", "/app.js": "application/javascript", "/styles.css": "text/css"}[path]
            self.send(200, text, mime + "; charset=utf-8")
            return
        if not self.authenticated():
            self.send(403, {"error": "Local session token required"})
            return
        try:
            if path == "/api/state":
                engine = self.server.engine
                native = engine.native_config
                self.send(200, {"dataset": engine.dataset.stats(), "jobs": engine.snapshots(), "scenarios": SCENARIOS,
                    "school": engine.school.public() if engine.school else {"connected": False},
                    "firebase": engine.firebase.firebase_public() if engine.firebase else {"connected": False},
                    "connections": {"web": {k: v for k, v in native["web"].items() if k not in ("password", "email")},
                                    "windows": native["windows"], "android": native["android"]},
                    "browser_setup_running": self.server.browser_install is not None and self.server.browser_install.poll() is None})
            elif path.startswith("/api/report/"):
                run_id = path.rsplit("/", 1)[1]
                if not re.fullmatch(r"[a-f0-9]{16}", run_id):
                    raise ValueError("Invalid report ID")
                self.send(200, (self.server.engine.reports / (run_id + ".json")).read_bytes(), name=run_id + ".json")
            elif path == "/api/backend":
                folder = self.server.resources / "backend"
                if not (folder / "Code.gs").is_file():
                    raise Blocked("Build the test-backend bundle with python prepare_backend.py first")
                out = io.BytesIO()
                with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
                    for file in folder.iterdir():
                        if file.is_file():
                            archive.write(file, file.name)
                self.send(200, out.getvalue(), "application/zip", "Saarthi-Test-Backend.zip")
            elif path.startswith("/api/export/"):
                fmt = path.rsplit("/", 1)[1]
                if fmt not in ("csv", "jsonl"):
                    raise ValueError("Supported exports: csv, jsonl")
                folder = self.server.engine.directory / "exports"
                folder.mkdir(parents=True, exist_ok=True)
                file = folder / ("students-" + secrets.token_hex(4) + "." + fmt)
                school = self.server.engine.school
                self.server.engine.dataset.export(file, fmt, school.project_id if school else "", school.script_url if school else "")
                self.send_response(200)
                self.send_header("Content-Type", "text/csv" if fmt == "csv" else "application/x-ndjson")
                self.send_header("Content-Length", str(file.stat().st_size))
                self.send_header("Content-Disposition", 'attachment; filename="students.' + fmt + '"')
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                with file.open("rb") as stream:
                    shutil.copyfileobj(stream, self.wfile)
            else:
                self.send(404, {"error": "Not found"})
        except Blocked as error:
            self.send(409, {"error": str(error)})
        except (OSError, ValueError) as error:
            self.send(400, {"error": str(error)[:240]})

    def do_POST(self):
        if not self.authenticated():
            self.send(403, {"error": "Local session token required"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 1 <= length <= 1_000_000:
                raise ValueError("Invalid request size")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("Expected a JSON object")
            path = urllib.parse.urlsplit(self.path).path
            engine = self.server.engine
            if path == "/api/run":
                self.send(202, engine.start(body.get("scenario"), body.get("options", {})))
            elif path == "/api/stop":
                engine.cancel(body.get("id"))
                self.send(200, {"stopping": True})
            elif path in ("/api/connect/firebase", "/api/connect/school"):
                if any(j.state == "RUNNING" for j in engine.jobs.values()):
                    raise ValueError("Wait for the active task before changing connections")
                firebase_only = path == "/api/connect/firebase"
                candidate = School(body, engine.allow_loopback, require_script=not firebase_only)
                try:
                    result = candidate.connect_firebase(body.get("email"), body.get("password"))
                    engine.firebase = candidate
                    if not firebase_only or (engine.school and engine.school.project_id != candidate.project_id):
                        engine.school = None
                    if not firebase_only:
                        result = candidate.connect_backend()
                        engine.school = candidate
                except Exception as error:
                    detail = engine.clean_error(error, candidate)
                    if candidate.firebase_info:
                        raise Blocked("Firebase verified; Apps Script backend still needs setup. " + detail) from error
                    raise Blocked(detail) from error
                self.send(200, result)
            elif path == "/api/connect/native":
                if any(j.state == "RUNNING" for j in engine.jobs.values()):
                    raise ValueError("Wait for the active task before changing connections")
                for platform in ("web", "windows", "android"):
                    value = body.get(platform, {})
                    if not isinstance(value, dict) or not isinstance(value.get("steps", []), list):
                        raise ValueError("Invalid runner configuration")
                    engine.native_config[platform] = value
                self.send(200, {"saved": True, "credentials": "Process memory only"})
            elif path == "/api/install-browser":
                if getattr(sys, "frozen", False):
                    command = [sys.executable, "--install-browser"]
                else:
                    command = [sys.executable, "-m", "playwright", "install", "chromium"]
                if self.server.browser_install and self.server.browser_install.poll() is None:
                    raise ValueError("Browser installation is already running")
                log = (engine.directory / "browser-install.log").open("wb")
                try:
                    self.server.browser_install = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                finally:
                    log.close()
                self.send(202, {"started": True})
            elif path == "/api/shutdown":
                for job in engine.jobs.values():
                    if job.state == "RUNNING":
                        job.stop.set()
                self.send(200, {"closing": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                self.send(404, {"error": "Not found"})
        except Blocked as error:
            self.send(409, {"error": str(error)})
        except Exception as error:
            self.send(400, {"error": self.server.engine.clean_error(error, self.server.engine.school)})
