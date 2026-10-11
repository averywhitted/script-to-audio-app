// Playback bar (rehearsal) docked at the bottom of the workspace.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'widgets.dart';
import 'render_dialog.dart';
import '../state/player_state.dart';

class _Transport extends StatelessWidget {
  const _Transport(this.icon, this.help, this.onTap);
  final IconData icon;
  final String help;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Tooltip(
      message: help,
      child: Hover(
        cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        builder: (context, h) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: h && onTap != null ? t.accentSoft : t.ctrl, shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: onTap == null ? t.faint : t.ink2),
          ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Tooltip(
      message: playing ? 'Pause' : 'Play',
      child: Hover(
        cursor: SystemMouseCursors.click,
        builder: (context, h) => GestureDetector(
          onTap: onTap,
          child: AnimatedScale(
            scale: h ? 1.04 : 1,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: t.accent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: t.accent.withValues(alpha: t.dark ? 0.35 : 0.4),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 24, color: t.onAccent),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundStep extends StatelessWidget {
  const _RoundStep(this.label, this.help, this.onTap);
  final String label;
  final String help;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Tooltip(
      message: help,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: t.border),
            ),
            child: Text(
              label,
              style: TextStyles.ui(t, weight: FontWeight.w700, color: onTap == null ? t.faint : t.ink2),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Log
// ---------------------------------------------------------------------------

String _clock(double s) {
  final t = s.isFinite && s > 0 ? s.round() : 0;
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}

/// Rehearsal controls, docked under the script.
class PlaybackBar extends StatelessWidget {
  const PlaybackBar({super.key, required this.selectedRange});

  /// Start and end time (s) of the lines selected in the playing scene, if any.
  final (double, double)? Function() selectedRange;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final p = context.watch<RehearsalPlayer>();
    final app = context.watch<AppState>();
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(top: BorderSide(color: t.rule)),
      ),
      child: p.scenes.isEmpty ? _empty(context, t, app) : _bar(context, t, p, app),
    );
  }

  Widget _empty(BuildContext context, Tokens t, AppState app) => Row(
    children: [
      Icon(Icons.headphones_rounded, size: 18, color: t.muted),
      const SizedBox(width: 10),
      Text(
        'Rehearse',
        style: TextStyles.ui(t, weight: FontWeight.w700, color: t.ink2),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text('Render a scene and its playback controls appear here.', style: TextStyles.ui(t, color: t.muted)),
      ),
      if (app.script != null) Btn('Render…', small: true, icon: Icons.graphic_eq_rounded, onPressed: app.isGenerating ? null : () => showRenderSheet(context)),
    ],
  );

  Widget _bar(BuildContext context, Tokens t, RehearsalPlayer p, AppState app) {
    final cur = p.currentScene;
    final roles = (app.script?.characters.map((c) => c.name).toList() ?? <String>[])..sort();
    return Row(
      children: [
        SizedBox(
          width: 200,
          child: SelectField<int>(
            compact: true,
            label: cur == null ? '' : 'Scene ${cur.sceneNumber} · ${cur.sceneTitle}',
            items: [
              for (var i = 0; i < p.scenes.length; i++)
                MenuItemSpec(i, 'Scene ${p.scenes[i].sceneNumber}: ${p.scenes[i].sceneTitle}', checked: i == p.currentSceneIndex),
            ],
            onSelected: (i) => p.switchToScene(i),
          ),
        ),
        const SizedBox(width: 6),
        _Transport(Icons.skip_previous_rounded, 'Previous scene (⌘←)', p.currentSceneIndex > 0 ? p.prevScene : null),
        const SizedBox(width: 4),
        _Transport(Icons.fast_rewind_rounded, 'Previous line (←)', p.prevLine),
        const SizedBox(width: 8),
        _PlayButton(playing: p.isPlaying, onTap: p.togglePlayPause),
        const SizedBox(width: 8),
        _Transport(Icons.fast_forward_rounded, 'Next line (→)', p.nextLine),
        const SizedBox(width: 4),
        _Transport(Icons.skip_next_rounded, 'Next scene (⌘→)', p.currentSceneIndex < p.scenes.length - 1 ? p.nextScene : null),
        const SizedBox(width: 14),
        Text(_clock(p.currentTime), style: TextStyles.script(t, size: 11.5, color: t.muted)),
        const SizedBox(width: 8),
        Expanded(
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              _Timeline(player: p, allSpeakers: app.allSpeakers),
              if (p.waitingAtCue != null)
                Positioned(
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: t.mine, borderRadius: BorderRadius.circular(99)),
                    child: Text(
                      'Your line — press Space to continue',
                      style: TextStyles.ui(t, size: 11, weight: FontWeight.w700, color: const Color(0xFF1C1B19)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(_clock(p.duration), style: TextStyles.script(t, size: 11.5, color: t.muted)),
        const SizedBox(width: 12),
        Builder(
          builder: (ctx) => _BarChip(
            icon: Icons.person_outline_rounded,
            label: p.myRole.isEmpty ? 'My Role' : titleCaseName(p.myRole),
            active: p.myRole.isNotEmpty,
            tooltip: 'My Role: pick who you are rehearsing as',
            onTap: () => showPopover(ctx, (_) => _RolePopover(roles: roles), width: 280),
          ),
        ),
        const SizedBox(width: 6),
        Builder(
          builder: (ctx) => _BarChip(
            icon: Icons.repeat_rounded,
            label: switch (p.loopMode) {
              LoopMode.off => 'Loop',
              LoopMode.scene => 'Scene',
              LoopMode.lines => 'Lines',
            },
            active: p.loopMode != LoopMode.off,
            tooltip: 'Loop a scene or the lines you selected',
            onTap: () => showPopover(ctx, (_) => _LoopPopover(selectedRange: selectedRange), width: 250),
          ),
        ),
        const SizedBox(width: 6),
        Builder(
          builder: (ctx) => _BarChip(
            label: '${p.playbackRate.toStringAsFixed(2)}×',
            active: p.playbackRate != 1.0,
            tooltip: 'Speed',
            onTap: () => showPopover(ctx, (_) => const _SpeedPopover(), width: 260),
          ),
        ),
      ],
    );
  }
}

class _BarChip extends StatelessWidget {
  const _BarChip({required this.label, required this.onTap, this.icon, this.active = false, this.tooltip});
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool active;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget c = Hover(
      cursor: SystemMouseCursors.click,
      builder: (context, h) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: active ? t.accentSoft : (h ? t.ctrl : Colors.transparent),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: active ? t.accentLine : t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 15, color: active ? t.accent : t.muted), const SizedBox(width: 5)],
              Text(
                label,
                style: TextStyles.ui(t, size: 12, weight: FontWeight.w600, color: active ? t.accent : t.ink2),
              ),
            ],
          ),
        ),
      ),
    );
    if (tooltip != null) c = Tooltip(message: tooltip!, child: c);
    return c;
  }
}

