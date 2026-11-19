import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'mobile/dob_input_formatter.dart';

/// Shared entry rules for Windows student, teacher and other-staff names.
final windowsPersonNameInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r"[A-Za-z\u00C0-\u024F\u0900-\u097F\u0980-\u09FF .'-]")),
];

bool validWindowsPersonName(String text) {
  final value = text.trim();
  return value.isNotEmpty &&
      RegExp(r"^[A-Za-z\u00C0-\u024F\u0900-\u097F\u0980-\u09FF .'-]+$").hasMatch(value) &&
      RegExp(r'[A-Za-z\u00C0-\u024F\u0900-\u097F\u0980-\u09FF]').hasMatch(value);
}

bool validIndianPinCode(String text) =>
    RegExp(r'^[0-9]{6}$').hasMatch(text.trim());

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
    this.helpText = 'Select date of birth',
  });
  final TextEditingController controller;
  final TextStyle? style;
  final InputDecoration decoration;
  final bool enabled;
  final String helpText;
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
        helpText: helpText,
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
      inputFormatters: [DateOfBirthInputFormatter()],
      decoration: decoration.copyWith(
        suffixIcon: IconButton(
          tooltip: helpText,
          onPressed: enabled ? selectDate : null,
          icon: const Icon(Icons.calendar_month_outlined),
        ),
      ),
    );
  }
}
