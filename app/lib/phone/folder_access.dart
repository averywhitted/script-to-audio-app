// The projects folder the user picked in Files (iOS). Implemented in
// ios/Runner/AppDelegate.swift (ProjectsFolderPlugin).

import 'package:flutter/services.dart';

class FolderEntry {
  FolderEntry(this.name, {required this.isDir, required this.downloaded});
  final String name;
  final bool isDir;

  /// False while iCloud hasn't brought the file onto the phone yet.
  final bool downloaded;
}

/// What Remove Download did: bytes freed, files removed, and files kept (not uploaded to iCloud yet, or not in iCloud).
class RemovedDownload {
  const RemovedDownload({required this.freed, required this.files, required this.kept});
  final int freed, files, kept;
}

class FolderAccess {
  static const _channel = MethodChannel('tableread/folder');

  /// Shows the Files folder picker. Returns the folder's path, or null if cancelled.
  static Future<String?> pick() => _channel.invokeMethod<String>('pick');

  /// The remembered folder (access started for this session), or null.
  static Future<String?> folder() => _channel.invokeMethod<String>('folder');

  static Future<void> forget() => _channel.invokeMethod('forget');

  static Future<List<FolderEntry>> list(String path) async {
    final raw = await _channel.invokeMethod<List>('list', {'path': path}) ?? const [];
    return [
      for (final e in raw.cast<Map>())
        FolderEntry(e['name'] as String, isDir: e['dir'] as bool? ?? false, downloaded: e['downloaded'] as bool? ?? true),
    ];
  }

  /// Waits until each file is on the phone.
  static Future<void> download(List<String> paths) => _channel.invokeMethod('download', {'paths': paths});

  static Future<void> delete(String path) => _channel.invokeMethod('delete', {'path': path});

  /// Remove Download (#118): takes a project's files off this device and leaves them in iCloud Drive.
  static Future<RemovedDownload> evict(String path) async {
    final r = Map<String, dynamic>.from(await _channel.invokeMethod<Map>('evict', {'path': path}) ?? const {});
    return RemovedDownload(
      freed: (r['freed'] as num?)?.toInt() ?? 0,
      files: (r['files'] as num?)?.toInt() ?? 0,
      kept: (r['kept'] as num?)?.toInt() ?? 0,
    );
  }

  /// Shows the Files picker for a screenplay PDF. Returns a copy of it in the app's temporary folder, or null if cancelled.
  static Future<String?> pickPdf() => _channel.invokeMethod<String>('pickPdf');

  /// Copies a local file into the projects folder (coordinated).
  static Future<void> copyIn(String from, String to) => _channel.invokeMethod('copyIn', {'from': from, 'to': to});

  /// Coordinated write, so iCloud picks the change up cleanly.
  static Future<void> write(String path, String text) => _channel.invokeMethod('write', {'path': path, 'text': text});
}
