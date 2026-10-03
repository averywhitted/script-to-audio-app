#!/usr/bin/env python3
"""label_sample.py — label a random sample of real script lines, quickly.

The second half of the parser's answer key. Generated scripts (synth_*.py) give
exact answers but can't show every quirk of real PDFs; this measures the
parser on the real ones. A fixed random sample of lines is drawn — the same
number from each PDF in "Test PDFs/", so every script counts equally — and you
label each line in a local web page: the line is highlighted on its real page,
you press a number for what it is and, for dialogue, a letter for who says it.
The parser's own answer is never shown, so it can't sway you.

Labels are saved to Test PDFs/reference/real_sample.json after every keypress.
They are stored by PDF, page and line position plus a fingerprint of the text,
never the text itself, so the file can be committed without publishing any
script. `real_score.py` scores the parser against them.

Statistics: with 31 lines from each of 13 scripts (403 in all), the parser's
overall accuracy is pinned within about +-5 points, 95% of the time.

Usage:
  python scripts/label_sample.py            # open http://localhost:8765
  python scripts/label_sample.py --per-pdf 40 --new   # fresh, larger sample (only before labelling)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sys
from collections import Counter
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import fitz  # PyMuPDF

ROOT = Path(__file__).resolve().parent.parent
PDF_DIR = ROOT / "Test PDFs"
LABELS = PDF_DIR / "reference" / "real_sample.json"
SEED = 2026

KINDS = [  # (key, label, help)
    ("1", "dialog", "Dialogue: spoken by a character"),
    ("2", "stage_direction", "Stage direction / action: read by the narrator"),
    ("3", "parenthetical", "Aside: bracketed direction like (beat), (to JOHN)"),
    ("4", "character_cue", "Character name above or before a speech"),
    ("5", "scene_heading", "Scene / act heading"),
    ("6", "page_furniture", "Page junk: page number, header, title page, cast list, notes"),
    ("7", "mixed", "Mixed: more than one of the above on this line"),
    ("0", "unsure", "Can't tell"),
]


# ---------------------------------------------------------------------------
# Lines
# ---------------------------------------------------------------------------

def page_lines(page: fitz.Page) -> list[tuple[str, tuple[float, float, float, float]]]:
    """Non-empty physical lines on a page, in PyMuPDF's order (stable per file)."""
    out = []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            text = "".join(s["text"] for s in line["spans"]).strip()
            if text:
                out.append((text, tuple(line["bbox"])))
    return out


def fingerprint(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:12]


@lru_cache(maxsize=None)
def doc(name: str) -> fitz.Document:
    return fitz.open(PDF_DIR / name)


def line_text(item: dict) -> str | None:
    """The text of a sampled line, or None if the PDF no longer matches."""
    lines = page_lines(doc(item["pdf"])[item["page"]])
    if item["line"] >= len(lines):
        return None
    text = lines[item["line"]][0]
    return text if fingerprint(text) == item["sha1"] else None


def draw_sample(per_pdf: int) -> dict:
    rng = random.Random(SEED)
    items = []
    for pdf in sorted(p.name for p in PDF_DIR.glob("*.pdf")):
        d = doc(pdf)
        every = [(pg, i, t, bb) for pg in range(len(d)) for i, (t, bb) in enumerate(page_lines(d[pg]))]
        for pg, i, t, bb in rng.sample(every, min(per_pdf, len(every))):
            items.append({"pdf": pdf, "page": pg, "line": i, "bbox": [round(v, 1) for v in bb],
                          "sha1": fingerprint(t), "label": None, "speaker": None})
    rng.shuffle(items)  # mix scripts so fatigue doesn't land on one of them
    return {"_meta": {"seed": SEED, "per_pdf": per_pdf,
                      "about": "Hand labels for a random sample of real PDF lines. "
                               "Positions and fingerprints only; no script text."},
            "items": items}


def load() -> dict:
    return json.loads(LABELS.read_text())


def save(data: dict) -> None:
    tmp = LABELS.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1))
    tmp.replace(LABELS)


@lru_cache(maxsize=None)
def speaker_names(pdf: str) -> list[str]:
    """Names to offer for dialogue: short ALL-CAPS lines that recur in the PDF.

    Found independently of the parser, so offering them shows nothing of its
    answer; they only save typing. Any other name can be typed in.
    """
    counts: Counter = Counter()
    d = doc(pdf)
    for pg in d:
        for text in pg.get_text("text").splitlines():   # plain text: fast, positions not needed
            t = re.sub(r"\(.*?\)", "", text).strip().rstrip(":.")
            if (1 <= len(t) <= 24 and t.upper() == t and re.search(r"[A-Z]", t)
                    and len(t.split()) <= 3 and not re.match(r"^(INT|EXT|SCENE|ACT)\b", t)):
                counts[t] += 1
    return [n for n, c in counts.most_common(15) if c >= 3]


