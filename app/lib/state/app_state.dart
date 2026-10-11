// All app state and business rules for an open project.
// Port of Sources/TableRead/AppState.swift. Rules are kept the same on purpose:
// correction keys, line merging, undo/redo depth, voice casting by gender,
// stale-render detection and the render event handling.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/models.dart';
import '../services/platform.dart';
import '../services/project_store.dart';
import '../services/python_bridge.dart';
import '../services/settings.dart';
import '../theme/tokens.dart' show characterColorsEnabled;

class _Snapshot {
  _Snapshot(this.corrections, this.added);
  final Map<String, ParserCorrection> corrections;
  final Map<String, List<UserAddedElement>> added;
}

enum UpdateStage { idle, downloading, extracting, installing, failed }

class UpdateInfo {
  UpdateInfo({required this.version, required this.releaseNotes, required this.htmlUrl, required this.hasZipAsset});
  final String version;
  final String releaseNotes;
  final String htmlUrl;
  final bool hasZipAsset;
}

class AppState extends ChangeNotifier {
  AppState(this.settings, this.store, {bool startBackgroundTasks = true}) {
    bridge = PythonBridge(onPythonLog: (line) => dlog('[py] $line', LogStyle.debug));
    _loadSettings();
    if (startBackgroundTasks) {
      unawaited(refreshEngineStatus());
      Future.delayed(const Duration(seconds: 6), checkForUpdates);
    }
  }

  final Settings settings;
  final ProjectStore store;
  late final PythonBridge bridge;

  // Script
  String? pdfPath;
  ScriptSummary? script;
  bool isParsing = false;
  double parseFraction = 0;
  String parseMessage = '';

  /// True for a project that hasn't confirmed its cast yet; the workspace
  /// opens the Cast dialog after the parse.
  bool castPending = false;
  String? errorMessage;

  // Engines and voices
  EngineKind selectedEngine = EngineKind.macOS;
  Set<EngineKind> installedEngines = {EngineKind.macOS};
  Map<EngineKind, EngineStatus> engineStatuses = {};
  List<VoiceSummary> voices = [];
  bool isFetchingVoices = false;
  Map<String, String> voiceAssignment = {};
  Map<String, String> characterGenderOverrides = {};
  String? previewingVoiceId;
  String? preparingPreviewVoiceId;
  AudioPlayer? _preview;
  AudioPlayer get _previewPlayer => _preview ??= AudioPlayer();
  bool hasStoredOpenAIKey = false;
  String openAIKeyStatus = 'idle'; // idle | checking | valid | invalid
  String? openAIKeyError;
  EngineKind? installingEngine;
  EngineKind? uninstallingEngine;
  double? installProgress;

  // Scene selection and rendering
  Set<int> selectedScenes = {};
  bool isGenerating = false;
  bool isPaused = false;
  double generationProgress = 0;
  List<int> renderingSceneNumbers = [];
  Map<int, double> sceneProgress = {};
  final List<LogEntry> generationLog = [];
  final List<LogEntry> debugLog = [];
  String? outputDirectory;
  Map<int, SceneOutputInfo> sceneFileInfo = {};
  Map<int, String> sceneCueFiles = {};
  Set<int> scenesNeedingRerender = {};

  /// Fingerprint of each rendered scene's edits at render time (saved in project.json).
  Map<int, String> renderFingerprints = {};
  Map<int, String> _renderingFingerprints = {};
  final Set<int> _provisionalFingerprints = {};
  String? backgroundRenderProjectId;

