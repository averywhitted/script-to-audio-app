// The iPhone's rehearsal screen (#91), after the mockup
// (https://claude.ai/artifact/7rVmDhroJQJzHnLLVimJ8B) and Avery's first notes:
// the whole play in one scroll with each scene's heading sticking to the top
// (tap it to jump to another scene); lines follow playback; a dark bar holds
// the timeline and transport; Rehearse opens the role and practice settings.
// Playback is the Mac's RehearsalPlayer.

import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../state/player_state.dart';
import '../theme/tokens.dart';
import '../ui/dashboard.dart' show blockText;
import '../ui/widgets.dart' show NameChip, titleCaseName;
import '../services/project_files.dart' show RehearsalState, loadNewestRehearsal, rehearsalFolder;
import 'adaptive.dart';
import 'bookmarks.dart';
import 'scene_timeline.dart';
import 'folder_access.dart';
import 'line_notes.dart';
import 'now_playing.dart';
import 'notice.dart';
import 'outline_rail.dart';
import 'page_align.dart';
import 'pdf_panel.dart';
import 'pdf_view.dart';
import 'phone_store.dart';
import 'rehearsal_session.dart';
import 'script_search.dart';

const _textScales = [1.0, 1.15, 1.3, 1.5];
const _textSizeLabels = ['Small', 'Medium', 'Large', 'Huge'];

/// The sticky scene heading's height.
const _headingHeight = 52.0;

/// The bottom bar follows the theme: a light tray in light mode, dark in dark.
({Color bg, Color edge, Color ink, Color btn, Color btnOn}) _barColors(Tokens t) => t.dark
    ? (
        bg: const Color(0xFF262624),
        edge: const Color(0x1FFFFFFF),
        ink: const Color(0xFFEFEDE8),
        btn: const Color(0x1CFFFFFF),
        btnOn: const Color(0x33FFFFFF),
      )
    : (bg: t.panel, edge: t.border, ink: t.ink, btn: const Color(0x12000000), btnOn: const Color(0x21000000));

/// Remembers that the one-time Line! hint was seen.
const _lineHintSeenKey = 'phoneLineHintSeen';

/// Page numbers in the script scroll, and whether the PDF pane is open (iPad).
const _showPagesKey = 'phoneShowPages';
const _pdfOpenKey = 'padPdfOpen';

class PhoneRehearsalScreen extends StatefulWidget {
  const PhoneRehearsalScreen({super.key, required this.project, this.store, this.folderAccess = true, this.audio = true, this.pageTexts});
  final Project project;

  /// For asking the Mac to render the text-only scenes.
  final PhoneStore? store;

  /// Off in tests: settings are written with dart:io instead of the native plugin.
  final bool folderAccess;

  /// Off in tests, where the audio plugin doesn't exist.
  final bool audio;

  /// Reads the text of each page of the PDF; tests give their own, the phone uses PDFKit.
  final Future<List<String>> Function(String path)? pageTexts;

  @override
  State<PhoneRehearsalScreen> createState() => _PhoneRehearsalScreenState();
}

