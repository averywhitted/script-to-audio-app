// Renders every screen to PNG (test/goldens/) in light and dark so the UI can
// be reviewed without launching the app. Run: flutter test --update-goldens test/screens_test.dart

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/services/project_store.dart';
import 'package:table_read/services/settings.dart';
import 'package:table_read/state/app_state.dart';
import 'package:table_read/state/player_state.dart';
import 'package:table_read/theme/tokens.dart';
import 'package:table_read/ui/cast_dialog.dart';
import 'package:table_read/ui/dashboard.dart';
import 'package:table_read/ui/log_dialog.dart';
import 'package:table_read/ui/render_dialog.dart';
import 'package:table_read/ui/gallery.dart';
import 'package:table_read/ui/popovers.dart';
import 'package:table_read/ui/sheets.dart';
import 'package:table_read/ui/widgets.dart';

import 'fixtures.dart';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await loader.load();
  }

  const fonts = 'assets/fonts';
  await family('Hanken', [
    '$fonts/HankenGrotesk-Regular.ttf',
    '$fonts/HankenGrotesk-Medium.ttf',
    '$fonts/HankenGrotesk-SemiBold.ttf',
    '$fonts/HankenGrotesk-Bold.ttf',
  ]);
  await family('CourierPrime', ['$fonts/CourierPrime-Regular.ttf', '$fonts/CourierPrime-Bold.ttf', '$fonts/CourierPrime-Italic.ttf']);
  await family('Caveat', ['$fonts/Caveat-SemiBold.ttf']);
  await family('YoungSerif', ['$fonts/YoungSerif-Regular.ttf']);
  final sdk = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path; // .../bin/cache/artifacts/engine/<host>/flutter_tester
  for (final candidate in [
    '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await family('MaterialIcons', [candidate]);
      break;
    }
  }
}

late Directory tmp;
late String earnestFolder;

