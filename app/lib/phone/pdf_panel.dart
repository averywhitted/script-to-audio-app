// The PDF and its toolbar (#115). On iPhone it fills a screen of its own; on iPad it
// sits beside the script (#121). The toolbar has search, the page / continuous
// switch (#120) and Apple Pencil markup (#119), the last two on iPad only.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'ink_layer.dart';
import 'pdf_view.dart';
import 'rehearsal_session.dart';

class PdfPanel extends StatefulWidget {
  const PdfPanel({
    super.key,
    required this.pdfPath,
    required this.folder,
    required this.controller,
    required this.pad,
    this.onClose,
    this.folderAccess = true,
    this.linkedQuery,
    this.onSearch,
  });

  final String pdfPath;
  final String folder;
  final PdfController controller;

  /// iPad: page / continuous switch and Pencil markup are on.
  final bool pad;
  final VoidCallback? onClose;
  final bool folderAccess;

  /// Beside the script there is one search for both: this is its text (the PDF highlights it too), and [onSearch] opens it.
  final String? linkedQuery;
  final VoidCallback? onSearch;

  @override
  State<PdfPanel> createState() => _PdfPanelState();
}

class _PdfPanelState extends State<PdfPanel> {
  PdfMarkup? _markup;
  bool _searching = false;
  final _query = TextEditingController();
  final _queryFocus = FocusNode();

