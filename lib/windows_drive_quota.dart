/// Quota values must come from an already-authorized owner-scoped Drive read.
/// This API never asks for broader scopes or interprets school file bytes as
/// total Google account usage (which can also include Gmail and Photos).
class WindowsDriveQuota {
  static Future<Map<String, dynamic>> measure({
    Future<Map<String, dynamic>> Function()? authorizedRead,
  }) async {
    if (authorizedRead == null)
      return {
        'status': 'Unknown',
        'reason':
            'Google account quota permission unavailable; school files are a separate measurement',
      };
    try {
      final value = await authorizedRead().timeout(const Duration(seconds: 5));
      if (value['status'] == 'Unknown')
        return {
          'status': 'Unknown',
          'reason': value['reason'] is String
              ? value['reason']
              : 'School owner quota reporting unavailable'
        };
      final usage = int.tryParse('${value['usage']}');
      final limit = int.tryParse('${value['limit']}');
      if (usage == null || usage < 0)
        throw StateError('Invalid quota response');
      if (limit == null)
        return {
          'status': 'Measured',
          'usageBytes': usage,
          'limitBytes': null,
          'reason':
              'Google reports no storage limit for this authorized account',
        };
      if (limit < 0) throw StateError('Invalid quota limit');
      return {
        'status': 'Measured',
        'usageBytes': usage,
        'limitBytes': limit,
        'availableBytes': usage >= limit ? 0 : limit - usage,
        'measuredAt': DateTime.now().millisecondsSinceEpoch,
      };
    } catch (_) {
      return {
        'status': 'Unknown',
        'reason':
            'Authorized Google quota read failed; no estimated quota shown',
      };
    }
  }
}
