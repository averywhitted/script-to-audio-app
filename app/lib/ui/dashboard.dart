// The workspace: header with the tool palette (Cast, Render, search), the
// script, and the playback bar. Contract: screens[dashboard].

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/project_store.dart';
import '../state/app_state.dart';
import '../state/player_state.dart';
import '../theme/tokens.dart';
import 'cast_dialog.dart';
import 'empty_art.dart';
import 'export.dart';
import 'header.dart';
import 'playback_bar.dart';
import 'popovers.dart';
import 'render_dialog.dart';
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

/// Which scenes are open (remembered per project).
class SceneView extends ChangeNotifier {
  final Set<int> expanded = {};
  final Set<int> showAll = {};

  void toggle(int n) {
    if (!expanded.remove(n)) {
      expanded.add(n);
    } else {
      showAll.remove(n);
    }
    notifyListeners();
  }

  void open(int n, {bool all = false}) {
    final changed = expanded.add(n) | (all && showAll.add(n));
    if (changed) notifyListeners();
  }

  void restore(Iterable<int> open) {
    expanded.addAll(open);
    notifyListeners();
  }

  void toggleShowAll(int n) {
    showAll.contains(n) ? showAll.remove(n) : showAll.add(n);
    notifyListeners();
  }
}

/// Find-in-script state for the header search bar.
class SearchState extends ChangeNotifier {
  String query = '';
  int current = 0;

  /// Bumped whenever the user moves to a result, so the script scrolls to it.
  int jumpTick = 0;

  void setQuery(String q) {
    query = q;
    current = 0;
    jumpTick++;
    notifyListeners();
  }

  void step(int delta, int total) {
    if (total == 0) return;
    current = (current + delta) % total;
    if (current < 0) current += total;
    jumpTick++;
    notifyListeners();
  }
}

class SearchHit {
  const SearchHit(this.sceneNumber, this.row);
  final int sceneNumber;
  final int row;
}

bool _matches(String? text, String q) => text != null && q.isNotEmpty && text.toLowerCase().contains(q);

/// Every row whose words (or speaker) contain the query, in script order.
List<SearchHit> searchHits(AppState app, String query) {
  final q = query.trim().toLowerCase();
  if (q.length < 2) return const [];
  final out = <SearchHit>[];
  for (final s in app.scenes) {
    final merged = app.mergedElements(s);
    for (var i = 0; i < merged.length; i++) {
      final (text, speaker) = rowWordsAndSpeaker(app, s, merged[i]);
      if (_matches(text, q) || _matches(speaker, q)) out.add(SearchHit(s.number, i));
    }
  }
  return out;
}

/// The words a row shows and who says them (for search).
(String?, String?) rowWordsAndSpeaker(AppState app, Scene scene, MergedElement m) {
  switch (m) {
    case ParsedItem(:final element):
      final fix = app.correctionFor(scene.number, element);
      final text = (fix?.correctedText?.isNotEmpty ?? false) ? fix!.correctedText! : element.text;
      final sp = fix?.correctedSpeaker ?? element.displaySpeaker;
      final texts = fix?.correctedOverlapTexts ?? element.overlapTexts;
      return (texts != null && texts.isNotEmpty ? texts.join(' ') : text, sp);
    case ManualOverlapItem(:final primary, :final secondary):
      return ('${primary.text} ${secondary.text}', '${primary.speaker ?? ''} ${secondary.speaker ?? ''}');
    case AddedItem(:final element):
      return (element.text, element.speaker);
  }
}

