// Sheets inside the main window: New Project, Onboarding, Report a Bug,
// Update Available, Settings. Contract: sheets[], settingsSheet.

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/platform.dart';
import '../services/project_store.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

const _repo = 'averywhitted/script-to-audio-app';
const destinationDescription = 'a public issue on github.com/$_repo';

String issueUrl(String title, String body, List<String> labels) {
  var text = body;
  if (text.length > 6000) text = '${text.substring(0, 6000)}\n\n…truncated. Use Export… in Settings to save the full data to a file.';
  return Uri.https('github.com', '/$_repo/issues/new', {'title': title, 'body': text, if (labels.isNotEmpty) 'labels': labels.join(',')}).toString();
}

Widget _footer(Tokens t, List<Widget> children) => Container(
  padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
  decoration: BoxDecoration(
    border: Border(top: BorderSide(color: t.rule)),
  ),
  child: Row(children: children),
);

Widget _fieldLabel(Tokens t, String s, {String? hint}) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(s, style: TextStyles.ui(t, weight: FontWeight.w600)),
      if (hint != null) ...[const SizedBox(height: 2), Text(hint, style: TextStyles.ui(t, size: 11.5, color: t.muted))],
    ],
  ),
);

// ---------------------------------------------------------------------------
// New Project
// ---------------------------------------------------------------------------

