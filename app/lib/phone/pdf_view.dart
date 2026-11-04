// Show PDF (#115): the screenplay as a native PDFKit view (ios/Runner/PdfPlugin.swift),
// with search, page / continuous reading (#120) and Apple Pencil markup on iPad (#119).
// Markup is saved in the project, never in the PDF: Markup/<device>.json, one
// ink drawing per page; each device writes only its own file and reading
// merges them page by page (newest wins), like the notes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart' show clockNow;
import '../services/project_files.dart';
import '../theme/tokens.dart';
import 'folder_access.dart';
import 'ink_layer.dart';

const markupFolder = 'Markup';

class PdfService {
  static const _channel = MethodChannel('tableread/pdf');

  /// The text of every page, in order (to line the script up with its pages).
  static Future<List<String>> pageTexts(String path) async =>
      (await _channel.invokeMethod<List>('pageTexts', {'path': path}) ?? const []).cast<String>();

  /// The native PDF view exists on iPhone and iPad only.
  static bool get available => !kIsWeb && Platform.isIOS;
}

/// One device's drawings of a project's pages, merged with the other devices'.
class PdfMarkup {
  PdfMarkup({required this.folder, required this.deviceId, this.folderAccess = true});
  final String folder;
  final String deviceId;
  final bool folderAccess;

  // page index → (the page's ink as JSON, edited at). Empty data = erased.
  final Map<int, (String, DateTime)> _all = {};
  final Map<int, (String, DateTime)> _mine = {};

  String get _path => '$folder/$markupFolder/$deviceId.json';

  /// Page index (0-based) → drawing, for the pages that have one.
  Map<String, String> get drawings => {
    for (final e in _all.entries)
      if (e.value.$1.isNotEmpty) '${e.key}': e.value.$1,
  };

  void load() {
    _all.clear();
    _mine.clear();
    final dir = Directory('$folder/$markupFolder');
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final device = f.path.split('/').last.replaceFirst(RegExp(r'\.json$'), '');
      try {
        final j = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
        for (final e in Map<String, dynamic>.from(j['pages'] as Map? ?? const {}).entries) {
          final i = int.tryParse(e.key);
          if (i == null) continue;
          final p = Map<String, dynamic>.from(e.value as Map);
          final at = DateTime.tryParse(p['updatedAt'] as String? ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
          final v = (p['data'] as String? ?? '', at);
          if (device == deviceId) _mine[i] = v;
          final old = _all[i];
          if (old == null || at.isAfter(old.$2)) _all[i] = v;
        }
      } catch (e) {
        debugPrint('Skipping markup file ${f.path}: $e');
      }
    }
  }

  Future<void> set(int page, String data) async {
    final v = (data, clockNow().toUtc());
    _mine[page] = v;
    _all[page] = v;
    final text = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'device': deviceId,
      'pages': {
        for (final e in _mine.entries) '${e.key}': {'data': e.value.$1, 'updatedAt': e.value.$2.toIso8601String()},
      },
    });
    try {
      if (folderAccess) {
        await FolderAccess.write(_path, text);
      } else {
        writeFileAtomic(_path, text);
      }
    } catch (e) {
      debugPrint('Could not save markup: $e');
    }
  }
}

enum InkTool { pen, marker, eraser }

/// What the pen and the highlighter offer: a few colors and three thicknesses each (widths in points on the page).
const penColors = [Color(0xFF1C1B19), Color(0xFF1F5FD9), Color(0xFFD92F2F), Color(0xFF2E8B57)];
const penWidths = [1.5, 3.0, 6.0];
const markerColors = [Color(0xFFFFE23D), Color(0xFF7ED957), Color(0xFFFF8FC8), Color(0xFF6EC1FF)];
const markerWidths = [10.0, 15.0, 24.0];

class _InkEdit {
  _InkEdit(this.page, this.before, this.after);
  final int page;
  final List<InkStroke> before, after;
}

/// Talks to one native PDF view, and keeps the ink drawn over it.
class PdfController extends ChangeNotifier {
  MethodChannel? _ch;

