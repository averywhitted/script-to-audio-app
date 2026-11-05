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
      body: SafeArea(child: store.folder == null && !store.loading ? const _Welcome() : const _Projects()),
    );
  }
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
    if (store.downloading.containsKey(p.id)) return;
    final ok = await store.download(p);
    if (!ok || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhoneRehearsalScreen(project: p, store: store, folderAccess: store.folderAccess, audio: store.folderAccess),
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
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _open(context, p),
                    onLongPress: () => _projectMenu(context, p),
                    child: Semantics(
                      button: true,
                      label: p.name,
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
                  );
                }),
              ),
            ),
        ],
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
