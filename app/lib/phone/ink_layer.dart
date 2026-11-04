// Apple Pencil markup (#119), drawn by Flutter over the PDF page. The PDF shows one page fitted to the screen
// (ios/Runner/PdfPlugin.swift says where it is); strokes are kept in page coordinates (0-1 across and down the page),
// so they stay on the same words at any screen size, and saved as JSON per page.

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'pdf_view.dart';

class InkStroke {
  InkStroke({required this.marker, required this.color, required this.width, required this.points});

  /// Highlighter (see-through, wide) or pen.
  final bool marker;
  final int color;

  /// As a fraction of the page's width.
  final double width;

  /// Page coordinates, 0-1.
  final List<Offset> points;

  Map<String, dynamic> toJson() => {
    'm': marker ? 1 : 0,
    'c': color,
    'w': double.parse(width.toStringAsFixed(5)),
    'p': [
      for (final p in points) ...[double.parse(p.dx.toStringAsFixed(4)), double.parse(p.dy.toStringAsFixed(4))],
    ],
  };

  factory InkStroke.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List).cast<num>();
    return InkStroke(
      marker: j['m'] == 1,
      color: j['c'] as int,
      width: (j['w'] as num).toDouble(),
      points: [for (var i = 0; i + 1 < p.length; i += 2) Offset(p[i].toDouble(), p[i + 1].toDouble())],
    );
  }
}

String encodeInk(List<InkStroke> strokes) => strokes.isEmpty
    ? ''
    : jsonEncode({
        'v': 2,
        's': [for (final s in strokes) s.toJson()],
      });

List<InkStroke> decodeInk(String data) {
  if (data.isEmpty) return [];
  try {
    final j = jsonDecode(data) as Map;
    return [for (final s in j['s'] as List) InkStroke.fromJson(Map<String, dynamic>.from(s as Map))];
  } catch (_) {
    return []; // not ours (an older format): nothing to show
  }
}

/// Does a point lie on [s] (within [slop], in page units)? For the eraser.
bool strokeNear(InkStroke s, Offset p, double slop) {
  for (var i = 0; i < s.points.length; i++) {
    if ((s.points[i] - p).distance <= slop + s.width / 2) return true;
    if (i > 0) {
      final a = s.points[i - 1], b = s.points[i];
      final ab = b - a, len2 = ab.dx * ab.dx + ab.dy * ab.dy;
      if (len2 == 0) continue;
      final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
      if ((a + ab * t - p).distance <= slop + s.width / 2) return true;
    }
  }
  return false;
}

class _InkPainter extends CustomPainter {
  _InkPainter(this.strokes, this.rect, this.revision) : super();
  final List<InkStroke> strokes;
  final Rect rect;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(rect);
    for (final s in strokes) {
      if (s.points.isEmpty) continue;
      final paint = Paint()
        ..color = Color(s.color).withValues(alpha: s.marker ? 0.38 : 1)
        ..style = PaintingStyle.stroke
        ..strokeCap = s.marker ? StrokeCap.butt : StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = s.width * rect.width;
      Offset at(Offset p) => Offset(rect.left + p.dx * rect.width, rect.top + p.dy * rect.height);
      if (s.points.length == 1) {
        canvas.drawCircle(at(s.points.first), s.width * rect.width / 2, paint..style = PaintingStyle.fill);
        continue;
      }
      final path = Path()..moveTo(at(s.points.first).dx, at(s.points.first).dy);
      for (var i = 1; i < s.points.length - 1; i++) {
        final m = (at(s.points[i]) + at(s.points[i + 1])) / 2;
        path.quadraticBezierTo(at(s.points[i]).dx, at(s.points[i]).dy, m.dx, m.dy);
      }
      path.lineTo(at(s.points.last).dx, at(s.points.last).dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_InkPainter old) => true;
}

/// The page's ink, and (while marking up) the Pencil's strokes. Fingers turn the page with a swipe, or draw when
/// "draw with a finger too" is on.
class InkOverlay extends StatefulWidget {
  const InkOverlay({super.key, required this.controller});
  final PdfController controller;

  @override
  State<InkOverlay> createState() => _InkOverlayState();
}

class _InkOverlayState extends State<InkOverlay> {
  PdfController get c => widget.controller;
  int? _pointer;
  bool _erasing = false;
  InkStroke? _stroke;
  // A finger that is not drawing: where it started, to see if it was a page-turning swipe.
  int? _swipePointer;
  Offset _swipeFrom = Offset.zero;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Offset? _toPage(Offset local) {
    final r = c.pageRect;
    if (r == null || !r.inflate(4).contains(local)) return null;
    return Offset(((local.dx - r.left) / r.width).clamp(0.0, 1.0), ((local.dy - r.top) / r.height).clamp(0.0, 1.0));
  }

  bool _draws(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus ||
      (c.finger && (e.kind == PointerDeviceKind.touch)) ||
      e.kind == PointerDeviceKind.mouse; // a mouse or trackpad, for the simulator

  void _down(PointerDownEvent e) {
    if (c.markup && _draws(e)) {
      if (_pointer != null) return;
      final p = _toPage(e.localPosition);
      if (p == null) return;
      _pointer = e.pointer;
      _erasing = e.kind == PointerDeviceKind.invertedStylus || c.tool == InkTool.eraser;
      if (_erasing) {
        c.beginEdit();
        c.eraseAt(p);
      } else {
        final w = c.currentWidth / c.pageWidth;
        _stroke = InkStroke(marker: c.tool == InkTool.marker, color: c.currentColor.toARGB32(), width: w, points: [p]);
        c.liveStroke = _stroke;
      }
      setState(() {});
    } else if (e.kind == PointerDeviceKind.touch && _swipePointer == null) {
      _swipePointer = e.pointer;
      _swipeFrom = e.localPosition;
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final p = _toPage(e.localPosition);
    if (p == null) return;
    if (_erasing) {
      c.eraseAt(p);
    } else {
      _stroke?.points.add(p);
      c.notifyInk();
    }
  }

  void _up(PointerEvent e) {
    if (e.pointer == _swipePointer) {
      _swipePointer = null;
      final d = e.localPosition - _swipeFrom;
      if (e is PointerUpEvent && d.dx.abs() > 60 && d.dx.abs() > d.dy.abs() * 1.5) d.dx < 0 ? c.nextPage() : c.prevPage();
    }
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_erasing) {
      c.endEdit();
    } else if (_stroke != null) {
      c.liveStroke = null;
      if (e is PointerUpEvent) c.commitStroke(_stroke!);
      _stroke = null;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final r = c.pageRect;
    if (c.continuous || r == null) return const SizedBox.shrink();
    final strokes = [...c.strokesOnPage, if (c.liveStroke != null) c.liveStroke!];
    return Listener(
      behavior: c.markup ? HitTestBehavior.opaque : HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: IgnorePointer(
        child: CustomPaint(key: const Key('inkCanvas'), size: Size.infinite, painter: _InkPainter(strokes, r, c.inkRevision)),
      ),
    );
  }
}