class NewProjectSheet extends StatefulWidget {
  const NewProjectSheet({super.key});
  @override
  State<NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends State<NewProjectSheet> {
  final name = TextEditingController();
  String? custom;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final ok = name.text.trim().isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader(icon: Icons.create_new_folder_outlined, title: 'New Project', subtitle: 'Give your project a name, then choose a screenplay PDF.'),
        Container(height: 1, color: t.rule),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 20, 26, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _fieldLabel(t, 'Project Name'),
              Field(
                controller: name,
                placeholder: 'e.g. Hamlet, The Godfather…',
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (name.text.trim().isNotEmpty) Navigator.of(context).pop((name.text.trim(), custom));
                },
              ),
              const SizedBox(height: 16),
              _fieldLabel(t, 'Save Location'),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                decoration: BoxDecoration(
                  color: t.field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 16, color: t.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            custom == null ? '~/Documents/Table Read/' : custom!.split('/').last,
                            style: TextStyles.ui(t, color: custom == null ? t.ink2 : t.ink),
                          ),
                          Text(
                            custom == null ? 'Default location' : 'A new project folder will be created inside this location',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyles.ui(t, size: 11, color: t.muted),
                          ),
                        ],
                      ),
                    ),
                    Btn(
                      'Choose…',
                      kind: BtnKind.link,
                      small: true,
                      onPressed: () async {
                        final dir = await getDirectoryPath();
                        if (dir != null) setState(() => custom = dir);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _footer(t, [
          Btn('Cancel', kind: BtnKind.plain, onPressed: () => Navigator.of(context).pop()),
          const Spacer(),
          Btn('Create & Choose PDF…', kind: BtnKind.primary, onPressed: ok ? () => Navigator.of(context).pop((name.text.trim(), custom)) : null),
        ]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Onboarding
// ---------------------------------------------------------------------------

Future<void> showOnboarding(BuildContext context) => showSheet(context, (ctx) => const _Onboarding(), width: 560, dismissible: false);

class _Onboarding extends StatelessWidget {
  const _Onboarding();
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget step(int n, IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: t.accentSoft, shape: BoxShape.circle),
            child: Icon(icon, size: 17, color: t.accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$n.  ',
                        style: TextStyles.ui(t, weight: FontWeight.w700, color: t.accent),
                      ),
                      TextSpan(
                        text: title,
                        style: TextStyles.ui(t, weight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                Text(body, style: TextStyles.ui(t, color: t.ink2, height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
    Widget tip(String s) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_rounded, size: 15, color: t.ok),
          const SizedBox(width: 8),
          Expanded(
            child: Text(s, style: TextStyles.ui(t, size: 12.5, color: t.ink2, height: 1.4)),
          ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 34, 40, 24),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                decoration: BoxDecoration(color: t.highlighter, borderRadius: BorderRadius.circular(4)),
                child: Text(
                  'TR',
                  style: TextStyle(fontFamily: Fonts.hand, fontWeight: FontWeight.w600, fontSize: 40, color: const Color(0xFF1C1B19)),
                ),
              ),
              const SizedBox(height: 14),
              Text('Welcome to Table Read', style: TextStyles.display(t, size: 28)),
              const SizedBox(height: 8),
              Text(
                'Turn any screenplay PDF into a full cast audio drama —\neach character voiced differently, scene by scene.',
                textAlign: TextAlign.center,
                style: TextStyles.ui(t, size: 14, color: t.ink2, height: 1.45),
              ),
            ],
          ),
        ),
        Container(height: 1, color: t.rule),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(40, 24, 40, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                step(1, Icons.note_add_outlined, 'Import a Script PDF', 'Create a project and choose a screenplay or stage-play PDF.'),
                step(2, Icons.manage_search_rounded, 'Review the Parse', 'Check who says each line and fix anything marked with a “?”.'),
                step(3, Icons.record_voice_over_outlined, 'Cast Your Voices', 'Pick an engine and give each character a voice in the Cast tab.'),
                step(4, Icons.play_circle_outline_rounded, 'Generate Audio', 'Select scenes and render them in the Render tab, one file per scene.'),
                const SizedBox(height: 4),
                Text(
                  'Tips',
                  style: TextStyles.ui(t, weight: FontWeight.w700, color: t.muted),
                ),
                const SizedBox(height: 8),
                tip('Removed lines stay in the script, struck through, so you can restore them.'),
                tip('Every edit can be undone with ⌘Z.'),
                tip('In the Rehearse tab, pick your role to mute or block your own lines.'),
              ],
            ),
          ),
        ),
        _footer(t, [const Spacer(), Btn('Get Started', kind: BtnKind.primary, onPressed: () => Navigator.of(context).pop())]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Report a Bug
// ---------------------------------------------------------------------------

Future<void> showBugReportSheet(BuildContext context) => showSheet(context, (ctx) => const _BugReport(), width: 480);

class _BugReport extends StatefulWidget {
  const _BugReport();
  @override
  State<_BugReport> createState() => _BugReportState();
}

class _BugReportState extends State<_BugReport> {
  final what = TextEditingController();
  final steps = TextEditingController();
  Map<String, String> info = const {'version': AppState.appVersion, 'build': '', 'os': ''};
  bool sent = false;

  @override
  void initState() {
    super.initState();
    NativePlatform.appVersion().then((v) {
      if (mounted) setState(() => info = {...v, 'version': AppState.appVersion});
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final version = 'v${info['version']} (build ${info['build']})';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          icon: Icons.bug_report_outlined,
          iconColor: t.danger,
          title: 'Report a Bug',
          subtitle: 'Reports go directly to the developer. No account required.',
        ),
        Container(height: 1, color: t.rule),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: t.ctrl, borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SYSTEM INFO', style: TextStyles.label(t)),
                      const SizedBox(height: 6),
                      Text('App version   $version', style: TextStyles.ui(t, size: 12)),
                      Text('macOS             ${info['os']}', style: TextStyles.ui(t, size: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _fieldLabel(t, 'What happened?'),
                Field(controller: what, maxLines: 5, minLines: 4, onChanged: (_) => setState(() {})),
                const SizedBox(height: 14),
                _fieldLabel(t, 'Steps to reproduce', hint: 'Optional — helps a lot if you can describe what you did before it happened.'),
                Field(controller: steps, maxLines: 4, minLines: 3),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.rule)),
          ),
          child: Text(
            'This opens a prefilled report as $destinationDescription. Nothing is sent until you review it there and submit it.',
            style: TextStyles.ui(t, size: 11.5, color: t.muted, height: 1.4),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
          child: Row(
            children: [
              if (sent) ...[
                Icon(Icons.check_circle_rounded, size: 15, color: t.ok),
                const SizedBox(width: 6),
                Text('Opened in your browser.', style: TextStyles.ui(t, color: t.ok)),
              ],
              const Spacer(),
              Btn('Cancel', kind: BtnKind.plain, onPressed: () => Navigator.of(context).pop()),
              const SizedBox(width: 8),
              Btn(
                'Review on GitHub…',
                kind: BtnKind.primary,
                onPressed: what.text.trim().isEmpty || sent
                    ? null
                    : () async {
                        final body =
                            'App version: $version\nmacOS: ${info['os']}\n\nWhat happened:\n${what.text}\n\nSteps to reproduce:\n${steps.text.isEmpty ? '(not provided)' : steps.text}';
                        await NativePlatform.openURL(issueUrl('Bug report $version', body, ['bug', 'user-report']));
                        if (!mounted) return;
                        setState(() => sent = true);
                        Future.delayed(const Duration(milliseconds: 1500), () {
                          if (mounted) Navigator.of(context).pop();
                        });
                      },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Update Available
// ---------------------------------------------------------------------------

Future<void> showUpdateSheet(BuildContext context) => showSheet(context, (ctx) => const _UpdateSheet(), width: 440);

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet();
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final u = app.availableUpdate;
    final busy = app.updateStage == UpdateStage.downloading || app.updateStage == UpdateStage.extracting || app.updateStage == UpdateStage.installing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          icon: Icons.arrow_circle_down_rounded,
          iconColor: t.accent,
          title: 'Update Available',
          subtitle: u == null ? null : 'Table Read ${u.version} is ready to install.\nYou have version ${AppState.appVersion}.',
        ),
        if (u != null && u.releaseNotes.isNotEmpty) ...[
          Container(height: 1, color: t.rule),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Text(u.releaseNotes, style: TextStyles.ui(t, height: 1.5)),
            ),
          ),
        ],
        if (app.updateStage != UpdateStage.idle) ...[
          Container(height: 1, color: t.rule),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            child: switch (app.updateStage) {
              UpdateStage.downloading => Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: app.updateFraction > 0 ? app.updateFraction : null,
                      minHeight: 5,
                      color: t.accent,
                      backgroundColor: t.ctrl,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    app.updateFraction > 0 ? 'Downloading… ${(app.updateFraction * 100).round()}%' : 'Connecting…',
                    style: TextStyles.ui(t, size: 12, color: t.muted),
                  ),
                ],
              ),
              UpdateStage.extracting => Text('Extracting…', style: TextStyles.ui(t, size: 12, color: t.muted)),
              UpdateStage.installing => Text('Installing — Table Read will relaunch shortly…', style: TextStyles.ui(t, size: 12, color: t.muted)),
              UpdateStage.failed => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.cancel_rounded, size: 15, color: t.danger),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(app.updateError ?? 'The update failed.', style: TextStyles.ui(t, size: 12, color: t.danger)),
                  ),
                ],
              ),
              UpdateStage.idle => const SizedBox.shrink(),
            },
          ),
        ],
        _footer(t, [
          if (u != null) Btn('Release Notes', kind: BtnKind.plain, onPressed: () => NativePlatform.openURL(u.htmlUrl)),
          const Spacer(),
          Btn('Later', kind: BtnKind.plain, onPressed: busy ? null : () => Navigator.of(context).pop()),
          const SizedBox(width: 8),
          Btn(
            busy ? 'Installing…' : (u?.hasZipAsset == false ? 'Download on GitHub' : (app.updateStage == UpdateStage.failed ? 'Retry' : 'Update Now')),
            kind: BtnKind.primary,
            onPressed: busy || u == null
                ? null
                : () {
                    if (u.hasZipAsset == false) {
                      NativePlatform.openURL(u.htmlUrl);
                    } else {
                      app.downloadAndInstallUpdate();
                    }
                  },
          ),
        ]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Settings (a sheet with four tabs)
// ---------------------------------------------------------------------------

Future<void> showSettingsSheet(BuildContext context, {int initialTab = 0}) => showSheet(context, (ctx) => _SettingsSheet(initialTab: initialTab), width: 560);

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initialTab});
  final int initialTab;
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late int tab = widget.initialTab;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    const tabs = [
      ('General', Icons.tune_rounded),
      ('Engines', Icons.graphic_eq_rounded),
      ('Projects', Icons.folder_outlined),
      ('About', Icons.info_outline_rounded),
    ];
    return SizedBox(
      height: 580,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 0),
            child: Row(
              children: [
                Text('Settings', style: TextStyles.display(t, size: 20)),
                const Spacer(),
                IconBtn(Icons.close_rounded, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < tabs.length; i++)
                  GestureDetector(
                    onTap: () => setState(() => tab = i),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        width: 86,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(color: tab == i ? t.accentSoft : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                        child: Column(
                          children: [
                            Icon(tabs[i].$2, size: 20, color: tab == i ? t.accent : t.muted),
                            const SizedBox(height: 3),
                            Text(
                              tabs[i].$1,
                              style: TextStyles.ui(t, size: 12, weight: FontWeight.w600, color: tab == i ? t.accent : t.muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(height: 1, color: t.rule),
          Expanded(
            child: switch (tab) {
              0 => const _GeneralTab(),
              1 => const _EnginesTab(),
              2 => const _ProjectsTab(),
              _ => const _AboutTab(),
            },
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.header, required this.children, this.footer});
  final String header;
  final List<Widget> children;
  final String? footer;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(header.toUpperCase(), style: TextStyles.label(t)),
          ),
          Panel(
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), child: children[i]),
                  if (i < children.length - 1) const Hairline(),
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text(footer!, style: TextStyles.ui(t, size: 11.5, color: t.muted, height: 1.45)),
            ),
        ],
      ),
    );
  }
}

