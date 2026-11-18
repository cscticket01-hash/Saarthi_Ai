"""Exercise the native runner's process/evidence gates without an emulator/cloud."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).with_name('run_android_live_test.sh')
SCHOOL = 'vs-db8afb01a3be46a983c8284714d06e5d'

class AndroidRunnerGuards(unittest.TestCase):
    def run_case(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / 'tools'
            tools.mkdir()
            (root / 'android/app').mkdir(parents=True)
            (root / 'android/app/google-services.json').write_text(json.dumps({'client':[{'client_info':{'android_client_info':{'package_name':'com.example.syncreview'}}}]}))
            (root / 'vs-android-test.json').write_text('{"private":"never-print-this"}')
            flutter = '''#!/usr/bin/env python3
import json,os,sys
if sys.argv[1]=='build':
 assert '--dart-define=VS_TEST_RUN_ID=123-2' in sys.argv
 assert '--dart-define=VS_TEST_WEBSITE_RUN_ID=123-1' in sys.argv
 sys.exit(0)
assert sys.argv[1]=='drive'
assert '--driver=integration_test/sync_v2_android_driver.dart' in sys.argv
assert '--use-application-binary=build/app/outputs/flutter-apk/app-debug.apk' in sys.argv
assert '--no-dds' in sys.argv and '--dds' not in sys.argv
assert '--no-enable-impeller' in sys.argv
assert '127.0.0.1' in os.environ['NO_PROXY']
mode=os.environ['RUNNER_GUARD_MODE']
if mode=='vm_failure':
 print('Connecting to the VM Service timed out.');sys.exit(1)
proof={'schoolId':'vs-db8afb01a3be46a983c8284714d06e5d','status':'PASS','androidRunId':'123-2','websiteRunId':'123-2' if mode=='wrong_attempt' else '123-1','nativeCloudChecks':'FAIL' if mode=='bad_cloud' else 'PASS'}
print('VS_ANDROID_OS_EVIDENCE '+json.dumps(proof))
if mode=='duplicate': print('VS_ANDROID_OS_EVIDENCE '+json.dumps(proof))
sys.exit(1 if mode=='failed_test_with_proof' else 0)
'''
            (tools / 'flutter').write_text(flutter)
            (tools / 'adb').write_text('#!/bin/sh\ncase "$*" in *run-as*) cat >/dev/null;; esac\nexit 0\n')
            (tools / 'timeout').write_text('#!/bin/sh\nshift 3\nexec "$@"\n')
            for tool in tools.iterdir(): tool.chmod(0o700)
            env={**os.environ,'PATH':str(tools)+os.pathsep+os.environ['PATH'],'RUNNER_TEMP':str(root),'GITHUB_RUN_ID':'123','GITHUB_RUN_ATTEMPT':'2','VS_TEST_WEBSITE_RUN_ID':'456-1' if mode=='foreign_website' else '123-1','RUNNER_GUARD_MODE':mode}
            result=subprocess.run(['bash',str(RUNNER)],cwd=root,env=env,capture_output=True,text=True,timeout=15)
            proof=root/'build/cloud-prerequisites/android-os.json'
            self.assertNotIn('never-print-this',result.stdout+result.stderr)
            self.assertFalse((root/'vs-android-native.log').exists())
            return result.returncode, json.loads(proof.read_text()) if proof.exists() else None

    def test_real_success_requires_native_cloud_pass(self):
        code, proof=self.run_case('pass')
        self.assertEqual(code,0);self.assertEqual(proof['schoolId'],SCHOOL)

    def test_vm_connection_failure_cannot_produce_success(self):
        code,proof=self.run_case('vm_failure')
        self.assertNotEqual(code,0);self.assertIsNone(proof)

    def test_native_failure_and_duplicate_evidence_fail_closed(self):
        for mode in ['bad_cloud','duplicate','wrong_attempt','foreign_website']:
            with self.subTest(mode=mode):
                code,proof=self.run_case(mode)
                self.assertNotEqual(code,0);self.assertIsNone(proof)

    def test_failed_process_cannot_be_hidden_by_pass_envelope(self):
        code,proof=self.run_case('failed_test_with_proof')
        self.assertNotEqual(code,0);self.assertIsNone(proof)

if __name__=='__main__': unittest.main()
