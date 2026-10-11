// Talks to backend/audio_worker.py exactly like Sources/TableRead/PythonBridge.swift:
// one process per command, the JSON request on stdin, a JSON response (or a
// stream of JSON event lines) on stdout. Nothing about the Python side changes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/models.dart';

class WorkerException implements Exception {
  WorkerException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PythonBridge {
  PythonBridge({this.onPythonLog}) : repoRoot = _findRepoRoot();

  /// Called with each line Python writes to stderr (routed to the Log tab).
  void Function(String line)? onPythonLog;

  final String? repoRoot;
  Process? _streamProcess;

  // Baked in at build time: flutter build macos --dart-define=TR_REPO_ROOT=...
  static const _bakedRoot = String.fromEnvironment('TR_REPO_ROOT');

  static String? _findRepoRoot() {
    bool valid(String dir) => File('$dir/backend/audio_worker.py').existsSync();
    // 1. Bundled inside the .app: Contents/Resources/backend/audio_worker.py
    final exe = Platform.resolvedExecutable; // .../Contents/MacOS/<name>
    final resources = '${File(exe).parent.parent.path}/Resources';
    if (valid(resources)) return resources;
    // 2. Development: the source tree baked in at build time.
    if (_bakedRoot.isNotEmpty && valid(_bakedRoot)) return _bakedRoot;
    // 3. Walk up from the working directory.
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      if (valid(dir.path)) return dir.path;
      dir = dir.parent;
    }
    return null;
  }

  String get workerPath {
    final root = repoRoot;
    if (root == null) {
      throw WorkerException('Could not find the Python worker (backend/audio_worker.py). Rebuild the preview with TR_REPO_ROOT set to the repository folder.');
    }
    return '$root/backend/audio_worker.py';
  }

  String get pythonPath {
    final root = repoRoot;
    if (root != null) {
      for (final candidate in [
        '$root/python/bin/python3', // bundled runtime (Contents/Resources/python)
        '$root/.venv/bin/python3',
        '$root/.venv/bin/python',
      ]) {
        if (File(candidate).existsSync()) return candidate;
      }
    }
    for (final candidate in ['/opt/homebrew/bin/python3', '/usr/local/bin/python3', '/usr/bin/python3']) {
      if (File(candidate).existsSync()) return candidate;
    }
    return 'python3';
  }

