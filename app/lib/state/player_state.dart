// Rehearsal player. Port of Sources/TableRead/PlayerState.swift.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/models.dart';
import 'app_state.dart';

class ScenePlayerItem {
  ScenePlayerItem(this.sceneNumber, this.sceneTitle, this.audioPath, this.cues);
  final int sceneNumber;
  final String sceneTitle;
  final String audioPath;
  final List<SceneCue> cues;
}

class RehearsalPlayer extends ChangeNotifier {
  RehearsalPlayer({this.audioEnabled = true});

  /// Off in screen tests, where the audio plugin doesn't exist.
  final bool audioEnabled;

  AudioPlayer? _p;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription? _stateSub;

  /// Created on first use, so screens can be built without the audio plugin.
  AudioPlayer get _player {
    final existing = _p;
    if (existing != null) return existing;
    final p = AudioPlayer();
    _p = p;
    _posSub = p.positionStream.listen(_tick);
    _stateSub = p.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && isPlaying) {
        if (currentSceneIndex + 1 < scenes.length) {
          switchToScene(currentSceneIndex + 1, autoPlay: true);
        } else {
          pause();
          _player.seek(Duration.zero);
        }
      }
    });
    return p;
  }

  List<ScenePlayerItem> scenes = [];
  int currentSceneIndex = 0;
  List<SceneCue> cues = [];
  bool isPlaying = false;
  double currentTime = 0;
  int currentCueIndex = -1;
  String myRole = '';
  bool muteMyLines = false;
  bool blockMyLines = false;
  double playbackRate = 1.0;

  ScenePlayerItem? get currentScene => currentSceneIndex >= 0 && currentSceneIndex < scenes.length ? scenes[currentSceneIndex] : null;

  SceneCue? get currentCue => currentCueIndex >= 0 && currentCueIndex < cues.length ? cues[currentCueIndex] : null;

  void load(AppState app) {
    final pdf = app.pdfPath;
    if (pdf == null) {
      scenes = [];
      notifyListeners();
      return;
    }
    final out = app.outputDirectory ?? app.defaultOutputDirectory(pdf);
    final items = <ScenePlayerItem>[];
    final keys = app.sceneFileInfo.keys.toList()..sort();
    for (final n in keys) {
      final info = app.sceneFileInfo[n]!;
      if (!info.exists) continue;
      items.add(ScenePlayerItem(n, info.title, '$out/${info.filename}', _loadCues(app.sceneCueFiles[n])));
    }
    final currentNumber = currentScene?.sceneNumber;
    final hadScenes = scenes.isNotEmpty;
    scenes = items;
    if (scenes.isEmpty) {
      notifyListeners();
      return;
    }
    final idx = currentNumber == null ? -1 : scenes.indexWhere((s) => s.sceneNumber == currentNumber);
    if (!hadScenes || idx < 0) {
      switchToScene(0);
    } else {
      currentSceneIndex = idx;
      if (cues.isEmpty) cues = scenes[idx].cues;
      notifyListeners();
    }
  }

  static List<SceneCue> _loadCues(String? path) {
    if (path == null) return const [];
    try {
      final j = jsonDecode(File(path).readAsStringSync()) as Map;
      return ((j['cues'] as List?) ?? const []).map((e) => SceneCue.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> switchToScene(int index, {bool autoPlay = false}) async {
    if (index < 0 || index >= scenes.length) return;
    final wasPlaying = isPlaying;
    if (audioEnabled) await _player.pause();
    currentSceneIndex = index;
    currentCueIndex = -1;
    currentTime = 0;
    cues = scenes[index].cues;
    notifyListeners();
    if (!audioEnabled) return;
    try {
      await _player.setFilePath(scenes[index].audioPath);
      await _player.setSpeed(playbackRate);
    } catch (_) {}
    if (wasPlaying || autoPlay) play();
  }

  @visibleForTesting
  void refreshForTest() => notifyListeners();

  void togglePlayPause() => isPlaying ? pause() : play();

  void play() {
    if (scenes.isEmpty) return;
    isPlaying = true;
    if (audioEnabled) _player.play();
    notifyListeners();
  }

  void pause() {
    isPlaying = false;
    if (audioEnabled) {
      _player.pause();
      _player.setVolume(1);
    }
    notifyListeners();
  }

  void setRate(double r) {
    final snapped = (r * 20).round() / 20;
    playbackRate = snapped.clamp(0.5, 2.0);
    if (audioEnabled) _player.setSpeed(playbackRate);
    notifyListeners();
  }

  void stepRate(double delta) => setRate(playbackRate + delta);

  void setRole(String role) {
    myRole = role;
    if (role.isEmpty) {
      muteMyLines = false;
      blockMyLines = false;
    }
    notifyListeners();
  }

  void setMute(bool v) {
    muteMyLines = v;
    notifyListeners();
  }

  void setBlock(bool v) {
    blockMyLines = v;
    notifyListeners();
  }

  void nextLine() {
    final next = currentCueIndex + 1;
    if (next < cues.length) _seek(cues[next].startTime);
  }

  void prevLine() {
    if (cues.isEmpty) return;
    if (currentCueIndex > 0) {
      final cue = cues[currentCueIndex];
      _seek(currentTime - cue.startTime > 1.5 ? cue.startTime : cues[currentCueIndex - 1].startTime);
    } else {
      _seek(0);
    }
  }

  void nextScene() {
    if (currentSceneIndex + 1 < scenes.length) switchToScene(currentSceneIndex + 1, autoPlay: isPlaying);
  }

  void prevScene() {
    if (currentSceneIndex > 0) {
      switchToScene(currentSceneIndex - 1, autoPlay: isPlaying);
    } else {
      _seek(0);
    }
  }

  void _seek(double t) {
    if (audioEnabled) _player.seek(Duration(milliseconds: (t * 1000).round()));
    currentTime = t;
    _updateCue();
    notifyListeners();
  }

  bool isMyLine(String speaker) => myRole.isNotEmpty && speaker.split('/').contains(myRole);

  void _tick(Duration pos) {
    currentTime = pos.inMilliseconds / 1000;
    final before = currentCueIndex;
    _updateCue();
    // Mute my lines: silence during my cues (looking one tick ahead) so the
    // gap stays the length of the line.
    var muted = false;
    if (muteMyLines && myRole.isNotEmpty) {
      final c = currentCue;
      if (c != null && isMyLine(c.speaker) && currentTime >= c.startTime && currentTime < c.endTime) muted = true;
      final ni = currentCueIndex + 1;
      if (ni >= 0 && ni < cues.length && isMyLine(cues[ni].speaker) && cues[ni].startTime - currentTime <= 0.06) muted = true;
    }
    _player.setVolume(muted ? 0 : 1);
    if (before != currentCueIndex) notifyListeners();
  }

  void _updateCue() {
    if (cues.isEmpty) {
      currentCueIndex = -1;
      return;
    }
    var lo = 0, hi = cues.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final c = cues[mid];
      if (c.startTime <= currentTime && currentTime < c.endTime) {
        found = mid;
        break;
      } else if (c.endTime <= currentTime) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (found == -1) found = cues.lastIndexWhere((c) => c.startTime <= currentTime);
    currentCueIndex = found;
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _p?.dispose();
    super.dispose();
  }
}
