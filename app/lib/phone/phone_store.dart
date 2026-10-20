// The iPhone's view of the projects folder: which projects are there and
// whether each one is on the phone yet. The Mac owns project.json; the phone
// only reads it (and writes its own rehearsal file).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'folder_access.dart';

class PhoneStore extends ChangeNotifier {
  PhoneStore({this.folderAccess = true});

  /// Off in tests, which set [folder] directly.
  final bool folderAccess;

  String? folder;
  bool loading = true;
  String? error;
  List<Project> projects = [];

  /// Project id → download progress (0–1) while it's being brought onto the phone.
  final Map<String, double> downloading = {};

  Future<void> start() async {
    if (folderAccess) {
      try {
        folder = await FolderAccess.folder();
      } catch (e) {
        error = '$e';
      }
    }
    await refresh();
  }

  Future<void> pickFolder() async {
    try {
      final picked = await FolderAccess.pick();
      if (picked == null) return;
      folder = picked;
      error = null;
    } catch (e) {
      error = '$e';
    }
    await refresh();
  }

  Future<void> forgetFolder() async {
    if (folderAccess) await FolderAccess.forget();
    folder = null;
    projects = [];
    notifyListeners();
  }

  Future<List<FolderEntry>> _list(String path) async {
    if (folderAccess) return FolderAccess.list(path);
    return [
      for (final e in Directory(path).listSync())
        if (!e.path.split('/').last.startsWith('.')) FolderEntry(e.path.split('/').last, isDir: e is Directory, downloaded: true),
    ];
  }

  Future<void> _download(List<String> paths) async {
    if (folderAccess && paths.isNotEmpty) await FolderAccess.download(paths);
  }

  /// Reads every project's project.json (fetching just those from iCloud first).
  Future<void> refresh() async {
    final f = folder;
    if (f == null) {
      loading = false;
      notifyListeners();
      return;
    }
    loading = true;
    notifyListeners();
    try {
      final dirs = (await _list(f)).where((e) => e.isDir).toList();
      final manifests = <String>[];
      for (final d in dirs) {
        final entries = await _list('$f/${d.name}');
        final m = entries.where((e) => e.name == 'project.json').firstOrNull;
        if (m == null) continue;
        manifests.add('$f/${d.name}/project.json');
        if (!m.downloaded) await _download([manifests.last]);
      }
      final out = <Project>[];
      for (final path in manifests) {
        try {
          final j = Map<String, dynamic>.from(jsonDecode(File(path).readAsStringSync()) as Map);
          out.add(Project.fromJson(j, folderPath: File(path).parent.path));
        } catch (e) {
          debugPrint('Skipping $path: $e');
        }
      }
      out.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
      projects = out;
      error = null;
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }

  /// Brings the whole project onto the phone (audio, cues, script, rehearsal
  /// files) so it plays offline. Only files not already here are fetched.
  Future<bool> download(Project p) async {
    final folder = p.folderPath;
    if (folder == null) return false;
    downloading[p.id] = 0;
    notifyListeners();
    try {
      final missing = <String>[];
      Future<void> walk(String dir) async {
        for (final e in await _list(dir)) {
          if (e.isDir) {
            await walk('$dir/${e.name}');
          } else if (!e.downloaded) {
            missing.add('$dir/${e.name}');
          }
        }
      }

      await walk(folder);
      // The PDF stays on the Mac: the phone never parses.
      missing.removeWhere((m) => m.toLowerCase().endsWith('.pdf'));
      for (var i = 0; i < missing.length; i++) {
        await _download([missing[i]]);
        downloading[p.id] = (i + 1) / missing.length;
        notifyListeners();
      }
      return true;
    } catch (e) {
      error = 'Couldn\'t download “${p.name}”: $e';
      return false;
    } finally {
      downloading.remove(p.id);
      notifyListeners();
    }
  }
}
