import 'dart:convert';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      responseDataCallback: (data) {
        if (data == null) throw StateError('Missing Android TEST evidence');
        print('VS_ANDROID_OS_EVIDENCE ${jsonEncode(data)}');
      },
    );
