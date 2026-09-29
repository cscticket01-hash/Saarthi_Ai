import 'package:flutter/material.dart';

enum WindowsServiceType {
  localStorage,
  firebase,
  googleDrive,
}

enum WindowsHealthState {
  unknown,
  checking,
  healthy,
  unhealthy,
}

class WindowsServiceHealth {
  const WindowsServiceHealth({
    required this.state,
    required this.message,
    required this.updatedAt,
  });

  final WindowsHealthState state;
  final String message;
  final DateTime updatedAt;
}

class WindowsServiceStatus extends ChangeNotifier {
  WindowsServiceStatus._();

  static final WindowsServiceStatus instance =
      WindowsServiceStatus._();

  final Map<WindowsServiceType, WindowsServiceHealth> _health = {
    for (final type in WindowsServiceType.values)
      type: WindowsServiceHealth(
        state: WindowsHealthState.unknown,
        message: 'Abhi test nahi hua.',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
  };

  WindowsServiceHealth health(WindowsServiceType type) =>
      _health[type]!;

  void checking(
    WindowsServiceType type, [
    String message = 'Checking...',
  ]) {
    _set(
      type,
      WindowsHealthState.checking,
      message,
    );
  }

  void healthy(
    WindowsServiceType type, [
    String message = 'Working',
  ]) {
    _set(
      type,
      WindowsHealthState.healthy,
      message,
    );
  }

  void unhealthy(
    WindowsServiceType type,
    String message,
  ) {
    _set(
      type,
      WindowsHealthState.unhealthy,
      message,
    );
  }

  void unknown(
    WindowsServiceType type, [
    String message = 'Abhi test nahi hua.',
  ]) {
    _set(
      type,
      WindowsHealthState.unknown,
      message,
    );
  }

  void _set(
    WindowsServiceType type,
    WindowsHealthState state,
    String message,
  ) {
    final next = WindowsServiceHealth(
      state: state,
      message: message.trim().isEmpty
          ? state.name
          : message.trim(),
      updatedAt: DateTime.now(),
    );

    final old = _health[type];

    if (old?.state == next.state &&
        old?.message == next.message) {
      return;
    }

    _health[type] = next;

    notifyListeners();
  }
}

class WindowsStatusLed extends StatelessWidget {
  const WindowsStatusLed({
    super.key,
    required this.service,
    this.showLabel = true,
    this.compact = false,
  });

  final WindowsServiceType service;
  final bool showLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: WindowsServiceStatus.instance,
      builder: (context, _) {
        final health =
            WindowsServiceStatus.instance.health(
          service,
        );

        final color = _color(
          health.state,
        );

        final label = _label(
          health.state,
        );

        return Tooltip(
          message: health.message,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 7 : 9,
              vertical: compact ? 4 : 5,
            ),
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius:
                  BorderRadius.circular(999),
              border: Border.all(
                color: color.withOpacity(0.35),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: compact ? 9 : 11,
                  height: compact ? 9 : 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: [
                      BoxShadow(
                        color:
                            color.withOpacity(0.58),
                        blurRadius:
                            health.state ==
                                        WindowsHealthState
                                            .healthy ||
                                    health.state ==
                                        WindowsHealthState
                                            .unhealthy
                                ? 8
                                : 3,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                if (showLabel) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize:
                          compact ? 9 : 10,
                      fontWeight:
                          FontWeight.w900,
                      letterSpacing: .35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Color _color(
    WindowsHealthState state,
  ) {
    switch (state) {
      case WindowsHealthState.healthy:
        return const Color(
          0xFF00E59F,
        );

      case WindowsHealthState.unhealthy:
        return const Color(
          0xFFFF4D5A,
        );

      case WindowsHealthState.checking:
        return Colors.orangeAccent;

      case WindowsHealthState.unknown:
        return Colors.blueGrey;
    }
  }

  String _label(
    WindowsHealthState state,
  ) {
    switch (state) {
      case WindowsHealthState.healthy:
        return 'WORKING';

      case WindowsHealthState.unhealthy:
        return 'ERROR';

      case WindowsHealthState.checking:
        return 'CHECKING';

      case WindowsHealthState.unknown:
        return 'UNKNOWN';
    }
  }
}
