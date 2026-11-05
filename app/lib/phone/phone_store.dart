// The iPhone's view of the projects folder: which projects are there and
// whether each one is on the phone yet. The Mac owns project.json; the phone
// only reads it (and writes its own rehearsal file).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/project_files.dart';
import '../services/rust_core.dart';
import 'folder_access.dart';

class PhoneStore extends ChangeNotifier {
  PhoneStore({this.folderAccess = true, @visibleForTesting this.lister, @visibleForTesting this.downloader});

  /// Tests stand in for iCloud: what a folder holds, and bringing files onto the device.
  final Future<List<FolderEntry>> Function(String path)? lister;
  final Future<void> Function(List<String> paths)? downloader;

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

  /// Project ids waiting for their turn to download, in order (the first goes next).
  final List<String> queue = [];

  /// Project id → every file (the PDF aside) is on this device. Missing = not known yet, taken as in iCloud only.
  final Map<String, bool> onDevice = {};

  /// Project id → how far through the script the newest rehearsal file of any device says it was read (0–1), for the
  /// projects that have been read at all.
  final Map<String, double> progress = {};

  /// Project ids opened on this device (kept in the app's settings).
  final Set<String> opened = {};
  static const _openedKey = 'openedProjects';

  /// The project the user tapped to open while it was still coming down: it opens when it is here (and only that one;
  /// downloads asked for with the icon never open anything).
  String? wantsOpen;

  /// Projects whose files were just removed: iCloud is slow to say so, and a look too soon must not call them downloaded.
  final Map<String, DateTime> _evictedAt = {};
  bool _justEvicted(String id) => _evictedAt[id] != null && DateTime.now().difference(_evictedAt[id]!) < const Duration(seconds: 30);

  final Map<String, Future<bool>> _active = {};
  final Set<String> _cancelled = {};
  bool _pumping = false;

  /// Project ids whose downloaded files are being taken off the device right now (the cover shows a throbber).
  final Set<String> removing = {};

  /// Where a project is as far as this device goes.
  DownloadPhase phaseOf(Project p) {
    if (removing.contains(p.id)) return DownloadPhase.removing;
    if (downloading.containsKey(p.id)) return DownloadPhase.downloading;
    if (queue.contains(p.id)) return DownloadPhase.queued;
    return (onDevice[p.id] ?? !folderAccess) ? DownloadPhase.device : DownloadPhase.cloud;
  }

  /// 1-based place in the queue (1 = next), or null.
  int? queuePlace(Project p) {
    final i = queue.indexOf(p.id);
    return i < 0 ? null : i + 1;
  }

  /// Downloaded and never opened here, nor read on any device.
  bool isNew(Project p) => phaseOf(p) == DownloadPhase.device && !opened.contains(p.id) && !progress.containsKey(p.id);

  Future<void> markOpened(Project p) async {
    if (!opened.add(p.id)) return;
    notifyListeners();
    try {
      (await SharedPreferences.getInstance()).setStringList(_openedKey, opened.toList());
    } catch (_) {}
  }

  Future<void> start() async {
    try {
      opened.addAll((await SharedPreferences.getInstance()).getStringList(_openedKey) ?? const []);
    } catch (_) {}
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
    if (lister != null) return lister!(path);
    if (folderAccess) return FolderAccess.list(path);
    return [
      for (final e in Directory(path).listSync())
        if (!e.path.split('/').last.startsWith('.')) FolderEntry(e.path.split('/').last, isDir: e is Directory, downloaded: true),
    ];
  }

  Future<void> _download(List<String> paths) async {
    if (downloader != null) return downloader!(paths);
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
        // The small rehearsal files say how far each device has read.
        if (entries.any((e) => e.isDir && e.name == rehearsalFolder)) {
          for (final r in await _list('$f/${d.name}/$rehearsalFolder')) {
            if (!r.isDir && r.name.endsWith('.json') && !r.downloaded) wanted.add('$f/${d.name}/$rehearsalFolder/${r.name}');
          }
        }
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
      progress.clear();
      for (final p in out) {
        final read = p.folderPath == null ? null : loadNewestRehearsal(p.folderPath!);
        if (read != null && read.readScene != null) progress[p.id] = read.readProgress ?? 0;
      }
      error = null;
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
    await rescanDownloads();
  }

