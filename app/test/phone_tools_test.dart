// The iPhone / iPad rehearsal tools that need no screen: notes per line (#117),
// lining the script up with the PDF's pages (#116), and searching the text (#113).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:table_read/models/models.dart' show clockNow;
import 'package:table_read/phone/line_notes.dart';
import 'package:table_read/phone/page_align.dart';
import 'package:table_read/phone/phone_store.dart';
import 'package:table_read/phone/rehearsal_session.dart';
import 'package:table_read/phone/script_search.dart';
import 'package:table_read/services/project_files.dart';

import 'fixtures.dart';

void main() {
  late Directory tmp;
  late String folder;

  setUpAll(() {
    tmp = Directory('${Directory.systemTemp.path}/tr_phone_tools');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    folder = writeProjects(tmp.path);
    saveScriptSnapshot(folder, earnestScript(), pdfFilename: 'script.pdf');
  });

  Future<RehearsalSession> session() async {
    final s = PhoneStore(folderAccess: false)..folder = tmp.path;
    await s.refresh();
    return RehearsalSession.load(s.projects.firstWhere((p) => p.folderPath == folder));
  }

  group('line keys', () {
    test('are unique, and the same text twice in a scene gets a repeat number', () async {
      final s = await session();
      final keys = [for (final sc in s.scenes) ...sc.lines.map((l) => l.key)];
      expect(keys.every((k) => k.isNotEmpty), isTrue);
      expect(keys.toSet().length, keys.length);
    });

    test('long text is cut to 60 characters like the corrections', () {
      expect(lineNoteKey(3, 'x' * 100, 0), '3|${'x' * 60}|0');
    });
  });

  group('notes', () {
    late Directory notesDir;
    setUp(() {
      notesDir = Directory('$folder/$notesFolder');
      if (notesDir.existsSync()) notesDir.deleteSync(recursive: true);
    });

    LineNotes notes(String device) => LineNotes(folder: folder, deviceId: device, folderAccess: false)..load();

    test('are saved in the project and read back', () async {
      final a = notes('A');
      await a.set('1|Hello|0', '  Slow down here  ');
      expect(a['1|Hello|0']!.text, 'Slow down here');
      expect(notes('A')['1|Hello|0']!.text, 'Slow down here');
      expect(File('$folder/$notesFolder/A.json').existsSync(), isTrue);
    });

    test('each device writes only its own file, and the newest edit wins when they are merged', () async {
      var t = DateTime.utc(2026, 10, 10, 9);
      clockNow = () => t;
      final a = notes('A');
      await a.set('k', 'from A');
      t = t.add(const Duration(minutes: 5));
      final b = notes('B')..load();
      await b.set('k', 'from B, later');
      expect(Directory('$folder/$notesFolder').listSync().length, 2);
      expect(notes('A')['k']!.text, 'from B, later');
      expect(notes('B')['k']!.text, 'from B, later');
    });

    test('a deletion beats an older copy on another device', () async {
      var t = DateTime.utc(2026, 10, 10, 9);
      clockNow = () => t;
      await notes('A').set('k', 'keep?');
      t = t.add(const Duration(minutes: 1));
      final b = notes('B');
      await b.remove('k');
      expect(notes('A').has('k'), isFalse);
      expect(notes('A').count, 0);
    });

    test('an empty note is a deletion; expanding is per screen and not saved', () async {
      final a = notes('A');
      await a.set('k', 'x');
      a.toggle('k');
      expect(a.expanded, {'k'});
      await a.set('k', '   ');
      expect(a.has('k'), isFalse);
      expect(a.expanded, isEmpty);
      expect(notes('A').expanded, isEmpty);
    });
  });

  group('lining lines up with PDF pages', () {
    const pages = [
      'THE PLAY\nby Somebody\n',
      '1  INT. MORNING ROOM - DAY\nALGERNON\nDid you hear what I was playing, Lane?\nLANE\nI didn\'t think it polite to listen, sir.\n',
      'ALGERNON\nI\'m sorry for that, for your sake.\nLANE\nYes, sir.\n',
      'ALGERNON\nYes, sir.\n',
    ];

    test('each line takes the page it starts on, moving only forward', () {
      final p = alignLinesToPages(pages, [
        'Did you hear what I was playing, Lane?',
        'I didn\'t think it polite to listen, sir.',
        'I\'m sorry for that, for your sake.',
        'Yes, sir.', // appears on page 3 first (after the cursor), not page 2
        'Yes, sir.', // the repeat is page 4
      ]);
      expect(p, [2, 2, 3, 3, 4]);
    });

    test('quotes, dashes, case and line breaks do not matter', () {
      final p = alignLinesToPages(pages, ['did you hear what i was playing — lane?', 'I DIDN’T THINK IT POLITE TO LISTEN, SIR']);
      expect(p, [2, 2]);
    });

    test('a line that is not in the PDF takes the previous line\'s page; no pages means page 1', () {
      expect(alignLinesToPages(pages, ['I\'m sorry for that, for your sake.', 'something the parser invented', '']), [3, 3, 3]);
      expect(alignLinesToPages(const [], ['a', 'b']), [1, 1]);
    });

    test('a line that runs over a page break belongs to the page it starts on', () {
      final p = alignLinesToPages(
        ['aaa\nThis line is long and it runs on and on and on\n', 'and finally ends\nNEXT LINE here\n'],
        ['This line is long and it runs on and on and on and finally ends', 'NEXT LINE here'],
      );
      expect(p, [1, 2]);
    });
  });

  group('search', () {
    test('finds text in rendered and text-only scenes, in script order', () async {
      final s = await session();
      final hits = searchScript(s, 'the');
      expect(hits, isNotEmpty);
      expect([for (final h in hits) h.scene], orderedEquals([for (final h in hits) h.scene]..sort()));
      final h = hits.first;
      expect(s.scenes[h.scene].lines[h.line].text.toLowerCase().substring(h.start, h.end), 'the');
    });

    test('ignores case and accents, and an empty query finds nothing', () async {
      final s = await session();
      expect(searchScript(s, 'ALGERNON').length, searchScript(s, 'algernon').length);
      expect(searchScript(s, '   '), isEmpty);
      expect(searchScript(s, 'zzzqq'), isEmpty);
    });

    test('a speaker\'s name finds their lines even when the text lacks it', () async {
      final s = await session();
      final byName = searchScript(s, 'lane').where((h) => !h.inText);
      expect(byName, isNotEmpty);
      expect(byName.every((h) => s.scenes[h.scene].lines[h.line].names.any((n) => n.toLowerCase().contains('lane'))), isTrue);
    });

    test('skipped lines (blanked ones) never match', () async {
      final s = await session();
      final all = searchScript(s, 'the');
      final none = searchScript(s, 'the', skip: (_) => true);
      expect(all, isNotEmpty);
      expect(none, isEmpty);
    });
  });
}
