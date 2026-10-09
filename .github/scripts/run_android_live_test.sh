#!/usr/bin/env bash
# Isolated TEST runner: credentials stay in private emulator app storage.
set -euo pipefail
flutter build apk --debug -t integration_test/sync_v2_android_live_test.dart --dart-define=VS_TEST_CONNECT_CONFIRM=vs-db8afb01a3be46a983c8284714d06e5d --dart-define=VS_TEST_RUN_ID=$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT --dart-define=SAARTHI_MANAGED_ACCOUNTS=true --dart-define=SAARTHI_SCHOOL_CLOUD_URL=https://saarthi-sync-v2-test.onrender.com/school-cloud
adb install -r build/app/outputs/flutter-apk/app-debug.apk
test_package="$(python -c 'import json; print(json.load(open("android/app/google-services.json"))["client"][0]["client_info"]["android_client_info"]["package_name"])')"
[[ "$test_package" =~ ^[a-zA-Z0-9_.]+$ ]]
adb shell "run-as $test_package sh -c 'cat > files/vs_test_credentials.json'" < "$RUNNER_TEMP/vs-android-test.json"
set +e
flutter test integration_test/sync_v2_android_live_test.dart -d emulator-5554 --dart-define=VS_TEST_CONNECT_CONFIRM=vs-db8afb01a3be46a983c8284714d06e5d --dart-define=VS_TEST_RUN_ID=$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT --dart-define=SAARTHI_MANAGED_ACCOUNTS=true --dart-define=SAARTHI_SCHOOL_CLOUD_URL=https://saarthi-sync-v2-test.onrender.com/school-cloud
android_result=$?
mkdir -p build/cloud-prerequisites
adb shell run-as "$test_package" cat files/vs_android_evidence.json > build/cloud-prerequisites/android-os.json
exit "$android_result"
