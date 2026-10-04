bool schoolOnline(Map school,int now){final seen=school['lastSeenAt'];return school['blocked']!=true&&school['loginDisabled']!=true&&school['deletedAt']==null&&seen is num&&seen>0&&seen<=now&&now-seen<=(school['managed']==true?90000:10*60000);}
Map<String, int> monitorSummary(List<Map<String, dynamic>> schools, int now) {
  const day = 86400000;
  int number(dynamic n) => n is num ? n.toInt() : 0;
  final active = schools.where((s) => s['managed']==true?schoolOnline(s,now):number(s['lastSeenAt']) >= now - day).length;
  // A stale school summary must never keep students online indefinitely.
  final live = schools.where((s) => (s['managed']!=true||schoolOnline(s,now)) && number(s['lastSeenAt']) >= now - 10 * 60000 &&
    number(s['reportedAt'] ?? s['lastSeenAt']) >= now - 10 * 60000);
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
