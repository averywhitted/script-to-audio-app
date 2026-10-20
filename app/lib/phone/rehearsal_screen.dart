// The iPhone's rehearsal screen (#91), after the mockup
// (https://claude.ai/artifact/7rVmDhroJQJzHnLLVimJ8B): the scene's lines fill
// the screen and follow playback; a dark bar holds the timeline and
// transport; Rehearse opens a panel with the role and practice settings.
// Playback is the Mac's RehearsalPlayer, unchanged.

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../state/player_state.dart';
import '../theme/tokens.dart';
import '../ui/dashboard.dart' show blockText;
import '../ui/playback_bar.dart' show SceneTimeline;
import '../ui/widgets.dart' show NameChip, titleCaseName;
import 'rehearsal_session.dart';

const _textScales = [1.0, 1.15, 1.3, 1.5];
const _textSizeLabels = ['Small', 'Medium', 'Large', 'Extra Large'];

class PhoneRehearsalScreen extends StatefulWidget {
  const PhoneRehearsalScreen({super.key, required this.project, this.folderAccess = true, this.audio = true});
  final Project project;

  /// Off in tests: settings are written with dart:io instead of the native plugin.
  final bool folderAccess;

  /// Off in tests, where the audio plugin doesn't exist.
  final bool audio;

  @override
  State<PhoneRehearsalScreen> createState() => _PhoneRehearsalScreenState();
}

class _PhoneRehearsalScreenState extends State<PhoneRehearsalScreen> {
  late final RehearsalSession session = RehearsalSession.load(widget.project);
  late final RehearsalPlayer player = RehearsalPlayer(audioEnabled: widget.audio);
  final scroll = ScrollController();

  /// The scene on screen: the playing one, unless the user picked a text-only scene.
  int? viewing;
  int? _lastScene;
  int _lastCue = -2;
  final Map<int, GlobalKey> _rowKeys = {};

  /// Lines picked for a loop (long-press and drag), as line indices in [viewing].
  int? _selA, _selB;

  int textSize = 1;

