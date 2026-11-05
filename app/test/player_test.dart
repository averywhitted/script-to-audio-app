// RehearsalPlayer rules that need position ticks (the audio plugin isn't
// there in tests, so ticks are fed by hand).

import 'package:flutter_test/flutter_test.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/state/player_state.dart';

/// LANE 0–2 s, ALGERNON 2.5–5 s, LANE 5.5–7 s, ALGERNON 7.5–10 s.
Future<RehearsalPlayer> _player() async {
  SceneCue cue(int i, String who, double a, double b) => SceneCue(index: i, kind: 'dialog', speaker: who, text: 'Line $i', startTime: a, endTime: b);
  final p = RehearsalPlayer(audioEnabled: false);
  p.loadItems([
    ScenePlayerItem(1, 'One', '/none.m4a', [
      cue(0, 'LANE', 0, 2),
      cue(1, 'ALGERNON', 2.5, 5),
      cue(2, 'LANE', 5.5, 7),
      cue(3, 'ALGERNON', 7.5, 10),
    ], 10),
  ]);
  await Future<void>.delayed(Duration.zero);
  p
    ..setRole('ALGERNON')
    ..setCueMode(true)
    ..tickForTest(0.1); // the position report that confirms loading the scene
  return p;
}

void main() {
  test('Stop Before My Lines waits at my line, and play carries on past it', () async {
    final p = await _player();
    p.play();
    p.tickForTest(1.0);
    expect(p.waitingAtCue, isNull);
    p.tickForTest(2.5);
    expect(p.waitingAtCue, 1);
    expect(p.isPlaying, isFalse);
    p.play();
    expect(p.waitingAtCue, isNull);
    expect(p.currentTime, 5.0);
    // The phone's seek lands a little early, still inside my line: keep going.
    p.tickForTest(4.8);
    expect(p.waitingAtCue, isNull);
    expect(p.isPlaying, isTrue);
    p.tickForTest(6.0);
    expect(p.waitingAtCue, isNull);
    // My next line still stops.
    p.tickForTest(7.5);
    expect(p.waitingAtCue, 3);
  });

  test('a seek elsewhere forgets the line already said', () async {
    final p = await _player();
    p.play();
    p.tickForTest(2.5);
    p.play();
    p.seek(2.0);
    p.play();
    p.tickForTest(2.1);
    p.tickForTest(2.5);
    expect(p.waitingAtCue, 1);
  });

  test('Line! shows my line; calling again hides it', () async {
    final p = await _player();
    p.play();
    p.tickForTest(2.5);
    p.callForLine();
    expect(p.revealedCue, 1);
    p.callForLine();
    expect(p.revealedCue, isNull);
    expect(p.waitingAtCue, 1, reason: 'still waiting for me to say it');
  });
}
