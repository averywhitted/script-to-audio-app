// Which PDF page each script line starts on (#116). The parsed script carries no
// page numbers, and the parser is frozen, so the lines are matched against the
// PDF's own text instead: scanning forward through the pages' text, each line
// is looked for just after the previous one. Lines are in reading order, so the
// match only ever moves forward.

/// Letters and digits only, lower case: line wraps, dashes, quotes and spacing
/// differ between the script's lines and the page's text.
String _fold(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c)) b.write(c.toLowerCase());
  }
  return b.toString();
}

/// How much of a line is searched for: enough to be unique, short enough to
/// survive a line that carries over onto the next page.
const _probe = 28;

/// 1-based page for each of [lines], in order. A line that can't be found (a
/// heading the parser dropped, a typo) takes the page of the line before it.
List<int> alignLinesToPages(List<String> pageTexts, List<String> lines) {
  if (pageTexts.isEmpty) return List.filled(lines.length, 1);
  final pages = [for (final p in pageTexts) _fold(p)];
  var page = 0, offset = 0;
  final out = <int>[];
  for (final line in lines) {
    final f = _fold(line);
    final probe = f.length > _probe ? f.substring(0, _probe) : f;
    if (probe.isEmpty) {
      out.add(page + 1);
      continue;
    }
    var found = false;
    // This page after the last match, then a few pages on.
    for (var p = page; p < pages.length && p <= page + 3 && !found; p++) {
      final at = pages[p].indexOf(probe, p == page ? offset : 0);
      if (at >= 0) {
        page = p;
        offset = at + probe.length;
        found = true;
      }
    }
    out.add(page + 1);
  }
  return out;
}
