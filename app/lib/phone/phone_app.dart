// Table Read on iPhone (#90): pick the projects folder once, then the
// project covers, as on the Mac. Rehearsal happens on the Mac's renders.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/project_files.dart';
import '../theme/tokens.dart';
import '../ui/gallery.dart' show ScriptCover;
import 'phone_store.dart';

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
      body: SafeArea(
        child: store.folder == null && !store.loading
            ? const _Welcome()
            : const _Projects(),
      ),
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
            child: Text(n, style: TextStyles.ui(t, size: 14, weight: FontWeight.w700, color: t.accent)),
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
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.asset('assets/app_icon.png', width: 96, height: 96),
          ),
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
        if (store.error != null) ...[
          const SizedBox(height: 16),
          Text(store.error!, style: TextStyles.ui(t, color: t.danger)),
        ],
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
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PhoneProjectScreen(project: p)));
  }

  Future<void> _menu(BuildContext context) async {
    final store = context.read<PhoneStore>();
    final t = Tokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.sheet,
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
                  IconButton(
                    tooltip: 'More',
                    icon: Icon(Icons.more_horiz_rounded, color: t.ink2),
                    onPressed: () => _menu(context),
                  ),
                ],
              ),
            ),
          ),
          if (store.error != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              sliver: SliverToBoxAdapter(child: Text(store.error!, style: TextStyles.ui(t, color: t.danger))),
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
                    'No projects in this folder yet.\nRender a script on your Mac and it shows up here.',
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
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 16,
                  childAspectRatio: 196 / 258,
                ),
                delegate: SliverChildBuilderDelegate(childCount: store.projects.length, (context, i) {
                  final p = store.projects[i];
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _open(context, p),
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

/// Stand-in until the rehearsal screen (#91): the scenes the Mac saved.
class PhoneProjectScreen extends StatelessWidget {
  const PhoneProjectScreen({super.key, required this.project});
  final Project project;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final folder = project.folderPath!;
    final script = loadScriptSnapshot(folder);
    final rendered = <int>{
      for (final f in Directory(folder).listSync().whereType<File>())
        if (RegExp(r'/Scene_(\d+)_.*\.m4a$').firstMatch(f.path) case final m?) int.parse(m.group(1)!),
    };
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        title: Text(project.name, style: TextStyles.ui(t, size: 17, weight: FontWeight.w600)),
      ),
      body: script == null
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'Open this project on your Mac once, and it saves the script for your iPhone.',
                  textAlign: TextAlign.center,
                  style: TextStyles.ui(t, size: 16, color: t.muted, height: 1.5),
                ),
              ),
            )
          : ListView.separated(
              itemCount: script.scenes.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: t.ruleSoft),
              itemBuilder: (context, i) {
                final s = script.scenes[i];
                final title = project.sceneTitleOverrides.values.map((m) => m[s.number]).nonNulls.firstOrNull ?? s.title;
                return ListTile(
                  leading: Text(s.number.toString().padLeft(2, '0'), style: TextStyles.script(t, size: 14, weight: FontWeight.w700)),
                  title: Text(title, style: TextStyles.ui(t, size: 16)),
                  subtitle: Text('${s.elements.length} lines', style: TextStyles.ui(t, color: t.muted)),
                  trailing: rendered.contains(s.number)
                      ? Icon(Icons.graphic_eq_rounded, color: t.ok)
                      : Text('Text only', style: TextStyles.ui(t, size: 12, color: t.muted)),
                );
              },
            ),
    );
  }
}
