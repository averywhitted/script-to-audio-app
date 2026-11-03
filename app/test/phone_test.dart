// The iPhone app's screens (#90, #91), rendered at iPhone size in light and
// dark (test/goldens/phone_*). The projects folder is a plain temp folder
// here; on the phone it comes through FolderAccess (ios/Runner/AppDelegate.swift).
// Run: flutter test --update-goldens test/phone_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/phone/phone_app.dart';
import 'package:table_read/phone/phone_store.dart';
import 'package:table_read/phone/rehearsal_session.dart';
import 'package:table_read/services/project_files.dart';

import 'fixtures.dart';

/// A heading's text sits a little below the heading's own top.
const _headingSlack = 30.0;

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
  File('$folder/Scene_${n.toString().padLeft(2, '0')}_Scene.cues.json').writeAsStringSync(
    jsonEncode({'schemaVersion': 1, 'sceneNumber': n, 'sceneTitle': scene.title, 'totalDuration': cues.length * 3.0, 'cues': cues}),
  );
  File('$folder/Scene_${n.toString().padLeft(2, '0')}_Scene.m4a').writeAsStringSync('');
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
    for (final n in [1, 2, 8]) {
      _writeCues(earnestFolder, n, script.scenes[n - 1]);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final req = File('$earnestFolder/$renderRequestFile');
    if (req.existsSync()) req.deleteSync();
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
    expect(session.items.map((i) => i.sceneNumber), [1, 2, 8]);
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
      expect(find.text('Morning-room, Half-Moon Street'), findsOneWidget); // scene 1's heading
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
    expect(find.byKey(const Key('lineButton')), findsOneWidget); // Line! takes the role pill's place
  });

  testWidgets('the whole play scrolls; a scene heading jumps to another scene', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await _openEarnest(tester);
    await tester.tap(find.text('Morning-room, Half-Moon Street'));
    await tester.pumpAndSettle();
    // The list drops down from the heading, not up from the bottom.
    final drop = tester.getRect(find.byKey(const Key('sceneDropdown')));
    expect(drop.top, closeTo(tester.getRect(find.byType(CustomScrollView)).top + 52, 1));
    await tester.tap(find.descendant(of: find.byKey(const Key('sceneDropdown')), matching: find.text('Bunburying')));
    await tester.pumpAndSettle();
    // Scene 3's heading is stuck at the top, marked text only; its first line is under it.
    final heading = tester.getRect(find.text('Bunburying'));
    final top = tester.getRect(find.byType(CustomScrollView)).top;
    expect(heading.top - top, lessThan(_headingSlack), reason: 'scene 3 heading at the very top');
    expect(find.text('Cucumber sandwiches').hitTestable(), findsNothing, reason: "scene 2's heading has scrolled away");
    expect(find.text('Text only'), findsWidgets);
    final first = tester.getRect(find.text('The scene opens. DR. CHASUBLE enters, carrying a book.'));
    expect(first.top, greaterThan(heading.bottom));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_scene_jump.png'));
  });

  testWidgets('dragging a selection to the bottom edge keeps scrolling and selecting', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await _openEarnest(tester);
    await tester.tap(find.text('Morning-room, Half-Moon Street'));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const Key('sceneDropdown'));
    final row = find.descendant(of: sheet, matching: find.text('Tea, and a misunderstanding')); // scene 8: 41 lines
    await tester.scrollUntilVisible(
      row,
      120,
      scrollable: find.descendant(of: sheet, matching: find.byType(Scrollable)),
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    final list = find.byType(CustomScrollView);
    double offset() => tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable))).position.pixels;
    final before = offset();
    final start = tester.getCenter(find.text('Line 1 of scene 8, spoken with great feeling and a certain amount of wit.'));
    final g = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pump();
    final view = tester.getRect(list); // the selection bar has taken its place below the list
    await g.moveTo(Offset(start.dx, view.bottom - 10));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(offset() - before, greaterThan(300), reason: 'the list scrolled under the finger');
    final n = int.parse(RegExp(r'(\d+) lines selected').firstMatch(tester.widget<Text>(find.textContaining('lines selected')).data!)!.group(1)!);
    expect(n, greaterThan(8), reason: 'more lines than fit on screen at once');
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('Line! in the bar: only with Block My Lines; a hint the first time only', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await _openEarnest(tester);
    expect(find.byKey(const Key('lineButton')), findsNothing);
    await tester.tap(find.text('Rehearse'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Algernon'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block My Lines'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Forgot a line? '), findsNothing, reason: 'the hint is one rich text');
    expect(find.textContaining('Tap Line! below'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_line_hint.png'));
    const mine = 'Line 1 of scene 1, spoken with great feeling and a certain amount of wit.';
    await tester.tap(find.byKey(const Key('lineButton')));
    await tester.pump();
    expect(find.text(mine), findsOneWidget);
    expect(find.textContaining('Tap Line! below'), findsNothing, reason: 'using it dismisses the hint');
    await tester.tap(find.byKey(const Key('lineButton')));
    await tester.pump();
    expect(find.text(mine), findsNothing, reason: 'calling Line! again stops it');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('phoneLineHintSeen'), isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('tapping my blanked line shows it; tapping again hides it', (tester) async {
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
    const mine = 'Line 1 of scene 1, spoken with great feeling and a certain amount of wit.';
    await tester.tap(find.textContaining('____ _ __ _____ _'));
    await tester.pump();
    expect(find.text(mine), findsOneWidget);
    await tester.tap(find.text(mine));
    await tester.pump();
    expect(find.text(mine), findsNothing);
    // Left alone, a peek hides by itself.
    await tester.tap(find.textContaining('____ _ __ _____ _'));
    await tester.pump();
    expect(find.text(mine), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(mine), findsNothing);
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
    expect(saved?.device, anyOf('iPhone', 'iPad')); // which one depends on the screen the test pretends to have
    await _openEarnest(tester);
    await tester.pumpAndSettle();
    expect(find.byTooltip('My Character: Jack'), findsOneWidget); // the header's person icon lights up (the bar no longer repeats the role)
  });

  testWidgets('long-press a cover to ask the Mac to render it; it waits on the home screen', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await tester.longPress(find.text('THE IMPORTANCE OF BEING EARNEST'));
    await tester.pumpAndSettle();
    expect(find.textContaining('9 scenes not rendered yet'), findsOneWidget);
    await tester.tap(find.text('Ask Mac to Render'));
    await tester.pumpAndSettle();
    expect(find.text('WAITING FOR YOUR MAC'), findsOneWidget);
    expect(loadRenderRequest(earnestFolder)?.scenes, [3, 4, 5, 6, 7, 9, 10, 11, 12]);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_waiting.png'));
    await tester.longPress(find.text('THE IMPORTANCE OF BEING EARNEST'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel Render Request'));
    await tester.pumpAndSettle();
    expect(find.text('WAITING FOR YOUR MAC'), findsNothing);
    expect(loadRenderRequest(earnestFolder), isNull);
  });

  testWidgets('a project the Mac hasn\'t opened since the update asks for that', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await tester.tap(find.text('HAMLET'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open this project on your Mac once'), findsOneWidget);
  });
}
