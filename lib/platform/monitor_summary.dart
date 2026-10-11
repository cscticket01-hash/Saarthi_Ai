bool schoolOnline(Map school,int now){final seen=school['lastSeenAt'];return school['blocked']!=true&&school['loginDisabled']!=true&&school['deletedAt']==null&&seen is num&&seen>0&&seen<=now&&now-seen<=(school['managed']==true?90000:10*60000);}
Map<String, int> monitorSummary(List<Map<String, dynamic>> schools, int now) {
  const day = 86400000;
  int number(dynamic n) => n is num ? n.toInt() : 0;
  final active = schools.where((s) => s['managed']==true?schoolOnline(s,now):number(s['lastSeenAt']) >= now - day).length;
  // A stale school summary must never keep students online indefinitely.
  // Student cloud activity is independent of the management PC's heartbeat.
  // Require a bounded measured report; a future timestamp cannot stay live.
  final live = schools.where((s) {
    final reported = s['managed'] == true ? s['reportedAt'] :
        s['reportedAt'] ?? s['lastSeenAt'];
    return s['blocked'] != true && s['loginDisabled'] != true &&
        s['deletedAt'] == null && reported is num && reported.isFinite &&
        reported > 0 && reported <= now && now - reported <= 10 * 60000;
  });
  return {
    'totalSchools': schools.length,
    'activeSchools': active,
    'inactiveSchools': schools.length - active,
    'totalStudents': schools.fold(0, (n, s) => n + number(s['studentCount'])),
    'studentAppUsers': schools.fold(0, (n, s) => n + number(s['studentAppUsers'])),
    'onlineStudents': live.fold(0, (n, s) => n + number(s['onlineStudents'])),
    'purchasedSchools': schools.where((s) => s['purchased'] == true).length,
    'expiringSchools': schools.where((s) => number(s['licenseExpiresAt']) > now &&
        number(s['licenseExpiresAt']) <= now + 14 * day).length,
  };
}
