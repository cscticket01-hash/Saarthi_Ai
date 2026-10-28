import 'windows_appearance.dart';
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
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = FirebaseFirestore.instance.activeProfileId;
    final saved = await CentralSchoolCloud.saved();
    final school = saved['schoolId']?.toString() ?? '',
        uid = saved['uid']?.toString() ?? '';
    var source = saved['photoUrl']?.toString() ?? '';
    if (uid.isEmpty) return;
    bool own() =>
        mounted &&
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
    try {
      final token = await CentralSchoolCloud.firebaseToken();
      final response = await http
          .post(
            Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:lookup', {
              'key': platformApiKey,
            }),
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
    return OriginalGoogleProfilePhoto(bytes: bytes);
  }
}

/// Render downloaded bytes directly, including animated image codecs.
class OriginalGoogleProfilePhoto extends StatelessWidget {
  const OriginalGoogleProfilePhoto({super.key, required this.bytes});
  final Uint8List? bytes;
  @override
  Widget build(BuildContext context) {
    const empty = SizedBox(width: 68, height: 68);
    return Semantics(
      image: true,
      label: 'Google account profile photo',
      child: bytes == null
          ? empty
          : ClipOval(
              child: Image.memory(
                bytes!,
                width: 68,
                height: 68,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => empty,
              ),
            ),
    );
  }
}
