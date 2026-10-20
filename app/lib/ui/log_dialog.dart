// The app log, shown from Debug → Show Log.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'widgets.dart';
import 'empty_art.dart';

class LogTab extends StatefulWidget {
  const LogTab({super.key});
  @override
  State<LogTab> createState() => _LogTabState();
}

class _LogTabState extends State<LogTab> {
  LogStyle? filter;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final entries = filter == null ? app.debugLog : app.debugLog.where((e) => e.style == filter).toList();
    Widget chip(String label, LogStyle? f) => GestureDetector(
      onTap: () => setState(() => filter = filter == f ? null : f),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: filter == f ? t.accentSoft : Colors.transparent, borderRadius: BorderRadius.circular(5)),
          child: Text(
            label,
            style: TextStyles.ui(t, size: 11.5, weight: filter == f ? FontWeight.w700 : FontWeight.w500, color: filter == f ? t.accent : t.muted),
          ),
        ),
      ),
    );
    Color color(LogStyle s) => switch (s) {
      LogStyle.error => t.danger,
      LogStyle.warning => t.warn,
      LogStyle.success => t.ok,
      LogStyle.info => t.ink,
      LogStyle.debug => t.muted,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 6),
          child: Row(
            children: [
              Text('${app.debugLog.length} entries', style: TextStyles.ui(t, size: 12, color: t.muted)),
              const Spacer(),
              chip('All', null),
              chip('Err', LogStyle.error),
              chip('Warn', LogStyle.warning),
              chip('Py', LogStyle.debug),
              IconBtn(
                Icons.copy_rounded,
                size: 14,
                tooltip: 'Copy all log entries',
                onTap: () => copyText(app.debugLog.map((e) => '[${e.timestampString}] ${e.text}').join('\n')),
              ),
              IconBtn(Icons.delete_outline_rounded, size: 15, tooltip: 'Clear log', onTap: app.clearDebugLog),
            ],
          ),
        ),
        Expanded(
          child: app.debugLog.isEmpty
              ? const EmptyState(compact: true, art: EmptyArt.promptBook, title: 'No activity yet')
              : Container(
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  decoration: BoxDecoration(
                    color: t.sheet,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: t.border),
                  ),
                  child: ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[entries.length - 1 - i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 62,
                              child: Text(e.timestampString, style: TextStyles.script(t, size: 10, color: t.faint)),
                            ),
                            Expanded(
                              child: SelectableText(e.text, style: TextStyles.script(t, size: 10.5, color: color(e.style))),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// Opened from Cast when an engine isn't installed.

/// Debug → Show Log.
Future<void> showLogSheet(BuildContext context) => showSheet(context, (ctx) {
  final t = Tokens.of(ctx);
  return SizedBox(
    height: 560,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
          child: Row(
            children: [
              Text('Log', style: TextStyles.display(t, size: 22)),
              const Spacer(),
              IconBtn(Icons.close_rounded, tooltip: 'Close', onTap: () => Navigator.of(ctx).pop()),
            ],
          ),
        ),
        const Expanded(child: LogTab()),
      ],
    ),
  );
}, width: 720);