/// The words a row is voiced with (null when it isn't voiced). Used to match
/// rows to the audio's cue map.
String? voicedText(AppState app, Scene scene, MergedElement m) {
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

/// A row's stable id, the same one the worker writes into the cue map.
String rowRef(MergedElement m) => switch (m) {
  ParsedItem(:final element) => element.ref,
  ManualOverlapItem(:final primary) => primary.ref,
  AddedItem(:final element) => 'added:${element.id}',
};

/// For each cue, the row it voices (-1 when none). Cues name their line
/// (`ref`), so the match is exact; old cue maps without refs, or a ref that
/// isn't on screen, fall back to matching words, in order, between the rows
/// already matched on either side, so a repeated line can't light up the
/// wrong copy.
List<int> matchCuesToRows(List<String?> rowRefs, List<String?> rowTexts, List<String?> cueRefs, List<String> cueTexts) {
  final out = List<int>.filled(cueRefs.length, -1);
  final taken = List<bool>.filled(rowRefs.length, false);
  final byRef = <String, int>{};
  for (var i = 0; i < rowRefs.length; i++) {
    final r = rowRefs[i];
    if (r != null) byRef.putIfAbsent(r, () => i);
  }
  for (var c = 0; c < cueRefs.length; c++) {
    final r = cueRefs[c];
    final row = r == null ? null : byRef[r];
    if (row != null && !taken[row]) {
      out[c] = row;
      taken[row] = true;
    }
  }
  // Words, in order, within the gap between ref-matched neighbours.
  var lastRow = -1;
  for (var c = 0; c < out.length; c++) {
    if (out[c] >= 0) {
      lastRow = out[c];
      continue;
    }
    var hi = rowRefs.length;
    for (var d = c + 1; d < out.length; d++) {
      if (out[d] >= 0) {
        hi = out[d];
        break;
      }
    }
    final want = cueTexts[c].trim();
    for (var i = lastRow + 1; i < hi; i++) {
      if (!taken[i] && rowTexts[i]?.trim() == want) {
        out[c] = i;
        taken[i] = true;
        lastRow = i;
        break;
      }
    }
  }
  return out;
}

/// Rows ↔ cues for one scene.
class CueRowMap {
  CueRowMap(AppState app, Scene scene, List<MergedElement> rows, List<SceneCue> cues)
    : _rowForCue = matchCuesToRows(
        [for (final m in rows) rowRef(m)],
        [for (final m in rows) voicedText(app, scene, m)],
        [for (final c in cues) c.ref],
        [for (final c in cues) c.text],
      );
  final List<int> _rowForCue;
  late final Map<int, int> _cueForRow = {
    for (var c = 0; c < _rowForCue.length; c++)
      if (_rowForCue[c] >= 0) _rowForCue[c]: c,
  };

  /// The row voiced by cue [cue], or -1.
  int rowForCue(int cue) => cue >= 0 && cue < _rowForCue.length ? _rowForCue[cue] : -1;

  /// The cue that voices row [row], or -1.
  int cueForRow(int row) => _cueForRow[row] ?? -1;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with SingleTickerProviderStateMixin {
  final selection = LineSelection();
  final view = SceneView();
  final search = SearchState();
  final searchFocus = FocusNode();
  bool _castShown = false;
  bool _viewRestored = false;
  Map<int, SceneOutputInfo>? _lastFileInfo;
  late final AppState app = context.read<AppState>();
  late final RehearsalPlayer player = context.read<RehearsalPlayer>();

  /// House lights: opening a project fades up from a warm dim (0.3 s).
  late final AnimationController _houseLights = AnimationController(vsync: this, duration: const Duration(milliseconds: 300), value: 0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_houseLights.value == 0 && !_houseLights.isAnimating) {
      if (MediaQuery.of(context).disableAnimations) {
        _houseLights.value = 1;
      } else {
        _houseLights.forward();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    app.addListener(_onAppChange);
    view.addListener(_saveView);
    player.onSettingsChanged = _saveView;
    player.onSceneTurn = () => app.playEffect('page');
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAppChange());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    app.removeListener(_onAppChange);
    player.onSettingsChanged = null;
    player.onSceneTurn = null;
    player.unload();
    searchFocus.dispose();
    _houseLights.dispose();
    super.dispose();
  }

  void _onAppChange() {
    if (!mounted) return;
    // Restore the remembered view once the script is in.
    if (!_viewRestored && app.script != null) {
      _viewRestored = true;
      final v = app.loadView();
      final open = ((v['expanded'] as List?) ?? const []).map((e) => (e as num).toInt());
      final role = v['role'] as String?;
      if (role != null && app.script!.characters.any((c) => c.name == role)) player.myRole = role;
      player.muteMyLines = v['mute'] as bool? ?? false;
      player.blockMyLines = v['block'] as bool? ?? false;
      player.cueMode = v['cue'] as bool? ?? false;
      player.playbackRate = (v['speed'] as num?)?.toDouble() ?? 1.0;
      view.restore(open);
    }
    // Rendered files changed: refresh the playback bar.
    if (!identical(_lastFileInfo, app.sceneFileInfo)) {
      _lastFileInfo = app.sceneFileInfo;
      player.load(app);
    }
    // First open of a new project: cast it once the parse is done.
    if (!_castShown && app.castPending && app.script != null && !app.isParsing) {
      _castShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showCastSheet(context);
      });
    }
  }

  void _saveView() {
    if (!_viewRestored) return;
    app.saveView({
      'expanded': view.expanded.toList()..sort(),
      'role': player.myRole,
      'mute': player.muteMyLines,
      'block': player.blockMyLines,
      'cue': player.cueMode,
      'speed': player.playbackRate,
    });
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false; // a sheet is open
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed && e.logicalKey == LogicalKeyboardKey.keyF) {
      searchFocus.requestFocus();
      return true;
    }
    if (isTextInputFocused()) return false;
    if (player.scenes.isEmpty) return false;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.space:
        player.togglePlayPause();
        return true;
      case LogicalKeyboardKey.keyL when player.blockMyLines && player.myRole.isNotEmpty && !keys.isMetaPressed:
        player.callForLine();
        return true;
      case LogicalKeyboardKey.arrowLeft:
        keys.isMetaPressed ? player.prevScene() : player.prevLine();
        return true;
      case LogicalKeyboardKey.arrowRight:
        keys.isMetaPressed ? player.nextScene() : player.nextLine();
        return true;
    }
    return false;
  }

  /// Start and end time of the selected lines, when they're in the playing scene.
  (double, double)? _selectedRange() {
    final cur = player.currentScene;
    if (cur == null || selection.isEmpty || selection.sceneNumber != cur.sceneNumber) return null;
    final scene = app.scenes.where((s) => s.number == cur.sceneNumber).firstOrNull;
    if (scene == null) return null;
    final merged = app.mergedElements(scene);
    final map = CueRowMap(app, scene, merged, player.cues);
    double? start, end;
    for (var i = 0; i < merged.length; i++) {
      final m = merged[i];
      final picked = switch (m) {
        ParsedItem(:final element) => selection.refs.contains(element.ref),
        ManualOverlapItem(:final primary) => selection.refs.contains(primary.ref),
        AddedItem(:final element) => selection.addedIds.contains(element.id),
      };
      if (!picked) continue;
      final ci = map.cueForRow(i);
      if (ci < 0) continue;
      final c = player.cues[ci];
      start = start == null ? c.startTime : (c.startTime < start ? c.startTime : start);
      end = end == null ? c.endTime : (c.endTime > end ? c.endTime : end);
    }
    return start == null ? null : (start, end!);
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: selection),
        ChangeNotifierProvider.value(value: view),
        ChangeNotifierProvider.value(value: search),
      ],
      child: Material(
        color: t.bg,
        child: Stack(
          children: [
            Column(
              children: [
                const _WorkspaceHeader(),
                _ToolBar(searchFocus: searchFocus),
                const Expanded(child: ScriptArea()),
                PlaybackBar(selectedRange: _selectedRange),
              ],
            ),
            // Clicks go straight through; it's only light.
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _houseLights,
                builder: (context, _) {
                  final dim = 1 - Curves.easeOut.transform(_houseLights.value);
                  return dim <= 0 ? const SizedBox.shrink() : Container(color: const Color(0xFF1E140A).withValues(alpha: 0.38 * dim));
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
// Header: back, title, tool palette, app options
// ---------------------------------------------------------------------------

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader();

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
    return AppHeader(
      leading: [
        IconBtn(Icons.chevron_left_rounded, size: 20, tooltip: 'Back to Projects', onTap: () => _back(context)),
        const SizedBox(width: 6),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(store.currentProject?.name ?? '', overflow: TextOverflow.ellipsis, style: TextStyles.display(t, size: 17)),
          ),
        ),
      ],
    );
  }
}

