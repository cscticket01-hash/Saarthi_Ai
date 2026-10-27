import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_fee_settings_design.dart';

void main() {
  testWidgets('fees uses explicit Back at desktop and compact widths; brand does not navigate', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in [1440.0, 420.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
        body: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
          builder: (_) => WindowsFeeSettingsLayout(classes: const ['Class 1'], selectedClass: 'Class 1',
            session: '2026-2027', sessions: const ['2026-2027'], loading: false, failed: false,
            saving: false, editing: false, rows: const [], onClass: (_) {}, onSession: (_) {},
            onAdd: () {}, onChanged: () {}, onSave: () {}, onEdit: () {}, onCancel: () {}, onRetry: () {}))),
          child: const Text('Open fees'))))));
      await tester.tap(find.text('Open fees'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fees-back')), findsOneWidget);
      await tester.tap(find.text('Vidya Saarthi'));
      await tester.pumpAndSettle();
      expect(find.text('Payment Collection Settings'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fees-back')));
      await tester.pumpAndSettle();
      expect(find.text('Open fees'), findsOneWidget);
      expect(find.text('Payment Collection Settings'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('fee actions stay reachable at desktop and compact high DPI; render approved design', (tester) async {
    if (Platform.isWindows) {
      await tester.runAsync(() async {
        await (FontLoader('Segoe UI')..addFont(Future.value(ByteData.sublistView(await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes())))).load();
        await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    final names = ['Tuition Fees','Admission Fees','Registration Fees','Nobikaron Fees','Bidya Bharati Sahojog Rashi','Building Fees','Shishu Bharati Fees',''];
    final rows = <WindowsFeeEditorRow>[];
    final actions = <String>[];
    for (var i=0; i<names.length; i++) {
      final id=i;
      rows.add(WindowsFeeEditorRow(id:id,name:TextEditingController(text:names[i]),amount:TextEditingController(),onDelete:()=>actions.add('delete-$id')));
    }
    addTearDown(() async { for(final row in rows) {row.name.dispose();row.amount.dispose();} await tester.binding.setSurfaceSize(null); });
    for (final spec in [('desktop',const Size(1440,1000),1.0),('compact',const Size(420,900),1.5)]) {
      await tester.binding.setSurfaceSize(spec.$2);
      final key=GlobalKey();
      await tester.pumpWidget(MaterialApp(theme:ThemeData(brightness:Brightness.dark,fontFamily:'Segoe UI'),
        builder:(context,child)=>MediaQuery(data:MediaQuery.of(context).copyWith(textScaler:TextScaler.linear(spec.$3)),child:child!),
        home:RepaintBoundary(key:key,child:WindowsFeeSettingsLayout(classes:List.generate(12,(i)=>'Class ${i+1}'),
          selectedClass:'Class 2',session:'2026-2027',sessions:const ['2026-2027','2025-2026'],loading:false,failed:false,saving:false,editing:true,
          rows:rows,onClass:(v)=>actions.add(v),onSession:(v)=>actions.add(v),onAdd:()=>actions.add('add'),onChanged:()=>actions.add('change'),
          onSave:()=>actions.add('save'),onEdit:()=>actions.add('edit'),onCancel:()=>actions.add('cancel'),onRetry:()=>actions.add('retry')))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add fee'));expect(actions.last,'add');
      await tester.ensureVisible(find.byKey(const ValueKey('fee-name-0')));
      await tester.enterText(find.byKey(const ValueKey('fee-name-0')),'${spec.$1} Tuition');expect(actions.last,'change');
      await tester.ensureVisible(find.byKey(const ValueKey('delete-fee-0')));
      await tester.tap(find.byKey(const ValueKey('delete-fee-0')));expect(actions.last,'delete-0');
      await tester.ensureVisible(find.text('Save changes'));await tester.tap(find.text('Save changes'));expect(actions.last,'save');
      expect(tester.takeException(),isNull);
      await tester.ensureVisible(find.text('Fee details'));await tester.pumpAndSettle();
      if (Platform.isWindows) {
        await tester.runAsync(() async {
          final image=await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
          final bytes=(await image.toByteData(format:ui.ImageByteFormat.png))!.buffer.asUint8List();
          final file=File('build/fee-settings-preview/fee-settings-${spec.$1}.png');
          await file.parent.create(recursive:true);await file.writeAsBytes(bytes);image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());await tester.pumpAndSettle();
    }
  });
}
