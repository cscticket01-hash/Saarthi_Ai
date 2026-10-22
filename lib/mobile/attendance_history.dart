import 'dart:async';
import 'package:flutter/foundation.dart';

/// Cached, server-confirmed history. Queue confirmation automatically invalidates
/// it; an empty initial response is not fabricated before the first read finishes.
class AttendanceHistoryController extends ChangeNotifier {
  AttendanceHistoryController({
    required this.load,
    required this.cached,
    required this.confirmations,
    required this.confirmationKey,
  }) {
    _lastConfirmation = confirmationKey();
    confirmations.addListener(_confirmed);
  }
  final Future<List<Map<String, dynamic>>> Function(String) load;
  final List<Map<String, dynamic>>? Function(String) cached;
  final Listenable confirmations;
  final String Function() confirmationKey;
  String month = '', _lastConfirmation = '';
  List<Map<String, dynamic>> rows = [];
  bool ready = false, _disposed = false;
  Object? error;
  int _generation = 0;
  Future<void>? _flight;
  bool _again = false;

  void _confirmed() {
    final key = confirmationKey();
    if (key.isEmpty || key == _lastConfirmation) return;
    _lastConfirmation = key;
    // A response started before the ACK can be stale; schedule one trailing read.
    _again = _flight != null;
    unawaited(refresh());
  }

  Future<void> selectMonth(String value) {
    if (month != value) {
      _generation++;
      _flight = null;
      _again = false;
      month = value;
      final saved = cached(value);
      rows = saved ?? [];
      ready = saved != null;
      error = null;
      notifyListeners();
    }
    return refresh();
  }

  Future<void> refresh() {
    if (_disposed || month.isEmpty) return Future.value();
    if (_flight != null) return _flight!;
    final generation = _generation, selected = month;
    final pending = (() async {
      try {
        final result = await load(selected);
        if (_disposed || generation != _generation) return;
        rows = result;
        ready = true;
        error = null;
        notifyListeners();
      } catch (e) {
        if (_disposed || generation != _generation) return;
        error = e;
        notifyListeners(); // Retain known rows/ready on outages.
      }
    })();
    _flight = pending;
    return pending.whenComplete(() {
      if (_disposed ||
          generation != _generation ||
          !identical(_flight, pending))
        return;
      _flight = null;
      if (_again) {
        _again = false;
        unawaited(refresh());
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    confirmations.removeListener(_confirmed);
    super.dispose();
  }
}
