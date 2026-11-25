import 'package:flutter/material.dart' hide Text;
import 'windows_appearance.dart';
import 'windows_ui_localization.dart';

/// The popup uses the actual trigger's bounds in the same Navigator overlay.
/// A fixed-width target rectangle makes both of Flutter's horizontal growth
/// directions resolve to the same left edge. No screen-width guess or offset
/// from the parent notice card is used.
class WindowsNoticeActionMenu extends StatelessWidget {
  const WindowsNoticeActionMenu({super.key, required this.onSelected});
  final ValueChanged<String> onSelected;
  static const double menuWidth = 156;
  static const anchorKey = ValueKey('notice-actions-anchor');

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    return Builder(builder: (anchorContext) {
      return IconButton(
        key: anchorKey,
        tooltip: WindowsUiLanguage.translate('Notice Actions'),
        icon: Icon(Icons.more_vert_rounded,
          color: WindowsAppearance.foreground(Colors.white70), size: 20),
        onPressed: () async {
          final overlay = Navigator.of(anchorContext).overlay!;
          final overlayBox = overlay.context.findRenderObject() as RenderBox;
          final surface = Color.alphaBlend(
            WindowsAppearance.accent.withValues(alpha: .10),
            WindowsAppearance.surface,
          ).withValues(alpha: 1);
          final labelColor = WindowsAppearance.onColor(surface);
          final accent = WindowsAppearance.foreground(WindowsAppearance.accent);
          final danger = WindowsAppearance.foreground(Colors.redAccent);
          const margin = 8.0;
          final width = (overlayBox.size.width - 2 * margin)
              .clamp(0.0, menuWidth).toDouble();

          RelativeRect? previous;
          RelativeRect locate() {
            final box = anchorContext.mounted ? anchorContext.findRenderObject() : null;
            if (box is! RenderBox || !box.attached || !box.hasSize ||
                !overlayBox.attached || !overlayBox.hasSize) {
              return previous ?? RelativeRect.fill;
            }
            final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
            final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlayBox);
            final size = overlayBox.size;
            final maxLeft = (size.width - width - margin).clamp(margin, double.infinity).toDouble();
            final left = (bottomRight.dx - width).clamp(margin, maxLeft).toDouble();
            // Prefer below the trigger. If there is insufficient height,
            // place above it rather than drifting far from the selected card.
            const height = 152.0; // three 44px rows + divider + padding
            final below = bottomRight.dy + 4;
            final top = below + height + margin <= size.height
                ? below : (topLeft.dy - height - 4).clamp(margin, double.infinity).toDouble();
            return previous = RelativeRect.fromSize(
              Rect.fromLTWH(left, top, width, 0), size);
          }

          PopupMenuItem<String> item(String value, String title, IconData icon, Color iconColor, Color textColor) =>
              PopupMenuItem<String>(
                value: value,
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Icon(icon, color: iconColor, size: 18),
                  const SizedBox(width: 10),
                  Flexible(child: Text(title, style: TextStyle(
                    fontFamily: 'Segoe UI', color: textColor, fontSize: 13))),
                ]),
              );

          final value = await showMenu<String>(
            context: anchorContext,
            positionBuilder: (_, __) => locate(),
            constraints: BoxConstraints.tightFor(width: width),
            color: surface,
            surfaceTintColor: Colors.transparent,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: WindowsAppearance.accent.withValues(alpha: .45)),
            ),
            menuPadding: const EdgeInsets.symmetric(vertical: 5),
            items: [
              item('preview', 'Preview', Icons.visibility_outlined, accent, labelColor),
              item('edit', 'Edit', Icons.edit_outlined, accent, labelColor),
              const PopupMenuDivider(height: 8),
              item('delete', 'Delete', Icons.delete_outline_rounded, danger, danger),
            ],
          );
          if (anchorContext.mounted && value != null) onSelected(value);
        },
      );
    });
  }
}
