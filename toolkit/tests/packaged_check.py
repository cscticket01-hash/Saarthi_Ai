"""Runs the actual packaged EXE on the Windows Actions runner."""
import json
import os
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
        deadline=time.monotonic()+300
        last_state=None;last_count=-1;last_error=''
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            while time.monotonic()<deadline:
                if process.poll() is not None:
                    raise AssertionError('Packaged app exited before verification: '+str(process.returncode))
                try:
                    with opener.open(origin,timeout=1) as response: html=response.read().decode()
                    token=re.search(r'name="lab-session" content="([^"]+)"',html).group(1)
                    req=urllib.request.Request(origin+'/api/state',headers={'X-Lab-Token':token})
                    with opener.open(req,timeout=3) as response: state=json.load(response)
                    last_state=state
                    if state['dataset']['count']!=last_count:
                        last_count=state['dataset']['count']
                        print('Actual persisted identities: '+str(last_count),flush=True)
                    if any(j['state']=='FAIL' for j in state['jobs']):
                        raise AssertionError('Packaged generation failed: '+json.dumps(state['jobs']))
                    if state['dataset']['ready'] and not any(j['state']=='RUNNING' for j in state['jobs']):
                        assert state['dataset']['count']==100000
                        break
                except (OSError,ValueError,AttributeError) as error:last_error=str(error)
                time.sleep(.2)
            else:raise AssertionError('Packaged app did not finish its actual base; last count='+str(last_count)+'; error='+last_error)
            req=urllib.request.Request(origin+'/api/backend',headers={'X-Lab-Token':token})
            with opener.open(req,timeout=3) as response: assert response.read(2)==b'PK'
            request=urllib.request.Request(origin+'/api/shutdown',data=b'{}',headers={'X-Lab-Token':token,'Content-Type':'application/json'})
            with opener.open(request,timeout=3) as response: assert json.load(response)['closing']
            process.wait(timeout=10)
            assert process.returncode==0
            print('Actual packaged EXE: 100,000 base and setup bundle verified.')
        finally:
            if process.poll() is None:
                if os.name=='nt':
                    # PyInstaller's one-file parent has a child. Stop only this
                    # test's process tree so failed checks cannot leak a writer.
                    subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],capture_output=True)
                else:process.kill()
                process.wait(timeout=10)


if __name__=='__main__':main()
