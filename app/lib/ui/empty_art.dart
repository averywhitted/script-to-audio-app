// Empty-state illustrations: simple line art drawn in code, one yellow
// highlighter accent each. The design called for these but left them as placeholders.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum EmptyArt { table, box, stage, titlePage, promptBook, chair, pages }

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.art, required this.title, this.message, this.action, this.compact = false});
  final EmptyArt art;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: compact ? 120 : 180,
              height: compact ? 84 : 120,
              child: CustomPaint(painter: _ArtPainter(art, t)),
            ),
            SizedBox(height: compact ? 12 : 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyles.ui(t, size: compact ? 14 : 16, weight: FontWeight.w700),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyles.ui(t, color: t.muted, height: 1.45),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class EmptyArtView extends StatelessWidget {
  const EmptyArtView(this.art, {super.key, this.width = 180, this.height = 120});
  final EmptyArt art;
  final double width, height;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: CustomPaint(painter: _ArtPainter(art, Tokens.of(context))),
  );
}

class _ArtPainter extends CustomPainter {
  _ArtPainter(this.art, this.t);
  final EmptyArt art;
  final Tokens t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 180, size.height / 120);
    final line = Paint()
      ..color = t.muted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = t.sheet;
    final hl = Paint()
      ..color = const Color(0xFFFFFB85).withValues(alpha: t.dark ? 0.55 : 0.95)
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    final faint = Paint()
      ..color = t.border
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    void rrect(Rect r, double rad) {
      final rr = RRect.fromRectAndRadius(r, Radius.circular(rad));
      canvas.drawRRect(rr, fill);
      canvas.drawRRect(rr, line);
    }

    switch (art) {
      case EmptyArt.table:
        // Empty read-through table with four chairs and a highlighted script.
        canvas.drawLine(const Offset(46, 52), const Offset(96, 52), hl);
        rrect(const Rect.fromLTWH(30, 44, 120, 26), 6);
        canvas.drawLine(const Offset(48, 70), const Offset(44, 104), line);
        canvas.drawLine(const Offset(132, 70), const Offset(136, 104), line);
        for (final x in [22.0, 158.0]) {
          rrect(Rect.fromLTWH(x - 10, 60, 20, 22), 4);
          canvas.drawLine(Offset(x - 6, 82), Offset(x - 6, 100), line);
          canvas.drawLine(Offset(x + 6, 82), Offset(x + 6, 100), line);
        }
        for (final x in [70.0, 110.0]) {
          rrect(Rect.fromLTWH(x - 10, 16, 20, 20), 4);
        }
        canvas.drawLine(const Offset(106, 57), const Offset(130, 57), faint);
      case EmptyArt.box:
        // Closed storage box with a label.
        rrect(const Rect.fromLTWH(40, 40, 100, 64), 6);
        rrect(const Rect.fromLTWH(34, 28, 112, 18), 5);
        canvas.drawLine(const Offset(74, 70), const Offset(106, 70), hl);
        rrect(const Rect.fromLTWH(70, 62, 40, 16), 3);
      case EmptyArt.stage:
        // Dark stage with headphones in a spotlight.
        final dark = Paint()..color = t.dark ? const Color(0xFF0E0E0D) : const Color(0xFF2A2825);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(20, 14, 140, 92), const Radius.circular(8)), dark);
        final spot = Paint()..color = const Color(0xFFFFFB85).withValues(alpha: 0.22);
        canvas.drawPath(
          Path()
            ..moveTo(78, 14)
            ..lineTo(102, 14)
            ..lineTo(128, 96)
            ..lineTo(52, 96)
            ..close(),
          spot,
        );
        final light = Paint()
          ..color = const Color(0xFFEFEDE8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(const Rect.fromLTWH(72, 52, 36, 36), math.pi, math.pi, false, light);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(68, 68, 9, 16), const Radius.circular(3)), Paint()..color = const Color(0xFFEFEDE8));
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(103, 68, 9, 16), const Radius.circular(3)), Paint()..color = const Color(0xFFEFEDE8));
        canvas.drawLine(
          const Offset(28, 96),
          const Offset(152, 96),
          Paint()
            ..color = const Color(0xFF6B6760)
            ..strokeWidth = 2,
        );
      case EmptyArt.titlePage:
        // Blank title page held by two brads.
        rrect(const Rect.fromLTWH(56, 8, 68, 100), 3);
        canvas.drawLine(const Offset(74, 46), const Offset(106, 46), hl);
        canvas.drawLine(const Offset(78, 58), const Offset(102, 58), faint);
        final brass = Paint()..color = const Color(0xFFA9853C);
        canvas.drawCircle(const Offset(64, 22), 3, brass);
        canvas.drawCircle(const Offset(64, 94), 3, brass);
      case EmptyArt.promptBook:
        // Open prompt book with empty ruled pages.
        rrect(const Rect.fromLTWH(26, 24, 64, 80), 4);
        rrect(const Rect.fromLTWH(90, 24, 64, 80), 4);
        canvas.drawLine(const Offset(38, 44), const Offset(70, 44), hl);
        for (final y in [58.0, 70.0, 82.0]) {
          canvas.drawLine(Offset(38, y), Offset(78, y), faint);
          canvas.drawLine(Offset(102, y), Offset(142, y), faint);
        }
      case EmptyArt.chair:
        // An empty chair waiting for a voice.
        rrect(const Rect.fromLTWH(64, 18, 52, 48), 8);
        rrect(const Rect.fromLTWH(58, 62, 64, 14), 4);
        canvas.drawLine(const Offset(64, 76), const Offset(60, 106), line);
        canvas.drawLine(const Offset(116, 76), const Offset(120, 106), line);
        canvas.drawLine(const Offset(76, 36), const Offset(104, 36), hl);
      case EmptyArt.pages:
        // Pages being read, a pencil moving across them.
        rrect(const Rect.fromLTWH(40, 22, 70, 86), 3);
        rrect(const Rect.fromLTWH(54, 14, 70, 86), 3);
        canvas.drawLine(const Offset(66, 36), const Offset(104, 36), hl);
        for (final y in [50.0, 62.0, 74.0]) {
          canvas.drawLine(Offset(66, y), Offset(110, y), faint);
        }
        final pencil = Paint()..color = t.accent;
        canvas.save();
        canvas.translate(128, 66);
        canvas.rotate(-0.8);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-4, -28, 8, 40), const Radius.circular(2)), pencil);
        canvas.drawPath(
          Path()
            ..moveTo(-4, 12)
            ..lineTo(4, 12)
            ..lineTo(0, 20)
            ..close(),
          Paint()..color = t.muted,
        );
        canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ArtPainter old) => old.art != art || old.t.dark != t.dark;
}
