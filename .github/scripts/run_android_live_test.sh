#!/usr/bin/env bash
# Isolated TEST runner: credentials stay in private emulator app storage.
set -euo pipefail
flutter build apk --debug -t integration_test/sync_v2_android_live_test.dart --dart-define=VS_TEST_CONNECT_CONFIRM=vs-db8afb01a3be46a983c8284714d06e5d --dart-define=VS_TEST_RUN_ID=$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT --dart-define=SAARTHI_MANAGED_ACCOUNTS=true --dart-define=SAARTHI_SCHOOL_CLOUD_URL=https://saarthi-sync-v2-test.onrender.com/school-cloud
adb install -r build/app/outputs/flutter-apk/app-debug.apk
test_package="$(python -c 'import json; print(json.load(open("android/app/google-services.json"))["client"][0]["client_info"]["android_client_info"]["package_name"])')"
[[ "$test_package" =~ ^[a-zA-Z0-9_.]+$ ]]
adb shell "run-as $test_package sh -c 'mkdir -p files && cat > files/vs_test_credentials.json'" < "$RUNNER_TEMP/vs-android-test.json"
test_log="$RUNNER_TEMP/vs-android-native.log"
set +e
flutter test integration_test/sync_v2_android_live_test.dart -d emulator-5554 --dart-define=VS_TEST_CONNECT_CONFIRM=vs-db8afb01a3be46a983c8284714d06e5d --dart-define=VS_TEST_RUN_ID=$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT --dart-define=SAARTHI_MANAGED_ACCOUNTS=true --dart-define=SAARTHI_SCHOOL_CLOUD_URL=https://saarthi-sync-v2-test.onrender.com/school-cloud 2>&1 | tee "$test_log"
android_result=${PIPESTATUS[0]}
mkdir -p build/cloud-prerequisites
# flutter test removes the package on exit. Capture the exact native evidence
# printed after the app's flushed evidence write, rather than reading a removed package.
python - "$test_log" <<'PYPROOF'
import json,sys,pathlib
lines=pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines()
proofs=[json.loads(line.split('VS_ANDROID_OS_EVIDENCE ',1)[1]) for line in lines if 'VS_ANDROID_OS_EVIDENCE {' in line]
if len(proofs)!=1: raise SystemExit('Expected exactly one native Android evidence envelope')
proof=proofs[0]
if proof.get('schoolId')!='vs-db8afb01a3be46a983c8284714d06e5d' or proof.get('status')!='PASS' or proof.get('nativeCloudChecks')!='PASS':
  raise SystemExit('Native Android did not prove a successful isolated cloud check')
pathlib.Path('build/cloud-prerequisites/android-os.json').write_text(json.dumps(proof))
PYPROOF
proof_result=$?
rm -f "$test_log"
if [ "$android_result" -ne 0 ]; then exit "$android_result"; fi
if [ "$proof_result" -ne 0 ]; then exit "$proof_result"; fi
exit "$android_result"
