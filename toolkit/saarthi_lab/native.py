"""Optional real browser/Windows/Android runners. Missing tools never mean PASS."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from .dataset import Cancelled
from .transport import Blocked, RemoteError, validate_url


def run_native(job, config, directory):
    artifact_dir = Path(directory) / "captures" / job.id
    artifact_dir.mkdir(parents=True, exist_ok=True)
    if job.scenario == "web_ui":
        _web(job, config["web"], artifact_dir)
    elif job.scenario == "windows_ui":
        _windows(job, config["windows"], artifact_dir)
    else:
        _android(job, config["android"], artifact_dir)


def _check_stop(job):
    if job.stop.is_set():
        raise Cancelled("Device/browser scenario stopped")


def _web(job, config, artifacts):
    if job.config["concurrency"] != 1:
        raise Blocked("Browser screen tests currently use one browser worker; set concurrency to 1")
    url = validate_url(config.get("url", ""), allow_loopback=True)
    expected = str(config.get("expected_selector", "")).strip()
    if not expected:
        raise Blocked("Set a browser success selector; a page opening alone does not prove success")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as error:
        raise Blocked("Install the browser runner: pip install -r requirements-web.txt, then python -m playwright install chromium") from error
    job.source = url + " · actual Chromium browser"
    job.phase = "Running browser journeys"
    with sync_playwright() as playwright:
        try:
            browser = playwright.chromium.launch(headless=bool(config.get("headless", False)))
        except Exception as error:
            raise Blocked("Chromium is not installed. Use Connections → Install browser runner") from error
        try:
            for index in range(job.config["count"]):
                _check_stop(job)
                context = browser.new_context()
                page = context.new_page()
                page.set_default_timeout(job.config["timeout"] * 1000)
                tick = time.perf_counter()
                success, error = False, ""
                try:
                    page.goto(url, wait_until="domcontentloaded")
                    if config.get("email"):
                        page.get_by_label(config.get("email_label", "Developer ID / Email"), exact=True).fill(config["email"])
                        page.get_by_label(config.get("password_label", "Password"), exact=True).fill(config.get("password", ""))
                        page.get_by_role("button", name=config.get("login_button", "Sign in"), exact=True).click()
                    for step in config.get("steps", []):
                        _check_stop(job)
                        locator = page.locator(step["selector"])
                        if step["action"] == "click":
                            locator.click()
                        elif step["action"] == "fill":
                            locator.fill(str(step.get("value", "")))
                        elif step["action"] == "assert_text":
                            observed = locator.inner_text()
                            if str(step["value"]) not in observed:
                                raise RemoteError("Browser text assertion failed")
                        else:
                            raise ValueError("Unsupported browser action")
                    page.locator(expected).wait_for(state="visible")
                    success = True
                    job.metrics["last_dom_loaded_ms"] = page.evaluate("performance.getEntriesByType('navigation')[0]?.domContentLoadedEventEnd ?? null")
                except Exception as exc:
                    error = "Browser assertion or navigation failed: " + type(exc).__name__
                finally:
                    # Capture only the first journey and failed journeys, not 100,000 screenshots.
                    if index == 0 or not success:
                        page.screenshot(path=str(artifacts / f"browser-{index + 1}.png"))
                    context.close()
                job.record(time.perf_counter() - tick, success, error, index + 1)
        finally:
            browser.close()
    job.peak_concurrency = 1
    job.check("Verified browser journeys", job.config["count"], job.succeeded, job.succeeded == job.config["count"])
    _sla(job)


def _windows(job, config, artifacts):
    if os.name != "nt":
        raise Blocked("Run the Windows screen runner on a Windows PC")
    executable = Path(str(config.get("exe", "")))
    if not executable.is_file() or executable.suffix.lower() != ".exe":
        raise Blocked("Select the test-copy Windows EXE")
    steps = config.get("steps", [])
    if not steps or not any(s.get("action") in ("assert_text", "wait") for s in steps):
        raise Blocked("Configure Windows UI steps with a success assertion")
    try:
        import psutil
        from pywinauto.application import Application
    except ImportError as error:
        raise Blocked("Install the Windows runner with requirements-windows.txt") from error
    isolated = artifacts / "isolated-profile"
    roaming, local = isolated / "Roaming", isolated / "Local"
    roaming.mkdir(parents=True, exist_ok=True)
    local.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment.update(APPDATA=str(roaming), LOCALAPPDATA=str(local))
    process = subprocess.Popen([str(executable), *map(str, config.get("args", []))], cwd=executable.parent, env=environment)
    monitor_stop = threading.Event()
    peak = [None]
    def monitor():
        while not monitor_stop.wait(.05):
            try:
                memory = psutil.Process(process.pid).memory_info().rss
                peak[0] = max(peak[0] or 0, memory)
            except psutil.Error:
                break
    threading.Thread(target=monitor, daemon=True).start()
    job.source = str(executable) + " · isolated APPDATA/LOCALAPPDATA"
    job.phase = "Running Windows UI assertions"
    try:
        app = Application(backend="uia").connect(process=process.pid, timeout=job.config["timeout"])
        window = app.window(title_re=config.get("window_title", ".*"))
        window.wait("visible", timeout=job.config["timeout"])
        for number, step in enumerate(steps, 1):
            _check_stop(job)
            tick = time.perf_counter()
            success, error = False, ""
            try:
                selector = {k: step[k] for k in ("title", "auto_id", "control_type", "title_re") if step.get(k)}
                if not selector:
                    raise ValueError("Windows action needs an accessible control selector")
                control = window.child_window(**selector)
                control.wait("visible", timeout=job.config["timeout"])
                if step["action"] == "click":
                    control.click_input()
                elif step["action"] == "fill":
                    control.set_edit_text(str(step.get("value", "")))
                elif step["action"] == "assert_text":
                    if str(step["value"]) not in control.window_text():
                        raise RemoteError("Windows control text assertion failed")
                elif step["action"] != "wait":
                    raise ValueError("Unsupported Windows UI action")
                success = True
            except Exception as exc:
                error = "Windows UI step failed: " + type(exc).__name__
            job.record(time.perf_counter() - tick, success, error, number)
            if not success:
                break
        window.capture_as_image().save(artifacts / "windows.png")
        job.metrics["peak_process_memory_bytes"] = peak[0]
        job.metrics["isolation"] = "Child process uses a separate profile; native credential stores/licensing still require a test build or VM"
        job.check("All Windows scenario steps completed", len(steps), job.completed, job.completed == len(steps))
        job.check("Successful Windows UI assertions", len(steps), job.succeeded, job.succeeded == len(steps))
        _sla(job)
    finally:
        monitor_stop.set()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()


def _android(job, config, artifacts):
    adb = config.get("adb") or shutil.which("adb")
    serial = str(config.get("serial", "")).strip()
    component = str(config.get("component", "")).strip()
    if not adb or not serial or not re.fullmatch(r"[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+", component):
        raise Blocked("Set ADB, the exact device serial, and the test app's package/activity")
    steps = config.get("steps", [])
    if not any(s.get("action") in ("assert_text", "assert_resource") for s in steps):
        raise Blocked("Android screen tests need at least one UI success assertion")
    def command(*args, binary=False):
        result = subprocess.run([str(adb), "-s", serial, *map(str, args)],
                                capture_output=True, timeout=job.config["timeout"], check=True)
        return result.stdout if binary else result.stdout.decode("utf-8", errors="replace")
    devices = subprocess.run([str(adb), "devices"], capture_output=True, text=True, timeout=10, check=True).stdout
    if not re.search(r"^" + re.escape(serial) + r"\s+device\s*$", devices, re.M):
        raise Blocked("The selected Android device is absent, offline or has not allowed USB debugging")
    apk = str(config.get("apk", "")).strip()
    if apk:
        if not Path(apk).is_file():
            raise Blocked("The selected test APK does not exist")
        output = command("install", "-r", "-t", apk)
        if "Success" not in output:
            raise RemoteError("Android test APK installation failed")
    launch = command("shell", "am", "start", "-W", "-n", component)
    if "Error:" in launch or "Status: ok" not in launch:
        raise RemoteError("Android app launch was not confirmed")
    for metric in ("ThisTime", "TotalTime", "WaitTime"):
        match = re.search(r"^" + metric + r":\s*(\d+)", launch, re.M)
        if match:
            job.metrics["android_" + metric.lower() + "_ms"] = int(match.group(1))
    job.source = serial + " · actual Android device/emulator"
    job.phase = "Running Android UI assertions"
    def nodes():
        command("shell", "uiautomator", "dump", "/sdcard/saarthi-toolkit-ui.xml")
        xml = command("exec-out", "cat", "/sdcard/saarthi-toolkit-ui.xml")
        return list(ET.fromstring(xml).iter("node"))
    for number, step in enumerate(steps, 1):
        _check_stop(job)
        tick = time.perf_counter()
        success, error = False, ""
        try:
            action = step["action"]
            if action == "tap":
                command("shell", "input", "tap", int(step["x"]), int(step["y"]))
            elif action == "keyevent":
                command("shell", "input", "keyevent", int(step["key"]))
            elif action in ("assert_text", "assert_resource", "tap_resource"):
                current = nodes()
                if action == "assert_text":
                    found = [n for n in current if str(step["value"]) in (n.get("text", "") + n.get("content-desc", ""))]
                else:
                    found = [n for n in current if n.get("resource-id") == step["value"]]
                if not found:
                    raise RemoteError("Expected Android UI element was not found")
                if action == "tap_resource":
                    bounds = re.findall(r"\d+", found[0].get("bounds", ""))
                    if len(bounds) != 4:
                        raise RemoteError("Android element has no tap bounds")
                    left, top, right, bottom = map(int, bounds)
                    command("shell", "input", "tap", (left + right) // 2, (top + bottom) // 2)
            else:
                raise ValueError("Unsupported Android UI action")
            success = True
        except Exception as exc:
            error = "Android UI step failed: " + type(exc).__name__
        job.record(time.perf_counter() - tick, success, error, number)
        if not success:
            break
    (artifacts / "android.png").write_bytes(command("exec-out", "screencap", "-p", binary=True))
    memory = command("shell", "dumpsys", "meminfo", component.split("/")[0])
    match = re.search(r"TOTAL PSS:\s*(\d+)", memory)
    if match:
        job.metrics["android_process_pss_kb"] = int(match.group(1))
    job.check("All Android scenario steps completed", len(steps), job.completed, job.completed == len(steps))
    job.check("Successful Android UI assertions", len(steps), job.succeeded, job.succeeded == len(steps))
    _sla(job)


def _sla(job):
    from .jobs import percentile
    observed = percentile(job.latencies, 95)
    if observed is not None:
        job.check("P95 journey/step time (ms)", "≤ " + str(job.config["max_p95_ms"]), round(observed, 3), observed <= job.config["max_p95_ms"])
