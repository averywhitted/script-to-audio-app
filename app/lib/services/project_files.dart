// Files inside a project folder that other devices read (#89): the parsed
// script, so the iPhone can show scenes without parsing the PDF, and each
// device's rehearsal settings. Project folders can live in iCloud Drive, so
// every write is whole-file and atomic, and each device writes only its own
// rehearsal file (two devices never write the same file, so iCloud never
// makes conflict copies).

import 'dart:convert';
import 'dart:io';

import '../models/models.dart';

const scriptSnapshotFile = 'script.json';
const rehearsalFolder = 'Rehearsal';

const _encoder = JsonEncoder.withIndent('  ');

/// Writes [text] to [path] through a temporary file, so a reader (or iCloud)
/// never sees half a file. Skips the write when the file already says it.
void writeFileAtomic(String path, String text) {
  final f = File(path);
  try {
    if (f.existsSync() && f.readAsStringSync() == text) return;
  } catch (_) {}
  f.parent.createSync(recursive: true);
  final tmp = File('$path.tmp');
  tmp.writeAsStringSync(text, flush: true);
  tmp.renameSync(path);
}

/// Saves the parse next to project.json. Corrections and added lines stay in
/// project.json and are applied on top, the same way on every device.
void saveScriptSnapshot(String folder, ScriptSummary script, {required String pdfFilename}) {
  writeFileAtomic('$folder/$scriptSnapshotFile', scriptSnapshotText(script, pdfFilename: pdfFilename));
}

/// The text of script.json (also written by the iPhone, through the Files plugin).
String scriptSnapshotText(ScriptSummary script, {required String pdfFilename}) =>
    _encoder.convert({'schemaVersion': 1, 'pdfFilename': pdfFilename, 'script': script.toJson()});

/// The text of project.json, formatted as the Mac writes it.
String projectManifestText(Project p) => _encoder.convert(p.toJson());

ScriptSummary? loadScriptSnapshot(String folder) {
  try {
    final j = jsonDecode(File('$folder/$scriptSnapshotFile').readAsStringSync()) as Map;
    return ScriptSummary.fromJson(Map<String, dynamic>.from(j['script'] as Map));
  } catch (_) {
    return null;
  }
}

/// The parse kept with the project (script.json), if it is still a parse of [pdfPath]: written for that PDF's file name, and
/// the PDF has not been replaced since (a PDF newer than the saved parse by more than a couple of seconds counts as
/// replaced). Opening a project uses this instead of reading the PDF again; Re-parse makes a fresh one.
ScriptSummary? loadSavedParse(String folder, String pdfPath) {
  try {
    final file = File('$folder/$scriptSnapshotFile');
    final j = jsonDecode(file.readAsStringSync()) as Map;
    if (j['pdfFilename'] != pdfPath.split('/').last) return null;
    final pdf = File(pdfPath);
    if (pdf.existsSync() && pdf.lastModifiedSync().isAfter(file.lastModifiedSync().add(const Duration(seconds: 2)))) return null;
    final script = ScriptSummary.fromJson(Map<String, dynamic>.from(j['script'] as Map));
    return script.scenes.isEmpty ? null : script;
  } catch (_) {
    return null;
  }
}

/// One device's rehearsal settings for one project.
class RehearsalState {
  RehearsalState({
    this.role = '',
    this.roles = const [],
    this.mute = false,
    this.block = false,
    this.cue = false,
    this.speed = 1.0,
    this.loopMode = 'off',
    this.loopStart = 0,
    this.loopEnd = 0,
    this.sceneNumber,
    this.time = 0,
    this.readScene,
    this.readLine = '',
    this.readProgress,
    DateTime? updatedAt,
    this.device = '',
    this.fileId = '',
  }) : updatedAt = updatedAt ?? clockNow().toUtc();

  String role;

  /// Everyone being played when there are several ([role] is the first).
  List<String> roles;
  bool mute, block, cue;
  double speed;