/// The tool palette under the title bar: Cast, Render, then search.
class _ToolBar extends StatelessWidget {
  const _ToolBar({required this.searchFocus});
  final FocusNode searchFocus;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final edited = app.scenesNeedingRerender.length;
    final engineReady = app.installedEngines.contains(app.selectedEngine);
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(bottom: BorderSide(color: t.rule)),
      ),
      child: Row(
        children: [
          ToolButton(
            icon: Icons.record_voice_over_outlined,
            label: 'Cast',
            tooltip: 'Choose the voice engine and cast each character (⌘K)',
            badge: engineReady ? null : '!',
            onTap: app.script == null ? null : () => showCastSheet(context),
          ),
          const SizedBox(width: 6),
          if (app.isGenerating)
            const RenderStatusChip()
          else
            ToolButton(
              icon: Icons.graphic_eq_rounded,
              label: 'Render',
              tooltip: edited > 0 ? '$edited edited scene${edited == 1 ? '' : 's'} to re-render' : 'Choose scenes to render (⌘R)',
              badge: edited > 0 ? '$edited edited' : null,
              onTap: app.script == null ? null : () => showRenderSheet(context),
            ),
          const SizedBox(width: 6),
          ToolButton(
            icon: Icons.ios_share_rounded,
            label: 'Export',
            tooltip: app.hasRenderedAudio ? 'Copy the rendered audio to a folder (⇧⌘E)' : 'Render a scene first',
            onTap: app.hasRenderedAudio
                ? () {
                    final store = context.read<ProjectStore>();
                    exportAudio(context, sourceFolder: app.outputDirectory ?? store.currentProject!.folderPath!, projectName: store.currentProject!.name);
                  }
                : null,
          ),
          Container(width: 1, height: 20, margin: const EdgeInsets.symmetric(horizontal: 12), color: t.rule),
          _SearchField(focus: searchFocus),
        ],
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.focus});
  final FocusNode focus;
  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final ctl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final search = context.watch<SearchState>();
    final hits = searchHits(app, search.query);
    final active = search.query.trim().length >= 2;
    return SizedBox(
      width: 300,
      height: 30,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            ctl.clear();
            search.setQuery('');
            widget.focus.unfocus();
          },
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => search.step(-1, hits.length),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => search.step(-1, hits.length),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => search.step(1, hits.length),
        },
        child: TextField(
          controller: ctl,
          focusNode: widget.focus,
          // Fill the 30 px box exactly, the same height as the buttons beside it.
          expands: true,
          maxLines: null,
          textAlignVertical: TextAlignVertical.center,
          // Clicking anywhere else hands the keyboard back to playback (Space).
          onTapOutside: (_) => widget.focus.unfocus(),
          onChanged: search.setQuery,
          onSubmitted: (_) {
            search.step(1, hits.length);
            widget.focus.requestFocus();
          },
          style: TextStyles.ui(t, size: 12.5),
          cursorColor: t.accent,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search script',
            hintStyle: TextStyles.ui(t, size: 12.5, color: t.faint),
            prefixIcon: Icon(Icons.search_rounded, size: 16, color: t.muted),
            prefixIconConstraints: const BoxConstraints(minWidth: 30),
            suffixIconConstraints: const BoxConstraints(minWidth: 0),
            suffixIcon: active
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hits.isEmpty ? 'No matches' : '${search.current % hits.length + 1} of ${hits.length}',
                        style: TextStyles.ui(t, size: 11, color: t.muted),
                      ),
                      IconBtn(
                        Icons.keyboard_arrow_up_rounded,
                        size: 16,
                        box: 22,
                        tooltip: 'Previous match (⇧↩)',
                        onTap: hits.isEmpty ? null : () => search.step(-1, hits.length),
                      ),
                      IconBtn(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        box: 22,
                        tooltip: 'Next match (↩)',
                        onTap: hits.isEmpty ? null : () => search.step(1, hits.length),
                      ),
                      const SizedBox(width: 2),
                    ],
                  )
                : null,
            filled: true,
            fillColor: t.sheet,
            contentPadding: EdgeInsets.zero,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: t.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: t.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: t.accent, width: 1.5),
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
  final GlobalKey _activeLineKey = GlobalKey();
  final GlobalKey _hitKey = GlobalKey();
  DateTime _lastManualScroll = DateTime.fromMillisecondsSinceEpoch(0);
  int? _lastActiveScene;
  int _lastCue = -1;
  bool _lastPlaying = false;
  int _lastJump = 0;

  /// Scrolls [key]'s line into view. The line may not exist until the scene
  /// opens on the next frame, so it retries for a few frames.
  void _scrollTo(GlobalKey key, {int tries = 6}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = key.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
      } else if (tries > 0) {
        _scrollTo(key, tries: tries - 1);
        WidgetsBinding.instance.scheduleFrame();
      }
    });
  }

  /// Keeps the playing line on screen: when a new line starts (unless the
  /// user scrolled in the last 3 seconds) and always on play and pause. Opens
  /// the scene, and its "show all" part when the line is past the first rows.
  void _followPlayback(AppState app, RehearsalPlayer player, SceneView view) {
    final scene = player.currentScene;
    final hasLine = scene != null && player.currentCueIndex >= 0;
    final toggled = player.isPlaying != _lastPlaying;
    _lastPlaying = player.isPlaying;
    final cueChanged = player.currentCueIndex != _lastCue || scene?.sceneNumber != _lastActiveScene;
    _lastCue = player.currentCueIndex;
    _lastActiveScene = scene?.sceneNumber;
    if (!hasLine || !(toggled || cueChanged)) return;
    if (!toggled && DateTime.now().difference(_lastManualScroll) < const Duration(seconds: 3)) return;
    final n = scene.sceneNumber;
    final s = app.script?.scenes.where((x) => x.number == n).firstOrNull;
    if (s == null) return;
    final merged = app.mergedElements(s);
    final row = CueRowMap(app, s, merged, player.cues).rowForCue(player.currentCueIndex);
    final needAll = row >= _Lines.initialLimit;
    WidgetsBinding.instance.addPostFrameCallback((_) => view.open(n, all: needAll));
    _scrollTo(_activeLineKey);
  }

  void _followSearch(SearchState search, List<SearchHit> hits, SceneView view) {
    if (search.jumpTick == _lastJump) return;
    _lastJump = search.jumpTick;
    if (hits.isEmpty) return;
    final hit = hits[search.current % hits.length];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      view.open(hit.sceneNumber, all: hit.row >= _Lines.initialLimit);
      _scrollTo(_hitKey);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final player = context.watch<RehearsalPlayer>();
    final sel = context.watch<LineSelection>();
    final view = context.watch<SceneView>();
    final search = context.watch<SearchState>();
    final script = app.script;

    if (script == null) {
      if (app.isParsing) return _ParseProgress(fraction: app.parseFraction, message: app.parseMessage);
      return const EmptyState(art: EmptyArt.titlePage, title: 'No script loaded', message: 'Open a PDF to review parsed scenes and characters.');
    }
    _followPlayback(app, player, view);
    final hits = searchHits(app, search.query);
    _followSearch(search, hits, view);
    final currentHit = hits.isEmpty ? null : hits[search.current % hits.length];
    final activeScene = (player.isPlaying || player.currentCueIndex >= 0) ? player.currentScene?.sceneNumber : null;

    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: (n) {
            if (n.direction != ScrollDirection.idle) _lastManualScroll = DateTime.now();
            return false;
          },
          child: Scrollbar(
            controller: _scroll,
            // Every scene is built (not a lazy list) so playback and search
            // can scroll to a line in any scene. Script text follows the
            // Text Size setting.
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(app.scriptTextScale)),
              child: SingleChildScrollView(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(24, 18, 24, sel.isEmpty ? 24 : 88),
                child: Column(
                  children: [
                    for (final s in script.scenes)
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1080),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: activeScene != null && activeScene != s.number ? 0.55 : 1,
                              child: SceneCard(
                                scene: s,
                                expanded: view.expanded.contains(s.number),
                                showAll: view.showAll.contains(s.number),
                                activeLineKey: activeScene == s.number ? _activeLineKey : null,
                                searchQuery: search.query.trim().length >= 2 ? search.query.trim() : '',
                                matchCount: hits.where((h) => h.sceneNumber == s.number).length,
                                currentHitRow: currentHit?.sceneNumber == s.number ? currentHit!.row : null,
                                hitKey: _hitKey,
                                onToggleExpand: () {
                                  if (view.expanded.contains(s.number) && sel.sceneNumber == s.number) sel.clear();
                                  view.toggle(s.number);
                                },
                                onToggleShowAll: () => view.toggleShowAll(s.number),
                              ),
                            ),
                          ),
                        ),
                      ),
                    _StatsFooter(script: script),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (app.canUndo || app.canRedo)
          Positioned(
            top: 10,
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
            bottom: 16,
            child: Center(child: _SelectionBar(selection: sel)),
          ),
        if (app.showCurtainCall)
          Positioned(
            left: 0,
            right: 0,
            top: app.canUndo || app.canRedo ? 54 : 12,
            child: Center(child: _CurtainCall(count: script.scenes.length, onClose: app.dismissCurtainCall)),
          ),
        if (sel.isEmpty ? _tipFor(app, player) : null case final tip?)
          Positioned(
            left: 18,
            bottom: 16,
            child: MarginTip(key: ValueKey(tip.$1), text: tip.$2, onDismiss: () => app.dismissTip(tip.$1)),
          ),
        if (app.isFetchingVoices)
          Positioned(
            right: 18,
            bottom: 12,
            child: Row(
              children: [
                SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.6, color: t.muted)),
                const SizedBox(width: 6),
                Text('Loading voices…', style: TextStyles.ui(t, size: 12, color: t.muted)),
              ],
            ),
          ),
      ],
    );
  }
}

