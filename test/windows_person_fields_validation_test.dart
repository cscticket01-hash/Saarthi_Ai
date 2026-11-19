import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_person_fields.dart';

void main() {
  test('student, teacher and staff names accept letters, not digits', () {
    expect(validWindowsPersonName('Mohit Das'), isTrue);
    expect(validWindowsPersonName('মোহিত দাস'), isTrue);
    expect(validWindowsPersonName("Mary-Anne O'Neil"), isTrue);
    expect(validWindowsPersonName('Person 123'), isFalse);
    expect(validWindowsPersonName('123'), isFalse);
    expect(validWindowsPersonName(''), isFalse);
  });

  test('Indian PIN is exactly six numeric digits', () {
    expect(validIndianPinCode('788806'), isTrue);
    expect(validIndianPinCode('78880'), isFalse);
    expect(validIndianPinCode('7888067'), isFalse);
    expect(validIndianPinCode('78AB06'), isFalse);
  });

  test('name input formatter discards digit characters', () {
    final formatter = windowsPersonNameInputFormatters.first;
    final result = formatter.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(
        text: 'Person123',
        selection: TextSelection.collapsed(offset: 9),
      ),
    );
    expect(result.text, 'Person');
  });

  testWidgets('Windows date input inserts slashes and retains date picker', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: WindowsDateOfBirthField(controller: controller),
    )));
    await tester.enterText(find.byType(TextField), '02021997');
    expect(controller.text, '02/02/1997');
    expect(find.byIcon(Icons.calendar_month_outlined), findsOneWidget);
    expect(parsePersonBirthDate(controller.text), DateTime(1997, 2, 2));
    expect(parsePersonBirthDate('31/02/1997'), isNull);
  });
}