  int page = 1;
  int pageCount = 0;
  bool continuous = true;
  bool markup = false;
  bool finger = false;

  /// Where the current page is in the view, and its size on paper (points); from the native view.
  Rect? pageRect;
  double pageWidth = 612;

  /// The pen in hand, and the color and thickness (index) each ink remembers.
  InkTool tool = InkTool.pen;
  int penColor = 0, penWidth = 1, markerColor = 0, markerWidth = 1;

  Color get currentColor => tool == InkTool.pen ? penColors[penColor] : markerColors[markerColor];
  double get currentWidth => tool == InkTool.pen ? penWidths[penWidth] : markerWidths[markerWidth];

  /// Search: how many matches, and which one is showing (1-based; 0 = none).
  int searchCount = 0;
  int searchIndex = 0;

  /// The ink: page index (0-based) → strokes.
  final Map<int, List<InkStroke>> ink = {};
  InkStroke? liveStroke;
  int inkRevision = 0;
  final List<_InkEdit> _undo = [], _redo = [];
  List<InkStroke>? _editBefore;

  List<InkStroke> get strokesOnPage => ink[page - 1] ?? const [];
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The user changed [page] (0-based): [data] is its ink as JSON ('' = none left). The panel saves it.
  void Function(int page, String data)? onMarkup;

  /// Called once the view exists.
  VoidCallback? onReady;

  /// The saved ink the view starts with (page index → JSON).
  Map<String, String> get initialMarkup => const {};
  set initialMarkup(Map<String, String> m) {
    ink.clear();
    for (final e in m.entries) {
      final i = int.tryParse(e.key);
      if (i != null) ink[i] = decodeInk(e.value);
    }
  }

