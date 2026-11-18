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
  testWidgets('landing shows only Windows and Android download cards',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: DeveloperLoginShell(
          form: Text('Login only'),
        ),
      ),
    );

    expect(find.text('Get Saarthi AI Apps'), findsOneWidget);
    expect(find.text('Windows App'), findsOneWidget);
    expect(find.text('Android App'), findsOneWidget);
    expect(find.text('Web Version'), findsNothing);
    expect(find.text('Sign up'), findsNothing);
    expect(find.text('97% Done'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

}