Widget _toggleLine(Tokens t, String label, bool v, ValueChanged<bool> on) => Row(
  children: [
    Expanded(child: Text(label, style: TextStyles.ui(t))),
    Toggle(value: v, onChanged: on),
  ],
);

class _GeneralTab extends StatefulWidget {
  const _GeneralTab();
  @override
  State<_GeneralTab> createState() => _GeneralTabState();
}

class _GeneralTabState extends State<_GeneralTab> {
  bool checking = false;
  bool contributed = false;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final u = app.availableUpdate;
    final count = app.corrections.length;
    final unsent = app.corrections.values.where((c) => !c.uploaded).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      children: [
        _Section(
          header: 'Script Display',
          footer: 'Each character gets their own highlighter color on their name in the script, the scene list and the Cast tab. Turn it off for plain gray name tags.',
          children: [
            _toggleLine(t, 'Character highlight colors', app.characterColors, app.setCharacterColors),
            Row(
              children: [
                Expanded(
                  child: _HighlightPreview(colors: true, selected: app.characterColors, onTap: () => app.setCharacterColors(true)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _HighlightPreview(colors: false, selected: !app.characterColors, onTap: () => app.setCharacterColors(false)),
                ),
              ],
            ),
          ],
        ),
        _Section(
          header: 'Software Update',
          children: [
            if (u != null)
              Row(
                children: [
                  Icon(Icons.arrow_circle_down_rounded, color: t.accent, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Table Read ${u.version} is available', style: TextStyles.ui(t, weight: FontWeight.w600)),
                        Text('You have version ${AppState.appVersion}', style: TextStyles.ui(t, size: 11.5, color: t.muted)),
                      ],
                    ),
                  ),
                  Btn(
                    'Update Now',
                    kind: BtnKind.primary,
                    small: true,
                    onPressed: () => showUpdateSheet(context), // on top of Settings; Later returns here
                  ),
                ],
              )
            else
              Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: t.ok, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Table Read is up to date', style: TextStyles.ui(t, color: t.ink2)),
                  ),
                  if (checking)
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8))
                  else
                    Btn(
                      'Check for Updates',
                      kind: BtnKind.link,
                      small: true,
                      onPressed: () async {
                        setState(() => checking = true);
                        await app.checkForUpdates();
                        if (mounted) setState(() => checking = false);
                      },
                    ),
                ],
              ),
          ],
        ),
        _Section(
          header: 'Update Channel',
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Segmented(
                    labels: const ['Stable', 'Beta'],
                    selected: app.updateChannel == 'stable' ? 0 : 1,
                    onChanged: (i) => app.setUpdateChannel(i == 0 ? 'stable' : 'beta'),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  app.updateChannel == 'stable'
                      ? 'Tested, production-ready releases only.'
                      : 'Includes pre-releases with new features that may have rough edges.',
                  style: TextStyles.ui(t, size: 11.5, color: t.muted),
                ),
              ],
            ),
          ],
        ),
        _Section(
          header: 'Render',
          children: [
            Tooltip(
              message: 'When a render completes without errors, the output folder opens automatically in Finder.',
              child: _toggleLine(
                t,
                'Auto-open output folder in Finder after render',
                app.autoOpenFinderAfterRender,
                (v) => app.setSetting('autoOpenFinderAfterRender', v),
              ),
            ),
          ],
        ),
        _Section(
          header: 'Notifications',
          footer:
              'macOS will ask for permission the first time a notification option is enabled. Notifications appear even when Table Read is in the background.',
          children: [
            _toggleLine(t, 'Notify when a scene finishes rendering', app.notifyOnSceneComplete, (v) => app.setSetting('notifyOnSceneComplete', v)),
            _toggleLine(t, 'Notify when the full render completes', app.notifyOnRenderComplete, (v) => app.setSetting('notifyOnRenderComplete', v)),
            _toggleLine(t, 'Notify if the render finishes with errors', app.notifyOnRenderFailed, (v) => app.setSetting('notifyOnRenderFailed', v)),
          ],
        ),
        _Section(
          header: 'Default Output Folder',
          footer: 'Audio files are saved here unless you change it during a session.',
          children: [
            Row(
              children: [
                Icon(Icons.folder_rounded, size: 16, color: t.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    app.settings.getString('lastOutputDirectory')?.replaceFirst(Platform.environment['HOME'] ?? '~', '~') ?? 'Next to the PDF (default)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.ui(t, color: app.settings.getString('lastOutputDirectory') == null ? t.muted : t.ink),
                  ),
                ),
                Btn(
                  'Change…',
                  small: true,
                  onPressed: () async {
                    final d = await getDirectoryPath();
                    if (d != null) {
                      await app.settings.setString('lastOutputDirectory', d);
                      app.outputDirectory = d;
                      setState(() {});
                    }
                  },
                ),
                if (app.settings.getString('lastOutputDirectory') != null) ...[
                  const SizedBox(width: 6),
                  Btn(
                    'Reset to Default',
                    kind: BtnKind.danger,
                    small: true,
                    onPressed: () async {
                      await app.settings.setString('lastOutputDirectory', null);
                      setState(() {});
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
        _Section(
          header: 'Parser Corrections',
          footer:
              'Corrections you make in the script are stored locally and are never sent on their own.\n\n'
              'Contribute… opens a prefilled report as $destinationDescription, which you then review and submit yourself. '
              'It includes the lines of dialogue the correction applies to, so it will be publicly visible. Your file paths and name are not included. '
              'If your script is confidential, use Export… to save the corrections to a file and send them privately instead.',
          children: [
            _toggleLine(t, 'Offer to contribute corrections', app.contributeCorrections, (v) => app.setSetting('contributeCorrections', v)),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$count correction${count == 1 ? '' : 's'} stored locally', style: TextStyles.ui(t, color: t.ink2)),
                      if (app.contributeCorrections && unsent > 0) Text('$unsent not yet contributed', style: TextStyles.ui(t, size: 11.5, color: t.muted)),
                    ],
                  ),
                ),
                if (app.contributeCorrections) ...[
                  if (contributed) ...[Icon(Icons.check_circle_rounded, size: 14, color: t.ok), const SizedBox(width: 4)],
                  Btn('Contribute…', small: true, onPressed: count == 0 ? null : () => _contribute(app)),
                  const SizedBox(width: 6),
                ],
                Btn('Export…', small: true, onPressed: count == 0 ? null : () => _export(app)),
                const SizedBox(width: 6),
                Btn(
                  'Clear All',
                  kind: BtnKind.danger,
                  small: true,
                  onPressed: count == 0
                      ? null
                      : () {
                          app.corrections.clear();
                          app.persistProject();
                          app.refresh();
                        },
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _contribute(AppState app) async {
    final lines = app.corrections.values
        .map((c) {
          final parts = <String>[
            'Scene ${c.sceneNumber} · ${c.originalKind}${c.originalSpeaker != null ? ' (${c.originalSpeaker})' : ''}',
            'Original:  ${textPrefix60(c.textKey)}',
            if (c.correctedText != null) 'Text fix:  ${c.correctedText}',
            if (c.correctedKind != null) 'Kind fix:  ${c.correctedKind}',
            if (c.correctedSpeaker != null) 'Speaker:   ${c.correctedSpeaker!.isEmpty ? '(narrator)' : c.correctedSpeaker}',
            if (c.markedAsNoise) 'Removed:   yes',
          ];
          return parts.join('\n');
        })
        .join('\n\n---\n\n');
    final n = app.corrections.length;
    await NativePlatform.openURL(
      issueUrl('Parser corrections v${AppState.appVersion} ($n correction${n == 1 ? '' : 's'})', lines, ['correction', 'user-report']),
    );
    for (final c in app.corrections.values) {
      c.uploaded = true;
    }
    app.persistProject();
    setState(() => contributed = true);
  }

  Future<void> _export(AppState app) async {
    final loc = await getSaveLocation(suggestedName: 'table_read_corrections_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
    if (loc == null) return;
    File(loc.path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(app.corrections.values.map((c) => c.toJson()).toList()));
  }
}

class _EnginesTab extends StatefulWidget {
  const _EnginesTab();
  @override
  State<_EnginesTab> createState() => _EnginesTabState();
}

class _EnginesTabState extends State<_EnginesTab> {
  final key = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      children: [
        _Section(
          header: 'OpenAI TTS',
          footer: "Your key is stored in Keychain and never sent anywhere except OpenAI's API. Type a new key and click Save to update, or Clear to remove it.",
          children: [
            Row(
              children: [
                Expanded(
                  child: Field(controller: key, obscure: true, placeholder: app.hasStoredOpenAIKey ? 'Enter new key to replace…' : 'Paste your key here…'),
                ),
                const SizedBox(width: 8),
                Btn(
                  'Save',
                  kind: BtnKind.primary,
                  small: true,
                  onPressed: () async {
                    await app.saveOpenAIKey(key.text);
                    key.clear();
                  },
                ),
                if (app.hasStoredOpenAIKey) ...[const SizedBox(width: 6), Btn('Clear', small: true, onPressed: () => app.saveOpenAIKey(''))],
              ],
            ),
            if (app.hasStoredOpenAIKey)
              Row(
                children: [
                  ...switch (app.openAIKeyStatus) {
                    'checking' => [
                      const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.6)),
                      const SizedBox(width: 6),
                      Text('Checking key…', style: TextStyles.ui(t, size: 12)),
                    ],
                    'valid' => [
                      Icon(Icons.check_circle_rounded, size: 15, color: t.ok),
                      const SizedBox(width: 6),
                      Text('API key verified — OpenAI TTS is active', style: TextStyles.ui(t, size: 12, color: t.ok)),
                    ],
                    'invalid' => [
                      Icon(Icons.cancel_rounded, size: 15, color: t.danger),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(app.openAIKeyError ?? 'Key check failed', style: TextStyles.ui(t, size: 12, color: t.danger)),
                      ),
                    ],
                    _ => [
                      Icon(Icons.key_rounded, size: 15, color: t.muted),
                      const SizedBox(width: 6),
                      Text('API key saved in Keychain', style: TextStyles.ui(t, size: 12, color: t.ink2)),
                    ],
                  },
                  const Spacer(),
                  Btn('Test Key', small: true, onPressed: app.openAIKeyStatus == 'checking' ? null : app.testOpenAIKey),
                ],
              ),
          ],
        ),
        _Section(
          header: 'Local Engines',
          footer: 'macOS Voices is always available with no setup required.',
          children: [
            for (final e in [EngineKind.kokoro, EngineKind.piper]) _EngineRow(engine: e),
          ],
        ),
      ],
    );
  }
}

class _EngineRow extends StatelessWidget {
  const _EngineRow({required this.engine});
  final EngineKind engine;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final installed = app.installedEngines.contains(engine);
    final status = app.engineStatuses[engine];
    Widget trailing;
    if (app.installingEngine == engine) {
      final f = app.installProgress;
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 90,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: f, minHeight: 4, color: t.accent, backgroundColor: t.ctrl),
            ),
          ),
          const SizedBox(width: 6),
          Text(f == null ? 'Installing…' : (f >= 1 ? 'Finishing…' : '${(f * 100).round()}%'), style: TextStyles.ui(t, size: 11.5, color: t.muted)),
          IconBtn(Icons.cancel_rounded, size: 15, tooltip: 'Cancel installation', onTap: app.cancelInstall),
        ],
      );
    } else if (app.uninstallingEngine == engine) {
      trailing = Text('Removing…', style: TextStyles.ui(t, size: 11.5, color: t.muted));
    } else if (!engine.isSupported) {
      trailing = Text('Coming soon', style: TextStyles.ui(t, size: 11.5, color: t.faint));
    } else if (installed) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status != null) Text(status.sizeLabel, style: TextStyles.ui(t, size: 11.5, color: t.muted)),
          const SizedBox(width: 8),
          Btn('Uninstall', small: true, onPressed: () => app.uninstallEngine(engine)),
        ],
      );
    } else {
      trailing = Btn('Install', kind: BtnKind.primary, small: true, onPressed: () => app.installEngine(engine));
    }
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(engine.title, style: TextStyles.ui(t, weight: FontWeight.w600)),
              Text(engine.subtitle, style: TextStyles.ui(t, size: 11.5, color: t.muted)),
            ],
          ),
        ),
        trailing,
      ],
    );
  }
}