  /// 'off' | 'scene' | 'lines' (LoopMode names); start/end are seconds in the scene.
  String loopMode;
  double loopStart, loopEnd;

  /// Where playback last stopped.
  int? sceneNumber;
  double time;

  /// Where the script was being read (position sync): the scene, and the line's identity (lineNoteKey).
  int? readScene;
  String readLine;

  /// How far through the script that line is (0...1), for the progress bar on the project's cover; null when unknown.
  double? readProgress;

  DateTime updatedAt;

  /// A label for the device (iPhone, iPad, Mac), shown to the user.
  String device;

  /// The device id this state was read from (its file's name); not saved.
  String fileId;

  factory RehearsalState.fromJson(Map<String, dynamic> j) {
    final loop = (j['loop'] as Map?) ?? const {};
    final pos = (j['position'] as Map?) ?? const {};
    return RehearsalState(
      role: j['role'] as String? ?? '',
      roles: ((j['roles'] as List?) ?? const []).cast<String>(),
      mute: j['mute'] as bool? ?? false,
      block: j['block'] as bool? ?? false,
      cue: j['cue'] as bool? ?? false,
      speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
      loopMode: loop['mode'] as String? ?? 'off',
      loopStart: (loop['start'] as num?)?.toDouble() ?? 0,
      loopEnd: (loop['end'] as num?)?.toDouble() ?? 0,
      sceneNumber: (pos['scene'] as num?)?.toInt(),
      time: (pos['time'] as num?)?.toDouble() ?? 0,
      readScene: (j['reading'] as Map?)?['scene'] as int?,
      readLine: (j['reading'] as Map?)?['line'] as String? ?? '',
      readProgress: ((j['reading'] as Map?)?['progress'] as num?)?.toDouble(),
      updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      device: j['device'] as String? ?? '',
    );
  }

  /// Everything but the timestamp: two states that say the same thing.
  Map<String, dynamic> _body() => {
    'role': role,
    'roles': roles,
    'mute': mute,
    'block': block,
    'cue': cue,
    'speed': speed,
    'loop': {'mode': loopMode, 'start': loopStart, 'end': loopEnd},
    'position': {'scene': sceneNumber, 'time': time},
    'reading': {'scene': readScene, 'line': readLine, if (readProgress != null) 'progress': double.parse(readProgress!.toStringAsFixed(3))},
  };

  bool sameAs(RehearsalState o) => jsonEncode(_body()) == jsonEncode(o._body());

  Map<String, dynamic> toJson() => {'schemaVersion': 1, 'device': device, 'updatedAt': updatedAt.toIso8601String(), ..._body()};
}

String rehearsalPath(String folder, String deviceId) => '$folder/$rehearsalFolder/$deviceId.json';

/// The newest rehearsal state any device wrote for this project, or null.
RehearsalState? loadNewestRehearsal(String folder) {
  final dir = Directory('$folder/$rehearsalFolder');
  if (!dir.existsSync()) return null;
  RehearsalState? best;
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json')) continue;
    try {
      final s = RehearsalState.fromJson(Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map));
      s.fileId = f.path.split('/').last.replaceFirst(RegExp(r'\.json$'), '');
      if (best == null || s.updatedAt.isAfter(best.updatedAt)) best = s;
    } catch (_) {}
  }
  return best;
}

/// Writes this device's state, unless it says the same as what's there.
void writeRehearsal(String folder, String deviceId, RehearsalState state) {
  final path = rehearsalPath(folder, deviceId);
  try {
    final old = RehearsalState.fromJson(Map<String, dynamic>.from(jsonDecode(File(path).readAsStringSync()) as Map));
    if (old.sameAs(state)) return;
  } catch (_) {}
  writeFileAtomic(path, _encoder.convert(state.toJson()));
}

