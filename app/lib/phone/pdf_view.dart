// Show PDF (#115): the screenplay as a native PDFKit view (ios/Runner/PdfPlugin.swift),
// with search, page / continuous reading (#120) and Apple Pencil markup on iPad (#119).
// Marking up opens Apple's own PencilKit markup (a native full-screen viewer with the
// system tool palette, ios/Runner/PdfPlugin.swift). It is saved in the project, never in
// the PDF: Markup/<device>.json, one PencilKit drawing per page; each device writes only
// its own file and reading merges them page by page (newest wins), like the notes.

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

  /// Opens the native markup viewer on [page] (0-based), [fraction] of the way down it, and returns where it was left when it is closed. [drawings] is page index → saved
  /// drawing; every drawing that settles while it is open is passed to [onSave] (page index, data; '' = nothing left).
  static Future<({int page, double fraction})?> markUp({
    required String path,
    required int page,
    double fraction = 0,
    required Map<String, String> drawings,
    required bool dark,
    required void Function(int page, String data) onSave,
  }) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'markup') {
        final a = Map<String, dynamic>.from(call.arguments as Map);
        onSave(a['page'] as int, a['data'] as String);
      }
    });
    try {
      final r = await _channel.invokeMethod<Map>('presentMarkup', {
        'path': path,
        'page': page,
        'fraction': fraction,
        'pages': drawings,
        'dark': dark,
      });
      return r == null ? null : (page: r['page'] as int, fraction: (r['fraction'] as num).toDouble());
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

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

/// Talks to one native PDF view.
class PdfController extends ChangeNotifier {
  MethodChannel? _ch;

  int page = 1;
  int pageCount = 0;
  bool continuous = true;

  /// Search: how many matches, and which one is showing (1-based; 0 = none).
  int searchCount = 0;
  int searchIndex = 0;

  /// The saved markup (page index → PencilKit drawing); the view shows it. Kept current by the panel.
  Map<String, String> _drawings = {};
  Map<String, String> get drawings => _drawings;
  set drawings(Map<String, String> m) {
    _drawings = m;
    _ch?.invokeMethod('loadMarkup', {'pages': m});
  }

  /// Called once the view exists.
  VoidCallback? onReady;

  void attach(int viewId) {
    final ch = MethodChannel('tableread/pdfview_$viewId');
    _ch = ch;
    ch.setMethodCallHandler((call) async {
      if (call.method == 'page') {
        final a = Map<String, dynamic>.from(call.arguments as Map);
        page = a['page'] as int;
        pageCount = a['count'] as int;
        notifyListeners();
      }
    });
    () async {
      final s = Map<String, dynamic>.from(await ch.invokeMethod('state') as Map);
      page = s['page'] as int;
      pageCount = s['count'] as int;
      if (!continuous) await ch.invokeMethod('setMode', {'continuous': false});
      if (_drawings.isNotEmpty) await ch.invokeMethod('loadMarkup', {'pages': _drawings});
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

  /// The page at the top of the view (0-based) and how far down it the top edge is (0...1).
  Future<({int page, double fraction})> position() async {
    final r = await _ch?.invokeMethod<Map>('position');
    return r == null ? (page: page - 1, fraction: 0.0) : (page: r['page'] as int, fraction: (r['fraction'] as num).toDouble());
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
    return _view(t.dark);
  }

  Widget _view(bool dark) {
    return UiKitView(
      viewType: 'tableread/pdfview',
      creationParams: {'path': path, 'dark': dark},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: controller.attach,
      // The PDF scrolls and pinches: it takes every touch that starts on it.
      gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
    );
  }
}