# ---------------------------------------------------------------------------
# Web page
# ---------------------------------------------------------------------------

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Label lines</title>
<style>
 :root { --bg:#f6f5f2; --fg:#1d1d1b; --muted:#6b6b66; --line:#d8d6cf; --hi:#2f6fdd; --card:#fff; }
 @media (prefers-color-scheme: dark) { :root { --bg:#1b1b1a; --fg:#ecebe6; --muted:#a3a29b; --line:#3a3936; --card:#252523; } }
 body { margin:0; font:15px -apple-system, system-ui, sans-serif; background:var(--bg); color:var(--fg); }
 main { display:grid; grid-template-columns: minmax(0,1fr) 360px; gap:20px; padding:16px; max-width:1300px; margin:auto; }
 .pagewrap { position:relative; background:#fff; border:1px solid var(--line); align-self:start; }
 .pagewrap img { display:block; width:100%; }
 .box { position:absolute; border:2px solid var(--hi); background:rgba(47,111,221,.12); border-radius:3px; }
 aside { position:sticky; top:16px; align-self:start; }
 .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px; margin-bottom:12px; }
 .text { font:16px ui-monospace, Menlo, monospace; white-space:pre-wrap; }
 .muted { color:var(--muted); font-size:13px; }
 button { font:inherit; width:100%; text-align:left; padding:7px 10px; margin:3px 0; border:1px solid var(--line);
          border-radius:7px; background:var(--card); color:var(--fg); cursor:pointer; }
 button:hover { border-color:var(--hi); }
 kbd { display:inline-block; min-width:18px; text-align:center; font:12px ui-monospace, monospace; border:1px solid var(--line);
       border-radius:4px; padding:0 4px; margin-right:8px; }
 .bar { height:6px; background:var(--line); border-radius:3px; overflow:hidden; }
 .bar div { height:100%; width:0; background:var(--hi); }
 input { font:inherit; width:100%; box-sizing:border-box; padding:7px; border:1px solid var(--line); border-radius:7px;
         background:var(--card); color:var(--fg); }
 @media (max-width: 800px) { main { grid-template-columns: 1fr; } aside { position:static; } }
</style></head><body><main>
 <div class="pagewrap" id="pw"><img id="img" alt="PDF page"><div class="box" id="box"></div></div>
 <aside>
  <div class="card"><div class="bar"><div id="prog"></div></div><p class="muted" id="count"></p>
   <div class="text" id="line"></div><p class="muted" id="where"></p></div>
  <div class="card" id="speakers" hidden><p><b>Who says it?</b> <span class="muted">letter key, or / to type</span></p>
   <div id="names"></div><input id="other" placeholder="Other name, then Enter"></div>
  <div class="card" id="kinds"></div>
  <div class="card"><button id="back"><kbd>&larr;</kbd>Back to previous line</button>
   <p class="muted">Labels save after every choice. You can close this tab and resume later.</p></div>
 </aside></main>
<script>
const KINDS = __KINDS__;
let state = null, idx = 0, pendingDialog = false;
const $ = id => document.getElementById(id);
async function load(to) {
  const r = await fetch('/item' + (to === undefined ? '' : '?i=' + to)); state = await r.json();
  if (state.done) { document.querySelector('main').innerHTML =
      '<div class="card"><h2>All ' + state.total + ' lines labelled.</h2><p>Run <code>python scripts/real_score.py</code> to score the parser.</p></div>'; return; }
  idx = state.index; pendingDialog = false; $('speakers').hidden = true;
  $('line').textContent = state.text; $('where').textContent = state.pdf + ' \\u00b7 page ' + (state.page + 1);
  $('count').textContent = state.labelled + ' of ' + state.total + ' labelled' + (state.label ? ' \\u00b7 this one: ' + state.label + (state.speaker ? ' (' + state.speaker + ')' : '') : '');
  $('prog').style.width = (100 * state.labelled / state.total) + '%';
  const img = $('img'); img.onload = () => {
    const s = img.clientWidth / state.pw, b = state.bbox, box = $('box');
    box.style.left = (b[0] * s - 4) + 'px'; box.style.top = (b[1] * s - 3) + 'px';
    box.style.width = ((b[2] - b[0]) * s + 8) + 'px'; box.style.height = ((b[3] - b[1]) * s + 6) + 'px';
    box.scrollIntoView({block: 'center', behavior: 'instant'});
  };
  img.src = '/page?pdf=' + encodeURIComponent(state.pdf) + '&p=' + state.page;
  $('kinds').innerHTML = KINDS.map(k => '<button data-k="' + k[0] + '"><kbd>' + k[0] + '</kbd>' + k[2] + '</button>').join('');
  $('names').innerHTML = state.names.map((n, i) => '<button data-n="' + n + '"><kbd>' + String.fromCharCode(97 + i) + '</kbd>' + n + '</button>').join('');
}
async function send(label, speaker) {
  await fetch('/label', {method: 'POST', body: JSON.stringify({index: idx, label, speaker: speaker || null})});
  load();
}
function choose(key) {
  const k = KINDS.find(k => k[0] === key); if (!k) return;
  if (k[1] === 'dialog') { pendingDialog = true; $('speakers').hidden = false; $('other').value = ''; return; }
  send(k[1]);
}
document.addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b) return;
  if (b.dataset.k) choose(b.dataset.k);
  if (b.dataset.n) send('dialog', b.dataset.n);
  if (b.id === 'back') load(Math.max(0, idx - 1));
});
document.addEventListener('keydown', e => {
  if (e.target === $('other')) { if (e.key === 'Enter' && $('other').value.trim()) send('dialog', $('other').value.trim().toUpperCase()); if (e.key === 'Escape') $('other').blur(); return; }
  if (e.key === 'ArrowLeft') return load(Math.max(0, idx - 1));
  if (pendingDialog && /^[a-o]$/.test(e.key)) { const n = state.names[e.key.charCodeAt(0) - 97]; if (n) send('dialog', n); return; }
  if (pendingDialog && e.key === '/') { e.preventDefault(); $('other').focus(); return; }
  if (pendingDialog && e.key === 'Escape') { pendingDialog = false; $('speakers').hidden = true; return; }
  choose(e.key);
});
load();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the terminal quiet
        pass

    def _send(self, body: bytes, ctype: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        from urllib.parse import parse_qs, urlparse
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/":
            html = PAGE.replace("__KINDS__", json.dumps(KINDS))
            return self._send(html.encode(), "text/html; charset=utf-8")
        if url.path == "/page":
            if q.get("pdf") not in {p.name for p in PDF_DIR.glob("*.pdf")}:
                return self._send(b"no", "text/plain", 404)
            pix = doc(q["pdf"])[int(q["p"])].get_pixmap(dpi=110)
            return self._send(pix.tobytes("png"), "image/png")
        if url.path == "/item":
            data = load()
            items = data["items"]
            labelled = sum(1 for it in items if it["label"])
            if "i" in q:
                i = int(q["i"])
            else:
                i = next((n for n, it in enumerate(items) if not it["label"]), None)
                if i is None:
                    return self._send(json.dumps({"done": True, "total": len(items)}).encode(), "application/json")
            it = items[i]
            text = line_text(it) or "(this line no longer matches the PDF; press 0 to skip)"
            page = doc(it["pdf"])[it["page"]]
            body = {"index": i, "total": len(items), "labelled": labelled, "text": text,
                    "pdf": it["pdf"], "page": it["page"], "bbox": it["bbox"], "pw": page.rect.width,
                    "label": it["label"], "speaker": it["speaker"], "names": speaker_names(it["pdf"])}
            return self._send(json.dumps(body).encode(), "application/json")
        return self._send(b"not found", "text/plain", 404)

    def do_POST(self):
        if self.path != "/label":
            return self._send(b"not found", "text/plain", 404)
        msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        valid = {k[1] for k in KINDS}
        if msg.get("label") not in valid:
            return self._send(b"bad label", "text/plain", 400)
        data = load()
        it = data["items"][int(msg["index"])]
        it["label"] = msg["label"]
        it["speaker"] = msg.get("speaker") if msg["label"] == "dialog" else None
        save(data)
        return self._send(b"ok", "text/plain")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--per-pdf", type=int, default=31)
    ap.add_argument("--new", action="store_true", help="discard labels and draw a fresh sample")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    if args.new and LABELS.exists() and any(it["label"] for it in load()["items"]):
        print(f"Refusing to draw a new sample: {LABELS.relative_to(ROOT)} already has labels.\n"
              "Move that file somewhere safe first if you really want to start over.")
        return 1
    if args.new or not LABELS.exists():
        save(draw_sample(args.per_pdf))
        print(f"Drew a new sample: {args.per_pdf} lines from each PDF.")
    data = load()
    done = sum(1 for it in data["items"] if it["label"])
    print(f"{done} of {len(data['items'])} lines labelled.")
    print("Reading the PDFs once so every line loads instantly...", flush=True)
    for pdf in sorted({it["pdf"] for it in data["items"]}):
        speaker_names(pdf)
    print(f"Open http://localhost:{args.port}  (Ctrl-C to stop; labels are already saved)", flush=True)
    # One request at a time: PyMuPDF documents must not be used from two threads.
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
