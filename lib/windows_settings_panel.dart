import 'dart:convert';

import 'package:flutter/material.dart';

import 'windows_local_auth.dart';
import 'windows_local_settings.dart';

class WindowsSettingsPanel extends StatefulWidget {
  const WindowsSettingsPanel({super.key});

  @override
  State<WindowsSettingsPanel> createState() =>
      _WindowsSettingsPanelState();
}

class _WindowsSettingsPanelState
    extends State<WindowsSettingsPanel> {
  final _firebase = TextEditingController();
  final _cloud = TextEditingController();

  bool _loading = true;
  bool _savingFirebase = false;
  bool _savingCloud = false;

  String? _savedFirebase;
  String? _savedCloud;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _firebase.dispose();
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

  Future<void> _saveFirebase() async {
    if (_savingFirebase) return;
    if (!await _unlock()) return;

    setState(() => _savingFirebase = true);

    try {
      await WindowsExternalConnections.save(
        firebaseLink: _firebase.text,
      );

      final data =
          WindowsExternalConnections
              .decodeFirebaseLink(
        _firebase.text,
      );

      if (!mounted) return;

      setState(() {
        _savedFirebase =
            _firebase.text.trim();
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          backgroundColor:
              const Color(0xFF00A884),
          content: Text(
            'Firebase link locally save hua. Project: ${data['projectId']}',
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
            _savingFirebase = false);
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
    String subtitle = 'NOT SAVED';

    if (_savedFirebase?.isNotEmpty ==
        true) {
      try {
        final decoded =
            WindowsExternalConnections
                .decodeFirebaseLink(
          _savedFirebase!,
        );

        subtitle =
            'SAVED • ${decoded['projectId']}';
      } catch (_) {
        subtitle = 'SAVED';
      }
    }

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
                  Icons
                      .local_fire_department_rounded,
                  color:
                      Colors.orangeAccent,
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
                  subtitle,
                  style: TextStyle(
                    color:
                        _savedFirebase
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
              'Optional cloud sync ke liye school ka Vidya Saarthi Firebase link yahan save hoga. Local app Firebase ke bina bhi chalega.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _firebase,
              maxLines: 3,
              decoration:
                  const InputDecoration(
                labelText:
                    'vidyasaarthi://firebase?config=...',
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    _savingFirebase
                        ? null
                        : _saveFirebase,
                icon: const Icon(
                  Icons.save_rounded,
                ),
                label: Text(
                  _savingFirebase
                      ? 'Saving...'
                      : 'Save Firebase Link',
                ),
              ),
            ),
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