  @override
  void initState() {
    super.initState();
    if (widget.audio) {
      AudioSession.instance.then((s) => s.configure(const AudioSessionConfiguration.speech())).catchError((_) {});
    }
    player.loadItems(session.items);
    viewing = player.currentScene?.sceneNumber ?? session.scenes.firstOrNull?.number;
    _lastScene = viewing;
    player.addListener(_onPlayer);
    session.restore(player).then((_) {
      if (!mounted) return;
      setState(() => viewing = player.currentScene?.sceneNumber ?? viewing);
      player.onSettingsChanged = () => session.scheduleSave(player, folderAccess: widget.folderAccess);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent(animate: false));
    });
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => textSize = (p.getInt('phoneTextSize') ?? 1).clamp(0, 3));
    });
  }

  @override
  void dispose() {
    player.removeListener(_onPlayer);
    player.onSettingsChanged = null;
    session.save(player, folderAccess: widget.folderAccess);
    session.dispose();
    player.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _onPlayer() {
    if (!mounted) return;
    final scene = player.currentScene?.sceneNumber;
    // Playback moved on to another scene: follow it if we were watching the playing one.
    if (scene != _lastScene) {
      if (viewing == _lastScene) {
        viewing = scene;
        _rowKeys.clear();
        _clearSelection();
        if (scroll.hasClients) scroll.jumpTo(0);
      }
      _lastScene = scene;
    }
    if (player.currentCueIndex != _lastCue) {
      _lastCue = player.currentCueIndex;
      if (viewing == scene) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
    setState(() {});
  }

  PhoneScene? get _scene => session.scenes.where((s) => s.number == viewing).firstOrNull;

  void _scrollToCurrent({bool animate = true}) {
    final s = _scene;
    if (s == null || player.currentScene?.sceneNumber != s.number) return;
    final i = s.lines.indexWhere((l) => l.cueIndex == player.currentCueIndex);
    final ctx = _rowKeys[i]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, alignment: 0.3, duration: animate ? const Duration(milliseconds: 250) : Duration.zero, curve: Curves.easeOut);
  }

  void _showScene(int number) {
    final si = player.scenes.indexWhere((s) => s.sceneNumber == number);
    if (si >= 0 && si != player.currentSceneIndex) player.switchToScene(si);
    setState(() {
      viewing = number;
      _rowKeys.clear();
      _clearSelection();
    });
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  void _tapLine(PhoneScene s, PhoneLine l) {
    if (!s.rendered || l.cueIndex == null) return;
    if (_selA != null) {
      setState(_clearSelection);
      return;
    }
    if (player.waitingAtCue != null && player.waitingAtCue == l.cueIndex) {
      player.callForLine();
      return;
    }
    player.playFrom(s.number, l.cueIndex!);
  }

  // Loop selection -------------------------------------------------------------

  void _clearSelection() {
    _selA = null;
    _selB = null;
  }

  int? _lineAt(Offset global) {
    for (final e in _rowKeys.entries) {
      final box = e.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (global.dy >= top && global.dy < top + box.size.height) return e.key;
    }
    return null;
  }

  void _loopSelection() {
    final s = _scene;
    if (s == null || _selA == null) return;
    final a = _selA! < _selB! ? _selA! : _selB!, b = _selA! < _selB! ? _selB! : _selA!;
    final cues = s.lines.sublist(a, b + 1).map((l) => l.cueIndex).nonNulls.toList();
    final item = player.scenes.where((i) => i.sceneNumber == s.number).firstOrNull;
    if (item == null || cues.isEmpty) return;
    final start = item.cues[cues.first].startTime, end = item.cues[cues.last].endTime;
    final si = player.scenes.indexOf(item);
    Future<void> go() async {
      if (si != player.currentSceneIndex) await player.switchToScene(si, startAt: start);
      player.setLoop(LoopMode.lines, start: start, end: end);
      player.play();
    }

    go();
    setState(_clearSelection);
  }

  // Building -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final s = _scene;
    final selecting = _selA != null;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(t, s),
            Expanded(child: s == null ? _empty(t) : _script(t, s)),
            if (player.waitingAtCue != null && viewing == player.currentScene?.sceneNumber) _cueCard(t),
            if (selecting) _selectionBar(t),
            if (player.scenes.isNotEmpty) _bar(t),
          ],
        ),
      ),
    );
  }

  Widget _header(Tokens t, PhoneScene? s) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 8, 6),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Projects',
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: t.accent, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: GestureDetector(
            onTap: _openScenes,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyles.ui(t, size: 12, weight: FontWeight.w500, color: t.muted)),
                Text(
                  s == null ? '' : '${s.number} · ${s.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.ui(t, size: 17, weight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        TextButton(
          onPressed: _openTextOptions,
          style: TextButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: t.ink2),
          child: Text('Aa', style: TextStyles.ui(t, size: 17, weight: FontWeight.w600, color: t.ink2)),
        ),
      ],
    ),
  );

  Widget _empty(Tokens t) => Padding(
    padding: const EdgeInsets.all(32),
    child: Center(
      child: Text(
        'Open this project on your Mac once, and it saves the script for your iPhone.',
        textAlign: TextAlign.center,
        style: TextStyles.ui(t, size: 16, color: t.muted, height: 1.5),
      ),
    ),
  );

  Widget _script(Tokens t, PhoneScene s) {
    final scale = _textScales[textSize];
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 40),
      // Not lazy: every row exists, so playback can scroll to any line.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!s.rendered)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: t.panel, borderRadius: BorderRadius.circular(10)),
              child: Text('Text only. Render this scene on your Mac to hear it.', style: TextStyles.ui(t, size: 14, color: t.ink2)),
            ),
          for (final (i, l) in s.lines.indexed) _line(t, s, i, l, scale),
        ],
      ),
    );
  }

  Widget _line(Tokens t, PhoneScene s, int i, PhoneLine l, double scale) {
    final key = _rowKeys.putIfAbsent(i, GlobalKey.new);
    final playingHere = player.currentScene?.sceneNumber == s.number;
    final current = playingHere && l.cueIndex != null && l.cueIndex == player.currentCueIndex;
    final mine = l.isDialog && player.isMyLine(l.speaker);
    final waiting = playingHere && l.cueIndex != null && l.cueIndex == player.waitingAtCue;
    final revealed = playingHere && l.cueIndex != null && l.cueIndex == player.revealedCue;
    final blocked = mine && player.blockMyLines && !revealed;
    final a = _selA, b = _selB;
    final selected = a != null && b != null && i >= (a < b ? a : b) && i <= (a < b ? b : a);
    final textStyle = TextStyles.script(
      t,
      size: 15 * scale,
      italic: !l.isDialog,
      // The highlighter is yellow in both themes: dark ink on it.
      color: current ? const Color(0xFF1C1B19) : (blocked ? t.muted : (l.isDialog ? t.ink : t.ink2)),
    ).copyWith(height: 1.45, letterSpacing: blocked ? 0.3 : null);
    final body = l.isDialog
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final n in l.names) NameChip(n, allSpeakers: session.characters, uppercase: true, size: 12.5 * scale),
                  if (mine) Text('· YOU', style: TextStyles.ui(t, size: 11 * scale, weight: FontWeight.w600, color: current ? const Color(0xFF46433E) : t.ink2)),
                ],
              ),
              const SizedBox(height: 3),
              Text(blocked ? blockText(l.text) : l.text, style: textStyle),
              if (waiting && blocked)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Tap the line to peek', style: TextStyles.ui(t, size: 13, weight: FontWeight.w600, color: const Color(0xFF2C6BC9))),
                ),
            ],
          )
        : Text(l.text, style: textStyle);
    final Color? fill = current ? t.highlighter : (selected ? t.accentSoft : (mine ? t.mine : null));
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: () => _tapLine(s, l),
      onLongPressStart: s.rendered && l.cueIndex != null ? (_) => setState(() => _selA = _selB = i) : null,
      onLongPressMoveUpdate: s.rendered
          ? (d) {
              final j = _lineAt(d.globalPosition);
              if (j != null && j != _selB && s.lines[j].cueIndex != null) setState(() => _selB = j);
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(6),
          border: current ? Border.all(color: t.highlighterEdge, width: 2) : (selected ? Border.all(color: t.accentLine, width: 1.5) : null),
        ),
        child: body,
      ),
    );
  }

  Widget _cueCard(Tokens t) => Container(
    margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
    padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
    decoration: BoxDecoration(color: t.sheet, borderRadius: BorderRadius.circular(16), boxShadow: t.shadow),
    child: Row(
      children: [
        Text('Your line', style: TextStyles.hand(t, size: 26, color: t.accent)),
        const SizedBox(width: 12),
        Expanded(child: Text('Say it, then tap play or your AirPods.', style: TextStyles.ui(t, size: 14, color: t.ink2))),
        if (player.blockMyLines)
          FilledButton(
            onPressed: player.callForLine,
            style: FilledButton.styleFrom(
              backgroundColor: t.highlighter,
              foregroundColor: const Color(0xFF1C1B19),
              side: const BorderSide(color: Color(0xFF1C1B19), width: 2),
              minimumSize: const Size(44, 40),
            ),
            child: Text('Line!', style: TextStyles.ui(t, size: 15, weight: FontWeight.w700, color: const Color(0xFF1C1B19))),
          ),
      ],
    ),
  );

  Widget _selectionBar(Tokens t) {
    final n = ((_selA! - _selB!).abs()) + 1;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(color: t.sheet, borderRadius: BorderRadius.circular(16), boxShadow: t.shadow),
      child: Row(
        children: [
          Expanded(child: Text('$n line${n == 1 ? '' : 's'} selected', style: TextStyles.ui(t, size: 15, weight: FontWeight.w600))),
          TextButton(onPressed: () => setState(_clearSelection), child: const Text('Cancel')),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: _loopSelection,
            icon: const Icon(Icons.repeat_rounded, size: 18),
            label: const Text('Loop'),
            style: FilledButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.onAccent),
          ),
        ],
      ),
    );
  }

  Widget _bar(Tokens t) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final clock = TextStyles.ui(t, size: 12, color: t.barInk.withValues(alpha: 0.7)).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    Widget round(IconData icon, String label, VoidCallback? onTap, {double size = 48, Color? bg, double iconSize = 24}) => Semantics(
      button: true,
      label: label,
      child: Material(
        color: bg ?? t.barBtn,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Icon(icon, color: t.barInk, size: iconSize)),
        ),
      ),
    );
    Widget pill(String label, VoidCallback onTap, {IconData? icon, bool strong = false}) => Material(
      color: strong ? t.barBtnOn : t.barBtn,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 16, color: t.barInk), const SizedBox(width: 6)],
              Flexible(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyles.ui(t, size: 14, weight: FontWeight.w600, color: t.barInk)),
              ),
            ],
          ),
        ),
      ),
    );
    final waiting = player.waitingAtCue != null;
    return Container(
      decoration: BoxDecoration(color: t.bar, borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
      padding: EdgeInsets.fromLTRB(18, 10, 18, 12 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (player.flash != null) Text(player.flash!, style: TextStyles.hand(t, size: 20, color: t.highlighter)),
          Row(
            children: [
              Text(_clockText(player.currentTime), style: clock),
              const SizedBox(width: 10),
              Expanded(
                // Room for the knob at either end.
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  child: SceneTimeline(player: player, allSpeakers: session.characters, height: 36, knob: 11),
                ),
              ),
              const SizedBox(width: 10),
              Text(_clockText(player.duration), style: clock),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // The side buttons share what the transport leaves.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: pill(player.myRole.isEmpty ? 'My Role' : titleCaseName(player.myRole), _openPanel),
                ),
              ),
              const SizedBox(width: 8),
              round(Icons.fast_rewind_rounded, 'Previous line', player.prevLine, size: 44),
              const SizedBox(width: 8),
              round(
                player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                player.isPlaying ? 'Pause' : (waiting ? 'Carry on' : 'Play'),
                () {
                  if (viewing != player.currentScene?.sceneNumber) _showScene(player.currentScene!.sceneNumber);
                  player.togglePlayPause();
                },
                size: 60,
                bg: t.accent,
                iconSize: 32,
              ),
              const SizedBox(width: 8),
              round(Icons.fast_forward_rounded, 'Next line', player.nextLine, size: 44),
              const SizedBox(width: 8),
              Expanded(child: Align(alignment: Alignment.centerRight, child: pill('Rehearse', _openPanel, strong: true))),
            ],
          ),
        ],
      ),
    );
  }

  // Sheets ---------------------------------------------------------------------

  Future<void> _openPanel() async {
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.sheet,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => ListenableBuilder(
        listenable: player,
        builder: (ctx, _) => _RehearsePanel(player: player, session: session, viewing: viewing, onScene: (n) {
          Navigator.pop(ctx);
          _showScene(n);
        }),
      ),
    );
  }

  Future<void> _openScenes() async {
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.sheet,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (ctx, sc) => _SceneList(
          session: session,
          viewing: viewing,
          controller: sc,
          onScene: (n) {
            Navigator.pop(ctx);
            _showScene(n);
          },
        ),
      ),
    );
  }

  Future<void> _openTextOptions() async {
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.sheet,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('TEXT SIZE', style: TextStyles.label(t)),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [for (var i = 0; i < 4; i++) ButtonSegment(value: i, label: Text(_textSizeLabels[i].split(' ').last))],
                  selected: {textSize},
                  onSelectionChanged: (v) async {
                    setState(() => textSize = v.first);
                    set(() {});
                    (await SharedPreferences.getInstance()).setInt('phoneTextSize', v.first);
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Character colors'),
                  subtitle: const Text('A color for each character’s name'),
                  value: characterColorsEnabled,
                  onChanged: (v) async {
                    characterColorsEnabled = v;
                    setState(() {});
                    set(() {});
                    (await SharedPreferences.getInstance()).setBool('phoneCharacterColors', v);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _clockText(double s) {
  final m = s ~/ 60, sec = (s % 60).floor();
  return '$m:${sec.toString().padLeft(2, '0')}';
}

/// Role, practice toggles, loop, speed and scene: the Mac's playback-bar
/// options, as one panel.
class _RehearsePanel extends StatelessWidget {
  const _RehearsePanel({required this.player, required this.session, required this.viewing, required this.onScene});
  final RehearsalPlayer player;
  final RehearsalSession session;
  final int? viewing;
  final ValueChanged<int> onScene;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final hasRole = player.myRole.isNotEmpty;
    Widget chip(String label, String role) {
      final on = player.myRole == role;
      return ChoiceChip(
        label: Text(label),
        selected: on,
        showCheckmark: false,
        onSelected: (_) => player.setRole(role),
        labelStyle: TextStyles.ui(t, size: 15, weight: on ? FontWeight.w700 : FontWeight.w500, color: on ? const Color(0xFF1C1B19) : t.ink2),
        selectedColor: t.highlighter,
        backgroundColor: t.panel,
        side: on ? const BorderSide(color: Color(0xFF1C1B19), width: 2) : BorderSide.none,
        shape: const StadiumBorder(),
      );
    }

    Widget toggle(String title, String sub, bool value, ValueChanged<bool> set) => SwitchListTile(
      title: Text(title, style: TextStyles.ui(t, size: 16, weight: FontWeight.w600)),
      subtitle: Text(sub, style: TextStyles.ui(t, size: 13, color: t.muted)),
      value: value && hasRole,
      onChanged: hasRole ? set : null,
    );
    final scene = session.scenes.where((s) => s.number == (player.currentScene?.sceneNumber ?? viewing)).firstOrNull;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Rehearse', style: TextStyles.ui(t, size: 22, weight: FontWeight.w700))),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                ],
              ),
              const SizedBox(height: 8),
              Text('MY ROLE', style: TextStyles.label(t)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [chip('No one', ''), for (final c in session.characters) chip(titleCaseName(c), c)],
              ),
              const SizedBox(height: 16),
              Material(
                color: t.panel,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    toggle('Mute My Lines', 'Silence where you speak', player.muteMyLines, player.setMute),
                    Divider(height: 1, indent: 16, color: t.ruleSoft),
                    toggle('Block My Lines', 'Blank them out to test memory', player.blockMyLines, player.setBlock),
                    Divider(height: 1, indent: 16, color: t.ruleSoft),
                    toggle('Stop Before My Lines', 'Pause so you can say it, then carry on', player.cueMode, player.setCueMode),
                  ],
                ),
              ),
              if (!hasRole)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text('Pick your role to use these.', style: TextStyles.ui(t, size: 13, color: t.muted)),
                ),
              const SizedBox(height: 18),
              Text('LOOP', style: TextStyles.label(t)),
              const SizedBox(height: 8),
              SegmentedButton<LoopMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: LoopMode.off, label: Text('Off')),
                  ButtonSegment(value: LoopMode.scene, label: Text('Scene')),
                  ButtonSegment(value: LoopMode.lines, label: Text('Lines')),
                ],
                selected: {player.loopMode},
                onSelectionChanged: (v) {
                  final m = v.first;
                  if (m == LoopMode.lines && !(player.loopEnd > player.loopStart)) return; // pick lines first
                  player.setLoop(m, start: player.loopStart, end: player.loopEnd);
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text('To loop some lines, long-press a line in the script and drag.', style: TextStyles.ui(t, size: 13, color: t.muted)),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(child: Text('SPEED', style: TextStyles.label(t))),
                  Text('${player.playbackRate.toStringAsFixed(2)}×', style: TextStyles.ui(t, size: 15, weight: FontWeight.w600)),
                ],
              ),
              Slider(value: player.playbackRate, min: 0.5, max: 2, divisions: 30, onChanged: player.setRate),
              const SizedBox(height: 6),
              if (scene != null)
                ListTile(
                  tileColor: t.panel,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  title: Text('Scene ${scene.number} · ${scene.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyles.ui(t, size: 16, weight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    final picked = await showModalBottomSheet<int>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: t.sheet,
                      showDragHandle: true,
                      builder: (ctx) => DraggableScrollableSheet(
                        expand: false,
                        initialChildSize: 0.6,
                        maxChildSize: 0.92,
                        builder: (ctx, sc) => _SceneList(session: session, viewing: viewing, controller: sc, onScene: (n) => Navigator.pop(ctx, n)),
                      ),
                    );
                    if (picked != null) onScene(picked);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SceneList extends StatelessWidget {
  const _SceneList({required this.session, required this.viewing, required this.controller, required this.onScene});
  final RehearsalSession session;
  final int? viewing;
  final ScrollController controller;
  final ValueChanged<int> onScene;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return ListView.builder(
      controller: controller,
      itemCount: session.scenes.length,
      itemBuilder: (context, i) {
        final s = session.scenes[i];
        return ListTile(
          selected: s.number == viewing,
          selectedTileColor: t.accentSoft,
          leading: Text(s.number.toString().padLeft(2, '0'), style: TextStyles.script(t, size: 14, weight: FontWeight.w700)),
          title: Text(s.title, style: TextStyles.ui(t, size: 16)),
          subtitle: Text('${s.lines.length} lines', style: TextStyles.ui(t, color: t.muted)),
          trailing: s.rendered ? Icon(Icons.graphic_eq_rounded, color: t.ok) : Text('Text only', style: TextStyles.ui(t, size: 12, color: t.muted)),
          onTap: () => onScene(s.number),
        );
      },
    );
  }
}
