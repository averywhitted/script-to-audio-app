// Integration: drives the real backend/audio_worker.py through the Dart bridge.
// Skips itself if the repository's Python environment isn't available.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/services/python_bridge.dart';
import 'package:table_read/state/app_state.dart';

void main() {
  final bridge = PythonBridge();
  final root = bridge.repoRoot;
  final skip = root == null ? 'repository with backend/audio_worker.py not found' : null;

  test('parse a test PDF', () async {
    final pdfs = Directory('$root/Test PDFs').listSync().whereType<File>().where((f) => f.path.endsWith('.pdf')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final script = await bridge.parse(pdfs.first.path);
    expect(script.scenes, isNotEmpty);
    expect(script.characters, isNotEmpty);
    expect(script.lineCount, greaterThan(50));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('engine status and macOS voices', () async {
    final status = await bridge.engineStatus();
    expect(status[EngineKind.macOS]?.installed, isTrue);
    final (voices, _) = await bridge.voices(EngineKind.macOS);
    expect(voices, isNotEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('scene file names match the Python pipeline', () async {
    final titles = ['Morning-room, Half-Moon Street', 'Scene_1 part 2', "Jack's \"mourning\"", 'Café — Act Ⅱ', '', '  - - ', 'A' * 80];
    final code = '''
import sys, json
sys.path.insert(0, "backend")
from audio_pipeline import _sanitize_filename_part
print(json.dumps([f"Scene_{i+1:02d}_{_sanitize_filename_part(t)}.m4a" for i, t in enumerate(json.loads(sys.argv[1]))]))
''';
    final r = await Process.run(bridge.pythonPath, ['-c', code, jsonEncode(titles)], workingDirectory: root);
    expect(r.exitCode, 0, reason: r.stderr as String);
    final expected = (jsonDecode((r.stdout as String).trim()) as List).cast<String>();
    final actual = [for (var i = 0; i < titles.length; i++) AppState.sceneFilename(i + 1, titles[i])];
    expect(actual, expected);
  }, skip: skip);

  test('render the shortest scene with macOS voices, with pause and resume', () async {
    final pdfs = Directory('$root/Test PDFs').listSync().whereType<File>().where((f) => f.path.endsWith('.pdf')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final pdf = pdfs.first.path;
    final script = await bridge.parse(pdf);
    final scene = (List.of(script.scenes)..sort((a, b) => a.elements.length.compareTo(b.elements.length))).first;
    final out = Directory.systemTemp.createTempSync('tr_render').path;
    final events = <String>[];
    var paused = false;
    await bridge.generate(
      pdfPath: pdf,
      outputDir: out,
      engine: EngineKind.macOS,
      sceneNumbers: [scene.number],
      assignment: const {},
      userAddedElements: const {},
      corrections: const [],
      onEvent: (e) {
        events.add(e.event);
        if (!paused && e.event == 'progress') {
          paused = true;
          bridge.pause();
          Future.delayed(const Duration(milliseconds: 400), bridge.resume);
        }
      },
    );
    expect(events, contains('done'));
    expect(events, contains('cueMap'));
    final name = AppState.sceneFilename(scene.number, scene.title);
    expect(File('$out/$name').existsSync(), isTrue, reason: 'rendered $name');
    final cueFile = File('$out/${name.replaceAll('.m4a', '.cues.json')}');
    expect(cueFile.existsSync(), isTrue);
    // Every cue names its line with the same ref the app uses, one cue per
    // line, in order, with no overlapping times.
    final cues = ((jsonDecode(cueFile.readAsStringSync()) as Map)['cues'] as List).map((e) => SceneCue.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    final refs = {for (final el in scene.elements) el.ref};
    expect(cues, isNotEmpty);
    for (final c in cues) {
      expect(c.ref, isNotNull, reason: c.text);
      expect(refs, contains(c.ref));
    }
    expect(cues.map((c) => c.ref).toSet().length, cues.length);
    for (var i = 1; i < cues.length; i++) {
      expect(cues[i].startTime, greaterThanOrEqualTo(cues[i - 1].endTime));
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}
