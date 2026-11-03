// Show PDF (#115): the screenplay as a native PDFKit view (ios/Runner/PdfPlugin.swift),
// with search, page / continuous reading (#120) and Apple Pencil markup on iPad (#119).
// Markup is saved in the project, never in the PDF: Markup/<device>.json, one
// PencilKit drawing per page; each device writes only its own file and reading
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

  // page index → (base64 PencilKit data, edited at). Empty data = erased.
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

/// What the pen and the highlighter offer: a few colors and three thicknesses each.
const penColors = [Color(0xFF1C1B19), Color(0xFF1F5FD9), Color(0xFFD92F2F), Color(0xFF2E8B57)];
const penWidths = [1.5, 3.0, 6.0];
const markerColors = [Color(0xFFFFE23D), Color(0xFF7ED957), Color(0xFFFF8FC8), Color(0xFF6EC1FF)];
const markerWidths = [10.0, 15.0, 24.0];

/// Talks to one native PDF view.
class PdfController extends ChangeNotifier {
  MethodChannel? _ch;

  int page = 1;
  int pageCount = 0;
  bool continuous = true;
  bool markup = false;
  bool finger = false;

  /// The pen in hand, and the color and thickness (index) each ink remembers.
  InkTool tool = InkTool.pen;
  int penColor = 0, penWidth = 1, markerColor = 0, markerWidth = 1;

  /// Apple's own tool palette instead of ours.
  bool systemPalette = false;

  /// Whether the page last drawn on has something to undo / redo.
  bool canUndo = false;
  bool canRedo = false;

  /// Search: how many matches, and which one is showing (1-based; 0 = none).
  int searchCount = 0;
  int searchIndex = 0;

  /// The user drew on [page] (0-based): [data] is the page's PencilKit drawing, base64 ('' = erased).
  void Function(int page, String data)? onMarkup;

  /// Called once the view exists and has taken the saved drawings.
  VoidCallback? onReady;

  /// The saved drawings the view starts with (page index → base64).
  Map<String, String> initialMarkup = const {};

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
        case 'markup':
          onMarkup?.call(a['page'] as int, a['data'] as String);
        case 'history':
          canUndo = a['undo'] as bool;
          canRedo = a['redo'] as bool;
          notifyListeners();
      }
    });
    () async {
      final s = Map<String, dynamic>.from(await ch.invokeMethod('state') as Map);
      page = s['page'] as int;
      pageCount = s['count'] as int;
      if (initialMarkup.isNotEmpty) await ch.invokeMethod('loadMarkup', {'pages': initialMarkup});
      if (!continuous) await ch.invokeMethod('setMode', {'continuous': false});
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
    page = n;
    notifyListeners();
    await _ch?.invokeMethod('goToPage', {'page': n});
  }

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

  Future<void> undo() async => _ch?.invokeMethod('undo');
  Future<void> redo() async => _ch?.invokeMethod('redo');
  Future<void> clearPage() async => _ch?.invokeMethod('clearPage');

  Future<void> setMarkup({bool? enabled, bool? finger}) async {
    markup = enabled ?? markup;
    this.finger = finger ?? this.finger;
    notifyListeners();
    await _sendTool();
    await _ch?.invokeMethod('setMarkup', {'enabled': markup, 'finger': this.finger});
  }

  Future<void> _sendTool() async {
    final pen = tool == InkTool.pen;
    await _ch?.invokeMethod('setTool', {
      'tool': tool.name,
      'color': (pen ? penColors[penColor] : markerColors[markerColor]).toARGB32(),
      'width': pen ? penWidths[penWidth] : markerWidths[markerWidth],
    });
  }

  /// Picks the ink, and/or its color and thickness (indexes into the lists above).
  Future<void> setTool({InkTool? tool, int? color, int? width}) async {
    this.tool = tool ?? this.tool;
    if (this.tool == InkTool.pen) {
      penColor = color ?? penColor;
      penWidth = width ?? penWidth;
    } else if (this.tool == InkTool.marker) {
      markerColor = color ?? markerColor;
      markerWidth = width ?? markerWidth;
    }
    systemPalette = false;
    notifyListeners();
    await _ch?.invokeMethod('systemPalette', {'on': false});
    await _sendTool();
  }

  /// Apple's tool palette (pens, pencil, ruler, lasso...) in place of our strip.
  Future<void> setSystemPalette(bool on) async {
    systemPalette = on;
    notifyListeners();
    await _ch?.invokeMethod('systemPalette', {'on': on});
    if (!on) await _sendTool();
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
    return UiKitView(
      viewType: 'tableread/pdfview',
      creationParams: {'path': path, 'dark': t.dark},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: controller.attach,
      // The PDF scrolls, pinches and (on iPad) draws: it takes every touch that starts on it.
      gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
    );
  }
}
