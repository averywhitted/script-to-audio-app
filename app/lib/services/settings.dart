// App preferences. The preview keeps its own preferences; on first launch it
// copies the projects-folder setting from the Swift app so both see the same
// projects.

import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  Settings._(this._p);
  final SharedPreferences _p;

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    final s = Settings._(p);
    if (!p.containsKey('importedSwiftSettings')) {
      await s._importFromSwiftApp();
      await p.setBool('importedSwiftSettings', true);
    }
    return s;
  }

  /// Reads a few values the Swift app saved (domain com.averywhitted.tableread).
  /// Read-only: the Swift app's settings are never changed.
  Future<void> _importFromSwiftApp() async {
    Future<String?> read(String key) async {
      try {
        final r = await Process.run('/usr/bin/defaults', ['read', 'com.averywhitted.tableread', key]);
        if (r.exitCode != 0) return null;
        final v = (r.stdout as String).trim();
        return v.isEmpty ? null : v;
      } catch (_) {
        return null;
      }
    }

    final base = await read('projectsBaseURL');
    if (base != null) await _p.setString('projectsBaseURL', base);
    final channel = await read('updateChannel');
    if (channel != null) await _p.setString('updateChannel', channel);
    for (final k in ['autoOpenFinderAfterRender', 'contributeCorrections', 'notifyOnSceneComplete', 'notifyOnRenderComplete', 'notifyOnRenderFailed']) {
      final v = await read(k);
      if (v != null) await _p.setBool(k, v == '1' || v.toLowerCase() == 'true');
    }
    final out = await read('lastOutputDirectory');
    if (out != null) await _p.setString('lastOutputDirectory', out);
  }

  String? getString(String k) => _p.getString(k);
  Future<void> setString(String k, String? v) => v == null ? _p.remove(k) : _p.setString(k, v);
  bool getBool(String k, {bool fallback = false}) => _p.getBool(k) ?? fallback;
  Future<void> setBool(String k, bool v) => _p.setBool(k, v);
  List<String> getStringList(String k) => _p.getStringList(k) ?? const [];
  Future<void> setStringList(String k, List<String> v) => _p.setStringList(k, v);
}
