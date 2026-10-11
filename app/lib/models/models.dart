// Data models shared with the Python worker and the Swift app's saved files.
//
// Field names and encodings match Sources/TableRead/Models.swift and
// Project.swift exactly, so projects written by either app open in the other.

import 'package:characters/characters.dart';
import 'package:uuid/uuid.dart';

const narratorKey = '__NARRATOR__';

/// Replaceable in tests so dates and times on screen are stable.
DateTime Function() clockNow = DateTime.now;

/// First 60 characters of a line, as Swift's `String.prefix(60)` counts them.
String textPrefix60(String text) => text.characters.take(60).toString();

/// Identifies a parsed line within its scene. Must match `elementRef` in
/// Models.swift and `_element_ref` in audio_worker.py.
String elementRef(String text, int occurrence) {
  final prefix = textPrefix60(text);
  return occurrence == 0 ? prefix : '$prefix\u001F$occurrence';
}

String correctionKey(String pdfPath, int sceneNumber, String text, [int occurrence = 0]) => '$pdfPath|$sceneNumber|${elementRef(text, occurrence)}';

enum EngineKind {
  macOS('macOS', 'macOS Voices', 'Built in, free, offline'),
  kokoro('kokoro', 'Kokoro Local', 'Offline neural voices'),
  piper('piper', 'Piper Local', 'Small, fast offline voices'),
  openAI('openAI', 'OpenAI TTS', 'Cloud quality, API key and limits');

  const EngineKind(this.id, this.title, this.subtitle);
  final String id;
  final String title;
  final String subtitle;

  bool get isSupported => this != EngineKind.piper;

  static EngineKind? fromId(String? id) {
    for (final e in values) {
      if (e.id == id) return e;
    }
    return null;
  }
}

class SceneElement {
  SceneElement({
    required this.kind,
    this.speaker,
    required this.text,
    this.overlapCue,
    this.overlapTexts,
    this.confidence = 1.0,
    this.reason,
    this.occurrence = 0,
  });

  String kind; // dialog | stage_direction | parenthetical
  String? speaker;
  String text;
  List<String>? overlapCue;
  List<String>? overlapTexts;
  double confidence;
  String? reason;
  int occurrence;

  factory SceneElement.fromJson(Map<String, dynamic> j) => SceneElement(
    kind: j['kind'] as String? ?? 'stage_direction',
    speaker: j['speaker'] as String?,
    text: j['text'] as String? ?? '',
    overlapCue: (j['overlapCue'] as List?)?.cast<String>(),
    overlapTexts: (j['overlapTexts'] as List?)?.cast<String>(),
    confidence: (j['confidence'] as num?)?.toDouble() ?? 1.0,
    reason: j['reason'] as String?,
  );

  SceneElement copy() => SceneElement(
    kind: kind,
    speaker: speaker,
    text: text,
    overlapCue: overlapCue == null ? null : List.of(overlapCue!),
    overlapTexts: overlapTexts == null ? null : List.of(overlapTexts!),
    confidence: confidence,
    reason: reason,
    occurrence: occurrence,
  );

  String get ref => elementRef(text, occurrence);
  bool get isOverlap => (overlapCue?.length ?? 0) >= 2;
  bool get hasSplitText => (overlapTexts?.length ?? 0) >= 2;

  String get displaySpeaker {
    if (kind == 'stage_direction' || kind == 'parenthetical') return 'Narrator';
    if (isOverlap) return overlapCue!.join(' & ');
    return speaker ?? 'Narrator';
  }
}

class Scene {
  Scene({required this.number, required this.title, required this.elementCount, required this.elements});

  final int number;
  final String title;
  final int elementCount;
  final List<SceneElement> elements;

  factory Scene.fromJson(Map<String, dynamic> j) {
    final els = ((j['elements'] as List?) ?? const []).map((e) => SceneElement.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    // Number repeated lines so a correction to one copy never lands on another (#55).
    final seen = <String, int>{};
    for (final el in els) {
      final p = textPrefix60(el.text);
      el.occurrence = seen[p] ?? 0;
      seen[p] = el.occurrence + 1;
    }
    return Scene(
      number: (j['number'] as num).toInt(),
      title: j['title'] as String? ?? '',
      elementCount: (j['elementCount'] as num?)?.toInt() ?? els.length,
      elements: els,
    );
  }

  /// Unique speaking characters, in order of first line.
  List<String> get speakers {
    final seen = <String>{};
    final out = <String>[];
    for (final el in elements) {
      if (el.kind != 'dialog') continue;
      final names = el.isOverlap ? el.overlapCue! : [if (el.speaker != null) el.speaker!];
      for (final n in names) {
        if (seen.add(n)) out.add(n);
      }
    }
    return out;
  }
}

class CharacterSummary {
  CharacterSummary({required this.name, this.genderHint, this.roleHint});
  final String name;
  final String? genderHint;
  final String? roleHint;

