import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared manual DD/MM/YYYY entry with automatic separators.
class SaarthiDateInputFormatter extends TextInputFormatter {
  static final _nonDigits = RegExp(r'[^0-9]');
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) return newValue;
    var digits = newValue.text.replaceAll(_nonDigits, '');
    if (digits.length > 8) digits = digits.substring(0, 8);
    if (oldValue.text.endsWith('/') &&
        oldValue.text.substring(0, oldValue.text.length - 1) == newValue.text &&
        digits.isNotEmpty) {
      digits = digits.substring(0, digits.length - 1);
    }
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      buffer.write(digits[i]);
      if (i == 1 || i == 3) buffer.write('/');
    }
    final formatted = buffer.toString();
    final rawCursor = newValue.selection.extentOffset.clamp(0, newValue.text.length).toInt();
    final before = newValue.text.substring(0, rawCursor).replaceAll(_nonDigits, '').length;
    var cursor = 0, seen = 0;
    while (cursor < formatted.length && seen < before) {
      if (formatted[cursor] != '/') seen++;
      cursor++;
    }
    if (cursor < formatted.length && formatted[cursor] == '/') cursor++;
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: cursor));
  }
}

final postalPinInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.digitsOnly,
  LengthLimitingTextInputFormatter(6),
];

bool isValidPostalPin(String value) => RegExp(r'^[0-9]{6}

DateTime? parsePersonBirthDate(String value) {
  final parts = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$')
      .firstMatch(value.trim());
  if (parts == null) return null;
  final day = int.parse(parts[1]!),
      month = int.parse(parts[2]!),
      year = int.parse(parts[3]!);
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

class WindowsDateOfBirthField extends StatelessWidget {
  const WindowsDateOfBirthField({
    super.key,
    required this.controller,
    this.style,
    this.decoration = const InputDecoration(
      labelText: 'Date of Birth (DD/MM/YYYY)',
    ),
    this.enabled = true,
    this.isBirthDate = true,
  });
  final TextEditingController controller;
  final TextStyle? style;
  final InputDecoration decoration;
  final bool enabled;
  final bool isBirthDate;
  @override
  Widget build(BuildContext context) {
    Future<void> selectDate() async {
      final today = DateUtils.dateOnly(DateTime.now());
      final first = DateTime(1900);
      final last = isBirthDate ? today : DateTime(2100, 12, 31);
      final parsed = parsePersonBirthDate(controller.text);
      final initial =
          parsed != null && !parsed.isBefore(first) && !parsed.isAfter(last)
          ? parsed
          : isBirthDate ? DateTime(today.year - 10, today.month, today.day) : today;
      final chosen = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: first,
        lastDate: last,
        helpText: isBirthDate ? 'Select date of birth' : 'Select date',
      );
      if (chosen != null && context.mounted) {
        controller.text =
            '${chosen.day.toString().padLeft(2, '0')}/${chosen.month.toString().padLeft(2, '0')}/${chosen.year}';
      }
    }

    return TextField(
      controller: controller,
      style: style,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [SaarthiDateInputFormatter()],
      decoration: decoration.copyWith(
        suffixIcon: IconButton(
          tooltip: isBirthDate ? 'Select date of birth' : 'Select date',
          onPressed: enabled ? selectDate : null,
          icon: const Icon(Icons.calendar_month_outlined),
        ),
      ),
    );
  }
}

// Validate new or changed fields while allowing unchanged legacy typos.
String normalizeTeacherPhone(dynamic value) {
  var digits = (value ?? '').toString().replaceAll(RegExp(r'\D'), '');
  if (digits.length == 12 && digits.startsWith('91')) {
    digits = digits.substring(2);
  }
  return digits;
}

String? validateTeacherOptionalFields({
  required String email,
  required String birthDate,
  required String joiningDate,
  Map<String, dynamic>? previous,
  DateTime? today,
}) {
  bool changed(String key, String value) =>
      previous == null || (previous[key]?.toString().trim() ?? '') != value.trim();
  if (changed('email', email) && email.trim().isNotEmpty &&
      !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim())) {
    return 'Enter a valid email address.';
  }
  DateTime? parse(String value) {
    final trimmed = value.trim();
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(trimmed);
    return iso == null ? parsePersonBirthDate(trimmed)
        : parsePersonBirthDate(iso[3]! + '/' + iso[2]! + '/' + iso[1]!);
  }
  final now = today ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  if (changed('dateOfBirth', birthDate) && birthDate.trim().isNotEmpty) {
    final date = parse(birthDate);
    if (date == null || date.year < 1900 || date.isAfter(day)) {
      return 'Enter a valid date of birth.';
    }
  }
  if ((changed('joiningDate', joiningDate) || changed('dateOfBirth', birthDate)) &&
      joiningDate.trim().isNotEmpty) {
    final joining = parse(joiningDate);
    final birth = parse(birthDate);
    if (joining == null || joining.year < 1900 ||
        (birth != null && joining.isBefore(birth))) {
      return 'Enter a valid joining date.';
    }
  }
  return null;
}
).hasMatch(value);


