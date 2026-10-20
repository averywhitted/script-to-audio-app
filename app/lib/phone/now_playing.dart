// Lock screen, Control Center and headphone controls for the iPhone (#92).
// Tells iOS what's playing (ios/Runner/AppDelegate.swift, NowPlayingPlugin)
// and turns its buttons into player actions. An AirPods press is "toggle":
// while Stop Before My Lines waits at your line, that carries on, so you can
// run lines hands-free. Double press = next line, triple press = previous.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/player_state.dart';

class NowPlaying {
  NowPlaying(this.player, {required this.projectName});

  final RehearsalPlayer player;
  final String projectName;

  static const channel = MethodChannel('tableread/nowplaying');

  String? _sent;
  double _sentPosition = 0;
  DateTime _sentAt = DateTime.fromMillisecondsSinceEpoch(0);

  void attach() {
    channel.setMethodCallHandler(_onCall);
    player.addListener(_changed);
    _changed();
  }

  void detach() {
    player.removeListener(_changed);
    channel.setMethodCallHandler(null);
    channel.invokeMethod('clear').catchError((_) {});
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'command') return;
    final args = Map<String, dynamic>.from((call.arguments as Map?) ?? const {});
    switch (args['name']) {
      case 'play':
        if (!player.isPlaying) player.play();
      case 'pause':
        if (player.isPlaying) player.pause();
      case 'toggle':
        player.togglePlayPause();
      case 'next':
        player.nextLine();
      case 'previous':
        player.prevLine();
      case 'seek':
        player.seek((args['position'] as num?)?.toDouble() ?? player.currentTime);
    }
  }

  /// What iOS shows. Sent when it changes, or when the position has drifted
  /// from where iOS thinks it is (it counts forward on its own while playing).
  @visibleForTesting
  Map<String, Object?> info() {
    final scene = player.currentScene;
    final waiting = player.waitingAtCue != null;
    return {
      'title': scene == null ? projectName : scene.sceneTitle,
      'artist': waiting ? 'Your line · press play to carry on' : projectName,
      'album': scene == null ? '' : 'Scene ${scene.sceneNumber}',
      'duration': player.duration,
      'position': player.currentTime,
      'rate': player.playbackRate,
      'playing': player.isPlaying,
    };
  }

  void _changed() {
    if (player.currentScene == null) return;
    final i = info();
    final key = [i['title'], i['artist'], i['album'], i['duration'], i['rate'], i['playing']].join('|');
    final elapsed = DateTime.now().difference(_sentAt).inMilliseconds / 1000;
    final expected = _sentPosition + (player.isPlaying ? elapsed * player.playbackRate : 0);
    if (key == _sent && (player.currentTime - expected).abs() < 1.0) return;
    _sent = key;
    _sentPosition = player.currentTime;
    _sentAt = DateTime.now();
    channel.invokeMethod('update', i).catchError((_) {});
  }
}
