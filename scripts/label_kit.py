#!/usr/bin/env python3
"""label_kit.py — both exams in one offline page: no server, pause any time.

label_sample.py needs its server running in a terminal. This builds the same
labelling page as plain files instead, so you can open it by double-clicking,
close it whenever you like and pick up where you stopped:

  Test PDFs/label-kit/Label lines.html     (open this)
  Test PDFs/label-kit/pages/*.jpg          (the PDF pages it shows)

It holds every unlabelled line from two samples:
  - the held-out exam   (real_sample.exam.json)
  - the side-by-side exam (real_sample.sbs.json, drawn here on first build:
    every side-by-side line outside Stereophonic plus a random sample of
    Stereophonic's room columns, about 400 lines; see side_by_side.py)

Labels save in the browser after every keypress. "Export labels" downloads
them as one file; importing it writes them into the sample files, where
real_score.py reads them. The kit folder holds page images and line text, so
it stays local (gitignored), like the PDFs themselves.

Usage:
  python scripts/label_kit.py                 # build (or rebuild) the kit
  python scripts/label_kit.py --import        # import the newest export in ~/Downloads
  python scripts/label_kit.py --import FILE   # import a specific export
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import label_sample as L  # noqa: E402
import side_by_side as SBS  # noqa: E402

KIT = L.PDF_DIR / "label-kit"
PAGE_WIDTH_PX = 1100
SETS = {"exam": "Held-out exam", "sbs": "Side-by-side exam"}
SBS_TARGET = 400          # total lines in the side-by-side exam
SBS_SAMPLED_PDF = "4.10.24_Stereophonic (2).pdf"   # too big to take whole: sampled


def sample_path(name: str) -> Path:
    return L.PDF_DIR / "reference" / L.SAMPLES[name][0]


def item_key(name: str, it: dict) -> str:
    """Stable across rebuilds: the line's position plus its fingerprint."""
    return f"{name}|{it['pdf']}|{it['page']}|{it['line']}|{it['sha1']}"


# ---------------------------------------------------------------------------
# The side-by-side sample
# ---------------------------------------------------------------------------

def draw_sbs() -> dict:
    """Every side-by-side line, except Stereophonic, which is sampled to bring
    the total to about SBS_TARGET. Lines already in another sample are left
    out so the samples stay independent."""
    taken = set()
    for name in ("main", "exam"):
        p = sample_path(name)
        if p.exists():
            taken |= {(it["pdf"], it["page"], it["line"]) for it in json.loads(p.read_text())["items"]}
    rng = random.Random(L.SAMPLES["sbs"][1])
    whole, pool = [], []
    for pdf in sorted(p.name for p in L.PDF_DIR.glob("*.pdf")):
        for page, region in SBS.all_regions(pdf):
            lines = L.lines_of(pdf, page)
            for i in region:
                if (pdf, page, i) in taken:
                    continue
                text, bb = lines[i]
                it = {"pdf": pdf, "page": page, "line": i, "bbox": [round(v, 1) for v in bb],
                      "region": _bbox_of([lines[j][1] for j in region]),
                      "sha1": L.fingerprint(text), "label": None, "speaker": None, "together": None}
                (pool if pdf == SBS_SAMPLED_PDF else whole).append(it)
    items = whole + rng.sample(pool, max(0, min(len(pool), SBS_TARGET - len(whole))))
    rng.shuffle(items)
    return {"_meta": {"seed": L.SAMPLES["sbs"][1], "target": SBS_TARGET,
                      "about": "Hand labels for side-by-side lines in the real PDFs (side_by_side.py). "
                               "Positions and fingerprints only; no script text. 'together' (dialogue "
                               "only) = spoken at the same time as the text beside it: 'yes', 'no' or "
                               "'unsure'."},
            "items": items}


def _bbox_of(boxes) -> list[float]:
    return [round(min(b[0] for b in boxes), 1), round(min(b[1] for b in boxes), 1),
            round(max(b[2] for b in boxes), 1), round(max(b[3] for b in boxes), 1)]


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

