// Bookmarks: places in the script to come back to. A bookmark belongs to one line
// (the notes' line identity, so it survives a re-parse).
//
// Same sync rules as the notes: each device writes only its own file
// (Bookmarks/<device>.json), reading merges every device's file bookmark by
// bookmark, newest edit wins, and a removed bookmark stays as a tombstone so the
// removal beats an older copy on another device.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart' show clockNow;
import '../services/project_files.dart';
import 'folder_access.dart';

const bookmarksFolder = 'Bookmarks';

class Bookmark {
  Bookmark({required this.scene, required this.text, DateTime? updatedAt, this.deleted = false}) : updatedAt = updatedAt ?? clockNow().toUtc();

  /// The scene's number, and the start of the line's text (to show in the list).
  final int scene;
  final String text;
  final DateTime updatedAt;
  final bool deleted;

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
    scene: (j['scene'] as num?)?.toInt() ?? 0,
    text: j['text'] as String? ?? '',
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    deleted: j['deleted'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {'scene': scene, 'text': text, 'updatedAt': updatedAt.toIso8601String(), if (deleted) 'deleted': true};
}

class Bookmarks extends ChangeNotifier {
  Bookmarks({required this.folder, required this.deviceId, this.folderAccess = true});

  final String folder;
  final String deviceId;

  /// Off in tests: files are written with dart:io instead of the native plugin.
  final bool folderAccess;

  final Map<String, Bookmark> _all = {};
  final Map<String, Bookmark> _mine = {};

  String get _path => '$folder/$bookmarksFolder/$deviceId.json';

  /// Line key → bookmark, for the live ones.
  Map<String, Bookmark> get live => {
    for (final e in _all.entries)
      if (!e.value.deleted) e.key: e.value,
  };

  bool has(String key) => _all[key] != null && !_all[key]!.deleted;
  int get count => live.length;

  void load() {
    _all.clear();
    _mine.clear();
    final dir = Directory('$folder/$bookmarksFolder');
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final device = f.path.split('/').last.replaceFirst(RegExp(r'\.json$'), '');
      try {
        final j = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
        for (final e in Map<String, dynamic>.from(j['bookmarks'] as Map? ?? const {}).entries) {
          final b = Bookmark.fromJson(Map<String, dynamic>.from(e.value as Map));
          if (device == deviceId) _mine[e.key] = b;
          final old = _all[e.key];
          if (old == null || b.updatedAt.isAfter(old.updatedAt)) _all[e.key] = b;
        }
      } catch (e) {
        debugPrint('Skipping bookmarks file ${f.path}: $e');
      }
    }
    notifyListeners();
  }

  Future<void> add(String key, int scene, String text) async {
    if (has(key)) return;
    _put(key, Bookmark(scene: scene, text: text.length > 80 ? text.substring(0, 80) : text));
    await _save();
  }

  Future<void> remove(String key) async {
    final b = _all[key];
    if (b == null || b.deleted) return;
    _put(key, Bookmark(scene: b.scene, text: b.text, deleted: true));
    await _save();
  }

  Future<void> toggle(String key, int scene, String text) => has(key) ? remove(key) : add(key, scene, text);

  void _put(String key, Bookmark b) {
    _mine[key] = b;
    _all[key] = b;
    notifyListeners();
  }

  Future<void> _save() async {
    final text = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'device': deviceId,
      'bookmarks': {for (final e in _mine.entries) e.key: e.value.toJson()},
    });
    try {
      if (folderAccess) {
        await FolderAccess.write(_path, text);
      } else {
        writeFileAtomic(_path, text);
      }
    } catch (e) {
      debugPrint('Could not save bookmarks: $e');
    }
  }
}
