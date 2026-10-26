/// Managed school reads can include a cold Apps Script execution. Keep the
/// client beyond the broker's 90-second execution window, but bounded. Queue
/// submission/status calls retain their short deadline and durable retry rules.
const schoolReadTimeout = Duration(seconds: 105);

/// Refresh ID requires two sequential reads: dashboard manifest, then PDF.
const schoolIdLoadTimeout = Duration(seconds: 225);

Duration managedSchoolRequestTimeout(String action) =>
    const {
      'mobile_complaint',
      'mobile_complaints',
      'mobile_login',
      'mobile_dashboard',
      'mobile_document',
      'mobile_attendance_list',
      'mobile_asset',
      'mobile_notice',
    }.contains(action)
    ? schoolReadTimeout
    : const Duration(seconds: 25);