  void attach(int viewId) {
    final ch = MethodChannel('tableread/pdfview_$viewId');
    _ch = ch;
    ch.setMethodCallHandler((call) async {
      final a = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'page':
          page = a['page'] as int;
          pageCount = a['count'] as int;
          notifyListeners();
        case 'geometry':
          pageRect = Rect.fromLTWH((a['x'] as num).toDouble(), (a['y'] as num).toDouble(), (a['w'] as num).toDouble(), (a['h'] as num).toDouble());
          pageWidth = (a['pageW'] as num).toDouble();
          notifyListeners();
      }
    });
    () async {
      final s = Map<String, dynamic>.from(await ch.invokeMethod('state') as Map);
      page = s['page'] as int;
      pageCount = s['count'] as int;
      if (!continuous) await ch.invokeMethod('setMode', {'continuous': false});
      if (markup) await ch.invokeMethod('lockFit', {'on': true});
      notifyListeners();
      onReady?.call();
    }();
  }

  @override
  void dispose() {
    _ch?.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> goToPage(int n) async {
    if (pageCount > 0) n = n.clamp(1, pageCount);
    page = n;
    notifyListeners();
    await _ch?.invokeMethod('goToPage', {'page': n});
  }

  Future<void> nextPage() => goToPage(page + 1);
  Future<void> prevPage() => goToPage(page - 1);

  Future<void> setContinuous(bool on) async {
    continuous = on;
    notifyListeners();
    await _ch?.invokeMethod('setMode', {'continuous': on});
  }

  /// Highlights every match; [reveal] also scrolls to the first (off when the script's own search is steering).
  Future<void> search(String query, {bool reveal = true}) async {
    final r = Map<String, dynamic>.from(
      await _ch?.invokeMethod('search', {'query': query, 'reveal': reveal}) as Map? ?? const {'count': 0, 'index': 0},
    );
    searchCount = r['count'] as int;
    searchIndex = r['index'] as int;
    notifyListeners();
  }

  Future<void> searchStep(bool forward) async {
    final r = Map<String, dynamic>.from(await _ch?.invokeMethod('searchStep', {'forward': forward}) as Map? ?? const {'count': 0, 'index': 0});
    searchCount = r['count'] as int;
    searchIndex = r['index'] as int;
    notifyListeners();
  }

  Future<void> clearSearch() async {
    searchCount = searchIndex = 0;
    notifyListeners();
    await _ch?.invokeMethod('clearSearch');
  }

  // Marking up ------------------------------------------------------------------

  /// Marking up shows one page at a time, fitted to the screen, so the ink has a fixed place to be drawn on.
  Future<void> setMarkup({bool? enabled, bool? finger}) async {
    final was = markup;
    markup = enabled ?? markup;
    this.finger = finger ?? this.finger;
    if (markup && !was) continuous = false;
    notifyListeners();
    if (markup && !was) await _ch?.invokeMethod('setMode', {'continuous': false});
    if (markup != was) await _ch?.invokeMethod('lockFit', {'on': markup});
  }

  void setTool({InkTool? tool, int? color, int? width}) {
    this.tool = tool ?? this.tool;
    if (this.tool == InkTool.pen) {
      penColor = color ?? penColor;
      penWidth = width ?? penWidth;
    } else if (this.tool == InkTool.marker) {
      markerColor = color ?? markerColor;
      markerWidth = width ?? markerWidth;
    }
    notifyListeners();
  }

  void notifyInk() {
    inkRevision++;
    notifyListeners();
  }

  void _record(int pageIndex, List<InkStroke> before, List<InkStroke> after) {
    ink[pageIndex] = after;
    _undo.add(_InkEdit(pageIndex, before, after));
    _redo.clear();
    _save(pageIndex);
    notifyInk();
  }

  void _save(int pageIndex) => onMarkup?.call(pageIndex, encodeInk(ink[pageIndex] ?? const []));

  void commitStroke(InkStroke s) {
    final i = page - 1;
    final before = List.of(ink[i] ?? const <InkStroke>[]);
    _record(i, before, [...before, s]);
  }

  /// The eraser removes whole strokes: [beginEdit], [eraseAt] as it moves, [endEdit] when it lifts.
  void beginEdit() => _editBefore = List.of(strokesOnPage);

  void eraseAt(Offset p) {
    final here = ink[page - 1];
    if (here == null) return;
    final slop = 0.012;
    final kept = [
      for (final s in here)
        if (!strokeNear(s, p, slop)) s,
    ];
    if (kept.length != here.length) {
      ink[page - 1] = kept;
      notifyInk();
    }
  }

  void endEdit() {
    final before = _editBefore;
    _editBefore = null;
    if (before == null) return;
    final after = strokesOnPage;
    if (after.length != before.length) {
      _undo.add(_InkEdit(page - 1, before, List.of(after)));
      _redo.clear();
      _save(page - 1);
    }
    notifyInk();
  }

  void clearPage() {
    final before = List.of(strokesOnPage);
    if (before.isEmpty) return;
    _record(page - 1, before, []);
  }

  void undo() {
    if (_undo.isEmpty) return;
    final e = _undo.removeLast();
    _redo.add(e);
    ink[e.page] = List.of(e.before);
    _save(e.page);
    if (e.page + 1 != page) goToPage(e.page + 1);
    notifyInk();
  }

  void redo() {
    if (_redo.isEmpty) return;
    final e = _redo.removeLast();
    _undo.add(e);
    ink[e.page] = List.of(e.after);
    _save(e.page);
    if (e.page + 1 != page) goToPage(e.page + 1);
    notifyInk();
  }
}

/// The native view itself (a placeholder where there is none: tests, the Mac).
class PdfNativeView extends StatelessWidget {
  const PdfNativeView({super.key, required this.path, required this.controller});
  final String path;
  final PdfController controller;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    if (!PdfService.available) {
      return ColoredBox(
        color: t.panel,
        child: Center(
          child: Text('The PDF opens on iPhone and iPad.', style: TextStyles.ui(t, color: t.muted)),
        ),
      );
    }
    // While marking up, Flutter's ink layer takes every touch; the PDF only shows the page.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => IgnorePointer(ignoring: controller.markup, child: _view(t.dark)),
    );
  }

  Widget _view(bool dark) {
    return UiKitView(
      viewType: 'tableread/pdfview',
      creationParams: {'path': path, 'dark': dark},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: controller.attach,
      // The PDF scrolls, pinches and (on iPad) draws: it takes every touch that starts on it.
      gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
    );
  }
}
