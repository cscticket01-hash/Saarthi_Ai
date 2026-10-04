"""A persistent, reusable student base. No customer/student data is imported."""
from __future__ import annotations

import csv
import json
import secrets
import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path

BASE_SIZE = 100_000


class Cancelled(Exception):
    pass


class StudentBase:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / "students.sqlite3"
        self.lock = threading.Lock()
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS students(
                    seq INTEGER PRIMARY KEY, person_id TEXT UNIQUE NOT NULL,
                    name TEXT NOT NULL, class TEXT NOT NULL, roll_no TEXT NOT NULL,
                    dob TEXT NOT NULL, link_token TEXT UNIQUE NOT NULL,
                    UNIQUE(class, roll_no));
                CREATE INDEX IF NOT EXISTS student_name ON students(name);
            """)
            db.execute("INSERT OR IGNORE INTO meta VALUES('dataset_id', ?)", (secrets.token_hex(8),))

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        try:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA journal_mode=WAL")
            with db:
                yield db
        finally:
            db.close()

    def stats(self):
        with self.connect() as db:
            count = db.execute("SELECT COUNT(*) FROM students").fetchone()[0]
            dataset_id = db.execute("SELECT value FROM meta WHERE key='dataset_id'").fetchone()[0]
        return {"target": BASE_SIZE, "count": count, "dataset_id": dataset_id,
                "ready": count == BASE_SIZE, "bytes": self.path.stat().st_size}

    def generate(self, progress=lambda n: None, stop=None):
        """Resume interrupted generation without changing existing QR identities."""
        stop = stop or threading.Event()
        with self.lock, self.connect() as db:
            dataset_id = db.execute("SELECT value FROM meta WHERE key='dataset_id'").fetchone()[0]
            existing = {r[0] for r in db.execute("SELECT seq FROM students")}
            first = ("Aarav", "Ananya", "Arup", "Bidhan", "Diya", "Kabir", "Meera", "Riya", "Rohan", "Tanvi")
            last = ("Das", "Roy", "Sen", "Sharma", "Borah", "Dey", "Paul", "Nath")
            batch = []
            for seq in range(1, BASE_SIZE + 1):
                if stop.is_set():
                    db.executemany("INSERT INTO students VALUES(?,?,?,?,?,?,?)", batch)
                    db.commit()
                    raise Cancelled("Student-base generation stopped; existing records are retained")
                if seq in existing:
                    continue
                if not batch:
                    # One cryptographic RNG call per batch avoids 100,000 Windows
                    # provider calls; each identity still receives 32 random bytes.
                    random_tokens = secrets.token_bytes(32 * 1000)
                offset = len(batch) * 32
                batch.append((seq, f"tk_{dataset_id}_{seq:06d}",
                              f"TEST {first[(seq - 1) % len(first)]} {last[(seq // 10) % len(last)]} {seq:06d}",
                              str((seq - 1) % 10 + 1), str((seq - 1) // 10 + 1),
                              f"{2010 + seq % 8:04d}-{seq % 12 + 1:02d}-{seq % 27 + 1:02d}",
                              random_tokens[offset:offset + 32].hex()))
                if len(batch) >= 1000:
                    db.executemany("INSERT INTO students VALUES(?,?,?,?,?,?,?)", batch)
                    db.commit()
                    existing.update(r[0] for r in batch)
                    batch.clear()
                    progress(len(existing))
            if batch:
                db.executemany("INSERT INTO students VALUES(?,?,?,?,?,?,?)", batch)
                db.commit()
            counts = db.execute("SELECT COUNT(*), COUNT(DISTINCT person_id), COUNT(DISTINCT link_token) FROM students").fetchone()
            if tuple(counts) != (BASE_SIZE, BASE_SIZE, BASE_SIZE):
                raise RuntimeError("Student-base integrity check failed")
            progress(BASE_SIZE)
        return self.stats()

    def select(self, count: int, start: int = 1):
        if not 1 <= count <= BASE_SIZE or not 1 <= start <= BASE_SIZE or start + count - 1 > BASE_SIZE:
            raise ValueError("Choose a student range inside 1–100,000")
        with self.connect() as db:
            rows = [dict(r) for r in db.execute(
                "SELECT * FROM students WHERE seq>=? AND seq<? ORDER BY seq", (start, start + count))]
        if len(rows) != count:
            raise ValueError("Generate the student base before selecting this range")
        return rows

    @staticmethod
    def profile(row):
        return {"name": row["name"], "class": row["class"], "rollNo": row["roll_no"],
                "dob": row["dob"], "dateOfBirth": row["dob"],
                "parentName": "TEST Guardian", "studentUid": row["person_id"],
                "mobileStableId": row["person_id"], "mobileLinkToken": row["link_token"]}

    @staticmethod
    def qr(row, project_id: str, script_url: str):
        return json.dumps({"app": "VIDYA_SAARTHI", "v": 3, "type": "student",
                           "firebaseProjectId": project_id, "googleScriptUrl": script_url,
                           "personId": row["person_id"], "linkToken": row["link_token"]},
                          separators=(",", ":"))

    def export(self, path: Path, fmt="csv", project_id="", script_url=""):
        with self.connect() as db, open(path, "w", encoding="utf-8", newline="") as stream:
            if fmt == "csv":
                writer = csv.writer(stream)
                writer.writerow(["number", "person_id", "name", "class", "roll_no", "dob"])
                for r in db.execute("SELECT * FROM students ORDER BY seq"):
                    writer.writerow([r[k] for k in ("seq", "person_id", "name", "class", "roll_no", "dob")])
            elif fmt == "jsonl":
                if not project_id or not script_url:
                    raise ValueError("Connect a test school before exporting matching school QR identities")
                for r in db.execute("SELECT * FROM students ORDER BY seq"):
                    row = dict(r)
                    stream.write(json.dumps({"seq": row["seq"], "personId": row["person_id"],
                                             "profile": self.profile(row),
                                             "qr": self.qr(row, project_id, script_url)}) + "\n")
            else:
                raise ValueError("Supported exports: csv, jsonl")
        return path
