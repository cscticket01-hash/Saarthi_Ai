import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/id_card_designer.dart';
import '../lib/id_card_designer_screen.dart';

Map<String, dynamic> manifest({bool narrow = false}) => {
  'version': 1,
  'id': 'test',
  'canvasWidth': 100,
  'canvasHeight': 100,
  'printWidthMm': 54,
  'printHeightMm': 54,
  'regions': [
    {
      'key': 'name',
      'side': 'front',
      'kind': 'text',
      'x': narrow ? 99.8 : 10,
      'y': 10,
      'width': narrow ? 0.2 : 50,
      'height': 20,
    },
    {
      'key': 'back',
      'side': 'back',
      'kind': 'text',
      'x': 10,
      'y': 10,
      'width': 50,
      'height': 20,
    },
  ],
};
void main() {
  testWidgets('valid narrow edge region does not crash slider range', (
    tester,
  ) async {
    final editor = IdCardDesigner(
      schoolId: 'school',
      manifest: manifest(narrow: true),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: IdCardDesignerScreen(designer: editor, onSave: (_) async {}),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('designer-front-name')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('draft save is school scoped and reports storage failures', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    final editor = IdCardDesigner(schoolId: 'school', manifest: manifest());
    await tester.pumpWidget(
      MaterialApp(
        home: IdCardDesignerScreen(
          designer: editor,
          onSave: (value) async {
            saved = value;
            throw StateError('offline');
          },
        ),
      ),
    );
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(saved?['schoolId'], 'school');
    expect(find.textContaining('Draft could not be saved'), findsOneWidget);
    expect(find.text('Save draft'), findsOneWidget);
  });
}
