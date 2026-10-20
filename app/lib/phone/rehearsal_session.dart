// One project open for rehearsal on the iPhone (#91): its scenes as lines to
// show, the rendered ones loaded into the shared RehearsalPlayer, and this
// phone's rehearsal settings saved in the project folder (#89's
// Rehearsal/<device>.json) so the Mac and the phone pick up each other's.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../services/project_files.dart';
import '../state/player_state.dart';
import 'folder_access.dart';

/// A line on screen. [cueIndex] is its place in the scene's audio (null in a
/// scene that isn't rendered).
class PhoneLine {
  PhoneLine({required this.kind, required this.speaker, required this.text, this.cueIndex});
  final String kind; // dialog | stage_direction | parenthetical
  final String speaker; // narratorKey, or slash-joined names for simultaneous lines
  final String text;
  final int? cueIndex;

  bool get isDialog => kind == 'dialog' && speaker != narratorKey;
  List<String> get names => speaker.split('/');
}

class PhoneScene {
  PhoneScene({required this.number, required this.title, required this.lines, required this.rendered});
  final int number;
  final String title;
  final List<PhoneLine> lines;
  final bool rendered;
}

class RehearsalSession {
  RehearsalSession({required this.project, required this.scenes, required this.characters, required this.items});

  final Project project;
  final List<PhoneScene> scenes;

  /// Everyone with a line, in order of appearance (the role picker's list).
  final List<String> characters;

  /// Rendered scenes, for the player.
  final List<ScenePlayerItem> items;

  String get folder => project.folderPath!;

  static final _sceneFile = RegExp(r'^Scene_(\d+)_.*\.m4a$');

  /// Reads the project folder (already on the phone: PhoneStore.download).
  static RehearsalSession load(Project project) {
    final folder = project.folderPath!;
    final script = loadScriptSnapshot(folder);

    // Rendered scenes: the cue maps say exactly what was voiced, corrections included.
    final audio = <int, String>{};
    for (final f in Directory(folder).listSync().whereType<File>()) {
      final name = f.path.split('/').last;
      final m = _sceneFile.firstMatch(name);
      if (m != null) audio[int.parse(m.group(1)!)] = f.path;
    }
    final items = <ScenePlayerItem>[];
    final cueTitles = <int, String>{};
    for (final n in audio.keys.toList()..sort()) {
      final path = audio[n]!;
      final cuePath = path.replaceFirst(RegExp(r'\.m4a$'), '.cues.json');
      final (cues, total) = RehearsalPlayer.loadCueFile(cuePath);
      try {
        cueTitles[n] = (jsonDecode(File(cuePath).readAsStringSync()) as Map)['sceneTitle'] as String? ?? '';
      } catch (_) {}
      items.add(ScenePlayerItem(n, '', path, cues, total));
    }

    // Edits are keyed by the PDF's path on the Mac: re-point them here.
    final pdf = project.pdfPath ?? '$folder/${project.pdfFilename}';
    final corrections = Map.of(project.corrections);
    final titles = {for (final e in project.sceneTitleOverrides.entries) e.key: Map.of(e.value)};
    final added = {for (final e in project.userAddedElements.entries) e.key: List.of(e.value)};
    rebaseEdits(pdfPath: pdf, corrections: corrections, sceneTitleOverrides: titles, userAddedElements: added);

    String titleFor(int n, String parsed) {
      final t = titles[pdf]?[n] ?? cueTitles[n] ?? parsed;
      return t.isEmpty ? 'Scene $n' : t;
    }

    final scenes = <PhoneScene>[];
    final numbers = <int>{...?script?.scenes.map((s) => s.number), ...audio.keys}.toList()..sort();
    for (final n in numbers) {
      final item = items.where((i) => i.sceneNumber == n).firstOrNull;
      final parsed = script?.scenes.where((s) => s.number == n).firstOrNull;
      final List<PhoneLine> lines;
      if (item != null) {
        lines = [for (final (i, c) in item.cues.indexed) PhoneLine(kind: c.kind, speaker: c.speaker, text: c.text, cueIndex: i)];
      } else {
        lines = [];
        for (final el in parsed?.elements ?? const <SceneElement>[]) {
          final fix = corrections[correctionKey(pdf, n, el.text, el.occurrence)];
          if (fix?.markedAsNoise ?? false) continue;
          final kind = fix?.correctedKind ?? el.kind;
          final who = fix?.correctedSpeaker ?? (el.isOverlap ? el.overlapCue!.join('/') : el.speaker);
          lines.add(
            PhoneLine(kind: kind, speaker: kind == 'dialog' && (who?.isNotEmpty ?? false) ? who! : narratorKey, text: fix?.correctedText ?? el.text),
          );
        }
      }
      scenes.add(PhoneScene(number: n, title: titleFor(n, parsed?.title ?? ''), lines: lines, rendered: item != null));
    }
    for (final item in items) {
      item.sceneTitle = scenes.firstWhere((s) => s.number == item.sceneNumber).title;
    }

    final characters = <String>[];
    for (final s in scenes) {
      for (final l in s.lines) {
        if (!l.isDialog) continue;
        for (final n in l.names) {
          if (!characters.contains(n)) characters.add(n);
        }
      }
    }
    return RehearsalSession(project: project, scenes: scenes, characters: characters, items: items);
  }