  factory CharacterSummary.fromJson(Map<String, dynamic> j) =>
      CharacterSummary(name: j['name'] as String, genderHint: j['genderHint'] as String?, roleHint: j['roleHint'] as String?);
}

class ScriptSummary {
  ScriptSummary({
    required this.title,
    required this.sceneCount,
    required this.characterCount,
    required this.lineCount,
    required this.characters,
    required this.scenes,
  });

  final String title;
  final int sceneCount;
  final int characterCount;
  final int lineCount;
  final List<CharacterSummary> characters;
  final List<Scene> scenes;

  factory ScriptSummary.fromJson(Map<String, dynamic> j) => ScriptSummary(
    title: j['title'] as String? ?? '',
    sceneCount: (j['sceneCount'] as num?)?.toInt() ?? 0,
    characterCount: (j['characterCount'] as num?)?.toInt() ?? 0,
    lineCount: (j['lineCount'] as num?)?.toInt() ?? 0,
    characters: ((j['characters'] as List?) ?? const []).map((e) => CharacterSummary.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
    scenes: ((j['scenes'] as List?) ?? const []).map((e) => Scene.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
  );
}

// ---------------------------------------------------------------------------
// Corrections and user-added lines (same JSON as the Swift app)
// ---------------------------------------------------------------------------

DateTime _date(dynamic v) {
  if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
  if (v is num) {
    // Swift's default Date encoding: seconds since 2001-01-01.
    return DateTime.utc(2001).add(Duration(milliseconds: (v * 1000).round()));
  }
  return DateTime.now();
}

String isoDate(DateTime d) {
  final u = d.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

class ParserCorrection {
  ParserCorrection({
    required this.textKey,
    required this.pdfIdentifier,
    required this.sceneNumber,
    required this.originalKind,
    this.originalSpeaker,
    this.correctedKind,
    this.correctedSpeaker,
    this.correctedText,
    this.correctedOverlapTexts,
    this.correctedOverlapSpeakers,
    this.markedAsNoise = false,
    this.isSplit = false,
    this.removedVoiceIndex,
    DateTime? timestamp,
    this.contributed = false,
    this.uploaded = false,
    this.manualOverlapPartnerKey,
    this.occurrence,
  }) : timestamp = timestamp ?? DateTime.now();

  String textKey;
  String pdfIdentifier;
  int sceneNumber;
  String originalKind;
  String? originalSpeaker;
  String? correctedKind;
  String? correctedSpeaker; // "" = narrator
  String? correctedText;
  List<String>? correctedOverlapTexts;
  List<String>? correctedOverlapSpeakers;
  bool markedAsNoise;
  bool isSplit;
  int? removedVoiceIndex; // 0 left, 1 right, 2 both
  DateTime timestamp;
  bool contributed;
  bool uploaded;
  String? manualOverlapPartnerKey;
  int? occurrence;

  String get storageKey => correctionKey(pdfIdentifier, sceneNumber, textKey, occurrence ?? 0);

  bool get hasOtherData =>
      correctedKind != null ||
      correctedSpeaker != null ||
      correctedText != null ||
      correctedOverlapTexts != null ||
      correctedOverlapSpeakers != null ||
      markedAsNoise ||
      isSplit ||
      manualOverlapPartnerKey != null;

  ParserCorrection copy() => ParserCorrection.fromJson(toJson());

  factory ParserCorrection.fromJson(Map<String, dynamic> j) => ParserCorrection(
    textKey: j['textKey'] as String? ?? '',
    pdfIdentifier: j['pdfIdentifier'] as String? ?? '',
    sceneNumber: (j['sceneNumber'] as num?)?.toInt() ?? 0,
    originalKind: j['originalKind'] as String? ?? 'dialog',
    originalSpeaker: j['originalSpeaker'] as String?,
    correctedKind: j['correctedKind'] as String?,
    correctedSpeaker: j['correctedSpeaker'] as String?,
    correctedText: j['correctedText'] as String?,
    correctedOverlapTexts: (j['correctedOverlapTexts'] as List?)?.cast<String>(),
    correctedOverlapSpeakers: (j['correctedOverlapSpeakers'] as List?)?.cast<String>(),
    markedAsNoise: j['markedAsNoise'] as bool? ?? false,
    isSplit: j['isSplit'] as bool? ?? false,
    removedVoiceIndex: (j['removedVoiceIndex'] as num?)?.toInt(),
    timestamp: _date(j['timestamp']),
    contributed: j['contributed'] as bool? ?? false,
    uploaded: j['uploaded'] as bool? ?? false,
    manualOverlapPartnerKey: j['manualOverlapPartnerKey'] as String?,
    occurrence: (j['occurrence'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'textKey': textKey,
    'pdfIdentifier': pdfIdentifier,
    'sceneNumber': sceneNumber,
    'originalKind': originalKind,
    if (originalSpeaker != null) 'originalSpeaker': originalSpeaker,
    if (correctedKind != null) 'correctedKind': correctedKind,
    if (correctedSpeaker != null) 'correctedSpeaker': correctedSpeaker,
    if (correctedText != null) 'correctedText': correctedText,
    if (correctedOverlapTexts != null) 'correctedOverlapTexts': correctedOverlapTexts,
    if (correctedOverlapSpeakers != null) 'correctedOverlapSpeakers': correctedOverlapSpeakers,
    'markedAsNoise': markedAsNoise,
    'isSplit': isSplit,
    if (removedVoiceIndex != null) 'removedVoiceIndex': removedVoiceIndex,
    'timestamp': isoDate(timestamp),
    'contributed': contributed,
    'uploaded': uploaded,
    if (manualOverlapPartnerKey != null) 'manualOverlapPartnerKey': manualOverlapPartnerKey,
    if (occurrence != null) 'occurrence': occurrence,
  };
}

class UserAddedElement {
  UserAddedElement({
    String? id,
    required this.pdfPath,
    required this.sceneNumber,
    required this.afterElementTextKey,
    required this.speaker,
    required this.text,
    required this.kind,
    DateTime? timestamp,
    this.isSplitFragment = false,
  }) : id = id ?? const Uuid().v4().toUpperCase(),
       timestamp = timestamp ?? DateTime.now();

  final String id;
  String pdfPath;
  int sceneNumber;
  String afterElementTextKey;
  String speaker; // "" = narrator
  String text;
  String kind;
  DateTime timestamp;
  bool isSplitFragment;

  factory UserAddedElement.fromJson(Map<String, dynamic> j) => UserAddedElement(
    id: j['id'] as String?,
    pdfPath: j['pdfPath'] as String? ?? '',
    sceneNumber: (j['sceneNumber'] as num?)?.toInt() ?? 0,
    afterElementTextKey: j['afterElementTextKey'] as String? ?? '',
    speaker: j['speaker'] as String? ?? '',
    text: j['text'] as String? ?? '',
    kind: j['kind'] as String? ?? 'dialog',
    timestamp: _date(j['timestamp']),
    isSplitFragment: j['isSplitFragment'] as bool? ?? false,
  );

  UserAddedElement copy() => UserAddedElement.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'id': id,
    'pdfPath': pdfPath,
    'sceneNumber': sceneNumber,
    'afterElementTextKey': afterElementTextKey,
    'speaker': speaker,
    'text': text,
    'kind': kind,
    'timestamp': isoDate(timestamp),
    'isSplitFragment': isSplitFragment,
  };
}

/// One row in an expanded scene: a parsed line, a user-added line, or a
/// pair the user made simultaneous.
sealed class MergedElement {}

class ParsedItem extends MergedElement {
  ParsedItem(this.element);
  final SceneElement element;
}

class AddedItem extends MergedElement {
  AddedItem(this.element);
  final UserAddedElement element;
}

class ManualOverlapItem extends MergedElement {
  ManualOverlapItem(this.primary, this.secondary);
  final SceneElement primary;
  final SceneElement secondary;
}

// ---------------------------------------------------------------------------
// Projects (project.json in each project folder)
// ---------------------------------------------------------------------------

class Project {
  Project({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.lastOpenedAt,
    required this.pdfFilename,
    required this.scriptTitle,
    required this.voiceAssignment,
    required this.characterGenderOverrides,
    required this.corrections,
    required this.sceneTitleOverrides,
    required this.userAddedElements,
    required this.selectedEngine,
    required this.renderedScenes,
    Map<int, String>? renderFingerprints,
    Set<String>? checkedLines,
    this.folderPath,
    this.extra = const {},
  }) : renderFingerprints = renderFingerprints ?? {},
       checkedLines = checkedLines ?? {};

  final String id;
  String name;
  DateTime createdAt;
  DateTime lastOpenedAt;
  String pdfFilename;
  String scriptTitle;
  Map<String, String> voiceAssignment;
  Map<String, String> characterGenderOverrides;
  Map<String, ParserCorrection> corrections;
  Map<String, Map<int, String>> sceneTitleOverrides;
  Map<String, List<UserAddedElement>> userAddedElements;
  String selectedEngine;
  List<int> renderedScenes;

  /// Scene number → fingerprint of the scene's edits when it was last rendered.
  /// A scene needs re-rendering only while its current fingerprint differs.
  Map<int, String> renderFingerprints;

  /// Lines the parser was unsure about that the user confirmed as they are
  /// ("<scene>|<elementRef>"). Not an edit: no re-render needed.
  Set<String> checkedLines;

  /// Absolute path of the project folder. Not saved.
  String? folderPath;

  /// Keys we don't model, kept so saving never drops data.
  final Map<String, dynamic> extra;

  String? get pdfPath => (folderPath == null || pdfFilename.isEmpty) ? null : '$folderPath/$pdfFilename';

  factory Project.newProject(String name, String folderPath, {String engine = 'macOS'}) {
    final now = DateTime.now();
    return Project(
      id: const Uuid().v4().toUpperCase(),
      name: name,
      createdAt: now,
      lastOpenedAt: now,
      pdfFilename: '',
      scriptTitle: '',
      voiceAssignment: {},
      characterGenderOverrides: {},
      corrections: {},
      sceneTitleOverrides: {},
      userAddedElements: {},
      selectedEngine: engine,
      renderedScenes: [],
      folderPath: folderPath,
    );
  }

  static const _known = {
    'id',
    'name',
    'createdAt',
    'lastOpenedAt',
    'pdfFilename',
    'scriptTitle',
    'voiceAssignment',
    'characterGenderOverrides',
    'corrections',
    'sceneTitleOverrides',
    'userAddedElements',
    'selectedEngine',
    'renderFingerprints',
    'checkedLines',
    'renderedScenes',
  };

  factory Project.fromJson(Map<String, dynamic> j, {String? folderPath}) {
    Map<int, String> intKeyed(dynamic v) {
      final out = <int, String>{};
      if (v is Map) {
        v.forEach((k, val) {
          final n = int.tryParse('$k');
          if (n != null && val is String) out[n] = val;
        });
      } else if (v is List) {
        // Older Swift encoding of [Int: String]: [k, v, k, v, ...]
        for (var i = 0; i + 1 < v.length; i += 2) {
          final n = (v[i] as num?)?.toInt();
          if (n != null && v[i + 1] is String) out[n] = v[i + 1] as String;
        }
      }
      return out;
    }

    return Project(
      id: j['id'] as String,
      name: j['name'] as String? ?? 'Untitled Project',
      createdAt: _date(j['createdAt']),
      lastOpenedAt: _date(j['lastOpenedAt']),
      pdfFilename: j['pdfFilename'] as String? ?? '',
      scriptTitle: j['scriptTitle'] as String? ?? '',
      voiceAssignment: Map<String, String>.from((j['voiceAssignment'] as Map?) ?? const {}),
      characterGenderOverrides: Map<String, String>.from((j['characterGenderOverrides'] as Map?) ?? const {}),
      corrections: ((j['corrections'] as Map?) ?? const {}).map(
        (k, v) => MapEntry(k as String, ParserCorrection.fromJson(Map<String, dynamic>.from(v as Map))),
      ),
      sceneTitleOverrides: ((j['sceneTitleOverrides'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, intKeyed(v))),
      userAddedElements: ((j['userAddedElements'] as Map?) ?? const {}).map(
        (k, v) => MapEntry(k as String, (v as List).map((e) => UserAddedElement.fromJson(Map<String, dynamic>.from(e as Map))).toList()),
      ),
      selectedEngine: j['selectedEngine'] as String? ?? 'macOS',
      renderedScenes: ((j['renderedScenes'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
      renderFingerprints: intKeyed(j['renderFingerprints']),
      checkedLines: {for (final e in (j['checkedLines'] as List?) ?? const []) '$e'},
      folderPath: folderPath,
      extra: Map.fromEntries(j.entries.where((e) => !_known.contains(e.key))),
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      ...extra,
      'characterGenderOverrides': characterGenderOverrides,
      'corrections': corrections.map((k, v) => MapEntry(k, v.toJson())),
      'createdAt': isoDate(createdAt),
      'id': id,
      'lastOpenedAt': isoDate(lastOpenedAt),
      'name': name,
      'pdfFilename': pdfFilename,
      'renderedScenes': renderedScenes,
      if (renderFingerprints.isNotEmpty) 'renderFingerprints': renderFingerprints.map((n, f) => MapEntry('$n', f)),
      if (checkedLines.isNotEmpty) 'checkedLines': (checkedLines.toList()..sort()),
      'sceneTitleOverrides': sceneTitleOverrides.map((k, v) => MapEntry(k, v.map((n, t) => MapEntry('$n', t)))),
      'scriptTitle': scriptTitle,
      'selectedEngine': selectedEngine,
      'userAddedElements': userAddedElements.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      'voiceAssignment': voiceAssignment,
    };
    final sorted = m.keys.toList()..sort();
    return {for (final k in sorted) k: m[k]};
  }
}

class ArchivedProjectMeta {
  ArchivedProjectMeta({required this.project, required this.zipFilename, required this.originalFolderName, required this.metaPath});
  final Project project;
  final String zipFilename;
  final String originalFolderName;
  final String metaPath;
}

// ---------------------------------------------------------------------------
// Voices, engines, render events, cue maps
// ---------------------------------------------------------------------------

class VoiceSummary {
  VoiceSummary({required this.id, required this.label, this.gender, this.locale, this.note, required this.display});
  final String id;
  final String label;
  final String? gender;
  final String? locale;
  final String? note;
  final String display;

  factory VoiceSummary.fromJson(Map<String, dynamic> j) => VoiceSummary(
    id: j['id'] as String,
    label: j['label'] as String? ?? j['id'] as String,
    gender: j['gender'] as String?,
    locale: j['locale'] as String?,
    note: j['note'] as String?,
    display: j['display'] as String? ?? j['label'] as String? ?? j['id'] as String,
  );
}

class EngineStatus {
  EngineStatus({required this.installed, required this.sizeLabel, required this.canUninstall});
  final bool installed;
  final String sizeLabel;
  final bool canUninstall;

  factory EngineStatus.fromJson(Map<String, dynamic> j) =>
      EngineStatus(installed: j['installed'] as bool? ?? false, sizeLabel: j['sizeLabel'] as String? ?? '', canUninstall: j['canUninstall'] as bool? ?? false);
}

class GenerationEvent {
  GenerationEvent(this.raw);
  final Map<String, dynamic> raw;

  String get event => raw['event'] as String? ?? '';
  String? get level => raw['level'] as String?;
  String? get message => raw['message'] as String?;
  int? get sceneIndex => (raw['sceneIndex'] as num?)?.toInt();
  int? get totalScenes => (raw['totalScenes'] as num?)?.toInt();
  String? get sceneTitle => raw['sceneTitle'] as String?;
  int? get elementIndex => (raw['elementIndex'] as num?)?.toInt();
  int? get totalElements => (raw['totalElements'] as num?)?.toInt();
  String? get outputDir => raw['outputDir'] as String?;
  List<String> get files => ((raw['files'] as List?) ?? const []).cast<String>();
  List<String> get errors => ((raw['errors'] as List?) ?? const []).cast<String>();
  double? get seconds => (raw['seconds'] as num?)?.toDouble();
  double? get fraction => (raw['fraction'] as num?)?.toDouble();
  int? get sceneNumber => (raw['sceneNumber'] as num?)?.toInt();
  String? get cueFilePath => raw['cueFilePath'] as String?;
}

class SceneCue {
  SceneCue({required this.index, required this.kind, required this.speaker, required this.text, required this.startTime, required this.endTime, this.ref});
  final int index;

  /// The line's stable id (element ref, or "added:<id>"); null in cue maps
  /// written before Oct 2026.
  final String? ref;
  final String kind;
  final String speaker; // "__NARRATOR__" for narration; slash-joined for overlaps
  final String text;
  final double startTime;
  final double endTime;

  factory SceneCue.fromJson(Map<String, dynamic> j) => SceneCue(
    index: (j['index'] as num).toInt(),
    kind: j['kind'] as String? ?? 'dialog',
    speaker: j['speaker'] as String? ?? narratorKey,
    text: j['text'] as String? ?? '',
    startTime: (j['startTime'] as num).toDouble(),
    endTime: (j['endTime'] as num).toDouble(),
    ref: j['ref'] as String?,
  );
}

class SceneOutputInfo {
  SceneOutputInfo({required this.exists, required this.filename, required this.title});
  final bool exists;
  final String filename;
  final String title;
}

enum LogStyle { info, success, warning, error, debug }

class LogEntry {
  LogEntry(this.text, this.style) : timestamp = clockNow();
  final DateTime timestamp;
  final String text;
  final LogStyle style;

  String get timestampString {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:${two(timestamp.second)}';
  }
}