  PdfController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _openMarkup();
  }

  Future<void> _openMarkup() async {
    final id = await RehearsalSession.deviceId();
    final m = PdfMarkup(folder: widget.folder, deviceId: id, folderAccess: widget.folderAccess)..load();
    c.initialMarkup = m.drawings;
    c.onMarkup = (page, data) => m.set(page, data);
    if (mounted) setState(() => _markup = m);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    c.onMarkup = null;
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _search(String q) => c.search(q);

  void _closeSearch() {
    setState(() => _searching = false);
    _query.clear();
    c.clearSearch();
  }

  Future<void> _askPage() async {
    final t = Tokens.of(context);
    final ctl = TextEditingController();
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.sheet,
        title: const Text('Go to page'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: '1–${c.pageCount}'),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text)), child: const Text('Go')),
        ],
      ),
    );
    ctl.dispose();
    if (n != null && n >= 1 && n <= c.pageCount) c.goToPage(n);
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Focus(
      // ⌘F on a keyboard: this panel's own search, or the script's when it is beside it.
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyF || !HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        if (widget.onSearch != null) {
          widget.onSearch!();
        } else {
          setState(() => _searching = true);
          WidgetsBinding.instance.addPostFrameCallback((_) => _queryFocus.requestFocus());
        }
        return KeyEventResult.handled;
      },
      child: _body(t),
    );
  }

  Widget _body(Tokens t) {
    return Column(
      children: [
        _searching && widget.onSearch == null ? _searchBar(t) : _toolbar(t),
        if (widget.pad && c.markup) _inkStrip(t),
        if (widget.linkedQuery != null && widget.linkedQuery!.trim().isNotEmpty) _linkedStrip(t),
        Expanded(
          child: Stack(
            children: [
              if (_markup != null)
                Positioned.fill(
                  child: PdfNativeView(path: widget.pdfPath, controller: c),
                ),
              if (_markup != null) Positioned.fill(child: InkOverlay(controller: c)),
              if (c.pageCount > 0)
                Positioned(
                  bottom: 14,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: _askPage,
                      child: Container(
                        key: const Key('pdfPageIndicator'),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(16)),
                        child: Text(
                          'Page ${c.page} of ${c.pageCount}',
                          style: TextStyles.ui(t, size: 13, weight: FontWeight.w600, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar(Tokens t) {
    Widget btn(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => IconButton(
      tooltip: tip,
      icon: Icon(icon, color: on ? t.onAccent : t.ink2),
      style: on ? IconButton.styleFrom(backgroundColor: t.accent) : null,
      onPressed: onTap,
    );
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(bottom: BorderSide(color: t.rule)),
      ),
      child: Row(
        children: [
          if (widget.onClose != null) btn(Icons.close_rounded, 'Close PDF', widget.onClose),
          Expanded(
            child: Text('Script PDF', style: TextStyles.ui(t, size: 16, weight: FontWeight.w600)),
          ),
          btn(Icons.search_rounded, 'Search the PDF', () {
            if (widget.onSearch != null) return widget.onSearch!();
            setState(() => _searching = true);
            WidgetsBinding.instance.addPostFrameCallback((_) => _queryFocus.requestFocus());
          }),
          if (!c.continuous) ...[
            btn(Icons.chevron_left_rounded, 'Previous page', c.page > 1 ? c.prevPage : null),
            btn(Icons.chevron_right_rounded, 'Next page', c.page < c.pageCount ? c.nextPage : null),
          ],
          if (widget.pad) ...[
            btn(
              c.continuous ? Icons.view_day_outlined : Icons.auto_stories_outlined,
              c.continuous ? 'Read one page at a time' : 'Scroll continuously',
              () => c.setContinuous(!c.continuous),
            ),
            btn(
              Icons.draw_rounded,
              c.markup ? 'Finish marking up' : 'Mark up with Apple Pencil',
              () => c.setMarkup(enabled: !c.markup),
              on: c.markup,
            ),
          ],
        ],
      ),
    );
  }

  /// Pen, highlighter and eraser; the ink's color and thickness; undo, redo, clear. Shown while marking up.
  Widget _inkStrip(Tokens t) {
    Widget tool(IconData icon, String tip, InkTool which) => IconButton(
      key: Key('ink_${which.name}'),
      tooltip: tip,
      icon: Icon(icon, color: c.tool == which ? t.onAccent : t.ink2),
      style: c.tool == which ? IconButton.styleFrom(backgroundColor: t.accent) : null,
      onPressed: () => c.setTool(tool: which),
    );
    Widget action(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => IconButton(
      tooltip: tip,
      icon: Icon(icon, color: on ? t.onAccent : t.ink2),
      style: on ? IconButton.styleFrom(backgroundColor: t.accent) : null,
      onPressed: onTap,
    );
    final pen = c.tool == InkTool.pen;
    final colors = pen ? penColors : markerColors;
    final picked = pen ? c.penColor : c.markerColor;
    final thick = pen ? c.penWidth : c.markerWidth;
    final inking = c.tool != InkTool.eraser;
    return Container(
      key: const Key('inkStrip'),
      height: 52,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(bottom: BorderSide(color: t.rule)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            tool(Icons.edit_rounded, 'Pen', InkTool.pen),
            tool(Icons.border_color_rounded, 'Highlighter', InkTool.marker),
            tool(Icons.auto_fix_normal_rounded, 'Eraser', InkTool.eraser),
            if (inking) ...[
              const SizedBox(width: 6),
              for (final (i, col) in colors.indexed)
                GestureDetector(
                  key: Key('ink_color_$i'),
                  onTap: () => c.setTool(color: i),
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: col,
                        shape: BoxShape.circle,
                        border: Border.all(color: i == picked ? t.accent : t.rule, width: i == picked ? 3 : 1),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              for (var i = 0; i < 3; i++)
                GestureDetector(
                  key: Key('ink_width_$i'),
                  onTap: () => c.setTool(width: i),
                  child: Container(
                    width: 36,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: i == thick ? t.accentSoft : null, borderRadius: BorderRadius.circular(8)),
                    child: Container(
                      width: 6.0 + i * 5,
                      height: pen ? 2.0 + i * 2 : 5.0 + i * 3,
                      decoration: BoxDecoration(color: t.ink2, borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                ),
            ],
            const SizedBox(width: 10),
            SizedBox(height: 28, child: VerticalDivider(width: 1, color: t.rule)),
            action(Icons.undo_rounded, 'Undo', c.canUndo ? c.undo : null),
            action(Icons.redo_rounded, 'Redo', c.canRedo ? c.redo : null),
            action(Icons.layers_clear_rounded, 'Clear this page’s markup', _confirmClear),
            action(
              Icons.touch_app_rounded,
              c.finger ? 'Draw with Pencil only' : 'Draw with a finger too',
              () => c.setMarkup(finger: !c.finger),
              on: c.finger,
            ),
          ],
        ),
      ),
    );
  }

  /// Clearing can be undone (Undo), so one tap is enough.
  void _confirmClear() {
    c.clearPage();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Cleared this page’s markup'),
        action: SnackBarAction(label: 'Undo', onPressed: c.undo),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// The script's search is running: how many times the PDF has the same words, with its own previous / next.
  Widget _linkedStrip(Tokens t) => Container(
    key: const Key('pdfLinkedSearch'),
    height: 40,
    padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
    decoration: BoxDecoration(
      color: t.panel,
      border: Border(bottom: BorderSide(color: t.rule)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            c.searchCount == 0 ? 'Not in the PDF' : '${c.searchIndex} of ${c.searchCount} in the PDF',
            style: TextStyles.ui(t, size: 13, color: t.muted),
          ),
        ),
        IconButton(
          tooltip: 'Previous in the PDF',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
          onPressed: c.searchCount == 0 ? null : () => c.searchStep(false),
        ),
        IconButton(
          tooltip: 'Next in the PDF',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: c.searchCount == 0 ? null : () => c.searchStep(true),
        ),
      ],
    ),
  );

  Widget _searchBar(Tokens t) => Container(
    height: 52,
    padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
    decoration: BoxDecoration(
      color: t.bg,
      border: Border(bottom: BorderSide(color: t.rule)),
    ),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('pdfSearchField'),
            controller: _query,
            focusNode: _queryFocus,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(hintText: 'Search the PDF', border: InputBorder.none, isDense: true),
            onChanged: _search,
            onSubmitted: (_) => c.searchStep(true),
          ),
        ),
        if (_query.text.isNotEmpty)
          Text(c.searchCount == 0 ? 'No matches' : '${c.searchIndex} of ${c.searchCount}', style: TextStyles.ui(t, size: 13, color: t.muted)),
        IconButton(
          tooltip: 'Previous match',
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
          onPressed: c.searchCount == 0 ? null : () => c.searchStep(false),
        ),
        IconButton(
          tooltip: 'Next match',
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: c.searchCount == 0 ? null : () => c.searchStep(true),
        ),
        TextButton(onPressed: _closeSearch, child: const Text('Done')),
      ],
    ),
  );
}
