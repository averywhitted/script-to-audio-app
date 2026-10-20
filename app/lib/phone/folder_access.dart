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

  /// Coordinated write, so iCloud picks the change up cleanly.
  static Future<void> write(String path, String text) => _channel.invokeMethod('write', {'path': path, 'text': text});
}
