import 'package:flutter/material.dart';

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