def build() -> int:
    if not sample_path("exam").exists():
        print("No held-out exam sample yet: run `python scripts/label_sample.py --sample exam` once to draw it.")
        return 1
    if not sample_path("sbs").exists():
        L.use_sample("sbs")
        L.save(draw_sbs())
        print(f"Drew the side-by-side exam: {len(L.load()['items'])} lines.")
    (KIT / "pages").mkdir(parents=True, exist_ok=True)
    pdfs = sorted(p.name for p in L.PDF_DIR.glob("*.pdf"))
    items, pages, names = [], set(), {}
    for name in SETS:
        data = json.loads(sample_path(name).read_text())
        for n, it in enumerate(data["items"]):
            if it["label"]:
                continue
            text = L.line_text(it)
            if text is None:
                print(f"  skipped a line that no longer matches its PDF: {it['pdf']} p{it['page'] + 1}")
                continue
            page = L.doc(it["pdf"])[it["page"]]
            pages.add((it["pdf"], it["page"]))
            if it["page"] > 0:
                pages.add((it["pdf"], it["page"] - 1))
            names.setdefault(it["pdf"], L.speaker_names(it["pdf"]))
            items.append({"key": item_key(name, it), "set": name, "pdf": it["pdf"], "page": it["page"],
                          "img": _img_name(pdfs, it["pdf"], it["page"]),
                          "prev": _img_name(pdfs, it["pdf"], it["page"] - 1) if it["page"] > 0 else None,
                          "w": page.rect.width, "bbox": it["bbox"], "region": it.get("region"),
                          "text": text})
    for pdf, pg in sorted(pages):
        out = KIT / "pages" / _img_name(pdfs, pdf, pg)
        if not out.exists():
            page = L.doc(pdf)[pg]
            z = PAGE_WIDTH_PX / page.rect.width
            pix = page.get_pixmap(matrix=L.fitz.Matrix(z, z), colorspace=L.fitz.csGRAY)
            out.write_bytes(pix.tobytes("jpeg", jpg_quality=70))
    data = {"items": items, "names": names, "kinds": L.KINDS, "sets": SETS}
    html = PAGE.replace("__DATA__", json.dumps(data).replace("</", "<\\/"))
    (KIT / "Label lines.html").write_text(html)
    counts = {s: sum(1 for i in items if i["set"] == s) for s in SETS}
    print(f"Built {KIT.relative_to(L.ROOT)}/Label lines.html: "
          + ", ".join(f"{counts[s]} {SETS[s].lower()} lines" for s in SETS)
          + f", {len(pages)} page images.")
    return 0


def _img_name(pdfs: list[str], pdf: str, page: int) -> str:
    return f"{pdfs.index(pdf):02d}-{page:03d}.jpg"


# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------

def import_labels(path: Path | None) -> int:
    if path is None:
        found = sorted((Path.home() / "Downloads").glob("table-read-labels*.json"),
                       key=lambda p: p.stat().st_mtime)
        if not found:
            print("No export found in ~/Downloads (table-read-labels*.json). Pass the file's path.")
            return 1
        path = found[-1]
    labels = json.loads(path.read_text())["labels"]
    valid = {k[1] for k in L.KINDS}
    for name in SETS:
        L.use_sample(name)
        data = L.load()
        by_key = {item_key(name, it): it for it in data["items"]}
        changed = 0
        for key, lab in labels.items():
            it = by_key.get(key)
            if it is None or lab.get("label") not in valid:
                continue
            new = {"label": lab["label"],
                   "speaker": lab.get("speaker") if lab["label"] == "dialog" else None}
            if name == "sbs":
                new["together"] = lab.get("together") if lab["label"] == "dialog" else None
            if any(it.get(k) != v for k, v in new.items()):
                it.update(new)
                changed += 1
        L.save(data)
        done = sum(1 for it in data["items"] if it["label"])
        print(f"{SETS[name]}: {changed} labels imported; {done} of {len(data['items'])} labelled.")
    print(f"From {path}")
    return 0


