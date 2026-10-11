// Logic tests: ports of Tests/TableReadTests/AppStateTests.swift plus the
// correction, undo and casting rules ported from AppState.swift.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/services/project_store.dart';
import 'package:table_read/services/settings.dart';
import 'package:table_read/state/app_state.dart';
import 'package:table_read/state/player_state.dart' show cueIndexAt;
import 'package:table_read/ui/dashboard.dart' show matchCuesToRows;

const pdf = '/tmp/echo.pdf';

ScriptSummary echoScript() => ScriptSummary.fromJson(jsonDecode('''
{"title":"Echo","sceneCount":1,"characterCount":2,"lineCount":4,
 "characters":[{"name":"LOLA","genderHint":"F"},{"name":"ELLIOT","genderHint":"M"}],
 "scenes":[{"number":1,"title":"One","elementCount":4,"elements":[
   {"kind":"dialog","speaker":"LOLA","text":"I'm looking at you.","confidence":1},
   {"kind":"dialog","speaker":"ELLIOT","text":"I'm looking at you.","confidence":1},
   {"kind":"stage_direction","text":"They stare.","confidence":1},
   {"kind":"dialog","speaker":"LOLA","text":"Both of us, then.","overlapCue":["LOLA","ELLIOT"],"overlapTexts":["Both of us,","then."]}
 ]}]}''') as Map<String, dynamic>);

Future<AppState> makeApp() async {
  final dir = Directory.systemTemp.createTempSync('tr_logic');
  SharedPreferences.setMockInitialValues({'importedSwiftSettings': true, 'projectsBaseURL': dir.path});
  final settings = await Settings.load();
  final app = AppState(settings, ProjectStore(settings), startBackgroundTasks: false);
  app.pdfPath = pdf;
  app.script = echoScript();
  return app;
}

