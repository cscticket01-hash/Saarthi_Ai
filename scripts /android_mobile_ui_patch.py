from pathlib import Path
import textwrap

DASHBOARD = Path('lib/main_dashboard_screen.dart')

if not DASHBOARD.exists():
    raise SystemExit('ERROR: lib/main_dashboard_screen.dart nahi mila')

text = DASHBOARD.read_text(encoding='utf-8', errors='ignore')

launcher_import = "import 'package:url_launcher/url_launcher.dart';"
if launcher_import not in text:
    mobile_import = "import 'package:mobile_scanner/mobile_scanner.dart';"
    if mobile_import not in text:
        raise SystemExit('ERROR: mobile_scanner import nahi mila')
    text = text.replace(mobile_import, mobile_import + '\n' + launcher_import, 1)

student_state_start = text.find('class _StudentPortalScreenState')
if student_state_start == -1:
    raise SystemExit('ERROR: StudentPortal state class nahi mila')

admin_state_start = text.find('class _AdminDashboardScreenState', student_state_start)
if admin_state_start == -1:
    raise SystemExit('ERROR: AdminDashboard state class marker nahi mila')

student_section = text[student_state_start:admin_state_start]

if '_openAndroidStudentProfilePanel' not in student_section:
    build_marker = '  @override\n  Widget build(BuildContext context) {'
    build_index = student_section.find(build_marker)
    if build_index == -1:
        raise SystemExit('ERROR: StudentPortal build method nahi mila')

    helpers = textwrap.dedent(r'''
      Widget _buildAndroidMobileNoticeBoard() {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('school_notices')
              .orderBy('timestamp', descending: true)
              .limit(30)
              .snapshots(),
          builder: (context, snapshot) {
            final docs = snapshot.data?.docs ?? const <QueryDocumentSnapshot>[];

            return Container(
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF17332F),
                    Color(0xFF15252B),
                    Color(0xFF111A20),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: const Color(0xFF00A884).withOpacity(0.18),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.20),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 13),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: const Color(0xFF00A884).withOpacity(0.14),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: const Color(0xFF00D9A5).withOpacity(0.20),
                            ),
                          ),
                          child: const Icon(
                            Icons.notifications_active_rounded,
                            color: Color(0xFF00D9A5),
                            size: 23,
                          ),
                        ),
                        const SizedBox(width: 11),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Notice Board',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'School announcements & updates',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 10.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D171C),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white10),
                          ),
                          child: Text(
                            '${docs.length}',
                            style: const TextStyle(
                              color: Color(0xFF00D9A5),
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(height: 1, color: Colors.white.withOpacity(0.055)),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 42),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF00A884),
                          strokeWidth: 2.4,
                        ),
                      ),
                    )
                  else if (snapshot.hasError)
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: _emptyNoticeState(
                        icon: Icons.error_outline_rounded,
                        title: 'Notice load nahi ho paya',
                        subtitle: 'Internet connection check karke dobara try karein.',
                      ),
                    )
                  else if (docs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: _emptyNoticeState(
                        icon: Icons.notifications_none_rounded,
                        title: 'Abhi koi notice nahi hai',
                        subtitle: 'School notice publish karega to yahan turant dikhega.',
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      child: Column(
                        children: [
                          for (var index = 0; index < docs.length; index++)
                            Builder(
                              builder: (context) {
                                final notice = docs[index].data()
                                    as Map<String, dynamic>;
                                final category =
                                    notice['category']?.toString() ?? 'General';
                                final accent = _categoryColor(category);
                                final date = _formatTimestamp(notice['timestamp']);

                                return Container(
                                  width: double.infinity,
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: index == 0
                                        ? accent.withOpacity(0.075)
                                        : const Color(0xFF10191F),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: index == 0
                                          ? accent.withOpacity(0.26)
                                          : Colors.white.withOpacity(0.055),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 38,
                                            height: 38,
                                            decoration: BoxDecoration(
                                              color: accent.withOpacity(0.13),
                                              borderRadius: BorderRadius.circular(11),
                                            ),
                                            child: Icon(
                                              _categoryIcon(category),
                                              color: accent,
                                              size: 19,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Wrap(
                                              spacing: 7,
                                              runSpacing: 5,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: accent.withOpacity(0.12),
                                                    borderRadius:
                                                        BorderRadius.circular(20),
                                                  ),
                                                  child: Text(
                                                    category.toUpperCase(),
                                                    style: TextStyle(
                                                      color: accent,
                                                      fontSize: 8.5,
                                                      fontWeight: FontWeight.w900,
                                                      letterSpacing: .4,
                                                    ),
                                                  ),
                                                ),
                                                if (index == 0)
                                                  const Text(
                                                    'LATEST',
                                                    style: TextStyle(
                                                      color: Color(0xFF00D9A5),
                                                      fontSize: 8.5,
                                                      fontWeight: FontWeight.w900,
                                                      letterSpacing: .6,
                                                    ),
                                                  ),
                                                if (date.isNotEmpty)
                                                  Text(
                                                    date,
                                                    style: const TextStyle(
                                                      color: Colors.white30,
                                                      fontSize: 9,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        notice['title']?.toString() ?? 'Notice',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w800,
                                          height: 1.25,
                                        ),
                                      ),
                                      if ((notice['description']?.toString() ?? '')
                                          .trim()
                                          .isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          notice['description'].toString(),
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 11.5,
                                            height: 1.5,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        );
      }

      Widget _buildAndroidAppUpdateCard() {
        const currentVersionCode = int.fromEnvironment(
          'APP_VERSION_CODE',
          defaultValue: 1,
        );
        const currentVersionName = String.fromEnvironment(
          'APP_VERSION_NAME',
          defaultValue: '1.0.0',
        );

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('app_config')
              .doc('android_update')
              .snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data() ?? <String, dynamic>{};
            final latestCode = (data['versionCode'] as num?)?.toInt() ?? 0;
            final latestName = data['versionName']?.toString().trim() ?? '';
            final apkUrl = data['apkUrl']?.toString().trim() ?? '';
            final mandatory = data['mandatory'] == true;
            final updateAvailable = latestCode > currentVersionCode;
            final whatsNewRaw = data['whatsNew'];
            final whatsNew = whatsNewRaw is List
                ? whatsNewRaw
                    .map((e) => e.toString())
                    .where((e) => e.trim().isNotEmpty)
                    .toList()
                : <String>[];

            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: updateAvailable
                      ? const [Color(0xFF163934), Color(0xFF14262C)]
                      : const [Color(0xFF17242B), Color(0xFF131D23)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: updateAvailable
                      ? const Color(0xFF00A884).withOpacity(0.35)
                      : Colors.white10,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00A884).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          updateAvailable
                              ? Icons.system_update_alt_rounded
                              : Icons.verified_rounded,
                          color: const Color(0xFF00D9A5),
                          size: 21,
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              updateAvailable
                                  ? 'Update Available'
                                  : 'Vidya Saarthi is up to date',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              updateAvailable && latestName.isNotEmpty
                                  ? 'Current $currentVersionName  •  Latest $latestName'
                                  : 'Installed version $currentVersionName',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (whatsNew.isNotEmpty) ...[
                    const SizedBox(height: 13),
                    const Text(
                      "What's New",
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final item in whatsNew.take(4))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 5),
                              child: Icon(
                                Icons.circle,
                                size: 5,
                                color: Color(0xFF00D9A5),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                item,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 10.5,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  if (updateAvailable) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A884),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(11),
                          ),
                        ),
                        onPressed: apkUrl.isEmpty
                            ? null
                            : () async {
                                final uri = Uri.tryParse(apkUrl);
                                if (uri == null) return;

                                final opened = await launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                );

                                if (!opened && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      backgroundColor: Colors.redAccent,
                                      content: Text(
                                        'Update download open nahi ho paya.',
                                      ),
                                    ),
                                  );
                                }
                              },
                        icon: const Icon(Icons.download_rounded, size: 19),
                        label: Text(
                          mandatory ? 'UPDATE REQUIRED' : 'DOWNLOAD UPDATE',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      'Download ke baad Android install confirmation dega. Same Vidya Saarthi app update hogi.',
                      style: TextStyle(
                        color: Colors.white30,
                        fontSize: 9.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      }

      Future<void> _openAndroidStudentProfilePanel() async {
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          barrierColor: Colors.black.withOpacity(0.62),
          builder: (sheetContext) {
            return FractionallySizedBox(
              heightFactor: 0.93,
              child: DefaultTabController(
                length: 2,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFF10191F),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(24),
                      topRight: Radius.circular(24),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 9),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 5),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: const Color(0xFF00A884).withOpacity(0.13),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.account_circle_rounded,
                                color: Color(0xFF00D9A5),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Profile & Settings',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  Text(
                                    'Vidya Saarthi Student',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(sheetContext),
                              icon: const Icon(
                                Icons.close_rounded,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const TabBar(
                        indicatorColor: Color(0xFF00D9A5),
                        labelColor: Color(0xFF00D9A5),
                        unselectedLabelColor: Colors.white38,
                        tabs: [
                          Tab(
                            icon: Icon(Icons.person_rounded, size: 18),
                            text: 'Profile',
                          ),
                          Tab(
                            icon: Icon(Icons.settings_rounded, size: 18),
                            text: 'Settings',
                          ),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            SingleChildScrollView(
                              padding: const EdgeInsets.all(14),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF172229),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white10),
                                ),
                                child: Column(
                                  children: [
                                    _buildProfileTop(),
                                    Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: _buildProfileDetails(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SingleChildScrollView(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                children: [
                                  _buildAndroidAppUpdateCard(),
                                  const SizedBox(height: 12),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF172229),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: const Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          Icons.notifications_active_rounded,
                                          color: Color(0xFF00D9A5),
                                          size: 22,
                                        ),
                                        SizedBox(width: 11),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'School Notifications',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              SizedBox(height: 4),
                                              Text(
                                                'App open hote hi notification permission maangi jati hai. New school notice background me bhi aa sakta hai.',
                                                style: TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 10.5,
                                                  height: 1.4,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            const Color(0xFF00D9A5),
                                        side: const BorderSide(
                                          color: Color(0xFF00A884),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                      onPressed: openAppSettings,
                                      icon: const Icon(
                                        Icons.tune_rounded,
                                        size: 18,
                                      ),
                                      label: const Text(
                                        'OPEN APP SETTINGS',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.redAccent,
                                side: BorderSide(
                                  color: Colors.redAccent.withOpacity(0.42),
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                _logoutStudent();
                              },
                              icon: const Icon(
                                Icons.logout_rounded,
                                size: 18,
                              ),
                              label: const Text(
                                'LOGOUT',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      }
    ''')

    student_section = student_section[:build_index] + helpers + student_section[build_index:]