class _PhoneRehearsalScreenState extends State<PhoneRehearsalScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final RehearsalSession session = RehearsalSession.load(widget.project);
  late final RehearsalPlayer player = RehearsalPlayer(audioEnabled: widget.audio);
  final scroll = ScrollController();
  late final NowPlaying nowPlaying = NowPlaying(player, projectName: widget.project.name);
  final List<StreamSubscription<dynamic>> _audioSubs = [];
  final _viewportKey = GlobalKey();

  int _lastCue = -2;
  int? _lastScene;

  /// `"scene:line"` → that line's row; `"scene"` → the scene's lines.
  final Map<String, GlobalKey> _keys = {};
  GlobalKey _key(String k) => _keys.putIfAbsent(k, GlobalKey.new);

  /// The user scrolled by hand: don't pull the view back to the playing line
  /// for a few seconds (or until they press play).
  DateTime _userScrolled = DateTime.fromMillisecondsSinceEpoch(0);
  bool get _following => DateTime.now().difference(_userScrolled) > const Duration(seconds: 4);

  /// Lines picked for a loop (long-press and drag): one scene, line indices.
  int? _selScene, _selA, _selB;
  Offset? _dragPoint;
  Timer? _edgeScroll;

  int textSize = 1;

  // Notes (#117)
  LineNotes? notes;

  // Bookmarks
  Bookmarks? bookmarks;

  // The playhead while browsing. Scrolling the script moves it to where you are on the page (nothing plays or seeks until you
  // press Play, tap a line or let go of the playhead); null: it is the player's own.
  final ValueNotifier<_Head?> _head = ValueNotifier(null);
  bool _scrubbing = false, _scrubWasPlaying = false;

  // A line pointed out for a moment: while the playhead is dragged, or when a line is tapped. It fades after.
  late final AnimationController _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 800), value: 0);
  ({int scene, int line})? _indicated;
  Timer? _fadeTimer;

  // The outline along the edge: the scene being read (follows the scroll), and the widget to fold away when scrolling.
  final ValueNotifier<int?> _viewScene = ValueNotifier(null);
  final GlobalKey<OutlineRailState> _railKey = GlobalKey();

  // Position sync: this device's id, and the newest rehearsal file we have already dealt with (applied, dismissed or written).
  String? _myDeviceId;
  DateTime _syncSeen = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  RehearsalState? _incoming;
  Timer? _syncTimer;
  bool _restored = false;

  // Search (#113)
  bool _searching = false;
  final _queryCtl = TextEditingController();
  final _queryFocus = FocusNode();
  List<SearchHit> _hits = const [];
  int _hit = 0;
  Map<String, List<SearchHit>> _hitsByLine = const {};

  // The PDF (#115) and its pages (#116). [_pageOf] is line key → PDF page; [_breakBefore] is the lines that start a page.
  late final PdfController pdf = PdfController();
  bool _pdfOpen = false;
  bool _showPages = false;
  Map<String, int>? _pageOf;
  Map<String, int> _breakBefore = const {};
  bool _preparingPdf = false;
  final _keyFocus = FocusNode();
  String? _hover;

  String get _pdfPath => widget.project.pdfPath ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.deviceLabel = 'iPhone'; // set to iPad in the first build, once the screen size is known
    RehearsalSession.deviceId().then((id) {
      final n = LineNotes(folder: session.folder, deviceId: id, folderAccess: widget.folderAccess)..load();
      n.addListener(() {
        if (mounted) setState(() {});
      });
      final b = Bookmarks(folder: session.folder, deviceId: id, folderAccess: widget.folderAccess)..load();
      b.addListener(() {
        if (mounted) setState(() {});
      });
      if (mounted) {
        setState(() {
          _myDeviceId = id;
          notes = n;
          bookmarks = b;
        });
      }
    });
    if (widget.audio) {
      AudioSession.instance
          .then((s) async {
            await s.configure(const AudioSessionConfiguration.speech());
            // Headphones pulled out, or a call coming in: stop, like any player.
            _audioSubs.add(s.becomingNoisyEventStream.listen((_) => player.pause()));
            _audioSubs.add(
              s.interruptionEventStream.listen((e) {
                if (e.begin) player.pause();
              }),
            );
          })
          .catchError((_) {});
      nowPlaying.attach();
    }
    player.loadItems(session.items);
    _lastScene = player.currentScene?.sceneNumber;
    player.addListener(_onPlayer);
    scroll.addListener(() {
      if (_selA != null && mounted) setState(() {});
    });
    session.restore(player).then((_) {
      if (!mounted) return;
      final newest = loadNewestRehearsal(session.folder);
      if (newest != null) _syncSeen = newest.updatedAt;
      setState(() {});
      player.onSettingsChanged = () => session.scheduleSave(player, folderAccess: widget.folderAccess);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Where the script was last being read (on any device), else where playback stopped.
        final rr = session.restoredReading;
        if (rr == null || !_jumpToReading(rr.$1, rr.$2, animate: false)) _scrollToCurrent(animate: false);
        _restored = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _updateViewScene());
      });
    });
    if (widget.folderAccess) _syncTimer = Timer.periodic(const Duration(seconds: 20), (_) => _checkOtherDevices());
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() {
          textSize = (p.getInt('phoneTextSize') ?? 1).clamp(0, 3);
          _lineHintSeen = p.getBool(_lineHintSeenKey) ?? false;
          _showPages = p.getBool(_showPagesKey) ?? false;
          _pdfOpen = p.getBool(_pdfOpenKey) ?? false;
        });
        if (_showPages || _pdfOpen) _preparePdf(open: false);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _viewScene.dispose();
    _head.dispose();
    _fadeTimer?.cancel();
    _fade.dispose();
    bookmarks?.dispose();
    if (widget.audio) nowPlaying.detach();
    for (final sub in _audioSubs) {
      sub.cancel();
    }
    _edgeScroll?.cancel();
    _queryCtl.dispose();
    _queryFocus.dispose();
    _keyFocus.dispose();
    pdf.dispose();
    notes?.dispose();
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
    if (player.isPlaying && _head.value != null && !_scrubbing) _head.value = null; // audio is the truth while it plays
    final scene = player.currentScene?.sceneNumber;
    if (player.currentCueIndex != _lastCue || scene != _lastScene) {
      _lastCue = player.currentCueIndex;
      _lastScene = scene;
      if (player.isPlaying && _following) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToCurrent();
          _noteReading(playing: true);
        });
      }
      _followPdf();
    }
    setState(() {});
  }

  PhoneScene? _sceneNumbered(int? n) => session.scenes.where((s) => s.number == n).firstOrNull;

  /// Scrolls so [key]'s row sits [alignment] of the way down the view.
  void _reveal(GlobalKey key, {double alignment = 0.3, bool animate = true, Duration duration = const Duration(milliseconds: 250), int settle = 0}) {
    final ro = key.currentContext?.findRenderObject();
    if (ro == null || !scroll.hasClients) return;
    final viewport = RenderAbstractViewport.maybeOf(ro);
    if (viewport == null) return;
    final pos = scroll.position;
    final target = viewport.getOffsetToReveal(ro, alignment).offset.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (animate) {
      scroll.animateTo(target, duration: duration, curve: duration.inMilliseconds > 300 ? Curves.easeInOutCubic : Curves.easeOut).then((_) {
        // Lines above can change height while the scroll runs (highlights, notes opening): land exactly.
        if (mounted && settle < 2 && scroll.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !scroll.hasClients) return;
            final r = key.currentContext?.findRenderObject();
            final v = r == null ? null : RenderAbstractViewport.maybeOf(r);
            final off = v?.getOffsetToReveal(r!, alignment).offset.clamp(scroll.position.minScrollExtent, scroll.position.maxScrollExtent);
            if (off != null && (off - scroll.offset).abs() > 2)
              _reveal(key, alignment: alignment, duration: const Duration(milliseconds: 160), settle: settle + 1);
          });
        }
      });
    } else {
      scroll.jumpTo(target);
    }
  }

  void _scrollToCurrent({bool animate = true}) {
    final s = _sceneNumbered(player.currentScene?.sceneNumber);
    if (s == null) return;
    final i = s.lines.indexWhere((l) => l.cueIndex == player.currentCueIndex);
    if (i < 0) return;
    _reveal(_key('${s.number}:$i'), animate: animate);
  }

  /// Smoothly scrolls so scene [number]'s title is at the top (and parks playback there if it is rendered).
  void _jumpToScene(int number) {
    final si = player.scenes.indexWhere((s) => s.sceneNumber == number);
    if (si >= 0 && si != player.currentSceneIndex) player.switchToScene(si);
    setState(_clearSelection);
    _userScrolled = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(_key('h$number'), alignment: 0, duration: const Duration(milliseconds: 480)));
  }

  /// Dragging along the outline: the script follows at once.
  void _scrubToScene(int number) {
    _userScrolled = DateTime.now();
    _reveal(_key('h$number'), alignment: 0, animate: false);
  }

  void _tapLine(PhoneScene s, PhoneLine l) {
    if (_selA != null) {
      setState(_clearSelection);
      return;
    }
    // A tap points the line out for a moment; it does not play it. Play does that, from here.
    _indicate(s.number, s.lines.indexOf(l));
    _releaseIndicator(delay: const Duration(milliseconds: 350));
    if (!s.rendered || l.cueIndex == null) return;
    final playingHere = player.currentScene?.sceneNumber == s.number;
    // My blanked line: peek (shows it and reads it aloud; tap again to hide).
    if (playingHere && l.isDialog && player.isMyLine(l.speaker) && player.blockMyLines) {
      player.peekLine(l.cueIndex!);
      return;
    }
    if (playingHere && player.waitingAtCue == l.cueIndex) {
      player.peekLine(l.cueIndex!);
      return;
    }
    final item = player.scenes.where((i) => i.sceneNumber == s.number).firstOrNull;
    if (item == null || l.cueIndex! >= item.cues.length) return;
    _head.value = null;
    _parkAt(s.number, item.cues[l.cueIndex!].startTime);
  }

  // The playhead, and the line pointed out ----------------------------------------

  /// Where the script is on the page: the line [depth] of the way down the view (0.3 is where playback puts the line it is
  /// reading), as scene index, line index and how far through that line.
  ({int scene, int line, double frac})? _probe([double depth = 0.3]) {
    final vp = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (vp == null || !vp.attached || !vp.hasSize || session.scenes.isEmpty) return null;
    final y = vp.localToGlobal(Offset.zero).dy + vp.size.height * depth;
    var si = 0;
    for (final (i, sc) in session.scenes.indexed) {
      final box = _keys['h${sc.number}']?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      if (box.localToGlobal(Offset.zero).dy <= y) {
        si = i;
      } else {
        break;
      }
    }
    final scene = session.scenes[si];
    for (var i = 0; i < scene.lines.length; i++) {
      final lb = _keys['${scene.number}:$i']?.currentContext?.findRenderObject() as RenderBox?;
      if (lb == null || !lb.attached || !lb.hasSize) continue;
      final top = lb.localToGlobal(Offset.zero).dy;
      if (top + lb.size.height > y) return (scene: si, line: i, frac: ((y - top) / lb.size.height).clamp(0.0, 1.0));
    }
    return (scene: si, line: scene.lines.isEmpty ? 0 : scene.lines.length - 1, frac: 1.0);
  }

  /// Scrolling moves the playhead to where you are on the page. Nothing plays or seeks yet.
  void _updateHead() {
    if (!mounted || _scrubbing) return;
    if (player.isPlaying) {
      if (_head.value != null) _head.value = null;
      return;
    }
    // At the very top of the script the playhead is at the start, not 30 % of the way down the first screen.
    final atTop = scroll.hasClients && scroll.offset <= 2 && session.scenes.isNotEmpty;
    final at = atTop ? (scene: 0, line: 0, frac: 0.0) : _probe();
    if (at == null) return;
    final scene = session.scenes[at.scene];
    final item = player.scenes.where((i) => i.sceneNumber == scene.number).firstOrNull;
    final ci = scene.lines.isEmpty ? null : scene.lines[at.line].cueIndex;
    final _Head h;
    if (item == null || ci == null || ci >= item.cues.length) {
      h = _Head(scene.number, 0, rendered: item != null);
    } else {
      final c = item.cues[ci];
      h = _Head(scene.number, c.startTime + at.frac * (c.endTime - c.startTime), cue: ci, rendered: true);
    }
    final old = _head.value;
    if (old == null || old.scene != h.scene || old.rendered != h.rendered || (old.time - h.time).abs() > 0.02) _head.value = h;
  }

  /// The scene the timeline shows (the one scrolled to, or the playing one) and its audio, if it has any.
  ({int? number, ScenePlayerItem? item}) _shown() {
    final h = _head.value;
    if (h != null) return (number: h.scene, item: h.rendered ? player.scenes.where((i) => i.sceneNumber == h.scene).firstOrNull : null);
    final it = player.currentScene;
    return (number: it?.sceneNumber, item: it);
  }

  /// Puts the player's playhead where the script is scrolled to (what Play, Previous and Next start from).
  Future<void> _commitHead() async {
    final h = _head.value;
    _head.value = null;
    if (h == null || !h.rendered) return;
    await _parkAt(h.scene, h.time);
  }

  /// Moves the player's playhead without starting it (a playing one carries on from there).
  Future<void> _parkAt(int sceneNumber, double time) async {
    final si = player.scenes.indexWhere((i) => i.sceneNumber == sceneNumber);
    if (si < 0) return;
    if (si != player.currentSceneIndex) {
      await player.switchToScene(si, startAt: time);
    } else {
      player.seek(time);
    }
  }

  void _scrubStart() {
    _scrubbing = true;
    _userScrolled = DateTime.now();
    _scrubWasPlaying = player.isPlaying;
    if (_scrubWasPlaying) player.pause();
    if (_selA != null) setState(_clearSelection);
  }

  /// Dragging the playhead: the script runs to the line at that time, and the line is pointed out while the finger is down.
  void _scrubTo(double time) {
    final item = _shown().item;
    final scene = _sceneNumbered(item?.sceneNumber);
    if (item == null || scene == null) return;
    var ci = 0;
    for (var i = 0; i < item.cues.length; i++) {
      if (item.cues[i].startTime <= time) ci = i;
    }
    _head.value = _Head(scene.number, time, cue: ci, rendered: true);
    final line = scene.lines.indexWhere((l) => l.cueIndex == ci);
    if (line < 0) return;
    _indicate(scene.number, line);
    final k = _key('${scene.number}:$line');
    if (k.currentContext != null) _reveal(k, animate: false);
  }

  Future<void> _scrubEnd(double time) async {
    _scrubbing = false;
    await _commitHead();
    if (_scrubWasPlaying) {
      _userScrolled = DateTime.fromMillisecondsSinceEpoch(0);
      player.play();
    }
    _scrubWasPlaying = false;
    _releaseIndicator();
  }

  /// Outlines a line until [_releaseIndicator] lets it fade.
  void _indicate(int scene, int line) {
    if (line < 0) return;
    _fadeTimer?.cancel();
    _fade.stop();
    _fade.value = 1;
    if (_indicated?.scene != scene || _indicated?.line != line) setState(() => _indicated = (scene: scene, line: line));
  }

  void _releaseIndicator({Duration delay = Duration.zero}) {
    _fadeTimer?.cancel();
    _fadeTimer = Timer(delay, () {
      if (!mounted) return;
      _fade.animateTo(0, duration: const Duration(milliseconds: 800), curve: Curves.easeOut).then((_) {
        if (mounted && _fade.value == 0 && _indicated != null) setState(() => _indicated = null);
      });
    });
  }

  // Loop selection -------------------------------------------------------------

  void _clearSelection() {
    _selScene = null;
    _selA = null;
    _selB = null;
    _dragPoint = null;
    _edgeScroll?.cancel();
    _edgeScroll = null;
  }

  int? _lineAt(Offset global) {
    final s = _sceneNumbered(_selScene);
    if (s == null) return null;
    int? nearest;
    var best = double.infinity;
    for (var i = 0; i < s.lines.length; i++) {
      if (s.lines[i].cueIndex == null) continue;
      final box = _keys['${s.number}:$i']?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy, bottom = top + box.size.height;
      if (global.dy >= top && global.dy < bottom) return i;
      // Past the scene's first or last line: the nearest one.
      final d = global.dy < top ? top - global.dy : global.dy - bottom;
      if (d < best) {
        best = d;
        nearest = i;
      }
    }
    return nearest;
  }

  void _dragTo(Offset global) {
    _dragPoint = global;
    final j = _lineAt(global);
    if (j != null && j != _selB) setState(() => _selB = j);
    // Near the top or bottom edge: keep scrolling, faster the closer the finger.
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final top = box.localToGlobal(Offset.zero).dy, bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    const zone = 72.0;
    final speed = global.dy > bottom - zone
        ? (global.dy - (bottom - zone)) / zone
        : (global.dy < top + zone ? -((top + zone) - global.dy) / zone : 0.0);
    if (speed == 0) {
      _edgeScroll?.cancel();
      _edgeScroll = null;
      return;
    }
    _edgeScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final p = _dragPoint;
      if (p == null || !scroll.hasClients) return;
      final b = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (b == null) return;
      final t0 = b.localToGlobal(Offset.zero).dy, b0 = b.localToGlobal(Offset(0, b.size.height)).dy;
      final v = p.dy > b0 - zone ? (p.dy - (b0 - zone)) / zone : (p.dy < t0 + zone ? -((t0 + zone) - p.dy) / zone : 0.0);
      if (v == 0) return;
      final pos = scroll.position;
      scroll.jumpTo((pos.pixels + v.clamp(-1.0, 1.0) * 14).clamp(pos.minScrollExtent, pos.maxScrollExtent));
      final j = _lineAt(p);
      if (j != null && j != _selB) setState(() => _selB = j);
    });
  }

  void _loopSelection() {
    final s = _sceneNumbered(_selScene);
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

  /// Set by the layout each build: whether the PDF can sit beside the script.
  bool _canSplit = false;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: t.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          bottom: false,
          child: Focus(
            focusNode: _keyFocus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: LayoutBuilder(
              builder: (context, box) {
                final size = sizeClassOf(box.maxWidth);
                _canSplit = box.maxWidth >= splitPdfMinWidth;
                final pane = _pdfOpen && _canSplit && _pdfPath.isNotEmpty;
                session.deviceLabel = isPadDisplay(context) ? 'iPad' : 'iPhone';
                final center = Column(
                  children: [
                    _searching ? _searchBar(t) : _header(t, wide: size != SizeClass.compact),
                    if (_incoming != null) _syncChip(t),
                    Expanded(child: session.scenes.isEmpty ? _empty(t) : _script(t)),
                    if (_selA != null && !_floatingMenu) _selectionBar(t),
                    if (_showLineHint) _lineHint(t),
                    if (player.scenes.isNotEmpty) _bar(t),
                  ],
                );
                if (!pane) return center;
                final pdfWidth = (box.maxWidth * 0.42).clamp(340.0, 620.0);
                return Row(
                  children: [
                    Expanded(child: center),
                    VerticalDivider(width: 1, color: t.rule),
                    SizedBox(width: pdfWidth, child: _pdfPane()),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // Keyboard (iPad) ------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final kb = HardwareKeyboard.instance;
    final cmd = kb.isMetaPressed, shift = kb.isShiftPressed;
    if (cmd && key == LogicalKeyboardKey.keyF) {
      _openSearch();
      return KeyEventResult.handled;
    }
    if (cmd && key == LogicalKeyboardKey.keyG) {
      if (_hits.isEmpty) return KeyEventResult.ignored;
      _stepHit(!shift);
      return KeyEventResult.handled;
    }
    if (cmd && shift && key == LogicalKeyboardKey.keyP) {
      _pdfOpen && _canSplit ? _closePdf() : _preparePdf();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _searching) {
      _closeSearch();
      return KeyEventResult.handled;
    }
    // Typing in the search field (or a note): the letters are theirs.
    final typing = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (typing || cmd) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.space && player.scenes.isNotEmpty) {
      _userScrolled = DateTime.fromMillisecondsSinceEpoch(0);
      player.togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight && player.scenes.isNotEmpty) {
      player.nextLine();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && player.scenes.isNotEmpty) {
      player.prevLine();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // Header ---------------------------------------------------------------------

  String get _rolesLabel => player.myRoles.map(titleCaseName).join(', ');

  Widget _header(Tokens t, {required bool wide}) {
    final hasRole = player.myRole.isNotEmpty;
    Widget icon(IconData i, String tip, VoidCallback? onTap, {bool on = false}) => IconButton(
      tooltip: tip,
      icon: Icon(i, color: on ? const Color(0xFF1C1B19) : t.ink2, size: 22),
      style: on ? IconButton.styleFrom(backgroundColor: t.highlighter) : null,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
      onPressed: onTap,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 2),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Projects',
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: t.accent, size: 22),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              widget.project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyles.ui(t, size: 17, weight: FontWeight.w600),
            ),
          ),
          icon(Icons.search_rounded, 'Search the script', _openSearch),
          // With a playback bar the bookmarks live there; a text-only project has no bar.
          if (player.scenes.isEmpty && bookmarks != null)
            icon((bookmarks?.count ?? 0) > 0 ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, 'Bookmarks', _openBookmarks),
          if (wide)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: TextButton.icon(
                key: const Key('myCharacter'),
                onPressed: _openRoleSheet,
                icon: Icon(Icons.person_rounded, size: 18, color: hasRole ? const Color(0xFF1C1B19) : t.ink2),
                label: Text(
                  hasRole ? _rolesLabel : 'My Character',
                  style: TextStyles.ui(t, size: 14, weight: FontWeight.w600, color: hasRole ? const Color(0xFF1C1B19) : t.ink2),
                ),
                style: TextButton.styleFrom(backgroundColor: hasRole ? t.highlighter : null, minimumSize: const Size(44, 40)),
              ),
            )
          else
            icon(Icons.person_rounded, hasRole ? 'My Character: $_rolesLabel' : 'My Character', _openRoleSheet, on: hasRole),
          if (_pdfPath.isNotEmpty) icon(Icons.picture_as_pdf_rounded, 'Show PDF', _togglePdf, on: _pdfOpen && _canSplit),
          TextButton(
            onPressed: _openTextOptions,
            style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: 8), foregroundColor: t.ink2),
            child: Text(
              'Aa',
              style: TextStyles.ui(t, size: 17, weight: FontWeight.w600, color: t.ink2),
            ),
          ),
        ],
      ),
    );
  }

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

  // Search (#113) --------------------------------------------------------------

  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _queryFocus.requestFocus());
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _queryCtl.clear();
      _hits = const [];
      _hitsByLine = const {};
      _hit = 0;
    });
    if (_pdfBesideScript) pdf.clearSearch();
    _keyFocus.requestFocus();
  }

  /// The PDF sits beside the script: one search covers both.
  bool get _pdfBesideScript => _pdfOpen && _canSplit && _pdfPath.isNotEmpty;

  void _runSearch(String q) {
    // A line blanked for practice stays blank: searching can't be used to read it.
    final hits = searchScript(session, q, skip: (l) => l.isDialog && player.blockMyLines && player.isMyLine(l.speaker));
    final by = <String, List<SearchHit>>{};
    for (final h in hits) {
      by.putIfAbsent(session.scenes[h.scene].lines[h.line].key, () => []).add(h);
    }
    setState(() {
      _hits = hits;
      _hitsByLine = by;
      _hit = 0;
    });
    if (_pdfBesideScript) pdf.search(q, reveal: false);
    if (hits.isNotEmpty) _revealHit();
  }

  void _stepHit(bool forward) {
    if (_hits.isEmpty) return;
    setState(() => _hit = (_hit + (forward ? 1 : _hits.length - 1)) % _hits.length);
    _revealHit();
  }

  void _revealHit() {
    final h = _hits[_hit];
    _userScrolled = DateTime.now();
    _revealLine(h.scene, h.line);
    // Beside the script, the PDF turns to the page the match is on.
    final page = _pageOf?[session.scenes[h.scene].lines[h.line].key];
    if (_pdfBesideScript && page != null && page != pdf.page) pdf.goToPage(page);
  }

  /// Scrolls to a line even when it is far away and not built yet: jumps to about where it should be (by how many
  /// lines come before it), then lets the list build and settles on the line itself.
  void _revealLine(int sceneIndex, int line, {double alignment = 0.35, int tries = 5}) {
    final s = session.scenes[sceneIndex];
    final key = _key('${s.number}:$line');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      if (key.currentContext != null) {
        _reveal(key, alignment: alignment);
        return;
      }
      if (tries == 0) return;
      var before = 0, total = 0;
      for (final (i, sc) in session.scenes.indexed) {
        if (i < sceneIndex) before += sc.lines.length;
        total += sc.lines.length;
      }
      before += line;
      final pos = scroll.position;
      pos.jumpTo((pos.maxScrollExtent * (before / (total == 0 ? 1 : total))).clamp(pos.minScrollExtent, pos.maxScrollExtent));
      _revealLine(sceneIndex, line, alignment: alignment, tries: tries - 1);
    });
    // A frame has to run for the callback above.
    WidgetsBinding.instance.scheduleFrame();
  }

  Widget _searchBar(Tokens t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 4, 4),
    child: SizedBox(
      height: 48,
      child: Row(
        children: [
          Icon(Icons.search_rounded, color: t.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const Key('scriptSearchField'),
              controller: _queryCtl,
              focusNode: _queryFocus,
              textInputAction: TextInputAction.search,
              style: TextStyles.ui(t, size: 16),
              decoration: const InputDecoration(hintText: 'Search the script', border: InputBorder.none, isDense: true),
              onChanged: _runSearch,
              onSubmitted: (_) => _stepHit(true),
            ),
          ),
          if (_queryCtl.text.trim().isNotEmpty)
            Text(_hits.isEmpty ? 'No matches' : '${_hit + 1} of ${_hits.length}', style: TextStyles.ui(t, size: 13, color: t.muted)),
          IconButton(
            tooltip: 'Previous match',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
            onPressed: _hits.isEmpty ? null : () => _stepHit(false),
          ),
          IconButton(
            tooltip: 'Next match',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: _hits.isEmpty ? null : () => _stepHit(true),
          ),
          TextButton(onPressed: _closeSearch, child: const Text('Done')),
        ],
      ),
    ),
  );

  // My Character, without any audio (#114) ------------------------------------

  Future<void> _openRoleSheet() async {
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.sheet,
      showDragHandle: true,
      constraints: sheetConstraints(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => ListenableBuilder(
        listenable: player,
        builder: (ctx, _) => _RoleSheet(player: player, session: session),
      ),
    );
    _keyFocus.requestFocus();
  }

  // The PDF (#115), its pages (#116) -------------------------------------------

  void _togglePdf() {
    if (_pdfOpen && _canSplit) {
      _closePdf();
    } else {
      _preparePdf();
    }
  }

  void _closePdf() {
    setState(() => _pdfOpen = false);
    SharedPreferences.getInstance().then((p) => p.setBool(_pdfOpenKey, false));
    _keyFocus.requestFocus();
  }

  /// Brings the PDF onto the device if it isn't, lines the script up with its pages, and (when [open]) shows it:
  /// beside the script on a wide window, on its own screen otherwise.
  Future<void> _preparePdf({bool open = true, int? page}) async {
    if (_pdfPath.isEmpty || _preparingPdf) return;
    setState(() => _preparingPdf = true);
    String? problem;
    try {
      if (!File(_pdfPath).existsSync() && widget.folderAccess) await FolderAccess.download([_pdfPath]);
      if (!File(_pdfPath).existsSync()) throw 'The PDF isn’t on this device yet.';
      if (_pageOf == null) {
        final read = widget.pageTexts ?? (PdfService.available ? PdfService.pageTexts : null);
        if (read != null) _alignPages(await read(_pdfPath));
      }
    } catch (e) {
      problem = 'Couldn’t open the PDF: $e';
    }
    if (!mounted) return;
    setState(() => _preparingPdf = false);
    if (problem != null) {
      if (open) showNotice(ScaffoldMessenger.of(context), problem);
      return;
    }
    if (!open) return;
    final at = page ?? _currentPage() ?? 1;
    if (_canSplit) {
      setState(() => _pdfOpen = true);
      SharedPreferences.getInstance().then((p) => p.setBool(_pdfOpenKey, true));
      pdf.onReady = () {
        pdf.goToPage(at);
        if (_searching && _queryCtl.text.trim().isNotEmpty) pdf.search(_queryCtl.text, reveal: false);
      };
      if (pdf.pageCount > 0) {
        pdf.goToPage(at);
        if (_searching && _queryCtl.text.trim().isNotEmpty) pdf.search(_queryCtl.text, reveal: false);
      }
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _PdfScreen(path: _pdfPath, folder: session.folder, page: at, folderAccess: widget.folderAccess),
        ),
      );
    }
  }

  void _alignPages(List<String> texts) {
    final lines = [for (final s in session.scenes) ...s.lines];
    final pages = alignLinesToPages(texts, [for (final l in lines) l.text]);
    final of = <String, int>{};
    final breaks = <String, int>{};
    for (final (i, l) in lines.indexed) {
      of[l.key] = pages[i];
      if (i > 0 && pages[i] != pages[i - 1]) breaks[l.key] = pages[i];
    }
    _pageOf = of;
    _breakBefore = breaks;
  }

  /// The PDF page of the line being read (or the first line on screen when nothing plays).
  int? _currentPage() {
    final pages = _pageOf;
    if (pages == null) return null;
    // Playing: the line being read. Otherwise the line at the top of the screen, wherever the player was left.
    if (player.isPlaying) {
      final s = _sceneNumbered(player.currentScene?.sceneNumber);
      final l = s?.lines.where((l) => l.cueIndex != null && l.cueIndex == player.currentCueIndex).firstOrNull;
      if (l != null) return pages[l.key];
    }
    final top = _topLine();
    if (top != null) {
      final lines = session.scenes[top.$1].lines;
      if (top.$2 < lines.length) return pages[lines[top.$2].key];
    }
    final s = _sceneNumbered(player.currentScene?.sceneNumber ?? _topScene);
    final l = s?.lines.firstOrNull;
    return l == null ? null : pages[l.key];
  }

  /// Keeps the PDF on the page being read while the script plays.
  void _followPdf() {
    if (!(_pdfOpen && _canSplit)) return;
    final p = _currentPage();
    if (p != null && p != pdf.page) pdf.goToPage(p);
  }

  Widget _pdfPane() => PdfPanel(
    pdfPath: _pdfPath,
    folder: session.folder,
    controller: pdf,
    pad: isPadDisplay(context),
    folderAccess: widget.folderAccess,
    onClose: _closePdf,
    linkedQuery: _searching ? _queryCtl.text : null,
    onSearch: _openSearch,
  );

  Future<void> _setShowPages(bool on) async {
    setState(() => _showPages = on);
    (await SharedPreferences.getInstance()).setBool(_showPagesKey, on);
    if (on && _pageOf == null) await _preparePdf(open: false);
  }

  // Where am I in the script, and position sync ------------------------------------

  /// The scene being read: the last one whose title has reached the top of the script. Every scene is laid out, so this
  /// is exact; it does not depend on what happens to be on screen.
  int? _sceneIndexAtTop() {
    final vp = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (vp == null || !vp.attached || !vp.hasSize) return null;
    final top = vp.localToGlobal(Offset.zero).dy + 6;
    int? found;
    for (final (si, s) in session.scenes.indexed) {
      final box = _keys['h${s.number}']?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      if (box.localToGlobal(Offset.zero).dy <= top) {
        found = si;
      } else {
        break;
      }
    }
    return found ?? (session.scenes.isEmpty ? null : 0);
  }

  /// The first line showing at the top of the script, as (scene index, line index).
  (int, int)? _topLine() {
    final si = _sceneIndexAtTop();
    final vp = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (si == null || vp == null) return null;
    final top = vp.localToGlobal(Offset.zero).dy;
    final s = session.scenes[si];
    for (var i = 0; i < s.lines.length; i++) {
      final lb = _keys['${s.number}:$i']?.currentContext?.findRenderObject() as RenderBox?;
      if (lb != null && lb.attached && lb.hasSize && lb.localToGlobal(Offset.zero).dy + lb.size.height > top) return (si, i);
    }
    // Past this scene's last line (its end padding): the next scene's first.
    if (si + 1 < session.scenes.length && session.scenes[si + 1].lines.isNotEmpty) return (si + 1, 0);
    return (si, 0);
  }

  bool _viewUpdateQueued = false, _readingQueued = false;

  void _queueViewUpdate({bool reading = false}) {
    _readingQueued = _readingQueued || reading;
    if (_viewUpdateQueued) return;
    _viewUpdateQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewUpdateQueued = false;
      final r = _readingQueued;
      _readingQueued = false;
      _updateViewScene();
      if (r) _noteReading();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Keeps the outline and the bar on the scene being read.
  void _updateViewScene() {
    if (!mounted) return;
    _updateHead();
    final si = _sceneIndexAtTop();
    if (si == null) return;
    final n = session.scenes[si].number;
    if (_viewScene.value != n) {
      _viewScene.value = n;
      setState(() {}); // the bar's name
    }
  }

  /// Remembers the line being read (in the rehearsal file other devices read). While playback is followed, that is the
  /// playing line; otherwise the first line on screen.
  void _noteReading({bool playing = false}) {
    if (!mounted || !_restored) return;
    PhoneScene? scene;
    PhoneLine? line;
    if (playing) {
      scene = _sceneNumbered(player.currentScene?.sceneNumber);
      line = scene?.lines.where((l) => l.cueIndex != null && l.cueIndex == player.currentCueIndex).firstOrNull;
    } else {
      final top = _topLine();
      if (top != null) {
        scene = session.scenes[top.$1];
        line = scene.lines.isEmpty ? null : scene.lines[top.$2];
      }
    }
    if (scene == null || line == null) return;
    if (session.readScene == scene.number && session.readLine == line.key) return;
    session.readScene = scene.number;
    session.readLine = line.key;
    session.readProgress = _progressOf(scene, line);
    _syncSeen = clockNow().toUtc();
    session.scheduleSave(player, folderAccess: widget.folderAccess, after: const Duration(seconds: 2));
  }

  /// How far through the script [line] is, by lines (0...1): what the project's cover shows.
  double _progressOf(PhoneScene scene, PhoneLine line) {
    var before = 0, total = 0;
    for (final sc in session.scenes) {
      if (identical(sc, scene)) before = total + sc.lines.indexOf(line);
      total += sc.lines.length;
    }
    return total <= 1 ? 0 : (before / (total - 1)).clamp(0.0, 1.0);
  }

  /// Scrolls to the line with [key] in scene [number]. False if the script has no such line.
  bool _jumpToReading(int number, String key, {bool animate = true}) {
    final si = session.scenes.indexWhere((s) => s.number == number);
    if (si < 0) return false;
    final li = session.scenes[si].lines.indexWhere((l) => l.key == key);
    if (li < 0) return false;
    _userScrolled = DateTime.now();
    _revealLine(si, li, alignment: 0.1);
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkOtherDevices();
  }

  /// Asks iCloud for the other devices' rehearsal files, then looks for one that has read further on than this device.
  Future<void> _checkOtherDevices() async {
    if (!mounted || _myDeviceId == null || !_restored) return;
    if (widget.folderAccess) {
      try {
        final dir = '${session.folder}/$rehearsalFolder';
        final stale = [
          for (final e in await FolderAccess.list(dir))
            if (!e.isDir && !e.downloaded) '$dir/${e.name}',
        ];
        if (stale.isNotEmpty) await FolderAccess.download(stale);
      } catch (_) {}
    }
    if (!mounted) return;
    final r = loadNewestRehearsal(session.folder);
    if (r == null || r.fileId == _myDeviceId || !r.updatedAt.isAfter(_syncSeen)) return;
    if (r.readScene == null || r.readLine.isEmpty || r.readLine == session.readLine) return;
    // Only offer a place this script has.
    final there = session.scenes.where((s) => s.number == r.readScene).firstOrNull;
    if (there == null || !there.lines.any((l) => l.key == r.readLine)) return;
    setState(() => _incoming = r);
  }

  @visibleForTesting
  Future<void> checkOtherDevicesForTest() => _checkOtherDevices();

  void _dismissIncoming() => setState(() {
    _syncSeen = _incoming?.updatedAt ?? _syncSeen;
    _incoming = null;
  });

  void _followIncoming() {
    final r = _incoming;
    if (r == null) return;
    _jumpToReading(r.readScene!, r.readLine);
    final si = player.scenes.indexWhere((i) => i.sceneNumber == r.readScene);
    if (si >= 0 && si != player.currentSceneIndex) player.switchToScene(si);
    _dismissIncoming();
  }

  /// "Your iPhone is at Scene 12": one tap to go there.
  Widget _syncChip(Tokens t) {
    final r = _incoming!;
    final scene = _sceneNumbered(r.readScene);
    final where = scene == null ? 'further on' : 'at scene ${scene.number}${scene.title.isEmpty ? '' : ' · ${scene.title}'}';
    return Container(
      key: const Key('syncChip'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: t.sheet,
        borderRadius: BorderRadius.circular(14),
        boxShadow: t.shadow,
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          Icon(Icons.sync_rounded, size: 18, color: t.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${r.device.isEmpty ? 'Another device' : r.device} is $where',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyles.ui(t, size: 14, weight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: _followIncoming, child: const Text('Jump there')),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: _dismissIncoming,
          ),
        ],
      ),
    );
  }

  // Bookmarks ------------------------------------------------------------------

  /// The line a new bookmark would mark: the one playing, else the first on screen.
  (PhoneScene, PhoneLine)? _spotLine() {
    if (player.isPlaying) {
      final s = _sceneNumbered(player.currentScene?.sceneNumber);
      final l = s?.lines.where((l) => l.cueIndex != null && l.cueIndex == player.currentCueIndex).firstOrNull;
      if (s != null && l != null) return (s, l);
    }
    final top = _topLine();
    if (top != null) {
      final s = session.scenes[top.$1];
      if (s.lines.isNotEmpty) return (s, s.lines[top.$2]);
    }
    final s = session.scenes.where((s) => s.lines.isNotEmpty).firstOrNull;
    return s == null ? null : (s, s.lines.first);
  }

  /// The line a bookmark would mark, drawn like it is in the script, only smaller.
  Widget _linePreview(Tokens t, PhoneScene s, PhoneLine l) {
    final size = 15 * _textScales[textSize] * 0.82;
    final mine = l.isDialog && player.isMyLine(l.speaker);
    final style = TextStyles.script(t, size: size, italic: !l.isDialog, color: l.isDialog ? t.ink : t.ink2).copyWith(height: 1.45);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${player.isPlaying ? 'Where it is playing' : 'Top of the screen'} · scene ${s.number}',
            style: TextStyles.ui(t, size: 12, color: t.muted),
          ),
          const SizedBox(height: 6),
          Container(
            key: const Key('bookmarkPreview'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
            decoration: BoxDecoration(
              color: mine ? t.mine : t.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: t.rule),
            ),
            child: l.isDialog
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final n in l.names)
                            NameChip(n, allSpeakers: session.characters, uppercase: true, size: 12.5 * 0.82 * _textScales[textSize]),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(l.text, maxLines: 4, overflow: TextOverflow.ellipsis, style: style),
                    ],
                  )
                : Text(l.text, maxLines: 4, overflow: TextOverflow.ellipsis, style: style),
          ),
        ],
      ),
    );
  }

  /// Goes to a bookmarked line (and, if its scene is rendered, parks playback there).
  void _goToBookmark(String key, Bookmark b) {
    final s = _sceneNumbered(b.scene);
    if (s == null) return;
    _jumpToReading(b.scene, key);
    final l = s.lines.where((l) => l.key == key).firstOrNull;
    final si = player.scenes.indexWhere((i) => i.sceneNumber == s.number);
    if (si >= 0 && l?.cueIndex != null) player.switchToScene(si, startAt: player.scenes[si].cues[l!.cueIndex!].startTime);
  }

  Future<void> _openBookmarks() async {
    final bm = bookmarks;
    if (bm == null) return;
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.sheet,
      showDragHandle: true,
      constraints: sheetConstraints(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => ListenableBuilder(
        listenable: bm,
        builder: (ctx, _) {
          final spot = _spotLine();
          final here = spot != null && bm.has(spot.$2.key);
          // In script order.
          final order = <String, int>{};
          for (final s in session.scenes) {
            for (final l in s.lines) {
              order[l.key] = order.length;
            }
          }
          final items = bm.live.entries.toList()..sort((a, b) => (order[a.key] ?? 1 << 30).compareTo(order[b.key] ?? 1 << 30));
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Bookmarks', style: TextStyles.ui(t, size: 22, weight: FontWeight.w700)),
                        ),
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (spot != null)
                      FilledButton.icon(
                        key: const Key('bookmarkHere'),
                        onPressed: () => bm.toggle(spot.$2.key, spot.$1.number, spot.$2.text),
                        icon: Icon(here ? Icons.bookmark_remove_rounded : Icons.bookmark_add_rounded, size: 20),
                        label: Text(here ? 'Remove the bookmark here' : 'Bookmark this spot', overflow: TextOverflow.ellipsis),
                        style: FilledButton.styleFrom(
                          backgroundColor: here ? t.panel : t.accent,
                          foregroundColor: here ? t.ink : t.onAccent,
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                    if (spot != null) _linePreview(t, spot.$1, spot.$2),
                    const SizedBox(height: 10),
                    if (items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'No bookmarks yet. You can also long-press a line and tap Bookmark.',
                          textAlign: TextAlign.center,
                          style: TextStyles.ui(t, size: 15, color: t.muted, height: 1.4),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final e in items)
                              Dismissible(
                                key: ValueKey(e.key),
                                direction: DismissDirection.endToStart,
                                onDismissed: (_) => bm.remove(e.key),
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  color: t.panel,
                                  child: const Icon(Icons.delete_outline_rounded),
                                ),
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.bookmark_rounded, color: t.dark ? t.highlighter : t.highlighterEdge),
                                  title: Text(e.value.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyles.script(t, size: 15)),
                                  subtitle: Text(
                                    'Scene ${e.value.scene}${_sceneNumbered(e.value.scene)?.title.isEmpty ?? true ? '' : ' · ${_sceneNumbered(e.value.scene)!.title}'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyles.ui(t, color: t.muted),
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'Remove bookmark',
                                    icon: const Icon(Icons.close_rounded, size: 20),
                                    onPressed: () => bm.remove(e.key),
                                  ),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _goToBookmark(e.key, e.value);
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    _keyFocus.requestFocus();
  }

  // Notes (#117) ---------------------------------------------------------------

  Future<void> _editNote(PhoneLine l) async {
    final n = notes;
    if (n == null) return;
    final t = Tokens.of(context);
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.sheet,
      showDragHandle: true,
      constraints: sheetConstraints(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _NoteSheet(line: l, existing: n[l.key]?.text),
    );
    if (text == null) return;
    await n.set(l.key, text);
    if (n.has(l.key)) n.expanded.add(l.key);
    if (mounted) setState(() {});
    _keyFocus.requestFocus();
  }

  final GlobalKey _stackKey = GlobalKey();
  final GlobalKey _barKey = GlobalKey();

  Widget _script(Tokens t) {
    final scale = _textScales[textSize];
    return LayoutBuilder(
      builder: (context, box) {
        // On a big window the script keeps a readable width, centred.
        final side = ((box.maxWidth - 800) / 2).clamp(0.0, double.infinity);
        return Stack(
          key: _stackKey,
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  _sceneBar(t, side),
                  Expanded(child: _scrollView(t, scale, side, box.maxHeight)),
                ],
              ),
            ),
            if (session.scenes.length > 1)
              Positioned(
                top: _headingHeight,
                bottom: 0,
                left: 0,
                right: 0,
                child: OutlineRail(
                  key: _railKey,
                  scenes: session.scenes,
                  current: _viewScene,
                  onPick: _jumpToScene,
                  onScrub: _scrubToScene,
                  bookmarked: {for (final b in bookmarks?.live.values ?? const <Bookmark>[]) b.scene},
                ),
              ),
            if (_selA != null && _dragPoint == null && _floatingMenu) _floatingSelectionMenu(t),
          ],
        );
      },
    );
  }

  /// The selection menu floats on the line, on the iPhone too (an experiment: set this false to put the iPhone's back in the
  /// bar at the bottom of the screen).
  static const _floatingMenuOnPhone = true;
  bool get _floatingMenu => isPadDisplay(context) || _floatingMenuOnPhone;

  /// The bar at the top of the script: the name of the scene being read changes as you scroll; the Text only tag and the
  /// scenes button stay where they are.
  Widget _sceneBar(Tokens t, double side) {
    final scene = _sceneNumbered(_viewScene.value ?? _topScene) ?? session.scenes.firstOrNull;
    if (scene == null) return const SizedBox.shrink();
    return Material(
      key: _barKey,
      color: t.bg,
      child: InkWell(
        onTap: () => _openScenesFromBar(),
        child: Container(
          height: _headingHeight,
          padding: EdgeInsets.fromLTRB(20 + side, 0, 14 + side, 0),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.rule)),
          ),
          child: Row(
            children: [
              Expanded(
                child: ClipRect(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (current, previous) =>
                        Stack(alignment: Alignment.centerLeft, children: [...previous, if (current != null) current]),
                    transitionBuilder: (child, anim) {
                      // The new name rises in from below as the old one leaves upward.
                      final entering = child.key == ValueKey(scene.number);
                      final slide = Tween<Offset>(begin: Offset(0, entering ? 0.6 : -0.6), end: Offset.zero).animate(anim);
                      return FadeTransition(
                        opacity: anim,
                        child: SlideTransition(position: slide, child: child),
                      );
                    },
                    child: Row(
                      key: ValueKey(scene.number),
                      children: [
                        Text(
                          scene.number.toString().padLeft(2, '0'),
                          style: TextStyles.script(t, size: 14, weight: FontWeight.w700, color: t.muted),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            scene.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyles.ui(t, size: 16, weight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: scene.rendered
                      ? const SizedBox(key: ValueKey('rendered'))
                      : Padding(
                          key: const ValueKey('textOnly'),
                          padding: const EdgeInsets.only(left: 8, right: 6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: t.panel,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: t.border),
                            ),
                            child: Text(
                              'Text only',
                              style: TextStyles.ui(t, size: 11.5, weight: FontWeight.w600, color: t.muted),
                            ),
                          ),
                        ),
                ),
              ),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: t.accentSoft, shape: BoxShape.circle),
                child: Icon(Icons.unfold_more_rounded, size: 18, color: t.accent, semanticLabel: 'Scenes'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A scene's title where the scene starts, in the script itself (it scrolls away; the bar above carries on).
  Widget _sceneTitleRow(Tokens t, PhoneScene s) => Padding(
    key: _key('h${s.number}'),
    padding: const EdgeInsets.fromLTRB(10, 22, 10, 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          s.number.toString().padLeft(2, '0'),
          style: TextStyles.script(t, size: 13, weight: FontWeight.w700, color: t.muted),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(s.title, style: TextStyles.ui(t, size: 17, weight: FontWeight.w700)),
        ),
      ],
    ),
  );

  Widget _scrollView(Tokens t, double scale, double side, double height) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is UserScrollNotification && n.direction != ScrollDirection.idle) {
          _userScrolled = DateTime.now();
          _railKey.currentState?.collapse();
        }
        // After the frame: the notification can come before the layout it describes.
        if (n is ScrollUpdateNotification || n is ScrollEndNotification) _queueViewUpdate(reading: n is ScrollEndNotification);
        return false;
      },
      child: CustomScrollView(
        key: _viewportKey,
        controller: scroll,
        slivers: [
          for (final s in session.scenes)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(20 + side, 0, 20 + side, 20),
              // Not lazy within a scene: playback can scroll to any line.
              sliver: SliverToBoxAdapter(
                child: Column(
                  key: _key('${s.number}'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_sceneTitleRow(t, s), for (final (i, l) in s.lines.indexed) _line(t, s, i, l, scale)],
                ),
              ),
            ),
          // Room under the last scene, so every scene (the last ones too) can be scrolled up to the top.
          SliverToBoxAdapter(child: SizedBox(height: (height - _headingHeight - 160).clamp(40.0, 1200.0))),
        ],
      ),
    );
  }

  /// Search highlights inside a line's text: the current match in the highlighter, the others paler.
  InlineSpan _spans(String text, List<SearchHit>? hits, SearchHit? current, TextStyle style, Tokens t) {
    final inText = [
      for (final h in hits ?? const <SearchHit>[])
        if (h.inText) h,
    ];
    if (inText.isEmpty) return TextSpan(text: text, style: style);
    final out = <InlineSpan>[];
    var at = 0;
    for (final h in inText) {
      final a = h.start.clamp(0, text.length), b = h.end.clamp(0, text.length);
      if (a < at || b <= a) continue;
      if (a > at) out.add(TextSpan(text: text.substring(at, a)));
      out.add(
        TextSpan(
          text: text.substring(a, b),
          style: TextStyle(
            backgroundColor: identical(h, current) ? t.highlighter : t.highlighter.withValues(alpha: 0.5),
            color: const Color(0xFF1C1B19),
          ),
        ),
      );
      at = b;
    }
    if (at < text.length) out.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: out);
  }

  Widget _line(Tokens t, PhoneScene s, int i, PhoneLine l, double scale) {
    final playingHere = player.currentScene?.sceneNumber == s.number;
    // The line being read is marked only while something is being read (or it waits for you): a playhead parked by scrolling, a
    // tap or scrubbing leaves the script looking normal.
    final current = playingHere && l.cueIndex != null && l.cueIndex == player.currentCueIndex && (player.isPlaying || player.waitingAtCue != null);
    final mine = l.isDialog && player.isMyLine(l.speaker);
    final revealed = playingHere && l.cueIndex != null && l.cueIndex == player.revealedCue;
    final blocked = mine && player.blockMyLines && !revealed;
    final a = _selA, b = _selB;
    final selected = _selScene == s.number && a != null && b != null && i >= (a < b ? a : b) && i <= (a < b ? b : a);
    const onHighlighter = Color(0xFF1C1B19);
    final hits = _hitsByLine[l.key];
    final hit = _hits.isEmpty ? null : _hits[_hit];
    final hasCurrentHit = hit != null && hits != null && hits.any((h) => identical(h, hit));
    final note = notes?[l.key];
    final noteOpen = note != null && notes!.expanded.contains(l.key);
    final marked = bookmarks?.has(l.key) ?? false;
    final breakPage = _showPages ? _breakBefore[l.key] : null;
    final textStyle = TextStyles.script(
      t,
      size: 15 * scale,
      italic: !l.isDialog,
      // The highlighter is yellow in both themes: dark ink on it.
      color: current ? onHighlighter : (blocked ? t.muted : (l.isDialog ? t.ink : t.ink2)),
    ).copyWith(height: 1.45, letterSpacing: blocked ? 0.3 : null);
    final text = blocked ? Text(blockText(l.text), style: textStyle) : Text.rich(_spans(l.text, hits, hit, textStyle, t));
    final body = l.isDialog
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final n in l.names) NameChip(n, allSpeakers: session.characters, uppercase: true, size: 12.5 * scale),
                  if (mine)
                    Text(
                      '· YOU',
                      style: TextStyles.ui(t, size: 11 * scale, weight: FontWeight.w600, color: current ? const Color(0xFF46433E) : t.ink2),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              text,
            ],
          )
        : text;
    final hovered = _hover == l.key;
    // My lines are filled in my character's own colour (the yellow stays for the line being read).
    final myName = mine ? l.names.firstWhere(player.myRoles.contains, orElse: () => l.names.first) : null;
    final Color? fill = current
        ? t.highlighter
        : (selected ? t.accentSoft : (mine ? speakerColors(myName!, session.characters, t).highlight : (hovered ? t.ruleSoft : null)));
    final row = MouseRegion(
      onEnter: (_) => setState(() => _hover = l.key),
      onExit: (_) => setState(() {
        if (_hover == l.key) _hover = null;
      }),
      child: RawGestureDetector(
        key: _key('${s.number}:$i'),
        behavior: HitTestBehavior.opaque,
        gestures: {
          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            TapGestureRecognizer.new,
            (r) => r.onTap = () => _tapLine(s, l),
          ),
          // Quicker than the system's half second.
          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 220)),
            (r) => r
              ..onLongPressStart = (d) {
                HapticFeedback.selectionClick();
                setState(() {
                  _selScene = s.number;
                  _selA = _selB = i;
                  _dragPoint = d.globalPosition;
                });
              }
              ..onLongPressMoveUpdate = s.rendered ? (d) => _dragTo(d.globalPosition) : null
              ..onLongPressEnd = (_) {
                _edgeScroll?.cancel();
                _edgeScroll = null;
                setState(() => _dragPoint = null);
              },
          ),
        },
        child: Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: EdgeInsets.fromLTRB(10, 8, 10 + (note == null ? 0 : 24) + (marked ? 22 : 0), 8),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(6),
                border: current
                    ? Border.all(color: t.dark ? onHighlighter : t.highlighterEdge, width: 2)
                    : (selected
                          ? Border.all(color: t.accentLine, width: 1.5)
                          : (hasCurrentHit ? Border.all(color: t.highlighterEdge, width: 1.5) : null)),
              ),
              child: SizedBox(width: double.infinity, child: body),
            ),
            if (_indicated != null && _indicated!.scene == s.number && _indicated!.line == i)
              Positioned.fill(
                top: 4,
                bottom: 4,
                child: IgnorePointer(
                  child: FadeTransition(
                    opacity: _fade,
                    child: DecoratedBox(
                      key: const Key('lineIndicator'),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: t.accent.withValues(alpha: 0.08),
                        border: Border.all(color: t.accent.withValues(alpha: 0.75), width: 2),
                      ),
                    ),
                  ),
                ),
              ),
            if (marked)
              Positioned(
                top: 6,
                right: note == null ? 6 : 30,
                child: Icon(Icons.bookmark_rounded, size: 18, color: t.dark ? t.highlighter : t.highlighterEdge),
              ),
            if (note != null)
              Positioned(
                top: 6,
                right: 4,
                child: _NoteFlag(open: noteOpen, onTap: () => notes!.toggle(l.key)),
              ),
          ],
        ),
      ),
    );
    if (breakPage == null && note == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (breakPage != null)
          _PageBreakMark(
            page: breakPage,
            onTap: () => _preparePdf(page: breakPage),
          ),
        row,
        if (note != null)
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: noteOpen
                  ? _NoteCard(key: ValueKey('card${l.key}'), text: note.text, onEdit: () => _editNote(l), onCollapse: () => notes!.toggle(l.key))
                  : const SizedBox(width: double.infinity),
            ),
          ),
      ],
    );
  }

  /// Line! is in the bar only while Block My Lines is on.
  bool get _lineButton => player.blockMyLines && player.myRole.isNotEmpty;

  /// Shown once, the first time Line! appears.
  bool _lineHintSeen = true;
  bool get _showLineHint => _lineButton && !_lineHintSeen;

  Future<void> _dismissLineHint() async {
    if (_lineHintSeen) return;
    setState(() => _lineHintSeen = true);
    (await SharedPreferences.getInstance()).setBool(_lineHintSeenKey, true);
  }

  /// Like calling "Line!" to whoever is on book: plays your line; calling
  /// again while it plays stops it.
  void _callLine() {
    _dismissLineHint();
    player.callForLine();
  }

  Widget _lineHint(Tokens t) => Container(
    margin: const EdgeInsets.fromLTRB(14, 8, 14, 10),
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    decoration: BoxDecoration(
      color: t.sheet,
      borderRadius: BorderRadius.circular(16),
      boxShadow: t.shadow,
      border: Border.all(color: t.border),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Forgot a line? ',
                  style: TextStyles.ui(t, size: 14, weight: FontWeight.w700),
                ),
                TextSpan(
                  text: 'Tap Line! below to hear it, and tap again to stop. You can also tap your line in the script.',
                  style: TextStyles.ui(t, size: 14, color: t.ink2),
                ),
              ],
            ),
          ),
        ),
        TextButton(onPressed: _dismissLineHint, child: const Text('Got it')),
      ],
    ),
  );

  /// What can be done with the selected line(s): bookmark, note (edit / delete), loop.
  List<Widget> _selectionActions(Tokens t, {bool compact = false}) {
    final n = ((_selA! - _selB!).abs()) + 1;
    final scene = _sceneNumbered(_selScene);
    final single = n == 1 && scene != null ? scene.lines[_selA!] : null;
    return [
      if (single != null && bookmarks != null)
        IconButton(
          key: const Key('bookmarkLine'),
          tooltip: bookmarks!.has(single.key) ? 'Remove bookmark' : 'Bookmark',
          icon: Icon(bookmarks!.has(single.key) ? Icons.bookmark_rounded : Icons.bookmark_border_rounded),
          onPressed: () {
            bookmarks!.toggle(single.key, scene!.number, single.text);
            setState(_clearSelection);
          },
        ),
      if (single != null && notes != null && compact)
        IconButton(
          key: const Key('noteLine'),
          tooltip: notes!.has(single.key) ? 'Edit Note' : 'Note',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () {
            setState(_clearSelection);
            _editNote(single);
          },
        )
      else if (single != null && notes != null)
        TextButton.icon(
          onPressed: () {
            setState(_clearSelection);
            _editNote(single);
          },
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: Text(notes!.has(single.key) ? 'Edit Note' : 'Note'),
        ),
      if (single != null && notes != null && notes!.has(single.key))
        IconButton(
          key: const Key('deleteNote'),
          tooltip: 'Delete Note',
          icon: Icon(Icons.delete_outline_rounded, color: t.ink2),
          onPressed: () {
            notes!.remove(single.key);
            setState(_clearSelection);
          },
        ),
      if (scene?.rendered ?? false)
        FilledButton.icon(
          onPressed: _loopSelection,
          icon: const Icon(Icons.repeat_rounded, size: 18),
          label: const Text('Loop'),
          style: FilledButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.onAccent),
        ),
    ];
  }

  /// The phone: a bar at the bottom.
  Widget _selectionBar(Tokens t) {
    final n = ((_selA! - _selB!).abs()) + 1;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: t.sheet,
        borderRadius: BorderRadius.circular(16),
        boxShadow: t.shadow,
        border: t.dark ? Border.all(color: t.border) : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text('$n line${n == 1 ? '' : 's'} selected', style: TextStyles.ui(t, size: 15, weight: FontWeight.w600)),
          ),
          TextButton(onPressed: () => setState(_clearSelection), child: const Text('Cancel')),
          ..._selectionActions(t),
        ],
      ),
    );
  }

  /// The iPad: the same actions in a card floating on the selected line(s).
  Widget _floatingSelectionMenu(Tokens t) {
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final scene = _sceneNumbered(_selScene);
    if (stack == null || !stack.hasSize || scene == null) return const SizedBox.shrink();
    final a = _selA! < _selB! ? _selA! : _selB!, b = _selA! < _selB! ? _selB! : _selA!;
    Rect? anchor;
    for (var i = a; i <= b; i++) {
      final box = _keys['${scene.number}:$i']?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final r = box.localToGlobal(Offset.zero, ancestor: stack) & box.size;
      anchor = anchor?.expandToInclude(r) ?? r;
    }
    if (anchor == null || anchor.bottom < _headingHeight || anchor.top > stack.size.height) return const SizedBox.shrink();
    final n = b - a + 1;
    final compact = !isPadDisplay(context); // the phone's card is narrow: icons only
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _MenuLayout(anchor, top: _headingHeight),
        child: Material(
          key: const Key('floatingMenu'),
          color: t.sheet,
          elevation: 10,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact || n > 1) ...[
                  Text(
                    '$n line${n == 1 ? '' : 's'}',
                    style: TextStyles.ui(t, size: 14, weight: FontWeight.w600, color: t.muted),
                  ),
                  const SizedBox(width: 6),
                ] else
                  const SizedBox(width: 10),
                ..._selectionActions(t, compact: compact),
                IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close_rounded, size: 20), onPressed: () => setState(_clearSelection)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(Tokens t) {
    final c = _barColors(t);
    final bottom = MediaQuery.of(context).padding.bottom;
    final clock = TextStyles.ui(t, size: 12, color: c.ink.withValues(alpha: 0.7)).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    Widget round(IconData icon, String label, VoidCallback? onTap, {double size = 48, Color? bg, Color? fg, double iconSize = 24}) => Semantics(
      button: true,
      label: label,
      child: Material(
        color: bg ?? c.btn,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: fg ?? c.ink, size: iconSize),
          ),
        ),
      ),
    );
    Widget pill(String label, VoidCallback onTap, {bool strong = false}) => Material(
      color: strong ? c.btnOn : c.btn,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyles.ui(t, size: 14, weight: FontWeight.w600, color: c.ink),
          ),
        ),
      ),
    );
    final waiting = player.waitingAtCue != null;
    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: c.edge)),
      ),
      padding: EdgeInsets.fromLTRB(18, 10, 18, 12 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (player.flash != null)
            Text(player.flash!, style: TextStyles.hand(t, size: 20, color: t.dark ? t.highlighter : t.accent))
          else if (waiting)
            Text('Your line', style: TextStyles.hand(t, size: 20, color: t.dark ? t.highlighter : t.accent)),
          ValueListenableBuilder<_Head?>(
            valueListenable: _head,
            builder: (context, head, _) {
              final shown = _shown();
              final item = shown.item;
              final isCurrent = item != null && identical(item, player.currentScene);
              final duration = item == null ? 0.0 : (isCurrent ? player.duration : item.totalDuration);
              final time = item == null ? 0.0 : (head?.time ?? player.currentTime);
              final loop = isCurrent && player.loopMode == LoopMode.lines && player.loopEnd > player.loopStart ? (player.loopStart, player.loopEnd) : null;
              return Row(
                children: [
                  Text(_clockText(time), style: clock),
                  const SizedBox(width: 10),
                  Expanded(
                    // Room for the knob at either end. A new scene's timeline fades in over the old one.
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
                        child: PhoneTimeline(
                          key: ValueKey(shown.number),
                          cues: item?.cues ?? const [],
                          duration: duration,
                          time: time,
                          allSpeakers: session.characters,
                          isMine: player.isMyLine,
                          loop: loop,
                          onScrubStart: _scrubStart,
                          onScrub: _scrubTo,
                          onScrubEnd: _scrubEnd,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(_clockText(duration), style: clock),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // The side buttons share what the transport leaves.
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: _lineButton ? _lineButtonWidget(t) : _bookmarksButton(t, c)),
              ),
              const SizedBox(width: 8),
              round(Icons.fast_rewind_rounded, 'Previous line', () async {
                await _commitHead();
                player.prevLine();
              }, size: 44),
              const SizedBox(width: 8),
              round(
                player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                player.isPlaying ? 'Pause' : (waiting ? 'Carry on' : 'Play'),
                () async {
                  _userScrolled = DateTime.fromMillisecondsSinceEpoch(0);
                  // Plays from where the script is scrolled to (the playhead you see).
                  await _commitHead();
                  player.togglePlayPause();
                  WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
                },
                size: 60,
                bg: t.accent,
                fg: t.onAccent,
                iconSize: 32,
              ),
              const SizedBox(width: 8),
              round(Icons.fast_forward_rounded, 'Next line', () async {
                await _commitHead();
                player.nextLine();
              }, size: 44),
              const SizedBox(width: 8),
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: pill('Rehearse', _openPanel, strong: true)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Bottom left: the bookmarks (My Role is already in the header and in Rehearse).
  Widget _bookmarksButton(Tokens t, ({Color bg, Color edge, Color ink, Color btn, Color btnOn}) c) {
    final n = bookmarks?.count ?? 0;
    return Semantics(
      button: true,
      label: 'Bookmarks',
      child: Material(
        color: c.btn,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          key: const Key('bookmarksButton'),
          borderRadius: BorderRadius.circular(22),
          onTap: _openBookmarks,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(n > 0 ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, size: 22, color: c.ink),
                if (n > 0) ...[
                  const SizedBox(width: 6),
                  Text(
                    '$n',
                    style: TextStyles.ui(t, size: 14, weight: FontWeight.w600, color: c.ink),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _lineButtonWidget(Tokens t) {
    const ink = Color(0xFF1C1B19);
    final on = player.revealedCue != null;
    return Semantics(
      button: true,
      label: on ? 'Stop your line' : 'Line! Hear your line',
      child: Material(
        color: on ? ink : t.highlighter,
        shape: const StadiumBorder(side: BorderSide(color: ink, width: 2)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: _callLine,
          child: Container(
            key: const Key('lineButton'),
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            child: Text('Line!', style: TextStyles.hand(t, size: 22, color: on ? t.highlighter : ink)),
          ),
        ),
      ),
    );
  }

  // Sheets ---------------------------------------------------------------------

  int? get _topScene => player.currentScene?.sceneNumber ?? session.scenes.firstOrNull?.number;

  Future<void> _openPanel() async {
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.sheet,
      showDragHandle: true,
      constraints: sheetConstraints(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => ListenableBuilder(
        listenable: player,
        builder: (ctx, _) => _RehearsePanel(
          player: player,
          session: session,
          viewing: _viewScene.value ?? _topScene,
          onPickScene: () {
            Navigator.pop(ctx);
            Future.delayed(const Duration(milliseconds: 250), () {
              if (mounted) _openScenesFromBar();
            });
          },
        ),
      ),
    );
  }

  /// The scene list, dropping down from the bar at the top (from the bar's tap or from the Rehearse panel).
  void _openScenesFromBar() {
    final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _openScenes(box.localToGlobal(Offset.zero) & box.size);
  }

  Future<void> _openScenes(Rect heading) async {
    final t = Tokens.of(context);
    final list = ScrollController();
    final picked = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close scenes',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, _, _) {
        final media = MediaQuery.of(ctx);
        final room = media.size.height - heading.bottom - media.padding.bottom - 24;
        return Stack(
          children: [
            // Dims the script below the heading; a tap anywhere closes.
            Positioned.fill(
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => Navigator.pop(ctx)),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: heading.bottom,
              bottom: 0,
              child: IgnorePointer(
                child: ColoredBox(color: Colors.black.withValues(alpha: t.dark ? 0.45 : 0.22)),
              ),
            ),
            Positioned(
              key: const Key('sceneDropdown'),
              left: heading.left + 8,
              right: media.size.width - heading.right + 8,
              top: heading.bottom,
              child: Material(
                color: t.sheet,
                elevation: 8,
                shadowColor: Colors.black45,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: room.clamp(160.0, media.size.height * 0.62)),
                  child: _SceneList(
                    session: session,
                    viewing: _viewScene.value ?? _topScene,
                    controller: list,
                    store: widget.store,
                    onScene: (n) => Navigator.pop(ctx, n),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      // Unfolds downward from the heading.
      transitionBuilder: (ctx, anim, _, child) {
        final a = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: a,
          child: AnimatedBuilder(
            animation: a,
            builder: (ctx, c) => ClipRect(
              clipper: _RevealDown(top: heading.bottom, progress: a.value),
              child: c,
            ),
            child: child,
          ),
        );
      },
    );
    list.dispose();
    if (picked != null) _jumpToScene(picked);
  }

  Future<void> _openTextOptions() async {
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.sheet,
      showDragHandle: true,
      constraints: sheetConstraints(context),
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
                  segments: [for (var i = 0; i < 4; i++) ButtonSegment(value: i, label: Text(_textSizeLabels[i]))],
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
                if (_pdfPath.isNotEmpty)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Page numbers'),
                    subtitle: const Text('A dotted line and the PDF page at each page break'),
                    value: _showPages,
                    onChanged: (v) {
                      set(() {});
                      _setShowPages(v).then((_) => set(() {}));
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
  const _RehearsePanel({required this.player, required this.session, required this.viewing, required this.onPickScene});
  final RehearsalPlayer player;
  final RehearsalSession session;
  final int? viewing;

  /// Closes the panel and drops the scene list down from the top heading.
  final VoidCallback onPickScene;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final hasRole = player.myRole.isNotEmpty;
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
                  Expanded(
                    child: Text('Rehearse', style: TextStyles.ui(t, size: 22, weight: FontWeight.w700)),
                  ),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                ],
              ),
              const SizedBox(height: 8),
              Text('MY ROLE', style: TextStyles.label(t)),
              const SizedBox(height: 8),
              _roleChips(t, player, session),
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
                  title: Text(
                    'Scene ${scene.number} · ${scene.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.ui(t, size: 16, weight: FontWeight.w600),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: onPickScene,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SceneList extends StatelessWidget {
  const _SceneList({required this.session, required this.viewing, required this.controller, required this.onScene, this.store});
  final RehearsalSession session;
  final int? viewing;
  final ScrollController controller;
  final ValueChanged<int> onScene;
  final PhoneStore? store;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final missing = session.scenes.where((s) => !s.rendered).length;
    final st = store;
    final header = st == null || missing == 0
        ? null
        : ListenableBuilder(
            listenable: st,
            builder: (context, _) {
              final asked = st.requests[session.project.id];
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: asked == null
                    ? OutlinedButton.icon(
                        onPressed: () => st.requestRender(session.project),
                        icon: const Icon(Icons.graphic_eq_rounded, size: 18),
                        label: Text('Ask Mac to Render $missing Text-Only Scene${missing == 1 ? '' : 's'}'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          foregroundColor: t.accent,
                          side: BorderSide(color: t.accentLine),
                        ),
                      )
                    : Row(
                        children: [
                          Icon(Icons.schedule_rounded, size: 18, color: t.muted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('Waiting for your Mac to render ${asked.summary}.', style: TextStyles.ui(t, size: 14, color: t.ink2)),
                          ),
                          TextButton(onPressed: () => st.cancelRequest(session.project), child: const Text('Cancel')),
                        ],
                      ),
              );
            },
          );
    return ListView.builder(
      controller: controller,
      itemCount: session.scenes.length + (header == null ? 0 : 1),
      itemBuilder: (context, i) {
        if (header != null) {
          if (i == 0) return header;
          i--;
        }
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

/// Clips everything below [top] to the part already unfolded.
class _RevealDown extends CustomClipper<Rect> {
  _RevealDown({required this.top, required this.progress});
  final double top, progress;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, 0, size.width, top + (size.height - top) * progress);

  @override
  bool shouldReclip(_RevealDown old) => old.progress != progress || old.top != top;
}

/// Everyone with a line, to pick as My Character ("No one" clears it).
Widget _roleChips(Tokens t, RehearsalPlayer player, RehearsalSession session) {
  Widget chip(String label, String role) {
    final on = role.isEmpty ? player.myRoles.isEmpty : player.myRoles.contains(role);
    return ChoiceChip(
      label: Text(label),
      selected: on,
      showCheckmark: false,
      onSelected: (_) => role.isEmpty ? player.setRole('') : player.toggleRole(role),
      labelStyle: TextStyles.ui(t, size: 15, weight: on ? FontWeight.w700 : FontWeight.w500, color: on ? const Color(0xFF1C1B19) : t.ink2),
      selectedColor: t.highlighter,
      backgroundColor: t.panel,
      side: on ? const BorderSide(color: Color(0xFF1C1B19), width: 2) : BorderSide.none,
      shape: const StadiumBorder(),
    );
  }

  return Wrap(spacing: 8, runSpacing: 8, children: [chip('No one', ''), for (final c in session.characters) chip(titleCaseName(c), c)]);
}

/// My Character (#114): choose who you play and see their lines highlighted in every scene, rendered or not.
class _RoleSheet extends StatelessWidget {
  const _RoleSheet({required this.player, required this.session});
  final RehearsalPlayer player;
  final RehearsalSession session;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final hasRole = player.myRole.isNotEmpty;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('My Character', style: TextStyles.ui(t, size: 22, weight: FontWeight.w700)),
                  ),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                ],
              ),
              Text(
                'Pick one or more. Their lines are highlighted all through the script. No audio needed.',
                style: TextStyles.ui(t, size: 14, color: t.muted),
              ),
              const SizedBox(height: 14),
              _roleChips(t, player, session),
              const SizedBox(height: 16),
              Material(
                color: t.panel,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: SwitchListTile(
                  title: Text('Block My Lines', style: TextStyles.ui(t, size: 16, weight: FontWeight.w600)),
                  subtitle: Text('Blank them out to test memory', style: TextStyles.ui(t, size: 13, color: t.muted)),
                  value: player.blockMyLines && hasRole,
                  onChanged: hasRole ? player.setBlock : null,
                ),
              ),
              if (!hasRole)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text('Pick your character to use this.', style: TextStyles.ui(t, size: 13, color: t.muted)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Write, change or delete a line's note. Pops the new text, or '' to delete.
class _NoteSheet extends StatefulWidget {
  const _NoteSheet({required this.line, this.existing});
  final PhoneLine line;
  final String? existing;

  @override
  State<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<_NoteSheet> {
  late final ctl = TextEditingController(text: widget.existing ?? '');

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Note', style: TextStyles.ui(t, size: 22, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            widget.line.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyles.script(t, size: 14, italic: true, color: t.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('noteField'),
            controller: ctl,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'A reminder for this line', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (widget.existing != null)
                TextButton(
                  onPressed: () => Navigator.pop(context, ''),
                  style: TextButton.styleFrom(foregroundColor: t.danger),
                  child: const Text('Delete'),
                ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, ctl.text),
                style: FilledButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.onAccent),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A line's note, collapsed: a little arrow flag. Tap to open the note; open, it points down.
class _NoteFlag extends StatelessWidget {
  const _NoteFlag({required this.open, required this.onTap});
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Semantics(
      button: true,
      label: open ? 'Hide note' : 'Show note',
      child: GestureDetector(
        key: const Key('noteFlag'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: AnimatedRotation(
            turns: open ? -0.25 : 0, // points at the line; open, down at the note
            duration: const Duration(milliseconds: 150),
            child: CustomPaint(
              size: const Size(20, 16),
              painter: _FlagPainter(fill: t.highlighter, edge: t.dark ? const Color(0xFF1C1B19) : t.highlighterEdge),
            ),
          ),
        ),
      ),
    );
  }
}

class _FlagPainter extends CustomPainter {
  _FlagPainter({required this.fill, required this.edge});
  final Color fill, edge;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w - 1, 1)
      ..lineTo(6, 1)
      ..lineTo(1, h / 2)
      ..lineTo(6, h - 1)
      ..lineTo(w - 1, h - 1)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_FlagPainter old) => old.fill != fill || old.edge != edge;
}

/// An open note, under its line.
class _NoteCard extends StatelessWidget {
  const _NoteCard({super.key, required this.text, required this.onEdit, required this.onCollapse});
  final String text;
  final VoidCallback onEdit, onCollapse;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Container(
      key: const Key('noteCard'),
      margin: const EdgeInsets.fromLTRB(18, 0, 4, 6),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: t.highlighter.withValues(alpha: t.dark ? 0.16 : 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: t.highlighterEdge, width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(text, style: TextStyles.hand(t, size: 18, color: t.ink)),
            ),
          ),
          IconButton(
            tooltip: 'Edit note',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.edit_outlined, size: 18, color: t.ink2),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Hide note',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.keyboard_arrow_up_rounded, color: t.ink2),
            onPressed: onCollapse,
          ),
        ],
      ),
    );
  }
}

/// Where a PDF page starts (#116): a dotted line across the script and the page's number.
class _PageBreakMark extends StatelessWidget {
  const _PageBreakMark({required this.page, required this.onTap});
  final int page;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Semantics(
      label: 'Page $page begins',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
        child: Row(
          children: [
            Expanded(
              child: CustomPaint(size: const Size(double.infinity, 1), painter: _DottedLine(t.muted.withValues(alpha: 0.7))),
            ),
            GestureDetector(
              key: Key('pageBreak$page'),
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 2, 4),
                child: Text(
                  'p. $page',
                  style: TextStyles.ui(t, size: 12, weight: FontWeight.w600, color: t.muted),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DottedLine extends CustomPainter {
  _DottedLine(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, 0), Offset(x + 0.1, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_DottedLine old) => old.color != color;
}

/// The PDF on its own screen (iPhone, and iPad windows too narrow to split).
class _PdfScreen extends StatefulWidget {
  const _PdfScreen({required this.path, required this.folder, required this.page, required this.folderAccess});
  final String path, folder;
  final int page;
  final bool folderAccess;

  @override
  State<_PdfScreen> createState() => _PdfScreenState();
}

class _PdfScreenState extends State<_PdfScreen> {
  late final PdfController controller = PdfController()..onReady = () => controller.goToPage(widget.page);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        child: PdfPanel(
          pdfPath: widget.path,
          folder: widget.folder,
          controller: controller,
          pad: isPadDisplay(context),
          folderAccess: widget.folderAccess,
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

/// Puts the floating selection menu above the selected line(s), or below when there is no room above, kept on screen.
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.anchor, {required this.top});
  final Rect anchor;
  final double top;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => BoxConstraints(maxWidth: c.maxWidth - 16);

  @override
  Offset getPositionForChild(Size size, Size child) {
    final above = anchor.top - child.height - 8;
    final y = above >= top ? above : (anchor.bottom + 8).clamp(top, size.height - child.height - 8);
    final x = (anchor.center.dx - child.width / 2).clamp(8.0, size.width - child.width - 8);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.anchor != anchor || old.top != top;
}

/// Where the playhead is while the script is being browsed: a time in a scene (not the player's own, until it is committed).
class _Head {
  const _Head(this.scene, this.time, {this.cue, required this.rendered});
  final int scene;
  final double time;

  /// The line (index in the scene's cues) the time falls in.
  final int? cue;

  /// False for a scene with no audio: the timeline is then bare.
  final bool rendered;
}