class _ParseProgress extends StatelessWidget {
  const _ParseProgress({required this.fraction, required this.message});
  final double fraction;
  final String message;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Center(
      child: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EmptyArtView(EmptyArt.pages),
            const SizedBox(height: 18),
            Text('Parsing script…', style: TextStyles.ui(t, size: 16, weight: FontWeight.w700)),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: fraction),
                duration: const Duration(milliseconds: 200),
                builder: (context, v, _) => LinearProgressIndicator(value: v, minHeight: 6, color: t.accent, backgroundColor: t.ctrl),
              ),
            ),
            const SizedBox(height: 8),
            Text(message, style: TextStyles.ui(t, size: 12, color: t.muted)),
          ],
        ),
      ),
    );
  }
}

class _StatsFooter extends StatelessWidget {
  const _StatsFooter({required this.script});
  final ScriptSummary script;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
      child: Center(
        child: Text(
          '${script.sceneCount} scenes · ${script.characterCount} characters · ${script.lineCount} lines',
          style: TextStyles.ui(t, size: 12, color: t.faint),
        ),
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
    this.searchQuery = '',
    this.matchCount = 0,
    this.currentHitRow,
    this.hitKey,
  });
  final Scene scene;
  final bool expanded, showAll;
  final VoidCallback onToggleExpand, onToggleShowAll;
  final GlobalKey? activeLineKey;
  final String searchQuery;
  final int matchCount;
  final int? currentHitRow;
  final GlobalKey? hitKey;
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
    final rendered = app.sceneFileInfo[s.number]?.exists == true;
    final edited = app.scenesNeedingRerender.contains(s.number);
    final speakers = s.speakers;
    final rendering = app.isGenerating && app.renderingSceneNumbers.contains(s.number);
    final progress = app.sceneProgress[s.number] ?? 0;
    final startedRender =
        rendering && (progress > 0 || app.renderingSceneNumbers.firstWhere((n) => (app.sceneProgress[n] ?? 0) < 1, orElse: () => -1) == s.number);
    final renderLabel = !rendering ? null : (progress >= 1 ? 'Rendered' : (startedRender ? 'Rendering ${(progress * 100).round()}%' : 'Queued'));

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.sheet,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: rendering && startedRender && progress < 1 ? t.accentLine : t.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: widget.onToggleExpand,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
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
                  if (app.wrappedAt[s.number] case final at?) WrapStamp(key: ValueKey(at), at: at),
                  if (edited && !rendering) ...[
                    const SizedBox(width: 8),
                    const Tooltip(
                      message: 'Edited since it was rendered',
                      child: Stamp('EDITED', kind: StampKind.warn),
                    ),
                  ],
                  if (widget.matchCount > 0) ...[
                    const SizedBox(width: 8),
                    Stamp('${widget.matchCount} match${widget.matchCount == 1 ? '' : 'es'}', kind: StampKind.accent),
                  ],
                  const SizedBox(width: 10),
                  for (final (i, sp) in speakers.take(5).indexed) ...[
                    // Plain names (highlight colors off) need a separator.
                    if (i > 0 && !characterColorsEnabled) Text(' · ', style: TextStyles.ui(t, size: 11, color: t.faint)) else const SizedBox(width: 4),
                    NameChip(sp, allSpeakers: app.allSpeakers),
                  ],
                  if (speakers.length > 5)
                    Padding(
                      padding: const EdgeInsets.only(left: 5),
                      child: Text('+${speakers.length - 5}', style: TextStyles.ui(t, size: 11, color: t.faint)),
                    ),
                  SizedBox(
                    width: 104,
                    child: Text(
                      renderLabel ?? '${s.elementCount} lines',
                      textAlign: TextAlign.right,
                      style: TextStyles.ui(
                        t,
                        size: 12,
                        weight: renderLabel != null ? FontWeight.w600 : FontWeight.w400,
                        color: renderLabel != null ? t.accent : t.muted,
                      ),
                    ),
                  ),
                  IconBtn(widget.expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, onTap: widget.onToggleExpand),
                ],
              ),
            ),
          ),
          if (rendering && widget.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(58, 0, 16, 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: startedRender ? progress : 0, minHeight: 4, color: t.accent, backgroundColor: t.ctrl),
              ),
            ),
          if (widget.expanded) ...[
            Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 12), color: t.rule),
            _Lines(
              scene: s,
              showAll: widget.showAll,
              onToggleShowAll: widget.onToggleShowAll,
              activeLineKey: widget.activeLineKey,
              searchQuery: widget.searchQuery,
              currentHitRow: widget.currentHitRow,
              hitKey: widget.hitKey,
            ),
          ],
          // Collapsed: render progress runs along the bottom edge of the bar.
          if (rendering && !widget.expanded)
            LinearProgressIndicator(value: startedRender ? progress : 0, minHeight: 3, color: t.accent, backgroundColor: Colors.transparent),
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
            style: TextStyles.ui(t, weight: FontWeight.w600),
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

