import 'package:flutter/material.dart';

class DeveloperLoginShell extends StatelessWidget {
  const DeveloperLoginShell({super.key, required this.form});
  final Widget form;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff07191e), Color(0xff10252c), Color(0xff071116)],
        ),
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: LayoutBuilder(
                      builder: (context, size) {
                        final wide = size.maxWidth >= 820;
                        final intro = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.school_outlined,
                              color: Color(0xff40d6b2),
                              size: 48,
                            ),
                            const SizedBox(height: 28),
                            Text(
                              'A clearer view of\nevery school.',
                              style: TextStyle(
                                fontSize: wide ? 48 : 30,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 1.12,
                              ),
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              'Manage school access, licensing and support from one secure control centre.',
                              style: TextStyle(
                                color: Color(0xffbbcbd0),
                                fontSize: 17,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 28),
                            const Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                Chip(
                                  avatar: Icon(
                                    Icons.verified_user_outlined,
                                    size: 18,
                                  ),
                                  label: Text('Developer access'),
                                ),
                                Chip(
                                  avatar: Icon(
                                    Icons.apartment_outlined,
                                    size: 18,
                                  ),
                                  label: Text('School isolation'),
                                ),
                              ],
                            ),
                          ],
                        );
                        final card = Container(
                          padding: const EdgeInsets.all(28),
                          decoration: BoxDecoration(
                            color: const Color(0xff102027),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: const Color(0xff31474e)),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x33000000),
                                blurRadius: 30,
                                offset: Offset(0, 16),
                              ),
                            ],
                          ),
                          child: form,
                        );
                        return wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(child: intro),
                                  const SizedBox(width: 64),
                                  SizedBox(width: 440, child: card),
                                ],
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  intro,
                                  const SizedBox(height: 32),
                                  card,
                                ],
                              );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
