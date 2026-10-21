"""Prototype line/span builder over out/<stem>.chars.json, scored against out/<stem>.pymupdf.json."""
import json, math, re, sys, collections
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "out"
# MuPDF's own line-box metrics for the 14 standard (non-embedded) PDF fonts, as ascent/descent in em
# above/below the baseline. Measured from PyMuPDF output (scripts in this spike); embedded fonts use PDFium's.
BASE14 = json.load(open(Path(__file__).resolve().parent.parent / "base14_metrics.json"))


def rotated(c):
    """Near-vertical text. PDFium also reports italic shear as an 'angle' (0.32 rad on Kill Floor) while the
    baseline stays horizontal, so only a large angle counts as rotated."""
    return abs(math.sin(c.get("ang", 0))) > 0.7


def build_lines(chars, back=0.5, drift=0.3, keep_blank=False, jump=2.0, space_gap=0.1):
    lines, cur = [], []
    for c in chars:
        if c["font"] in BASE14:
            c = dict(c, asc=BASE14[c["font"]][0], desc=-BASE14[c["font"]][1])
        elif c["asc"] is None:
            c = dict(c, asc=0.8, desc=-0.2)
        if c["gen"]:  # PDFium-inserted space: joins the current line, never decides a break
            if cur:
                cur.append(c)
            continue
        if cur:
            p = [x for x in cur if not x["gen"]][-1]
            sz = max(c["size"], p["size"], 1)  # PDFium's inserted spaces report size 1.0
            if rotated(c) or rotated(p):
                # rotated text: compare along/across the baseline direction instead of x/y
                a = p.get("ang", 0)
                ux, uy = math.cos(a), math.sin(a)  # baseline direction in y-down device space (PDFium's angle runs clockwise)
                dx, dy = c["ox"] - p["ox"], c["oy"] - p["oy"]
                along, across = dx * ux + dy * uy, -dx * uy + dy * ux
                same = (abs(c.get("ang", 0) - a) < 0.05 and abs(across) <= drift * sz
                        and -back * sz <= along <= (1 + jump) * sz)
            else:
                same = (abs(c["oy"] - p["oy"]) <= drift * sz and c["l"] >= p["r"] - back * sz
                        and (c["l"] - p["r"]) <= jump * sz)
            if same and c["gen"] and c["c"] == " " and (c["r"] - c["l"]) > jump * sz:
                same = False
            if not same:
                lines.append(cur); cur = []
            elif (not rotated(c) and c["c"] != " " and p["c"] != " " and cur[-1]["c"] != " "
                  and (c["l"] - p["r"]) > space_gap * sz):
                cur.append(dict(p, c=" ", gen=True, l=p["r"], r=c["l"]))  # MuPDF spaces by gap too
        cur.append(c)
    if cur:
        lines.append(cur)
    out = []
    for ln in lines:
        text = "".join(c["c"] for c in ln)
        if not text.strip() and not (keep_blank and text):
            continue
        # PyMuPDF trims nothing in span text but the parser strips; compare stripped
        base = ln[0]["oy"]
        sz = max(c["size"] for c in ln)
        a = max(c["asc"] * c["size"] for c in ln)
        d = max(-c["desc"] * c["size"] for c in ln)
        spans, sp = [], None
        for c in ln:
            key = (c["font"], round(c["size"], 2), c["italic"], c["bold"])
            if sp is None or sp["key"] != key:
                sp = {"key": key, "text": "", "font": c["font"], "size": c["size"], "italic": c["italic"], "bold": c["bold"]}
                spans.append(sp)
            sp["text"] += c["c"]
        if rotated(ln[0]):
            bbox = [min(min(c["l"], c["r"]) for c in ln), min(min(c["t"], c["b"]) for c in ln),
                    max(max(c["l"], c["r"]) for c in ln), max(max(c["t"], c["b"]) for c in ln)]
        else:
            bbox = [min(c["l"] for c in ln), base - a, max(c["r"] for c in ln), base + d]
        out.append({"bbox": bbox,
                    "text": text.strip(), "spans": spans})
    return out


def norm(t):
    return re.sub(r"\s+", " ", t).strip()


def score(stem, **kw):
    ref = json.load(open(OUT / f"{stem}.pymupdf.json")); ch = json.load(open(OUT / f"{stem}.chars.json"))
    tot = hit = textonly = mine_tot = 0
    ex = []
    for rp, cp in zip(ref["pages"], ch["pages"]):
        mine = build_lines(cp["chars"], **kw)
        mine_tot += len(mine)
        pool = collections.defaultdict(list)
        for m in mine:
            pool[norm(m["text"])].append(m)
        for b in rp["blocks"]:
            for ln in b["lines"]:
                t = norm("".join(s["text"] for s in ln["spans"]))
                if not t:
                    continue
                tot += 1
                cands = pool.get(t, [])
                if cands:
                    textonly += 1
                    x0, y0, x1, y1 = ln["bbox"]
                    ok = [m for m in cands if abs(m["bbox"][0]-x0) < 1.5 and abs(m["bbox"][1]-y0) < 1.0 and abs(m["bbox"][3]-y1) < 1.0 and abs(m["bbox"][2]-x1) < 2.5]
                    if ok:
                        hit += 1
                    elif len(ex) < 4:
                        ex.append(("geom", t[:40], [round(v, 1) for v in ln["bbox"]], [round(v, 1) for v in cands[0]["bbox"]]))
                elif len(ex) < 4:
                    ex.append(("text", t[:60]))
    return tot, hit, textonly, mine_tot, ex


if __name__ == "__main__":
    for stem in sys.argv[1:]:
        tot, hit, to, mt, ex = score(stem)
        print(f"{stem}: ref lines {tot}, text match {to/tot:.1%}, text+geometry {hit/tot:.1%}, mine {mt}")
        for e in ex:
            print("   ", e)
