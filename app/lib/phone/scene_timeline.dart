// The timeline above the transport on the phone: one scene's lines as coloured stretches with a playhead on them.
//
// It is not tied to the scene that is playing. Scrolling the script moves the playhead to where you are on the page, and
// crossing into another scene swaps in that scene's timeline (see rehearsal_screen.dart); dragging the playhead scrolls
// the script. It only tells the screen what was touched: the screen decides what that means for the audio.

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/tokens.dart';

class PhoneTimeline extends StatefulWidget {
  const PhoneTimeline({
    super.key,
    required this.cues,
    required this.duration,
    required this.time,
    required this.allSpeakers,
    required this.isMine,
    this.loop,
    this.height = 36,
    this.knob = 11,
    this.onScrubStart,
    this.onScrub,
    this.onScrubEnd,
  });

  /// The lines of the scene shown (empty for a scene that was not rendered: the track is then bare).
  final List<SceneCue> cues;
  final double duration;

  /// Where the playhead is, in seconds.
  final double time;
  final List<String> allSpeakers;
  final bool Function(String speaker) isMine;

  /// A looped stretch to outline (seconds), when this is the scene being looped.
  final (double, double)? loop;
  final double height, knob;

  /// A finger went down on the timeline (a tap or the start of a drag).
  final VoidCallback? onScrubStart;

  /// The finger is at this time (seconds), tap or drag.
  final ValueChanged<double>? onScrub;

  /// The finger came up, at this time.
  final ValueChanged<double>? onScrubEnd;

  @override
  State<PhoneTimeline> createState() => _PhoneTimelineState();
}

class _PhoneTimelineState extends State<PhoneTimeline> {
  bool _down = false;
  double _last = 0;

  bool get _live => widget.duration > 0 && widget.onScrub != null;

  void _at(double x, double width) {
    _last = (x / width).clamp(0.0, 1.0) * widget.duration;
    widget.onScrub!(_last);
  }

  void _start(double x, double width) {
    if (!_live || _down) return;
    _down = true;
    widget.onScrubStart?.call();
    _at(x, width);
  }

  void _end() {
    if (!_down) return;
    _down = false;
    widget.onScrubEnd?.call(_last);
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return LayoutBuilder(
      // Raw pointer events: a tap and a drag are the same thing here, and a finger always ends it, however it lifts.
      builder: (context, c) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _start(e.localPosition.dx, c.maxWidth),
        onPointerMove: (e) {
          if (_down) _at(e.localPosition.dx, c.maxWidth);
        },
        onPointerUp: (_) => _end(),
        onPointerCancel: (_) => _end(),
        child: SizedBox(
          width: c.maxWidth,
          height: widget.height,
          child: CustomPaint(
            painter: _Painter(
              cues: widget.cues,
              duration: widget.duration,
              time: widget.time,
              allSpeakers: widget.allSpeakers,
              isMine: widget.isMine,
              loop: widget.loop,
              t: t,
              knob: widget.knob,
            ),
          ),
        ),
      ),
    );
  }
}

class _Painter extends CustomPainter {
  _Painter({
    required this.cues,
    required this.duration,
    required this.time,
    required this.allSpeakers,
    required this.isMine,
    required this.loop,
    required this.t,
    required this.knob,
  });
  final List<SceneCue> cues;
  final double duration, time, knob;
  final List<String> allSpeakers;
  final bool Function(String) isMine;
  final (double, double)? loop;
  final Tokens t;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 2) return;
    final mid = size.height / 2 + 4;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, mid - 3, size.width, 6), const Radius.circular(3)), Paint()..color = t.ctrl);
    final d = duration;
    if (d <= 0) return;
    for (final c in cues) {
      final x0 = c.startTime / d * size.width, x1 = c.endTime / d * size.width;
      final mine = isMine(c.speaker);
      final speaker = c.speaker == narratorKey ? 'Narrator' : c.speaker.split('/').first;
      final color = mine ? const Color(0xFFFFE94D) : speakerColors(speaker, allSpeakers, t, enabled: true).dot.withValues(alpha: 0.8);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x0, mid - 3, (x1 - x0 - 1) < 1 ? 1.0 : (x1 - x0 - 1), 6), const Radius.circular(2)),
        Paint()..color = color,
      );
    }
    final l = loop;
    if (l != null && l.$2 > l.$1) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(l.$1 / d * size.width, mid - 7, l.$2 / d * size.width, mid + 7), const Radius.circular(4)),
        Paint()
          ..color = t.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final x = (time / d).clamp(0.0, 1.0) * size.width;
    canvas.drawCircle(Offset(x, mid), knob, Paint()..color = t.knob);
    canvas.drawCircle(
      Offset(x, mid),
      knob,
      Paint()
        ..color = t.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_Painter o) =>
      o.cues != cues || o.duration != duration || o.time != time || o.loop != loop || o.t != t || o.knob != knob || o.allSpeakers != allSpeakers;
}
