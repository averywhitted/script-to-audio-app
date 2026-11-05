// The lock-screen / headphone connector (lib/phone/now_playing.dart) against
// a stand-in for the native side.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_read/models/models.dart';
import 'package:table_read/phone/now_playing.dart';
import 'package:table_read/state/player_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final sent = <MethodCall>[];

  Future<void> press(String name, [Map<String, Object?> extra = const {}]) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('command', {'name': name, ...extra}));
    await messenger.handlePlatformMessage('tableread/nowplaying', data, (_) {});
  }

  Future<(RehearsalPlayer, NowPlaying)> setUpPlayer() async {
    sent.clear();
    messenger.setMockMethodCallHandler(NowPlaying.channel, (call) async {
      sent.add(call);
      return null;
    });
    SceneCue cue(int i, String who, double a, double b) =>
        SceneCue(index: i, kind: 'dialog', speaker: who, text: 'Line $i', startTime: a, endTime: b);
    final p = RehearsalPlayer(audioEnabled: false);
    p.loadItems([
      ScenePlayerItem(1, 'Morning-room', '/none.m4a', [cue(0, 'LANE', 0, 2), cue(1, 'ALGERNON', 2.5, 5), cue(2, 'LANE', 5.5, 7)], 7),
    ]);
    await Future<void>.delayed(Duration.zero);
    p.tickForTest(0.1);
    final np = NowPlaying(p, projectName: 'Earnest')..attach();
    return (p, np);
  }

  test('tells iOS the scene, project and whether it is playing', () async {
    final (p, np) = await setUpPlayer();
    expect(sent.last.method, 'update');
    expect((sent.last.arguments as Map)['title'], 'Morning-room');
    expect((sent.last.arguments as Map)['artist'], 'Earnest');
    expect((sent.last.arguments as Map)['playing'], false);
    p.play();
    expect((sent.last.arguments as Map)['playing'], true);
    np.detach();
    expect(sent.last.method, 'clear');
  });

  test('an AirPods press carries on at my line (Stop Before My Lines)', () async {
    final (p, np) = await setUpPlayer();
    p
      ..setRole('ALGERNON')
      ..setCueMode(true)
      ..play();
    p.tickForTest(2.5);
    expect(p.waitingAtCue, 1);
    expect((sent.last.arguments as Map)['artist'], startsWith('Your line'));
    await press('toggle');
    expect(p.waitingAtCue, isNull);
    expect(p.isPlaying, isTrue);
    expect(p.currentTime, 5.0);
    np.detach();
  });

  test('lock-screen pause, next line and seek', () async {
    final (p, np) = await setUpPlayer();
    p.play();
    await press('pause');
    expect(p.isPlaying, isFalse);
    await press('next');
    expect(p.currentCueIndex, 1);
    await press('seek', {'position': 6.0});
    expect(p.currentTime, 6.0);
    np.detach();
  });
}
