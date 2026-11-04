// The rehearsal tools added with the iPad version (#113-#121), exercised on screen:
// search, My Character without audio, notes, page breaks, Remove Download, the
// keyboard, and the iPad layouts (goldens in test/goldens/ipad_*).
// Run: flutter test --update-goldens test/ipad_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/phone/bookmarks.dart';
import 'package:table_read/phone/ink_layer.dart';
import 'package:table_read/phone/line_notes.dart';
import 'package:table_read/phone/pdf_view.dart';
import 'package:table_read/phone/phone_app.dart';
import 'package:table_read/phone/phone_store.dart';
import 'package:table_read/phone/rehearsal_screen.dart';
import 'package:table_read/phone/rehearsal_session.dart';
import 'package:table_read/services/project_files.dart';
import 'package:table_read/theme/tokens.dart';

import 'fixtures.dart';

late Directory tmp;
late String folder;

Future<PhoneStore> _store() async {
  final s = PhoneStore(folderAccess: false)..folder = tmp.path;
  await s.refresh();
  return s;
}

void _size(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The previous test's screen is still mounted, and saves its place (rehearsal file) when it goes: let it, then wipe it.
Future<void> _forgetLastTest(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  final r = Directory('$folder/$rehearsalFolder');
  if (r.existsSync()) r.deleteSync(recursive: true);
}

Future<void> _pump(WidgetTester tester, {Size size = const Size(402, 874), Brightness b = Brightness.light}) async {
  _size(tester, size.width, size.height);
  await _forgetLastTest(tester);
  await tester.pumpWidget(PhoneApp(store: await _store(), themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

Future<void> _openEarnest(WidgetTester tester) async {
  await tester.tap(find.text('THE IMPORTANCE OF BEING EARNEST'));
  await tester.pumpAndSettle();
}

/// The first screen, opened straight (to give it a PDF reader of its own).
Future<void> _pumpScreen(WidgetTester tester, {required Future<List<String>> Function(String) pageTexts, Size size = const Size(402, 874)}) async {
  _size(tester, size.width, size.height);
  final store = await _store();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: PhoneRehearsalScreen(project: store.projects.first, store: store, folderAccess: false, audio: false, pageTexts: pageTexts),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

const _line1 = 'Line 1 of scene 1, spoken with great feeling and a certain amount of wit.';
const _line3 = 'Line 3 of scene 1, spoken with great feeling and a certain amount of wit.';

void main() {
  setUpAll(() async {
    clockNow = () => DateTime(2026, 10, 10, 9, 14);
    await loadTestFonts();
    tmp = Directory('${Directory.systemTemp.path}/tr_ipad_fixture');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    folder = writeProjects(tmp.path);
    // Nothing rendered: every scene is text only, as on a phone that imported the PDF itself.
    saveScriptSnapshot(folder, earnestScript(), pdfFilename: 'script.pdf');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final d in [rehearsalFolder, notesFolder, 'Markup', bookmarksFolder]) {
      final dir = Directory('$folder/$d');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('My Character without audio (#114)', () {
    testWidgets('picking a character highlights their lines in a text-only project, and is saved', (tester) async {
      await _pump(tester);
      await _openEarnest(tester);
      expect(find.text('Rehearse'), findsNothing); // no playback bar: nothing is rendered
      expect(find.text('· YOU'), findsNothing);
      await tester.tap(find.byTooltip('My Character'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Algernon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('· YOU'), findsWidgets);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
      expect(loadNewestRehearsal(folder)?.role, 'ALGERNON');
    });

    testWidgets('Block My Lines works on text too', (tester) async {
      await _pump(tester);
      await _openEarnest(tester);
      await tester.tap(find.byTooltip('My Character'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Algernon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block My Lines'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text(_line1), findsNothing);
      expect(find.textContaining('____ _ __ _____ _'), findsWidgets);
    });
  });

  group('search (#113)', () {
    testWidgets('finds a phrase far down the script and scrolls to it; next and previous step through', (tester) async {
      await _pump(tester);
      await _openEarnest(tester);
      await tester.tap(find.byTooltip('Search the script'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('scriptSearchField')), 'scene 11,');
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'^1 of \d+$')), findsOneWidget);
      expect(find.textContaining('of scene 11,'), findsWidgets); // scrolled there, past ten unbuilt scenes
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'^2 of \d+$')), findsOneWidget);
      await tester.tap(find.byTooltip('Previous match'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'^1 of \d+$')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('scriptSearchField')), 'zzzzqq');
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scriptSearchField')), findsNothing);
    });

    testWidgets('Command-F opens the search, and Escape closes it (iPad keyboard)', (tester) async {
      await _pump(tester, size: const Size(1194, 834));
      await _openEarnest(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scriptSearchField')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scriptSearchField')), findsNothing);
    });
  });

  group('notes (#117)', () {
    testWidgets('add a note to a line: it collapses to a flag, opens again, and is saved in the project', (tester) async {
      await _pump(tester);
      await _openEarnest(tester);
      await tester.longPress(find.text(_line3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('noteField')), 'Take a breath before this');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('noteFlag')), findsOneWidget);
      expect(find.byKey(const Key('noteCard')), findsOneWidget); // open right after saving
      expect(find.text('Take a breath before this'), findsOneWidget);
      await tester.tap(find.byKey(const Key('noteFlag')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('noteCard')), findsNothing); // collapsed to the flag
      expect(find.byKey(const Key('noteFlag')), findsOneWidget);
      await tester.tap(find.byKey(const Key('noteFlag')));
      await tester.pumpAndSettle();
      expect(find.text('Take a breath before this'), findsOneWidget);
      final files = Directory('$folder/$notesFolder').listSync();
      expect(files.length, 1);
      expect((jsonDecode(File(files.single.path).readAsStringSync()) as Map)['notes'], hasLength(1));
    });

    testWidgets('a note can be edited and deleted', (tester) async {
      await _pump(tester);
      await _openEarnest(tester);
      Future<void> addNote(String text) async {
        await tester.longPress(find.text(_line3));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining(RegExp(r'^(Edit )?Note$')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('noteField')), text);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
      }

      await addNote('first');
      await addNote('second');
      expect(find.text('second'), findsOneWidget);
      expect(find.text('first'), findsNothing);
      await tester.tap(find.byTooltip('Edit note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('noteFlag')), findsNothing);
    });
  });

  group('PDF page numbers (#116)', () {
    // Three lines to a page.
    Future<List<String>> texts(String _) async {
      final session = RehearsalSession.load((await _store()).projects.first);
      final all = [for (final s in session.scenes) ...s.lines.map((l) => l.text)];
      return [for (var i = 0; i < all.length; i += 3) all.skip(i).take(3).join('\n')];
    }

    testWidgets('a dotted line and "p. N" mark each page break once Page numbers is on', (tester) async {
      await _pumpScreen(tester, pageTexts: texts);
      expect(find.text('p. 2'), findsNothing);
      await tester.tap(find.text('Aa'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Page numbers'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 20)); // outside the sheet: closes it
      await tester.pumpAndSettle();
      expect(find.text('p. 2'), findsOneWidget);
      expect(find.text('p. 3'), findsOneWidget);
      expect(find.text('p. 1'), findsNothing); // the first page needs no break above it
    });
  });

  group('Remove Download (#118)', () {
    testWidgets('is offered when a project has files on the device, with how much it frees', (tester) async {
      File('$folder/Scene_01_Scene.m4a').writeAsBytesSync(Uint8List(900 * 1024));
      addTearDown(() => File('$folder/Scene_01_Scene.m4a').deleteSync());
      await _pump(tester);
      await tester.longPress(find.text('THE IMPORTANCE OF BEING EARNEST'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Download'), findsOneWidget);
      expect(find.textContaining('Frees 9'), findsOneWidget); // 900 KB
      await tester.tap(find.text('Remove Download'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing to remove'), findsOneWidget); // no iCloud in tests: the plugin does the work on the device
    });

    testWidgets('says there is nothing to remove for a project that is only its script', (tester) async {
      await _pump(tester);
      await tester.longPress(find.text('HAMLET'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing downloaded to remove.'), findsOneWidget);
    });
  });

  group('iPad layouts (#121)', () {
    for (final b in [Brightness.light, Brightness.dark]) {
      final mode = b == Brightness.dark ? 'dark' : 'light';

      testWidgets('projects fill the width $mode', (tester) async {
        await _pump(tester, size: const Size(834, 1194), b: b);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/ipad_projects_$mode.png'));
      });

      testWidgets('rehearsal: the script centred, with the outline along the edge $mode', (tester) async {
        await _pump(tester, size: const Size(1194, 834), b: b);
        await _openEarnest(tester);
        expect(find.byTooltip('Projects'), findsOneWidget); // same header as the phone: back button, no sidebar
        expect(find.text('Morning-room, Half-Moon Street'), findsNWidgets(2)); // the bar and the title in the script
        expect(find.byKey(const Key('outlineRail')), findsOneWidget);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/ipad_rehearse_$mode.png'));
      });
    }

    testWidgets('the PDF sits beside the script on a wide window, with the iPad tools', (tester) async {
      await _pump(tester, size: const Size(1366, 1024));
      await _openEarnest(tester);
      await tester.tap(find.byTooltip('Show PDF'));
      await tester.pumpAndSettle();
      expect(find.text('Script PDF'), findsOneWidget);
      expect(find.byTooltip('Mark up with Apple Pencil'), findsOneWidget);
      expect(find.byTooltip('Read one page at a time'), findsOneWidget);
      await tester.tap(find.byTooltip('Mark up with Apple Pencil'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Draw with a finger too'), findsOneWidget);
      // The Pencil's own tools: undo / redo (greyed until there is something) and clearing the page.
      expect(find.byTooltip('Undo'), findsOneWidget);
      expect(find.byTooltip('Redo'), findsOneWidget);
      expect(find.byTooltip('Clear this page’s markup'), findsOneWidget);
      await tester.tap(find.byTooltip('Close PDF'));
      await tester.pumpAndSettle();
      expect(find.text('Script PDF'), findsNothing);
    });

    testWidgets('the PDF has the whole screen, also on a wide landscape window', (tester) async {
      await _pump(tester, size: const Size(1194, 834));
      await _openEarnest(tester);
      await tester.tap(find.byTooltip('Show PDF'));
      await tester.pumpAndSettle();
      expect(find.text('Script PDF'), findsOneWidget);
      expect(find.byTooltip('Close PDF'), findsOneWidget);
      expect(find.text('Morning-room, Half-Moon Street'), findsNothing); // the script is not beside it
      await tester.tap(find.byTooltip('Close PDF'));
      await tester.pumpAndSettle();
      expect(find.text('Script PDF'), findsNothing);
    });

    testWidgets('the outline: dashes for the scenes; tap opens the headings, picking one jumps there and folds it', (tester) async {
      await _pump(tester, size: const Size(1194, 834));
      await _openEarnest(tester);
      expect(find.byKey(const Key('outlineOpen')), findsNothing);
      await tester.tap(find.byKey(const Key('outlineRail')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('outlineOpen')), findsOneWidget);
      final target = sceneTitles[4];
      await tester.tap(find.descendant(of: find.byKey(const Key('outlineOpen')), matching: find.text(target)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('outlineOpen')), findsNothing);
      expect(find.textContaining('of scene 5,'), findsWidgets);
    });

    testWidgets('the outline folds away when the script is scrolled', (tester) async {
      await _pump(tester, size: const Size(1194, 834));
      await _openEarnest(tester);
      await tester.tap(find.byKey(const Key('outlineRail')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('outlineOpen')), findsOneWidget);
      await tester.drag(find.text(_line3), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('outlineOpen')), findsNothing);
    });
  });

  group('Bookmarks', () {
    testWidgets('bookmark a line from the selection bar; it is marked, listed, saved, and removable', (tester) async {
      await _pump(tester);
      await _openEarnest(tester);
      await tester.longPress(find.text(_line3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bookmarkLine')));
      await tester.pumpAndSettle();
      final files = Directory('$folder/Bookmarks').listSync();
      expect(files.length, 1);
      expect((jsonDecode(File(files.single.path).readAsStringSync()) as Map)['bookmarks'], hasLength(1));
      await tester.tap(find.byTooltip('Bookmarks')); // a text-only project has the button in the header
      await tester.pumpAndSettle();
      expect(find.text('Bookmarks'), findsOneWidget);
      expect(find.text(_line3), findsNWidgets(2)); // the line, and its row in the list
      await tester.tap(find.byTooltip('Remove bookmark'));
      await tester.pumpAndSettle();
      expect(find.text('No bookmarks yet. You can also long-press a line and tap Bookmark.'), findsOneWidget);
    });

    testWidgets('"Bookmark this spot" marks the line at the top of the screen', (tester) async {
      await _pump(tester);
      await _openEarnest(tester);
      await tester.tap(find.byTooltip('Bookmarks'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bookmarkHere')));
      await tester.pumpAndSettle();
      expect(find.text('Remove the bookmark here'), findsOneWidget);
      expect(find.textContaining('scene 1'), findsWidgets);
    });

    test('bookmarks from two devices merge, newest wins, a removal beats an older copy', () async {
      final dir = Directory.systemTemp.createTempSync('tr_bm');
      addTearDown(() => dir.deleteSync(recursive: true));
      var now = DateTime.utc(2026, 11, 3, 10);
      clockNow = () => now;
      final a = Bookmarks(folder: dir.path, deviceId: 'A', folderAccess: false);
      final b = Bookmarks(folder: dir.path, deviceId: 'B', folderAccess: false);
      await a.add('k1', 1, 'first');
      await a.add('k2', 2, 'second');
      now = now.add(const Duration(minutes: 5));
      b.load();
      await b.remove('k1'); // B removes it later than A made it
      a.load();
      expect(a.live.keys, ['k2']);
      expect(b.live.keys, ['k2']);
      clockNow = () => DateTime(2026, 10, 10, 9, 14);
    });
  });

  group('Position sync', () {
    testWidgets('opening the project goes to where the script was last being read, on any device', (tester) async {
      // Another device was reading scene 5.
      final script = loadScriptSnapshot(folder)!;
      final scene = script.scenes[4];
      final screenState = RehearsalSession.load((await _store()).projects.first);
      final target = screenState.scenes.firstWhere((s) => s.number == scene.number);
      await _pump(tester, size: const Size(1194, 834));
      writeRehearsal(
        folder,
        'OTHER',
        RehearsalState(readScene: target.number, readLine: target.lines.first.key, device: 'iPhone', updatedAt: DateTime.utc(2026, 11, 3, 12)),
      );
      await _openEarnest(tester);
      expect(find.textContaining('of scene ${target.number},'), findsWidgets);
    });

    testWidgets('another device reading further on offers a jump; Jump there goes, dismiss keeps still', (tester) async {
      await _pump(tester, size: const Size(1194, 834));
      await _openEarnest(tester);
      final session = RehearsalSession.load((await _store()).projects.first);
      final target = session.scenes[6];
      expect(find.byKey(const Key('syncChip')), findsNothing);
      // The other device writes (its file is newer than anything this one has).
      writeRehearsal(
        folder,
        'OTHER',
        RehearsalState(readScene: target.number, readLine: target.lines.first.key, device: 'iPhone', updatedAt: DateTime.utc(2099, 1, 1)),
      );
      final state = tester.state(find.byType(PhoneRehearsalScreen));
      await ((state as dynamic).checkOtherDevicesForTest() as Future<void>);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('syncChip')), findsOneWidget);
      expect(find.textContaining('iPhone is at scene ${target.number}'), findsOneWidget);
      await tester.tap(find.text('Jump there'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('syncChip')), findsNothing);
      expect(find.textContaining('of scene ${target.number},'), findsWidgets);
    });
  });

  group('Markup and characters', () {
    test('ink: strokes save as JSON, come back, erase by stroke, undo and redo', () {
      final c = PdfController()..pageCount = 3;
      final saved = <int, String>{};
      c.onMarkup = (p, d) => saved[p] = d;
      InkStroke stroke(double x) => InkStroke(marker: false, color: 0xFF1C1B19, width: 0.005, points: [Offset(x, 0.2), Offset(x + 0.1, 0.3)]);
      c.commitStroke(stroke(0.1));
      c.commitStroke(stroke(0.5));
      expect(c.strokesOnPage.length, 2);
      expect(decodeInk(saved[0]!).length, 2);
      c.beginEdit();
      c.eraseAt(const Offset(0.55, 0.25)); // on the second stroke
      c.endEdit();
      expect(c.strokesOnPage.length, 1);
      c.undo();
      expect(c.strokesOnPage.length, 2);
      c.redo();
      expect(c.strokesOnPage.length, 1);
      c.clearPage();
      expect(saved[0], ''); // nothing left on the page
      c.undo();
      expect(c.strokesOnPage.length, 1);
      // A new controller starts from what was saved.
      final d = PdfController()
        ..initialMarkup = {
          '0': encodeInk([stroke(0.1)]),
        };
      expect(d.ink[0]!.single.points.length, 2);
    });

    testWidgets('several characters can be picked, and all of their lines are marked', (tester) async {
      await _pump(tester);
      await _openEarnest(tester);
      await tester.tap(find.byTooltip('My Character'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Algernon'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Cecily'));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Algernon')).selected, isTrue);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Cecily')).selected, isTrue);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      // Scene 1: line 1 is Algernon's, line 2 Cecily's: both are mine.
      expect(find.text('· YOU'), findsAtLeastNWidgets(2));
    });

    testWidgets('dragging along the outline scrolls the script; a note can be deleted from the menu', (tester) async {
      await _pump(tester, size: const Size(1194, 834));
      await _openEarnest(tester);
      await tester.longPress(find.text(_line3));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('floatingMenu')), findsOneWidget);
      await tester.tap(find.text('Note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('noteField')), 'x');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text(_line3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deleteNote')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('noteFlag')), findsNothing);
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
      final before = scroll.position.pixels;
      await tester.drag(find.byKey(const Key('outlineRail')), const Offset(0, 70));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(before));
    });
  });
}
