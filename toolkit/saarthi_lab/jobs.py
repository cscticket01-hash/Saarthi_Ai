from __future__ import annotations

import json
import math
import secrets
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

TERMINAL = {"PASS", "FAIL", "BLOCKED", "INCONCLUSIVE", "CANCELLED"}


def percentile(values, percentage):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * percentage / 100) - 1)]


class Job:
    def __init__(self, scenario, config, directory: Path):
        self.id = secrets.token_hex(8)
        self.scenario = scenario
        self.config = dict(config)
        self.directory = Path(directory)
        self.stop = threading.Event()
        self.lock = threading.RLock()
        self.started = time.perf_counter()
        self.ended = None
        self.state = "RUNNING"
        self.phase = "Starting"
        self.completed = self.succeeded = self.failed = 0
        self.active = self.peak_concurrency = 0
        self.latencies = []
        self.errors = []
        self.checks = []
        self.timeline = []
        self.metrics = {}
        self.created_at = datetime.now(timezone.utc).isoformat()
        self.source = ""
        self._last_sample = self.started
        self._last_completed = 0

    def update(self, **values):
        with self.lock:
            for key, value in values.items():
                setattr(self, key, value)

    def record(self, seconds, success, message="", student=None):
        with self.lock:
            self.completed += 1
            self.succeeded += int(success)
            self.failed += int(not success)
            self.latencies.append(seconds * 1000)
            if message and len(self.errors) < 25:
                self.errors.append({"student_number": student, "message": str(message)[:300]})
            now = time.perf_counter()
            elapsed = now - self._last_sample
            if elapsed >= 1:
                self.timeline.append({"seconds": round(now - self.started, 3),
                                      "completed": self.completed,
                                      "per_second": round((self.completed - self._last_completed) / elapsed, 3)})
                if len(self.timeline) > 240:
                    self.timeline = self.timeline[::2]
                self._last_completed, self._last_sample = self.completed, now

    def snapshot(self):
        with self.lock:
            elapsed = (self.ended or time.perf_counter()) - self.started
            return {"id": self.id, "scenario": self.scenario, "config": self.config,
                    "created_at": self.created_at, "state": self.state, "phase": self.phase,
                    "target": self.source, "requested": self.config.get("count"),
                    "completed": self.completed, "succeeded": self.succeeded, "failed": self.failed,
                    "duration_seconds": round(elapsed, 3),
                    "avg_ms": round(sum(self.latencies) / len(self.latencies), 3) if self.latencies else None,
                    "p95_ms": percentile(self.latencies, 95), "p99_ms": percentile(self.latencies, 99),
                    "max_ms": max(self.latencies) if self.latencies else None,
                    "peak_concurrency": self.peak_concurrency, "metrics": dict(self.metrics),
                    "checks": list(self.checks), "errors": list(self.errors), "timeline": list(self.timeline),
                    "evidence": "Actual execution; missing measurements remain null"}

    def finish(self, state, phase="Completed"):
        if state not in TERMINAL:
            raise ValueError("Invalid final job status")
        with self.lock:
            ended = time.perf_counter()
            report = self.snapshot()
            report.update(state=state, phase=phase, duration_seconds=round(ended - self.started, 3))
            pending = self.directory / (self.id + ".pending")
            try:
                self.directory.mkdir(parents=True, exist_ok=True)
                pending.write_text(json.dumps(report, indent=2), encoding="utf-8")
                pending.replace(self.directory / (self.id + ".json"))
            except OSError as error:
                self.errors.append({"message": "Evidence report could not be saved: " + type(error).__name__})
                self.state, self.phase, self.ended = "FAIL", "Could not save evidence report", ended
                return
            # Publish the final state only after its downloadable evidence exists.
            self.state, self.phase, self.ended = state, phase, ended

    def check(self, name, expected, observed, ok):
        with self.lock:
            self.checks.append({"check": name, "expected": expected, "observed": observed, "pass": bool(ok)})

    def verdict(self):
        if self.stop.is_set():
            return "CANCELLED"
        if self.failed or any(not c["pass"] for c in self.checks):
            return "FAIL"
        if not self.checks:
            return "INCONCLUSIVE"
        return "PASS"