/// What a row needs from its scene: playing state, play-from-here, search.
class RowContext {
  const RowContext({required this.active, this.onPlay, this.query = '', this.currentHit = false, this.revealed = false});
  final bool active;
  final VoidCallback? onPlay;
  final String query;
  final bool currentHit;

  /// "Line!" is showing this (blocked) line for a moment.
  final bool revealed;
}

class _Lines extends StatelessWidget {
  const _Lines({
    required this.scene,
    required this.showAll,
    required this.onToggleShowAll,
    this.activeLineKey,
    this.searchQuery = '',
    this.currentHitRow,
    this.hitKey,
  });
  final Scene scene;
  final bool showAll;
  final VoidCallback onToggleShowAll;
  final GlobalKey? activeLineKey;
  final String searchQuery;
  final int? currentHitRow;
  final GlobalKey? hitKey;
  static const initialLimit = 30;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = context.watch<RehearsalPlayer>();
    final total = scene.elements.length;
    final limit = showAll ? total : initialLimit;
    final merged = app.mergedElements(scene, limit: limit);
    final playingHere = player.currentScene?.sceneNumber == scene.number;
    // This scene's audio, if rendered. Rows are matched to its cues on the
    // full row list (the visible rows are a prefix of it).
    final sceneItem = player.scenes.where((s) => s.sceneNumber == scene.number).firstOrNull;
    final map = sceneItem == null ? null : CueRowMap(app, scene, showAll ? merged : app.mergedElements(scene), sceneItem.cues);
    final activeRow = playingHere && map != null ? map.rowForCue(player.currentCueIndex) : -1;

    RowContext ctxFor(int i) {
      final ci = map?.cueForRow(i) ?? -1;
      return RowContext(
        active: i == activeRow,
        onPlay: ci < 0 ? null : () => player.playFrom(scene.number, ci),
        query: searchQuery,
        currentHit: currentHitRow == i,
        revealed: playingHere && ci >= 0 && player.revealedCue == ci,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < merged.length; i++) _row(app, merged[i], ctxFor(i), i == activeRow ? activeLineKey : (currentHitRow == i ? hitKey : null)),
          if (total > initialLimit)
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 6, 12, 2),
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

  Widget _row(AppState app, MergedElement m, RowContext rc, GlobalKey? key) => switch (m) {
    ParsedItem(:final element) =>
      element.isOverlap && _showsTwoPanel(app, element)
          ? SimultaneousRow(key: key, scene: scene, element: element, rc: rc)
          : LineRow(key: key, scene: scene, element: element, rc: rc),
    ManualOverlapItem(:final primary, :final secondary) => ManualPairRow(key: key, scene: scene, primary: primary, secondary: secondary, rc: rc),
    AddedItem(:final element) => AddedLineRow(key: key, scene: scene, element: element, rc: rc),
  };

  bool _showsTwoPanel(AppState app, SceneElement el) {
    final fix = app.correctionFor(scene.number, el);
    final kind = fix?.correctedKind ?? el.kind;
    final cue = fix?.correctedOverlapSpeakers ?? el.overlapCue ?? const [];
    return kind == 'dialog' && cue.length >= 2;
  }
}

/// Text with search matches highlighted.
TextSpan highlightSpan(String text, String query, TextStyle style, Color hit) {
  if (query.isEmpty) return TextSpan(text: text, style: style);
  final lower = text.toLowerCase(), q = query.toLowerCase();
  final spans = <TextSpan>[];
  var i = 0;
  while (true) {
    final j = lower.indexOf(q, i);
    if (j < 0) {
      spans.add(TextSpan(text: text.substring(i), style: style));
      break;
    }
    if (j > i) spans.add(TextSpan(text: text.substring(i, j), style: style));
    spans.add(
      TextSpan(
        text: text.substring(j, j + q.length),
        style: style.copyWith(backgroundColor: hit),
      ),
    );
    i = j + q.length;
  }
  return TextSpan(children: spans);
}