  // Edits
  Map<String, ParserCorrection> corrections = {};
  Map<String, Map<int, String>> sceneTitleOverrides = {};
  Map<String, List<UserAddedElement>> userAddedElements = {};
  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];
  int _suppressUndo = 0;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoCount => _undo.length;

  // Settings
  bool autoOpenFinderAfterRender = false;
  bool contributeCorrections = false;
  bool notifyOnSceneComplete = false;
  bool notifyOnRenderComplete = false;
  bool notifyOnRenderFailed = false;
  String updateChannel = 'beta';

  // Updates
  UpdateInfo? availableUpdate;
  UpdateStage updateStage = UpdateStage.idle;
  double updateFraction = 0;
  String? updateError;
  bool didPromptForUpdate = false;

  // Sheets the app shell shows (single window: everything is a sheet).
  final ValueNotifier<String?> sheetRequest = ValueNotifier(null);

  List<Scene> get scenes => script?.scenes ?? const [];
  List<String> get allSpeakers => ['Narrator', ...?script?.characters.map((c) => c.name)];
  String? get currentProjectFolder => store.currentProject?.folderPath;

  bool characterColors = true;

  void setCharacterColors(bool v) {
    characterColors = v;
    characterColorsEnabled = v;
    settings.setBool('characterHighlightColors', v);
    notifyListeners();
  }

  void _loadSettings() {
    characterColors = settings.getBool('characterHighlightColors', fallback: true);
    characterColorsEnabled = characterColors;
    autoOpenFinderAfterRender = settings.getBool('autoOpenFinderAfterRender');
    contributeCorrections = settings.getBool('contributeCorrections');
    notifyOnSceneComplete = settings.getBool('notifyOnSceneComplete');
    notifyOnRenderComplete = settings.getBool('notifyOnRenderComplete');
    notifyOnRenderFailed = settings.getBool('notifyOnRenderFailed');
    updateChannel = settings.getString('updateChannel') ?? 'beta';
    outputDirectory = settings.getString('lastOutputDirectory');
    hasStoredOpenAIKey = settings.getBool('openAIKeyStored');
    if (hasStoredOpenAIKey) installedEngines.add(EngineKind.openAI);
  }

  void setSetting(String key, bool value) {
    switch (key) {
      case 'autoOpenFinderAfterRender':
        autoOpenFinderAfterRender = value;
      case 'contributeCorrections':
        contributeCorrections = value;
      case 'notifyOnSceneComplete':
        notifyOnSceneComplete = value;
      case 'notifyOnRenderComplete':
        notifyOnRenderComplete = value;
      case 'notifyOnRenderFailed':
        notifyOnRenderFailed = value;
    }
    settings.setBool(key, value);
    notifyListeners();
  }

  void setUpdateChannel(String c) {
    updateChannel = c;
    settings.setString('updateChannel', c);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Logs
  // ---------------------------------------------------------------------------

  void appendLog(String text, LogStyle style) {
    generationLog.add(LogEntry(text, style));
    dlog(text, style);
  }

  void dlog(String text, [LogStyle style = LogStyle.debug]) {
    debugLog.add(LogEntry(text, style));
    if (debugLog.length > 2000) debugLog.removeRange(0, debugLog.length - 2000);
    notifyListeners();
  }

  void clearDebugLog() {
    debugLog.clear();
    notifyListeners();
  }

  void showError(String message) {
    errorMessage = message;
    dlog(message, LogStyle.error);
    notifyListeners();
  }

  /// Rebuild listeners after a direct field change.
  void refresh() => notifyListeners();

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Project lifecycle
  // ---------------------------------------------------------------------------

  void loadFromProject(Project p) {
    resetForNewProject();
    voiceAssignment = Map.of(p.voiceAssignment);
    characterGenderOverrides = Map.of(p.characterGenderOverrides);
    corrections = Map.of(p.corrections);
    sceneTitleOverrides = {for (final e in p.sceneTitleOverrides.entries) e.key: Map.of(e.value)};
    userAddedElements = {for (final e in p.userAddedElements.entries) e.key: List.of(e.value)};
    selectedEngine = EngineKind.fromId(p.selectedEngine) ?? EngineKind.macOS;
    renderFingerprints = Map.of(p.renderFingerprints);
    castPending = p.voiceAssignment.isEmpty && !settings.getBool('castConfirmed.${p.id}');
    final pdf = p.pdfPath;
    if (pdf != null) importPDF(pdf);
  }

  void resetForNewProject() {
    _undo.clear();
    _redo.clear();
    corrections = {};
    sceneTitleOverrides = {};
    userAddedElements = {};
    characterGenderOverrides = {};
    voices = [];
    voiceAssignment = {};
    selectedScenes = {};
    if (!isGenerating) {
      script = null;
      pdfPath = null;
      generationLog.clear();
      generationProgress = 0;
      sceneProgress = {};
      renderingSceneNumbers = [];
      sceneFileInfo = {};
      sceneCueFiles = {};
      scenesNeedingRerender = {};
      renderFingerprints = {};
    }
    notifyListeners();
  }

  Project _syncToProject(Project p) {
    p.voiceAssignment = Map.of(voiceAssignment);
    p.characterGenderOverrides = Map.of(characterGenderOverrides);
    p.corrections = Map.of(corrections);
    p.sceneTitleOverrides = {for (final e in sceneTitleOverrides.entries) e.key: Map.of(e.value)};
    p.userAddedElements = {for (final e in userAddedElements.entries) e.key: List.of(e.value)};
    p.selectedEngine = selectedEngine.id;
    p.renderedScenes = [
      for (final e in sceneFileInfo.entries)
        if (e.value.exists) e.key,
    ]..sort();
    final title = script?.title ?? '';
    if (title.isNotEmpty) p.scriptTitle = title;
    return p;
  }

  void persistProject() {
    final p = store.currentProject;
    if (p == null) return;
    store.saveProject(_syncToProject(p));
  }

  void returnToGallery() {
    persistProject();
    if (isGenerating) backgroundRenderProjectId = store.currentProject?.id;
    resetForNewProject();
    store.closeProject();
    store.loadAllProjects();
  }

  // ---------------------------------------------------------------------------
  // Parse
  // ---------------------------------------------------------------------------

  Future<void> importPDF(String path) async {
    dlog('importPDF: ${path.split('/').last}', LogStyle.info);
    pdfPath = path;
    outputDirectory = currentProjectFolder;
    sceneFileInfo = {};
    sceneCueFiles = {};
    isParsing = true;
    parseFraction = 0;
    parseMessage = 'Opening the PDF';
    errorMessage = null;
    notifyListeners();
    final sw = Stopwatch()..start();
    try {
      final parsed = await bridge.parse(
        path,
        onProgress: (f, m) {
          parseFraction = f;
          parseMessage = m;
          notifyListeners();
        },
      );
      parseFraction = 1;
      script = parsed;
      selectedScenes = parsed.scenes.map((s) => s.number).toSet();
      dlog(
        'parse finished · ${parsed.sceneCount} scenes, ${parsed.characterCount} characters, ${parsed.lineCount} lines (${sw.elapsedMilliseconds} ms)',
        LogStyle.success,
      );
      checkRenderedScenes();
      persistProject();
      fetchVoices();
    } catch (e) {
      showError(e.toString());
    }
    isParsing = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Engines and voices
  // ---------------------------------------------------------------------------

  Future<void> refreshEngineStatus() async {
    try {
      final st = await bridge.engineStatus();
      engineStatuses = st;
      installedEngines = {
        EngineKind.macOS,
        for (final e in st.entries)
          if (e.value.installed) e.key,
        if (hasStoredOpenAIKey) EngineKind.openAI,
      };
      notifyListeners();
    } catch (e) {
      dlog('engineStatus failed: $e', LogStyle.warning);
    }
  }

  void selectEngine(EngineKind e) {
    if (selectedEngine == e) return;
    selectedEngine = e;
    voices = [];
    _refreshEdited();
    notifyListeners();
    persistProject();
    fetchVoices();
  }

  Future<void> fetchVoices() async {
    final engine = selectedEngine;
    isFetchingVoices = true;
    notifyListeners();
    dlog('voices · ${engine.title}', LogStyle.info);
    try {
      final (list, auto) = await bridge.voices(engine, pdfPath: pdfPath);
      if (selectedEngine != engine) return;
      voices = list;
      var applied = 0;
      auto.forEach((char, voice) {
        if (!voiceAssignment.containsKey(char)) {
          voiceAssignment[char] = voice;
          applied++;
        }
      });
      dlog('voices · ${list.length} available, $applied auto-assigned', LogStyle.info);
      // Fingerprints seeded before the voices arrived describe the scene
      // without its auto-assigned voices; re-seed them now so the voices
      // filled in for an old render don't count as an edit.
      for (final n in _provisionalFingerprints) {
        renderFingerprints[n] = sceneFingerprint(n);
      }
      _provisionalFingerprints.clear();
      _refreshEdited();
      persistProject();
    } catch (e) {
      if (selectedEngine == engine) dlog('voices failed: $e', LogStyle.error);
    } finally {
      if (selectedEngine == engine) {
        isFetchingVoices = false;
        notifyListeners();
      }
    }
  }

  void assignVoice(String characterKey, String voiceId) {
    voiceAssignment[characterKey] = voiceId;
    _refreshEdited();
    notifyListeners();
    persistProject();
  }

  String effectiveGender(String characterKey, String? hint) => characterGenderOverrides[characterKey] ?? hint ?? 'N';

  /// Sets a character's gender and picks a matching voice if the current one
  /// doesn't fit (round-robin over voices other characters don't use).
  void setCharacterGender(String gender, String characterKey) {
    characterGenderOverrides[characterKey] = gender;
    final List<VoiceSummary> pool = switch (gender) {
      'M' => voices.where((v) => v.gender == 'M').toList(),
      'F' => voices.where((v) => v.gender == 'F').toList(),
      _ => (List.of(voices)..shuffle(math.Random())),
    };
    if (pool.isNotEmpty) {
      final current = voices.where((v) => v.id == voiceAssignment[characterKey]).firstOrNull;
      final fits = switch (gender) {
        'M' => current?.gender == 'M',
        'F' => current?.gender == 'F',
        _ => current != null,
      };
      if (!fits) {
        final taken = {
          for (final e in voiceAssignment.entries)
            if (e.key != characterKey) e.value,
        };
        voiceAssignment[characterKey] = (pool.where((v) => !taken.contains(v.id)).firstOrNull ?? pool.first).id;
      }
    }
    _refreshEdited();
    notifyListeners();
    persistProject();
  }

  Future<void> toggleVoicePreview(VoiceSummary voice) async {
    if (previewingVoiceId == voice.id) {
      await _previewPlayer.stop();
      previewingVoiceId = null;
      notifyListeners();
      return;
    }
    await _previewPlayer.stop();
    previewingVoiceId = null;
    preparingPreviewVoiceId = voice.id;
    notifyListeners();
    try {
      String? key;
      if (selectedEngine == EngineKind.openAI) key = await NativePlatform.keychainRead('openai_api_key');
      final path = await bridge.previewVoice(selectedEngine, voice.id, apiKey: key);
      preparingPreviewVoiceId = null;
      previewingVoiceId = voice.id;
      notifyListeners();
      await _previewPlayer.setFilePath(path);
      await _previewPlayer.play();
      await _previewPlayer.playerStateStream.firstWhere((s) => s.processingState == ProcessingState.completed);
    } catch (e) {
      dlog('preview failed: $e', LogStyle.error);
    }
    preparingPreviewVoiceId = null;
    if (previewingVoiceId == voice.id) previewingVoiceId = null;
    notifyListeners();
  }

  Future<void> saveOpenAIKey(String key) async {
    if (key.trim().isEmpty) {
      await NativePlatform.keychainDelete('openai_api_key');
      hasStoredOpenAIKey = false;
      installedEngines.remove(EngineKind.openAI);
    } else {
      await NativePlatform.keychainWrite('openai_api_key', key.trim());
      hasStoredOpenAIKey = true;
      installedEngines.add(EngineKind.openAI);
    }
    await settings.setBool('openAIKeyStored', hasStoredOpenAIKey);
    openAIKeyStatus = 'idle';
    notifyListeners();
  }

  Future<void> testOpenAIKey() async {
    openAIKeyStatus = 'checking';
    notifyListeners();
    try {
      final key = await NativePlatform.keychainRead('openai_api_key') ?? '';
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('https://api.openai.com/v1/models'));
      req.headers.set('Authorization', 'Bearer $key');
      final res = await req.close().timeout(const Duration(seconds: 15));
      await res.drain<void>();
      client.close();
      if (res.statusCode == 200) {
        openAIKeyStatus = 'valid';
      } else {
        openAIKeyStatus = 'invalid';
        openAIKeyError = res.statusCode == 401 ? 'The key was rejected by OpenAI.' : 'OpenAI returned status ${res.statusCode}.';
      }
    } catch (e) {
      openAIKeyStatus = 'invalid';
      openAIKeyError = 'Could not reach OpenAI: $e';
    }
    notifyListeners();
  }

  Future<void> installEngine(EngineKind e) async {
    installingEngine = e;
    installProgress = null;
    notifyListeners();
    try {
      await bridge.installEngine(e, (ev) {
        if (ev.fraction != null) installProgress = ev.fraction;
        if (ev.message != null) dlog(ev.message!, LogStyle.info);
        notifyListeners();
      });
    } catch (err) {
      showError('Could not install ${e.title}: $err');
    }
    installingEngine = null;
    installProgress = null;
    await refreshEngineStatus();
  }

  void cancelInstall() {
    bridge.cancel();
  }

  Future<void> uninstallEngine(EngineKind e) async {
    uninstallingEngine = e;
    notifyListeners();
    try {
      await bridge.uninstallEngine(e);
    } catch (err) {
      showError('Could not remove ${e.title}: $err');
    }
    uninstallingEngine = null;
    await refreshEngineStatus();
  }

  /// The user confirmed the Cast dialog for this project.
  void confirmCast() {
    castPending = false;
    final id = store.currentProject?.id;
    if (id != null) settings.setBool('castConfirmed.$id', true);
    persistProject();
    notifyListeners();
  }

  /// Per-project view state (open scenes, rehearsal settings), kept in app
  /// preferences rather than the project file.
  Map<String, dynamic> loadView() {
    final id = store.currentProject?.id;
    final raw = id == null ? null : settings.getString('view.$id');
    if (raw == null) return const {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return const {};
    }
  }

  void saveView(Map<String, dynamic> view) {
    final id = store.currentProject?.id;
    if (id != null) settings.setString('view.$id', jsonEncode(view));
  }

  /// Lines per character (dialogue only; a simultaneous line counts for each voice).
  Map<String, int> get lineCounts {
    final out = <String, int>{};
    for (final s in scenes) {
      for (final el in s.elements) {
        if (el.kind != 'dialog') {
          out[narratorKey] = (out[narratorKey] ?? 0) + 1;
          continue;
        }
        for (final n in el.isOverlap ? el.overlapCue! : [el.speaker ?? narratorKey]) {
          out[n] = (out[n] ?? 0) + 1;
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Scene selection
  // ---------------------------------------------------------------------------

  void toggleScene(int n) {
    selectedScenes.contains(n) ? selectedScenes.remove(n) : selectedScenes.add(n);
    notifyListeners();
  }

  void selectAllScenes() {
    selectedScenes = scenes.map((s) => s.number).toSet();
    notifyListeners();
  }

  void clearSceneSelection() {
    selectedScenes = {};
    notifyListeners();
  }

  void selectMissingScenes() {
    checkRenderedScenes();
    final missing = {
      for (final s in scenes)
        if (sceneFileInfo[s.number]?.exists != true) s.number,
    };
    if (missing.isNotEmpty) selectedScenes = missing;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  String defaultOutputDirectory(String pdf) {
    final folder = currentProjectFolder;
    if (folder != null) return folder;
    final dir = File(pdf).parent.path;
    final stem = pdf.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
    return '$dir/$stem - table read';
  }

  /// Must match scene_filename() in audio_pipeline.py (checked by test/worker_test.dart).
  static String sceneFilename(int number, String title) {
    var s = title.trim();
    s = s.replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}_\s\-]', unicode: true), ''); // Python's [^\w\s\-]
    s = s.replaceAll(RegExp(r'[\s\-]+'), '_');
    s = s.replaceAll(RegExp(r'^_+|_+$'), '');
    final chars = s.runes.toList();
    final part = chars.isEmpty ? 'Scene' : String.fromCharCodes(chars.take(60));
    return 'Scene_${number.toString().padLeft(2, '0')}_$part.m4a';
  }

  void checkRenderedScenes() {
    final pdf = pdfPath;
    if (pdf == null || script == null) return;
    final out = outputDirectory ?? defaultOutputDirectory(pdf);
    final info = <int, SceneOutputInfo>{};
    final cues = <int, String>{};
    for (final s in scenes) {
      final name = sceneFilename(s.number, s.title);
      final cue = name.replaceAll('.m4a', '.cues.json');
      info[s.number] = SceneOutputInfo(exists: File('$out/$name').existsSync(), filename: name, title: s.title);
      if (File('$out/$cue').existsSync()) cues[s.number] = '$out/$cue';
    }
    sceneFileInfo = info;
    sceneCueFiles = cues;
    // Scenes rendered before fingerprints existed are assumed up to date.
    for (final e in info.entries) {
      if (e.value.exists && !renderFingerprints.containsKey(e.key)) {
        renderFingerprints[e.key] = sceneFingerprint(e.key);
        _provisionalFingerprints.add(e.key);
      }
    }
    _refreshEdited();
    notifyListeners();
  }

  void renderSelectedScenes() => startGeneration((selectedScenes.toList()..sort()));

  void renderPreviewScene() {
    final first = scenes.where((s) => selectedScenes.contains(s.number)).firstOrNull;
    if (first == null) return showError('Select at least one scene first.');
    startGeneration([first.number]);
  }

  void rerenderEditedScenes() {
    selectedScenes = Set.of(scenesNeedingRerender);
    renderSelectedScenes();
  }

  Future<void> startGeneration(List<int> sceneNumbers) async {
    final pdf = pdfPath;
    if (pdf == null) return showError('Open a PDF before generating audio.');
    if (sceneNumbers.isEmpty) return showError('Select at least one scene to render.');
    if (!installedEngines.contains(selectedEngine)) {
      return showError('${selectedEngine.title} is not installed. Install it in Settings → Engines.');
    }
    final out = outputDirectory ?? defaultOutputDirectory(pdf);
    outputDirectory = out;
    settings.setString('lastOutputDirectory', out);
    generationLog.clear();
    generationProgress = 0;
    isPaused = false;
    renderingSceneNumbers = sceneNumbers;
    _renderingFingerprints = {for (final n in sceneNumbers) n: sceneFingerprint(n)};
    sceneProgress = {for (final n in sceneNumbers) n: 0.0};
    isGenerating = true;
    backgroundRenderProjectId = null;
    appendLog('generate · ${sceneNumbers.length} scene${sceneNumbers.length == 1 ? '' : 's'} → $out', LogStyle.info);
    notifyListeners();
    String? apiKey;
    if (selectedEngine == EngineKind.openAI) apiKey = await NativePlatform.keychainRead('openai_api_key');
    try {
      await bridge.generate(
        pdfPath: pdf,
        outputDir: out,
        engine: selectedEngine,
        sceneNumbers: sceneNumbers,
        assignment: voiceAssignment,
        apiKey: apiKey,
        userAddedElements: userAddedElements,
        corrections: corrections.values.where((c) => c.pdfIdentifier == pdf).toList(),
        onEvent: _handleEvent,
      );
    } catch (e) {
      if (isGenerating) {
        appendLog(e.toString(), LogStyle.error);
        showError(e.toString());
      }
    }
    isGenerating = false;
    isPaused = false;
    notifyListeners();
  }

  void cancelGeneration() {
    if (!isGenerating) return;
    appendLog('Cancel requested. Stopping the current render job.', LogStyle.warning);
    bridge.cancel();
    isGenerating = false;
    isPaused = false;
    backgroundRenderProjectId = null;
    notifyListeners();
  }

  void togglePause() {
    if (!isGenerating) return;
    if (isPaused) {
      bridge.resume();
      isPaused = false;
      appendLog('Render resumed.', LogStyle.info);
    } else {
      bridge.pause();
      isPaused = true;
      appendLog('Render paused.', LogStyle.warning);
    }
    notifyListeners();
  }

  void _handleEvent(GenerationEvent ev) {
    switch (ev.event) {
      case 'started':
        appendLog(ev.message ?? 'Generation started.', LogStyle.info);
      case 'progress':
        final si = ev.sceneIndex, ts = ev.totalScenes;
        if (si != null && ts != null && ts > 0 && si >= 0 && si < renderingSceneNumbers.length) {
          final n = renderingSceneNumbers[si];
          final ei = ev.elementIndex;
          if (ei != null && ei >= 0 && (ev.totalElements ?? 0) > 0) {
            final frac = (ei + 1) / ev.totalElements!;
            sceneProgress[n] = math.min(frac, 0.99);
            generationProgress = (si + frac) / ts;
          } else if (ei == -1) {
            if ((ev.message ?? '').startsWith('✓')) {
              sceneProgress[n] = 1.0;
              _markRendered(n);
            }
            generationProgress = (si + 1) / ts;
          }
        }
        final m = ev.message;
        if (m != null && m.isNotEmpty) {
          appendLog(m, m.toLowerCase().contains('error') ? LogStyle.error : LogStyle.info);
        } else if (ev.elementIndex != null && ev.totalElements != null && ev.elementIndex! >= 0) {
          final si2 = ev.sceneIndex ?? 0;
          final n = si2 < renderingSceneNumbers.length ? renderingSceneNumbers[si2] : si2 + 1;
          appendLog(
            'generate · Scene ${n.toString().padLeft(2, '0')} ${ev.sceneTitle ?? ''} · element ${ev.elementIndex! + 1}/${ev.totalElements}',
            LogStyle.debug,
          );
        }
      case 'log':
        appendLog(ev.message ?? '', switch (ev.level) {
          'success' => LogStyle.success,
          'warning' || 'warn' => LogStyle.warning,
          'error' => LogStyle.error,
          _ => LogStyle.info,
        });
      case 'done':
        generationProgress = 1;
        final errs = ev.errors;
        final secs = (ev.seconds ?? 0).round();
        appendLog(
          '${errs.isEmpty ? 'Done' : 'Finished with errors'}. Wrote ${ev.files.length} file(s) in ${secs < 60 ? '${secs}s' : '${secs ~/ 60}m ${secs % 60}s'}.',
          errs.isEmpty ? LogStyle.success : LogStyle.error,
        );
        for (final e in errs) {
          appendLog(e, LogStyle.error);
        }
        if (errs.isEmpty) {
          checkRenderedScenes();
          final bg = backgroundRenderProjectId;
          if (bg != null) {
            backgroundRenderProjectId = null;
            store.loadAllProjects();
          } else {
            persistProject();
          }
          final dir = ev.outputDir;
          if (autoOpenFinderAfterRender && dir != null) NativePlatform.openPath(dir);
        }
      case 'cueMap':
        final n = ev.sceneNumber, p = ev.cueFilePath;
        if (n != null && p != null) {
          sceneCueFiles[n] = p;
          _markRendered(n);
          checkRenderedScenes();
        }
      default:
        appendLog(ev.message ?? ev.event, LogStyle.info);
    }
    notifyListeners();
  }

  String get latestRenderLine {
    for (final l in generationLog.reversed) {
      if (l.text.trim().isNotEmpty) return l.text;
    }
    return 'Starting…';
  }

  // ---------------------------------------------------------------------------
  // Scene titles
  // ---------------------------------------------------------------------------

  String effectiveSceneTitle(Scene s) => sceneTitleOverrides[pdfPath ?? '']?[s.number] ?? s.title;

  void setSceneTitle(Scene s, String title) {
    final pdf = pdfPath;
    if (pdf == null) return;
    _pushUndo();
    final byPdf = sceneTitleOverrides.putIfAbsent(pdf, () => {});
    final t = title.trim();
    if (t.isEmpty) {
      byPdf.remove(s.number);
    } else {
      byPdf[s.number] = t;
    }
    notifyListeners();
    persistProject();
  }

  // ---------------------------------------------------------------------------
  // Undo / redo (corrections and added lines; 50 steps)
  // ---------------------------------------------------------------------------

  _Snapshot _snapshot() => _Snapshot(
    {for (final e in corrections.entries) e.key: e.value.copy()},
    {
      for (final e in userAddedElements.entries) e.key: [for (final a in e.value) a.copy()],
    },
  );

  void _pushUndo() {
    if (_suppressUndo > 0) return;
    _undo.add(_snapshot());
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_snapshot());
    final s = _undo.removeLast();
    corrections = s.corrections;
    userAddedElements = s.added;
    _refreshEdited();
    notifyListeners();
    persistProject();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_snapshot());
    final s = _redo.removeLast();
    corrections = s.corrections;
    userAddedElements = s.added;
    _refreshEdited();
    notifyListeners();
    persistProject();
  }

  // ---------------------------------------------------------------------------
  // Corrections
  // ---------------------------------------------------------------------------

  ParserCorrection? correctionFor(int sceneNumber, SceneElement el) => corrections[correctionKey(pdfPath ?? '', sceneNumber, el.text, el.occurrence)];

  void markSceneDirtyIfRendered(int n) => _refreshEdited(only: n);

  /// Fingerprint of everything in a scene that changes what is voiced:
  /// corrections and non-empty added lines. Timestamps and ids are left out, so
  /// undoing an edit, or editing a line back, returns the original fingerprint.
  String sceneFingerprint(int n) {
    final pdf = pdfPath ?? '';
    final corr = corrections.values.where((c) => c.pdfIdentifier == pdf && c.sceneNumber == n).toList()..sort((a, b) => a.storageKey.compareTo(b.storageKey));
    final added = (userAddedElements[addedKey(n)] ?? const <UserAddedElement>[]).where((a) => a.text.trim().isNotEmpty).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Everyone who speaks in the scene, after corrections, plus the narrator.
    final scene = scenes.where((s) => s.number == n).firstOrNull;
    final speakers = <String>{
      narratorKey,
      ...?scene?.speakers,
      for (final c in corr) ...[if (c.correctedSpeaker?.isNotEmpty ?? false) c.correctedSpeaker!, ...?c.correctedOverlapSpeakers],
      for (final a in added)
        if (a.speaker.isNotEmpty) a.speaker,
    }.toList()..sort();
    final canon = jsonEncode([
      selectedEngine.id,
      for (final sp in speakers) [sp, voiceAssignment[sp]],
      for (final c in corr)
        [
          c.storageKey,
          c.correctedKind,
          c.correctedSpeaker,
          c.correctedText,
          c.correctedOverlapTexts,
          c.correctedOverlapSpeakers,
          c.markedAsNoise,
          c.removedVoiceIndex,
          c.manualOverlapPartnerKey,
        ],
      for (final a in added) [a.afterElementTextKey, a.speaker, a.kind, a.text],
    ]);
    var h = 0xcbf29ce484222325; // FNV-1a, 64-bit
    for (final b in utf8.encode(canon)) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toUnsigned(64).toRadixString(16);
  }

  void _markRendered(int n) {
    final fp = _renderingFingerprints[n];
    if (fp != null) renderFingerprints[n] = fp;
    _refreshEdited(only: n);
  }

  /// A rendered scene needs re-rendering only while its edits differ from the render.
  void _refreshEdited({int? only}) {
    final numbers = only != null ? [only] : scenes.map((s) => s.number);
    for (final n in numbers) {
      final rendered = sceneFileInfo[n]?.exists == true;
      final fp = renderFingerprints[n];
      if (rendered && fp != null && fp != sceneFingerprint(n)) {
        scenesNeedingRerender.add(n);
      } else {
        scenesNeedingRerender.remove(n);
      }
    }
  }

  void saveCorrection(ParserCorrection c) {
    _pushUndo();
    corrections[c.storageKey] = c;
    markSceneDirtyIfRendered(c.sceneNumber);
    notifyListeners();
    persistProject();
  }

  void deleteCorrection(int sceneNumber, SceneElement el) {
    _pushUndo();
    corrections.remove(correctionKey(pdfPath ?? '', sceneNumber, el.text, el.occurrence));
    markSceneDirtyIfRendered(sceneNumber);
    notifyListeners();
    persistProject();
  }

  ParserCorrection _base(int sceneNumber, SceneElement el) {
    final existing = correctionFor(sceneNumber, el);
    return existing?.copy() ??
        ParserCorrection(
          textKey: el.text,
          pdfIdentifier: pdfPath ?? '',
          sceneNumber: sceneNumber,
          originalKind: el.kind,
          originalSpeaker: el.speaker,
          contributed: contributeCorrections,
          occurrence: el.occurrence,
        );
  }

  /// Saves an edit from the "Correct this line" popover.
  void correctLine(int sceneNumber, SceneElement el, {required String kind, String? speaker, String? text, List<String>? overlapTexts, required bool removed}) {
    final c = _base(sceneNumber, el)..timestamp = DateTime.now();
    c.correctedKind = kind == el.kind ? null : kind;
    if (kind == 'dialog' && speaker != null) {
      final narr = speaker == 'Narrator' ? '' : speaker;
      c.correctedSpeaker = (narr == (el.speaker ?? '')) ? null : narr;
    } else if (kind != 'dialog') {
      c.correctedSpeaker = null;
    }
    c.correctedText = (text == null || text == el.text) ? null : text;
    if (overlapTexts != null) {
      final orig = el.overlapTexts;
      c.correctedOverlapTexts = (orig != null && listEquals(orig, overlapTexts)) ? null : overlapTexts;
    }
    c.markedAsNoise = removed;
    if (!c.hasOtherData && c.removedVoiceIndex == null) {
      deleteCorrection(sceneNumber, el);
    } else {
      saveCorrection(c);
    }
  }

  void toggleRemoved(int sceneNumber, SceneElement el) {
    final existing = correctionFor(sceneNumber, el);
    final c = _base(sceneNumber, el)
      ..markedAsNoise = !(existing?.markedAsNoise ?? false)
      ..timestamp = DateTime.now();
    if (!c.hasOtherData && c.removedVoiceIndex == null) {
      deleteCorrection(sceneNumber, el);
    } else {
      saveCorrection(c);
    }
  }

  void removeLines(int sceneNumber, List<SceneElement> els, List<String> addedIds) {
    _pushUndo();
    _suppressUndo++;
    for (final el in els) {
      final c = _base(sceneNumber, el)
        ..markedAsNoise = true
        ..timestamp = DateTime.now();
      corrections[c.storageKey] = c;
    }
    final key = addedKey(sceneNumber);
    userAddedElements[key]?.removeWhere((a) => addedIds.contains(a.id));
    if (userAddedElements[key]?.isEmpty ?? false) userAddedElements.remove(key);
    markSceneDirtyIfRendered(sceneNumber);
    _suppressUndo--;
    notifyListeners();
    persistProject();
  }

  void reassignSpeaker(int sceneNumber, List<SceneElement> els, List<String> addedIds, String speaker) {
    _pushUndo();
    _suppressUndo++;
    final narr = speaker == 'Narrator' ? '' : speaker;
    for (final el in els) {
      if (el.kind != 'dialog') continue;
      final c = _base(sceneNumber, el)
        ..correctedSpeaker = narr
        ..timestamp = DateTime.now();
      corrections[c.storageKey] = c;
    }
    for (final a in userAddedElements[addedKey(sceneNumber)] ?? const <UserAddedElement>[]) {
      if (addedIds.contains(a.id) && a.kind == 'dialog') a.speaker = narr;
    }
    markSceneDirtyIfRendered(sceneNumber);
    _suppressUndo--;
    notifyListeners();
    persistProject();
  }

  // Simultaneous lines ---------------------------------------------------------

  void makeSimultaneous(int sceneNumber, SceneElement primary, SceneElement secondary) {
    final c = _base(sceneNumber, primary)
      ..manualOverlapPartnerKey = secondary.ref
      ..timestamp = DateTime.now();
    saveCorrection(c);
  }

  void breakSimultaneous(int sceneNumber, SceneElement primary) {
    final existing = correctionFor(sceneNumber, primary);
    if (existing == null) return;
    final c = existing.copy()
      ..manualOverlapPartnerKey = null
      ..timestamp = DateTime.now();
    if (c.correctedKind != null || c.correctedSpeaker != null || c.correctedText != null || c.correctedOverlapTexts != null || c.markedAsNoise) {
      saveCorrection(c);
    } else {
      deleteCorrection(sceneNumber, primary);
    }
  }

  void splitParserOverlap(int sceneNumber, SceneElement el) {
    _pushUndo();
    _suppressUndo++;
    final existing = correctionFor(sceneNumber, el);
    final c = _base(sceneNumber, el)
      ..markedAsNoise = true
      ..isSplit = true
      ..timestamp = DateTime.now();
    corrections[c.storageKey] = c;
    final cue = existing?.correctedOverlapSpeakers ?? el.overlapCue ?? const <String>[];
    final texts = existing?.correctedOverlapTexts ?? el.overlapTexts ?? List.filled(cue.length, el.text);
    for (var i = 0; i < cue.length; i++) {
      userAddedElements
          .putIfAbsent(addedKey(sceneNumber), () => [])
          .add(
            UserAddedElement(
              pdfPath: pdfPath ?? '',
              sceneNumber: sceneNumber,
              afterElementTextKey: el.ref,
              speaker: cue[i],
              text: i < texts.length ? texts[i] : el.text,
              kind: 'dialog',
              timestamp: DateTime.now().add(Duration(milliseconds: i)),
              isSplitFragment: true,
            ),
          );
    }
    markSceneDirtyIfRendered(sceneNumber);
    _suppressUndo--;
    notifyListeners();
    persistProject();
  }

  void relinkParserOverlap(int sceneNumber, SceneElement el) {
    final existing = correctionFor(sceneNumber, el);
    if (existing == null || !existing.isSplit) return;
    _pushUndo();
    existing
      ..markedAsNoise = false
      ..isSplit = false
      ..timestamp = DateTime.now();
    final key = addedKey(sceneNumber);
    userAddedElements[key]?.removeWhere((a) => a.isSplitFragment && a.afterElementTextKey == el.ref);
    if (userAddedElements[key]?.isEmpty ?? false) userAddedElements.remove(key);
    if (!existing.hasOtherData && existing.removedVoiceIndex == null) {
      corrections.remove(existing.storageKey);
    }
    markSceneDirtyIfRendered(sceneNumber);
    notifyListeners();
    persistProject();
  }

  void markOverlapVoiceRemoved(int sceneNumber, SceneElement el, int voiceIndex) {
    final prev = correctionFor(sceneNumber, el)?.removedVoiceIndex;
    final next = (prev == 0 && voiceIndex == 1) || (prev == 1 && voiceIndex == 0) ? 2 : voiceIndex;
    saveCorrection(
      _base(sceneNumber, el)
        ..removedVoiceIndex = next
        ..markedAsNoise = false
        ..isSplit = false
        ..timestamp = DateTime.now(),
    );
  }

  void restoreOverlapVoice(int sceneNumber, SceneElement el, int voiceIndex) {
    final existing = correctionFor(sceneNumber, el);
    final prev = existing?.removedVoiceIndex;
    if (existing == null || prev == null) return;
    _pushUndo();
    final int? next = switch ((prev, voiceIndex)) {
      (2, 0) => 1,
      (2, 1) => 0,
      _ => null,
    };
    existing
      ..removedVoiceIndex = next
      ..timestamp = DateTime.now();
    if (!existing.hasOtherData && next == null) corrections.remove(existing.storageKey);
    markSceneDirtyIfRendered(sceneNumber);
    notifyListeners();
    persistProject();
  }

  void editOverlapVoice(int sceneNumber, SceneElement el, int voiceIndex, String speaker, String text) {
    final c = _base(sceneNumber, el)..timestamp = DateTime.now();
    final cue = List<String>.of(c.correctedOverlapSpeakers ?? el.overlapCue ?? const []);
    final texts = List<String>.of(c.correctedOverlapTexts ?? el.overlapTexts ?? List.filled(cue.length, el.text));
    if (voiceIndex < cue.length) cue[voiceIndex] = speaker;
    while (texts.length < cue.length) {
      texts.add(el.text);
    }
    if (voiceIndex < texts.length) texts[voiceIndex] = text;
    c.correctedOverlapSpeakers = cue;
    c.correctedOverlapTexts = texts;
    saveCorrection(c);
  }

  // Added lines ----------------------------------------------------------------

  String addedKey(int sceneNumber) => '${pdfPath ?? ''}|$sceneNumber';

  void addLine(int sceneNumber, {required String afterRef, required String speaker, String kind = 'dialog'}) {
    _pushUndo();
    userAddedElements
        .putIfAbsent(addedKey(sceneNumber), () => [])
        .add(
          UserAddedElement(
            pdfPath: pdfPath ?? '',
            sceneNumber: sceneNumber,
            afterElementTextKey: afterRef,
            speaker: speaker == 'Narrator' ? '' : speaker,
            text: '',
            kind: kind,
          ),
        );
    markSceneDirtyIfRendered(sceneNumber);
    notifyListeners();
    persistProject();
  }

  void updateAddedLine(int sceneNumber, String id, {required String speaker, required String text, required String kind}) {
    final el = userAddedElements[addedKey(sceneNumber)]?.where((a) => a.id == id).firstOrNull;
    if (el == null) return;
    _pushUndo();
    el
      ..speaker = speaker == 'Narrator' ? '' : speaker
      ..text = text
      ..kind = kind;
    markSceneDirtyIfRendered(sceneNumber);
    notifyListeners();
    persistProject();
  }

  void deleteAddedLine(int sceneNumber, String id) {
    _pushUndo();
    final key = addedKey(sceneNumber);
    userAddedElements[key]?.removeWhere((a) => a.id == id);
    if (userAddedElements[key]?.isEmpty ?? false) userAddedElements.remove(key);
    markSceneDirtyIfRendered(sceneNumber);
    notifyListeners();
    persistProject();
  }

  /// Parsed lines interleaved with user-added lines; manual simultaneous pairs collapse to one row.
  List<MergedElement> mergedElements(Scene scene, {int limit = 1 << 30}) {
    final added = userAddedElements[addedKey(scene.number)] ?? const <UserAddedElement>[];
    final addedByKey = <String, List<UserAddedElement>>{};
    for (final a in added) {
      addedByKey.putIfAbsent(a.afterElementTextKey, () => []).add(a);
    }
    final secondary = <String>{};
    for (final el in scene.elements) {
      final fix = correctionFor(scene.number, el);
      if (fix?.markedAsNoise == true) continue;
      final pk = fix?.manualOverlapPartnerKey;
      if (pk != null) secondary.add(pk);
    }
    final byRef = <String, SceneElement>{};
    for (final el in scene.elements) {
      byRef.putIfAbsent(el.ref, () => el);
    }
    final out = <MergedElement>[];
    for (final el in scene.elements.take(limit)) {
      if (secondary.contains(el.ref)) continue;
      final pk = correctionFor(scene.number, el)?.manualOverlapPartnerKey;
      final partner = pk == null ? null : byRef[pk];
      if (partner != null) {
        out.add(ManualOverlapItem(el, partner));
        final bucket = [...?addedByKey[el.ref], ...?addedByKey[partner.ref]]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        out.addAll(bucket.map(AddedItem.new));
      } else {
        out.add(ParsedItem(el));
        final bucket = [...?addedByKey[el.ref]]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        out.addAll(bucket.map(AddedItem.new));
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Updates (check only in the preview; installing is not wired yet)
  // ---------------------------------------------------------------------------

  static const appVersion = '0.2.0-preview';

  static bool isNewer(String candidate, String current) {
    List<int> parts(String v) => v.replaceFirst(RegExp('^v'), '').split(RegExp(r'[.\-]')).map((p) => int.tryParse(p) ?? 0).toList();
    final a = parts(candidate), b = parts(current);
    for (var i = 0; i < math.max(a.length, b.length); i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  Future<void> checkForUpdates() async {
    try {
      final client = HttpClient();
      final path = updateChannel == 'stable' ? 'releases/latest' : 'releases?per_page=1';
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/averywhitted/script-to-audio-app/$path'));
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      client.close();
      if (res.statusCode != 200) return;
      dynamic j = jsonDecodeSafe(body);
      if (j is List) j = j.isEmpty ? null : j.first;
      if (j is! Map) return;
      final tag = j['tag_name'] as String? ?? '';
      if (!isNewer(tag, appVersion)) return;
      availableUpdate = UpdateInfo(
        version: tag.replaceFirst('v', ''),
        releaseNotes: j['body'] as String? ?? '',
        htmlUrl: j['html_url'] as String? ?? 'https://github.com/averywhitted/script-to-audio-app/releases',
        hasZipAsset: ((j['assets'] as List?) ?? const []).any((a) => (a as Map)['name'] == 'TableRead.zip'),
      );
      notifyListeners();
    } catch (_) {}
  }

  void simulateUpdate() {
    availableUpdate = UpdateInfo(
      version: '0.2.1',
      releaseNotes: '• Faster parsing for long scripts\n• Speaker names split across page breaks are caught more often\n• Fixes for voice previews',
      htmlUrl: 'https://github.com/averywhitted/script-to-audio-app/releases',
      hasZipAsset: true,
    );
    updateStage = UpdateStage.idle;
    notifyListeners();
  }

  Future<void> downloadAndInstallUpdate() async {
    final u = availableUpdate;
    if (u == null) return;
    // The preview can't replace itself yet: the Dart port of the updater is a
    // later step. Show the progress UI, then explain.
    updateStage = UpdateStage.downloading;
    updateFraction = 0;
    notifyListeners();
    for (var i = 1; i <= 10; i++) {
      await Future.delayed(const Duration(milliseconds: 120));
      updateFraction = i / 10;
      notifyListeners();
    }
    updateStage = UpdateStage.failed;
    updateError = 'This preview build can\'t install updates yet. Download ${u.version} from GitHub instead.';
    notifyListeners();
  }
}

dynamic jsonDecodeSafe(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}
