import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/cloudflare_save_notice.dart';
void main() {
  testWidgets('real acceptance expires after visibility without hiding errors or replaying on rebuild', (tester) async {
    final receipt = {'cloudflareAccepted':true,'operationId':'verified-operation',
      'acceptedAt':1000,'collection':'students_directory','operation':'delete','id':'synthetic'};
    Future<void> show(List<Map<String,dynamic>> rows) async {
      await tester.pumpWidget(MaterialApp(home:Column(children:[
        const Text('Unresolved provider error'), CloudflareSaveNotice(rows:rows)])));
    }
    await show([receipt]);
    expect(find.textContaining('Cloudflare saved · students_directory · delete'), findsOneWidget);
    await tester.pump(const Duration(seconds:4));
    expect(find.byKey(const ValueKey('cloudflare-save-success')), findsOneWidget);
    await tester.pump(const Duration(seconds:1));
    expect(find.byKey(const ValueKey('cloudflare-save-success')), findsNothing);
    expect(find.text('Unresolved provider error'), findsOneWidget);
    await show([receipt]);
    expect(find.byKey(const ValueKey('cloudflare-save-success')), findsNothing);
    await show([{...receipt,'acceptedAt':2000,'operationId':'second','operation':'write'}]);
    expect(find.byKey(const ValueKey('cloudflare-save-success')), findsOneWidget);
    await tester.pump(const Duration(seconds:5));
    await show([receipt]);
    expect(find.byKey(const ValueKey('cloudflare-save-success')), findsNothing);
    await show([{...receipt,'acceptedAt':3000,'operationId':'third'}]);
    expect(find.byKey(const ValueKey('cloudflare-save-success')), findsOneWidget);
    await show([]);
    expect(find.byKey(const ValueKey('cloudflare-save-success')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('unverified rows never imply Cloudflare success', (tester) async {
    await tester.pumpWidget(const MaterialApp(home:CloudflareSaveNotice(rows:[
      {'acceptedAt':1000,'operationId':'not-verified','state':'pending'},
    ])));
    expect(find.byKey(const ValueKey('cloudflare-save-success')), findsNothing);
  });
}
