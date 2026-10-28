import 'windows_appearance.dart';
import 'windows_google_profile.dart';
import 'windows_connect/google_authorization.dart';
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
  bool _connecting = false;
  int _generation = 0;
  GoogleAuthorization? _authorization;

  @override
  void dispose() {
    _generation++;
    _authorization?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() => _connecting = true);
    _generation++;
    final profile = FirebaseFirestore.instance.activeProfileId;
    try {
      final saved = await CentralSchoolCloud.saved();
      final uid = saved['uid']?.toString() ?? '';
      final school = saved['schoolId']?.toString() ?? '';
      final email = saved['email']?.toString() ?? '';
      _authorization = GoogleAuthorization();
      final account = await _authorization!.authorize(
        script: false,
        profileOnly: true,
      );
      await WindowsGoogleProfileStore().save(
        account,
        uid: uid,
        school: school,
        email: email,
        isCurrent: () async {
          final current = await CentralSchoolCloud.saved();
          return mounted &&
              FirebaseFirestore.instance.activeProfileId == profile &&
              current['uid'] == uid &&
              current['schoolId'] == school &&
              current['email'] == saved['email'];
        },
      );
      if (mounted && FirebaseFirestore.instance.activeProfileId == profile)
        await _load();
    } on SetupCancelled {
      // Keep the existing original on cancellation.
    } catch (error) {
      if (mounted && FirebaseFirestore.instance.activeProfileId == profile) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              error is StateError
                  ? error.message.toString()
                  : 'Gmail photo could not connect. Please retry.',
            ),
          ),
        );
      }
    } finally {
      _authorization?.close();
      _authorization = null;
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load().catchError((Object _) {});
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
      onConnect: _connect,
      connecting: _connecting,
    );
  }
}

/// Render downloaded bytes directly, including animated image codecs.
class OriginalGoogleProfilePhoto extends StatelessWidget {
  const OriginalGoogleProfilePhoto({
    super.key,
    required this.bytes,
    this.onConnect,
    this.connecting = false,
  });
  final VoidCallback? onConnect;
  final bool connecting;
  final Uint8List? bytes;
  @override
  Widget build(BuildContext context) {
    final empty = SizedBox(
      width: 68,
      height: 68,
      child: connecting
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(
              onPressed: onConnect,
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_a_photo_outlined, size: 20),
                  Text(
                    'Connect\nGmail photo',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
    );
    return Semantics(
      image: true,
      label: 'Google account profile photo',
      child: Tooltip(
        message: 'Connect the original Gmail profile photo',
        child: InkWell(
          onTap: connecting ? null : onConnect,
          customBorder: const CircleBorder(),
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
        ),
      ),
    );
  }
}
