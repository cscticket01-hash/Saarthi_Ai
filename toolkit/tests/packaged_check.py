"""Runs the actual packaged EXE on the Windows Actions runner."""
import json
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


def main():
    with tempfile.TemporaryDirectory() as directory:
        with socket.socket() as socket_:
            socket_.bind(('127.0.0.1',0));port=socket_.getsockname()[1]
        process=subprocess.Popen([str(Path(sys.argv[1]).resolve()),'--no-browser','--data-dir',directory,'--port',str(port)])
        origin='http://127.0.0.1:'+str(port)
        token=None
        deadline=time.monotonic()+90
        try:
            while time.monotonic()<deadline:
                try:
                    with urllib.request.urlopen(origin,timeout=1) as response: html=response.read().decode()
                    token=re.search(r'name="lab-session" content="([^"]+)"',html).group(1)
                    req=urllib.request.Request(origin+'/api/state',headers={'X-Lab-Token':token})
                    with urllib.request.urlopen(req,timeout=3) as response: state=json.load(response)
                    if state['dataset']['ready']:
                        assert state['dataset']['count']==100000
                        break
                except (OSError,ValueError,AttributeError):pass
                time.sleep(.2)
            else:raise AssertionError('Packaged app did not generate its real 100,000 student base')
            req=urllib.request.Request(origin+'/api/backend',headers={'X-Lab-Token':token})
            with urllib.request.urlopen(req,timeout=3) as response: assert response.read(2)==b'PK'
            request=urllib.request.Request(origin+'/api/shutdown',data=b'{}',headers={'X-Lab-Token':token,'Content-Type':'application/json'})
            with urllib.request.urlopen(request,timeout=3) as response: assert json.load(response)['closing']
            process.wait(timeout=10)
            assert process.returncode==0
            print('Actual packaged EXE: 100,000 base and setup bundle verified.')
        finally:
            if process.poll() is None:process.kill();process.wait(timeout=10)


if __name__=='__main__':main()