class _ProjectsTab extends StatelessWidget {
  const _ProjectsTab();
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final store = context.watch<ProjectStore>();
    final dir = Directory(store.baseDir);
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      children: [
        _Section(
          header: 'Default Projects Folder',
          footer: 'New projects are created inside this folder by default.',
          children: [
            Row(
              children: [
                Icon(Icons.folder_rounded, size: 18, color: t.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(dir.path.split('/').last, style: TextStyles.ui(t, weight: FontWeight.w600)),
                      Text(
                        dir.parent.path.replaceFirst(Platform.environment['HOME'] ?? '~', '~'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyles.ui(t, size: 11.5, color: t.muted),
                      ),
                    ],
                  ),
                ),
                Btn(
                  'Change…',
                  small: true,
                  onPressed: () async {
                    final d = await getDirectoryPath();
                    if (d != null) store.changeBaseDir(d);
                  },
                ),
                const SizedBox(width: 6),
                Btn('Reveal', small: true, onPressed: () => NativePlatform.revealInFinder(store.baseDir)),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _AboutTab extends StatefulWidget {
  const _AboutTab();
  @override
  State<_AboutTab> createState() => _AboutTabState();
}

class _AboutTabState extends State<_AboutTab> {
  bool checking = false;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final u = app.availableUpdate;
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 22, 32, 22),
      children: [
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/app_icon.png',
              width: 72,
              height: 72,
              errorBuilder: (_, _, _) => Icon(Icons.theater_comedy_outlined, size: 56, color: t.accent),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Center(child: Text('Table Read', style: TextStyles.display(t, size: 22))),
        Center(
          child: Text('Version ${AppState.appVersion}', style: TextStyles.ui(t, color: t.muted)),
        ),
        const SizedBox(height: 10),
        Center(
          child: u != null
              ? Btn(
                  'Version ${u.version} available',
                  kind: BtnKind.warn,
                  small: true,
                  icon: Icons.arrow_circle_down_rounded,
                  onPressed: () => showUpdateSheet(context), // on top of Settings; Later returns here
                )
              : (checking
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8))
                    : Btn(
                        'Check for Updates',
                        small: true,
                        onPressed: () async {
                          setState(() => checking = true);
                          await app.checkForUpdates();
                          if (mounted) setState(() => checking = false);
                        },
                      )),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text('© 2025 Avery Whitted. All rights reserved.', style: TextStyles.ui(t, size: 12, color: t.muted)),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: t.ctrl, borderRadius: BorderRadius.circular(8)),
          child: Text(
            'Table Read is free for personal, non-commercial use. See the license for details.\n\n'
            'Fonts: Hanken Grotesk, Courier Prime, Caveat and Young Serif, used under the SIL Open Font License.',
            style: TextStyles.ui(t, size: 11.5, color: t.ink2, height: 1.45),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Btn('View License on GitHub', small: true, onPressed: () => NativePlatform.openURL('https://github.com/averywhitted/table-read/blob/main/LICENSE')),
            const SizedBox(width: 8),
            Btn('Donate on Buy Me a Coffee', small: true, onPressed: () => NativePlatform.openURL('https://buymeacoffee.com/averywhitted')),
          ],
        ),
      ],
    );
  }
}

