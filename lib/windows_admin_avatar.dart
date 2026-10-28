import 'windows_appearance.dart';
import 'windows_google_profile.dart';
import 'windows_profile_image_policy.dart';

import 'dart:typed_data';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'platform/platform_config.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart';
import 'windows_school_image_cache.dart';

bool googleProfileImageUrl(String source) =>
    verifiedGoogleProfileImageUrl(source);

class WindowsAdminAvatar extends StatefulWidget {
  const WindowsAdminAvatar({super.key, required this.initial});
  final String initial;
  @override
  State<WindowsAdminAvatar> createState() => _WindowsAdminAvatarState();
}

class _WindowsAdminAvatarState extends State<WindowsAdminAvatar> {
  Uint8List? bytes;
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load().catchError((Object _) {});
  }

  @override
  void didUpdateWidget(covariant WindowsAdminAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial) {
      // Never carry an old account's avatar into a newly signed-in profile.
      _generation++;
      bytes = null;
      _load().catchError((Object _) {});
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final profile = FirebaseFirestore.instance.activeProfileId;
    final saved = await CentralSchoolCloud.saved();
    final school = saved['schoolId']?.toString() ?? '',
        uid = saved['uid']?.toString() ?? '';
    var source = saved['photoUrl']?.toString() ?? '';
    if (uid.isEmpty) return;
    final connectedPhoto = await WindowsGoogleProfileStore().photo(
      uid: uid,
      school: school,
      email: saved['email']?.toString() ?? '',
    );
    if (connectedPhoto.isNotEmpty) source = connectedPhoto;
    bool own() =>
        mounted &&
        generation == _generation &&
        FirebaseFirestore.instance.activeProfileId == profile &&
        FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] ==
            school;
    // Show this account's unchanged original before any network request. A
    // failed lookup or rate-limited download must not erase an offline photo.
    final cachedRows = await FirebaseFirestore.instance
        .collection('_windows_school_image_cache')
        .get();
    for (final doc in cachedRows.docs.reversed) {
      final row = doc.data();
      final fileId = row['fileId']?.toString() ?? '';
      if (row['schoolId'] != school || !adminAvatarCacheBelongsTo(fileId, uid))
        continue;
      final cached = await WindowsSchoolImageCache.read(school, fileId);
      if (!own() || (await CentralSchoolCloud.saved())['uid'] != uid) return;
      if (cached != null) {
        setState(() => bytes = cached);
        break;
      }
    }
    // Refresh only metadata from the authenticated Firebase account itself.
    if (connectedPhoto.isEmpty) {
      try {
        final token = await CentralSchoolCloud.firebaseToken();
        final response = await http
            .post(
              Uri.https(
                'identitytoolkit.googleapis.com',
                '/v1/accounts:lookup',
                {'key': platformApiKey},
              ),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'idToken': token}),
            )
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final users =
              (jsonDecode(response.body) as Map)['users'] as List? ?? [];
          if (users.length == 1 && users.first['localId'] == uid) {
            final photo = verifiedGoogleAccountPhoto(users.first as Map);
            if (photo.isNotEmpty) source = photo;
          }
        }
      } catch (_) {}
    }
    if (!googleProfileImageUrl(source) || !own()) return;
    source = originalGoogleProfileImageUrl(source);
    final key = 'admin-profile-$uid-${sha256.convert(utf8.encode(source))}';
    try {
      final cached = await WindowsSchoolImageCache.read(school, key);
      if (!own()) return;
      if (cached != null && mounted) setState(() => bytes = cached);
      final response = await http
          .get(Uri.parse(source))
          .timeout(const Duration(seconds: 12));
      if (!own() || (await CentralSchoolCloud.saved())['uid'] != uid) return;
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 20 * 1024 * 1024 ||
          !(response.headers['content-type'] ?? '').startsWith('image/'))
        return;
      // Validate without re-encoding, preserving all original animation frames.
      final codec = await ui.instantiateImageCodec(response.bodyBytes);
      codec.dispose();
      if (!own() || (await CentralSchoolCloud.saved())['uid'] != uid) return;
      setState(() => bytes = response.bodyBytes);
      await WindowsSchoolImageCache.store(
        school,
        key,
        WindowsSchoolImageCache.dataUrl(response.bodyBytes),
        profileId: profile,
      );
    } catch (_) {
      // Keep the last original when Google is temporarily unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    return OriginalGoogleProfilePhoto(
      bytes: bytes,
      initial: widget.initial,
    );
  }
}

/// Render the previously authorised Google account image as-is, including
/// animated GIF frames. An email/password login cannot silently grant Google
/// profile access: show a passive initial until a verified image is available.
class OriginalGoogleProfilePhoto extends StatelessWidget {
  const OriginalGoogleProfilePhoto({
    super.key,
    required this.bytes,
    this.initial = '',
  });

  final Uint8List? bytes;
  final String initial;

  @override
  Widget build(BuildContext context) {
    final normalized = initial.trim();
    final letter = normalized.isEmpty ? '?' : normalized.substring(0, 1).toUpperCase();
    final fallback = SizedBox(
      width: 68,
      height: 68,
      child: Center(
        child: Text(
          letter,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    return Semantics(
      image: true,
      label: bytes == null ? 'Google account avatar unavailable' : 'Google account profile photo',
      child: bytes == null
          ? fallback
          : ClipOval(
              child: Image.memory(
                bytes!,
                width: 68,
                height: 68,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => fallback,
              ),
            ),
    );
  }
}
