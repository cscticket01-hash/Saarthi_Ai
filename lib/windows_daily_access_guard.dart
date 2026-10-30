/// Runtime admission only; cloud identity, licensing and revocation remain
/// authoritative at the broker. Never stores credentials or business records.
/// A stricter 24-hour policy is staged behind SAARTHI_WINDOWS_REQUIRE_DAILY_ONLINE.
class WindowsDailyAccessGuard {
  WindowsDailyAccessGuard._();
  static bool Function(String school)? _restriction;
  static void install(bool Function(String school) restriction) {
    _restriction = restriction;
  }
  static void uninstall(bool Function(String school) restriction) {
    if (identical(_restriction, restriction)) _restriction = null;
  }
  static bool blockedFor(String school) =>
      school.isNotEmpty && (_restriction?.call(school) ?? false);
}
