"""Start the local Windows app; the dashboard is never publicly hosted."""
from __future__ import annotations

import argparse
import os
import sys
import threading
import webbrowser
from pathlib import Path

from saarthi_lab.engine import Engine
from saarthi_lab.server import LabServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--no-auto-base", action="store_true")
    parser.add_argument("--allow-loopback-targets", action="store_true", help="Local integration tests only")
    parser.add_argument("--install-browser", action="store_true")
    args = parser.parse_args()
    if args.install_browser:
        from playwright.__main__ import main as install
        sys.argv = ["playwright", "install", "chromium"]
        install()
        return
    directory = args.data_dir or Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "SaarthiTestLab"
    resources = Path(getattr(sys, "_MEIPASS", Path(__file__).parent)) / "saarthi_lab"
    if not getattr(sys, "frozen", False) and not (resources / "backend" / "Code.gs").is_file():
        from prepare_backend import bundle
        bundle(resources / "backend")
    engine = Engine(directory, args.allow_loopback_targets)
    server = LabServer(engine, resources, args.port)
    # Generation is a real, resumable background task. It never creates remote data.
    if not args.no_auto_base and not engine.dataset.stats()["ready"]:
        engine.start("base_generate", {})
    if not args.no_browser:
        threading.Timer(.4, lambda: webbrowser.open(server.origin)).start()
    if sys.stdout is not None:
        print("Saarthi Test Lab: " + server.origin, flush=True)
    try:
        server.serve_forever(poll_interval=.2)
    except KeyboardInterrupt:
        for job in engine.jobs.values():
            job.stop.set()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
