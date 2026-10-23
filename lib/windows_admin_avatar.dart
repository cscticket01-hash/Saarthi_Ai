import 'windows_appearance.dart';
import 'windows_profile_image_policy.dart';

import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'platform/platform_config.dart';
import 'windows_connect/google_authorization.dart';

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
  bool busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({String? preferredSource}) async {
    final profile = FirebaseFirestore.instance.activeProfileId;
    final saved = await CentralSchoolCloud.saved();
    final school = saved['schoolId']?.toString() ?? '',
        uid = saved['uid']?.toString() ?? '';
    var source = saved['photoUrl']?.toString() ?? '';
    if (uid.isEmpty) return;
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
      final users = (jsonDecode(response.body) as Map)['users'] as List? ?? [];
      if (users.length == 1 &&
          users.first['localId'] == uid &&
          googleProfileImageUrl(users.first['photoUrl']?.toString() ?? ''))
        source = users.first['photoUrl'];
    } catch (_) {}
    if (googleProfileImageUrl(preferredSource ?? '')) source = preferredSource!;
    if (!googleProfileImageUrl(source)) {
      // A password login in an older build could erase the URL while leaving
      // this same account's private cached original intact.
      final cached = await FirebaseFirestore.instance
          .collection('_windows_school_image_cache')
          .get();
      for (final doc in cached.docs) {
        final row = doc.data();
        final fileId = row['fileId']?.toString() ?? '';
        if (row['schoolId'] != school ||
            !adminAvatarCacheBelongsTo(fileId, uid))
          continue;
        final restored = await WindowsSchoolImageCache.read(school, fileId);
        if (!mounted ||
            FirebaseFirestore.instance.activeProfileId != profile ||
            (await CentralSchoolCloud.saved())['uid'] != uid)
          return;
        if (restored != null) {
          setState(() => bytes = restored);
          return;
        }
      }
      return;
    }
    final key = 'admin-profile-$uid-${sha256.convert(utf8.encode(source))}';
    bool own() =>
        FirebaseFirestore.instance.activeProfileId == profile &&
        FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] ==
            school;
    try {
      final cached = await WindowsSchoolImageCache.read(school, key);
      if (!own()) return;
      if (cached != null && mounted) setState(() => bytes = cached);
      final response = await http
          .get(Uri.parse(source))
          .timeout(const Duration(seconds: 5));
      if (!own() || (await CentralSchoolCloud.saved())['uid'] != uid) return;
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 2 * 1024 * 1024 ||
          !(response.headers['content-type'] ?? '').startsWith('image/'))
        return;
      await WindowsSchoolImageCache.store(
        school,
        key,
        WindowsSchoolImageCache.dataUrl(response.bodyBytes),
        profileId: profile,
      );
      if (mounted && own()) setState(() => bytes = response.bodyBytes);
    } catch (_) {
      /* Keep the letter fallback when Google supplies no usable image. */
    }
  }

  Future<void> _connect() async {
    if (busy) return;
    setState(() => busy = true);
    final profile = FirebaseFirestore.instance.activeProfileId;
    try {
      final before = await CentralSchoolCloud.saved();
      final account = await GoogleAuthorization().authorize(
        script: false,
        profileOnly: true,
      );
      final after = await CentralSchoolCloud.saved();
      if (profile != FirebaseFirestore.instance.activeProfileId ||
          before['uid'] != after['uid'] ||
          before['schoolId'] != after['schoolId'])
        throw StateError('School changed. Reopen settings.');
      if (account.email.toLowerCase() !=
          before['email']?.toString().toLowerCase())
        throw StateError(
          'Choose the Google account used by this administrator.',
        );
      if (!googleProfileImageUrl(account.photoUrl))
        throw StateError(
          'Google did not provide a profile image for this account.',
        );
      await CentralSchoolCloud.updateSession(before['schoolId'].toString(), {
        'photoUrl': account.photoUrl,
        'displayName': account.displayName,
      }, expectedUid: before['uid']);
      await _load(preferredSource: account.photoUrl);
      // Publish only the image returned by Google for the same verified email.
      // Password-only Firebase users then restore it on their other PCs too.
      final token = await CentralSchoolCloud.firebaseToken();
      final current = await CentralSchoolCloud.saved();
      if (!mounted ||
          FirebaseFirestore.instance.activeProfileId != profile ||
          current['uid'] != before['uid'] ||
          current['schoolId'] != before['schoolId']) {
        throw StateError('School changed. Reopen settings.');
      }
      final response = await http
          .post(
            Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:update', {
              'key': platformApiKey,
            }),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'idToken': token, 'photoUrl': account.photoUrl}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 ||
          (jsonDecode(response.body) as Map)['localId'] != before['uid']) {
        throw StateError(
          'Photo is saved on this PC, but account photo sync failed. Click to retry.',
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    final fallback = Text(
      widget.initial,
      style: TextStyle(
        color: WindowsAppearance.resolve(Colors.white),
        fontSize: 25,
        fontWeight: FontWeight.w800,
      ),
    );
    return Tooltip(
      message: 'Google profile photo • click to refresh or connect',
      child: InkWell(
        onTap: busy ? null : _connect,
        child: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : bytes == null
            ? fallback
            : ClipOval(
                child: Image.memory(
                  bytes!,
                  width: 68,
                  height: 68,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => fallback,
                ),
              ),
      ),
    );
  }
}