# ---------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Label lines</title>
<style>
 :root { --bg:#f6f5f2; --fg:#1d1d1b; --muted:#6b6b66; --line:#d8d6cf; --hi:#2f6fdd; --card:#fff; --warn:#b5730f; }
 @media (prefers-color-scheme: dark) { :root { --bg:#1b1b1a; --fg:#ecebe6; --muted:#a3a29b; --line:#3a3936; --card:#252523; --warn:#e0a24a; } }
 body { margin:0; font:15px -apple-system, system-ui, sans-serif; background:var(--bg); color:var(--fg); }
 main { display:grid; grid-template-columns: minmax(0,1fr) 370px; gap:20px; padding:16px; max-width:1320px; margin:auto; }
 .pagewrap { position:relative; background:#fff; border:1px solid var(--line); align-self:start; }
 .pagewrap img { display:block; width:100%; }
 .box { position:absolute; border:2px solid var(--hi); background:rgba(47,111,221,.12); border-radius:3px; pointer-events:none; }
 .region { position:absolute; border:2px dashed rgba(181,115,15,.75); border-radius:4px; pointer-events:none; }
 aside { position:sticky; top:16px; align-self:start; max-height:calc(100vh - 32px); overflow-y:auto; }
 .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px; margin-bottom:12px; }
 .text { font:16px ui-monospace, Menlo, monospace; white-space:pre-wrap; overflow-wrap:anywhere; }
 .muted { color:var(--muted); font-size:13px; }
 .warn { color:var(--warn); }
 button { font:inherit; width:100%; text-align:left; padding:7px 10px; margin:3px 0; border:1px solid var(--line);
          border-radius:7px; background:var(--card); color:var(--fg); cursor:pointer; }
 button:hover { border-color:var(--hi); }
 button.small { width:auto; display:inline-block; padding:5px 10px; margin:3px 4px 3px 0; }
 kbd { display:inline-block; min-width:18px; text-align:center; font:12px ui-monospace, monospace; border:1px solid var(--line);
       border-radius:4px; padding:0 4px; margin-right:8px; }
 .bar { height:6px; background:var(--line); border-radius:3px; overflow:hidden; margin:4px 0 2px; }
 .bar div { height:100%; width:0; background:var(--hi); }
 .tag { display:inline-block; font-size:12px; padding:1px 8px; border-radius:99px; border:1px solid var(--line); margin-bottom:8px; }
 input { font:inherit; width:100%; box-sizing:border-box; padding:7px; border:1px solid var(--line); border-radius:7px;
         background:var(--card); color:var(--fg); }
 @media (max-width: 800px) { main { grid-template-columns: 1fr; padding:16px; } aside { position:static; max-height:none; } }
</style></head><body><main>
 <div class="pagewrap" id="pw"><img id="img" alt="PDF page"><div class="region" id="region"></div><div class="box" id="box"></div></div>
 <aside>
  <div class="card" id="storewarn" hidden><b class="warn">This browser isn't saving your progress.</b>
   <p class="muted">Export often, or open this file in Chrome or Safari with normal (not private) browsing.</p></div>
  <div class="card" id="exportnag" hidden><b>Time to save a backup.</b>
   <p class="muted">Labels are saved in this browser, but a backup file protects them if browser data gets cleared.</p>
   <button class="small" id="nagexport">Export labels</button><button class="small" id="nagdismiss">Later</button></div>
  <div class="card" id="progress"></div>
  <div class="card"><span class="tag" id="settag"></span>
   <div class="text" id="line"></div><p class="muted" id="where"></p><p class="muted" id="sbsnote" hidden>
   The dashed box marks text laid out side by side. Label this line the same way as any other.</p></div>
  <div class="card" id="speakers" hidden><p><b>Who says it?</b> <span class="muted">letter key, or / to type</span></p>
   <p class="muted warn" id="namewarn" hidden>This line is just a name. If it's the name above a speech, press Esc, then 4.</p>
   <div id="names"></div><input id="other" placeholder="Other name, then Enter">
   <button id="unknown"><kbd>?</kbd>Can't see who says it, even on the previous page</button></div>
  <div class="card" id="together" hidden><p><b>Is it spoken at the same time as the text beside it?</b></p>
   <button data-t="yes"><kbd>y</kbd>Yes: both are heard at once</button>
   <button data-t="no"><kbd>n</kbd>No: one after the other, or it has nothing beside it</button>
   <button data-t="unsure"><kbd>u</kbd>Can't tell</button></div>
  <div class="card" id="kinds"></div>
  <div class="card"><button id="prevpage"><kbd>p</kbd>Show the previous page (to find who's speaking)</button>
   <button id="back"><kbd>&larr;</kbd>Back to the line before this one</button>
   <p class="muted">Every choice saves in this browser. Close the tab whenever you like; reopen this file to carry on.</p>
   <button class="small" id="export">Export labels</button><button class="small" id="restore">Load a backup</button>
   <input type="file" id="restorefile" accept=".json,application/json" hidden></div>
 </aside></main>
<script>
const DATA = __DATA__;
const KINDS = DATA.kinds, STORE = 'tableread-label-kit-v1';
const $ = id => document.getElementById(id);
let labels = {}, storeOK = true, pos = 0, step = null, pending = {}, showingPrev = false, sinceExport = 0;
const history = [];

function readStore() {
  try { labels = JSON.parse(localStorage.getItem(STORE) || '{}') || {}; sinceExport = Number(localStorage.getItem(STORE + '-since') || 0); }
  catch (e) { storeOK = false; labels = {}; }
}
function writeStore() {
  try { localStorage.setItem(STORE, JSON.stringify(labels)); localStorage.setItem(STORE + '-since', String(sinceExport)); }
  catch (e) { storeOK = false; }
  $('storewarn').hidden = storeOK;
}
const done = it => Boolean(labels[it.key]);
const nextOpen = (from) => { for (let i = 0; i < DATA.items.length; i++) { const j = (from + i) % DATA.items.length; if (!done(DATA.items[j])) return j; } return -1; };

function progress() {
  $('progress').innerHTML = Object.entries(DATA.sets).map(([s, title]) => {
    const all = DATA.items.filter(i => i.set === s), n = all.filter(done).length;
    return '<div><b>' + title + '</b> <span class="muted">' + n + ' of ' + all.length + '</span>' +
      '<div class="bar"><div style="width:' + (all.length ? 100 * n / all.length : 100) + '%"></div></div></div>';
  }).join('');
}
function show(i) {
  if (i < 0) return finished();
  pos = i; step = 'kind'; pending = {}; showingPrev = false;
  const it = DATA.items[i], lab = labels[it.key];
  $('speakers').hidden = true; $('together').hidden = true; $('kinds').hidden = false;
  $('settag').textContent = DATA.sets[it.set];
  $('line').textContent = it.text;
  $('where').textContent = it.pdf + ' \\u00b7 page ' + (it.page + 1) +
    (lab ? ' \\u00b7 labelled: ' + lab.label + (lab.speaker ? ' (' + lab.speaker + ')' : '') + (lab.together ? ', together: ' + lab.together : '') : '');
  $('sbsnote').hidden = it.set !== 'sbs';
  $('kinds').innerHTML = KINDS.map(k => '<button data-k="' + k[0] + '"><kbd>' + k[0] + '</kbd>' + k[2] + '</button>').join('');
  const names = DATA.names[it.pdf] || [];
  $('names').innerHTML = names.map((n, j) => '<button data-n="' + j + '"><kbd>' + String.fromCharCode(97 + j) + '</kbd>' + esc(n) + '</button>').join('');
  $('prevpage').innerHTML = '<kbd>p</kbd>Show the previous page (to find who\\u2019s speaking)';
  $('prevpage').disabled = !it.prev;
  drawPage(it.img, true);
  progress();
}
function drawPage(src, mark) {
  const it = DATA.items[pos], img = $('img');
  $('box').hidden = $('region').hidden = true;
  img.onload = () => {
    if (!mark) return;
    const s = img.clientWidth / it.w;
    place($('box'), it.bbox, s, 4, 3);
    if (it.region) place($('region'), it.region, s, 10, 8);
    $('box').scrollIntoView({block: 'center', behavior: 'instant'});
  };
  img.onerror = () => { $('where').innerHTML += '<br><span class="warn">The page image is missing. Keep the pages folder next to this file.</span>'; };
  img.src = 'pages/' + src;
}
function place(el, b, s, px, py) {
  el.style.left = (b[0] * s - px) + 'px'; el.style.top = (b[1] * s - py) + 'px';
  el.style.width = ((b[2] - b[0]) * s + 2 * px) + 'px'; el.style.height = ((b[3] - b[1]) * s + 2 * py) + 'px';
  el.hidden = false;
}
function save(lab) {
  const it = DATA.items[pos];
  labels[it.key] = Object.assign({label: lab.label}, lab.speaker ? {speaker: lab.speaker} : {}, lab.together ? {together: lab.together} : {});
  sinceExport++; writeStore();
  if (history[history.length - 1] !== pos) history.push(pos);
  $('exportnag').hidden = sinceExport < 50;
  show(nextOpen(pos + 1));
}
function chooseKind(key) {
  const k = KINDS.find(k => k[0] === key); if (!k) return;
  if (k[1] !== 'dialog') return save({label: k[1]});
  step = 'speaker'; pending = {label: 'dialog'};
  $('speakers').hidden = false; $('other').value = '';
  const bare = s => s.replace(/\\(.*?\\)/g, '').trim().replace(/[:.]+$/, '').toUpperCase();
  $('namewarn').hidden = !(DATA.names[DATA.items[pos].pdf] || []).some(n => bare(n) === bare(DATA.items[pos].text));
  $('speakers').scrollIntoView({block: 'nearest'});
}
function chooseSpeaker(name) {
  pending.speaker = name;
  if (DATA.items[pos].set !== 'sbs') return save(pending);
  step = 'together'; $('speakers').hidden = true; $('kinds').hidden = true; $('together').hidden = false;
}
function chooseTogether(v) { pending.together = v; save(pending); }
function back() {
  if (step === 'together') { step = 'speaker'; $('together').hidden = true; $('kinds').hidden = false; $('speakers').hidden = false; return; }
  if (!history.length) return;
  show(history.pop());
}
function togglePrev() {
  const it = DATA.items[pos]; if (!it || !it.prev) return;
  showingPrev = !showingPrev;
  drawPage(showingPrev ? it.prev : it.img, !showingPrev);
  $('prevpage').innerHTML = showingPrev ? '<kbd>p</kbd>Back to this line\\u2019s page' : '<kbd>p</kbd>Show the previous page (to find who\\u2019s speaking)';
  if (showingPrev) window.scrollTo({top: document.body.scrollHeight});
}
function exportLabels() {
  const stamp = new Date().toISOString().slice(0, 16).replace(/[-:]/g, '').replace('T', '-');
  const blob = new Blob([JSON.stringify({kind: 'table-read-labels', version: 1, exported: new Date().toISOString(), labels}, null, 1)], {type: 'application/json'});
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'table-read-labels-' + stamp + '.json';
  document.body.appendChild(a); a.click(); a.remove();
  sinceExport = 0; writeStore(); $('exportnag').hidden = true;
}
function restore(file) {
  file.text().then(t => {
    const d = JSON.parse(t);
    if (d.kind !== 'table-read-labels') throw new Error('not a labels export');
    const n = Object.keys(d.labels).filter(k => !labels[k]).length;
    labels = Object.assign({}, d.labels, labels); writeStore();
    alert('Loaded ' + n + ' labels from the backup.'); show(nextOpen(0));
  }).catch(e => alert('Could not read that file: ' + e.message));
}
function finished() {
  progress();
  document.querySelector('main').innerHTML = '<div class="card"><h2>Every line is labelled.</h2>' +
    '<p>Click <b>Export labels</b> below, then tell Claude to import your labels.</p>' +
    '<button class="small" id="export">Export labels</button></div>';
}
const esc = s => s.replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));

document.addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b) return;
  b.blur();
  if (b.dataset.k) chooseKind(b.dataset.k);
  if (b.dataset.n) chooseSpeaker((DATA.names[DATA.items[pos].pdf] || [])[Number(b.dataset.n)]);
  if (b.dataset.t) chooseTogether(b.dataset.t);
  if (b.id === 'unknown') chooseSpeaker('?');
  if (b.id === 'back') back();
  if (b.id === 'prevpage') togglePrev();
  if (b.id === 'export' || b.id === 'nagexport') exportLabels();
  if (b.id === 'nagdismiss') { $('exportnag').hidden = true; sinceExport = 25; writeStore(); }
  if (b.id === 'restore') $('restorefile').click();
});
$('restorefile').addEventListener('change', e => { if (e.target.files[0]) restore(e.target.files[0]); e.target.value = ''; });
document.addEventListener('keydown', e => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.target === $('other')) {
    if (e.key === 'Enter' && $('other').value.trim()) chooseSpeaker($('other').value.trim().toUpperCase());
    if (e.key === 'Escape') $('other').blur();
    return;
  }
  if (e.key === 'ArrowLeft') return back();
  if (e.key === 'p') return togglePrev();
  if (step === 'together') { const v = {y: 'yes', n: 'no', u: 'unsure'}[e.key]; if (v) chooseTogether(v); return; }
  if (step === 'speaker') {
    if (e.key === '?') return chooseSpeaker('?');
    if (e.key === '/') { e.preventDefault(); return $('other').focus(); }
    if (e.key === 'Escape') { step = 'kind'; $('speakers').hidden = true; return; }
    if (/^[a-o]$/.test(e.key)) { const n = (DATA.names[DATA.items[pos].pdf] || [])[e.key.charCodeAt(0) - 97]; if (n) chooseSpeaker(n); return; }
  }
  chooseKind(e.key);
});
window.addEventListener('resize', () => { if (!showingPrev && DATA.items[pos]) drawPage(DATA.items[pos].img, true); });
readStore(); writeStore();
show(nextOpen(0));
</script></body></html>"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--import", dest="imp", nargs="?", const="", metavar="FILE",
                    help="import an export (default: the newest in ~/Downloads)")
    args = ap.parse_args()
    if args.imp is not None:
        return import_labels(Path(args.imp).expanduser() if args.imp else None)
    return build()


if __name__ == "__main__":
    sys.exit(main())