  // ---------------------------------------------------------------------------
  // Rehearsal settings
  // ---------------------------------------------------------------------------

  /// Restores the newest settings any device saved: role, practice toggles,
  /// speed, and where playback stopped (paused there, not playing).
  Future<void> restore(RehearsalPlayer player) async {
    final r = loadNewestRehearsal(folder);
    if (r == null) return;
    if (r.role.isNotEmpty && characters.contains(r.role)) {
      player.myRole = r.role;
      player.muteMyLines = r.mute;
      player.blockMyLines = r.block;
      player.cueMode = r.cue;
    }
    player.playbackRate = r.speed;
    final si = player.scenes.indexWhere((s) => s.sceneNumber == r.sceneNumber);
    if (si >= 0) {
      await player.switchToScene(si, startAt: r.time);
      if (r.loopMode == 'scene') player.loopMode = LoopMode.scene;
      if (r.loopMode == 'lines' && r.loopEnd > r.loopStart) {
        player.loopMode = LoopMode.lines;
        player.loopStart = r.loopStart;
        player.loopEnd = r.loopEnd;
      }
    }
    player.refresh();
  }

  Timer? _saveTimer;

  /// Saves this phone's settings, half a second after the last change.
  void scheduleSave(RehearsalPlayer player, {bool folderAccess = true}) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => save(player, folderAccess: folderAccess));
  }

  Future<void> save(RehearsalPlayer player, {bool folderAccess = true}) async {
    _saveTimer?.cancel();
    final state = RehearsalState(
      role: player.myRole,
      mute: player.muteMyLines,
      block: player.blockMyLines,
      cue: player.cueMode,
      speed: player.playbackRate,
      loopMode: player.loopMode.name,
      loopStart: player.loopStart,
      loopEnd: player.loopEnd,
      sceneNumber: player.currentScene?.sceneNumber,
      time: player.currentTime,
      device: 'iPhone',
    );
    final id = await deviceId();
    try {
      if (folderAccess) {
        final path = rehearsalPath(folder, id);
        try {
          final old = RehearsalState.fromJson(Map<String, dynamic>.from(jsonDecode(File(path).readAsStringSync()) as Map));
          if (old.sameAs(state)) return;
        } catch (_) {}
        await FolderAccess.write(path, const JsonEncoder.withIndent('  ').convert(state.toJson()));
      } else {
        writeRehearsal(folder, id, state);
      }
    } catch (e) {
      debugPrint('Could not save rehearsal settings: $e');
    }
  }

  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('deviceId');
    if (id == null) {
      id = const Uuid().v4().toUpperCase();
      await prefs.setString('deviceId', id);
    }
    return id;
  }

  void dispose() => _saveTimer?.cancel();
}
