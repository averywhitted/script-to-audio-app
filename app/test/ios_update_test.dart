// The iPhone catch-up round: downloads you can queue and see (cloud / device icon on each cover), NEW and reading progress on
// covers, a playhead that follows the page (and scrubs it), lines that are pointed out then fade instead of playing, my lines in
// the character's colour, the outline on the iPhone's right edge, the floating line menu on the iPhone.
// Run: flutter test test/ios_update_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/phone/folder_access.dart';
import 'package:table_read/phone/phone_app.dart';
import 'package:table_read/phone/phone_store.dart';
import 'package:table_read/phone/rehearsal_screen.dart';
import 'package:table_read/phone/rehearsal_session.dart';
import 'package:table_read/phone/scene_timeline.dart';
import 'package:table_read/services/project_files.dart';
import 'package:table_read/theme/tokens.dart';

import 'fixtures.dart';

late Directory tmp;
late String earnest;

/// A pretend iCloud: .m4a files are "in the cloud" until the downloader fetches them, and each fetch waits for [gate].
class FakeCloud {
  final have = <String>{};
  final gates = <String, Completer<void>>{};
  final fetched = <String>[];

  Future<List<FolderEntry>> list(String path) async => [
    for (final e in Directory(path).listSync())
      if (!e.path.split('/').last.startsWith('.'))
        FolderEntry(
          e.path.split('/').last,
          isDir: e is Directory,
          downloaded: e is Directory || !e.path.endsWith('.m4a') || have.contains(e.path),
        ),
  ];

  Future<void> fetch(List<String> paths) async {
    for (final p in paths) {
      if (p.endsWith('.m4a')) {
        await (gates[p] ??= Completer<void>()).future;
        have.add(p);
        fetched.add(p);
      }
    }
  }

  void release(String path) => (gates[path] ??= Completer<void>()).complete();
}

