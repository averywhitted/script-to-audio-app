// A thin outline of the script on the left edge, a third of the way down: one dash per scene, the scene you are in
// longer and in the accent color, so you can see where you are without opening anything. Tap it and it opens into the
// scene headings; hold and drag along it to run through the script. It folds itself away when you scroll or tap elsewhere.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'rehearsal_session.dart';

class OutlineRail extends StatefulWidget {
  const OutlineRail({
    super.key,
    required this.scenes,
    required this.current,
    required this.onPick,
    required this.onScrub,
    this.bookmarked = const {},
  });

  final List<PhoneScene> scenes;

  /// The scene number being read (scrolled to), as it changes.
  final ValueListenable<int?> current;

  /// A heading was tapped in the open outline.
  final ValueChanged<int> onPick;

  /// The rail is being dragged: the scene under the finger.
  final ValueChanged<int> onScrub;

  /// Scene numbers holding a bookmark (a mark on their dash).
  final Set<int> bookmarked;

  @override
  State<OutlineRail> createState() => OutlineRailState();
}

class OutlineRailState extends State<OutlineRail> {
  bool _open = false;
  final _list = ScrollController();
  int? _scrubbing; // index under the finger while dragging

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
    return LayoutBuilder(
      builder: (context, box) => TapRegion(
        onTapOutside: (_) => collapse(),
        child: Align(
          // About a third of the way down.
          alignment: const Alignment(-1, -0.34),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            layoutBuilder: (current, previous) => Stack(alignment: const Alignment(-1, -0.34), children: [...previous, if (current != null) current]),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(anim), alignment: Alignment.centerLeft, child: child),
            ),
            child: _open ? _expanded(t, box.maxHeight * 0.62) : _dashes(t, box.maxHeight * 0.6),
          ),
        ),
      ),
    );
  }

  Widget _dashes(Tokens t, double room) {
    final n = widget.scenes.length;
    // Each scene gets an even slot; many scenes make the dashes tighter, never closer than 3 pt.
    final slot = (room / n).clamp(3.0, 11.0);
    final height = slot * n;
    int indexAt(double dy) => (dy / slot).floor().clamp(0, n - 1);
    return Semantics(
      key: const ValueKey('dashes'),
      button: true,
      label: 'Script outline',
      child: GestureDetector(
        key: const Key('outlineRail'),
        behavior: HitTestBehavior.opaque,
        onTap: _expand,
        onVerticalDragStart: (d) {
          setState(() => _scrubbing = indexAt(d.localPosition.dy));
          widget.onScrub(widget.scenes[_scrubbing!].number);
        },
        onVerticalDragUpdate: (d) {
          final i = indexAt(d.localPosition.dy);
          if (i != _scrubbing) {
            setState(() => _scrubbing = i);
            widget.onScrub(widget.scenes[i].number);
          }
        },
        onVerticalDragEnd: (_) => setState(() => _scrubbing = null),
        onVerticalDragCancel: () => setState(() => _scrubbing = null),
        child: SizedBox(
          width: 30,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ValueListenableBuilder<int?>(
                  valueListenable: widget.current,
                  builder: (context, now, _) {
                    final target = widget.scenes.indexWhere((s) => s.number == now).clamp(0, n - 1);
                    // The long dash slides from one scene to the next.
                    return TweenAnimationBuilder<double>(
                      tween: Tween(end: target.toDouble()),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      builder: (context, pos, _) => CustomPaint(
                        painter: _DashPainter(
                          numbers: [for (final s in widget.scenes) s.number],
                          pos: pos,
                          bookmarked: widget.bookmarked,
                          idle: t.muted.withValues(alpha: 0.55),
                          here: t.accent,
                          mark: t.highlighterEdge,
                        ),
                      ),
                    );
                  },
                ),
              ),
              // While dragging: which scene the script is at.
              if (_scrubbing != null)
                Positioned(
                  left: 36,
                  top: (slot * _scrubbing! + slot / 2 - 16).clamp(-40.0, height),
                  child: IgnorePointer(
                    child: Material(
                      color: t.sheet,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 240),
                          child: Text(
                            '${widget.scenes[_scrubbing!].number.toString().padLeft(2, '0')}  ${widget.scenes[_scrubbing!].title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyles.ui(t, size: 13, weight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _expanded(Tokens t, double maxHeight) => Padding(
    key: const ValueKey('open'),
    padding: const EdgeInsets.only(left: 8),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 300, maxHeight: maxHeight),
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
  );
}

class _DashPainter extends CustomPainter {
  _DashPainter({required this.numbers, required this.pos, required this.bookmarked, required this.idle, required this.here, required this.mark});
  final List<int> numbers;

  /// The current scene's place (fractional while the long dash slides).
  final double pos;
  final Set<int> bookmarked;
  final Color idle, here, mark;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.height / numbers.length;
    for (final (i, n) in numbers.indexed) {
      final y = slot * i + slot / 2;
      final near = (1 - (i - pos).abs()).clamp(0.0, 1.0); // 1 on the current dash, fading over a neighbour
      final w = 9 + 10 * near;
      final thick = (slot >= 6 ? 2.0 : 1.5) + 1.5 * near;
      final base = bookmarked.contains(n) ? mark : idle;
      final p = Paint()
        ..color = Color.lerp(base, here, near)!
        ..strokeWidth = thick
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(5, y), Offset(5 + w, y), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter o) =>
      o.pos != pos || o.bookmarked != bookmarked || o.numbers.length != numbers.length || o.idle != idle || o.here != here;
}
