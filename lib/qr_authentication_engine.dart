import 'school_qr_link.dart';

/// Shared identity boundary. A QR identifies a person; it never grants a new
/// session without the school's credential/revocation checks.
class QrAuthenticationEngine {
  final SchoolQrCapture _capture = SchoolQrCapture();
  bool get paused => _capture.paused;
  SchoolLink? capture(String raw) => _capture.capture(raw);
  void retry() => _capture.retry();
  static String encode(Map<String, dynamic> fields) =>
      SchoolLink.encode(fields);
  static SchoolLink decode(String raw, {String? expectedSchool}) {
    final link = SchoolLink.parse(raw);
    if (expectedSchool != null && link.projectId != expectedSchool) {
      throw StateError('This ID belongs to another school.');
    }
    return link;
  }

  static void validateSession(
    SchoolLink link,
    Map<String, dynamic> session, {
    required int now,
    bool restored = false,
  }) {
    final expiry = session['expiresAt'];
    final token = session[restored ? 'schoolToken' : 'sessionToken'];
    if (expiry is! num ||
        !expiry.isFinite ||
        expiry <= now ||
        token is! String ||
        token.isEmpty) {
      throw StateError('School returned an invalid or expired login session.');
    }
    if (!restored &&
        (session['projectId'] != link.projectId ||
            (link.managed && session['schoolId'] != link.schoolId))) {
      throw StateError('School identity mismatch. Login blocked.');
    }
    final person = session['person'];
    if (person is! Map)
      throw StateError('School returned an invalid person record.');
    for (final key in [
      'personId',
      link.role == 'teacher' ? 'teacherId' : 'studentId',
    ]) {
      if (person[key] != null && person[key].toString() != link.personId) {
        throw StateError('ID and school person record do not match.');
      }
    }
    final messaging = session['messaging'];
    if (messaging != null &&
        (messaging is! Map || messaging['projectId'] != link.projectId)) {
      throw StateError('School messaging project mismatch.');
    }
  }

  static Future<Map<String, dynamic>> authenticate(
    SchoolLink link,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) verify, {
    String studentClass = '',
    String roll = '',
    String dob = '',
    int Function()? clock,
  }) async {
    final decoded = decode(link.rawQr, expectedSchool: link.projectId);
    if (decoded.role != link.role || decoded.personId != link.personId ||
        decoded.linkToken != link.linkToken || decoded.managed != link.managed ||
        decoded.endpoint != link.endpoint || decoded.scriptUrl != link.scriptUrl ||
        decoded.schoolId != link.schoolId) {
      throw StateError('QR identity changed. Scan the original ID again.');
    }
    final response = await verify({
      'role': link.role,
      'personId': link.personId,
      'linkToken': link.linkToken,
      'studentClass': studentClass,
      'rollNo': roll,
      'dob': dob,
    });
    validateSession(
      link,
      response,
      now: (clock ?? () => DateTime.now().millisecondsSinceEpoch)(),
    );
    return response;
  }
}
