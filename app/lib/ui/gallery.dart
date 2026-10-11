// Projects (Project Gallery). Contract: screens[gallery].

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/platform.dart';
import '../services/project_store.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'empty_art.dart';
import 'export.dart';
import 'header.dart';
import 'sheets.dart';
import 'widgets.dart';

enum SortKey { recent, name, scenes, memorized }

extension on SortKey {
  String get label => switch (this) {
    SortKey.recent => 'Last Opened',
    SortKey.name => 'Name',
    SortKey.scenes => 'Scenes',
    SortKey.memorized => 'Memorized',
  };
}

String friendlyDate(DateTime d) {
  final now = clockNow();
  final local = d.toLocal();
  if (local.year == now.year && local.month == now.month && local.day == now.day) {
    return 'Today, ${DateFormat('H:mm').format(local)}';
  }
  final y = now.subtract(const Duration(days: 1));
  if (local.year == y.year && local.month == y.month && local.day == y.day) return 'Yesterday';
  if (local.year == now.year) return DateFormat('MMM d').format(local);
  return DateFormat('MMM d, y').format(local);
}

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  bool showArchived = false;
  bool listView = false;
  bool filterRendered = false;
  bool filterHasScreenplay = false;
  SortKey sortKey = SortKey.recent;
  bool descending = true;
  final Set<String> selected = {};
  String? anchorId;
  String? renamingId;

  // Rubber-band selection
  final Map<String, GlobalKey> _cardKeys = {};
  Offset? _dragStart, _dragNow;
  bool _downOnCard = false;
  final GlobalKey _areaKey = GlobalKey();

  List<Project> _displayed(ProjectStore store) {
    var list = List<Project>.of(store.projects);
    if (filterRendered) list = list.where((p) => p.renderedScenes.isNotEmpty).toList();
    if (filterHasScreenplay) list = list.where((p) => p.pdfFilename.isNotEmpty).toList();
    int cmp(Project a, Project b) => switch (sortKey) {
      SortKey.recent => a.lastOpenedAt.compareTo(b.lastOpenedAt),
      SortKey.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortKey.scenes => a.renderedScenes.length.compareTo(b.renderedScenes.length),
      SortKey.memorized => 0, // no memorization data yet; keep order
    };
    if (sortKey != SortKey.memorized) list.sort((a, b) => descending ? cmp(b, a) : cmp(a, b));
    return list;
  }

  void _toggleSort(SortKey k) => setState(() {
    if (sortKey == k) {
      descending = !descending;
    } else {
      sortKey = k;
      descending = true;
    }
  });

  void _tap(Project p, List<Project> shown) {
    final keys = HardwareKeyboard.instance;
    setState(() {
      renamingId = null;
      if (keys.isMetaPressed) {
        selected.contains(p.id) ? selected.remove(p.id) : selected.add(p.id);
        anchorId = p.id;
      } else if (keys.isShiftPressed && anchorId != null) {
        final a = shown.indexWhere((x) => x.id == anchorId), b = shown.indexWhere((x) => x.id == p.id);
        if (a >= 0 && b >= 0) {
          for (var i = (a < b ? a : b); i <= (a < b ? b : a); i++) {
            selected.add(shown[i].id);
          }
        }
      } else if (selected.length == 1 && selected.contains(p.id)) {
        selected.clear();
        anchorId = null;
      } else {
        selected
          ..clear()
          ..add(p.id);
        anchorId = p.id;
      }
    });
  }

  /// A click opens the project. While a selection is under way (or with ⌘ or
  /// ⇧ held) it adds to or removes from the selection instead.
  void _click(Project p, List<Project> shown) {
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isShiftPressed) return _tap(p, shown);
    if (selected.isNotEmpty) return _toggleSelect(p);
    _open(p);
  }

  void _toggleSelect(Project p) => setState(() {
    renamingId = null;
    selected.contains(p.id) ? selected.remove(p.id) : selected.add(p.id);
    anchorId = p.id;
  });

  void _rename(Project p) => setState(() {
    selected.clear();
    renamingId = p.id;
  });

  Future<void> _projectMenu(Project p, Offset pos) async {
    final pick = await showMenuAt<String>(context, pos, [
      const MenuItemSpec('open', 'Open'),
      const MenuItemSpec('rename', 'Rename…'),
      MenuItemSpec('export', 'Export Audio…', enabled: p.renderedScenes.isNotEmpty && p.folderPath != null),
      const MenuItemSpec.divider(),
      const MenuItemSpec('archive', 'Archive'),
      const MenuItemSpec('delete', 'Delete…'),
    ]);
    if (!mounted) return;
    switch (pick) {
      case 'open':
        _open(p);
      case 'rename':
        _rename(p);
      case 'export':
        exportAudio(context, sourceFolder: p.folderPath!, projectName: p.name);
      case 'archive':
        _confirmArchive([p]);
      case 'delete':
        _confirmDelete([p]);
    }
  }

  void _open(Project p) {
    final app = context.read<AppState>();
    final store = context.read<ProjectStore>();
    if (app.isGenerating && app.backgroundRenderProjectId != null && app.backgroundRenderProjectId != p.id) {
      app.showError('A render is in progress. Wait for it to finish before opening another project.');
      return;
    }
    setState(() {
      selected.clear();
      renamingId = null;
    });
    final opened = store.openProject(p);
    if (app.backgroundRenderProjectId == p.id) {
      app.backgroundRenderProjectId = null;
      store.currentProject = opened;
      app.persistProject();
      app.refresh();
      return;
    }
    app.loadFromProject(opened);
  }

  Future<void> _newProject() async {
    final result = await showSheet<(String, String?)>(context, (ctx) => const NewProjectSheet(), width: 460);
    if (result == null || !mounted) return;
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'PDF', extensions: ['pdf'], uniformTypeIdentifiers: ['com.adobe.pdf']),
      ],
    );
    if (file == null || !mounted) return;
    final store = context.read<ProjectStore>();
    final app = context.read<AppState>();
    try {
      final p = store.createProject(name: result.$1, customContainer: result.$2, pdfSourcePath: file.path, engine: app.selectedEngine.id);
      _open(p);
    } catch (e) {
      app.showError('Could not create the project: $e');
    }
  }

  Future<void> _confirmDelete(List<Project> items) async {
    final n = items.length;
    final r = await showConfirm(
      context,
      title: n == 1 ? 'Move this project to the Trash?' : 'Move $n projects to the Trash?',
      message: 'The project folder and any rendered audio go to the Trash. You can put them back from there, or from Recently Deleted.',
      buttons: const [('Cancel', BtnKind.secondary), ('Move to Trash', BtnKind.danger)],
    );
    if (r != 'Move to Trash' || !mounted) return;
    final store = context.read<ProjectStore>();
    setState(selected.clear);
    for (final p in items) {
      await store.deleteProject(p);
    }
  }

  Future<void> _confirmArchive(List<Project> items) async {
    final n = items.length;
    final r = await showConfirm(
      context,
      title: n == 1 ? 'Archive this project?' : 'Archive $n projects?',
      message: 'Each project is zipped, then its folder is moved to the Trash. You can unarchive it later from the Archived tab.',
      buttons: const [('Cancel', BtnKind.secondary), ('Archive', BtnKind.primary)],
    );
    if (r != 'Archive' || !mounted) return;
    final store = context.read<ProjectStore>();
    setState(selected.clear);
    for (final p in items) {
      await store.archiveProject(p);
    }
  }

  void _updateRubberBand(List<Project> shown) {
    final area = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (area == null || _dragStart == null || _dragNow == null) return;
    final rect = Rect.fromPoints(_dragStart!, _dragNow!);
    final hits = <String>{};
    for (final p in shown) {
      final box = _cardKeys[p.id]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final r = box.localToGlobal(Offset.zero, ancestor: area) & box.size;
      if (r.overlaps(rect)) hits.add(p.id);
    }
    setState(() {
      selected
        ..clear()
        ..addAll(hits);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final store = context.watch<ProjectStore>();
    final app = context.watch<AppState>();
    final shown = _displayed(store);
    final selectedProjects = shown.where((p) => selected.contains(p.id)).toList();

    return Material(
      color: t.bg,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Window header: traffic lights on the left, app options top-right.
              const AppHeader(border: false),
              _toolbar(t, store),
              Expanded(
                child: showArchived
                    ? _archived(t, store)
                    : (shown.isEmpty && store.recentlyDeleted.isEmpty && store.projects.isEmpty)
                    ? _empty(t)
                    : _active(t, store, app, shown),
              ),
            ],
          ),
          if (selected.isNotEmpty && !showArchived)
            Positioned(
              left: 0,
              right: 0,
              bottom: 18,
              child: Center(
                child: FloatingBar(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        '${selected.length} selected',
                        style: TextStyles.ui(t, size: 12.5, weight: FontWeight.w600, color: t.barInk),
                      ),
                    ),
                    if (selected.length == 1) BarButton('Rename', icon: Icons.edit_outlined, onTap: () => _rename(selectedProjects.first)),
                    BarButton('Archive', icon: Icons.archive_outlined, onTap: () => _confirmArchive(selectedProjects)),
                    BarButton('Delete', icon: Icons.delete_outline_rounded, danger: true, onTap: () => _confirmDelete(selectedProjects)),
                    BarButton('', icon: Icons.close_rounded, onTap: () => setState(selected.clear), tooltip: 'Clear selection'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolbar(Tokens t, ProjectStore store) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 6, 32, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Table Read', style: TextStyles.display(t, size: 34)),
              const SizedBox(height: 2),
              Text('Projects', style: TextStyles.ui(t, size: 14, color: t.muted)),
            ],
          ),
          const Spacer(),
          Segmented(
            labels: const ['Active', 'Archived'],
            selected: showArchived ? 1 : 0,
            onChanged: (i) => setState(() {
              showArchived = i == 1;
              selected.clear();
              if (showArchived) store.loadArchivedProjects();
            }),
          ),
          if (!showArchived) ...[
            const SizedBox(width: 10),
            Builder(
              builder: (ctx) => Stack(
                clipBehavior: Clip.none,
                children: [
                  IconBtn(
                    Icons.filter_list_rounded,
                    tooltip: 'Filter projects',
                    onTap: () async {
                      final v = await showAnchoredMenu<String>(ctx, [
                        MenuItemSpec('rendered', 'Rendered', checked: filterRendered),
                        MenuItemSpec('screenplay', 'Has Screenplay', checked: filterHasScreenplay),
                      ]);
                      setState(() {
                        if (v == 'rendered') filterRendered = !filterRendered;
                        if (v == 'screenplay') filterHasScreenplay = !filterHasScreenplay;
                      });
                    },
                  ),
                  if (filterRendered || filterHasScreenplay)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Segmented(
              labels: const ['', ''],
              icons: const [Icons.grid_view_rounded, Icons.view_list_rounded],
              selected: listView ? 1 : 0,
              onChanged: (i) => setState(() => listView = i == 1),
            ),
            if (!listView) ...[
              const SizedBox(width: 6),
              Builder(
                builder: (ctx) => Tooltip(
                  message: 'Sort projects',
                  child: Btn(
                    sortKey.label,
                    trailingIcon: descending ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                    kind: BtnKind.secondary,
                    small: true,
                    onPressed: () async {
                      final v = await showAnchoredMenu<SortKey>(ctx, [
                        for (final k in SortKey.values)
                          MenuItemSpec(k, sortKey == k ? '${k.label} (${descending ? 'descending' : 'ascending'})' : k.label, checked: sortKey == k),
                      ]);
                      if (v != null) _toggleSort(v);
                    },
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(width: 12),
          Btn('New Project', kind: BtnKind.primary, icon: Icons.add_rounded, onPressed: _newProject),
        ],
      ),
    );
  }

  Widget _empty(Tokens t) => EmptyState(
    art: EmptyArt.table,
    title: 'No projects yet',
    message: 'Create a new project to get started.',
    action: Btn('New Project', kind: BtnKind.primary, icon: Icons.add_rounded, onPressed: _newProject),
  );

  Widget _active(Tokens t, ProjectStore store, AppState app, List<Project> shown) {
    final band = (_dragStart != null && _dragNow != null) ? Rect.fromPoints(_dragStart!, _dragNow!) : null;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _downOnCard = ClickTarget.lastHandledDown == e.timeStamp;
        if (!_downOnCard && (selected.isNotEmpty || renamingId != null)) {
          setState(() {
            selected.clear();
            renamingId = null;
          });
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (d) {
          if (_downOnCard) return;
          setState(() {
            _dragStart = d.localPosition;
            _dragNow = d.localPosition;
          });
        },
        onPanUpdate: (d) {
          if (_dragStart == null) return;
          _dragNow = d.localPosition;
          _updateRubberBand(shown);
        },
        onPanEnd: (_) => setState(() {
          _dragStart = null;
          _dragNow = null;
        }),
        child: Stack(
          key: _areaKey,
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(40, 0, 40, 90),
              children: [
                if (listView) _listTable(t, store, app, shown) else _grid(t, store, app, shown),
                if (store.recentlyDeleted.isNotEmpty) ...[const SizedBox(height: 28), _recentlyDeleted(t, store)],
              ],
            ),
            if (band != null)
              Positioned.fromRect(
                rect: band,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.accentSoft,
                      border: Border.all(color: t.accentLine),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _grid(Tokens t, ProjectStore store, AppState app, List<Project> shown) {
    return Wrap(
      spacing: 22,
      runSpacing: 22,
      children: [
        for (final p in shown)
          ScriptCover(
            key: _cardKeys.putIfAbsent(p.id, () => GlobalKey()),
            project: p,
            selected: selected.contains(p.id),
            renaming: renamingId == p.id,
            archiving: store.archivingIds.contains(p.id),
            backgroundProgress: app.backgroundRenderProjectId == p.id && app.isGenerating ? app.generationProgress : null,
            onTap: () => _click(p, shown),
            onSelect: () => _toggleSelect(p),
            onMenu: (pos) => _projectMenu(p, pos),
            onRename: (name) {
              store.renameProject(p.id, name);
              setState(() => renamingId = null);
            },
            onRenameCancel: () => setState(() => renamingId = null),
          ),
      ],
    );
  }

  Widget _listTable(Tokens t, ProjectStore store, AppState app, List<Project> shown) {
    Widget header(String label, SortKey k, {double? width, TextAlign align = TextAlign.left}) {
      final active = sortKey == k;
      final w = GestureDetector(
        onTap: () => _toggleSort(k),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyles.ui(t, size: 11.5, weight: FontWeight.w600, color: active ? t.ink : t.muted),
              ),
              const SizedBox(width: 3),
              Icon(
                active ? (descending ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded) : Icons.unfold_more_rounded,
                size: 12,
                color: active ? t.ink2 : t.faint,
              ),
            ],
          ),
        ),
      );
      return width == null ? Expanded(child: w) : SizedBox(width: width, child: w);
    }

    return Panel(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(46, 10, 18, 8),
            child: Row(
              children: [
                header('Name', SortKey.name),
                const SizedBox(width: 110),
                header('Scenes', SortKey.scenes, width: 70),
                header('Last Opened', SortKey.recent, width: 120),
                const SizedBox(width: 26),
              ],
            ),
          ),
          const Hairline(),
          for (final p in shown) ...[
            ProjectRow(
              key: _cardKeys.putIfAbsent(p.id, () => GlobalKey()),
              project: p,
              selected: selected.contains(p.id),
              renaming: renamingId == p.id,
              archiving: store.archivingIds.contains(p.id),
              backgroundProgress: app.backgroundRenderProjectId == p.id && app.isGenerating ? app.generationProgress : null,
              onTap: () => _click(p, shown),
              onSelect: () => _toggleSelect(p),
              onMenu: (pos) => _projectMenu(p, pos),
              onRename: (name) {
                store.renameProject(p.id, name);
                setState(() => renamingId = null);
              },
              onRenameCancel: () => setState(() => renamingId = null),
            ),
            if (p != shown.last) const Hairline(),
          ],
        ],
      ),
    );
  }

  Widget _recentlyDeleted(Tokens t, ProjectStore store) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('RECENTLY DELETED', style: TextStyles.label(t)),
              const SizedBox(width: 10),
              Text('In your Trash — recoverable this session', style: TextStyles.ui(t, size: 12, color: t.faint)),
            ],
          ),
          const SizedBox(height: 8),
          for (final r in store.recentlyDeleted)
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(
                color: t.sheet,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.delete_outline_rounded, size: 15, color: t.faint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      r.project.name.toUpperCase(),
                      style: TextStyles.script(t, size: 12, weight: FontWeight.w700, color: t.ink2),
                    ),
                  ),
                  Btn('Restore', small: true, onPressed: () => store.restoreProject(r.project.id)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _archived(Tokens t, ProjectStore store) {
    if (store.archivedProjects.isEmpty) {
      return const EmptyState(art: EmptyArt.box, title: 'No archived projects', message: 'Archive projects to compress them and free up space.');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
      children: [
        Panel(
          child: Column(
            children: [
              for (final m in store.archivedProjects) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 17, color: t.muted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.project.name.toUpperCase(), style: TextStyles.script(t, size: 12.5, weight: FontWeight.w700)),
                            if (m.project.scriptTitle.isNotEmpty)
                              Text(
                                m.project.scriptTitle,
                                style: TextStyles.ui(t, size: 12, color: t.muted).copyWith(fontStyle: FontStyle.italic),
                              ),
                          ],
                        ),
                      ),
                      if (m.project.renderedScenes.isNotEmpty) const Stamp('RENDERED', kind: StampKind.ok, icon: Icons.check_rounded),
                      SizedBox(
                        width: 110,
                        child: Text(
                          friendlyDate(m.project.lastOpenedAt),
                          textAlign: TextAlign.right,
                          style: TextStyles.ui(t, size: 12, color: t.muted),
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 104,
                        child: store.archivingIds.contains(m.project.id)
                            ? const Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
                            : Btn('Unarchive', small: true, onPressed: () => store.unarchiveProject(m.project.id)),
                      ),
                    ],
                  ),
                ),
                if (m != store.archivedProjects.last) const Hairline(),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Grid card: a bound script cover
// ---------------------------------------------------------------------------

const _coverLight = [
  Color(0xFFF1E3A6),
  Color(0xFFCFDCE8),
  Color(0xFFEAC9BC),
  Color(0xFFD3E1C8),
  Color(0xFFE9D7A0),
  Color(0xFFDCD3E8),
  Color(0xFFC6D9D4),
  Color(0xFFE8D2C4),
];
const _coverDark = [
  Color(0xFF4A4430),
  Color(0xFF33404B),
  Color(0xFF4A3832),
  Color(0xFF39453A),
  Color(0xFF4B4529),
  Color(0xFF3F3949),
  Color(0xFF314441),
  Color(0xFF4A3D35),
];

Color coverColor(Project p, Tokens t) {
  var h = 0;
  for (final c in p.id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  final list = t.dark ? _coverDark : _coverLight;
  return list[h % list.length];
}

class ScriptCover extends StatelessWidget {
  const ScriptCover({
    super.key,
    required this.project,
    required this.selected,
    required this.renaming,
    required this.archiving,
    required this.backgroundProgress,
    required this.onTap,
    required this.onSelect,
    required this.onMenu,
    required this.onRename,
    required this.onRenameCancel,
  });
  final Project project;
  final bool selected, renaming, archiving;
  final double? backgroundProgress;

  /// Click: opens the project (or adds to a selection under way).
  final VoidCallback onTap;

  /// The checkbox: select or deselect.
  final VoidCallback onSelect;

  /// Right-click or the ⋯ button: Open / Rename / Archive / Delete.
  final ValueChanged<Offset> onMenu;
  final VoidCallback onRenameCancel;
  final ValueChanged<String> onRename;

  Widget _coverCheck(Tokens t) => Container(
    width: 18,
    height: 18,
    decoration: BoxDecoration(
      color: selected ? t.accent : Colors.white.withValues(alpha: 0.7),
      shape: BoxShape.circle,
      border: Border.all(color: selected ? t.accent : Colors.black26, width: 1.5),
    ),
    child: selected ? Icon(Icons.check_rounded, size: 12, color: t.onAccent) : null,
  );

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final cover = coverColor(project, t);
    final spine = Color.alphaBlend(Colors.black.withValues(alpha: 0.12), cover);
    final brass = t.dark ? const Color(0xFFB7964F) : const Color(0xFFA9853C);
    final n = project.renderedScenes.length;
    return Hover(
      cursor: SystemMouseCursors.click,
      builder: (context, h) => ClickTarget(
        onClick: onTap,
        onContextMenu: onMenu,
        child: SizedBox(
          width: 196,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: 232,
                transform: Matrix4.translationValues(0, h ? -2 : 0, 0),
                decoration: BoxDecoration(
                  color: cover,
                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(3), right: Radius.circular(8)),
                  border: Border.all(
                    color: selected ? t.accent : (backgroundProgress != null ? t.accentLine : Colors.black.withValues(alpha: 0.06)),
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: h ? 0.16 : 0.09),
                      blurRadius: h ? 16 : 8,
                      offset: Offset(0, h ? 8 : 4),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // Spine; fills with blue from the bottom while rendering in the background.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 12,
                      child: Container(
                        decoration: BoxDecoration(
                          color: spine,
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(2)),
                        ),
                        alignment: Alignment.bottomCenter,
                        child: backgroundProgress == null
                            ? null
                            : FractionallySizedBox(
                                heightFactor: backgroundProgress!.clamp(0.02, 1.0),
                                child: Container(color: t.accent),
                              ),
                      ),
                    ),
                    for (final y in [26.0, 192.0])
                      Positioned(
                        left: 20,
                        top: y,
                        child: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [brass.withValues(alpha: 1), Color.alphaBlend(Colors.black26, brass)],
                              center: const Alignment(-0.3, -0.4),
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 38,
                      right: 34, // clear of the checkbox
                      top: 18,
                      child: renaming
                          ? _RenameField(initial: project.name, onSubmit: onRename, onCancel: onRenameCancel, script: true)
                          : Text(
                              project.name.toUpperCase(),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyles.script(
                                t,
                                size: 13,
                                weight: FontWeight.w700,
                                color: t.dark ? const Color(0xFFF2EEE6) : const Color(0xFF2A2722),
                              ).copyWith(height: 1.3),
                            ),
                    ),
                    Positioned(
                      right: 6,
                      top: 6,
                      child: AnimatedOpacity(
                        opacity: selected || h ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        child: ClickTarget(
                          onClick: onSelect,
                          child: Tooltip(
                            message: selected ? 'Deselect' : 'Select',
                            waitDuration: const Duration(milliseconds: 600),
                            child: Padding(padding: const EdgeInsets.all(4), child: _coverCheck(t)),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: AnimatedOpacity(
                        opacity: h ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        child: _MoreButton(onMenu: onMenu, onCover: true),
                      ),
                    ),
                    if (n > 0)
                      Positioned(
                        left: 34,
                        bottom: 14,
                        child: Row(
                          children: [
                            Transform.rotate(
                              angle: -0.05,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                                decoration: BoxDecoration(
                                  border: Border.all(color: t.ok, width: 1.4),
                                  borderRadius: BorderRadius.circular(3),
                                  color: (t.dark ? Colors.black : Colors.white).withValues(alpha: 0.35),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.check_rounded, size: 11, color: t.ok),
                                    const SizedBox(width: 2),
                                    Text(
                                      'RENDERED',
                                      style: TextStyle(fontFamily: Fonts.ui, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: t.ok),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: (t.dark ? Colors.black : Colors.white).withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '$n scene${n == 1 ? '' : 's'}',
                                style: TextStyles.ui(t, size: 10.5, weight: FontWeight.w600, color: t.ink2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (archiving)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(color: t.bg.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(8)),
                          child: const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2))),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(friendlyDate(project.lastOpenedAt), style: TextStyles.ui(t, size: 12, color: t.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

class ProjectRow extends StatelessWidget {
  const ProjectRow({
    super.key,
    required this.project,
    required this.selected,
    required this.renaming,
    required this.archiving,
    required this.backgroundProgress,
    required this.onTap,
    required this.onSelect,
    required this.onMenu,
    required this.onRename,
    required this.onRenameCancel,
  });
  final Project project;
  final bool selected, renaming, archiving;
  final double? backgroundProgress;

  /// Click: opens the project (or adds to a selection under way).
  final VoidCallback onTap;

  /// The checkbox: select or deselect.
  final VoidCallback onSelect;

  /// Right-click or the ⋯ button: Open / Rename / Archive / Delete.
  final ValueChanged<Offset> onMenu;
  final VoidCallback onRenameCancel;
  final ValueChanged<String> onRename;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final n = project.renderedScenes.length;
    return Hover(
      builder: (context, h) => ClickTarget(
        onClick: onTap,
        onContextMenu: onMenu,
        child: Container(
          color: selected ? t.accentSoft : (h ? t.ruleSoft : Colors.transparent),
          padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
          child: Stack(
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: AnimatedOpacity(
                      opacity: selected || h ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: ClickTarget(
                        onClick: onSelect,
                        child: CheckMark(checked: selected, round: true, size: 16, tooltip: selected ? 'Deselect' : 'Select'),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        renaming
                            ? _RenameField(initial: project.name, onSubmit: onRename, onCancel: onRenameCancel, script: true)
                            : Text(
                                project.name.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyles.script(t, size: 12.5, weight: FontWeight.w700),
                              ),
                        if (backgroundProgress != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: SizedBox(
                              width: 160,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(value: backgroundProgress, minHeight: 3, color: t.accent, backgroundColor: t.ctrl),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: n > 0
                        ? const Align(
                            alignment: Alignment.centerLeft,
                            child: Stamp('RENDERED', kind: StampKind.ok, icon: Icons.check_rounded),
                          )
                        : null,
                  ),
                  SizedBox(
                    width: 70,
                    child: Text(
                      n == 0 ? '—' : '$n',
                      style: TextStyles.ui(t, size: 12.5, weight: FontWeight.w600, color: t.ink2),
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: Text(friendlyDate(project.lastOpenedAt), style: TextStyles.ui(t, size: 12.5, color: t.muted)),
                  ),
                  SizedBox(
                    width: 26,
                    child: AnimatedOpacity(
                      opacity: h ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: _MoreButton(onMenu: onMenu),
                    ),
                  ),
                ],
              ),
              if (archiving)
                Positioned.fill(
                  child: Container(
                    color: t.sheet.withValues(alpha: 0.7),
                    child: const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameField extends StatefulWidget {
  const _RenameField({required this.initial, required this.onSubmit, required this.onCancel, this.script = false});
  final String initial;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;
  final bool script;
  @override
  State<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends State<_RenameField> {
  late final c = TextEditingController(text: widget.initial)..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel},
      child: TextField(
        controller: c,
        autofocus: true,
        onSubmitted: widget.onSubmit,
        style: widget.script ? TextStyles.script(t, size: 12.5, weight: FontWeight.w700) : TextStyles.ui(t),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: t.field,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: t.accent),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: t.accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// Reveal a project folder (used by Settings → Projects).
Future<void> revealFolder(String path) => NativePlatform.revealInFinder(path);

/// ⋯ button on a project: opens the same menu as right-click.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.onMenu, this.onCover = false});
  final ValueChanged<Offset> onMenu;
  final bool onCover;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Builder(
      builder: (ctx) => ClickTarget(
        onClick: () {
          final box = ctx.findRenderObject() as RenderBox;
          onMenu(box.localToGlobal(Offset(0, box.size.height + 2)));
        },
        child: Tooltip(
          message: 'More (Rename, Archive, Delete)',
          waitDuration: const Duration(milliseconds: 600),
          child: Container(
            width: 24,
            height: 22,
            decoration: BoxDecoration(color: onCover ? Colors.white.withValues(alpha: 0.75) : t.ctrl, borderRadius: BorderRadius.circular(6)),
            child: Icon(Icons.more_horiz_rounded, size: 16, color: onCover ? const Color(0xFF2A2722) : t.ink2),
          ),
        ),
      ),
    );
  }
}
