// Notes on script lines (#117). A note belongs to one line; collapsed it is a
// small flag by the line, expanded it shows its text under the line.
//
// Like the rehearsal settings, each device writes only its own file
// (Notes/<device>.json), so iCloud never makes conflict copies; reading merges
// every device's file note by note, newest edit wins. A deleted note stays in
// its device's file as a tombstone so the deletion beats an older copy on
// another device.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart' show clockNow;
import '../services/project_files.dart';
import 'folder_access.dart';

const notesFolder = 'Notes';

/// A line's identity across re-parses: scene, its first 60 characters, and which
/// repeat of that text it is in the scene (the corrections' key, less the PDF path).
String lineNoteKey(int scene, String text, int occurrence) => '$scene|${text.length > 60 ? text.substring(0, 60) : text}|$occurrence';

class LineNote {
  LineNote({required this.text, DateTime? updatedAt, this.deleted = false}) : updatedAt = updatedAt ?? clockNow().toUtc();
  final String text;
  final DateTime updatedAt;
  final bool deleted;

  factory LineNote.fromJson(Map<String, dynamic> j) => LineNote(
    text: j['text'] as String? ?? '',
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    deleted: j['deleted'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {'text': text, 'updatedAt': updatedAt.toIso8601String(), if (deleted) 'deleted': true};
}

class LineNotes extends ChangeNotifier {
  LineNotes({required this.folder, required this.deviceId, this.folderAccess = true});

  final String folder;
  final String deviceId;

  /// Off in tests: files are written with dart:io instead of the native plugin.
  final bool folderAccess;

  /// Every device's notes, merged.
  final Map<String, LineNote> _all = {};

  /// Only what this device wrote (the file this device owns).
  final Map<String, LineNote> _mine = {};

  /// Notes the user has expanded (kept per open screen, not saved).
  final Set<String> expanded = {};

  String get _path => '$folder/$notesFolder/$deviceId.json';

  /// The live note for [key], if there is one.
  LineNote? operator [](String key) {
    final n = _all[key];
    return n == null || n.deleted ? null : n;
  }

  bool has(String key) => this[key] != null;
  int get count => _all.values.where((n) => !n.deleted).length;

  /// Reads every device's notes file in the project.
  void load() {
    _all.clear();
    _mine.clear();
    final dir = Directory('$folder/$notesFolder');
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final device = f.path.split('/').last.replaceFirst(RegExp(r'\.json$'), '');
      try {
        final j = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
        final notes = Map<String, dynamic>.from(j['notes'] as Map? ?? const {});
        for (final e in notes.entries) {
          final n = LineNote.fromJson(Map<String, dynamic>.from(e.value as Map));
          if (device == deviceId) _mine[e.key] = n;
          final old = _all[e.key];
          if (old == null || n.updatedAt.isAfter(old.updatedAt)) _all[e.key] = n;
        }
      } catch (e) {
        debugPrint('Skipping notes file ${f.path}: $e');
      }
    }
  }

  Future<void> set(String key, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return remove(key);
    _put(key, LineNote(text: trimmed));
    await _save();
  }

  Future<void> remove(String key) async {
    if (!has(key)) return;
    _put(key, LineNote(text: '', deleted: true));
    expanded.remove(key);
    await _save();
  }

  void _put(String key, LineNote n) {
    _mine[key] = n;
    _all[key] = n;
    notifyListeners();
  }

  Future<void> _save() async {
    final text = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'device': deviceId,
      'notes': {for (final e in _mine.entries) e.key: e.value.toJson()},
    });
    try {
      if (folderAccess) {
        await FolderAccess.write(_path, text);
      } else {
        writeFileAtomic(_path, text);
      }
    } catch (e) {
      debugPrint('Could not save notes: $e');
    }
  }

  void toggle(String key) {
    if (!expanded.remove(key)) expanded.add(key);
    notifyListeners();
  }
}
