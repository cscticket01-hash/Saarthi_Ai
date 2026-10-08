/// Counts only a real school roster with issued QR identities and student-app
/// registrations. Saving a notice locally never qualifies as delivery.
int schoolNoticeRecipients(
  Iterable<Map<String, dynamic>> students,
  Iterable<Map<String, dynamic>> mobileUsers,
) {
  final linked = students
      .where(
        (s) =>
            RegExp(r'^[A-Za-z0-9_-]{32,128}$')
                .hasMatch(s['mobileLinkToken']?.toString() ?? ''),
      )
      .length;
  final registered = mobileUsers.where((s) => s['role'] == 'student').length;
  return linked < registered ? linked : registered;
}

class WindowsNoticeDelivery {
  const WindowsNoticeDelivery({
    required this.notificationSent,
    required this.recipients,
    this.error = '',
    this.info = '',
    this.schoolPublished = false,
  });
  final bool notificationSent;
  final bool schoolPublished;
  final int recipients;
  final String error;
  final String info;
}
