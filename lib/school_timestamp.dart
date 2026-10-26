// Shared timestamp value; independent of native Windows storage.
class Timestamp {
  Timestamp.fromDate(DateTime value)
      : _value = value.toUtc();

  Timestamp.now()
      : _value = DateTime.now().toUtc();

  final DateTime _value;

  DateTime toDate() => _value.toLocal();

  int get millisecondsSinceEpoch =>
      _value.millisecondsSinceEpoch;
}