Future<(AppState, ProjectStore, RehearsalPlayer)> _makeState() async {
  SharedPreferences.setMockInitialValues({'importedSwiftSettings': true, 'hasSeenOnboarding': true, 'projectsBaseURL': tmp.path});
  final settings = await Settings.load();
  final store = ProjectStore(settings);
  final app = AppState(settings, store, startBackgroundTasks: false);
  return (app, store, RehearsalPlayer(audioEnabled: false));
}

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  Brightness b, {
  required AppState app,
  required ProjectStore store,
  required RehearsalPlayer player,
}) async {
  tester.view.physicalSize = const Size(1320, 860);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider.value(value: player),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

Future<void> _snap(WidgetTester tester, String name) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(() async {
    clockNow = () => DateTime(2026, 10, 10, 9, 14);
    await _loadFonts();
    tmp = Directory('${Directory.systemTemp.path}/tr_screens_fixture');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    earnestFolder = writeProjects(tmp.path);
  });

  for (final b in [Brightness.light, Brightness.dark]) {
    final mode = b == Brightness.dark ? 'dark' : 'light';

    testWidgets('gallery $mode', (tester) async {
      final (app, store, player) = await _makeState();
      await _pump(tester, const GalleryScreen(), b, app: app, store: store, player: player);
      await _snap(tester, 'gallery_grid_$mode');
      // Select two projects and show the selection bar.
      await tester.tap(find.text('HAMLET'));
      await tester.pump();
      await _snap(tester, 'gallery_selected_$mode');
      await tester.tap(find.byIcon(Icons.view_list_rounded));
      await _snap(tester, 'gallery_list_$mode');
      await tester.tap(find.text('Archived'));
      await _snap(tester, 'gallery_archived_$mode');
    });

    testWidgets('dashboard $mode', (tester) async {
      final (app, store, player) = await _makeState();
      final p = store.projects.firstWhere((x) => x.name.startsWith('The Importance'));
      store.currentProject = p;
      loadEarnest(app, earnestFolder);
      await _pump(tester, const DashboardScreen(), b, app: app, store: store, player: player);
      await _snap(tester, 'workspace_$mode');
      await tester.tap(find.text('Morning-room at the Manor House'));
      await tester.pumpAndSettle();
      await _snap(tester, 'workspace_scene_$mode');
      app.setCharacterColors(false);
      await _snap(tester, 'workspace_plain_names_$mode');
      app.setCharacterColors(true);

      // Hover a line: checkbox, Play, Edit, Restore, Add line.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.text("But I haven't got a cough.")));
      await tester.pumpAndSettle();
      await _snap(tester, 'workspace_hover_$mode');
      await gesture.moveTo(const Offset(5, 5));
      await gesture.removePointer();

      // Rehearsal: role, cue mode waiting at my line.
      player.setRole('CECILY');
      player.setMute(true);
      player.switchToScene(player.scenes.indexWhere((x) => x.sceneNumber == 9));
      await tester.pumpAndSettle();
      player.currentCueIndex = 2;
      player.currentTime = player.cues[2].startTime + 1;
      player.refreshForTest();
      await tester.pumpAndSettle();
      await _snap(tester, 'workspace_playing_$mode');
      player.setCueMode(true);
      player.waitingAtCue = 3;
      player.currentCueIndex = 3;
      player.currentTime = player.cues[3].startTime;
      player.setBlock(true);
      await tester.pumpAndSettle();
      await _snap(tester, 'workspace_cue_mode_$mode');
      player.waitingAtCue = null;
      player.setBlock(false);

      // Playback-bar popovers.
      await tester.tap(find.text('Cecily').last);
      await tester.pumpAndSettle();
      await _snap(tester, 'popover_role_$mode');
      Navigator.of(tester.element(find.byType(ScriptArea))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Loop'));
      await tester.pumpAndSettle();
      await _snap(tester, 'popover_loop_$mode');
      Navigator.of(tester.element(find.byType(ScriptArea))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.00×'));
      await tester.pumpAndSettle();
      await _snap(tester, 'popover_speed_$mode');
      Navigator.of(tester.element(find.byType(ScriptArea))).pop();
      await tester.pumpAndSettle();

      // Search.
      final searchState = Provider.of<SearchState>(tester.element(find.byType(ScriptArea)), listen: false);
      await tester.enterText(find.byType(TextField).first, 'cough');
      await tester.pumpAndSettle();
      expect(searchState.query, 'cough');
      await _snap(tester, 'workspace_search_$mode');
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();

      // Rendering: progress on the scene bars and in the header.
      Provider.of<SceneView>(tester.element(find.byType(ScriptArea)), listen: false).toggle(9);
      app.isGenerating = true;
      app.renderingSceneNumbers = [9, 10, 11];
      app.generationProgress = 0.46;
      app.sceneProgress = {9: 1.0, 10: 0.4, 11: 0};
      for (final l in ['generate · 3 scenes', 'wrote 09 Morning-room at the Manor House.m4a', 'generate · Scene 10 Lady Bracknell arrives · element 45/112']) {
        app.appendLog(l, LogStyle.info);
      }
      app.refresh();
      await tester.pump(const Duration(milliseconds: 200));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/workspace_rendering_$mode.png'));
      showRenderSheet(tester.element(find.byType(ScriptArea)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/sheet_render_progress_$mode.png'));
      Navigator.of(tester.element(find.byType(ScriptArea))).pop();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      app.isGenerating = false;
      app.refresh();
      await tester.pumpAndSettle();

      // Multi-select bar + undo pill.
      final sel = Provider.of<LineSelection>(tester.element(find.byType(ScriptArea)), listen: false);
      final s9 = app.scenes[8];
      sel.toggle(9, s9.elements[9].ref);
      sel.toggle(9, s9.elements[10].ref);
      app.setSceneTitle(s9, 'Morning-room at the Manor House');
      await tester.pumpAndSettle();
      await _snap(tester, 'workspace_selection_$mode');
    });

    testWidgets('parse progress $mode', (tester) async {
      final (app, store, player) = await _makeState();
      store.currentProject = store.projects.first;
      app.isParsing = true;
      app.parseFraction = 0.62;
      app.parseMessage = 'Reading page 81 of 131';
      await _pump(tester, const DashboardScreen(), b, app: app, store: store, player: player);
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/workspace_parsing_$mode.png'));
    });

    testWidgets('sheets $mode', (tester) async {
      final (app, store, player) = await _makeState();
      final p = store.projects.firstWhere((x) => x.name.startsWith('The Importance'));
      store.currentProject = p;
      loadEarnest(app, earnestFolder);
      await _pump(tester, const DashboardScreen(), b, app: app, store: store, player: player);
      final ctx = tester.element(find.byType(ScriptArea));

      Future<void> sheet(String name, Future<void> Function() open) async {
        open();
        await tester.pumpAndSettle();
        await _snap(tester, '${name}_$mode');
        Navigator.of(tester.element(find.byType(ScriptArea)), rootNavigator: true).pop();
        await tester.pumpAndSettle();
      }

      await sheet('sheet_new_project', () => showSheet(ctx, (_) => const NewProjectSheet(), width: 460));
      await sheet('sheet_cast', () => showCastSheet(ctx));
      await sheet('sheet_render', () => showRenderSheet(ctx));
      app.dlog('parse finished · 12 scenes, 9 characters, 642 lines (1612 ms)', LogStyle.success);
      app.dlog('[py] voices: kokoro model loaded', LogStyle.debug);
      app.dlog('line 311 low confidence (0.58): speaker name split across a page break', LogStyle.warning);
      await sheet('sheet_log', () => showLogSheet(ctx));
      await sheet('sheet_settings_general', () => showSettingsSheet(ctx));
      await sheet('sheet_settings_engines', () => showSettingsSheet(ctx, initialTab: 1));
      await sheet('sheet_settings_projects', () => showSettingsSheet(ctx, initialTab: 2));
      await sheet('sheet_settings_about', () => showSettingsSheet(ctx, initialTab: 3));
      await sheet('sheet_onboarding', () => showOnboarding(ctx));
      await sheet('sheet_bug_report', () => showBugReportSheet(ctx));
      app.simulateUpdate();
      await sheet('sheet_update', () => showUpdateSheet(ctx));
      await sheet(
        'sheet_confirm',
        () => showConfirm(
          ctx,
          title: 'Move 2 projects to the Trash?',
          message: 'The project folder and any rendered audio go to the Trash. You can put them back from there, or from Recently Deleted.',
          buttons: const [('Cancel', BtnKind.secondary), ('Move to Trash', BtnKind.danger)],
        ),
      );

      await tester.tap(find.text('Morning-room at the Manor House'));
      await tester.pumpAndSettle();
      final lineCtx = tester.element(find.text('A most distasteful one.'));
      final s9 = app.scenes[8];
      await sheet('popover_correct_line', () => showPopover(lineCtx, (_) => CorrectLinePopover(sceneNumber: 9, element: s9.elements[5]), width: 340));
      await sheet('popover_correct_simultaneous', () => showPopover(lineCtx, (_) => CorrectLinePopover(sceneNumber: 9, element: s9.elements[7]), width: 340));
      await sheet(
        'popover_edit_added',
        () => showPopover(lineCtx, (_) => EditAddedLinePopover(sceneNumber: 9, element: app.userAddedElements[app.addedKey(9)]!.first), width: 340),
      );
      await sheet('popover_change_speaker', () => showPopover(lineCtx, (_) => ChangeSpeakerPopover(lineCount: 2, onApply: (_) {}), width: 280));
    });
  }
}
