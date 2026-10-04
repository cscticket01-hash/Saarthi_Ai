"""Check the working dashboard, a real local run, responsive layout and no fake PASS."""
import tempfile
import threading
import time
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from playwright.sync_api import sync_playwright
from saarthi_lab.engine import Engine, SCENARIOS
from saarthi_lab.server import LabServer


def main():
    with tempfile.TemporaryDirectory() as directory:
        engine=Engine(Path(directory))
        server=LabServer(engine,Path(__file__).parent.parent/"saarthi_lab")
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        errors=[]
        output=Path("test-results");output.mkdir(exist_ok=True)
        try:
            with sync_playwright() as p:
                browser=p.chromium.launch(headless=True)
                page=browser.new_page(viewport={"width":1440,"height":1100})
                page.on("pageerror",lambda e:errors.append(str(e)))
                page.goto(server.origin)
                page.get_by_label("Select Student attendance",exact=True).wait_for()
                assert page.locator('#test-rows [data-state="PASS"]').count()==0
                assert page.locator('#test-rows [data-state="NOT RUN"]').count()==len(SCENARIOS)
                page.screenshot(path=str(output/"interface-not-run.png"),full_page=True)
                page.get_by_role('button',name='Run selected tests',exact=True).click()
                page.locator('#test-rows [data-state="BLOCKED"]').wait_for()
                assert page.locator('#test-rows [data-state="PASS"]').count()==0
                page.get_by_role('button',name='Student base',exact=True).click()
                page.get_by_role('button',name='Export student CSV',exact=True).wait_for()
                page.get_by_role('button',name='Test console',exact=True).click()
                page.get_by_role('button',name='Generate / resume base',exact=True).click()
                deadline=time.monotonic()+60
                while not engine.dataset.stats()["ready"] and time.monotonic()<deadline: time.sleep(.05)
                assert engine.dataset.stats()["count"]==100000
                page.locator('#base-status').filter(has_text='READY').wait_for()
                page.get_by_label('Select Student attendance',exact=True).uncheck()
                page.get_by_label('Select Student-base search',exact=True).check()
                page.locator('#student-count').fill('37')
                page.locator('#rate').fill('0')
                page.get_by_role('button',name='Run selected tests',exact=True).click()
                page.locator('#test-rows [data-state="PASS"]').wait_for()
                assert next(j for j in engine.snapshots() if j['scenario']=='base_search')['completed']==37
                page.screenshot(path=str(output/"interface-measured-local-run.png"),full_page=True)
                page.set_viewport_size({"width":390,"height":1100})
                page.screenshot(path=str(output/"interface-mobile-width.png"),full_page=True)
                assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
                assert not errors,errors
                browser.close()
        finally:
            server.shutdown();server.server_close();thread.join(timeout=2)


if __name__=='__main__':main()