/// Opens the speaker menu from a name tag; returns the picked name.
Future<String?> pickSpeaker(BuildContext anchor, AppState app, String current) =>
    showAnchoredMenu<String>(anchor, [for (final n in app.allSpeakers) MenuItemSpec(n, titleCaseName(n), checked: n == current)]);

/// On a line the parser wasn't sure about: a handwritten "who's speaking?"
/// note. Clicking it opens the speaker menu; picking anyone, even the same
/// name, confirms the line and the note goes away.
class CheckSpeakerTag extends StatelessWidget {
  const CheckSpeakerTag({super.key, required this.reason, required this.current, required this.onPick});
  final String? reason;
  final String current;
  final ValueChanged<String> onPick;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final why = reason ?? "Table Read isn't sure who says this line.";
    return Tooltip(
      message: '$why\nClick to choose the speaker. Picking one (even the same) marks the line as checked.',
      child: Builder(
        builder: (ctx) => Hover(
          cursor: SystemMouseCursors.click,
          builder: (context, h) => GestureDetector(
            onTap: () async {
              final picked = await pickSpeaker(ctx, app, current);
              if (picked != null) onPick(picked);
            },
            child: Transform.rotate(
              angle: -0.03,
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 1, 7, 2),
                decoration: BoxDecoration(
                  color: h ? t.warnSoft : t.warnSoft.withValues(alpha: t.warnSoft.a * 0.6),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: t.warn.withValues(alpha: 0.7), width: 1.2),
                ),
                child: Text("who's speaking?", style: TextStyles.hand(t, size: 15, color: t.warn)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A name tag you can click to change who says the line.
class SpeakerTag extends StatelessWidget {
  const SpeakerTag(this.name, {super.key, required this.onPick, this.strike = false, this.size = 10.5});
  final String name;
  final ValueChanged<String> onPick;
  final bool strike;
  final double size;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Tooltip(
      message: 'Change speaker',
      waitDuration: const Duration(milliseconds: 700),
      child: Builder(
        builder: (ctx) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () async {
              final picked = await pickSpeaker(ctx, app, name == 'NARRATOR' ? 'Narrator' : name);
              if (picked != null) onPick(picked);
            },
            child: NameChip(name, allSpeakers: app.allSpeakers, uppercase: true, strike: strike, size: size),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Line rows
// ---------------------------------------------------------------------------

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
      width: _gutterWidth,
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

/// Row chrome shared by every line: hover, selection, playing highlight. Hover
/// actions float over the row's top-right corner so they take no layout space
/// and the line stays centered.
class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.child,
    required this.selected,
    required this.active,
    required this.onHover,
    this.hit = false,
    this.actions,
    this.hover = false,
  });
  final Widget child;
  final bool selected, active, hit;

  /// Under the pointer (rows with floating actions are hovered when they show them).
  final bool hover;
  bool get hovered => hover || actions != null;
  final ValueChanged<bool> onHover;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Stack(
        children: [
          // The playing line sits in a follow spot: the existing highlight
          // color at the center, fading out toward the edges. The text never
          // sits on anything stronger than the flat highlight it replaced, so
          // contrast is the same or better. Fades in quickly as playback moves.
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: active
                  ? null
                  : selected
                  ? t.accentSoft.withValues(alpha: t.accentSoft.a * 0.7)
                  // A faint wash under the pointer, so it's clear which line
                  // the actions belong to.
                  : (hovered ? t.ink.withValues(alpha: t.dark ? 0.045 : 0.035) : t.accentSoft.withValues(alpha: 0)),
              gradient: active ? followSpot(t) : null,
              border: Border(left: BorderSide(color: active || hit ? t.accent : Colors.transparent, width: 3)),
            ),
            padding: const EdgeInsets.fromLTRB(0, 5, 0, 5),
            child: child,
          ),
          if (actions != null && actions!.isNotEmpty)
            Positioned(
              top: 1,
              right: 8,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: t.sheet,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: t.border),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 8, offset: const Offset(0, 2))],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < actions!.length; i++) ...[if (i > 0) const SizedBox(width: 3), actions![i]],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Dialogue sits in a centered block about as wide as a screenplay's
/// dialogue column, so lines read as a balanced column under the name.
class _DialogueBlock extends StatelessWidget {
  const _DialogueBlock({required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;
  static const maxWidth = 540.0;
  @override
  Widget build(BuildContext context) => enabled
      ? Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxWidth),
            child: SizedBox(width: double.infinity, child: child),
          ),
        )
      : child;
}

/// The follow spot behind the playing line: an oval of the playing-line
/// color, strongest in the middle where the dialogue sits.
Gradient followSpot(Tokens t) => RadialGradient(
  radius: 0.6,
  // Stretch the circle into a wide oval across the row.
  transform: const _WideOval(),
  colors: [t.accentSoft, t.accentSoft, t.accentSoft.withValues(alpha: t.accentSoft.a * 0.35)],
  stops: const [0, 0.45, 1],
);

class _WideOval extends GradientTransform {
  const _WideOval();
  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    // RadialGradient sizes to the shorter side; scale x to the row's width.
    final sx = bounds.height == 0 ? 1.0 : bounds.width / bounds.height;
    final c = bounds.center;
    return Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(sx, 1, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
  }
}

/// A handwritten "wrapped" stamp that lands on a scene's card when it
/// finishes rendering, then fades: ~0.2 s in, 2.5 s shown, ~0.25 s out. Never
/// blocks anything; without motion (Reduce Motion) it simply appears.
class WrapStamp extends StatefulWidget {
  const WrapStamp({super.key, required this.at});
  final DateTime at;
  static const shown = Duration(milliseconds: 2700);
  @override
  State<WrapStamp> createState() => _WrapStampState();
}

class _WrapStampState extends State<WrapStamp> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  Timer? _out;
  bool _visible = true, _gone = false;

  @override
  void initState() {
    super.initState();
    final age = clockNow().difference(widget.at);
    if (age > WrapStamp.shown) {
      _gone = true;
      return;
    }
    _in.forward();
    _out = Timer(WrapStamp.shown - age, () {
      if (!mounted) return;
      setState(() => _visible = false);
      Timer(const Duration(milliseconds: 260), () {
        if (mounted) setState(() => _gone = true);
      });
    });
  }

  @override
  void dispose() {
    _out?.cancel();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    final t = Tokens.of(context);
    final still = MediaQuery.of(context).disableAnimations;
    final stamp = Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.fromLTRB(7, 1, 8, 2),
      decoration: BoxDecoration(
        border: Border.all(color: t.ok, width: 1.4),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text('wrapped!', style: TextStyles.hand(t, size: 16, color: t.ok)),
    );
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 250),
      child: still
          ? Transform.rotate(angle: -0.08, child: stamp)
          : AnimatedBuilder(
              animation: _in,
              builder: (context, child) {
                final v = Curves.easeOutBack.transform(_in.value);
                return Opacity(
                  opacity: _in.value,
                  child: Transform.rotate(angle: -0.08, child: Transform.scale(scale: 1.35 - 0.35 * v, child: child)),
                );
              },
              child: stamp,
            ),
    );
  }
}

