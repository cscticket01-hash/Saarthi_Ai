#!/usr/bin/env bash
# Isolated TEST runner: credentials stay in private emulator app storage.
set -euo pipefail
apk=build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --debug -t integration_test/sync_v2_android_live_test.dart --dart-define=VS_TEST_CONNECT_CONFIRM=vs-db8afb01a3be46a983c8284714d06e5d --dart-define=VS_TEST_RUN_ID=$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT --dart-define=SAARTHI_MANAGED_ACCOUNTS=true --dart-define=SAARTHI_SCHOOL_CLOUD_URL=https://saarthi-sync-v2-test.onrender.com/school-cloud
test_package="$(python -c 'import json; print(json.load(open("android/app/google-services.json"))["client"][0]["client_info"]["android_client_info"]["package_name"])')"
[[ "$test_package" =~ ^[a-zA-Z0-9_.]+$ ]]
# A single fresh app/VM discovery is required. This runner owns only this emulator.
adb -s emulator-5554 wait-for-device
adb -s emulator-5554 shell am force-stop "$test_package"
adb -s emulator-5554 forward --remove-all
adb -s emulator-5554 logcat -c
adb -s emulator-5554 install -r "$apk"
# The forwarded VM service must use loopback directly.
export NO_PROXY="${NO_PROXY:-},localhost,127.0.0.1,::1"
export no_proxy="${no_proxy:-},localhost,127.0.0.1,::1"
adb -s emulator-5554 shell "run-as $test_package sh -c 'mkdir -p files && cat > files/vs_test_credentials.json'" < "$RUNNER_TEMP/vs-android-test.json"
test_log="$RUNNER_TEMP/vs-android-native.log"
trap 'rm -f "$test_log"' EXIT
# The integration driver reads the app's result over the forwarded VM service.
# It does not subscribe to flutter test's DDS-only golden comparison stream.
set +e
timeout --signal=TERM --kill-after=30s 12m flutter drive -d emulator-5554 \
  --no-dds --no-enable-impeller --verbose --use-application-binary="$apk" \
  --target=integration_test/sync_v2_android_live_test.dart \
  --driver=integration_test/sync_v2_android_driver.dart 2>&1 | tee "$test_log"
android_result=${PIPESTATUS[0]}
if [ "$android_result" -eq 124 ] || [ "$android_result" -eq 137 ]; then
  printf '%s\n' 'VS_ANDROID_TEST_FAILURE driver_timeout'
fi
if [ "$android_result" -ne 0 ]; then exit "$android_result"; fi
mkdir -p build/cloud-prerequisites
# The host driver prints the evidence returned by the successful native test.
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
exit $?
