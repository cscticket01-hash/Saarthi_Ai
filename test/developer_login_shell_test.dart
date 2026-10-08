import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/developer_login_shell.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(1440, 900)]) {
    testWidgets('developer login stays accessible at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var invoked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: DeveloperLoginShell(
            form: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const TextField(
                  decoration: InputDecoration(labelText: 'Email'),
                ),
                const TextField(
                  obscureText: true,
                  decoration: InputDecoration(labelText: 'Password'),
                ),
                FilledButton(
                  onPressed: () => invoked = true,
                  child: const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Sign in'));
      await tester.tap(find.text('Sign in'));
      expect(invoked, true);
      expect(tester.takeException(), isNull);
    });
  }
}