/// One colored segment per line (yellow for my lines); click or drag to seek.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.player, required this.allSpeakers});
  final RehearsalPlayer player;
  final List<String> allSpeakers;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        void seekAt(double x) {
          final d = player.duration;
          if (d > 0) player.seek((x / c.maxWidth).clamp(0.0, 1.0) * d);
        }

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seekAt(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => seekAt(d.localPosition.dx),
            child: SizedBox(
              width: c.maxWidth,
              height: 30,
              child: CustomPaint(
                painter: _TimelinePainter(player: player, allSpeakers: allSpeakers, t: t),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({required this.player, required this.allSpeakers, required this.t});
  final RehearsalPlayer player;
  final List<String> allSpeakers;
  final Tokens t;

  @override
  void paint(Canvas canvas, Size size) {
    final d = player.duration;
    if (size.width <= 2) return;
    final mid = size.height / 2 + 4;
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, mid - 3, size.width, 6), const Radius.circular(3));
    canvas.drawRRect(track, Paint()..color = t.ctrl);
    if (d <= 0) return;
    for (final c in player.cues) {
      final x0 = c.startTime / d * size.width, x1 = c.endTime / d * size.width;
      final mine = player.isMyLine(c.speaker);
      final speaker = c.speaker == narratorKey ? 'Narrator' : c.speaker.split('/').first;
      final color = mine ? const Color(0xFFFFE94D) : speakerColors(speaker, allSpeakers, t, enabled: true).dot.withValues(alpha: 0.8);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x0, mid - 3, (x1 - x0 - 1) < 1 ? 1.0 : (x1 - x0 - 1), 6), const Radius.circular(2)),
        Paint()..color = color,
      );
    }
    if (player.loopMode == LoopMode.lines && player.loopEnd > player.loopStart) {
      final a = player.loopStart / d * size.width, b = player.loopEnd / d * size.width;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(a, mid - 7, b, mid + 7), const Radius.circular(4)),
        Paint()
          ..color = t.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final x = (player.currentTime / d).clamp(0.0, 1.0) * size.width;
    canvas.drawCircle(Offset(x, mid), 7, Paint()..color = t.knob);
    canvas.drawCircle(
      Offset(x, mid),
      7,
      Paint()
        ..color = t.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_TimelinePainter old) => true;
}

