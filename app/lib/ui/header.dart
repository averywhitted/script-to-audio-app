// The window's top bar, shared by Projects and the workspace. The app options
// (Update Available, BETA, Report a Bug, Settings) are always pinned to the
// top-right corner.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/platform.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'sheets.dart';
import 'widgets.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({super.key, this.leading = const [], this.tools = const [], this.border = true});

  /// Left side, after the traffic lights (back button, title).
  final List<Widget> leading;

  /// Extra controls after [leading] (unused by the workspace, whose tools sit in a bar below).
  final List<Widget> tools;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => WindowControl.startDrag(),
      onDoubleTap: WindowControl.zoom,
      child: Container(
        height: 52,
        padding: const EdgeInsets.only(left: 84, right: 12),
        decoration: BoxDecoration(
          border: border ? Border(bottom: BorderSide(color: t.rule)) : null,
        ),
        child: Row(
          children: [
            ...leading,
            if (tools.isNotEmpty) ...[const SizedBox(width: 16), ...tools],
            const Spacer(),
            const AppOptions(),
          ],
        ),
      ),
    );
  }
}

/// Update Available · BETA · Report a Bug · Settings.
class AppOptions extends StatelessWidget {
  const AppOptions({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (app.availableUpdate != null) ...[
          Tooltip(
            message: 'A new version of Table Read is available',
            child: Pill('Update Available', icon: Icons.arrow_circle_down_rounded, bg: t.warnSoft, fg: t.warn, onTap: () => showUpdateSheet(context)),
          ),
          const SizedBox(width: 8),
        ],
        Tooltip(
          message: 'About Table Read',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: () => showSettingsSheet(context, initialTab: 3), child: const Stamp('BETA')),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Report a bug (⌘⇧B)',
          child: Hover(
            cursor: SystemMouseCursors.click,
            builder: (context, h) => GestureDetector(
              onTap: () => showBugReportSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: h ? t.ctrl : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: t.border),
                ),
                child: Text(
                  'Report a Bug',
                  style: TextStyles.ui(t, size: 11.5, weight: FontWeight.w600, color: t.ink2),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconBtn(Icons.settings_outlined, tooltip: 'Settings (⌘,)', onTap: () => showSettingsSheet(context)),
      ],
    );
  }
}

/// A labeled button in the workspace tool palette (Cast, Render).
class ToolButton extends StatelessWidget {
  const ToolButton({super.key, required this.icon, required this.label, required this.onTap, this.badge, this.badgeColor, this.tooltip});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? badge;
  final Color? badgeColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget b = Hover(
      cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      builder: (context, h) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: h && onTap != null ? Color.alphaBlend(t.ctrl, t.sheet) : t.sheet,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: t.accent),
              const SizedBox(width: 6),
              Text(label, style: TextStyles.ui(t, weight: FontWeight.w600)),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: (badgeColor ?? t.warn).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(99)),
                  child: Text(
                    badge!,
                    style: TextStyles.ui(t, size: 11, weight: FontWeight.w700, color: badgeColor ?? t.warn),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (tooltip != null) b = Tooltip(message: tooltip!, child: b);
    return b;
  }
}
