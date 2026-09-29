import 'package:flutter/material.dart';

import 'windows_firebase_connection.dart';

class WindowsOfflineHomeScreen extends StatefulWidget {
  const WindowsOfflineHomeScreen({super.key});

  @override
  State<WindowsOfflineHomeScreen> createState() =>
      _WindowsOfflineHomeScreenState();
}

class _WindowsOfflineHomeScreenState extends State<WindowsOfflineHomeScreen> {
  int _selectedIndex = 0;

  static const _items = <_OfflineNavItem>[
    _OfflineNavItem(
      label: 'Dashboard',
      icon: Icons.dashboard_rounded,
    ),
    _OfflineNavItem(
      label: 'Students',
      icon: Icons.groups_rounded,
      protected: true,
    ),
    _OfflineNavItem(
      label: 'Fees',
      icon: Icons.currency_rupee_rounded,
      protected: true,
    ),
    _OfflineNavItem(
      label: 'Attendance',
      icon: Icons.fact_check_rounded,
      protected: true,
    ),
    _OfflineNavItem(
      label: 'Results',
      icon: Icons.workspace_premium_rounded,
      protected: true,
    ),
    _OfflineNavItem(
      label: 'Settings',
      icon: Icons.settings_rounded,
    ),
  ];

  void _select(int index) {
    final item = _items[index];

    if (item.protected) {
      _showConnectRequired(item.label);
      return;
    }

    setState(() => _selectedIndex = index);
  }

  Future<void> _openFirebaseSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const WindowsFirebaseSetupScreen(),
      ),
    );

    if (mounted) {
      setState(() {});
    }
  }

  void _showConnectRequired(String feature) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF122129),
          title: const Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                color: Colors.orangeAccent,
              ),
              SizedBox(width: 10),
              Text('School not connected'),
            ],
          ),
          content: Text(
            '$feature school data use karne ke liye pehle '
            'Settings me school Firebase connect karein.',
            style: const TextStyle(
              color: Colors.white70,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext);
                setState(() => _selectedIndex = 5);
              },
              icon: const Icon(Icons.settings_rounded),
              label: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07151B),
      body: Row(
        children: [
          _buildSidebar(),
          Expanded(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: _selectedIndex == 5
                      ? _buildSettings()
                      : _buildDashboard(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 230,
      color: const Color(0xFF0A1E26),
      child: Column(
        children: [
          const SizedBox(height: 22),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: Color(0xFF00A884),
                  child: Icon(
                    Icons.auto_stories_rounded,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Vidya Saarthi',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                      Text(
                        'WINDOWS',
                        style: TextStyle(
                          color: Color(0xFF00D9A5),
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                final selected = index == _selectedIndex;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: selected
                        ? const Color(0xFF12373A)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _select(index),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              item.icon,
                              size: 20,
                              color: selected
                                  ? const Color(0xFF00D9A5)
                                  : Colors.white54,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                item.label,
                                style: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : Colors.white60,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (item.protected)
                              const Icon(
                                Icons.lock_outline_rounded,
                                size: 14,
                                color: Colors.white24,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withOpacity(0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.orangeAccent.withOpacity(0.20),
              ),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.cloud_off_rounded,
                  color: Colors.orangeAccent,
                  size: 18,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'School Firebase\nNot connected',
                    style: TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0D2028),
        border: Border(
          bottom: BorderSide(color: Colors.white10),
        ),
      ),
      child: Row(
        children: [
          Text(
            _items[_selectedIndex].label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 7,
            ),
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: Colors.orangeAccent.withOpacity(0.25),
              ),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orangeAccent,
                  size: 16,
                ),
                SizedBox(width: 7),
                Text(
                  'SETUP REQUIRED',
                  style: TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboard() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF10373A),
                  Color(0xFF10252E),
                ],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFF00D9A5).withOpacity(0.20),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00A884).withOpacity(0.14),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Icons.school_rounded,
                    color: Color(0xFF00D9A5),
                    size: 34,
                  ),
                ),
                const SizedBox(width: 18),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Vidya Saarthi is ready',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        'Software Firebase ke bina open hai. '
                        'School data use karne ke liye Settings me '
                        'school Firebase connect karein.',
                        style: TextStyle(
                          color: Colors.white60,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => setState(() => _selectedIndex = 5),
                  icon: const Icon(Icons.settings_rounded),
                  label: const Text('Open Settings'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: const [
              _OfflineFeatureCard(
                title: 'Students',
                icon: Icons.groups_rounded,
              ),
              _OfflineFeatureCard(
                title: 'Fees',
                icon: Icons.currency_rupee_rounded,
              ),
              _OfflineFeatureCard(
                title: 'Attendance',
                icon: Icons.fact_check_rounded,
              ),
              _OfflineFeatureCard(
                title: 'Results',
                icon: Icons.workspace_premium_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSettings() {
    final startupError = WindowsFirebaseConnection.startupError;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(26),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: 900,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'School Connections',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Har school apna Firebase aur baad me apna Google Drive / '
                'Google Cloud connect karega.',
                style: TextStyle(
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF10242C),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        CircleAvatar(
                          radius: 21,
                          backgroundColor: Color(0xFF18343B),
                          child: Icon(
                            Icons.local_fire_department_rounded,
                            color: Colors.orangeAccent,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Firebase / School Database',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'NOT CONNECTED',
                                style: TextStyle(
                                  color: Colors.orangeAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'School ka vidyasaarthi://firebase?config=... link '
                      'paste karke verify karein. Password save nahi hoga.',
                      style: TextStyle(
                        color: Colors.white60,
                        height: 1.45,
                      ),
                    ),
                    if (startupError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        startupError,
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 11,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _openFirebaseSettings,
                        icon: const Icon(Icons.link_rounded),
                        label: const Text(
                          'Connect School Firebase',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const _ComingSoonConnectionCard(
                title: 'Google Drive',
                subtitle: 'School ka own Apps Script / Drive connection',
                icon: Icons.add_to_drive_rounded,
              ),
              const SizedBox(height: 14),
              const _ComingSoonConnectionCard(
                title: 'Google Cloud',
                subtitle: 'School ka own Google Cloud configuration',
                icon: Icons.cloud_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineNavItem {
  const _OfflineNavItem({
    required this.label,
    required this.icon,
    this.protected = false,
  });

  final String label;
  final IconData icon;
  final bool protected;
}

class _OfflineFeatureCard extends StatelessWidget {
  const _OfflineFeatureCard({
    required this.title,
    required this.icon,
  });

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      height: 130,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF10242C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: Colors.white38,
              ),
              const Spacer(),
              const Icon(
                Icons.lock_outline_rounded,
                color: Colors.white24,
                size: 17,
              ),
            ],
          ),
          const Spacer(),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          const Text(
            'Firebase required',
            style: TextStyle(
              color: Colors.white30,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _ComingSoonConnectionCard extends StatelessWidget {
  const _ComingSoonConnectionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF10242C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: Colors.white38,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const Text(
            'NEXT',
            style: TextStyle(
              color: Colors.white24,
              fontSize: 9,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
