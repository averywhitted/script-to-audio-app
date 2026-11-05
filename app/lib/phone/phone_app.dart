// Table Read on iPhone (#90): pick the projects folder once, then the
// project covers, as on the Mac; a cover opens the rehearsal screen (#91).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../theme/tokens.dart';
import '../ui/gallery.dart' show ScriptCover, friendlyDate;
import 'adaptive.dart';
import 'folder_access.dart' show RemovedDownload;
import 'notice.dart';
import 'phone_store.dart';
import 'rehearsal_screen.dart';

/// Projects waiting on their download to open (a second tap meanwhile does nothing).
final _opening = <String>{};

/// A project that is only its project.json (and a script) has nothing worth removing.
const _smallestWorthRemoving = 200 * 1024;

String _size(int bytes) => bytes >= 1024 * 1024 * 1024
    ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
    : bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(bytes >= 100 * 1024 * 1024 ? 0 : 1)} MB'
    : '${(bytes / 1024).round()} KB';

String _removedMessage(Project p, RemovedDownload r) {
  if (r.files == 0) {
    return r.kept == 0
        ? 'Nothing to remove for “${p.name}”.'
        : '“${p.name}” isn’t in iCloud Drive (or hasn’t finished uploading), so its files stay on this device.';
  }
  final left = r.kept == 0 ? '' : ' ${r.kept} file${r.kept == 1 ? '' : 's'} not uploaded yet stayed.';
  return 'Removed ${_size(r.freed)} of “${p.name}”. It stays in iCloud Drive.$left';
}

class PhoneApp extends StatelessWidget {
  const PhoneApp({super.key, required this.store, this.themeMode = ThemeMode.system});
  final PhoneStore store;

  /// Follows the phone; tests pin it.
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        title: 'Table Read',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: themeMode,
        home: const PhoneHome(),
      ),
    );
  }
}

class PhoneHome extends StatelessWidget {
  const PhoneHome({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final store = context.watch<PhoneStore>();
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(child: store.folder == null && !store.loading ? const _Welcome() : const _OnResume(child: _Projects())),
    );
  }
}

/// When the app comes back to the front: iOS may have taken downloads off the device meanwhile, and another device may have read on.
class _OnResume extends StatefulWidget {
  const _OnResume({required this.child});
  final Widget child;

  @override
  State<_OnResume> createState() => _OnResumeState();
}

class _OnResumeState extends State<_OnResume> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    final store = context.read<PhoneStore>();
    store.rescanDownloads();
    store.refreshProgress();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// First launch: where the projects come from, and one button.
class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final store = context.read<PhoneStore>();
    Widget step(String n, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: t.accentSoft, shape: BoxShape.circle),
            child: Text(
              n,
              style: TextStyles.ui(t, size: 14, weight: FontWeight.w700, color: t.accent),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyles.ui(t, size: 16, height: 1.4))),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
      children: [
        Center(
          child: ClipRRect(borderRadius: BorderRadius.circular(22), child: Image.asset('assets/app_icon.png', width: 96, height: 96)),
        ),
        const SizedBox(height: 20),
        Text('Table Read', textAlign: TextAlign.center, style: TextStyles.display(t, size: 30)),
        const SizedBox(height: 8),
        Text(
          'Rehearse the scripts you render on your Mac.',
          textAlign: TextAlign.center,
          style: TextStyles.ui(t, size: 16, color: t.muted),
        ),
        const SizedBox(height: 36),
        step('1', 'On your Mac, open Table Read → Settings → Projects → Move to iCloud Drive.'),
        step('2', 'Here, choose iCloud Drive › Table Read.'),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: store.pickFolder,
          icon: const Icon(Icons.folder_open_rounded),
          label: const Text('Choose Folder'),
          style: FilledButton.styleFrom(
            backgroundColor: t.accent,
            foregroundColor: t.onAccent,
            minimumSize: const Size.fromHeight(52),
            textStyle: TextStyles.ui(t, size: 17, weight: FontWeight.w600),
          ),
        ),
        if (store.error != null) ...[const SizedBox(height: 16), Text(store.error!, style: TextStyles.ui(t, color: t.danger))],
      ],
    );
  }
}

class _Projects extends StatelessWidget {
  const _Projects();