  /// Reads how far each project has been read again (a rehearsal screen just closed, or another device wrote).
  void refreshProgress() {
    final before = Map.of(progress);
    progress.clear();
    for (final p in projects) {
      final read = p.folderPath == null ? null : loadNewestRehearsal(p.folderPath!);
      if (read != null && read.readScene != null) progress[p.id] = read.readProgress ?? 0;
    }
    if (!mapEquals(before, progress)) notifyListeners();
  }

  /// Looks at every project's files again: which are wholly on this device (iOS can take them off when space is short).
  Future<void> rescanDownloads() async {
    final list = List.of(projects);
    final found = await Future.wait([for (final p in list) _isOnDevice(p)]);
    var changed = false;
    for (final (i, p) in list.indexed) {
      final here = found[i] && !_justEvicted(p.id);
      if (onDevice[p.id] != here) {
        onDevice[p.id] = here;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Every file of the project but the PDF (which Show PDF fetches when asked) is on this device.
  Future<bool> _isOnDevice(Project p) async {
    final folder = p.folderPath;
    if (folder == null) return false;
    try {
      return (await _missingFiles(folder)).isEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> _missingFiles(String folder) async {
    final missing = <String>[];
    Future<void> walk(String dir) async {
      for (final e in await _list(dir)) {
        if (e.isDir) {
          await walk('$dir/${e.name}');
        } else if (!e.downloaded && !e.name.toLowerCase().endsWith('.pdf')) {
          missing.add('$dir/${e.name}');
        }
      }
    }

    await walk(folder);
    return missing;
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
    if (folder == null || removing.contains(p.id)) return null;
    // Acknowledge the tap at once: the cover shows a throbber until the files are gone.
    removing.add(p.id);
    notifyListeners();
    try {
      final r = folderAccess ? await FolderAccess.evict(folder) : const RemovedDownload(freed: 0, files: 0, kept: 0);
      if (r.files > 0) {
        // Say so now: the icon should not wait for iCloud to catch up.
        _evictedAt[p.id] = DateTime.now();
        onDevice[p.id] = false;
      }
      removing.remove(p.id);
      notifyListeners();
      await refresh();
      return r;
    } catch (e) {
      error = 'Couldn’t remove the download of “${p.name}”: $e';
      return null;
    } finally {
      removing.remove(p.id);
      notifyListeners();
    }
  }

  /// Brings the whole project onto the phone now (audio, cues, script, rehearsal files) so it plays offline: what opening
  /// a project does. Only files not already here are fetched. A project already coming down is waited for, and one
  /// waiting in the queue goes first.
  Future<bool> download(Project p) {
    queue.remove(p.id);
    // (A block body: `() => _active.remove(...)` would hand whenComplete the very future it belongs to, and wait for it forever.)
    return _active[p.id] ??= _run(p).whenComplete(() {
      _active.remove(p.id);
    });
  }

  /// Adds [p] to the downloads: they come down one after another, in the order asked.
  void enqueue(Project p) {
    if (phaseOf(p) != DownloadPhase.cloud) return;
    queue.add(p.id);
    notifyListeners();
    _pump();
  }

  /// Takes [p] out of the queue, or stops it where it is (what has arrived stays).
  void cancelDownload(Project p) {
    if (wantsOpen == p.id) wantsOpen = null;
    if (queue.remove(p.id)) {
      notifyListeners();
    } else if (downloading.containsKey(p.id)) {
      _cancelled.add(p.id);
    }
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (queue.isNotEmpty) {
        final id = queue.first;
        final p = projects.where((p) => p.id == id).firstOrNull;
        if (p == null) {
          queue.removeAt(0);
          continue;
        }
        await download(p); // takes it out of the queue
      }
    } finally {
      _pumping = false;
    }
  }

  Future<bool> _run(Project p) async {
    final folder = p.folderPath;
    if (folder == null) return false;
    _cancelled.remove(p.id);
    downloading[p.id] = 0;
    notifyListeners();
    var finished = false;
    try {
      final missing = await _missingFiles(folder);
      for (var i = 0; i < missing.length; i++) {
        if (_cancelled.remove(p.id)) return false;
        await _download([missing[i]]);
        downloading[p.id] = (i + 1) / missing.length;
        notifyListeners();
      }
      finished = true;
      _evictedAt.remove(p.id);
      return true;
    } catch (e) {
      error = 'Couldn\'t download “${p.name}”: $e';
      return false;
    } finally {
      downloading.remove(p.id);
      if (finished) onDevice[p.id] = true;
      notifyListeners();
      if (!finished) rescanDownloads();
    }
  }
}

/// Where a project is on this device.
enum DownloadPhase { cloud, queued, downloading, device, removing }