class _RolePopover extends StatelessWidget {
  const _RolePopover({required this.roles});
  final List<String> roles;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final p = context.watch<RehearsalPlayer>();
    final app = context.watch<AppState>();
    Widget toggle(String label, String help, bool v, ValueChanged<bool> on) => Tooltip(
      message: p.myRole.isEmpty ? 'Select a role above to enable this' : help,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyles.ui(t, color: p.myRole.isEmpty ? t.faint : t.ink)),
            ),
            Toggle(value: v, onChanged: p.myRole.isEmpty ? null : on),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('My Role', style: TextStyles.ui(t, size: 14, weight: FontWeight.w700)),
          const SizedBox(height: 8),
          SelectField<String>(
            label: p.myRole.isEmpty ? 'Spectator' : titleCaseName(p.myRole),
            leading: p.myRole.isEmpty ? null : SpeakerDot(p.myRole, allSpeakers: app.allSpeakers),
            items: [
              MenuItemSpec('', 'Spectator', checked: p.myRole.isEmpty),
              const MenuItemSpec.divider(),
              for (final r in roles) MenuItemSpec(r, titleCaseName(r), checked: r == p.myRole),
            ],
            onSelected: p.setRole,
          ),
          const SizedBox(height: 8),
          toggle('Mute My Lines', 'Skip audio playback for your lines', p.muteMyLines, p.setMute),
          toggle('Block My Lines', 'Replace your lines with underscores for memorization practice', p.blockMyLines, p.setBlock),
          toggle('Stop Before My Lines', 'Pause before each of your lines so you can say it, then press Space', p.cueMode, p.setCueMode),
        ],
      ),
    );
  }
}

class _LoopPopover extends StatelessWidget {
  const _LoopPopover({required this.selectedRange});
  final (double, double)? Function() selectedRange;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final p = context.watch<RehearsalPlayer>();
    final range = selectedRange();
    Widget option(String label, String sub, LoopMode mode, VoidCallback? onTap) {
      final on = p.loopMode == mode;
      return Hover(
        cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        builder: (context, h) => GestureDetector(
          onTap: onTap == null
              ? null
              : () {
                  onTap();
                  Navigator.of(context).pop();
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: on ? t.accentSoft : (h && onTap != null ? t.ctrl : Colors.transparent), borderRadius: BorderRadius.circular(7)),
            child: Row(
              children: [
                SizedBox(width: 20, child: on ? Icon(Icons.check_rounded, size: 15, color: t.accent) : null),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyles.ui(t, weight: FontWeight.w600, color: onTap == null ? t.faint : t.ink),
                      ),
                      Text(sub, style: TextStyles.ui(t, size: 11.5, color: t.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          option('Off', 'Play on to the next scene', LoopMode.off, () => p.setLoop(LoopMode.off)),
          option('Loop This Scene', 'Start the scene again when it ends', LoopMode.scene, () => p.setLoop(LoopMode.scene)),
          option(
            'Loop Selected Lines',
            range == null ? 'Select lines in the playing scene first' : 'Repeat ${_clock(range.$1)}–${_clock(range.$2)}',
            LoopMode.lines,
            range == null ? null : () => p.setLoop(LoopMode.lines, start: range.$1, end: range.$2),
          ),
        ],
      ),
    );
  }
}

class _SpeedPopover extends StatelessWidget {
  const _SpeedPopover();
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final p = context.watch<RehearsalPlayer>();
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('Speed', style: TextStyles.ui(t, size: 14, weight: FontWeight.w700)),
              const Spacer(),
              Text(
                '${p.playbackRate.toStringAsFixed(2)}×',
                style: TextStyles.script(t, size: 12, weight: FontWeight.w700, color: t.ink2),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _RoundStep('−', 'Slower (−0.05×)', p.playbackRate <= 0.5 ? null : () => p.stepRate(-0.05)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    activeTrackColor: t.accent,
                    inactiveTrackColor: t.ctrl,
                    thumbColor: t.knob,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8, elevation: 2),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Slider(value: p.playbackRate, min: 0.5, max: 2.0, onChanged: p.setRate),
                  ),
                ),
              ),
              _RoundStep('+', 'Faster (+0.05×)', p.playbackRate >= 2.0 ? null : () => p.stepRate(0.05)),
            ],
          ),
        ],
      ),
    );
  }
}
