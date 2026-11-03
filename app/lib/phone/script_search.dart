// Search the script text (#113): every scene, rendered or not. A match is a
// range inside one line's text, or (when only the speaker's name matches) the
// whole line.

import 'rehearsal_session.dart';

class SearchHit {
  const SearchHit(this.scene, this.line, this.start, this.end);
  final int scene; // index into session.scenes
  final int line; // index into that scene's lines
  /// The matched range in the line's text; start == end for a name-only hit.
  final int start, end;
  bool get inText => end > start;
}

/// Case-insensitive; accents don't matter (é finds e).
String _plain(String s) {
  const from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY';
  final b = StringBuffer();
  for (final c in s.runes) {
    final ch = String.fromCharCode(c);
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString().toLowerCase();
}

/// Every hit for [query], in script order. Lines in [skip] (blanked lines, so
/// searching can't be used to read them) are left out.
List<SearchHit> searchScript(RehearsalSession session, String query, {bool Function(PhoneLine)? skip}) {
  final q = _plain(query.trim());
  if (q.isEmpty) return const [];
  final hits = <SearchHit>[];
  for (final (si, s) in session.scenes.indexed) {
    for (final (li, l) in s.lines.indexed) {
      if (skip != null && skip(l)) continue;
      final text = _plain(l.text);
      var from = 0, any = false;
      while (true) {
        final at = text.indexOf(q, from);
        if (at < 0) break;
        // _plain keeps every character one-to-one, so offsets carry over.
        hits.add(SearchHit(si, li, at, at + q.length));
        any = true;
        from = at + q.length;
      }
      if (!any && l.isDialog && l.names.any((n) => _plain(n).contains(q))) hits.add(SearchHit(si, li, 0, 0));
    }
  }
  return hits;
}