/// The first-run tip that applies right now, if any: (id, text).
(String, String)? _tipFor(AppState app, RehearsalPlayer player) {
  bool open(String id) => !app.tipDismissed(id);
  if (open('whoSpeaking')) {
    final unsure = app.scenes.any(
      (sc) => sc.elements.any((el) => el.confidence < 0.7 && app.correctionFor(sc.number, el) == null && !app.isChecked(sc.number, el)),
    );
    if (unsure) return ('whoSpeaking', 'A few lines say “who’s speaking?” — click the tag to pick who says them.');
  }
  if (open('clickLine') && app.hasRenderedAudio) return ('clickLine', 'Click any line to hear it from there.');
  if (open('callLine') && player.blockMyLines && player.myRole.isNotEmpty) {
    return ('callLine', 'Drew a blank? Press L for your line.');
  }
  return null;
}

/// A handwritten note in the margin with a "Got it". Fades in; never covers
/// the script's text column for long and goes away for good when dismissed.
class MarginTip extends StatelessWidget {
  const MarginTip({super.key, required this.text, required this.onDismiss});
  final String text;
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 160),
      builder: (context, v, child) => Opacity(opacity: v, child: child),
      child: Transform.rotate(
        angle: -0.012,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 300),
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: BoxDecoration(
            color: t.sheet,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.border),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: Text(text, style: TextStyles.hand(t, size: 17, color: t.ink2).copyWith(height: 1.15)),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Don’t show this tip again',
                child: GestureDetector(
                  onTap: onDismiss,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1, right: 4),
                      child: Text('Got it', style: TextStyles.ui(t, size: 11.5, weight: FontWeight.w700, color: t.accent)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown once per project when every scene has been rendered.
class _CurtainCall extends StatelessWidget {
  const _CurtainCall({required this.count, required this.onClose});
  final int count;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 200),
      builder: (context, v, child) => Opacity(opacity: v, child: child),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
        decoration: BoxDecoration(
          color: t.okSoft,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: t.ok.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Curtain call!', style: TextStyles.hand(t, size: 19, color: t.ok)),
            const SizedBox(width: 10),
            Text('All $count scenes are rendered and ready to play.', style: TextStyles.ui(t, size: 12.5, color: t.ink2)),
            const SizedBox(width: 4),
            IconBtn(Icons.close_rounded, size: 14, box: 22, tooltip: 'Close', onTap: onClose),
          ],
        ),
      ),
    );
  }
}

/// Right-hand column of small status marks (muted, corrected, uncertain).
/// The same width as the checkbox gutter so lines stay centered.
class _Status extends StatelessWidget {
  const _Status({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: _gutterWidth,
    child: Padding(
      padding: const EdgeInsets.only(top: 2, right: 10),
      child: Wrap(alignment: WrapAlignment.end, spacing: 4, runSpacing: 2, children: children),
    ),
  );
}

const double _gutterWidth = 44;

class LineRow extends StatefulWidget {
  const LineRow({super.key, required this.scene, required this.element, required this.rc});
  final Scene scene;
  final SceneElement element;
  final RowContext rc;
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
    final blocked = mine && player.blockMyLines && !widget.rc.revealed;
    final shownText = blocked ? blockText(text) : text;
    final flagged = el.confidence < 0.7 && fix == null && !removed && !app.isChecked(n, el);
    final selected = sel.sceneNumber == n && sel.refs.contains(el.ref);

    final textStyle = TextStyles.script(
      t,
      italic: !isDialog,
      color: removed ? t.faint : (isDialog ? t.ink : t.ink2),
    ).copyWith(decoration: removed ? TextDecoration.lineThrough : null, decorationColor: t.muted, backgroundColor: mine && !removed ? t.mine : null);

