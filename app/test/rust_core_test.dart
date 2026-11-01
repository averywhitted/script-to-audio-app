// The shared Rust core through dart:ffi, against the Python worker on the same PDFs. Skips itself when the native
// libraries are not built (cd rust && cargo build --release) or the Python environment is missing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:table_read/phone/phone_store.dart';
import 'package:table_read/services/project_files.dart';
import 'package:table_read/services/python_bridge.dart';
import 'package:table_read/services/rust_core.dart';

void main() {
  final bridge = PythonBridge();
  final root = bridge.repoRoot;
  final core = root == null ? null : RustCore.locate(repoRoot: root);
  final skip = core == null || root == null ? 'Rust core or repository not found (cargo build --release in rust/)' : null;
  String pdf(String name) => '$root/Test PDFs/$name';

  // The worker reads PDFs with PyMuPDF, the core with PDFium, so a few lines differ legitimately (PyMuPDF glues a
  // page-break "(MORE)" into the preceding parenthetical, for instance). The answer keys are the real gate; this
  // checks the Dart plumbing end to end: same structure, nearly every element identical (90% overlap; small scripts amplify a few differences).
  test('parses a PDF to the same scenes, speakers and lines as the Python worker (within extraction noise)', () async {
    for (final name in ['synthetic/screenplay_letter.pdf', 'synthetic/inline_name_courier.pdf', 'Untitled shortfilm (third draft).pdf', 'Kill Floor (LCT Reading Draft).pdf']) {
      final config = File('$root/backend/corrections_config.json').readAsStringSync();
      final rust = await core!.parse(pdf(name), correctionsJson: config);
      final python = await bridge.parse(pdf(name));
      expect(rust.scenes, isNotEmpty, reason: name);
      expect(rust.title, isNotEmpty, reason: name);
      expect(rust.sceneCount, python.sceneCount, reason: name);
      expect(rust.characterCount, python.characterCount, reason: name);
      List<String> elements(s) => [for (final sc in s.scenes) for (final e in sc.elements) '${sc.number}|${e.kind}|${e.speaker}|${e.text}'];
      final a = elements(rust), b = elements(python);
      final common = a.toSet().intersection(b.toSet()).length;
      expect(common / (a.toSet().union(b.toSet()).length), greaterThan(0.9), reason: '$name: elements in common');
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  test('a missing PDF is an error message, not a crash', () async {
    expect(core!.parse('/nonexistent/none.pdf'), throwsA(isA<RustCoreException>()));
  }, skip: skip);

  test('the phone imports a PDF: a project folder with the PDF, script.json and project.json, and a second import gets its own folder', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('tr_import');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = PhoneStore(folderAccess: false)..folder = dir.path;
    final first = await store.importPdf(pickedPath: pdf('synthetic/screenplay_letter.pdf'), core: core);
    expect(store.error, isNull);
    expect(first, isNotNull);
    final folder = first!.folderPath!;
    expect(File('$folder/screenplay_letter.pdf').existsSync(), isTrue);
    final snapshot = loadScriptSnapshot(folder);
    expect(snapshot, isNotNull);
    expect(snapshot!.scenes, isNotEmpty);
    expect(first.pdfFilename, 'screenplay_letter.pdf');
    expect(store.projects.map((p) => p.id), contains(first.id));
    final second = await store.importPdf(pickedPath: pdf('synthetic/screenplay_letter.pdf'), core: core);
    expect(second!.folderPath, isNot(first.folderPath));
    expect(store.projects.length, 2);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('the corrections config bundled for the phone is the backend\'s', () {
    expect(
      File('assets/corrections_config.json').readAsStringSync(),
      File('../backend/corrections_config.json').readAsStringSync(),
      reason: 'copy backend/corrections_config.json to app/assets/ after changing it',
    );
  });
}
