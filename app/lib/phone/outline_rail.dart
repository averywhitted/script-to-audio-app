// A thin outline of the script along the edge: one dash per scene, the scene you
// are in longer and in the accent color, so you can see where you are without
// opening anything. Tap it and it opens into the scene headings; it folds itself
// away when you scroll or tap elsewhere.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'rehearsal_session.dart';

class OutlineRail extends StatefulWidget {
  const OutlineRail({super.key, required this.scenes, required this.current, required this.onPick, this.bookmarked = const {}});

  final List<PhoneScene> scenes;

  /// The scene number being read (scrolled to), as it changes.
  final ValueListenable<int?> current;
  final ValueChanged<int> onPick;

  /// Scene numbers holding a bookmark (a small tick on their dash).
  final Set<int> bookmarked;

  @override
  State<OutlineRail> createState() => OutlineRailState();
}

class OutlineRailState extends State<OutlineRail> {
  bool _open = false;
  final _list = ScrollController();

  bool get isOpen => _open;

  /// Folds the outline back to dashes (the script was scrolled).
  void collapse() {
    if (_open) setState(() => _open = false);
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  void _expand() {
    setState(() => _open = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final i = widget.scenes.indexWhere((s) => s.number == widget.current.value);
      if (i > 3 && _list.hasClients) _list.jumpTo(((i - 3) * 44.0).clamp(0.0, _list.position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return TapRegion(onTapOutside: (_) => collapse(), child: _open ? _expanded(t) : _dashes(t));
  }

  Widget _dashes(Tokens t) => LayoutBuilder(
    builder: (context, box) {
      final n = widget.scenes.length;
      // Each scene gets an even slot; many scenes make the dashes tighter, never smaller than a pixel apart.
      final slot = (box.maxHeight / n).clamp(3.0, 11.0);
      final height = slot * n;
      return Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          button: true,
          label: 'Script outline',
          child: GestureDetector(
            key: const Key('outlineRail'),
            behavior: HitTestBehavior.opaque,
            onTap: _expand,
            child: SizedBox(
              width: 26,
              height: height.clamp(0.0, box.maxHeight),
              child: ValueListenableBuilder<int?>(
                valueListenable: widget.current,
                builder: (context, now, _) => CustomPaint(
                  painter: _DashPainter(
                    numbers: [for (final s in widget.scenes) s.number],
                    now: now,
                    bookmarked: widget.bookmarked,
                    idle: t.muted.withValues(alpha: 0.55),
                    here: t.accent,
                    mark: t.highlighterEdge,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _expanded(Tokens t) => Align(
    alignment: Alignment.centerRight,
    child: Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Material(
          key: const Key('outlineOpen'),
          color: t.sheet,
          elevation: 8,
          shadowColor: Colors.black45,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: ValueListenableBuilder<int?>(
            valueListenable: widget.current,
            builder: (context, now, _) => ListView.builder(
              controller: _list,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: widget.scenes.length,
              itemBuilder: (context, i) {
                final s = widget.scenes[i];
                final here = s.number == now;
                return InkWell(
                  onTap: () {
                    collapse();
                    widget.onPick(s.number);
                  },
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 44),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    color: here ? t.accentSoft : null,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 26,
                          child: Text(
                            s.number.toString().padLeft(2, '0'),
                            style: TextStyles.script(t, size: 12, weight: FontWeight.w700, color: here ? t.accent : t.muted),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            s.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyles.ui(t, size: 14, weight: here ? FontWeight.w700 : FontWeight.w500),
                          ),
                        ),
                        if (widget.bookmarked.contains(s.number)) Icon(Icons.bookmark_rounded, size: 16, color: t.highlighterEdge),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

class _DashPainter extends CustomPainter {
  _DashPainter({required this.numbers, required this.now, required this.bookmarked, required this.idle, required this.here, required this.mark});
  final List<int> numbers;
  final int? now;
  final Set<int> bookmarked;
  final Color idle, here, mark;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.height / numbers.length;
    for (final (i, n) in numbers.indexed) {
      final y = slot * i + slot / 2;
      final isHere = n == now;
      final w = isHere ? 18.0 : 9.0;
      final thick = isHere ? 3.0 : (slot >= 6 ? 2.0 : 1.5);
      final p = Paint()
        ..color = isHere ? here : (bookmarked.contains(n) ? mark : idle)
        ..strokeWidth = thick
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(size.width - 4 - w, y), Offset(size.width - 4, y), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter o) =>
      o.now != now || o.bookmarked != bookmarked || o.numbers.length != numbers.length || o.idle != idle || o.here != here;
}