    final body = isDialog
        ? _DialogueBlock(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Name centered over the dialogue; an unsure line's tag sits
                // to its right without pushing it off center.
                Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    SpeakerTag(
                      speaker,
                      strike: removed,
                      onPick: (sp) => app.correctLine(n, el, kind: 'dialog', speaker: sp, text: text, removed: removed),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: flagged
                            ? Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: CheckSpeakerTag(
                                  reason: el.reason,
                                  current: speaker,
                                  onPick: (sp) => app.confirmSpeaker(n, el, sp, text: text, removed: removed),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                _Playable(
                  onPlay: widget.rc.onPlay,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    child: Text.rich(
                      key: ValueKey(blocked),
                      highlightSpan(shownText, blocked ? '' : widget.rc.query, textStyle, t.accentSoft),
                    ),
                  ),
                ),
              ],
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (flagged)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: CheckSpeakerTag(
                    reason: el.reason,
                    current: 'Narrator',
                    onPick: (sp) => app.confirmSpeaker(n, el, sp, text: text, removed: removed),
                  ),
                ),
              _Playable(onPlay: widget.rc.onPlay, child: Text.rich(highlightSpan(shownText, widget.rc.query, textStyle, t.accentSoft))),
            ],
          );

    return _RowShell(
      selected: selected,
      active: widget.rc.active,
      hit: widget.rc.currentHit,
      onHover: (v) => setState(() => hover = v),
      actions: hover
          ? [
              if (widget.rc.onPlay != null)
                Pill('Play', icon: Icons.play_arrow_rounded, bg: t.accentSoft, fg: t.accent, tooltip: 'Play from this line', onTap: widget.rc.onPlay),
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
            ]
          : null,
      child: Opacity(
        opacity: removed ? 0.6 : 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Gutter(checked: selected, onCheck: () => sel.toggle(n, el.ref), visible: hover || selected || sel.sceneNumber == n && !sel.isEmpty),
            Expanded(child: body),
            _Status(
              children: [
                if (mine && player.muteMyLines)
                  Tooltip(
                    message: 'Your line — muted during playback',
                    child: Icon(Icons.volume_off_rounded, size: 14, color: t.muted),
                  ),
                if (fix != null && !removed)
                  Tooltip(
                    message: 'User correction applied',
                    child: Icon(Icons.check_rounded, size: 15, color: t.accent),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A line the parser found as two voices at once.
class SimultaneousRow extends StatefulWidget {
  const SimultaneousRow({super.key, required this.scene, required this.element, required this.rc});
  final Scene scene;
  final SceneElement element;
  final RowContext rc;
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
              SpeakerTag(name, strike: voiceRemoved, onPick: (sp) => app.editOverlapVoice(n, el, i, sp, txt)),
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
          _Playable(
            onPlay: widget.rc.onPlay,
            child: Text.rich(
              highlightSpan(
                txt,
                widget.rc.query,
                TextStyles.script(
                  t,
                  color: voiceRemoved ? t.faint : t.ink,
                ).copyWith(decoration: voiceRemoved ? TextDecoration.lineThrough : null, decorationColor: t.muted),
                t.accentSoft,
              ),
              textAlign: TextAlign.center,
              maxLines: voiceRemoved ? 1 : null,
              overflow: voiceRemoved ? TextOverflow.ellipsis : null,
            ),
          ),
        ],
      );
    }

    return _RowShell(
      selected: selected,
      active: widget.rc.active,
      hit: widget.rc.currentHit,
      onHover: (v) => setState(() => hover = v),
      hover: hover,
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
          const SizedBox(width: _gutterWidth),
        ],
      ),
    );
  }
}

/// Two lines the user made simultaneous.
class ManualPairRow extends StatefulWidget {
  const ManualPairRow({super.key, required this.scene, required this.primary, required this.secondary, required this.rc});
  final Scene scene;
  final SceneElement primary, secondary;
  final RowContext rc;
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
            children: [
              SpeakerTag(
                name,
                strike: removed,
                onPick: (sp) => app.correctLine(n, el, kind: 'dialog', speaker: sp, text: txt, removed: removed),
              ),
            ],
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
          _Playable(
            onPlay: widget.rc.onPlay,
            child: Text.rich(
              highlightSpan(
                txt,
                widget.rc.query,
                TextStyles.script(
                  t,
                  color: removed ? t.faint : t.ink,
                ).copyWith(decoration: removed ? TextDecoration.lineThrough : null, decorationColor: t.muted),
                t.accentSoft,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    return _RowShell(
      selected: selected,
      active: widget.rc.active,
      hit: widget.rc.currentHit,
      onHover: (v) => setState(() => hover = v),
      hover: hover,
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
          const SizedBox(width: _gutterWidth),
        ],
      ),
    );
  }
}

class AddedLineRow extends StatefulWidget {
  const AddedLineRow({super.key, required this.scene, required this.element, required this.rc});
  final Scene scene;
  final UserAddedElement element;
  final RowContext rc;
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
      active: widget.rc.active,
      hit: widget.rc.currentHit,
      onHover: (v) => setState(() => hover = v),
      actions: hover
          ? [
              if (widget.rc.onPlay != null)
                Pill('Play', icon: Icons.play_arrow_rounded, bg: t.accentSoft, fg: t.accent, tooltip: 'Play from this line', onTap: widget.rc.onPlay),
              Builder(
                builder: (ctx) => Pill(
                  'Edit',
                  bg: speakerColors(speaker, app.allSpeakers, t).highlight,
                  fg: t.nameInk,
                  onTap: () => showPopover(ctx, (_) => EditAddedLinePopover(sceneNumber: n, element: el), width: 340),
                ),
              ),
              Pill(
                'Remove',
                icon: Icons.remove_circle_outline_rounded,
                bg: t.dangerSoft,
                fg: t.danger,
                tooltip: 'Remove this added line',
                onTap: () => app.deleteAddedLine(n, el.id),
              ),
            ]
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Gutter(checked: selected, onCheck: () => sel.toggleAdded(n, el.id), visible: hover || selected || sel.sceneNumber == n && !sel.isEmpty),
          Expanded(
            child: _DialogueBlock(
              enabled: isDialog,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: isDialog ? MainAxisAlignment.center : MainAxisAlignment.start,
                    children: [
                      if (isDialog) ...[
                        SpeakerTag(
                          speaker,
                          onPick: (sp) => app.updateAddedLine(
                            n,
                            el.id,
                            speaker: sp == 'Narrator' ? '' : sp,
                            text: el.text,
                            kind: sp == 'Narrator' ? 'stage_direction' : 'dialog',
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      const Stamp('ADDED'),
                    ],
                  ),
                  const SizedBox(height: 2),
                  if (empty)
                    Text(
                      'Empty — hover and tap Edit to add text',
                      style: TextStyles.ui(t, size: 12, color: t.faint).copyWith(fontStyle: FontStyle.italic),
                    )
                  else
                    _Playable(
                      onPlay: widget.rc.onPlay,
                      child: Text.rich(
                        highlightSpan(el.text, widget.rc.query, TextStyles.script(t, italic: !isDialog, color: isDialog ? t.ink : t.ink2), t.accentSoft),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const _Status(children: []),
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

/// Lets a line's words be clicked to play from that line (when its scene is rendered).
class _Playable extends StatelessWidget {
  const _Playable({required this.child, required this.onPlay});
  final Widget child;
  final VoidCallback? onPlay;
  @override
  Widget build(BuildContext context) {
    if (onPlay == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onPlay, child: child),
    );
  }
}
