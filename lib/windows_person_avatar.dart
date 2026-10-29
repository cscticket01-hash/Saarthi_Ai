import 'dart:convert';

import 'package:flutter/material.dart';

import 'windows_connect/school_drive_images.dart';
import 'windows_profile_image_policy.dart';

/// Uses the existing school-scoped image transport, including private Drive.
class WindowsPersonAvatar extends StatelessWidget {
  const WindowsPersonAvatar({
    super.key,
    required this.person,
    this.radius = 20,
    this.school = false,
  });
  final Map<String, dynamic> person;
  final double radius;
  final bool school;
  @override
  Widget build(BuildContext context) {
    final name = person['name']?.toString().trim() ?? '';
    Widget fallback() => ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Center(
        child: school || name.isEmpty
            ? Icon(school ? Icons.school : Icons.person)
            : Text(
                name.characters.first.toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
      ),
    );
    final source = school
        ? schoolProfileImageSource(person, 'logo')
        : person['photoUrl']?.toString().trim() ?? '';
    Widget fromBase64() {
      final raw =
          person[school ? 'logoBase64' : 'photoBase64']?.toString().trim() ??
          '';
      if (raw.isEmpty) return fallback();
      try {
        final bytes = raw.startsWith('data:image/')
            ? UriData.parse(raw).contentAsBytes()
            : base64Decode(raw);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback(),
        );
      } catch (_) {
        return fallback();
      }
    }

    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: ClipOval(
        child: source.isEmpty
            ? fromBase64()
            : schoolNetworkImage(
                source,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fromBase64(),
              ),
      ),
    );
  }
}
