import 'package:flutter/material.dart';

import 'windows_local_auth.dart';
import 'windows_local_settings.dart';
import 'windows_firebase_sync.dart';

class WindowsSettingsPanel extends StatefulWidget {
  const WindowsSettingsPanel({super.key});

  @override
  State<WindowsSettingsPanel> createState() =>
      _WindowsSettingsPanelState();
}

class _WindowsSettingsPanelState
    extends State<WindowsSettingsPanel> {
  final _firebase = TextEditingController();
  final _firebaseEmail = TextEditingController();
  final _firebasePassword = TextEditingController();
  final _cloud = TextEditingController();

  bool _loading = true;
  bool _savingFirebase = false;
  bool _testingFirebase = false;
  bool _disconnectingFirebase = false;
  bool _savingCloud = false;
  bool _firebasePasswordObscure = true;

  String? _savedFirebase;
  String? _savedCloud;
  bool _firebaseConnected = false;
  String _firebaseProjectId = '';
  String _firebaseStatusText = 'NOT CONNECTED';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _firebase.dispose();
    _firebaseEmail.dispose();
    _firebasePassword.dispose();
    _cloud.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data =
        await WindowsExternalConnections.load();

    if (!mounted) return;

    setState(() {
      _savedFirebase =
          data['firebaseLink']?.toString().trim();

      _savedCloud =
          data['googleCloudConsoleLink']
              ?.toString()
              .trim();

      _firebase.text = _savedFirebase ?? '';
      _cloud.text = _savedCloud ?? '';
    });

    final remoteStatus =
        await WindowsFirebaseRemote.status();

    if (!mounted) return;

    setState(() {
      _firebaseConnected =
          remoteStatus.authenticated;
      _firebaseProjectId =
          remoteStatus.projectId;
      _firebaseEmail.text =
          remoteStatus.email;

      if (_firebaseConnected) {
        _firebaseStatusText =
            'CONNECTED • ${remoteStatus.projectId}';
      } else if (_savedFirebase?.isNotEmpty == true) {
        _firebaseStatusText =
            'LINK SAVED • VERIFY REQUIRED';
      } else {
        _firebaseStatusText =
            'NOT CONNECTED';
      }

      _loading = false;
    });
  }

  Future<bool> _unlock() async {
    if (!WindowsLocalSecurity.configured) {
      if (!mounted) return false;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text(
            'Pehle Local Settings Lock configure karein.',
          ),
        ),
      );

      return false;
    }

    final controller = TextEditingController();
    bool obscure = true;
    String? error;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor:
                  const Color(0xFF172229),
              title: const Text(
                'Unlock Settings',
                style: TextStyle(
                  color: Colors.white,
                ),
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      obscureText: obscure,
                      autofocus: true,
                      onSubmitted: (_) {
                        final ok =
                            WindowsLocalSecurity
                                .verifyPassword(
                          controller.text,
                        );

                        if (ok) {
                          Navigator.pop(
                            dialogContext,
                            true,
                          );
                        } else {
                          setDialogState(() {
                            error =
                                'Galat Settings Password.';
                          });
                        }
                      },
                      decoration: InputDecoration(
                        labelText:
                            'Settings Password',
                        errorText: error,
                        suffixIcon: IconButton(
                          onPressed: () {
                            setDialogState(() {
                              obscure = !obscure;
                            });
                          },
                          icon: Icon(
                            obscure
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(
                    dialogContext,
                    false,
                  ),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final ok =
                        WindowsLocalSecurity
                            .verifyPassword(
                      controller.text,
                    );

                    if (ok) {
                      Navigator.pop(
                        dialogContext,
                        true,
                      );
                    } else {
                      setDialogState(() {
                        error =
                            'Galat Settings Password.';
                      });
                    }
                  },
                  child: const Text('Unlock'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    return result == true;
  }

  Future<void> _changeLock() async {
    if (!await _unlock()) return;
    if (!mounted) return;

    final currentPassword =
        TextEditingController();
    final id = TextEditingController(
      text: WindowsLocalSecurity.adminId,
    );
    final password =
        TextEditingController();
    final confirm =
        TextEditingController();

    String? error;
    bool obscure = true;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor:
                  const Color(0xFF172229),
              title: const Text(
                'Change Local Settings Lock',
                style: TextStyle(
                  color: Colors.white,
                ),
              ),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    TextField(
                      controller: currentPassword,
                      obscureText: true,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Current Settings Password',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: id,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Local Admin ID',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: password,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        labelText:
                            'New Settings Password',
                        suffixIcon: IconButton(
                          onPressed: () {
                            setDialogState(() {
                              obscure = !obscure;
                            });
                          },
                          icon: Icon(
                            obscure
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirm,
                      obscureText: obscure,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Confirm Password',
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(
                    dialogContext,
                    false,
                  ),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (password.text !=
                        confirm.text) {
                      setDialogState(() {
                        error =
                            'Password match nahi kar raha.';
                      });
                      return;
                    }

                    try {
                      await WindowsLocalSecurity
                          .change(
                        currentPassword:
                            currentPassword.text,
                        newAdminId:
                            id.text,
                        newPassword:
                            password.text,
                      );
                    } catch (e) {
                      setDialogState(() {
                        error = e
                            .toString()
                            .replaceFirst(
                              'Bad state: ',
                              '',
                            );
                      });
                      return;
                    }

                    await FirebaseAuth.instance
                        .refreshLocalUser();

                    if (dialogContext.mounted) {
                      Navigator.pop(
                        dialogContext,
                        true,
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    currentPassword.dispose();
    id.dispose();
    password.dispose();
    confirm.dispose();

    if (saved == true && mounted) {
      setState(() {});

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          backgroundColor:
              Color(0xFF00A884),
          content: Text(
            'Local Settings Lock update ho gaya.',
          ),
        ),
      );
    }
  }

  Future<void> _connectFirebase() async {
    if (_savingFirebase) return;
    if (!await _unlock()) return;

    final link = _firebase.text.trim();
    final email = _firebaseEmail.text.trim();
    final password = _firebasePassword.text;

    if (link.isEmpty ||
        email.isEmpty ||
        password.isEmpty) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text(
            'Firebase Link, Admin Email aur Password tino bharein.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _savingFirebase = true;
      _firebaseStatusText = 'VERIFYING...';
    });

    try {
      final result =
          await WindowsFirebaseRemote.connectAndVerify(
        firebaseLink: link,
        email: email,
        password: password,
      );

      _firebasePassword.clear();

      if (!mounted) return;

      setState(() {
        _savedFirebase = link;
        _firebaseConnected = true;
        _firebaseProjectId =
            result.projectId;
        _firebaseEmail.text =
            result.email;
        _firebaseStatusText =
            'CONNECTED • ${result.projectId}';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              const Color(0xFF00A884),
          content: Text(
            'Firebase successfully connected: ${result.projectId}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _firebaseConnected = false;
        _firebaseStatusText =
            'CONNECTION FAILED';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            e
                .toString()
                .replaceFirst(
                  'Bad state: ',
                  '',
                )
                .replaceFirst(
                  'FormatException: ',
                  '',
                ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingFirebase = false;
        });
      }
    }
  }

  Future<void> _testFirebase() async {
    if (_testingFirebase) return;

    setState(() {
      _testingFirebase = true;
      _firebaseStatusText =
          'TESTING CONNECTION...';
    });

    try {
      final result =
          await WindowsFirebaseRemote
              .testSavedConnection();

      if (!mounted) return;

      setState(() {
        _firebaseConnected = true;
        _firebaseProjectId =
            result.projectId;
        _firebaseEmail.text =
            result.email;
        _firebaseStatusText =
            'CONNECTED • ${result.projectId}';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor:
              Color(0xFF00A884),
          content: Text(
            'Firebase Auth + Firestore connection OK.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _firebaseConnected = false;
        _firebaseStatusText =
            'CONNECTION FAILED';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              Colors.redAccent,
          content: Text(
            e
                .toString()
                .replaceFirst(
                  'Bad state: ',
                  '',
                ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _testingFirebase = false;
        });
      }
    }
  }

  Future<void> _disconnectFirebase() async {
    if (_disconnectingFirebase) return;
    if (!await _unlock()) return;

    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF172229),
          title: const Text(
            'Disconnect Firebase?',
            style: TextStyle(
              color: Colors.white,
            ),
          ),
          content: const Text(
            'Sirf is Windows PC ka Firebase connection remove hoga. '
            'Local school data delete nahi hoga aur Firebase ke existing cloud data ko bhi delete nahi kiya jayega.',
            style: TextStyle(
              color: Colors.white70,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(
                dialogContext,
                false,
              ),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(
                dialogContext,
                true,
              ),
              child: const Text(
                'Disconnect',
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    setState(() {
      _disconnectingFirebase = true;
    });

    try {
      await WindowsFirebaseRemote.disconnect();

      _firebase.clear();
      _firebaseEmail.clear();
      _firebasePassword.clear();

      if (!mounted) return;

      setState(() {
        _savedFirebase = null;
        _firebaseConnected = false;
        _firebaseProjectId = '';
        _firebaseStatusText =
            'NOT CONNECTED';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor:
              Colors.orangeAccent,
          content: Text(
            'Firebase connection remove ho gaya. Local app/data safe hai.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _disconnectingFirebase =
              false;
        });
      }
    }
  }

  Future<void> _saveCloud() async {
    if (_savingCloud) return;
    if (!await _unlock()) return;

    setState(() => _savingCloud = true);

    try {
      await WindowsExternalConnections.save(
        googleCloudConsoleLink:
            _cloud.text,
      );

      if (!mounted) return;

      setState(() {
        _savedCloud =
            _cloud.text.trim();
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          backgroundColor:
              Color(0xFF00A884),
          content: Text(
            'Google Cloud Console link locally save ho gaya.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          backgroundColor:
              Colors.redAccent,
          content: Text(
            e
                .toString()
                .replaceFirst(
                  'FormatException: ',
                  '',
                ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() =>
            _savingCloud = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child:
                CircularProgressIndicator(),
          ),
        ),
      );
    }

    return Column(
      children: [
        _securityCard(),
        const SizedBox(height: 14),
        _firebaseCard(),
        const SizedBox(height: 14),
        _cloudCard(),
      ],
    );
  }

  Widget _securityCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.lock_rounded,
                  color:
                      Color(0xFF00D9A5),
                ),
                SizedBox(width: 10),
                Text(
                  'Local Settings Lock',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight:
                        FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Admin ID: ${WindowsLocalSecurity.adminId}',
              style: const TextStyle(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Ye ID/Password sirf is Windows PC ke protected settings ke liye hai. Firebase se koi relation nahi.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _changeLock,
              icon: const Icon(
                Icons.password_rounded,
              ),
              label: const Text(
                'Change Local ID / Password',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _firebaseCard() {
    final connected =
        _firebaseConnected;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons
                      .local_fire_department_rounded,
                  color: connected
                      ? const Color(
                          0xFF00D9A5,
                        )
                      : Colors
                          .orangeAccent,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Firebase Connection',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight:
                          FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  _firebaseStatusText,
                  style: TextStyle(
                    color: connected
                        ? const Color(
                            0xFF00D9A5,
                          )
                        : Colors
                            .orangeAccent,
                    fontSize: 10,
                    fontWeight:
                        FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Windows app ka main database local PC me hi rahega. '
              'Yahan school ka Firebase connect hoga taaki next step me cloud sync use kiya ja sake.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                height: 1.4,
              ),
            ),
            if (_firebaseProjectId
                .isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Project: $_firebaseProjectId',
                style: const TextStyle(
                  color:
                      Color(0xFF00D9A5),
                  fontSize: 11,
                  fontWeight:
                      FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _firebase,
              maxLines: 3,
              enabled:
                  !_savingFirebase &&
                  !_testingFirebase,
              decoration:
                  const InputDecoration(
                labelText:
                    'vidyasaarthi://firebase?config=...',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller:
                  _firebaseEmail,
              keyboardType:
                  TextInputType.emailAddress,
              enabled:
                  !_savingFirebase &&
                  !_testingFirebase,
              decoration:
                  const InputDecoration(
                labelText:
                    'Firebase Admin Email',
                prefixIcon: Icon(
                  Icons.email_outlined,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller:
                  _firebasePassword,
              obscureText:
                  _firebasePasswordObscure,
              enabled:
                  !_savingFirebase &&
                  !_testingFirebase,
              onSubmitted: (_) =>
                  _connectFirebase(),
              decoration:
                  InputDecoration(
                labelText:
                    'Firebase Password',
                helperText:
                    'Password save nahi hoga. Secure refresh token save hoga.',
                prefixIcon:
                    const Icon(
                  Icons
                      .lock_outline_rounded,
                ),
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() {
                      _firebasePasswordObscure =
                          !_firebasePasswordObscure;
                    });
                  },
                  icon: Icon(
                    _firebasePasswordObscure
                        ? Icons
                            .visibility_off
                        : Icons
                            .visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child:
                  FilledButton.icon(
                onPressed:
                    _savingFirebase
                        ? null
                        : _connectFirebase,
                icon: _savingFirebase
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                          color:
                              Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.link_rounded,
                      ),
                label: Text(
                  _savingFirebase
                      ? 'Verifying Firebase...'
                      : 'Connect & Verify Firebase',
                ),
              ),
            ),
            if (_savedFirebase
                    ?.isNotEmpty ==
                true) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child:
                        OutlinedButton.icon(
                      onPressed:
                          _testingFirebase ||
                                  _savingFirebase
                              ? null
                              : _testFirebase,
                      icon: _testingFirebase
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth:
                                    2,
                              ),
                            )
                          : const Icon(
                              Icons
                                  .verified_rounded,
                            ),
                      label: Text(
                        _testingFirebase
                            ? 'Testing...'
                            : 'Test Connection',
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 10,
                  ),
                  Expanded(
                    child:
                        OutlinedButton.icon(
                      onPressed:
                          _disconnectingFirebase
                              ? null
                              : _disconnectFirebase,
                      icon: const Icon(
                        Icons
                            .link_off_rounded,
                      ),
                      label: Text(
                        _disconnectingFirebase
                            ? 'Removing...'
                            : 'Disconnect',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cloudCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.cloud_rounded,
                  color:
                      Color(0xFF4DA3FF),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Google Cloud Console',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight:
                          FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  _savedCloud?.isNotEmpty ==
                          true
                      ? 'SAVED'
                      : 'NOT SAVED',
                  style: TextStyle(
                    color:
                        _savedCloud
                                    ?.isNotEmpty ==
                                true
                            ? const Color(
                                0xFF00D9A5,
                              )
                            : Colors
                                .orangeAccent,
                    fontSize: 10,
                    fontWeight:
                        FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'School ka own Google Cloud Console project link yahan locally save karein.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cloud,
              decoration:
                  const InputDecoration(
                labelText:
                    'https://console.cloud.google.com/...',
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    _savingCloud
                        ? null
                        : _saveCloud,
                icon: const Icon(
                  Icons.save_rounded,
                ),
                label: Text(
                  _savingCloud
                      ? 'Saving...'
                      : 'Save Google Cloud Link',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
