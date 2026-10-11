// Project Dashboard: top bar, script area, side panel. Contract: screens[dashboard].

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/platform.dart';
import '../services/project_store.dart';
import '../state/app_state.dart';
import '../state/player_state.dart';
import '../theme/tokens.dart';
import 'empty_art.dart';
import 'popovers.dart';
import 'sheets.dart';
import 'side_panel.dart';
import 'widgets.dart';

/// Lines selected for multi-line actions (one scene at a time).
class LineSelection extends ChangeNotifier {
  int? sceneNumber;
  final Set<String> refs = {};
  final Set<String> addedIds = {};

  bool get isEmpty => refs.isEmpty && addedIds.isEmpty;
  int get count => refs.length + addedIds.length;

  void _scope(int n) {
    if (sceneNumber != n) {
      refs.clear();
      addedIds.clear();
      sceneNumber = n;
    }
  }

  void toggle(int n, String ref) {
    _scope(n);
    refs.contains(ref) ? refs.remove(ref) : refs.add(ref);
    notifyListeners();
  }

  void toggleAdded(int n, String id) {
    _scope(n);
    addedIds.contains(id) ? addedIds.remove(id) : addedIds.add(id);
    notifyListeners();
  }

  void clear() {
    refs.clear();
    addedIds.clear();
    sceneNumber = null;
    notifyListeners();
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double sideWidth = 340;
  SideTab tab = SideTab.cast;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return ChangeNotifierProvider(
      create: (_) => LineSelection(),
      child: Material(
        color: t.bg,
        child: Column(
          children: [
            const _TopBar(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final maxSide = (c.maxWidth - 450).clamp(240.0, 480.0);
                  final w = sideWidth.clamp(240.0, maxSide);
                  return Row(
                    children: [
                      const Expanded(child: ScriptArea()),
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (d) => setState(() => sideWidth = (w - d.delta.dx).clamp(240.0, maxSide)),
                          child: Container(
                            width: 5,
                            color: Colors.transparent,
                            child: Center(child: Container(width: 1, color: t.rule)),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: SidePanel(tab: tab, onTab: (x) => setState(() => tab = x)),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar();

  Future<void> _back(BuildContext context) async {
    final app = context.read<AppState>();
    if (app.isGenerating) {
      final r = await showConfirm(
        context,
        title: 'A render is in progress.',
        buttons: const [('Keep Rendering', BtnKind.secondary), ('Cancel Render & Go Home', BtnKind.danger)],
      );
      if (r != 'Cancel Render & Go Home') return;
      app.cancelGeneration();
    }
    if (!context.mounted) return;
    context.read<RehearsalPlayer>().pause();
    context.read<LineSelection>().clear();
    app.returnToGallery();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final store = context.watch<ProjectStore>();
    final app = context.watch<AppState>();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => WindowControl.startDrag(),
      onDoubleTap: WindowControl.zoom,
      child: Container(
        height: 52,
        padding: const EdgeInsets.only(left: 84, right: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.rule)),
        ),
        child: Row(
          children: [
            IconBtn(Icons.chevron_left_rounded, size: 20, tooltip: 'Back to Projects', onTap: () => _back(context)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(store.currentProject?.name ?? '', overflow: TextOverflow.ellipsis, style: TextStyles.display(t, size: 17)),
            ),
            const Spacer(),
            if (app.availableUpdate != null) ...[
              Tooltip(
                message: 'A new version of Table Read is available',
                child: Pill('Update Available', icon: Icons.arrow_circle_down_rounded, bg: t.warnSoft, fg: t.warn, onTap: () => showUpdateSheet(context)),
              ),
              const SizedBox(width: 8),
            ],
            const Stamp('BETA'),
            const SizedBox(width: 8),
            _OutlinePill(label: 'Report a Bug', tooltip: 'Report a bug (⌘⇧B)', onTap: () => showBugReportSheet(context)),
            const SizedBox(width: 4),
            IconBtn(Icons.settings_outlined, tooltip: 'Settings (⌘,)', onTap: () => showSettingsSheet(context)),
          ],
        ),
      ),
    );
  }
}

class _OutlinePill extends StatelessWidget {
  const _OutlinePill({required this.label, required this.onTap, this.tooltip});
  final String label;
  final VoidCallback onTap;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Tooltip(
      message: tooltip ?? '',
      child: Hover(
        cursor: SystemMouseCursors.click,
        builder: (context, h) => GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: h ? t.ctrl : Colors.transparent,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: t.border),
            ),
            child: Text(
              label,
              style: TextStyles.ui(t, size: 11.5, weight: FontWeight.w600, color: t.ink2),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Script area
// ---------------------------------------------------------------------------

class ScriptArea extends StatefulWidget {
  const ScriptArea({super.key});
  @override
  State<ScriptArea> createState() => _ScriptAreaState();
}

class _ScriptAreaState extends State<ScriptArea> {
  final ScrollController _scroll = ScrollController();
  final Set<int> _expanded = {};
  final Set<int> _showAll = {};
  final GlobalKey _activeLineKey = GlobalKey();
  DateTime _lastManualScroll = DateTime.fromMillisecondsSinceEpoch(0);
  int? _lastActiveScene;
  int _lastCue = -1;

  void _followPlayback(RehearsalPlayer player) {
    final scene = player.isPlaying || player.currentCueIndex >= 0 ? player.currentScene?.sceneNumber : null;
    if (scene != null && scene != _lastActiveScene) {
      _lastActiveScene = scene;
      _expanded.add(scene);
    }
    if (player.currentCueIndex != _lastCue) {
      _lastCue = player.currentCueIndex;
      if (DateTime.now().difference(_lastManualScroll) > const Duration(seconds: 3)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _activeLineKey.currentContext;
          if (ctx != null && ctx.mounted) {
            Scrollable.ensureVisible(ctx, alignment: 0.45, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final player = context.watch<RehearsalPlayer>();
    final sel = context.watch<LineSelection>();
    final script = app.script;

    if (script == null) {
      if (app.isParsing) {
        return const EmptyState(art: EmptyArt.pages, title: 'Parsing script…');
      }
      return const EmptyState(art: EmptyArt.titlePage, title: 'No script loaded', message: 'Open a PDF to review parsed scenes and characters.');
    }
    _followPlayback(player);
    final activeScene = (player.isPlaying || player.currentCueIndex >= 0) ? player.currentScene?.sceneNumber : null;

    return Stack(
      children: [
        Column(
          children: [
            _statsStrip(t, app, script),
            Expanded(
              child: NotificationListener<UserScrollNotification>(
                onNotification: (n) {
                  if (n.direction != ScrollDirection.idle) _lastManualScroll = DateTime.now();
                  return false;
                },
                child: Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.fromLTRB(16, 16, 16, sel.isEmpty ? 24 : 88),
                    itemCount: script.scenes.length,
                    itemBuilder: (context, i) {
                      final s = script.scenes[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: activeScene != null && activeScene != s.number ? 0.55 : 1,
                          child: SceneCard(
                            scene: s,
                            expanded: _expanded.contains(s.number),
                            showAll: _showAll.contains(s.number),
                            activeLineKey: activeScene == s.number ? _activeLineKey : null,
                            onToggleExpand: () => setState(() {
                              if (!_expanded.remove(s.number)) {
                                _expanded.add(s.number);
                              } else {
                                _showAll.remove(s.number);
                                if (sel.sceneNumber == s.number) sel.clear();
                              }
                            }),
                            onToggleShowAll: () => setState(() => _showAll.contains(s.number) ? _showAll.remove(s.number) : _showAll.add(s.number)),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
        if (app.canUndo || app.canRedo)
          Positioned(
            top: 48,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingBar(
                children: [
                  BarButton('Undo ${app.undoCount}', icon: Icons.undo_rounded, enabled: app.canUndo, onTap: app.undo, tooltip: 'Undo (⌘Z)'),
                  BarButton('Redo', icon: Icons.redo_rounded, enabled: app.canRedo, onTap: app.redo, tooltip: 'Redo (⇧⌘Z)'),
                ],
              ),
            ),
          ),
        if (!sel.isEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: Center(child: _SelectionBar(selection: sel)),
          ),
      ],
    );
  }

  Widget _statsStrip(Tokens t, AppState app, ScriptSummary s) {
    Widget stat(int n, String word) => Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$n ',
            style: TextStyles.ui(t, size: 12.5, weight: FontWeight.w700),
          ),
          TextSpan(
            text: word,
            style: TextStyles.ui(t, size: 12.5, color: t.ink2),
          ),
        ],
      ),
    );
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.rule)),
      ),
      child: Row(
        children: [
          stat(s.sceneCount, 'scenes'),
          const SizedBox(width: 16),
          stat(s.characterCount, 'characters'),
          const SizedBox(width: 16),
          stat(s.lineCount, 'lines'),
          if (app.isFetchingVoices) ...[
            const SizedBox(width: 18),
            SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.6, color: t.muted)),
            const SizedBox(width: 6),
            Text('Loading voices…', style: TextStyles.ui(t, size: 12, color: t.muted)),
          ],
          const Spacer(),
          Btn('Select All', kind: BtnKind.plain, small: true, onPressed: app.selectAllScenes),
          const SizedBox(width: 10),
          Btn('Select None', kind: BtnKind.plain, small: true, onPressed: app.clearSceneSelection),
          const SizedBox(width: 10),
          Btn(
            'Skip Rendered',
            kind: BtnKind.plain,
            small: true,
            tooltip: "Select only scenes that haven't been rendered yet",
            onPressed: app.selectMissingScenes,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scene card
// ---------------------------------------------------------------------------

class SceneCard extends StatefulWidget {
  const SceneCard({
    super.key,
    required this.scene,
    required this.expanded,
    required this.showAll,
    required this.onToggleExpand,
    required this.onToggleShowAll,
    this.activeLineKey,
  });
  final Scene scene;
  final bool expanded, showAll;
  final VoidCallback onToggleExpand, onToggleShowAll;
  final GlobalKey? activeLineKey;
  @override
  State<SceneCard> createState() => _SceneCardState();
}

class _SceneCardState extends State<SceneCard> {
  bool editingTitle = false;
  late final TextEditingController titleCtl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final s = widget.scene;
    final selected = app.selectedScenes.contains(s.number);
    final rendered = app.sceneFileInfo[s.number]?.exists == true;
    final speakers = s.speakers;
    return Container(
      decoration: BoxDecoration(
        color: t.sheet,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: selected ? t.accentLine : t.border, width: selected ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: widget.onToggleExpand,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
              child: Row(
                children: [
                  CheckMark(
                    checked: selected,
                    onTap: () => app.toggleScene(s.number),
                    tooltip: selected ? 'Included in the next render' : 'Not included in the next render',
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 34,
                    child: Row(
                      children: [
                        Text(s.number.toString().padLeft(2, '0'), style: TextStyles.script(t, size: 12, weight: FontWeight.w700)),
                        if (rendered) ...[
                          const SizedBox(width: 4),
                          Tooltip(
                            message: 'Already rendered — output file exists',
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(color: t.okDot, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: editingTitle ? _titleEditor(t, app, s) : _title(t, app, s)),
                  const SizedBox(width: 10),
                  for (final sp in speakers.take(5))
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: NameChip(sp, allSpeakers: app.allSpeakers),
                    ),
                  if (speakers.length > 5)
                    Padding(
                      padding: const EdgeInsets.only(left: 5),
                      child: Text('+${speakers.length - 5}', style: TextStyles.ui(t, size: 11, color: t.faint)),
                    ),
                  SizedBox(
                    width: 66,
                    child: Text(
                      '${s.elementCount} lines',
                      textAlign: TextAlign.right,
                      style: TextStyles.ui(t, size: 12, color: t.muted),
                    ),
                  ),
                  IconBtn(widget.expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, onTap: widget.onToggleExpand),
                ],
              ),
            ),
          ),
          if (widget.expanded) ...[
            Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 12), color: t.rule),
            _Lines(scene: s, showAll: widget.showAll, onToggleShowAll: widget.onToggleShowAll, activeLineKey: widget.activeLineKey),
          ],
        ],
      ),
    );
  }

  Widget _title(Tokens t, AppState app, Scene s) => Hover(
    builder: (context, h) => Row(
      children: [
        Flexible(
          child: Text(
            app.effectiveSceneTitle(s),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyles.ui(t, weight: FontWeight.w600, color: app.selectedScenes.contains(s.number) ? t.ink : t.ink2),
          ),
        ),
        const SizedBox(width: 6),
        AnimatedOpacity(
          opacity: h ? 1 : 0,
          duration: const Duration(milliseconds: 100),
          child: Pill(
            'Edit',
            onTap: () {
              titleCtl.text = app.effectiveSceneTitle(s);
              setState(() => editingTitle = true);
            },
          ),
        ),
      ],
    ),
  );

  Widget _titleEditor(Tokens t, AppState app, Scene s) {
    void commit() {
      app.setSceneTitle(s, titleCtl.text);
      setState(() => editingTitle = false);
    }

    return Row(
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => editingTitle = false)},
            child: TextField(
              controller: titleCtl,
              autofocus: true,
              onSubmitted: (_) => commit(),
              style: TextStyles.ui(t, weight: FontWeight.w600),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Scene title',
                filled: true,
                fillColor: t.field,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(5),
                  borderSide: BorderSide(color: t.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(5),
                  borderSide: BorderSide(color: t.accent, width: 1.5),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Pill('Save', bg: t.accent, fg: t.onAccent, onTap: commit),
      ],
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({required this.scene, required this.showAll, required this.onToggleShowAll, this.activeLineKey});
  final Scene scene;
  final bool showAll;
  final VoidCallback onToggleShowAll;
  final GlobalKey? activeLineKey;
  static const initialLimit = 30;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = context.watch<RehearsalPlayer>();
    final total = scene.elements.length;
    final limit = showAll ? total : initialLimit;
    final merged = app.mergedElements(scene, limit: limit);
    // Which row is playing: the cue's text, matched by occurrence, so a line
    // that repeats an earlier line's words doesn't light up both.
    final playingHere = player.currentScene?.sceneNumber == scene.number;
    final activeRow = playingHere
        ? activeRowIndex([for (final m in merged) _rowText(app, m)], [for (final c in player.cues) c.text], player.currentCueIndex)
        : -1;
    var row = -1;
    bool isActive() => ++row == activeRow;
    GlobalKey? keyIf(bool active) => active ? activeLineKey : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in merged)
            if (isActive()) _row(app, m, true, keyIf(true)) else _row(app, m, false, null),
          if (total > initialLimit)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 6, 12, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Btn(
                  showAll ? 'Show fewer lines' : 'Show all $total lines (${total - initialLimit} more)',
                  kind: BtnKind.link,
                  small: true,
                  icon: showAll ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  onPressed: onToggleShowAll,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(AppState app, MergedElement m, bool active, GlobalKey? key) => switch (m) {
    ParsedItem(:final element) =>
      element.isOverlap && _showsTwoPanel(app, element)
          ? SimultaneousRow(key: key, scene: scene, element: element, active: active)
          : LineRow(key: key, scene: scene, element: element, active: active),
    ManualOverlapItem(:final primary, :final secondary) => ManualPairRow(key: key, scene: scene, primary: primary, secondary: secondary, active: active),
    AddedItem(:final element) => AddedLineRow(key: key, scene: scene, element: element, active: active),
  };

  /// The words this row is voiced with (null when it isn't voiced).
  String? _rowText(AppState app, MergedElement m) {
    switch (m) {
      case ParsedItem(:final element):
        final fix = app.correctionFor(scene.number, element);
        if (fix?.markedAsNoise == true) return null;
        return (fix?.correctedText?.isNotEmpty ?? false) ? fix!.correctedText! : element.text;
      case ManualOverlapItem(:final primary):
        final fix = app.correctionFor(scene.number, primary);
        return (fix?.correctedText?.isNotEmpty ?? false) ? fix!.correctedText! : primary.text;
      case AddedItem(:final element):
        return element.text.trim().isEmpty ? null : element.text;
    }
  }

  bool _showsTwoPanel(AppState app, SceneElement el) {
    final fix = app.correctionFor(scene.number, el);
    final kind = fix?.correctedKind ?? el.kind;
    final cue = fix?.correctedOverlapSpeakers ?? el.overlapCue ?? const [];
    return kind == 'dialog' && cue.length >= 2;
  }
}

// ---------------------------------------------------------------------------
// Line rows
// ---------------------------------------------------------------------------

/// Index of the playing row. The cue at [cueIndex] is the k-th cue with its
/// words; the playing row is the k-th row with the same words. Rows with null
/// text (removed lines) never match. Returns -1 when nothing matches.
int activeRowIndex(List<String?> rowTexts, List<String> cueTexts, int cueIndex) {
  if (cueIndex < 0 || cueIndex >= cueTexts.length) return -1;
  final want = cueTexts[cueIndex].trim();
  var k = 0;
  for (var i = 0; i < cueIndex; i++) {
    if (cueTexts[i].trim() == want) k++;
  }
  var seen = 0;
  for (var i = 0; i < rowTexts.length; i++) {
    if (rowTexts[i]?.trim() == want) {
      if (seen == k) return i;
      seen++;
    }
  }
  return -1;
}

/// Replaces letters with underscores, keeping spaces and punctuation (Block My Lines).
String blockText(String s) => s.replaceAll(RegExp(r'\p{L}|\p{N}', unicode: true), '_');

class _Gutter extends StatelessWidget {
  const _Gutter({required this.checked, required this.onCheck, required this.visible});
  final bool checked;
  final VoidCallback onCheck;

  /// Checkboxes stay hidden until the row is hovered, checked, or a selection
  /// is under way in this scene.
  final bool visible;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: Padding(
        padding: const EdgeInsets.only(top: 3, left: 16),
        child: Align(
          alignment: Alignment.topLeft,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: IgnorePointer(
              ignoring: !visible,
              child: CheckMark(checked: checked, onTap: onCheck, size: 12),
            ),
          ),
        ),
      ),
    );
  }
}

/// Row chrome shared by every line: hover, selection, playing highlight.
class _RowShell extends StatelessWidget {
  const _RowShell({required this.child, required this.selected, required this.active, required this.onHover});
  final Widget child;
  final bool selected, active;
  final ValueChanged<bool> onHover;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Container(
        decoration: BoxDecoration(
          color: active ? t.accentSoft : (selected ? t.accentSoft.withValues(alpha: t.accentSoft.a * 0.7) : Colors.transparent),
          border: Border(left: BorderSide(color: active ? t.accent : Colors.transparent, width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(0, 5, 10, 5),
        child: child,
      ),
    );
  }
}

class LineRow extends StatefulWidget {
  const LineRow({super.key, required this.scene, required this.element, required this.active});
  final Scene scene;
  final SceneElement element;
  final bool active;
  @override
  State<LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<LineRow> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final player = context.watch<RehearsalPlayer>();
    final sel = context.watch<LineSelection>();
    final el = widget.element;
    final n = widget.scene.number;
    final fix = app.correctionFor(n, el);
    final removed = fix?.markedAsNoise == true;
    final kind = fix?.correctedKind ?? el.kind;
    var speaker = el.displaySpeaker;
    if (fix?.correctedSpeaker != null) speaker = fix!.correctedSpeaker!.isEmpty ? 'Narrator' : fix.correctedSpeaker!;
    if (kind != 'dialog') speaker = 'Narrator';
    final text = (fix?.correctedText?.isNotEmpty ?? false) ? fix!.correctedText! : el.text;
    final isDialog = kind == 'dialog' && speaker != 'Narrator';
    final mine = isDialog && player.myRole.isNotEmpty && player.isMyLine(speaker);
    final shownText = mine && player.blockMyLines ? blockText(text) : text;
    final flagged = el.confidence < 0.7 && fix == null && !removed;
    final selected = sel.sceneNumber == n && sel.refs.contains(el.ref);

    final textStyle = TextStyles.script(
      t,
      italic: !isDialog,
      color: removed ? t.faint : (isDialog ? t.ink : t.ink2),
    ).copyWith(decoration: removed ? TextDecoration.lineThrough : null, decorationColor: t.muted, backgroundColor: mine && !removed ? t.mine : null);

    final body = isDialog
        ? LayoutBuilder(
            builder: (context, c) => Padding(
              padding: EdgeInsets.only(left: c.maxWidth * 0.12, right: c.maxWidth * 0.12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: NameChip(speaker, allSpeakers: app.allSpeakers, uppercase: true, strike: removed),
                  ),
                  const SizedBox(height: 2),
                  Text(shownText, style: textStyle),
                ],
              ),
            ),
          )
        : Text.rich(
            TextSpan(
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: NameChip('NARRATOR', allSpeakers: app.allSpeakers, uppercase: true, size: 9.5, strike: removed),
                  ),
                ),
                TextSpan(text: shownText, style: textStyle),
              ],
            ),
          );

    return _RowShell(
      selected: selected,
      active: widget.active,
      onHover: (v) => setState(() => hover = v),
      child: Opacity(
        opacity: removed ? 0.6 : 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Gutter(checked: selected, onCheck: () => sel.toggle(n, el.ref), visible: hover || selected || sel.sceneNumber == n && !sel.isEmpty),
            Expanded(child: body),
            SizedBox(
              width: 196,
              child: hover
                  ? Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        Builder(
                          builder: (ctx) => Pill(
                            'Edit',
                            bg: speakerColors(speaker, app.allSpeakers, t).highlight,
                            fg: t.nameInk,
                            onTap: () => showPopover(ctx, (_) => CorrectLinePopover(sceneNumber: n, element: el), width: 340),
                          ),
                        ),
                        Pill(
                          removed ? 'Restore' : 'Remove',
                          icon: removed ? Icons.undo_rounded : Icons.remove_circle_outline_rounded,
                          bg: removed ? null : t.dangerSoft,
                          fg: removed ? null : t.danger,
                          tooltip: removed ? 'Restore this line' : "Mark line as removed (won't be voiced)",
                          onTap: () => app.toggleRemoved(n, el),
                        ),
                        Pill(
                          'Add line',
                          icon: Icons.add_circle_outline_rounded,
                          tooltip: 'Insert a new line below this one',
                          onTap: () => app.addLine(n, afterRef: el.ref, speaker: kind == 'dialog' ? (speaker == 'Narrator' ? '' : speaker) : ''),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (mine && player.muteMyLines)
                          Padding(
                            padding: const EdgeInsets.only(right: 8, top: 2),
                            child: Tooltip(
                              message: 'Your line — muted during playback',
                              child: Icon(Icons.volume_off_rounded, size: 14, color: t.muted),
                            ),
                          ),
                        if (fix != null && !removed)
                          Tooltip(
                            message: 'User correction applied',
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_rounded, size: 15, color: t.accent),
                                Text('fixed', style: TextStyles.hand(t, size: 18, color: t.accent)),
                              ],
                            ),
                          ),
                        if (flagged)
                          Tooltip(
                            message: el.reason ?? 'Parser is uncertain about this line — check the speaker or type',
                            child: Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Text('?', style: TextStyles.hand(t, size: 26, color: t.warn)),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A line the parser found as two voices at once.
class SimultaneousRow extends StatefulWidget {
  const SimultaneousRow({super.key, required this.scene, required this.element, required this.active});
  final Scene scene;
  final SceneElement element;
  final bool active;
  @override
  State<SimultaneousRow> createState() => _SimultaneousRowState();
}

class _SimultaneousRowState extends State<SimultaneousRow> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final sel = context.watch<LineSelection>();
    final el = widget.element;
    final n = widget.scene.number;
    final fix = app.correctionFor(n, el);
    final removed = fix?.markedAsNoise == true;
    final cue = fix?.correctedOverlapSpeakers ?? el.overlapCue!;
    final texts = fix?.correctedOverlapTexts ?? el.overlapTexts;
    final rv = fix?.removedVoiceIndex;
    final selected = sel.sceneNumber == n && sel.refs.contains(el.ref);

    Widget voice(int i) {
      final name = i < cue.length ? cue[i] : '';
      final txt = (texts != null && i < texts.length) ? texts[i] : ((fix?.correctedText?.isNotEmpty ?? false) ? fix!.correctedText! : el.text);
      final voiceRemoved = removed || rv == 2 || rv == i;
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              NameChip(name, allSpeakers: app.allSpeakers, uppercase: true, strike: voiceRemoved),
              if (fix != null && !voiceRemoved) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'User correction applied',
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
                  ),
                ),
              ],
            ],
          ),
          if (hover && !(removed && i == 1)) ...[
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                if (removed && fix?.isSplit == true && i == 0)
                  Pill('Relink', icon: Icons.link_rounded, tooltip: 'Restore as simultaneous lines', onTap: () => app.relinkParserOverlap(n, el))
                else if (voiceRemoved)
                  Pill('Restore', icon: Icons.undo_rounded, tooltip: 'Restore this voice', onTap: () => app.restoreOverlapVoice(n, el, i))
                else ...[
                  Builder(
                    builder: (ctx) => Pill(
                      'Edit',
                      bg: speakerColors(name, app.allSpeakers, t).highlight,
                      fg: t.nameInk,
                      onTap: () => showPopover(ctx, (_) => EditVoicePopover(sceneNumber: n, element: el, voiceIndex: i), width: 320),
                    ),
                  ),
                  Pill(
                    'Remove',
                    icon: Icons.remove_circle_outline_rounded,
                    bg: t.dangerSoft,
                    fg: t.danger,
                    tooltip: 'Remove this voice',
                    onTap: () => app.markOverlapVoiceRemoved(n, el, i),
                  ),
                  if (i == 0) ...[
                    Pill('Unlink', icon: Icons.link_off_rounded, tooltip: 'Split into two separate solo lines', onTap: () => app.splitParserOverlap(n, el)),
                    Pill(
                      'Add line',
                      icon: Icons.add_circle_outline_rounded,
                      tooltip: 'Insert a new line below this one',
                      onTap: () => app.addLine(n, afterRef: el.ref, speaker: cue.first),
                    ),
                  ],
                ],
              ],
            ),
          ],
          const SizedBox(height: 3),
          Text(
            txt,
            textAlign: TextAlign.center,
            maxLines: voiceRemoved ? 1 : null,
            overflow: voiceRemoved ? TextOverflow.ellipsis : null,
            style: TextStyles.script(
              t,
              color: voiceRemoved ? t.faint : t.ink,
            ).copyWith(decoration: voiceRemoved ? TextDecoration.lineThrough : null, decorationColor: t.muted),
          ),
        ],
      );
    }

    return _RowShell(
      selected: selected,
      active: widget.active,
      onHover: (v) => setState(() => hover = v),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Gutter(checked: selected, onCheck: () => sel.toggle(n, el.ref), visible: hover || selected || sel.sceneNumber == n && !sel.isEmpty),
          Expanded(
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: voice(0)),
                  Container(width: 1, margin: const EdgeInsets.symmetric(horizontal: 14), color: t.rule),
                  Expanded(child: voice(1)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

/// Two lines the user made simultaneous.
class ManualPairRow extends StatefulWidget {
  const ManualPairRow({super.key, required this.scene, required this.primary, required this.secondary, required this.active});
  final Scene scene;
  final SceneElement primary, secondary;
  final bool active;
  @override
  State<ManualPairRow> createState() => _ManualPairRowState();
}

class _ManualPairRowState extends State<ManualPairRow> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final sel = context.watch<LineSelection>();
    final n = widget.scene.number;
    final selected = sel.sceneNumber == n && sel.refs.contains(widget.primary.ref);

    Widget voice(SceneElement el, bool first) {
      final fix = app.correctionFor(n, el);
      final removed = fix?.markedAsNoise == true;
      final s = fix?.correctedSpeaker;
      final name = s == null ? (el.speaker ?? 'Narrator') : (s.isEmpty ? 'Narrator' : s);
      final txt = (fix?.correctedText?.isNotEmpty ?? false) ? fix!.correctedText! : el.text;
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [NameChip(name, allSpeakers: app.allSpeakers, uppercase: true, strike: removed)],
          ),
          if (hover) ...[
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                Builder(
                  builder: (ctx) => Pill(
                    'Edit',
                    bg: speakerColors(name, app.allSpeakers, t).highlight,
                    fg: t.nameInk,
                    onTap: () => showPopover(
                      ctx,
                      (_) => EditVoicePopover(sceneNumber: n, element: el, voiceIndex: first ? 0 : 1, manualPair: first ? widget.secondary : widget.primary),
                      width: 320,
                    ),
                  ),
                ),
                Pill(
                  removed ? 'Restore' : 'Remove',
                  icon: removed ? Icons.undo_rounded : Icons.remove_circle_outline_rounded,
                  bg: removed ? null : t.dangerSoft,
                  fg: removed ? null : t.danger,
                  onTap: () => app.toggleRemoved(n, el),
                ),
                if (first)
                  Pill('Unlink', icon: Icons.link_off_rounded, tooltip: 'Split into two separate lines', onTap: () => app.breakSimultaneous(n, widget.primary)),
                if (!first)
                  Pill(
                    'Add line',
                    icon: Icons.add_circle_outline_rounded,
                    tooltip: 'Insert a new line below this pair',
                    onTap: () => app.addLine(n, afterRef: widget.secondary.ref, speaker: name == 'Narrator' ? '' : name),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 3),
          Text(
            txt,
            textAlign: TextAlign.center,
            style: TextStyles.script(
              t,
              color: removed ? t.faint : t.ink,
            ).copyWith(decoration: removed ? TextDecoration.lineThrough : null, decorationColor: t.muted),
          ),
        ],
      );
    }

    return _RowShell(
      selected: selected,
      active: widget.active,
      onHover: (v) => setState(() => hover = v),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Gutter(checked: selected, onCheck: () => sel.toggle(n, widget.primary.ref), visible: hover || selected || sel.sceneNumber == n && !sel.isEmpty),
          Expanded(
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: voice(widget.primary, true)),
                  Container(width: 1, margin: const EdgeInsets.symmetric(horizontal: 14), color: t.rule),
                  Expanded(child: voice(widget.secondary, false)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class AddedLineRow extends StatefulWidget {
  const AddedLineRow({super.key, required this.scene, required this.element, this.active = false});
  final Scene scene;
  final UserAddedElement element;
  final bool active;
  @override
  State<AddedLineRow> createState() => _AddedLineRowState();
}

class _AddedLineRowState extends State<AddedLineRow> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final sel = context.watch<LineSelection>();
    final el = widget.element;
    final n = widget.scene.number;
    final isDialog = el.kind == 'dialog' && el.speaker.isNotEmpty;
    final speaker = isDialog ? el.speaker : 'Narrator';
    final selected = sel.sceneNumber == n && sel.addedIds.contains(el.id);
    final empty = el.text.trim().isEmpty;
    return _RowShell(
      selected: selected,
      active: widget.active,
      onHover: (v) => setState(() => hover = v),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Gutter(checked: selected, onCheck: () => sel.toggleAdded(n, el.id), visible: hover || selected || sel.sceneNumber == n && !sel.isEmpty),
          Expanded(
            child: Column(
              crossAxisAlignment: isDialog ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NameChip(isDialog ? speaker : 'NARRATOR', allSpeakers: app.allSpeakers, uppercase: true, size: isDialog ? 10.5 : 9.5),
                    const SizedBox(width: 6),
                    const Stamp('ADDED'),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  empty ? 'Empty — hover and tap Edit to add text' : el.text,
                  textAlign: isDialog ? TextAlign.center : TextAlign.left,
                  style: empty
                      ? TextStyles.ui(t, size: 12, color: t.faint).copyWith(fontStyle: FontStyle.italic)
                      : TextStyles.script(t, italic: !isDialog, color: isDialog ? t.ink : t.ink2),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 196,
            child: hover
                ? Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    children: [
                      Builder(
                        builder: (ctx) => Pill(
                          'Edit',
                          bg: speakerColors(speaker, app.allSpeakers, t).highlight,
                          fg: t.nameInk,
                          onTap: () => showPopover(ctx, (_) => EditAddedLinePopover(sceneNumber: n, element: el), width: 340),
                        ),
                      ),
                      Pill(
                        '',
                        icon: Icons.remove_circle_outline_rounded,
                        bg: t.dangerSoft,
                        fg: t.danger,
                        tooltip: 'Remove this added line',
                        onTap: () => app.deleteAddedLine(n, el.id),
                      ),
                    ],
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Multi-line selection bar
// ---------------------------------------------------------------------------

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.selection});
  final LineSelection selection;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final n = selection.sceneNumber;
    final scene = app.scenes.where((s) => s.number == n).firstOrNull;
    if (scene == null) return const SizedBox.shrink();
    final els = scene.elements.where((e) => selection.refs.contains(e.ref)).toList();
    final added = (app.userAddedElements[app.addedKey(scene.number)] ?? const <UserAddedElement>[]).where((a) => selection.addedIds.contains(a.id)).toList();
    String kindOf(SceneElement e) => app.correctionFor(scene.number, e)?.correctedKind ?? e.kind;
    final dialogEls = els.where((e) => kindOf(e) == 'dialog').toList();
    final addedDialog = added.where((a) => a.kind == 'dialog').toList();
    final canSimul =
        added.isEmpty &&
        els.length == 2 &&
        els.every((e) => kindOf(e) == 'dialog' && !e.isOverlap && app.correctionFor(scene.number, e)?.manualOverlapPartnerKey == null);

    return FloatingBar(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            '${selection.count} selected',
            style: TextStyles.ui(t, size: 12.5, weight: FontWeight.w600, color: t.barInk),
          ),
        ),
        BarButton(
          'Remove',
          icon: Icons.remove_circle_outline_rounded,
          danger: true,
          tooltip: 'Mark selected lines as removed',
          onTap: () {
            app.removeLines(scene.number, els, added.map((a) => a.id).toList());
            selection.clear();
          },
        ),
        if (canSimul)
          BarButton(
            'Simultaneous',
            icon: Icons.people_alt_outlined,
            tooltip: 'Make selected lines play simultaneously',
            onTap: () {
              final idx0 = scene.elements.indexOf(els[0]), idx1 = scene.elements.indexOf(els[1]);
              final (a, b) = idx0 <= idx1 ? (els[0], els[1]) : (els[1], els[0]);
              app.makeSimultaneous(scene.number, a, b);
              selection.clear();
            },
          ),
        if (dialogEls.isNotEmpty || addedDialog.isNotEmpty)
          Builder(
            builder: (ctx) => BarButton(
              'Speaker',
              icon: Icons.account_circle_outlined,
              tooltip: 'Reassign speaker for selected dialog lines',
              onTap: () {
                showPopover(
                  ctx,
                  (_) => ChangeSpeakerPopover(
                    lineCount: dialogEls.length + addedDialog.length,
                    onApply: (sp) {
                      app.reassignSpeaker(scene.number, dialogEls, addedDialog.map((a) => a.id).toList(), sp);
                      selection.clear();
                    },
                  ),
                  width: 280,
                );
              },
            ),
          ),
        BarButton('', icon: Icons.close_rounded, tooltip: 'Clear selection', onTap: selection.clear),
      ],
    );
  }
}
