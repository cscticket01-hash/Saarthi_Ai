import 'package:flutter/material.dart';

Future<bool> confirmSchoolPayment(
  BuildContext context, {
  required String name,
  required bool collecting,
  required String amount,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Payment'),
        content: Text(
          'Are you sure you want to ${collecting ? 'collect this payment from' : 'make this payment to'} $name?\n\nAmount: $amount\n\nOnce confirmed, this payment cannot be changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Payment'),
          ),
        ],
      ),
    ) ==
    true;
