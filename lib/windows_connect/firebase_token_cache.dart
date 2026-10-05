/// Memory-only Firebase ID tokens. Licence and tenant checks still run on the
/// server for every operation; this only avoids redundant token exchanges.
class FirebaseTokenCache {
  String? _identity;
  String? _token;
  int _expiresAt = 0;
  Future<String>? _pending;
  int _generation = 0;

  void clear() {
    _generation++;
    _identity = null;
    _token = null;
    _expiresAt = 0;
    _pending = null;
  }

  Future<String> get(String identity,
      Future<({String token, int expiresAt})> Function() refresh,
      {int? now}) {
    if (_identity != identity) { clear(); _identity = identity; }
    final time = now ?? DateTime.now().millisecondsSinceEpoch;
    if (_token != null && _expiresAt > time + 60000) return Future.value(_token);
    if (_pending != null) return _pending!;
    final generation = _generation;
    final future = refresh().then((value) {
      if (generation != _generation) throw StateError('School changed during token refresh.');
      _token = value.token;
      _expiresAt = value.expiresAt;
      return value.token;
    });
    _pending = future;
    return future.whenComplete(() { if (generation == _generation) _pending = null; });
  }
}
