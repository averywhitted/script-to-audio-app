// Opening a project keeps the parse it was given instead of reading the PDF again; Re-parse reads it fresh.
// Run: flutter test test/saved_parse_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/services/project_files.dart';
import 'package:table_read/services/project_store.dart';
import 'package:table_read/services/settings.dart';
import 'package:table_read/state/app_state.dart';

ScriptSummary echo() => ScriptSummary.fromJson(
  jsonDecode('''
{"title":"Echo","sceneCount":1,"characterCount":1,"lineCount":1,
 "characters":[{"name":"LOLA","genderHint":"F"}],
 "scenes":[{"number":1,"title":"One","elementCount":1,"elements":[
   {"kind":"dialog","speaker":"LOLA","text":"I'm looking at you.","confidence":1}]}]}''') as Map<String, dynamic>,
);

/// A project folder with a PDF and, unless [parsed] is false, its saved parse.
String _folder({bool parsed = true, String savedFor = 'script.pdf'}) {
  final dir = Directory.systemTemp.createTempSync('tr_saved_parse').path;
  File('$dir/script.pdf').writeAsStringSync('%PDF-1.4 sample');
  if (parsed) saveScriptSnapshot(dir, echo(), pdfFilename: savedFor);
  return dir;
}

Future<AppState> _app() async {
  final dir = Directory.systemTemp.createTempSync('tr_saved_parse_app');
  SharedPreferences.setMockInitialValues({'importedSwiftSettings': true, 'projectsBaseURL': dir.path});
  final settings = await Settings.load();
  return AppState(settings, ProjectStore(settings), startBackgroundTasks: false);
}

void main() {
  group('the saved parse', () {
    test('is used for the PDF it was made from', () {
      final f = _folder();
      expect(loadSavedParse(f, '$f/script.pdf')?.title, 'Echo');
    });

    test('is not used without one, for another PDF, or after the PDF was replaced', () {
      expect(loadSavedParse(_folder(parsed: false), '/x/script.pdf'), isNull);
      final other = _folder(savedFor: 'other.pdf');
      expect(loadSavedParse(other, '$other/script.pdf'), isNull);
      final f = _folder();
      File('$f/script.pdf').setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5))); // a newer PDF
      expect(loadSavedParse(f, '$f/script.pdf'), isNull);
    });
  });

  group('opening a project', () {
    test('uses the saved parse: no reading of the PDF, ready at once', () async {
      final f = _folder();
      final app = await _app();
      final p = Project.newProject('P', f)..pdfFilename = 'script.pdf';
      app.store.openProject(p);
      app.loadFromProject(p);
      expect(app.isParsing, isFalse);
      expect(app.script?.title, 'Echo');
      expect(app.selectedScenes, {1});
      expect(app.pdfPath, '$f/script.pdf');
    });

    test('reads the PDF when there is no saved parse', () async {
      final f = _folder(parsed: false);
      final app = await _app();
      final p = Project.newProject('P', f)..pdfFilename = 'script.pdf';
      app.store.openProject(p);
      app.loadFromProject(p);
      expect(app.isParsing, isTrue); // the parse is under way (it ends in an error here: no worker in tests)
      expect(app.script, isNull);
    });

    test('Re-parse reads the PDF again even though a saved parse is there; not while parsing', () async {
      final f = _folder();
      final app = await _app();
      final p = Project.newProject('P', f)..pdfFilename = 'script.pdf';
      app.store.openProject(p);
      app.loadFromProject(p);
      expect(app.isParsing, isFalse);
      final again = app.reparse();
      expect(app.isParsing, isTrue);
      await app.reparse(); // a second press while it runs does nothing
      await again.catchError((_) {});
    });
  });
}
