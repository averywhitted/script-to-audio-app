// The iPhone's view of the projects folder: which projects are there and
// whether each one is on the phone yet. The Mac owns project.json; the phone
// only reads it (and writes its own rehearsal file).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/models.dart';
import '../services/project_files.dart';
import '../services/rust_core.dart';
import 'folder_access.dart';

class PhoneStore extends ChangeNotifier {
  PhoneStore({this.folderAccess = true});

  /// Off in tests, which set [folder] directly.
  final bool folderAccess;

  String? folder;
  bool loading = true;
  String? error;
  List<Project> projects = [];

  /// Project id → the render this phone asked the Mac for (render-request.json).
  Map<String, RenderRequest> requests = {};

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
        final wanted = [
          for (final e in entries)
            if ((e.name == 'project.json' || e.name == renderRequestFile || e.name == scriptSnapshotFile) && !e.downloaded) '$f/${d.name}/${e.name}',
        ];
        await _download(wanted);
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
      requests = {
        for (final p in out)
          if (p.folderPath case final f?) p.id: ?loadRenderRequest(f),
      };
      error = null;
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }

  /// True while a PDF is being read (the import button shows progress).
  bool importing = false;

  /// Import a screenplay (#102): pick a PDF in Files (or take [pickedPath]), parse it here with the shared Rust core,
  /// and add it to the projects folder as a new project (PDF, script.json, project.json) that the Mac picks up. The
  /// phone doesn't render voices: the Mac does, when asked. Returns the new project, or null if cancelled or failed
  /// ([error] says why).
  Future<Project?> importPdf({String? pickedPath, RustCore? core}) async {
    final base = folder;
    if (base == null || importing) return null;
    importing = true;
    error = null;
    notifyListeners();
    try {
      final path = pickedPath ?? await FolderAccess.pickPdf();
      if (path == null) return null;
      core ??= RustCore.locate();
      if (core == null) throw 'This build has no PDF reader. Reinstall the app from your Mac.';
      final script = await core.parse(path, correctionsJson: await rootBundle.loadString('assets/corrections_config.json'));
      final pdfName = path.split('/').last;
      final stem = pdfName.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
      final name = script.title.trim().isNotEmpty ? script.title.trim() : (stem.isEmpty ? 'Untitled Project' : stem);
      final taken = {for (final e in await _list(base)) e.name};
      final clean = name.replaceAll(RegExp(r'[^\p{L}\p{N} \-_]', unicode: true), '').trim();
      var dirName = clean.isEmpty ? 'Untitled Project' : clean;
      for (var n = 2; taken.contains(dirName); n++) {
        dirName = '${clean.isEmpty ? 'Untitled Project' : clean} $n';
      }
      final dir = '$base/$dirName';
      final project = Project.newProject(name, dir)
        ..pdfFilename = pdfName
        ..scriptTitle = script.title;
      final files = {
        scriptSnapshotFile: scriptSnapshotText(script, pdfFilename: pdfName),
        'project.json': projectManifestText(project), // last: the project exists for other devices once this is there
      };
      if (folderAccess) {
        await FolderAccess.copyIn(path, '$dir/$pdfName');
        for (final f in files.entries) {
          await FolderAccess.write('$dir/${f.key}', f.value);
        }
      } else {
        Directory(dir).createSync(recursive: true);
        File(path).copySync('$dir/$pdfName');
        for (final f in files.entries) {
          writeFileAtomic('$dir/${f.key}', f.value);
        }
      }
      importing = false;
      await refresh();
      return projects.where((p) => p.id == project.id).firstOrNull ?? project;
    } catch (e) {
      error = 'Couldn’t import that PDF: $e';
      return null;
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  /// Scenes the Mac hasn't rendered yet, when the Mac has saved the script
  /// (null when it hasn't: the request then asks for every missing scene).
  List<int>? missingScenes(Project p) {
    final folder = p.folderPath;
    final script = folder == null ? null : loadScriptSnapshot(folder);
    if (script == null) return null;
    // The audio files that are there (the same test as the rehearsal screen's).
    final rendered = <int>{
      for (final f in Directory(folder!).listSync().whereType<File>())
        if (RegExp(r'/Scene_(\d+)_[^/]*\.m4a$').firstMatch(f.path) case final m?) int.parse(m.group(1)!),
    };
    return [
      for (final s in script.scenes)
        if (!rendered.contains(s.number)) s.number,
    ];
  }

  /// Asks the Mac to render [p]: the scenes not rendered yet.
  Future<void> requestRender(Project p) async {
    final folder = p.folderPath;
    if (folder == null) return;
    final r = RenderRequest(scenes: missingScenes(p));
    try {
      if (folderAccess) {
        await FolderAccess.write('$folder/$renderRequestFile', r.encode());
      } else {
        writeFileAtomic('$folder/$renderRequestFile', r.encode());
      }
      requests[p.id] = r;
    } catch (e) {
      error = 'Couldn’t ask your Mac to render “${p.name}”: $e';
    }
    notifyListeners();
  }

  Future<void> cancelRequest(Project p) async {
    final folder = p.folderPath;
    if (folder == null) return;
    try {
      if (folderAccess) {
        await FolderAccess.delete('$folder/$renderRequestFile');
      } else {
        final f = File('$folder/$renderRequestFile');
        if (f.existsSync()) f.deleteSync();
      }
      requests.remove(p.id);
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  /// How much room a project's downloaded files take on this device.
  int localBytes(Project p) {
    final folder = p.folderPath;
    if (folder == null || !Directory(folder).existsSync()) return 0;
    var total = 0;
    for (final f in Directory(folder).listSync(recursive: true).whereType<File>()) {
      if (f.path.split('/').last.startsWith('.')) continue;
      total += f.lengthSync();
    }
    return total;
  }

  /// Remove Download (#118): frees the project's files on this device; they stay in iCloud Drive and come back when it
  /// is opened. Returns what happened, or null if it failed ([error] says why).
  Future<RemovedDownload?> removeDownload(Project p) async {
    final folder = p.folderPath;
    if (folder == null) return null;
    try {
      final r = folderAccess ? await FolderAccess.evict(folder) : const RemovedDownload(freed: 0, files: 0, kept: 0);
      await refresh();
      return r;
    } catch (e) {
      error = 'Couldn’t remove the download of “${p.name}”: $e';
      notifyListeners();
      return null;
    }
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
      // The PDF comes later, when Show PDF (or page numbers) asks for it.
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
