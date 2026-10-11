import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'services/project_store.dart';
import 'services/settings.dart';
import 'state/app_state.dart';
import 'state/player_state.dart';
import 'theme/tokens.dart';
import 'ui/cast_dialog.dart';
import 'ui/dashboard.dart';
import 'ui/gallery.dart';
import 'ui/log_dialog.dart';
import 'ui/render_dialog.dart';
import 'ui/sheets.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final store = ProjectStore(settings);
  final app = AppState(settings, store);
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider(create: (_) => RehearsalPlayer()),
      ],
      child: const TableReadApp(),
    ),
  );
}

class TableReadApp extends StatelessWidget {
  const TableReadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Table Read',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}

/// One window. Shows Projects or the open project; everything else is a sheet.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String? _shownError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      if (!app.settings.getBool('hasSeenOnboarding')) {
        app.settings.setBool('hasSeenOnboarding', true);
        showOnboarding(context);
      }
    });
  }

  void _maybeShowError(AppState app) {
    final msg = app.errorMessage;
    if (msg == null || msg == _shownError) return;
    _shownError = msg;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showConfirm(context, title: 'Something went wrong', message: msg, buttons: const [('OK', BtnKind.primary)]);
      _shownError = null;
      app.clearError();
    });
  }

  void _maybePromptUpdate(AppState app) {
    if (app.availableUpdate != null && !app.didPromptForUpdate) {
      app.didPromptForUpdate = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showUpdateSheet(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ProjectStore>();
    final app = context.watch<AppState>();
    final player = context.read<RehearsalPlayer>();
    _maybeShowError(app);
    _maybePromptUpdate(app);
    final inProject = store.currentProject != null;
    final canRender = inProject && !app.isGenerating && app.selectedScenes.isNotEmpty;

    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'Table Read',
          menus: [
            PlatformMenuItemGroup(
              members: [PlatformMenuItem(label: 'About Table Read', onSelected: () => showSettingsSheet(context, initialTab: 3))],
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Settings…',
                  shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
                  onSelected: () => showSettingsSheet(context),
                ),
                PlatformMenuItem(
                  label: app.availableUpdate != null ? 'Update to ${app.availableUpdate!.version}…' : 'Check for Updates',
                  onSelected: () async {
                    if (app.availableUpdate == null) await app.checkForUpdates();
                    if (app.availableUpdate != null && context.mounted) showUpdateSheet(context);
                  },
                ),
              ],
            ),
            if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.hide))
              const PlatformMenuItemGroup(
                members: [
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
                ],
              ),
            if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit))
              const PlatformMenuItemGroup(members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit)]),
          ],
        ),
        PlatformMenu(
          label: 'Edit',
          menus: [
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Undo',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
                  onSelected: app.canUndo && !_textFieldFocused() ? app.undo : null,
                ),
                PlatformMenuItem(
                  label: 'Redo',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true),
                  onSelected: app.canRedo && !_textFieldFocused() ? app.redo : null,
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: 'Script',
          menus: [
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Cast Voices…',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
                  onSelected: inProject && app.script != null ? () => showCastSheet(context) : null,
                ),
                PlatformMenuItem(
                  label: 'Render Scenes…',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
                  onSelected: inProject && app.script != null ? () => showRenderSheet(context) : null,
                ),
                PlatformMenuItem(
                  label: 'Preview First Scene',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true),
                  onSelected: canRender ? app.renderPreviewScene : null,
                ),
              ],
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: app.isPaused ? 'Resume Render' : 'Pause Render',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true, shift: true),
                  onSelected: app.isGenerating ? app.togglePause : null,
                ),
                PlatformMenuItem(
                  label: 'Cancel Render',
                  shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
                  onSelected: app.isGenerating ? app.cancelGeneration : null,
                ),
              ],
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Skip Already-Rendered Scenes',
                  onSelected: inProject && !app.isGenerating && app.script != null
                      ? () {
                          showRenderSheet(context);
                          app.selectMissingScenes();
                        }
                      : null,
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: 'Help',
          menus: [
            PlatformMenuItem(
              label: 'Table Read Help',
              shortcut: const SingleActivator(LogicalKeyboardKey.slash, meta: true, shift: true),
              onSelected: () => showOnboarding(context),
            ),
            PlatformMenuItem(
              label: 'Report a Bug…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyB, meta: true, shift: true),
              onSelected: () => showBugReportSheet(context),
            ),
          ],
        ),
        PlatformMenu(
          label: 'Debug',
          menus: [
            PlatformMenuItem(label: 'Show Log', shortcut: const SingleActivator(LogicalKeyboardKey.keyL, meta: true, alt: true), onSelected: () => showLogSheet(context)),
            PlatformMenuItem(
              label: 'Simulate Update Available',
              onSelected: () {
                app.simulateUpdate();
                app.didPromptForUpdate = true;
                showUpdateSheet(context);
              },
            ),
            PlatformMenuItem(
              label: 'Clear Update State',
              onSelected: () {
                app.availableUpdate = null;
                app.updateStage = UpdateStage.idle;
                app.refresh();
              },
            ),
            PlatformMenuItem(label: 'Reset Onboarding', onSelected: () => app.settings.setBool('hasSeenOnboarding', false)),
            PlatformMenuItem(
              label: 'Show Error Alert',
              onSelected: () => app.showError('This is what an error looks like. The worker’s message would appear here.'),
            ),
          ],
        ),
      ],
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: inProject ? const DashboardScreen(key: ValueKey('dashboard')) : _GalleryWithPlayerReset(player: player, key: const ValueKey('gallery')),
      ),
    );
  }

  static bool _textFieldFocused() {
    final f = FocusManager.instance.primaryFocus;
    return f?.context?.widget is EditableText;
  }
}

class _GalleryWithPlayerReset extends StatelessWidget {
  const _GalleryWithPlayerReset({super.key, required this.player});
  final RehearsalPlayer player;
  @override
  Widget build(BuildContext context) => const GalleryScreen();
}
