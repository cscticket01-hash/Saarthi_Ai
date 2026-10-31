import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mobile/dob_input_formatter.dart';
import '../lib/mobile/school_session.dart';

void main() {
  final formatter = DateOfBirthInputFormatter();
  TextEditingValue type(String digits) => formatter.formatEditUpdate(
    TextEditingValue.empty,
    TextEditingValue(text: digits, selection: TextSelection.collapsed(offset: digits.length)));
  test('DOB automatically inserts DD/MM/YYYY separators and limits to eight digits', () {
    expect(type('0').text, '0');
    expect(type('02').text, '02/');
    expect(type('021').text, '02/1');
    expect(type('0212').text, '02/12/');
    expect(type('02121997').text, '02/12/1997');
    expect(type('02/12/1997').text, '02/12/1997');
    expect(type('02121997123').text, '02/12/1997');
    expect(type('02').selection.baseOffset, 3);
  });
  test('checkout defaults on for existing school, can be hidden per verified schedule', () {
    final school = SchoolSession();
    expect(school.studentCheckoutEnabled, true);
    school.dashboard = {'attendanceStatus': {'version': 1, 'schedule': {
      'enabled': true, 'startMinute': 540, 'endMinute': 600, 'checkoutEnabled': false,
    }}};
    expect(school.studentCheckoutEnabled, false);
    school.dashboard = {'attendanceStatus': {'version': 1, 'schedule': {
      'enabled': true, 'startMinute': 540, 'endMinute': 600, 'checkoutEnabled': true,
    }}};
    expect(school.studentCheckoutEnabled, true);
  });
}