  Future<void> _open(BuildContext context, Project p) async {
    final store = context.read<PhoneStore>();
    if (!_opening.add(p.id)) return;
    final bool ok;
    try {
      // A project already coming down is waited for; one waiting its turn goes first.
      ok = await store.download(p);
    } finally {
      _opening.remove(p.id);
    }
    if (!ok || !context.mounted) return;
    store.markOpened(p);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhoneRehearsalScreen(project: p, store: store, folderAccess: store.folderAccess, audio: store.folderAccess),
      ),
    );
    // The screen saves where it was left as it closes.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    store.refreshProgress();
  }

  /// The cloud / device icon on a cover: what is downloaded, and what can be done about it.
  Future<void> _downloadSheet(BuildContext context, Project p) async {
    final store = context.read<PhoneStore>();
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.sheet,
      constraints: sheetConstraints(context),
      builder: (ctx) => ListenableBuilder(
        listenable: store,
        builder: (ctx, _) {
          final phase = store.phaseOf(p);
          final local = store.localBytes(p);
          final pct = ((store.downloading[p.id] ?? 0) * 100).round();
          final ahead = (store.queuePlace(p) ?? 1) - 1 + (store.downloading.isEmpty ? 0 : store.downloading.length);
          final (IconData icon, String status) = switch (phase) {
            DownloadPhase.cloud => (Icons.cloud_outlined, 'In iCloud Drive only. Not on this device yet.'),
            DownloadPhase.queued => (Icons.schedule_rounded, ahead <= 1 ? 'Waiting for a download to finish.' : 'Waiting behind $ahead downloads.'),
            DownloadPhase.downloading => (Icons.downloading_rounded, 'Downloading… $pct%'),
            DownloadPhase.device => (Icons.download_done_rounded, local > 0 ? 'On this device · ${_size(local)}' : 'On this device'),
          };
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(p.name, style: TextStyles.ui(t, size: 17, weight: FontWeight.w700)),
                  subtitle: Row(
                    children: [
                      Icon(icon, size: 16, color: t.muted),
                      const SizedBox(width: 6),
                      Expanded(child: Text(status)),
                    ],
                  ),
                ),
                if (phase == DownloadPhase.cloud)
                  ListTile(
                    key: const Key('downloadProject'),
                    leading: const Icon(Icons.cloud_download_outlined),
                    title: const Text('Download'),
                    subtitle: const Text('Keeps the audio and script on this device so it plays offline. Several can be queued; they come down one after another.'),
                    onTap: () {
                      Navigator.pop(ctx);
                      store.enqueue(p);
                    },
                  ),
                if (phase == DownloadPhase.queued || phase == DownloadPhase.downloading)
                  ListTile(
                    key: const Key('cancelDownload'),
                    leading: const Icon(Icons.close_rounded),
                    title: Text(phase == DownloadPhase.queued ? 'Remove from Queue' : 'Cancel Download'),
                    onTap: () {
                      Navigator.pop(ctx);
                      store.cancelDownload(p);
                    },
                  ),
                if (phase == DownloadPhase.device)
                  ListTile(
                    key: const Key('removeDownloadHere'),
                    leading: const Icon(Icons.cloud_off_rounded),
                    title: const Text('Remove Download'),
                    subtitle: Text(
                      local < _smallestWorthRemoving
                          ? 'Nothing much to remove.'
                          : 'Frees ${_size(local)}. It stays in iCloud Drive and comes back when you open it.',
                    ),
                    enabled: local >= _smallestWorthRemoving,
                    onTap: () async {
                      Navigator.pop(ctx);
                      final messenger = ScaffoldMessenger.of(context);
                      final r = await store.removeDownload(p);
                      if (r == null) return;
                      showNotice(messenger, _removedMessage(p, r));
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Long-press a cover: ask the Mac to render it (or take the request back).
  Future<void> _projectMenu(BuildContext context, Project p) async {
    final store = context.read<PhoneStore>();
    final t = Tokens.of(context);
    final asked = store.requests[p.id];
    final missing = store.missingScenes(p);
    final local = store.localBytes(p);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.sheet,
      constraints: sheetConstraints(context),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(p.name, style: TextStyles.ui(t, size: 17, weight: FontWeight.w700)),
            ),
            if (asked == null)
              ListTile(
                leading: const Icon(Icons.graphic_eq_rounded),
                title: const Text('Ask Mac to Render'),
                subtitle: Text(
                  missing == null
                      ? 'Every scene not rendered yet. Table Read on your Mac will ask you to start it.'
                      : missing.isEmpty
                      ? 'Every scene is rendered already.'
                      : '${missing.length} scene${missing.length == 1 ? '' : 's'} not rendered yet. Table Read on your Mac will ask you to start it.',
                ),
                enabled: missing == null || missing.isNotEmpty,
                onTap: () {
                  Navigator.pop(ctx);
                  store.requestRender(p);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.close_rounded),
                title: const Text('Cancel Render Request'),
                subtitle: Text('Asked for ${asked.summary}'),
                onTap: () {
                  Navigator.pop(ctx);
                  store.cancelRequest(p);
                },
              ),
            if (store.phaseOf(p) == DownloadPhase.cloud)
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined),
                title: const Text('Download'),
                subtitle: const Text('Keeps it on this device so it plays offline.'),
                onTap: () {
                  Navigator.pop(ctx);
                  store.enqueue(p);
                },
              ),
            ListTile(
              leading: const Icon(Icons.cloud_off_rounded),
              title: const Text('Remove Download'),
              subtitle: Text(
                local < _smallestWorthRemoving
                    ? 'Nothing downloaded to remove.'
                    : 'Frees ${_size(local)} on this device. It stays in iCloud Drive and comes back when you open it.',
              ),
              enabled: local >= _smallestWorthRemoving && !store.downloading.containsKey(p.id),
              onTap: () async {
                Navigator.pop(ctx);
                final messenger = ScaffoldMessenger.of(context);
                final r = await store.removeDownload(p);
                if (r == null) return;
                showNotice(messenger, _removedMessage(p, r));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context) async {
    final store = context.read<PhoneStore>();
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.sheet,
      constraints: sheetConstraints(context),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('Choose a Different Folder'),
              subtitle: Text(store.folder ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.pop(ctx);
                store.pickFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('Refresh'),
              onTap: () {
                Navigator.pop(ctx);
                store.refresh();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final store = context.watch<PhoneStore>();
    return RefreshIndicator(
      onRefresh: store.refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(child: Text('Projects', style: TextStyles.display(t, size: 32))),
                  if (store.importing)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    )
                  else
                    IconButton(
                      tooltip: 'Import a PDF',
                      icon: Icon(Icons.add_rounded, color: t.ink2),
                      onPressed: store.folder == null ? null : () => store.importPdf(),
                    ),
                  IconButton(
                    tooltip: 'More',
                    icon: Icon(Icons.more_horiz_rounded, color: t.ink2),
                    onPressed: () => _menu(context),
                  ),
                ],
              ),
            ),
          ),
          if (store.requests.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              sliver: SliverToBoxAdapter(
                child: _Waiting(store: store, onTap: (p) => _projectMenu(context, p)),
              ),
            ),
          if (store.error != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Text(store.error!, style: TextStyles.ui(t, color: t.danger)),
              ),
            ),
          if (store.loading && store.projects.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))
          else if (store.projects.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    'No projects in this folder yet.\nTap + to import a screenplay PDF, or render a script on your Mac and it shows up here.',
                    textAlign: TextAlign.center,
                    style: TextStyles.ui(t, size: 16, color: t.muted, height: 1.5),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              sliver: SliverGrid(
                // Two covers across on a phone; as many as fit on an iPad.
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 230,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 16,
                  childAspectRatio: 196 / 258,
                ),
                delegate: SliverChildBuilderDelegate(childCount: store.projects.length, (context, i) {
                  final p = store.projects[i];
                  return _Cover(
                    project: p,
                    store: store,
                    onOpen: () => _open(context, p),
                    onMenu: () => _projectMenu(context, p),
                    onDownloadTap: () => _downloadSheet(context, p),
                  );
                }),
              ),
            ),
        ],
      ),
    );
  }
}

