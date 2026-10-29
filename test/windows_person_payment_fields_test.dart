import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_person_fields.dart';
import '../lib/windows_payment_confirmation.dart';

void main() {
  test('birth date parsing rejects calendar overflow', () {
    expect(parsePersonBirthDate('29/02/2024'), DateTime(2024, 2, 29));
    expect(parsePersonBirthDate('29/02/2023'), isNull);
    expect(parsePersonBirthDate('31/04/2020'), isNull);
  });
  testWidgets('DOB calendar opens on saved date; cancel preserves original', (
    tester,
  ) async {
    final controller = TextEditingController(text: '03/05/2010');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WindowsDateOfBirthField(controller: controller)),
      ),
    );
    await tester.tap(find.byTooltip('Select date of birth'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.text, '03/05/2010');
    await tester.tap(find.byTooltip('Select date of birth'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(controller.text, '03/05/2010');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  for (final collecting in [true, false]) {
    testWidgets(
      'payment ${collecting ? 'collection' : 'salary'} requires explicit confirmation',
      (tester) async {
        var writes = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () async {
                    if (await confirmSchoolPayment(
                      context,
                      name: 'Person One',
                      collecting: collecting,
                      amount: '₹100',
                    ))
                      writes++;
                  },
                  child: const Text('Pay'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Pay'));
        await tester.pumpAndSettle();
        expect(writes, 0);
        expect(
          find.textContaining(
            'Once confirmed, this payment cannot be changed.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(writes, 0);
        await tester.tap(find.text('Pay'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm Payment'));
        await tester.pumpAndSettle();
        expect(writes, 1);
      },
    );
  }
}
