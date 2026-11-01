// The shared Rust core (rust/crates/ffi) through dart:ffi: a PDF path in, the parsed script out, as the same JSON the
// Python worker's `parse` produces. One native call per parse, on a background isolate so the UI never waits on it.
//
// Where the native code lives:
//   macOS   libtable_read_ffi.dylib + libpdfium.dylib, next to the app (Contents/Frameworks) or, in a development
//           build, rust/target/release and the venv's pypdfium2 copy of PDFium.
//   iPhone  the same two dylibs in the .app's Frameworks folder (scripts/build_ios_native.sh builds them).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../models/models.dart';

class RustCoreException implements Exception {
  RustCoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef _ParseNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class RustCore {
  RustCore({this.libraryPath, this.pdfiumPath});

  /// The core's dylib; null means the symbols are linked into this process.
  final String? libraryPath;

  /// PDFium's dylib; null when PDFium is linked in statically.
  final String? pdfiumPath;

  /// Finds the native libraries, or null when this build has none (the caller then uses the Python worker).
  static RustCore? locate({String? repoRoot}) {
    final env = Platform.environment;
    if (Platform.isIOS) {
      // .../Runner.app/Runner -> .../Runner.app/Frameworks (the "Embed native libraries" build phase puts them there)
      final frameworks = '${File(Platform.resolvedExecutable).parent.path}/Frameworks';
      final lib = '$frameworks/libtable_read_ffi.dylib', pdfium = '$frameworks/libpdfium.dylib';
      return File(lib).existsSync() && File(pdfium).existsSync() ? RustCore(libraryPath: lib, pdfiumPath: pdfium) : null;
    }
    if (!Platform.isMacOS) return null;
    final exeDir = File(Platform.resolvedExecutable).parent.path; // .../Contents/MacOS
    final candidates = <(String, String?)>[
      if (env['TABLE_READ_RUST_LIB'] != null) (env['TABLE_READ_RUST_LIB']!, env['TABLE_READ_PDFIUM_LIB']),
      ('$exeDir/../Frameworks/libtable_read_ffi.dylib', '$exeDir/../Frameworks/libpdfium.dylib'),
      if (repoRoot != null) ('$repoRoot/rust/target/release/libtable_read_ffi.dylib', _venvPdfium(repoRoot)),
    ];
    for (final (lib, pdfium) in candidates) {
      if (File(lib).existsSync() && pdfium != null && File(pdfium).existsSync()) {
        return RustCore(libraryPath: lib, pdfiumPath: pdfium);
      }
    }
    return null;
  }

  static String? _venvPdfium(String root) {
    final lib = Directory('$root/.venv/lib');
    if (!lib.existsSync()) return null;
    for (final py in lib.listSync().whereType<Directory>()) {
      final f = File('${py.path}/site-packages/pypdfium2_raw/libpdfium.dylib');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// Parses [pdfPath]. [correctionsJson] is the content of corrections_config.json (optional).
  Future<ScriptSummary> parse(String pdfPath, {String? correctionsJson}) async {
    final lib = libraryPath, pdfium = pdfiumPath;
    final raw = await Isolate.run(() => _parseBlocking(lib, pdfium, pdfPath, correctionsJson));
    final r = jsonDecode(raw) as Map<String, dynamic>;
    if (r['ok'] != true) throw RustCoreException(r['error'] as String? ?? 'The Rust core could not parse this PDF.');
    return ScriptSummary.fromJson(Map<String, dynamic>.from(r['script'] as Map));
  }

  static String _parseBlocking(String? libraryPath, String? pdfiumPath, String pdfPath, String? correctionsJson) {
    final lib = libraryPath == null ? DynamicLibrary.process() : DynamicLibrary.open(libraryPath);
    final parse = lib.lookupFunction<_ParseNative, _ParseNative>('tr_parse_pdf');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('tr_free');
    final path = pdfPath.toNativeUtf8();
    final config = correctionsJson?.toNativeUtf8();
    final dylib = pdfiumPath?.toNativeUtf8();
    final out = parse(path, config ?? nullptr, dylib ?? nullptr);
    try {
      return out.toDartString();
    } finally {
      free(out);
      malloc.free(path);
      if (config != null) malloc.free(config);
      if (dylib != null) malloc.free(dylib);
    }
  }
}
