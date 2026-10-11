// Render dialog and the in-header render status.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

class _SceneRenderRow extends StatelessWidget {
  const _SceneRenderRow({required this.scene});
  final Scene scene;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final n = scene.number;
    final selected = app.selectedScenes.contains(n);
    final edited = app.scenesNeedingRerender.contains(n);
    final rendered = app.sceneFileInfo[n]?.exists == true;
    final rendering = app.isGenerating && app.renderingSceneNumbers.contains(n);
    final p = app.sceneProgress[n] ?? 0;
    return GestureDetector(
      onTap: () => app.toggleScene(n),
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: selected ? t.accentSoft.withValues(alpha: t.accentSoft.a * 0.6) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            CheckMark(checked: selected, onTap: () => app.toggleScene(n)),
            const SizedBox(width: 10),
            Text('Scene ${n.toString().padLeft(2, '0')}', style: TextStyles.script(t, size: 12, weight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(app.effectiveSceneTitle(scene), overflow: TextOverflow.ellipsis, style: TextStyles.ui(t, size: 12.5)),
            ),
            if (rendering && p < 1)
              SizedBox(
                width: 40,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: p, minHeight: 3, color: t.accent, backgroundColor: t.ctrl),
                ),
              )
            else if (edited)
              const Stamp('EDITED', kind: StampKind.warn)
            else if (rendered)
              const Stamp('RENDERED', kind: StampKind.ok),
          ],
        ),
      ),
    );
  }
}

