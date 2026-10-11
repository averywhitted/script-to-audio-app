// Sample data for screen renders and logic tests. Mirrors the design's mock
// content (The Importance of Being Earnest).

import 'dart:convert';
import 'dart:io';

import 'package:table_read/models/models.dart';
import 'package:table_read/state/app_state.dart';

const sceneTitles = [
  'Morning-room, Half-Moon Street',
  'Cucumber sandwiches',
  'Bunburying',
  'The proposal',
  'The garden at the Manor House',
  'Jack in mourning',
  'Cecily and Algernon',
  'Tea, and a misunderstanding',
  'Morning-room at the Manor House',
  'Lady Bracknell arrives',
  'The handbag',
  'Ernest after all',
];

const characters = {
  'ALGERNON': 'M',
  'CECILY': 'F',
  'DR. CHASUBLE': 'M',
  'GWENDOLEN': 'F',
  'JACK': 'M',
  'LADY BRACKNELL': 'F',
  'LANE': 'M',
  'MERRIMAN': 'M',
  'MISS PRISM': 'F',
};

Map<String, dynamic> _d(String sp, String text, {double conf = 1, String? reason}) => {
  'kind': 'dialog',
  'speaker': sp,
  'text': text,
  'confidence': conf,
  'reason': reason,
};
Map<String, dynamic> _n(String text) => {'kind': 'stage_direction', 'speaker': null, 'text': text};

List<Map<String, dynamic>> _scene9() => [
  _n('Morning-room at the Manor House. GWENDOLEN and CECILY are at the window, looking out into the garden.'),
  _d('CECILY', 'They have been eating muffins. That looks like repentance.'),
  _d('GWENDOLEN', "(After a pause.) They don't seem to notice us at all. Couldn't you cough?"),
  _d('CECILY', "But I haven't got a cough."),
  _n('THE IMPORTANCE OF BEING EARNEST          47'),
  _d('GWENDOLEN', 'This dignified silence seems to produce an unpleasant effect.', conf: 0.58, reason: 'Speaker name split across a page break'),
  _d('CECILY', 'A most distasteful one.'),
  {
    'kind': 'dialog',
    'speaker': 'GWENDOLEN',
    'text': 'Your Christian names are still an insuperable barrier. That is all!',
    'overlapCue': ['GWENDOLEN', 'CECILY'],
    'overlapTexts': ['Your Christian names are still an insuperable barrier.', 'That is all!'],
  },
  _n('They turn away from the window together.'),
  _d('JACK', 'Gwendolen — Cecily — it is a very painful position for me to be in.'),
  _d('ALGERNON', 'I see you are looking at me.'),
  _d('GWENDOLEN', 'Let us preserve a dignified silence.'),
];

List<Map<String, dynamic>> _generic(int n) {
  final names = characters.keys.toList();
  return [
    _n('The scene opens. ${names[n % names.length]} enters, carrying a book.'),
    for (var i = 0; i < 6; i++) _d(names[(n + i) % names.length], 'Line ${i + 1} of scene ${n + 1}, spoken with great feeling and a certain amount of wit.'),
  ];
}

ScriptSummary earnestScript() {
  final scenes = <Map<String, dynamic>>[];
  for (var i = 0; i < sceneTitles.length; i++) {
    final els = i == 8 ? _scene9() : _generic(i);
    scenes.add({
      'number': i + 1,
      'title': sceneTitles[i],
      'elementCount': [42, 37, 55, 58, 48, 51, 66, 71, 64, 112, 39, 31][i],
      'elements': els,
    });
  }
  return ScriptSummary.fromJson({
    'title': 'THE IMPORTANCE OF BEING EARNEST',
    'sceneCount': 12,
    'characterCount': characters.length,
    'lineCount': 642,
    'characters': [
      for (final e in characters.entries) {'name': e.key, 'genderHint': e.value},
    ],
    'scenes': scenes,
  });
}

List<VoiceSummary> kokoroVoices() => [
  for (final v in [
    ['bm_lewis', 'Lewis', 'M'],
    ['bm_fable', 'Fable', 'M'],
    ['bm_daniel', 'Daniel', 'M'],
    ['bm_george', 'George', 'M'],
    ['am_adam', 'Adam', 'M'],
    ['am_michael', 'Michael', 'M'],
    ['bf_isabella', 'Isabella', 'F'],
    ['bf_emma', 'Emma', 'F'],
    ['bf_alice', 'Alice', 'F'],
    ['bf_lily', 'Lily', 'F'],
    ['af_heart', 'Heart', 'F'],
  ])
    VoiceSummary(id: v[0], label: v[1], gender: v[2], locale: 'en_GB', display: '${v[1]} (${v[2]}) en_GB'),
];