DateTime? parsePersonBirthDate(String value) {
  final parts = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$')
      .firstMatch(value.trim());
  if (parts == null) return null;
  final day = int.parse(parts[1]!),
      month = int.parse(parts[2]!),
      year = int.parse(parts[3]!);
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

class WindowsDateOfBirthField extends StatelessWidget {
  const WindowsDateOfBirthField({
    super.key,
    required this.controller,
    this.style,
    this.decoration = const InputDecoration(
      labelText: 'Date of Birth (DD/MM/YYYY)',
    ),
    this.enabled = true,
  });
  final TextEditingController controller;
  final TextStyle? style;
  final InputDecoration decoration;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    Future<void> selectDate() async {
      final today = DateUtils.dateOnly(DateTime.now());
      final first = DateTime(1900);
      final parsed = parsePersonBirthDate(controller.text);
      final initial =
          parsed != null && !parsed.isBefore(first) && !parsed.isAfter(today)
          ? parsed
          : DateTime(today.year - 10, today.month, today.day);
      final chosen = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: first,
        lastDate: today,
        helpText: 'Select date of birth',
      );
      if (chosen != null && context.mounted) {
        controller.text =
            '${chosen.day.toString().padLeft(2, '0')}/${chosen.month.toString().padLeft(2, '0')}/${chosen.year}';
      }
    }

    return TextField(
      controller: controller,
      style: style,
      enabled: enabled,
      keyboardType: TextInputType.datetime,
      decoration: decoration.copyWith(
        suffixIcon: IconButton(
          tooltip: 'Select date of birth',
          onPressed: enabled ? selectDate : null,
          icon: const Icon(Icons.calendar_month_outlined),
        ),
      ),
    );
  }
}

// Validate new or changed fields while allowing unchanged legacy typos.
String normalizeTeacherPhone(dynamic value) {
  var digits = (value ?? '').toString().replaceAll(RegExp(r'\D'), '');
  if (digits.length == 12 && digits.startsWith('91')) {
    digits = digits.substring(2);
  }
  return digits;
}

String? validateTeacherOptionalFields({
  required String email,
  required String birthDate,
  required String joiningDate,
  Map<String, dynamic>? previous,
  DateTime? today,
}) {
  bool changed(String key, String value) =>
      previous == null || (previous[key]?.toString().trim() ?? '') != value.trim();
  if (changed('email', email) && email.trim().isNotEmpty &&
      !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim())) {
    return 'Enter a valid email address.';
  }
  DateTime? parse(String value) {
    final trimmed = value.trim();
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(trimmed);
    return iso == null ? parsePersonBirthDate(trimmed)
        : parsePersonBirthDate(iso[3]! + '/' + iso[2]! + '/' + iso[1]!);
  }
  final now = today ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  if (changed('dateOfBirth', birthDate) && birthDate.trim().isNotEmpty) {
    final date = parse(birthDate);
    if (date == null || date.year < 1900 || date.isAfter(day)) {
      return 'Enter a valid date of birth.';
    }
  }
  if ((changed('joiningDate', joiningDate) || changed('dateOfBirth', birthDate)) &&
      joiningDate.trim().isNotEmpty) {
    final joining = parse(joiningDate);
    final birth = parse(birthDate);
    if (joining == null || joining.year < 1900 ||
        (birth != null && joining.isBefore(birth))) {
      return 'Enter a valid joining date.';
    }
  }
  return null;
}
