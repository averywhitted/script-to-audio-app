// The iPhone app's screens (#90), rendered at iPhone size in light and dark
// (test/goldens/phone_*). The projects folder is a plain temp folder here;
// on the phone it comes through FolderAccess (ios/Runner/AppDelegate.swift).
// Run: flutter test --update-goldens test/phone_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/phone/phone_app.dart';
import 'package:table_read/phone/phone_store.dart';
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

void main() {
  setUpAll(() async {
    clockNow = () => DateTime(2026, 10, 10, 9, 14);
    await loadTestFonts();
    tmp = Directory('${Directory.systemTemp.path}/tr_phone_fixture');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    earnestFolder = writeProjects(tmp.path);
    saveScriptSnapshot(earnestFolder, earnestScript(), pdfFilename: 'script.pdf');
    for (final n in [1, 2]) {
      File('$earnestFolder/Scene_0${n}_Scene.m4a').writeAsStringSync('');
    }
  });

  test('the project list reads every project.json, newest first, and skips archives', () async {
    final s = await _store();
    expect(s.projects.map((p) => p.name).take(3), ['The Importance of Being Earnest', 'Hamlet', 'Uncle Vanya']);
    expect(s.projects.length, 8);
    expect(s.projects.every((p) => p.folderPath!.startsWith(tmp.path)), isTrue);
  });

  for (final b in [Brightness.light, Brightness.dark]) {
    final mode = b == Brightness.dark ? 'dark' : 'light';

    testWidgets('welcome $mode', (tester) async {
      await _pump(tester, await _store(withFolder: false), b);
      expect(find.text('Choose Folder'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_welcome_$mode.png'));
    });

    testWidgets('projects $mode, then open one', (tester) async {
      await _pump(tester, await _store(), b);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_projects_$mode.png'));
      await tester.tap(find.text('THE IMPORTANCE OF BEING EARNEST'));
      await tester.pumpAndSettle();
      // The scenes the Mac saved; rendered ones marked, the rest text only.
      expect(find.text('Morning-room, Half-Moon Street'), findsOneWidget);
      expect(find.text('Text only'), findsWidgets);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_project_$mode.png'));
    });
  }

  testWidgets('a project the Mac hasn\'t opened since the update asks for that', (tester) async {
    await _pump(tester, await _store(), Brightness.light);
    await tester.tap(find.text('HAMLET'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open this project on your Mac once'), findsOneWidget);
  });
}
