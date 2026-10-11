import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import '../lib/health/health_reporter.dart';
import '../lib/health/health_transport.dart';

void main() {
  test('temporary diagnostic transport failures retain recovery admission', () {
    for (final error in <Object>[
      TimeoutException('synthetic timeout'),
      const SocketException('synthetic disconnected path'),
      http.ClientException('synthetic network failure'),
    ]) {
      expect(healthTransportFailure(error), HealthSendResult.retryable);
    }
  });
  test('unknown and invalid diagnostic failures remain attention', () {
    for (final error in <Object>[
      StateError('synthetic authorization or school change'),
      const FormatException('synthetic malformed response'),
      ArgumentError('synthetic invalid configuration'),
    ]) {
      expect(healthTransportFailure(error), HealthSendResult.attention);
    }
  });
}
