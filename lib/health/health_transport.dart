import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'health_reporter.dart';

/// Diagnostic delivery may recover from transport outages without reauth.
/// Unknown failures remain attention: never retry business operations here.
HealthSendResult healthTransportFailure(Object error) =>
    error is TimeoutException ||
            error is SocketException ||
            error is http.ClientException
        ? HealthSendResult.retryable
        : HealthSendResult.attention;
