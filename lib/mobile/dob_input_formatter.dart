import 'package:flutter/services.dart';

/// DD/MM/YYYY input, including pasted digits and predictable caret position.
/// Converts digits only; date validity is verified by the existing login API.
class DateOfBirthInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    final dateDigits = digits.length > 8 ? digits.substring(0, 8) : digits;
    final buffer = StringBuffer();
    for (var i = 0; i < dateDigits.length; i++) {
      if (i == 2 || i == 4) buffer.write('/');
      buffer.write(dateDigits[i]);
    }
    if (dateDigits.length == 2 || dateDigits.length == 4) buffer.write('/');
    final formatted = buffer.toString();
    final safeEnd = newValue.selection.extentOffset.clamp(0, raw.length);
    final prefix = raw.substring(0, safeEnd).replaceAll(RegExp(r'\D'), '');
    final cursorDigits = prefix.length.clamp(0, dateDigits.length);
    var offset = cursorDigits + (cursorDigits >= 2 ? 1 : 0) + (cursorDigits >= 4 ? 1 : 0);
    if (offset > formatted.length) offset = formatted.length;
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: offset));
  }
}
