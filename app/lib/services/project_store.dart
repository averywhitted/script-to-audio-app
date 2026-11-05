// Projects on disk: one folder per project with a project.json manifest.
// Port of Sources/TableRead/ProjectStore.swift, same folder layout and files.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'platform.dart';
import 'project_files.dart';
import 'settings.dart';

class DeletedProjectRecord {
  DeletedProjectRecord(this.project, this.originalPath, this.trashedPath);
  final Project project;
  final String originalPath;
  final String trashedPath;
}

class ProjectStore extends ChangeNotifier {
  ProjectStore(this.settings) {
    baseDir = settings.getString('projectsBaseURL') ?? defaultBaseDir;
    loadAllProjects();
    loadArchivedProjects();
  }

  final Settings settings;
  late String baseDir;

  List<Project> projects = [];
  Project? currentProject;
  final List<DeletedProjectRecord> recentlyDeleted = [];
  List<ArchivedProjectMeta> archivedProjects = [];
  final Set<String> archivingIds = {};

  /// Project id → what the iPhone asked this Mac to render (render-request.json).
  Map<String, RenderRequest> renderRequests = {};

  /// Project files this session has already backed up before first changing them.
  final Set<String> _backedUp = {};

  static String get defaultBaseDir => '${Platform.environment['HOME']}/Documents/Table Read';

  static const _encoder = JsonEncoder.withIndent('  ');

  List<String> get _externalFolders => settings.getStringList('externalProjectFolders');

  bool isManagedProjectFolder(String path) => File('$path/project.json').existsSync();

  void loadAllProjects() {
    final dir = Directory(baseDir);
    final candidates = <String>[
      if (dir.existsSync()) ...dir.listSync().whereType<Directory>().map((d) => d.path).where((p) => !p.split('/').last.startsWith('.')),
      ..._externalFolders,
    ];
    final seen = <String>{};
    final loaded = <Project>[];
    for (final folder in candidates) {
      final manifest = File('$folder/project.json');
      if (!manifest.existsSync()) continue;
      try {
        final p = Project.fromJson(Map<String, dynamic>.from(jsonDecode(manifest.readAsStringSync()) as Map), folderPath: folder);
        if (!seen.add(p.id)) continue;
        if (p.renderedScenes.isEmpty) {
          // Backfill from audio files, like the Swift app.
          final nums = <int>[];
          for (final f in Directory(folder).listSync().whereType<File>()) {
            final name = f.path.split('/').last;
            final m = RegExp(r'^Scene_(\d+)_.*\.m4a$').firstMatch(name);
            if (m != null) nums.add(int.parse(m.group(1)!));
          }
          if (nums.isNotEmpty) p.renderedScenes = nums..sort();
        }
        loaded.add(p);
      } catch (e) {
        debugPrint('Skipping $folder: $e');
      }
    }
    loaded.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    projects = loaded;
    renderRequests = _readRenderRequests();
    notifyListeners();
  }