/// A small sample of the script, drawn with highlight colors on or off.
class _HighlightPreview extends StatelessWidget {
  const _HighlightPreview({required this.colors, required this.selected, required this.onTap});
  final bool colors;
  final bool selected;
  final VoidCallback onTap;

  static const _cast = ['CECILY', 'GWENDOLEN', 'JACK'];

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget line(String name, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        children: [
          NameChip(name, allSpeakers: _cast, uppercase: true, size: 9.5, colors: colors),
          const SizedBox(height: 2),
          Text(text, textAlign: TextAlign.center, style: TextStyles.script(t, size: 10.5).copyWith(height: 1.35)),
        ],
      ),
    );
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
              decoration: BoxDecoration(
                color: t.bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: selected ? t.accent : t.border, width: selected ? 2 : 1),
              ),
              child: Column(
                children: [
                  Wrap(
                    spacing: 4,
                    alignment: WrapAlignment.center,
                    children: [for (final c in _cast) NameChip(c, allSpeakers: _cast, size: 9, colors: colors)],
                  ),
                  const SizedBox(height: 8),
                  line('CECILY', 'They have been eating muffins.'),
                  line('GWENDOLEN', "Couldn't you cough?"),
                ],
              ),
            ),
            const SizedBox(height: 5),
            Text(
              colors ? 'On' : 'Off',
              style: TextStyles.ui(t, size: 12, weight: FontWeight.w600, color: selected ? t.accent : t.muted),
            ),
          ],
        ),
      ),
    );
  }
}