  Map<String, String>? get _environment {
    final root = repoRoot;
    if (root == null || !File('$root/python/bin/python3').existsSync()) return null; // dev: inherit
    final home = Platform.environment['HOME'] ?? '';
    final pkgs = '$home/Library/Application Support/TableRead/python-packages';
    Directory(pkgs).createSync(recursive: true);
    return {'TABLEREAD_PACKAGES': pkgs, 'HOME': home, 'PATH': '/usr/bin:/bin:/usr/local/bin', 'TMPDIR': Directory.systemTemp.path};
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  Future<ScriptSummary> parse(String pdfPath) async {
    final r = await _request({'command': 'parse', 'pdfPath': pdfPath});
    final script = r['script'];
    if (script is! Map) throw WorkerException('The Python worker returned an unexpected response.');
    return ScriptSummary.fromJson(Map<String, dynamic>.from(script));
  }

  Future<(List<VoiceSummary>, Map<String, String>)> voices(EngineKind engine, {String? pdfPath}) async {
    final r = await _request({'command': 'voices', 'engine': engine.id, if (pdfPath != null) 'pdfPath': pdfPath});
    final list = ((r['voices'] as List?) ?? const []).map((e) => VoiceSummary.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    final auto = Map<String, String>.from((r['autoAssign'] as Map?) ?? const {});
    return (list, auto);
  }

  Future<Map<EngineKind, EngineStatus>> engineStatus() async {
    final r = await _request({'command': 'engineStatus'});
    final out = <EngineKind, EngineStatus>{};
    ((r['engines'] as Map?) ?? const {}).forEach((k, v) {
      final e = EngineKind.fromId(k as String);
      if (e != null) out[e] = EngineStatus.fromJson(Map<String, dynamic>.from(v as Map));
    });
    return out;
  }

  Future<void> uninstallEngine(EngineKind engine) async {
    await _request({'command': 'uninstallEngine', 'engine': engine.id});
  }

  Future<String> previewVoice(EngineKind engine, String voiceId, {String? apiKey}) async {
    final r = await _request({'command': 'previewVoice', 'engine': engine.id, 'voiceId': voiceId, if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey});
    final path = r['path'] as String?;
    if (path == null) throw WorkerException(r['error'] as String? ?? 'Could not prepare voice preview.');
    return path;
  }

  Future<void> generate({
    required String pdfPath,
    required String outputDir,
    required EngineKind engine,
    required List<int> sceneNumbers,
    required Map<String, String> assignment,
    String? apiKey,
    required Map<String, List<UserAddedElement>> userAddedElements,
    required List<ParserCorrection> corrections,
    required void Function(GenerationEvent) onEvent,
  }) async {
    final payload = <String, dynamic>{
      'command': 'generate',
      'pdfPath': pdfPath,
      'outputDir': outputDir,
      'engine': engine.id,
      'sceneNumbers': sceneNumbers,
      if (assignment.isNotEmpty) 'assignment': assignment,
      if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
    };
    final byScene = <String, List<Map<String, dynamic>>>{};
    for (final n in sceneNumbers) {
      final els = userAddedElements['$pdfPath|$n'] ?? const [];
      final list = [
        for (final el in els)
          if (el.text.trim().isNotEmpty) {'afterElementTextKey': el.afterElementTextKey, 'speaker': el.speaker, 'text': el.text, 'kind': el.kind},
      ];
      if (list.isNotEmpty) byScene['$n'] = list;
    }
    if (byScene.isNotEmpty) payload['userAddedElements'] = byScene;
    if (corrections.isNotEmpty) {
      payload['corrections'] = [
        for (final c in corrections)
          {
            'sceneNumber': c.sceneNumber,
            'textPrefix': textPrefix60(c.textKey),
            'occurrence': c.occurrence ?? 0,
            'markedAsNoise': c.markedAsNoise,
            if (c.correctedKind != null) 'correctedKind': c.correctedKind,
            if (c.correctedSpeaker != null) 'correctedSpeaker': c.correctedSpeaker,
            if (c.correctedText != null && c.correctedText!.isNotEmpty) 'correctedText': c.correctedText,
            if (c.correctedOverlapSpeakers?.isNotEmpty ?? false) 'correctedOverlapSpeakers': c.correctedOverlapSpeakers,
            if (c.correctedOverlapTexts?.isNotEmpty ?? false) 'correctedOverlapTexts': c.correctedOverlapTexts,
            if (c.manualOverlapPartnerKey != null) 'manualOverlapPartnerKey': c.manualOverlapPartnerKey,
            if (c.removedVoiceIndex != null) 'removedVoiceIndex': c.removedVoiceIndex,
          },
      ];
    }
    await _stream(payload, onEvent);
  }

  Future<void> installEngine(EngineKind engine, void Function(GenerationEvent) onEvent) => _stream({'command': 'installEngine', 'engine': engine.id}, onEvent);

  void pause() => _streamProcess?.kill(ProcessSignal.sigstop);
  void resume() => _streamProcess?.kill(ProcessSignal.sigcont);

  void cancel() {
    final p = _streamProcess;
    if (p == null) return;
    p.kill(ProcessSignal.sigcont); // a suspended process can't handle SIGTERM
    p.kill(ProcessSignal.sigterm);
    _streamProcess = null;
  }

  // ---------------------------------------------------------------------------
  // Process plumbing
  // ---------------------------------------------------------------------------

  Future<Process> _start() => Process.start(
    pythonPath,
    [workerPath],
    workingDirectory: Directory.systemTemp.path, // neutral CWD, like the Swift app
    environment: _environment,
    includeParentEnvironment: _environment == null,
  );

  void _forwardStderr(String text) {
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isNotEmpty) onPythonLog?.call(line);
    }
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> payload) async {
    final process = await _start();
    process.stdin.write(jsonEncode(payload));
    await process.stdin.close();
    final outF = process.stdout.transform(utf8.decoder).join();
    final errF = process.stderr.transform(utf8.decoder).join();
    final out = await outF;
    _forwardStderr(await errF);
    await process.exitCode;
    // Engines may print download progress to stdout; take the last JSON line.
    Map<String, dynamic>? decoded;
    for (final line in const LineSplitter().convert(out).reversed) {
      final t = line.trim();
      if (!t.startsWith('{')) continue;
      try {
        decoded = Map<String, dynamic>.from(jsonDecode(t) as Map);
        break;
      } catch (_) {}
    }
    if (decoded == null) throw WorkerException('The Python worker returned an unexpected response.');
    if (decoded['ok'] != true) {
      throw WorkerException((decoded['error'] as String?) ?? 'Python worker failed.');
    }
    return decoded;
  }

  Future<void> _stream(Map<String, dynamic> payload, void Function(GenerationEvent) onEvent) async {
    final process = await _start();
    _streamProcess = process;
    process.stdin.write(jsonEncode(payload));
    await process.stdin.close();
    String? workerError;
    final errBuf = StringBuffer();
    final errDone = process.stderr.transform(utf8.decoder).listen((s) {
      errBuf.write(s);
      _forwardStderr(s);
    }).asFuture<void>();
    await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
      final t = line.trim();
      if (!t.startsWith('{')) return;
      try {
        final m = Map<String, dynamic>.from(jsonDecode(t) as Map);
        if (m.containsKey('event')) {
          onEvent(GenerationEvent(m));
        } else if (m['ok'] == false) {
          workerError = [m['error'], m['traceback']].whereType<String>().join('\n\n');
        }
      } catch (_) {}
    });
    await errDone;
    final code = await process.exitCode;
    if (identical(_streamProcess, process)) _streamProcess = null;
    if (code != 0) {
      if (code == -15 || code == 143) throw WorkerException('Canceled.');
      final err = errBuf.toString().trim();
      throw WorkerException(workerError ?? (err.isEmpty ? 'Worker exited with code $code.' : err));
    }
  }
}