void main() {
  group('repeated lines (#55)', () {
    test('decoding numbers repeats', () {
      expect(echoScript().scenes[0].elements.map((e) => e.occurrence), [0, 1, 0, 0]);
    });

    test('first copy keeps the old key; second gets a suffix', () {
      final els = echoScript().scenes[0].elements;
      expect(correctionKey(pdf, 1, els[0].text, els[0].occurrence), "$pdf|1|I'm looking at you.");
      expect(els[1].ref, "I'm looking at you.\u001F1");
    });

    test('correction to the second copy leaves the first alone', () async {
      final app = await makeApp();
      final els = app.scenes[0].elements;
      app.correctLine(1, els[1], kind: 'dialog', speaker: 'MAX', removed: false);
      expect(app.correctionFor(1, els[0]), isNull);
      expect(app.correctionFor(1, els[1])?.correctedSpeaker, 'MAX');
    });

    test('manual overlap absorbs only the named copy', () async {
      final app = await makeApp();
      final els = app.scenes[0].elements;
      app.makeSimultaneous(1, els[2], els[1]);
      final merged = app.mergedElements(app.scenes[0]);
      expect(merged.whereType<ManualOverlapItem>().length, 1);
      // LOLA's identical line survives as its own row; ELLIOT's copy is absorbed.
      final parsed = merged.whereType<ParsedItem>().map((p) => p.element.speaker).toList();
      expect(parsed, ['LOLA', 'LOLA']);
    });

    test('prefix uses 60 characters, not 60 UTF-16 units', () {
      final long = '${'é' * 59}👋🏽 tail';
      expect(textPrefix60(long).runes.length, greaterThan(60)); // emoji + skin tone = 1 character
      expect(textPrefix60(long).endsWith('👋🏽'), isTrue);
    });
  });

  group('edits', () {
    test('remove and restore a line; undo and redo', () async {
      final app = await makeApp();
      final el = app.scenes[0].elements[2];
      app.toggleRemoved(1, el);
      expect(app.correctionFor(1, el)?.markedAsNoise, isTrue);
      expect(app.undoCount, 1);
      app.toggleRemoved(1, el);
      expect(app.correctionFor(1, el), isNull, reason: 'a correction with nothing left is deleted');
      app.undo();
      expect(app.correctionFor(1, el)?.markedAsNoise, isTrue);
      app.redo();
      expect(app.correctionFor(1, el), isNull);
    });

    test('undo history keeps at most 50 steps', () async {
      final app = await makeApp();
      final el = app.scenes[0].elements[2];
      for (var i = 0; i < 60; i++) {
        app.toggleRemoved(1, el);
      }
      expect(app.undoCount, 50);
    });

    test('simultaneous voice removal escalates to both, then restores one at a time', () async {
      final app = await makeApp();
      final el = app.scenes[0].elements[3];
      app.markOverlapVoiceRemoved(1, el, 0);
      expect(app.correctionFor(1, el)?.removedVoiceIndex, 0);
      app.markOverlapVoiceRemoved(1, el, 1);
      expect(app.correctionFor(1, el)?.removedVoiceIndex, 2);
      app.restoreOverlapVoice(1, el, 0);
      expect(app.correctionFor(1, el)?.removedVoiceIndex, 1);
      app.restoreOverlapVoice(1, el, 1);
      expect(app.correctionFor(1, el), isNull);
    });

    test('unlink splits into two added lines; relink restores', () async {
      final app = await makeApp();
      final el = app.scenes[0].elements[3];
      app.splitParserOverlap(1, el);
      final added = app.userAddedElements[app.addedKey(1)]!;
      expect(added.map((a) => (a.speaker, a.text)), [('LOLA', 'Both of us,'), ('ELLIOT', 'then.')]);
      expect(app.correctionFor(1, el)?.isSplit, isTrue);
      app.relinkParserOverlap(1, el);
      expect(app.userAddedElements[app.addedKey(1)], isNull);
      expect(app.correctionFor(1, el), isNull);
    });

    test('added lines appear after the line they follow', () async {
      final app = await makeApp();
      final els = app.scenes[0].elements;
      app.addLine(1, afterRef: els[0].ref, speaker: 'LOLA');
      final merged = app.mergedElements(app.scenes[0]);
      expect(merged[0], isA<ParsedItem>());
      expect(merged[1], isA<AddedItem>());
      expect((merged[2] as ParsedItem).element.speaker, 'ELLIOT');
    });

    test('reassigning a narrator line keeps it narration', () async {
      final app = await makeApp();
      final els = app.scenes[0].elements;
      app.reassignSpeaker(1, [els[1], els[2]], const [], 'LOLA');
      expect(app.correctionFor(1, els[1])?.correctedSpeaker, 'LOLA');
      expect(app.correctionFor(1, els[2]), isNull);
    });
  });

  group('casting', () {
    test('gender change picks a matching voice nobody else uses', () async {
      final app = await makeApp();
      app.voices = [
        VoiceSummary(id: 'm1', label: 'M1', gender: 'M', display: 'M1'),
        VoiceSummary(id: 'm2', label: 'M2', gender: 'M', display: 'M2'),
        VoiceSummary(id: 'f1', label: 'F1', gender: 'F', display: 'F1'),
      ];
      app.voiceAssignment = {'LOLA': 'm1'};
      app.setCharacterGender('M', 'ELLIOT');
      expect(app.voiceAssignment['ELLIOT'], 'm2');
      app.setCharacterGender('F', 'LOLA');
      expect(app.voiceAssignment['LOLA'], 'f1');
      app.setCharacterGender('M', 'ELLIOT'); // already fits: unchanged
      expect(app.voiceAssignment['ELLIOT'], 'm2');
    });
  });

  group('project files', () {
    test('Swift-written project.json round-trips without losing data', () {
      const swift = '''
{
  "characterGenderOverrides" : {"UNCLE" : "M"},
  "corrections" : {
    "/p/x.pdf|1|Hello there." : {
      "contributed" : false, "isSplit" : false, "markedAsNoise" : true, "originalKind" : "dialog",
      "originalSpeaker" : "UNCLE", "pdfIdentifier" : "/p/x.pdf", "sceneNumber" : 1,
      "textKey" : "Hello there.", "timestamp" : "2026-09-29T17:27:32Z", "uploaded" : false
    }
  },
  "createdAt" : "2026-09-29T17:27:32Z",
  "futureField" : {"kept" : true},
  "id" : "9D0412C6-AD25-4338-B9FB-2E620537B778",
  "lastOpenedAt" : "2026-09-29T17:27:32Z",
  "name" : "TLRAD",
  "pdfFilename" : "script.pdf",
  "renderedScenes" : [1, 2],
  "sceneTitleOverrides" : {"/p/x.pdf" : {"1" : "Scene 1"}},
  "scriptTitle" : "THE LIVING ROOM",
  "selectedEngine" : "kokoro",
  "userAddedElements" : {"/p/x.pdf|1" : [{"afterElementTextKey" : "Hello there.", "id" : "4B1F0B7E-7A0C-4C1A-9C61-3B4B2F7E6A10", "isSplitFragment" : false, "kind" : "dialog", "pdfPath" : "/p/x.pdf", "sceneNumber" : 1, "speaker" : "UNCLE", "text" : "Hi.", "timestamp" : "2026-09-29T17:30:00Z"}]},
  "voiceAssignment" : {"UNCLE" : "am_liam"}
}''';
      final p = Project.fromJson(jsonDecode(swift) as Map<String, dynamic>);
      expect(p.sceneTitleOverrides['/p/x.pdf']![1], 'Scene 1');
      expect(p.corrections.values.single.markedAsNoise, isTrue);
      final out = p.toJson();
      final again = jsonDecode(jsonEncode(out)) as Map<String, dynamic>;
      final original = jsonDecode(swift) as Map<String, dynamic>;
      expect(again, original, reason: 'every key and value survives a load and save');
    });

    test('older Swift encoding of [Int: String] as a flat list still loads', () {
      final p = Project.fromJson({
        'id': 'A',
        'name': 'Old',
        'createdAt': '2026-01-01T00:00:00Z',
        'lastOpenedAt': '2026-01-01T00:00:00Z',
        'sceneTitleOverrides': {
          '/x.pdf': [3, 'Three', 7, 'Seven']
        },
      });
      expect(p.sceneTitleOverrides['/x.pdf'], {3: 'Three', 7: 'Seven'});
    });
  });

  group('unsure lines', () {
    test('confirming the same speaker marks the line checked without an edit', () async {
      final app = await makeApp();
      final el = app.scenes.first.elements.first;
      app.confirmSpeaker(1, el, 'LOLA', text: el.text, removed: false);
      expect(app.isChecked(1, el), isTrue);
      expect(app.correctionFor(1, el), isNull, reason: 'not an edit, so no re-render');
      // A different speaker is a real correction.
      final other = app.scenes.first.elements[1];
      app.confirmSpeaker(1, other, 'LOLA', text: other.text, removed: false);
      expect(app.correctionFor(1, other)?.correctedSpeaker, 'LOLA');
    });

    test('checked lines survive a save and load', () {
      final p = Project.fromJson({'id': 'A', 'name': 'P', 'createdAt': '2026-01-01T00:00:00Z', 'lastOpenedAt': '2026-01-01T00:00:00Z'});
      p.checkedLines = {'2|Hello'};
      expect(Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>).checkedLines, {'2|Hello'});
    });
  });

  test('export audio copies only the .m4a files, into a new folder each time', () async {
    final src = Directory.systemTemp.createTempSync('tr_export_src');
    final dest = Directory.systemTemp.createTempSync('tr_export_dest');
    File('${src.path}/Scene_01_One.m4a').writeAsStringSync('a');
    File('${src.path}/Scene_01_One.cues.json').writeAsStringSync('{}');
    File('${src.path}/Scene_02_Two.m4a').writeAsStringSync('b');
    File('${src.path}/project.json').writeAsStringSync('{}');
    final (folder, count) = await AppState.exportAudio(sourceFolder: src.path, projectName: 'My/Play', destination: dest.path);
    expect(count, 2);
    expect(folder, '${dest.path}/My-Play Audio');
    expect(Directory(folder).listSync().map((e) => e.uri.pathSegments.last).toList()..sort(), ['Scene_01_One.m4a', 'Scene_02_Two.m4a']);
    final (again, _) = await AppState.exportAudio(sourceFolder: src.path, projectName: 'My/Play', destination: dest.path);
    expect(again, '${dest.path}/My-Play Audio 2');
  });

  test('version comparison', () {
    expect(AppState.isNewer('v0.2.1', '0.2.0-preview'), isTrue);
    expect(AppState.isNewer('v0.1.8', '0.2.0-preview'), isFalse);
    expect(AppState.isNewer('0.2.0', '0.2.0'), isFalse);
  });

  group('playing line', () {
    // Old cue maps (no refs): matched by words, in order.
    List<int> byText(List<String?> rows, List<String> cues) =>
        matchCuesToRows([for (final _ in rows) null], rows, [for (final _ in cues) null], cues);

    test('a repeated line lights up only the copy being played', () {
      final rows = ["I'm looking at you.", "I'm looking at you.", 'They stare.'];
      expect(byText(rows, ["I'm looking at you.", "I'm looking at you.", 'They stare.']), [0, 1, 2]);
    });

    test('removed rows are skipped; added rows count', () {
      expect(byText(['A.', null, 'B.', 'A.'], ['A.', 'B.', 'A.']), [0, 2, 3]);
    });

    test('cue refs match rows exactly, even when the words differ or repeat', () {
      // Row 1 was skipped by the voice; row 3 repeats row 0's words.
      final rowRefs = ['a', 'b', 'c', 'd'];
      final rowTexts = ['Yes.', 'Beat.', 'No.', 'Yes.'];
      final cueRefs = ['a', 'c', 'd'];
      final cueTexts = ['Yes.', 'No (edited).', 'Yes.'];
      expect(matchCuesToRows(rowRefs, rowTexts, cueRefs, cueTexts), [0, 2, 3]);
    });

    test('a cue without a known ref is matched by words only between its neighbours', () {
      // The middle cue's ref is unknown; its words appear twice, but only the
      // copy between rows 0 and 3 is eligible.
      final rowRefs = ['a', 'x', 'y', 'd', 'z'];
      final rowTexts = ['One.', 'Two.', 'Mid.', 'Four.', 'Mid.'];
      final m = matchCuesToRows(rowRefs, rowTexts, ['a', 'gone', 'd', 'gone2'], ['One.', 'Mid.', 'Four.', 'Mid.']);
      expect(m, [0, 2, 3, 4]);
    });

    test('cueIndexAt: a seek landing just before a line still lights that line', () {
      SceneCue c(double s, double e) => SceneCue(index: 0, kind: 'dialog', speaker: 'A', text: '', startTime: s, endTime: e);
      final cues = [c(1, 2), c(2.5, 4), c(4.4, 6)];
      expect(cueIndexAt(cues, 0.5), -1); // title / lead-in
      expect(cueIndexAt(cues, 2.4995), 1); // seek rounding
      expect(cueIndexAt(cues, 2.2), 0); // pause after line 0: line 0 stays lit
      expect(cueIndexAt(cues, 5), 2);
    });
  });

  group('re-render detection', () {
    Future<AppState> rendered() async {
      final app = await makeApp();
      app.sceneFileInfo = {1: SceneOutputInfo(exists: true, filename: 'x.m4a', title: 'One')};
      app.renderFingerprints = {1: app.sceneFingerprint(1)};
      return app;
    }

    test('an edit marks the scene; undo clears it', () async {
      final app = await rendered();
      app.toggleRemoved(1, app.scenes[0].elements[2]);
      expect(app.scenesNeedingRerender, {1});
      app.undo();
      expect(app.scenesNeedingRerender, isEmpty);
      app.redo();
      expect(app.scenesNeedingRerender, {1});
    });

    test('deleting the correction, or editing the line back, clears it', () async {
      final app = await rendered();
      final el = app.scenes[0].elements[0];
      app.correctLine(1, el, kind: 'dialog', speaker: 'ELLIOT', removed: false);
      expect(app.scenesNeedingRerender, {1});
      app.deleteCorrection(1, el);
      expect(app.scenesNeedingRerender, isEmpty);
      app.correctLine(1, el, kind: 'dialog', speaker: 'ELLIOT', removed: false);
      app.correctLine(1, el, kind: 'dialog', speaker: 'LOLA', removed: false);
      expect(app.scenesNeedingRerender, isEmpty);
    });

    test('an empty added line is not an edit; giving it text is', () async {
      final app = await rendered();
      app.addLine(1, afterRef: app.scenes[0].elements[0].ref, speaker: 'LOLA');
      expect(app.scenesNeedingRerender, isEmpty);
      final added = app.userAddedElements[app.addedKey(1)]!.single;
      app.updateAddedLine(1, added.id, speaker: 'LOLA', text: 'Hello.', kind: 'dialog');
      expect(app.scenesNeedingRerender, {1});
      app.deleteAddedLine(1, added.id);
      expect(app.scenesNeedingRerender, isEmpty);
    });

    test('fingerprints are saved with the project', () {
      final p = Project.newProject('X', '/tmp/x')..renderFingerprints = {3: 'abc'};
      final again = Project.fromJson(p.toJson());
      expect(again.renderFingerprints, {3: 'abc'});
    });
  });
}
