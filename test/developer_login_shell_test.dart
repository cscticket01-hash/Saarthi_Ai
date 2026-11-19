import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/developer_login_shell.dart';
import '../lib/developer_account_widgets.dart';
import '../lib/website_installer_transfer.dart';

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
    expect(find.text('The browser manages file transfer progress after download starts.'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both installer cards can be cancelled separately with real progress',
      (tester) async {
    final sessions = <_FakeInstallerTransfer>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppDownloadButtons(
          createTransfer: () {
            final session = _FakeInstallerTransfer();
            sessions.add(session);
            return session;
          },
        ),
      ),
    ));

    final windows = find.byKey(const ValueKey('Windows App-action'));
    final android = find.byKey(const ValueKey('Android App-action'));
    expect(find.text('The browser manages file transfer progress after download starts.'), findsNothing);
    await tester.tap(windows);
    await tester.pump();
    expect(sessions.length, 1);
    expect(sessions[0].url, contains('/downloads/windows.exe'));
    expect(find.text('Cancel'), findsOneWidget);

    sessions[0].progress(8 * 1024 * 1024, 16 * 1024 * 1024);
    await tester.pump();
    expect(find.text('8.0 MB / 16.0 MB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(android);
    await tester.pump();
    expect(sessions.length, 2);
    expect(sessions[1].url, contains('/downloads/android.apk'));
    expect(find.text('Cancel'), findsNWidgets(2));

    await tester.tap(windows);
    await tester.pump();
    expect(sessions[0].cancelled, true);
    expect(sessions[1].cancelled, false);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(android);
    await tester.pump();
    expect(sessions[1].cancelled, true);
    expect(find.text('Cancel'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('Cancel resets the button before browser abort event arrives',
      (tester) async {
    final sessions = <_FakeInstallerTransfer>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppDownloadButtons(
          createTransfer: () {
            final session = _FakeInstallerTransfer()
              ..deferAbortAcknowledgement = true;
            sessions.add(session);
            return session;
          },
        ),
      ),
    ));
    final windows = find.byKey(const ValueKey('Windows App-action'));
    await tester.tap(windows);
    await tester.pump();
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(windows);
    await tester.pump();
    expect(sessions[0].cancelled, true);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Download'), findsNWidgets(2));
    sessions[0].progress(4096, 8192);
    sessions[0].completed();
    sessions[0].onCancelled();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Installer received. Check the browser save prompt.'),
        findsNothing);
  });

}

class _FakeInstallerTransfer implements WebsiteInstallerTransfer {
  bool cancelled = false;
  bool deferAbortAcknowledgement = false;
  String? url;
  late void Function(int, int?) progress;
  late void Function() onCancelled;
  late void Function() completed;

  @override
  void start({
    required String url,
    required String filename,
    required void Function(int downloadedBytes, int? totalBytes) onProgress,
    required void Function() onTransferred,
    required void Function() onCancelled,
    required void Function(String error) onFailure,
  }) {
    this.url = url;
    progress = onProgress;
    this.onCancelled = onCancelled;
    completed = onTransferred;
  }

  @override
  void cancel() {
    cancelled = true;
    if (!deferAbortAcknowledgement) onCancelled();
  }
}