/// One project's cover with what the phone knows about it: whether it is in the cloud or on the device (and how far its
/// download is), whether it is new, and how far it has been read.
class _Cover extends StatelessWidget {
  const _Cover({required this.project, required this.store, required this.onOpen, required this.onMenu, required this.onDownloadTap});
  final Project project;
  final PhoneStore store;
  final VoidCallback onOpen, onMenu, onDownloadTap;

  // The Mac's cover is 196 pt wide and 232 pt tall; everything here is placed against that, scaled to the column.
  static const _w = 196.0, _h = 232.0;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final p = project;
    final phase = store.phaseOf(p);
    final known = store.onDevice.containsKey(p.id) || phase != DownloadPhase.cloud || !store.folderAccess;
    final read = store.progress[p.id];
    final isNew = store.isNew(p);
    final label = [
      p.name,
      if (isNew) 'new',
      if (read != null && read > 0) '${(read * 100).round()} percent read',
      switch (phase) {
        DownloadPhase.cloud => 'in iCloud, not downloaded',
        DownloadPhase.queued => 'waiting to download',
        DownloadPhase.downloading => 'downloading',
        DownloadPhase.device => 'on this device',
      },
    ].join(', ');
    return LayoutBuilder(
      builder: (context, box) {
        final s = box.maxWidth / _w;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onOpen,
                onLongPress: onMenu,
                child: Semantics(
                  button: true,
                  label: label,
                  child: ExcludeSemantics(
                    // The Mac's cover, scaled to the column.
                    child: IgnorePointer(
                      child: FittedBox(
                        alignment: Alignment.topCenter,
                        child: ScriptCover(
                          project: p,
                          selected: false,
                          renaming: false,
                          archiving: false,
                          backgroundProgress: store.downloading[p.id],
                          onTap: () {},
                          onSelect: () {},
                          onMenu: (_) {},
                          onRename: (_) {},
                          onRenameCancel: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (read != null && read > 0.005)
              Positioned(
                left: 12 * s,
                right: 0,
                top: _h * s - 5 * s,
                height: 5 * s,
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.only(bottomRight: Radius.circular(8 * s)),
                    child: Stack(
                      children: [
                        Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: 0.28))),
                        FractionallySizedBox(
                          widthFactor: read.clamp(0.02, 1.0),
                          child: ColoredBox(key: const Key('coverProgress'), color: t.dark ? t.accentLine.withValues(alpha: 1) : t.accent),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // NEW sits in the date row under the cover, clear of the title.
            if (isNew)
              Positioned(
                top: _h * s + 6 * s,
                right: 2,
                child: IgnorePointer(
                  child: Container(
                    key: const Key('coverNew'),
                    padding: EdgeInsets.symmetric(horizontal: 7 * s.clamp(0.9, 1.2), vertical: 1.5),
                    decoration: BoxDecoration(color: t.accent, borderRadius: BorderRadius.circular(20)),
                    child: Text(
                      'NEW',
                      style: TextStyle(fontFamily: Fonts.ui, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: t.onAccent),
                    ),
                  ),
                ),
              ),
            // The download icon takes the cover's top right corner (the title keeps clear of it).
            if (known)
              Positioned(
                right: 0,
                top: 0,
                child: _DownloadBadge(
                  key: Key('download_${p.id}'),
                  phase: phase,
                  progress: store.downloading[p.id] ?? 0,
                  place: store.queuePlace(p),
                  onTap: onDownloadTap,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The round icon on a cover: a cloud with an arrow (in iCloud, tap to download), a clock (waiting its turn), a ring that
/// fills while downloading (tap to stop), or a tick (on this device). Tapping any of them opens the download options.
class _DownloadBadge extends StatelessWidget {
  const _DownloadBadge({super.key, required this.phase, required this.progress, required this.place, required this.onTap});
  final DownloadPhase phase;
  final double progress;
  final int? place;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final (String tip, Widget glyph) = switch (phase) {
      DownloadPhase.cloud => ('In iCloud. Download options', Icon(Icons.cloud_download_outlined, size: 17, color: t.ink2)),
      DownloadPhase.queued => ('Waiting to download', Icon(Icons.schedule_rounded, size: 17, color: t.muted)),
      DownloadPhase.downloading => (
        'Downloading. Options',
        SizedBox(
          width: 22,
          height: 22,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: progress.clamp(0.04, 1.0),
                strokeWidth: 2.6,
                color: t.accent,
                backgroundColor: t.accent.withValues(alpha: 0.2),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: t.accent, borderRadius: BorderRadius.circular(2)),
              ),
            ],
          ),
        ),
      ),
      DownloadPhase.device => ('On this device. Download options', Icon(Icons.download_done_rounded, size: 17, color: t.ok)),
    };
    return Semantics(
      button: true,
      label: tip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // A 44 pt target around a smaller disc.
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (t.dark ? Colors.black : Colors.white).withValues(alpha: 0.78),
                border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
              ),
              child: glyph,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Waiting for your Mac": the projects this phone asked the Mac to render.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.store, required this.onTap});
  final PhoneStore store;
  final ValueChanged<Project> onTap;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final rows = [
      for (final p in store.projects)
        if (store.requests[p.id] case final r?) (p, r),
    ];
    return Container(
      decoration: BoxDecoration(
        color: t.accentSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.accentLine),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WAITING FOR YOUR MAC', style: TextStyles.label(t)),
          const SizedBox(height: 2),
          for (final (p, r) in rows)
            InkWell(
              onTap: () => onTap(p),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.graphic_eq_rounded, size: 20, color: t.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyles.ui(t, size: 16, weight: FontWeight.w600),
                          ),
                          Text(
                            '${r.summary[0].toUpperCase()}${r.summary.substring(1)} · asked ${_lowerFirst(friendlyDate(r.requestedAt))}',
                            style: TextStyles.ui(t, size: 13, color: t.muted),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.more_horiz_rounded, color: t.muted),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Today, 9:14" reads as "asked today, 9:14" mid-sentence.
String _lowerFirst(String s) => s.startsWith('Today') || s.startsWith('Yesterday') ? s[0].toLowerCase() + s.substring(1) : s;