/// [n] projects (of writeProjects' eight) each get one audio file that has to come from the cloud.
List<String> _audioFor(int n) {
  final out = <String>[];
  for (final d in Directory(tmp.path).listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path))) {
    if (!File('${d.path}/project.json').existsSync() || out.length >= n) continue;
    final f = File('${d.path}/Scene_01_Scene.m4a')..writeAsStringSync('x');
    out.add(f.path);
  }
  return out;
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(402, 874);
  tester.view.devicePixelRatio = 1;
  tester.view.display.size = const Size(402, 874); // an iPhone: not an iPad
  tester.view.display.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

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
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory('${Directory.systemTemp.path}/tr_ios_update_fixture')..createSync(recursive: true);
    for (final e in tmp.listSync()) {
      e.deleteSync(recursive: true);
    }
    earnest = writeProjects(tmp.path);
  });

  group('downloads', () {
    test('a project is in the cloud until its files are on the device', () async {
      final cloud = FakeCloud();
      _audioFor(1);
      final s = PhoneStore(lister: cloud.list, downloader: cloud.fetch)..folder = tmp.path;
      await s.refresh();
      final p = s.projects.firstWhere((p) => p.folderPath == _folderWithAudio());
      expect(s.phaseOf(p), DownloadPhase.cloud);
      expect(s.phaseOf(s.projects.firstWhere((q) => q.id != p.id)), DownloadPhase.device); // nothing to fetch: already here
    });

    test('several downloads come one after another, in the order asked, and can be taken out of the line', () async {
      final cloud = FakeCloud();
      final files = _audioFor(3);
      final s = PhoneStore(lister: cloud.list, downloader: cloud.fetch)..folder = tmp.path;
      await s.refresh();
      final ps = [for (final f in files) s.projects.firstWhere((p) => f.startsWith(p.folderPath!))];
      for (final p in ps) {
        s.enqueue(p);
      }
      await _settle();
      expect(s.phaseOf(ps[0]), DownloadPhase.downloading);
      expect(s.phaseOf(ps[1]), DownloadPhase.queued);
      expect(s.phaseOf(ps[2]), DownloadPhase.queued);
      expect(s.queuePlace(ps[1]), 1);
      expect(s.queuePlace(ps[2]), 2);
      expect(cloud.gates.keys, [files[0]]); // only the first has been asked for

      s.cancelDownload(ps[2]); // out of the line
      expect(s.phaseOf(ps[2]), DownloadPhase.cloud);

      cloud.release(files[0]);
      await _settle();
      expect(s.phaseOf(ps[0]), DownloadPhase.device);
      expect(s.phaseOf(ps[1]), DownloadPhase.downloading);

      cloud.release(files[1]);
      await _settle();
      expect(s.phaseOf(ps[1]), DownloadPhase.device);
      expect(s.queue, isEmpty);
      expect(cloud.fetched, [files[0], files[1]]); // the cancelled one was never fetched
    });

    test('opening a project that is waiting in the line brings it forward', () async {
      final cloud = FakeCloud();
      final files = _audioFor(2);
      final s = PhoneStore(lister: cloud.list, downloader: cloud.fetch)..folder = tmp.path;
      await s.refresh();
      final ps = [for (final f in files) s.projects.firstWhere((p) => f.startsWith(p.folderPath!))];
      s.enqueue(ps[0]);
      s.enqueue(ps[1]);
      await _settle();
      expect(s.phaseOf(ps[1]), DownloadPhase.queued);
      final opened = s.download(ps[1]); // what tapping the cover does
      await _settle();
      expect(s.phaseOf(ps[1]), DownloadPhase.downloading);
      cloud.release(files[1]);
      expect(await opened, isTrue);
      expect(s.phaseOf(ps[1]), DownloadPhase.device);
      cloud.release(files[0]);
      await _settle();
      expect(s.queue, isEmpty);
    });

    test('a running download can be cancelled; what arrived stays', () async {
      final cloud = FakeCloud();
      final files = _audioFor(1);
      File('${File(files[0]).parent.path}/Scene_02_Scene.m4a').writeAsStringSync('x');
      final s = PhoneStore(lister: cloud.list, downloader: cloud.fetch)..folder = tmp.path;
      await s.refresh();
      final p = s.projects.firstWhere((p) => files[0].startsWith(p.folderPath!));
      s.enqueue(p);
      await _settle();
      s.cancelDownload(p);
      for (final f in Directory(p.folderPath!).listSync().where((f) => f.path.endsWith('.m4a'))) {
        cloud.release(f.path);
      }
      await _settle();
      expect(s.downloading, isEmpty);
      expect(s.phaseOf(p), DownloadPhase.cloud); // it stopped before the second file
    });

    testWidgets('each cover shows where it is; the icon opens the options, and Download queues it', (tester) async {
      final cloud = FakeCloud();
      final files = _audioFor(2);
      final s = PhoneStore(lister: cloud.list, downloader: cloud.fetch)..folder = tmp.path;
      await s.refresh();
      final ps = [for (final f in files) s.projects.firstWhere((p) => f.startsWith(p.folderPath!))];
      _phone(tester);
      await tester.pumpWidget(PhoneApp(store: s, themeMode: ThemeMode.light));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.byIcon(Icons.cloud_download_outlined), findsNWidgets(2)); // the two with files still in iCloud
      expect(find.byIcon(Icons.download_done_rounded), findsNWidgets(6)); // the rest are here

      await tester.tap(find.byKey(Key('download_${ps[0].id}')));
      await tester.pumpAndSettle();
      expect(find.text('In iCloud Drive only. Not on this device yet.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('downloadProject')));
      await tester.pumpAndSettle();
      // The second is asked for too, and waits behind the first.
      await tester.tap(find.byKey(Key('download_${ps[1].id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloadProject')));
      await tester.pumpAndSettle();
      expect(s.phaseOf(ps[0]), DownloadPhase.downloading);
      expect(s.phaseOf(ps[1]), DownloadPhase.queued);
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget); // the ring on the one coming down

      await tester.tap(find.byKey(Key('download_${ps[1].id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Waiting for a download to finish'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cancelDownload')));
      await tester.pumpAndSettle();
      expect(s.phaseOf(ps[1]), DownloadPhase.cloud);

      cloud.release(files[0]);
      await tester.runAsync(_settle);
      await tester.pumpAndSettle();
      expect(s.phaseOf(ps[0]), DownloadPhase.device);
    });
  });

  group('new and progress', () {
    testWidgets('a downloaded project nobody has opened is NEW; opening it ends that, and the bar follows where you read to', (tester) async {
      final s = PhoneStore(folderAccess: false)..folder = tmp.path;
      await s.refresh();
      _phone(tester);
      await tester.pumpWidget(PhoneApp(store: s, themeMode: ThemeMode.light));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('coverNew')), findsNWidgets(8));
      expect(find.byKey(const Key('coverProgress')), findsNothing);

      final p = s.projects.firstWhere((p) => p.folderPath == earnest);
      await s.markOpened(p);
      await tester.pump();
      expect(find.byKey(const Key('coverNew')), findsNWidgets(7));

      // Another device read to 40 % of it (the shared rehearsal file says so).
      writeRehearsal(earnest, 'OTHER-DEVICE', RehearsalState(readScene: 4, readLine: 'x', readProgress: 0.4, device: 'iPad'));
      s.refreshProgress();
      await tester.pump();
      expect(s.progress[p.id], 0.4);
      expect(find.byKey(const Key('coverProgress')), findsOneWidget);
      final bar = tester.getSize(find.byKey(const Key('coverProgress')));
      final track = tester.getSize(find.byKey(const Key('coverProgress'))).width / 0.4;
      expect(bar.width / track, closeTo(0.4, 0.01));
      // Read on another device counts as opened: not NEW any more, even where it was never opened here.
      final q = s.projects.firstWhere((q) => q.name == 'Hamlet');
      writeRehearsal(q.folderPath!, 'OTHER-DEVICE', RehearsalState(readScene: 1, readLine: 'y', readProgress: 0.05, device: 'iPad'));
      s.refreshProgress();
      expect(s.isNew(q), isFalse);
    });
  });

  group('rehearsal', () {
    late Scene firstScene;
    setUp(() {
      final script = earnestScript();
      firstScene = script.scenes[0];
      saveScriptSnapshot(earnest, script, pdfFilename: 'script.pdf');
      for (final n in [1, 2, 8]) {
        _writeCues(earnest, n, script.scenes[n - 1]);
      }
    });

    String clock(double s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

    /// The previous test's screen saves its place as it goes: let it, wipe it, then open the play on [size] (an iPhone unless it is a big one).
    Future<PhoneStore> open(WidgetTester tester, {Size size = const Size(402, 874)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.display.size = size;
      tester.view.display.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      final r = Directory('$earnest/$rehearsalFolder');
      if (r.existsSync()) r.deleteSync(recursive: true);
      final s = PhoneStore(folderAccess: false)..folder = tmp.path;
      await s.refresh();
      await tester.pumpWidget(PhoneApp(store: s, themeMode: ThemeMode.light));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.text('THE IMPORTANCE OF BEING EARNEST'), warnIfMissed: false);
      await tester.pumpAndSettle();
      return s;
    }

    final line3 = find.text('Line 3 of scene 1, spoken with great feeling and a certain amount of wit.');

    testWidgets('the outline is on the right edge half way down on an iPhone, and stays on the left on an iPad', (tester) async {
      await open(tester);
      final phone = tester.getCenter(find.byKey(const Key('outlineRail')));
      expect(phone.dx, greaterThan(402 - 40));
      expect(phone.dy, closeTo(tester.getRect(find.byType(CustomScrollView)).center.dy, 120));
      await tester.tap(find.byKey(const Key('outlineRail')));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const Key('outlineOpen'))).right, greaterThan(402 - 20)); // opens leftwards from the edge

      await open(tester, size: const Size(834, 1194));
      expect(tester.getCenter(find.byKey(const Key('outlineRail'))).dx, lessThan(60));
    });

    testWidgets('tapping a line points it out for a moment and moves the playhead there; it does not play', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('lineIndicator')), findsNothing);
      await tester.tap(line3);
      await tester.pump();
      expect(find.byKey(const Key('lineIndicator')), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget); // still stopped
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      expect(find.text('0:09'), findsOneWidget); // the playhead is on that line (the fourth, 9 s in)
      await tester.pump(const Duration(milliseconds: 500)); // held for a moment...
      await tester.pump(const Duration(milliseconds: 300)); // ...then fading
      expect(find.byKey(const Key('lineIndicator')), findsOneWidget);
      expect(tester.widget<FadeTransition>(find.ancestor(of: find.byKey(const Key('lineIndicator')), matching: find.byType(FadeTransition)).first).opacity.value,
          lessThan(1));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('lineIndicator')), findsNothing); // gone
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      // Play then plays from there.
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    });

    testWidgets('scrolling the script moves the playhead; crossing into another scene swaps the timeline; Play starts from there', (tester) async {
      await open(tester);
      expect(find.text('0:00'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -260));
      await tester.pumpAndSettle();
      expect(find.text('0:00'), findsNothing); // the playhead went with the page
      final scene1 = clock(firstScene.elements.length * 3.0);
      expect(find.text(scene1), findsOneWidget);

      // Into scene 8 (a longer one).
      final scene2 = clock(earnestScript().scenes[7].elements.length * 3.0);
      expect(scene2, isNot(scene1));
      await tester.tap(find.text('Morning-room, Half-Moon Street').first); // the scene bar's list
      await tester.pumpAndSettle();
      final sheet = find.byKey(const Key('sceneDropdown'));
      final row = find.descendant(of: sheet, matching: find.text('Tea, and a misunderstanding'));
      await tester.scrollUntilVisible(row, 120, scrollable: find.descendant(of: sheet, matching: find.byType(Scrollable)));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text(scene2), findsOneWidget);
      expect(find.text(scene1), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget); // nothing started by looking

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.text(scene2), findsOneWidget); // playing scene 8, not the scene the player was parked in
    });

    testWidgets('dragging the playhead scrolls the script and outlines the line under it, which fades when you let go', (tester) async {
      await open(tester);
      final line1 = find.text('Line 1 of scene 1, spoken with great feeling and a certain amount of wit.');
      // Scroll the first lines away, then scrub back to the start.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(line1.hitTestable(), findsNothing);
      final rect = tester.getRect(find.byType(PhoneTimeline));
      final g = await tester.startGesture(Offset(rect.left + rect.width * 0.5, rect.center.dy));
      await tester.pump();
      await g.moveTo(Offset(rect.left + 2, rect.center.dy));
      await tester.pump();
      expect(find.byKey(const Key('lineIndicator')), findsOneWidget); // pointed out while the finger is down
      expect(line1.hitTestable(), findsOneWidget); // the script ran back to the line under the playhead
      expect(find.text('0:00'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('lineIndicator')), findsOneWidget); // no fading while held
      await g.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('lineIndicator')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('lineIndicator')), findsNothing);
      expect(find.text('0:00'), findsOneWidget);
    });

    testWidgets('my lines are filled in my character\'s colour', (tester) async {
      final store = await open(tester);
      await tester.tap(find.text('Rehearse'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Algernon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final t = Tokens.of(tester.element(find.text('· YOU').first));
      final characters = RehearsalSession.load(store.projects.firstWhere((p) => p.folderPath == earnest)).characters;
      final mine = find.ancestor(of: find.text('· YOU').first, matching: find.byType(AnimatedContainer)).first;
      final fill = (tester.widget<AnimatedContainer>(mine).decoration! as BoxDecoration).color;
      expect(fill, speakerColors('ALGERNON', characters, t).highlight);
      expect(fill, isNot(t.mine)); // not the old yellow
    });

    testWidgets('the line menu floats on the line on an iPhone too, with room for its buttons', (tester) async {
      await open(tester);
      await tester.longPress(line3);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('floatingMenu')), findsOneWidget);
      expect(find.byKey(const Key('noteLine')), findsOneWidget); // icons, not words, on the narrow screen
      expect(find.byKey(const Key('bookmarkLine')), findsOneWidget);
      expect(find.text('Loop'), findsOneWidget);
      expect(tester.takeException(), isNull); // nothing overflowed
      final menu = tester.getRect(find.byKey(const Key('floatingMenu')));
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(402));
      expect(menu.bottom, lessThanOrEqualTo(tester.getRect(line3).top + 4)); // above the line, attached to it
    });

    testWidgets('the PDF opens on the page of the line at the top of the screen, not where the player was left', (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      tester.view.display.size = const Size(402, 874);
      tester.view.display.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      final r = Directory('$earnest/$rehearsalFolder');
      if (r.existsSync()) r.deleteSync(recursive: true);
      final store = PhoneStore(folderAccess: false)..folder = tmp.path;
      await store.refresh();
      final script = earnestScript();
      // One PDF page per scene.
      Future<List<String>> pageTexts(String _) async => [for (final sc in script.scenes) sc.elements.map((e) => e.text).join('\n')];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: PhoneRehearsalScreen(
            project: store.projects.firstWhere((p) => p.folderPath == earnest),
            store: store,
            folderAccess: false,
            audio: false,
            pageTexts: pageTexts,
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      // The player is parked in scene 1; look at scene 5.
      await tester.tap(find.text('Morning-room, Half-Moon Street').first);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byKey(const Key('sceneDropdown')), matching: find.text(sceneTitles[4])));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show PDF'));
      await tester.pumpAndSettle();
      final screen = tester.widget(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_PdfScreen'));
      expect((screen as dynamic).page, 5);
    });
  });
}

String _folderWithAudio() {
  for (final d in Directory(tmp.path).listSync().whereType<Directory>()) {
    if (File('${d.path}/Scene_01_Scene.m4a').existsSync()) return d.path;
  }
  return '';
}