/// Edits in project.json are keyed by the PDF's absolute path, which changes
/// when the project folder moves (to iCloud Drive, or onto another device). A
/// project has one PDF, so every edit in its file belongs to it: re-point
/// them all at [pdfPath]. Returns true if anything changed.
bool rebaseEdits({
  required String pdfPath,
  required Map<String, ParserCorrection> corrections,
  required Map<String, Map<int, String>> sceneTitleOverrides,
  required Map<String, List<UserAddedElement>> userAddedElements,
}) {
  var changed = false;
  if (corrections.values.any((c) => c.pdfIdentifier != pdfPath)) {
    final all = corrections.values.toList();
    corrections.clear();
    for (final c in all) {
      c.pdfIdentifier = pdfPath;
      corrections[c.storageKey] = c;
    }
    changed = true;
  }
  if (sceneTitleOverrides.keys.any((k) => k != pdfPath)) {
    final merged = <int, String>{};
    for (final e in sceneTitleOverrides.entries) {
      if (e.key != pdfPath) merged.addAll(e.value);
    }
    merged.addAll(sceneTitleOverrides[pdfPath] ?? const {});
    sceneTitleOverrides
      ..clear()
      ..[pdfPath] = merged;
    changed = true;
  }
  if (userAddedElements.entries.any((e) => !e.key.startsWith('$pdfPath|') || e.value.any((a) => a.pdfPath != pdfPath))) {
    final all = userAddedElements.values.expand((l) => l).toList();
    userAddedElements.clear();
    for (final a in all) {
      a.pdfPath = pdfPath;
      userAddedElements.putIfAbsent('$pdfPath|${a.sceneNumber}', () => []).add(a);
    }
    changed = true;
  }
  return changed;
}

// ---------------------------------------------------------------------------
// Render requests: the iPhone asks the Mac to render a project
// ---------------------------------------------------------------------------

const renderRequestFile = 'render-request.json';

/// Written by the iPhone; the Mac shows it on its home screen and removes it
/// once those scenes are rendered (or the user dismisses it).
class RenderRequest {
  RenderRequest({this.scenes, DateTime? requestedAt, this.device = 'iPhone'}) : requestedAt = requestedAt ?? clockNow().toUtc();

  /// The scenes asked for; null = every scene not rendered yet.
  final List<int>? scenes;
  final DateTime requestedAt;
  final String device;

  factory RenderRequest.fromJson(Map<String, dynamic> j) => RenderRequest(
    scenes: (j['scenes'] as List?)?.map((e) => (e as num).toInt()).toList(),
    requestedAt: DateTime.tryParse(j['requestedAt'] as String? ?? '')?.toUtc(),
    device: j['device'] as String? ?? 'iPhone',
  );

  Map<String, dynamic> toJson() => {'schemaVersion': 1, 'device': device, 'requestedAt': requestedAt.toIso8601String(), 'scenes': scenes};

  String encode() => _encoder.convert(toJson());

  /// "3 scenes" / "every scene not rendered yet".
  String get summary {
    final s = scenes;
    if (s == null) return 'every scene not rendered yet';
    return '${s.length} scene${s.length == 1 ? '' : 's'}';
  }
}

RenderRequest? loadRenderRequest(String folder) {
  try {
    return RenderRequest.fromJson(Map<String, dynamic>.from(jsonDecode(File('$folder/$renderRequestFile').readAsStringSync()) as Map));
  } catch (_) {
    return null;
  }
}

/// After a render: drops the scenes now rendered from the request; removes
/// the file once nothing asked for is left. Returns the request still open.
RenderRequest? settleRenderRequest(String folder, {required Set<int> rendered, required Set<int> allScenes}) {
  final req = loadRenderRequest(folder);
  if (req == null) return null;
  final left = (req.scenes ?? allScenes.toList()).where((n) => !rendered.contains(n)).toList();
  if (left.isEmpty) {
    try {
      File('$folder/$renderRequestFile').deleteSync();
    } catch (_) {}
    return null;
  }
  if (req.scenes != null && left.length != req.scenes!.length) {
    final next = RenderRequest(scenes: left, requestedAt: req.requestedAt, device: req.device);
    writeFileAtomic('$folder/$renderRequestFile', next.encode());
    return next;
  }
  return req;
}
