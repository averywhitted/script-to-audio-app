// Rehearsal player (the playback bar). Started as a port of
// Sources/TableRead/PlayerState.swift; adds play-from-line, cue mode, loops,
// seeking and the scene timeline.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/models.dart';
import 'app_state.dart';

class ScenePlayerItem {
  ScenePlayerItem(this.sceneNumber, this.sceneTitle, this.audioPath, this.cues, this.totalDuration);
  final int sceneNumber;
  String sceneTitle;
  final String audioPath;
  final List<SceneCue> cues;
  final double totalDuration;
}

enum LoopMode { off, scene, lines }

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
    // Frequent position updates keep the line highlight within ~0.1 s of the voice.
    _posSub = p
        .createPositionStream(steps: 2000, minPeriod: const Duration(milliseconds: 40), maxPeriod: const Duration(milliseconds: 100))
        .listen(_tick);
    _stateSub = p.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && isPlaying) _sceneEnded();
    });
    return p;
  }

  List<ScenePlayerItem> scenes = [];
  int currentSceneIndex = 0;
  List<SceneCue> cues = [];
  bool isPlaying = false;
  double currentTime = 0;
  int currentCueIndex = -1;
  /// Everyone I am playing (the phone lets you pick several); [myRole] is the first, for the places that need one.
  Set<String> myRoles = {};
  String get myRole => myRoles.isEmpty ? '' : myRoles.first;
  set myRole(String v) => myRoles = v.isEmpty ? {} : {v};
  bool muteMyLines = false;
  bool blockMyLines = false;

  /// Cue mode: stop just before each of my lines so I can say it myself.
  bool cueMode = false;

  /// Index of my cue the player is waiting at (cue mode), or null.
  int? waitingAtCue;
  double playbackRate = 1.0;
  LoopMode loopMode = LoopMode.off;
  double loopStart = 0, loopEnd = 0;

  /// Called whenever rehearsal settings change, so the view can be remembered.
  VoidCallback? onSettingsChanged;

  /// Called when playback moves to another scene (the optional page-turn sound).
  VoidCallback? onSceneTurn;

  ScenePlayerItem? get currentScene => currentSceneIndex >= 0 && currentSceneIndex < scenes.length ? scenes[currentSceneIndex] : null;
  SceneCue? get currentCue => currentCueIndex >= 0 && currentCueIndex < cues.length ? cues[currentCueIndex] : null;
  double get duration {
    final s = currentScene;
    if (s == null) return 0;
    if (s.totalDuration > 0) return s.totalDuration;
    return cues.isEmpty ? 0 : cues.last.endTime;
  }

  bool hasScene(int sceneNumber) => scenes.any((s) => s.sceneNumber == sceneNumber);

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
      final (cueList, total) = loadCueFile(app.sceneCueFiles[n]);
      items.add(
        ScenePlayerItem(
          n,
          app.effectiveSceneTitle(
            app.scenes.firstWhere(
              (s) => s.number == n,
              orElse: () => Scene(number: n, title: info.title, elementCount: 0, elements: const []),
            ),
          ),
          '$out/${info.filename}',
          cueList,
          total,
        ),
      );
    }
    loadItems(items);
  }

  /// Loads rendered scenes (the iPhone builds these from the project folder).
  /// Keeps the current scene when it's still there.
  void loadItems(List<ScenePlayerItem> items) {
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
      cues = scenes[idx].cues;
      notifyListeners();
    }
  }

  void unload() {
    pause();
    scenes = [];
    cues = [];
    currentCueIndex = -1;
    currentTime = 0;
    waitingAtCue = null;
    loopMode = LoopMode.off;
    notifyListeners();
  }

  /// A scene's cue map: every voiced line with its start and end time.
  static (List<SceneCue>, double) loadCueFile(String? path) {
    if (path == null) return (const [], 0);
    try {
      final j = jsonDecode(File(path).readAsStringSync()) as Map;
      final list = ((j['cues'] as List?) ?? const []).map((e) => SceneCue.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      return (list, (j['totalDuration'] as num?)?.toDouble() ?? 0);
    } catch (_) {
      return (const [], 0);
    }
  }

  Future<void> switchToScene(int index, {bool autoPlay = false, double startAt = 0}) async {
    if (index < 0 || index >= scenes.length) return;
    final wasPlaying = isPlaying;
    if (audioEnabled) await _player.pause();
    final changed = index != currentSceneIndex;
    if (changed && scenes.isNotEmpty && (wasPlaying || autoPlay)) onSceneTurn?.call();
    currentSceneIndex = index;
    cues = scenes[index].cues;
    currentTime = startAt;
    _carriedPast = null;
    _prompt = null;
    revealedCue = null;
    waitingAtCue = null;
    if (changed && loopMode == LoopMode.lines) loopMode = LoopMode.off;
    _updateCue();
    notifyListeners();
    _expectSeek(startAt);
    if (audioEnabled) {
      try {
        await _player.setFilePath(scenes[index].audioPath);
        await _player.setSpeed(playbackRate);
        if (startAt > 0) await _player.seek(Duration(milliseconds: (startAt * 1000).round()));
      } catch (_) {}
    }
    if (wasPlaying || autoPlay) play();
  }

  /// Plays scene [sceneNumber] from cue [cueIndex] (clicking a line).
  Future<void> playFrom(int sceneNumber, int cueIndex) async {
    final si = scenes.indexWhere((s) => s.sceneNumber == sceneNumber);
    if (si < 0) return;
    final sceneCues = scenes[si].cues;
    final t = (cueIndex >= 0 && cueIndex < sceneCues.length) ? sceneCues[cueIndex].startTime : 0.0;
    waitingAtCue = null;
    if (si != currentSceneIndex) {
      await switchToScene(si, autoPlay: true, startAt: t);
    } else {
      seek(t);
      play();
    }
  }

  @visibleForTesting
  void refreshForTest() => notifyListeners();

  /// Rebuild listeners after settings were restored directly into the fields.
  void refresh() => notifyListeners();

  void togglePlayPause() => isPlaying ? pause() : play();

  /// A short handwritten word over the timeline ("Places…" as cue-mode
  /// rehearsal starts). Gone after a second; never blocks anything.
  String? flash;
  Timer? _flashTimer;
  void _showFlash(String text) {
    flash = text;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1100), () {
      flash = null;
      notifyListeners();
    });
  }

  /// "Line!": like an actor calling for a prompt, shows my current (or next)
  /// line and reads it aloud from the recording. Calling again while it shows
  /// hides it; otherwise it hides two seconds after the reading ends.
  int? revealedCue;
  Timer? _revealTimer;
  static const revealDuration = Duration(seconds: 2);

  void callForLine() {
    if (myRole.isEmpty || cues.isEmpty) return;
    var target = waitingAtCue ?? _prompt?.cue ?? -1;
    if (target < 0) {
      for (var i = currentCueIndex < 0 ? 0 : currentCueIndex; i < cues.length; i++) {
        if (isMyLine(cues[i].speaker)) {
          target = i;
          break;
        }
      }
    }
    if (target >= 0) peekLine(target);
  }

  /// Shows cue [i] (and reads it aloud); a second call while it shows hides it.
  void peekLine(int i) {
    if (i < 0 || i >= cues.length) return;
    _revealTimer?.cancel();
    if (revealedCue == i) {
      revealedCue = null;
      _endPrompt();
      notifyListeners();
      return;
    }
    revealedCue = i;
    _startPrompt(i);
    if (_prompt == null) _hideRevealSoon(); // nothing to play (tests, no audio)
    notifyListeners();
  }

  void _hideRevealSoon() {
    _revealTimer?.cancel();
    _revealTimer = Timer(revealDuration, () {
      revealedCue = null;
      notifyListeners();
    });
  }

  /// The line being read aloud for a peek, and where to go back to after.
  _Prompt? _prompt;
  int? get promptingCue => _prompt?.cue;

  void _startPrompt(int i) {
    _endPrompt();
    if (!audioEnabled) return;
    _prompt = _Prompt(i, currentTime, isPlaying, waitingAtCue);
    waitingAtCue = null;
    isPlaying = false;
    final start = cues[i].startTime;
    _expectSeek(start);
    _player.setVolume(1);
    _player.seek(Duration(milliseconds: (start * 1000).round())).then((_) {
      if (_prompt?.cue == i) _player.play();
    });
  }

  /// Back to where the peek started: waiting at my line again, or playing on.
  void _endPrompt() {
    final pr = _prompt;
    if (pr == null) return;
    _prompt = null;
    if (audioEnabled) _player.pause();
    currentTime = pr.time;
    _expectSeek(pr.time);
    if (audioEnabled) _player.seek(Duration(milliseconds: (pr.time * 1000).round()));
    _updateCue();
    waitingAtCue = pr.waiting;
    if (pr.waiting != null) currentCueIndex = pr.waiting!;
    if (pr.wasPlaying) {
      isPlaying = true;
      if (audioEnabled) _player.play();
    }
  }

  /// Cue mode: the last of my lines the actor already said. Seeks on the
  /// phone can land a little early, inside that line; it must not stop there again.
  int? _carriedPast;

  void play() {
    if (scenes.isEmpty) return;
    if (_prompt != null) {
      // Play during a peek: stop reading and carry on as if it had finished.
      revealedCue = null;
      _endPrompt();
    }
    final w = waitingAtCue;
    if (w != null) {
      // Cue mode: the actor said their line; carry on after it.
      waitingAtCue = null;
      var j = w;
      while (j + 1 < cues.length && isMyLine(cues[j + 1].speaker)) {
        j++;
      }
      seek(j < cues.length ? cues[j].endTime : currentTime);
      _carriedPast = j;
    }
    // Starting a scene in cue mode: the actor's call to positions.
    if (cueMode && myRole.isNotEmpty && w == null && currentTime < 0.5) _showFlash('Places…');
    isPlaying = true;
    if (audioEnabled) _player.play();
    notifyListeners();
  }

  void pause() {
    if (_prompt != null) {
      revealedCue = null;
      _prompt = null;
    }
    isPlaying = false;
    if (audioEnabled && _p != null) {
      _player.pause();
      _player.setVolume(1);
    }
    notifyListeners();
    onSettingsChanged?.call(); // remembers where playback stopped
  }

  // After a seek (or loading a file) the audio plugin keeps reporting the old
  // position for a moment. Until a position near the target arrives, those
  // reports are ignored so the highlight doesn't jump back to the old line.
  double? _seekTarget;
  DateTime _seekDeadline = DateTime.fromMillisecondsSinceEpoch(0);
  void _expectSeek(double t) {
    _seekTarget = t;
    _seekDeadline = DateTime.now().add(const Duration(milliseconds: 1500));
  }

  void seek(double t) {
    _carriedPast = null;
    final clamped = t.clamp(0.0, duration > 0 ? duration : t);
    _expectSeek(clamped);
    if (audioEnabled) _player.seek(Duration(milliseconds: (clamped * 1000).round()));
    currentTime = clamped;
    waitingAtCue = null;
    _updateCue();
    notifyListeners();
  }

  void setRate(double r) {
    final snapped = (r * 20).round() / 20;
    playbackRate = snapped.clamp(0.5, 2.0);
    if (audioEnabled && _p != null) _player.setSpeed(playbackRate);
    notifyListeners();
    onSettingsChanged?.call();
  }

  void stepRate(double delta) => setRate(playbackRate + delta);

  void setRole(String role) {
    myRole = role;
    _rolesChanged();
  }

  /// Adds or drops one character from the ones I am playing.
  void toggleRole(String role) {
    if (!myRoles.remove(role)) myRoles = {...myRoles, role};
    _rolesChanged();
  }

  void _rolesChanged() {
    if (myRoles.isEmpty) {
      muteMyLines = false;
      blockMyLines = false;
      cueMode = false;
      waitingAtCue = null;
    }
    notifyListeners();
    onSettingsChanged?.call();
  }

  void setMute(bool v) {
    muteMyLines = v;
    notifyListeners();
    onSettingsChanged?.call();
  }

  void setBlock(bool v) {
    blockMyLines = v;
    notifyListeners();
    onSettingsChanged?.call();
  }

  void setCueMode(bool v) {
    cueMode = v;
    if (!v) waitingAtCue = null;
    notifyListeners();
    onSettingsChanged?.call();
  }

  void setLoop(LoopMode mode, {double start = 0, double end = 0}) {
    loopMode = mode;
    loopStart = start;
    loopEnd = end;
    if (mode == LoopMode.lines && (currentTime < start || currentTime >= end)) seek(start);
    notifyListeners();
    onSettingsChanged?.call();
  }

  void nextLine() {
    final next = currentCueIndex + 1;
    if (next < cues.length) seek(cues[next].startTime);
  }

  void prevLine() {
    if (cues.isEmpty) return;
    if (currentCueIndex > 0) {
      final cue = cues[currentCueIndex];
      seek(currentTime - cue.startTime > 1.5 ? cue.startTime : cues[currentCueIndex - 1].startTime);
    } else {
      seek(0);
    }
  }

  void nextScene() {
    if (currentSceneIndex + 1 < scenes.length) switchToScene(currentSceneIndex + 1, autoPlay: isPlaying);
  }

  void prevScene() {
    if (currentSceneIndex > 0) {
      switchToScene(currentSceneIndex - 1, autoPlay: isPlaying);
    } else {
      seek(0);
    }
  }

  bool isMyLine(String speaker) => myRoles.isNotEmpty && speaker.split('/').any(myRoles.contains);

  void _sceneEnded() {
    if (loopMode == LoopMode.scene) {
      seek(0);
      if (audioEnabled) _player.play();
    } else if (currentSceneIndex + 1 < scenes.length) {
      switchToScene(currentSceneIndex + 1, autoPlay: true);
    } else {
      pause();
      seek(0);
    }
  }

  @visibleForTesting
  void tickForTest(double seconds) => _tick(Duration(milliseconds: (seconds * 1000).round()));

  void _tick(Duration pos) {
    if (waitingAtCue != null) return;
    final t = pos.inMilliseconds / 1000;
    final target = _seekTarget;
    if (target != null) {
      if ((t - target).abs() > 0.3 && DateTime.now().isBefore(_seekDeadline)) return;
      _seekTarget = null;
    }
    // Reading a line aloud for a peek: just that line, then back.
    final pr = _prompt;
    if (pr != null) {
      currentTime = t;
      if (t >= cues[pr.cue].endTime) {
        _endPrompt();
        _hideRevealSoon();
        notifyListeners();
      } else {
        _throttledNotify();
      }
      return;
    }
    currentTime = t;
    final before = currentCueIndex;
    _updateCue();
    final past = _carriedPast;
    if (past != null && currentCueIndex > past) _carriedPast = null;
    if (isPlaying && loopMode == LoopMode.lines && loopEnd > loopStart && currentTime >= loopEnd) {
      seek(loopStart);
      if (audioEnabled) _player.play();
      return;
    }
    // Cue mode: stop at the start of my next line.
    if (isPlaying && cueMode && myRole.isNotEmpty) {
      for (final i in [currentCueIndex, currentCueIndex + 1]) {
        if (i < 0 || i >= cues.length) continue;
        if (past != null && i <= past) continue;
        final c = cues[i];
        if (isMyLine(c.speaker) && currentTime >= c.startTime - 0.08 && currentTime < c.endTime) {
          isPlaying = false;
          if (audioEnabled) _player.pause();
          waitingAtCue = i;
          currentCueIndex = i;
          currentTime = c.startTime;
          notifyListeners();
          return;
        }
      }
    }
    // Mute my lines: silence during my cues (looking one tick ahead) so the
    // gap stays the length of the line.
    var muted = false;
    if (muteMyLines && myRole.isNotEmpty) {
      final c = currentCue;
      if (c != null && isMyLine(c.speaker) && currentTime >= c.startTime && currentTime < c.endTime) muted = true;
      final ni = currentCueIndex + 1;
      if (ni >= 0 && ni < cues.length && isMyLine(cues[ni].speaker) && cues[ni].startTime - currentTime <= 0.06) muted = true;
    }
    if (audioEnabled) _player.setVolume(muted ? 0 : 1);
    if (before != currentCueIndex) {
      notifyListeners();
    } else {
      _throttledNotify();
    }
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastNotify) > const Duration(milliseconds: 200)) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  void _updateCue() {
    if (cues.isEmpty) {
      currentCueIndex = -1;
      return;
    }
    currentCueIndex = cueIndexAt(cues, currentTime);
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _flashTimer?.cancel();
    _posSub?.cancel();
    _stateSub?.cancel();
    _p?.dispose();
    super.dispose();
  }
}

/// The cue playing at [t]: the last cue that has started. Between lines (the
/// pause) the previous line stays lit. A small tolerance absorbs seeks that
/// land a hair before a line's start, which would otherwise light the line
/// before it.
int cueIndexAt(List<SceneCue> cues, double t) {
  const tolerance = 0.03;
  var lo = 0, hi = cues.length - 1, found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    if (cues[mid].startTime <= t + tolerance) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

class _Prompt {
  _Prompt(this.cue, this.time, this.wasPlaying, this.waiting);
  final int cue;
  final double time;
  final bool wasPlaying;
  final int? waiting;
}