/// While rendering: the "recording booth" card.
class _Booth extends StatelessWidget {
  const _Booth({required this.showLog, required this.onToggleLog});
  final bool showLog;
  final VoidCallback onToggleLog;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.booth,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _RecLamp(on: !app.isPaused),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: app.generationProgress == 0 ? null : app.generationProgress,
                    minHeight: 5,
                    color: t.accent,
                    backgroundColor: t.ctrl,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            app.latestRenderLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyles.script(t, size: 11.5, color: t.boothSub),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _BoothButton(
                  app.isPaused ? 'Resume' : 'Pause',
                  icon: app.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  onTap: app.togglePause,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _BoothButton('Cancel', icon: Icons.close_rounded, danger: true, onTap: app.cancelGeneration),
              ),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onToggleLog,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                children: [
                  Icon(showLog ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 16, color: t.boothSub),
                  Text(
                    'Show Log',
                    style: TextStyles.ui(t, size: 12, weight: FontWeight.w600, color: t.boothSub),
                  ),
                ],
              ),
            ),
          ),
          if (showLog)
            Container(
              margin: const EdgeInsets.only(top: 6),
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                reverse: true,
                shrinkWrap: true,
                children: [
                  for (final l in app.generationLog.reversed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        '${l.timestampString}  ${l.text}',
                        style: TextStyles.script(t, size: 10.5, color: l.style == LogStyle.error ? t.danger : t.boothSub),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BoothButton extends StatelessWidget {
  const _BoothButton(this.label, {required this.icon, required this.onTap, this.danger = false});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final fg = danger ? t.danger : t.boothInk;
    return Hover(
      cursor: SystemMouseCursors.click,
      builder: (context, h) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 28,
          decoration: BoxDecoration(
            color: danger ? (h ? t.dangerSoft : Colors.transparent) : Color.alphaBlend(t.ink.withValues(alpha: h ? 0.06 : 0), t.ctrl),
            borderRadius: BorderRadius.circular(7),
            border: danger ? Border.all(color: t.danger.withValues(alpha: 0.6)) : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyles.ui(t, size: 12.5, weight: FontWeight.w600, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecLamp extends StatefulWidget {
  const _RecLamp({required this.on});
  final bool on;
  @override
  State<_RecLamp> createState() => _RecLampState();
}

class _RecLampState extends State<_RecLamp> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final reduce = MediaQuery.of(context).disableAnimations;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final glow = !widget.on ? 0.0 : (reduce ? 0.6 : 0.4 + 0.6 * c.value);
        return Tooltip(
          message: widget.on ? 'Recording' : 'Paused',
          child: Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: widget.on ? t.rec : t.boothSub,
              shape: BoxShape.circle,
              boxShadow: widget.on
                  ? [
                      BoxShadow(
                        color: t.rec.withValues(alpha: 0.7 * glow),
                        blurRadius: 10 * glow + 2,
                        spreadRadius: 2 * glow,
                      ),
                    ]
                  : null,
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Rehearse
// ---------------------------------------------------------------------------

Future<void> showRenderSheet(BuildContext context) => showSheet(context, (_) => const _RenderSheet(), width: 560);

class _RenderSheet extends StatefulWidget {
  const _RenderSheet();
  @override
  State<_RenderSheet> createState() => _RenderSheetState();
}

class _RenderSheetState extends State<_RenderSheet> {
  bool showLog = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    if (!app.isGenerating) {
      // Start from what most likely needs rendering: edited scenes, else unrendered ones.
      if (app.scenesNeedingRerender.isNotEmpty) {
        app.selectedScenes = Set.of(app.scenesNeedingRerender);
      } else {
        final missing = {
          for (final s in app.scenes)
            if (app.sceneFileInfo[s.number]?.exists != true) s.number,
        };
        app.selectedScenes = missing.isNotEmpty ? missing : {};
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final ready = app.installedEngines.contains(app.selectedEngine);
    final n = app.selectedScenes.length;
    final edited = app.scenesNeedingRerender.length;
    return SizedBox(
      height: 600,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.isGenerating ? 'Rendering' : 'Render Scenes', style: TextStyles.display(t, size: 24)),
                      const SizedBox(height: 4),
                      Text('Each scene becomes its own audio file, voiced with ${app.selectedEngine.title}.', style: TextStyles.ui(t, color: t.ink2)),
                    ],
                  ),
                ),
                IconBtn(Icons.close_rounded, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
              ],
            ),
          ),
          if (app.isGenerating)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: _Booth(showLog: showLog, onToggleLog: () => setState(() => showLog = !showLog)),
            )
          else ...[
            if (edited > 0)
              Container(
                margin: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                decoration: BoxDecoration(color: t.warnSoft, borderRadius: BorderRadius.circular(8)),
                child: Row(
                  children: [
                    Icon(Icons.edit_note_rounded, size: 17, color: t.warn),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$edited scene${edited == 1 ? ' was' : 's were'} edited since rendering.',
                        style: TextStyles.ui(t, size: 12.5, color: t.ink2),
                      ),
                    ),
                    Btn('Select Edited', small: true, onPressed: () => setState(() => app.selectedScenes = Set.of(app.scenesNeedingRerender))),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 24, 6),
              child: Row(
                children: [
                  Btn('All Unrendered', kind: BtnKind.plain, small: true, onPressed: app.selectMissingScenes),
                  const SizedBox(width: 8),
                  Btn('Select All', kind: BtnKind.plain, small: true, onPressed: app.selectAllScenes),
                  const SizedBox(width: 8),
                  Btn('Clear', kind: BtnKind.plain, small: true, onPressed: app.clearSceneSelection),
                ],
              ),
            ),
          ],
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              children: [
                Panel(
                  child: Column(
                    children: [
                      for (final s in app.scenes) ...[_SceneRenderRow(scene: s), if (s != app.scenes.last) const Hairline()],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.rule)),
            ),
            child: Row(
              children: [
                if (!ready)
                  Expanded(
                    child: Text('${app.selectedEngine.title} not installed — go to Settings to set it up.', style: TextStyles.ui(t, size: 12, color: t.warn)),
                  )
                else
                  const Spacer(),
                if (app.isGenerating)
                  Btn('Close', onPressed: () => Navigator.of(context).pop())
                else ...[
                  Btn('Cancel', kind: BtnKind.plain, onPressed: () => Navigator.of(context).pop()),
                  const SizedBox(width: 8),
                  Btn(
                    'Render $n Scene${n == 1 ? '' : 's'}',
                    kind: BtnKind.primary,
                    icon: Icons.graphic_eq_rounded,
                    onPressed: n == 0 || !ready
                        ? null
                        : () {
                            app.renderSelectedScenes();
                            Navigator.of(context).pop();
                          },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown in the tool palette while a render runs: progress, pause, cancel.
class RenderStatusChip extends StatelessWidget {
  const RenderStatusChip({super.key});
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final total = app.renderingSceneNumbers.length;
    final done = app.renderingSceneNumbers.where((n) => (app.sceneProgress[n] ?? 0) >= 1).length;
    final current = (done + 1).clamp(1, total);
    return Tooltip(
      message: 'Show render progress',
      child: Hover(
        cursor: SystemMouseCursors.click,
        builder: (context, h) => GestureDetector(
          onTap: () => showRenderSheet(context),
          child: Container(
            height: 30,
            padding: const EdgeInsets.only(left: 11, right: 3),
            decoration: BoxDecoration(
              color: h ? t.ctrl : t.sheet,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RecLamp(on: !app.isPaused),
                const SizedBox(width: 8),
                Text(app.isPaused ? 'Paused' : 'Rendering $current of $total', style: TextStyles.ui(t, size: 12.5, weight: FontWeight.w600)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: app.generationProgress == 0 ? null : app.generationProgress,
                      minHeight: 4,
                      color: t.accent,
                      backgroundColor: t.ctrl,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconBtn(
                  app.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  size: 16,
                  box: 24,
                  tooltip: app.isPaused ? 'Resume' : 'Pause',
                  onTap: app.togglePause,
                ),
                IconBtn(Icons.close_rounded, size: 15, box: 24, tooltip: 'Cancel', onTap: app.cancelGeneration),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