old_logout = """          IconButton(
            tooltip: 'Logout',
            icon: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.10), borderRadius: BorderRadius.circular(11)),
              child: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 19),
            ),
            onPressed: _logoutStudent,
          ),"""

new_profile_button = """          IconButton(
            tooltip: 'Profile & Settings',
            icon: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.12),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: const Color(0xFF00A884).withOpacity(0.24),
                ),
              ),
              child: const Icon(
                Icons.account_circle_rounded,
                color: Color(0xFF00D9A5),
                size: 21,
              ),
            ),
            onPressed: _openAndroidStudentProfilePanel,
          ),"""

if old_logout not in student_section:
    raise SystemExit('ERROR: Student Portal logout appbar patch point nahi mila')
student_section = student_section.replace(old_logout, new_profile_button, 1)

old_mobile_layout = """          if (isMobile) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
              child: Column(
                children: [
                  _buildMobileProfileCard(),
                  const SizedBox(height: 14),
                  _buildNoticeBoard(context, height: null),
                ],
              ),
            );
          }"""

new_mobile_layout = """          if (isMobile) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              child: _buildAndroidMobileNoticeBoard(),
            );
          }"""

if old_mobile_layout not in student_section:
    raise SystemExit('ERROR: Student Portal mobile layout patch point nahi mila')
student_section = student_section.replace(old_mobile_layout, new_mobile_layout, 1)

text = text[:student_state_start] + student_section + text[admin_state_start:]
DASHBOARD.write_text(text, encoding='utf-8')

print('Android-only Student Portal UI patch applied.')
print('Website/repository source is not changed by this script in CI.')
