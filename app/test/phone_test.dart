// The iPhone app's screens (#90, #91), rendered at iPhone size in light and
// dark (test/goldens/phone_*). The projects folder is a plain temp folder
// here; on the phone it comes through FolderAccess (ios/Runner/AppDelegate.swift).
// Run: flutter test --update-goldens test/phone_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/phone/phone_app.dart';
import 'package:table_read/phone/phone_store.dart';
import 'package:table_read/phone/rehearsal_session.dart';
import 'package:table_read/services/project_files.dart';

import 'fixtures.dart';

late Directory tmp;
late String earnestFolder;

Future<PhoneStore> _store({bool withFolder = true}) async {
  final s = PhoneStore(folderAccess: false)..folder = withFolder ? tmp.path : null;
  await s.refresh();
  return s;
}

Future<void> _pump(WidgetTester tester, PhoneStore store, Brightness b) async {
  tester.view.physicalSize = const Size(402, 874); // iPhone 17, in points
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(PhoneApp(store: store, themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

Future<void> _openEarnest(WidgetTester tester) async {
  await tester.tap(find.text('THE IMPORTANCE OF BEING EARNEST'));
  await tester.pumpAndSettle();
}

/// A cue map for a rendered scene: each line 3 s apart, as the worker writes them.
void _writeCues(String folder, int n, Scene scene) {
  final cues = [
    for (final (i, el) in scene.elements.indexed)
      {
        'index': i,
        'kind': el.kind,
        'speaker': el.kind == 'dialog' ? (el.isOverlap ? el.overlapCue!.join('/') : el.speaker) : narratorKey,
        'text': el.text,
        'startTime': i * 3.0,
        'endTime': i * 3.0 + 2.5,
        'ref': el.ref,
      },
  ];
  File('$folder/Scene_0${n}_Scene.cues.json').writeAsStringSync(
    jsonEncode({'schemaVersion': 1, 'sceneNumber': n, 'sceneTitle': scene.title, 'totalDuration': cues.length * 3.0, 'cues': cues}),
  );
  File('$folder/Scene_0${n}_Scene.m4a').writeAsStringSync('');
}

void main() {
  setUpAll(() async {
    clockNow = () => DateTime(2026, 10, 10, 9, 14);
    await loadTestFonts();
    tmp = Directory('${Directory.systemTemp.path}/tr_phone_fixture');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    earnestFolder = writeProjects(tmp.path);
    final script = earnestScript();
    saveScriptSnapshot(earnestFolder, script, pdfFilename: 'script.pdf');
    for (final n in [1, 2]) {
      _writeCues(earnestFolder, n, script.scenes[n - 1]);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final r = Directory('$earnestFolder/$rehearsalFolder');
    if (r.existsSync()) r.deleteSync(recursive: true);
  });

  test('the project list reads every project.json, newest first, and skips archives', () async {
    final s = await _store();
    expect(s.projects.map((p) => p.name).take(3), ['The Importance of Being Earnest', 'Hamlet', 'Uncle Vanya']);
    expect(s.projects.length, 8);
    expect(s.projects.every((p) => p.folderPath!.startsWith(tmp.path)), isTrue);
  });

  test('a session shows rendered scenes from their cues and the rest from script.json', () async {
    final s = await _store();
    final session = RehearsalSession.load(s.projects.first);
    expect(session.items.map((i) => i.sceneNumber), [1, 2]);
    expect(session.scenes.length, 12);
    expect(session.scenes[0].rendered, isTrue);
    expect(session.scenes[0].lines.every((l) => l.cueIndex != null), isTrue);
    expect(session.scenes[2].rendered, isFalse);
    expect(session.scenes[2].lines.first.text, startsWith('The scene opens.'));
    expect(session.characters, contains('ALGERNON'));
  });

  for (final b in [Brightness.light, Brightness.dark]) {
    final mode = b == Brightness.dark ? 'dark' : 'light';

    testWidgets('welcome $mode', (tester) async {
      await _pump(tester, await _store(withFolder: false), b);
      expect(find.text('Choose Folder'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_welcome_$mode.png'));
    });

    testWidgets('projects and rehearsal $mode', (tester) async {
      await _pump(tester, await _store(), b);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_projects_$mode.png'));
      await _openEarnest(tester);
      expect(find.text('1 · Morning-room, Half-Moon Street'), findsOneWidget);
      expect(find.text('Rehearse'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_rehearse_$mode.png'));
      await tester.tap(find.text('Rehearse'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Algernon'));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_panel_$mode.png'));
    });
  }

  testWidgets('Block My Lines blanks only my lines', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await _openEarnest(tester);
    await tester.tap(find.text('Rehearse'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Algernon'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block My Lines'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // Scene 1: line 1 is Algernon's, line 2 Cecily's.
    expect(find.text('Line 1 of scene 1, spoken with great feeling and a certain amount of wit.'), findsNothing);
    expect(find.textContaining('____ _ __ _____ _'), findsOneWidget);
    expect(find.text('Line 2 of scene 1, spoken with great feeling and a certain amount of wit.'), findsOneWidget);
    expect(find.text('Algernon'), findsOneWidget); // the role pill in the bar
  });

  testWidgets('a text-only scene says so', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await _openEarnest(tester);
    await tester.tap(find.text('1 · Morning-room, Half-Moon Street'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bunburying'));
    await tester.pumpAndSettle();
    expect(find.text('3 · Bunburying'), findsOneWidget);
    expect(find.textContaining('Text only. Render this scene'), findsOneWidget);
  });

  testWidgets('tapping a line plays from it; long-press picks lines to loop', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await _openEarnest(tester);
    await tester.tap(find.text('Line 3 of scene 1, spoken with great feeling and a certain amount of wit.'));
    await tester.pumpAndSettle();
    expect(find.text('0:09'), findsOneWidget); // line 4 of the cue map starts at 9 s
    await tester.longPress(find.text('Line 2 of scene 1, spoken with great feeling and a certain amount of wit.'));
    await tester.pumpAndSettle();
    expect(find.text('1 line selected'), findsOneWidget);
    await tester.tap(find.text('Loop'));
    await tester.pumpAndSettle();
    expect(find.text('1 line selected'), findsNothing);
  });

  testWidgets('rehearsal settings are saved in the project and come back', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await _openEarnest(tester);
    await tester.tap(find.text('Rehearse'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Jack'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Projects'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    final saved = loadNewestRehearsal(earnestFolder);
    expect(saved?.role, 'JACK');
    expect(saved?.device, 'iPhone');
    await _openEarnest(tester);
    await tester.pumpAndSettle();
    expect(find.text('Jack'), findsOneWidget);
  });

  testWidgets('a project the Mac hasn\'t opened since the update asks for that', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await tester.tap(find.text('HAMLET'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open this project on your Mac once'), findsOneWidget);
  });
}