  void loadArchivedProjects() {
    final dir = Directory(baseDir);
    if (!dir.existsSync()) {
      archivedProjects = [];
      return;
    }
    final out = <ArchivedProjectMeta>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.archive-meta.json')) continue;
      try {
        final j = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
        out.add(
          ArchivedProjectMeta(
            project: Project.fromJson(Map<String, dynamic>.from(j['project'] as Map)),
            zipFilename: j['zipFilename'] as String,
            originalFolderName: j['originalFolderName'] as String,
            metaPath: f.path,
          ),
        );
      } catch (_) {}
    }
    out.sort((a, b) => b.project.lastOpenedAt.compareTo(a.project.lastOpenedAt));
    archivedProjects = out;
    notifyListeners();
  }

  String _sanitized(String name) {
    final s = name.replaceAll(RegExp(r'[^\p{L}\p{N} \-_]', unicode: true), '').trim();
    return s.isEmpty ? 'Untitled Project' : s;
  }

  String _uniqueFolder(String container, String name) {
    var candidate = '$container/$name';
    var suffix = 2;
    while (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound) {
      candidate = '$container/$name $suffix';
      suffix++;
    }
    return candidate;
  }

  /// Creates a fresh, uniquely named folder inside [customContainer] (or the
  /// projects folder) and copies the PDF into it. Never uses the container itself.
  Project createProject({required String name, String? customContainer, required String pdfSourcePath, String engine = 'macOS'}) {
    final container = customContainer ?? baseDir;
    Directory(container).createSync(recursive: true);
    final folder = _uniqueFolder(container, _sanitized(name));
    Directory(folder).createSync(recursive: true);
    final pdfName = pdfSourcePath.split('/').last;
    try {
      File(pdfSourcePath).copySync('$folder/$pdfName');
    } catch (e) {
      if (isManagedProjectFolder(folder) || Directory(folder).listSync().isEmpty) {
        Directory(folder).deleteSync(recursive: true);
      }
      rethrow;
    }
    final project = Project.newProject(name.trim().isEmpty ? 'Untitled Project' : name.trim(), folder, engine: engine)..pdfFilename = pdfName;
    saveProject(project);
    if (customContainer != null) {
      settings.setStringList('externalProjectFolders', [..._externalFolders, folder]);
    }
    projects.insert(0, project);
    notifyListeners();
    return project;
  }

  Project openProject(Project p) {
    p.lastOpenedAt = clockNow();
    saveProject(p);
    currentProject = p;
    notifyListeners();
    return p;
  }

  void closeProject() {
    currentProject = null;
    notifyListeners();
  }

  void saveProject(Project p) {
    final folder = p.folderPath;
    if (folder == null) return;
    final manifest = File('$folder/project.json');
    // One-time safety copy of the file as the Swift app last wrote it.
    if (manifest.existsSync() && _backedUp.add(folder)) {
      final backup = File('$folder/project.json.preview-backup');
      if (!backup.existsSync()) manifest.copySync(backup.path);
    }
    final tmp = File('$folder/project.json.tmp');
    tmp.writeAsStringSync(_encoder.convert(p.toJson()), flush: true);
    tmp.renameSync(manifest.path);
    final i = projects.indexWhere((x) => x.id == p.id);
    if (i >= 0) projects[i] = p;
    notifyListeners();
  }

  void renameProject(String id, String newName) {
    final name = newName.trim();
    if (name.isEmpty) return;
    final p = projects.where((x) => x.id == id).firstOrNull;
    if (p == null) return;
    p.name = name;
    saveProject(p);
  }

  Future<void> deleteProject(Project p) async {
    final folder = p.folderPath;
    if (folder == null || !isManagedProjectFolder(folder)) return;
    projects.removeWhere((x) => x.id == p.id);
    if (currentProject?.id == p.id) currentProject = null;
    notifyListeners();
    final trashed = await NativePlatform.trash(folder);
    if (trashed != null) {
      recentlyDeleted.add(DeletedProjectRecord(p, folder, trashed));
      notifyListeners();
    }
  }

  void restoreProject(String id) {
    final rec = recentlyDeleted.where((r) => r.project.id == id).firstOrNull;
    if (rec == null) return;
    var dest = rec.originalPath;
    if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
      dest = '$baseDir/${rec.originalPath.split('/').last}_restored';
    }
    try {
      Directory(rec.trashedPath).renameSync(dest);
    } catch (_) {}
    recentlyDeleted.removeWhere((r) => r.project.id == id);
    loadAllProjects();
  }

  Future<void> archiveProject(Project p) async {
    final folder = p.folderPath;
    if (folder == null || !isManagedProjectFolder(folder)) return;
    archivingIds.add(p.id);
    notifyListeners();
    final parent = Directory(folder).parent.path;
    final folderName = folder.split('/').last;
    final zipName = '${p.id}.zip';
    final zipPath = '$baseDir/$zipName';
    final metaPath = '$baseDir/${p.id}.archive-meta.json';
    Directory(baseDir).createSync(recursive: true);
    File(metaPath).writeAsStringSync(_encoder.convert({'project': p.toJson(), 'zipFilename': zipName, 'originalFolderName': folderName}));
    try {
      final zip = await Process.run('/usr/bin/zip', ['-r', zipPath, folderName], workingDirectory: parent);
      if (zip.exitCode != 0) throw Exception('zip exited with status ${zip.exitCode}');
      final test = await Process.run('/usr/bin/unzip', ['-t', zipPath]);
      if (test.exitCode != 0) throw Exception('the archive failed its integrity check');
      await NativePlatform.trash(folder);
      settings.setStringList('externalProjectFolders', _externalFolders.where((f) => f != folder).toList());
      projects.removeWhere((x) => x.id == p.id);
      loadArchivedProjects();
    } catch (_) {
      for (final path in [metaPath, zipPath]) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
    }
    archivingIds.remove(p.id);
    notifyListeners();
  }

  Future<void> unarchiveProject(String id) async {
    final meta = archivedProjects.where((m) => m.project.id == id).firstOrNull;
    if (meta == null) return;
    archivingIds.add(id);
    notifyListeners();
    final r = await Process.run('/usr/bin/unzip', ['-o', '$baseDir/${meta.zipFilename}', '-d', baseDir]);
    if (r.exitCode == 0) {
      for (final path in ['$baseDir/${meta.zipFilename}', meta.metaPath]) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      loadArchivedProjects();
      loadAllProjects();
    }
    archivingIds.remove(id);
    notifyListeners();
  }

  static String get iCloudDriveRoot => '${Platform.environment['HOME']}/Library/Mobile Documents/com~apple~CloudDocs';
  static String get iCloudProjectsDir => '$iCloudDriveRoot/Table Read';

  bool get projectsInICloud => baseDir == iCloudProjectsDir || baseDir.startsWith('$iCloudDriveRoot/');

  /// What a move would carry: project folders and archives (zip + meta) directly in [baseDir].
  ({int projects, int archives}) movableCounts() {
    final dir = Directory(baseDir);
    if (!dir.existsSync()) return (projects: 0, archives: 0);
    var projects = 0, archives = 0;
    for (final e in dir.listSync()) {
      if (e is Directory && isManagedProjectFolder(e.path)) projects++;
      if (e is File && e.path.endsWith('.archive-meta.json')) archives++;
    }
    return (projects: projects, archives: archives);
  }

  /// Moves everything in the projects folder (projects, archives, anything
  /// else the user keeps there) into [target] and makes it the projects
  /// folder. Name clashes get " 2", " 3"… Projects added from elsewhere
  /// (external folders) stay where they are. Throws if [target]'s parent
  /// doesn't exist (iCloud Drive turned off).
  Future<int> moveProjectsTo(String target) async {
    if (target == baseDir) return 0;
    if (!Directory(Directory(target).parent.path).existsSync()) {
      throw const FileSystemException('iCloud Drive isn\'t turned on on this Mac (System Settings → Apple Account → iCloud).');
    }
    Directory(target).createSync(recursive: true);
    final source = Directory(baseDir);
    var moved = 0;
    if (source.existsSync()) {
      for (final e in source.listSync()) {
        final name = e.path.split('/').last;
        if (name.startsWith('.')) continue;
        var dest = '$target/$name';
        for (var n = 2; FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound; n++) {
          final dot = e is! File ? -1 : (name.endsWith('.archive-meta.json') ? name.length - '.archive-meta.json'.length : name.lastIndexOf('.'));
          dest = dot > 0 ? '$target/${name.substring(0, dot)} $n${name.substring(dot)}' : '$target/$name $n';
        }
        try {
          e.renameSync(dest);
        } on FileSystemException {
          // Another volume: copy, then Trash the original only if the copy worked.
          final r = await Process.run('/usr/bin/ditto', [e.path, dest]);
          if (r.exitCode != 0) throw FileSystemException('Could not copy $name (${r.stderr})'.trim());
          await NativePlatform.trash(e.path);
        }
        moved++;
      }
      // An archive's meta names its zip by file name: keep them paired after a rename.
      _repairArchiveMetas(target);
      if (source.listSync().every((e) => e.path.split('/').last.startsWith('.'))) await NativePlatform.trash(source.path);
    }
    recentlyDeleted.clear();
    changeBaseDir(target);
    return moved;
  }

  void _repairArchiveMetas(String dir) {
    for (final f in Directory(dir).listSync().whereType<File>().where((f) => f.path.endsWith('.archive-meta.json'))) {
      try {
        final j = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
        final zip = j['zipFilename'] as String?;
        final expected = '${f.path.split('/').last.replaceFirst('.archive-meta.json', '')}.zip';
        if (zip != null && zip != expected && File('$dir/$expected').existsSync()) {
          j['zipFilename'] = expected;
          f.writeAsStringSync(_encoder.convert(j));
        }
      } catch (_) {}
    }
  }

  Map<String, RenderRequest> _readRenderRequests() => {
    for (final p in projects)
      if (p.folderPath case final f?) p.id: ?loadRenderRequest(f),
  };

  /// Re-reads only the request files (iCloud brings new ones while the app is open).
  void refreshRenderRequests() {
    final next = _readRenderRequests();
    final same =
        next.length == renderRequests.length &&
        next.entries.every((e) => renderRequests[e.key]?.requestedAt == e.value.requestedAt && renderRequests[e.key]?.summary == e.value.summary);
    if (same) return;
    renderRequests = next;
    notifyListeners();
  }

  void refresh() => notifyListeners();

  void dismissRenderRequest(Project p) {
    final folder = p.folderPath;
    if (folder == null) return;
    try {
      File('$folder/$renderRequestFile').deleteSync();
    } catch (_) {}
    renderRequests.remove(p.id);
    notifyListeners();
  }

  void changeBaseDir(String path) {
    baseDir = path;
    settings.setString('projectsBaseURL', path);
    loadAllProjects();
    loadArchivedProjects();
  }
}