/// Writes sample projects into [base]; returns the folder of the Earnest project.
String writeProjects(String base) {
  final now = clockNow();
  final specs = [
    ('The Importance of Being Earnest', 12, now.subtract(const Duration(hours: 1))),
    ('Hamlet', 7, now.subtract(const Duration(hours: 2))),
    ('Uncle Vanya', 8, DateTime(now.year, 10, 2)),
    ('Twelfth Night', 18, DateTime(now.year, 9, 30)),
    ("A Doll's House", 0, DateTime(now.year, 9, 27)),
    ('The Seagull', 1, DateTime(now.year, 9, 21)),
    ('Much Ado About Nothing', 0, DateTime(now.year, 9, 14)),
    ('Spring Showcase, Draft 3', 6, DateTime(now.year, 9, 9)),
  ];
  String? earnest;
  for (final (i, s) in specs.indexed) {
    final folder = '$base/${s.$1.replaceAll(RegExp(r"[^\w \-]"), '')}';
    Directory(folder).createSync(recursive: true);
    final p = Project.newProject(s.$1, folder)
      ..pdfFilename = 'script.pdf'
      ..lastOpenedAt = s.$3
      ..renderedScenes = [for (var n = 1; n <= s.$2; n++) n];
    final j = p.toJson()..['id'] = 'PROJECT-$i-0000-0000-000000000000';
    File('$folder/project.json').writeAsStringSync(jsonEncode(j));
    File('$folder/script.pdf').writeAsStringSync('%PDF-1.4 sample');
    if (i == 0) earnest = folder;
  }
  // One archived project.
  final arch = Project.newProject('The Cherry Orchard', '$base/x')..scriptTitle = 'The Cherry Orchard: A Comedy in Four Acts';
  File('$base/ARCH-1.archive-meta.json')
      .writeAsStringSync(jsonEncode({'project': arch.toJson(), 'zipFilename': 'ARCH-1.zip', 'originalFolderName': 'The Cherry Orchard'}));
  return earnest!;
}

/// Puts the app into an open-project state like the design's dashboard screens.
void loadEarnest(AppState app, String folder) {
  final script = earnestScript();
  app.pdfPath = '$folder/script.pdf';
  app.script = script;
  app.outputDirectory = folder;
  app.selectedEngine = EngineKind.kokoro;
  app.installedEngines = {EngineKind.macOS, EngineKind.kokoro};
  app.voices = kokoroVoices();
  app.voiceAssignment = {
    narratorKey: 'bm_lewis',
    'ALGERNON': 'bm_fable',
    'CECILY': 'bf_isabella',
    'DR. CHASUBLE': 'bm_daniel',
    'GWENDOLEN': 'bf_emma',
    'JACK': 'bm_george',
    'LADY BRACKNELL': 'bf_alice',
    'LANE': 'am_michael',
    'MERRIMAN': 'am_adam',
    'MISS PRISM': 'bf_lily',
  };
  app.selectedScenes = {10, 11, 12};
  // Rendered audio + cue maps for scenes 1–9.
  for (final s in script.scenes.take(9)) {
    final name = AppState.sceneFilename(s.number, s.title);
    File('$folder/$name').writeAsStringSync('');
    var t = 1.0;
    final cues = [
      for (final (i, el) in s.elements.indexed)
        {
          'index': i,
          'kind': el.kind,
          'speaker': el.kind == 'dialog' ? (el.isOverlap ? el.overlapCue!.join('/') : el.speaker) : narratorKey,
          'text': el.text,
          'startTime': t,
          'endTime': t += 3.5,
        },
    ];
    File('$folder/${name.replaceAll('.m4a', '.cues.json')}').writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'sceneNumber': s.number, 'sceneTitle': s.title, 'generatedAt': '2026-10-10T09:00:00Z', 'totalDuration': t, 'cues': cues}),
    );
  }
  app.checkRenderedScenes();
  app.scenesNeedingRerender = {4, 8};
  final s9 = script.scenes[8];
  // A corrected line, a removed line (page header), an added line.
  app.corrections[correctionKey(app.pdfPath!, 9, s9.elements[1].text)] = ParserCorrection(
    textKey: s9.elements[1].text,
    pdfIdentifier: app.pdfPath!,
    sceneNumber: 9,
    originalKind: 'dialog',
    originalSpeaker: 'GWENDOLEN',
    correctedSpeaker: 'CECILY',
  );
  app.corrections[correctionKey(app.pdfPath!, 9, s9.elements[4].text)] = ParserCorrection(
    textKey: s9.elements[4].text,
    pdfIdentifier: app.pdfPath!,
    sceneNumber: 9,
    originalKind: 'stage_direction',
    markedAsNoise: true,
  );
  app.userAddedElements[app.addedKey(9)] = [
    UserAddedElement(
      pdfPath: app.pdfPath!,
      sceneNumber: 9,
      afterElementTextKey: s9.elements[8].ref,
      speaker: '',
      text: 'A long pause. Neither moves.',
      kind: 'stage_direction',
    ),
  ];
}
