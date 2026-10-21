"""Prototype (Python/pypdfium2, same PDFium as the Rust spike): dump per-char data.

Writes out/<stem>.chars.json = pages -> chars [{c, l, t, r, b (top-left origin pt), ox, oy (origin),
size (scaled), font, italic, bold, weight}] in stream order. Used to design the block builder before
porting it to Rust (pdfium-render).
Usage: python proto_chars.py <pdf> <outdir>
"""
import ctypes
import json
import sys
from pathlib import Path

import pypdfium2 as pdfium
import pypdfium2.raw as raw

FLAG_ITALIC = 0x40
FLAG_FORCEBOLD = 0x40000


SCALE = 100  # device pixels per point, so the integer-size API keeps sub-point precision


def make_to_device(page):
    w, h = page.get_size()
    rot = page.get_rotation() // 90
    dx, dy = ctypes.c_int(), ctypes.c_int()

    def to_dev(x, y):
        raw.FPDF_PageToDevice(page, 0, 0, int(round(w * SCALE)), int(round(h * SCALE)), 0 if rot is None else 0,
                              x, y, ctypes.byref(dx), ctypes.byref(dy))
        return dx.value / SCALE, dy.value / SCALE
    return to_dev


def page_chars(page):
    w, h = page.get_size()
    to_dev = make_to_device(page)
    tp = page.get_textpage()
    n = tp.count_chars()
    out = []
    # content-stream position of every text object (PDFium's text page re-orders; MuPDF keeps stream order)
    obj_index, obj_ptrs = {}, {}
    for k in range(raw.FPDFPage_CountObjects(page)):
        o = raw.FPDFPage_GetObject(page, k)
        if raw.FPDFPageObj_GetType(o) == raw.FPDF_PAGEOBJ_TEXT:
            addr = ctypes.cast(o, ctypes.c_void_p).value
            obj_index[addr] = k
            obj_ptrs[k] = o
    last_obj = -1
    used = set()
    buf = ctypes.create_string_buffer(256)
    flags = ctypes.c_int()
    mat = raw.FS_MATRIX()
    ox, oy = ctypes.c_double(), ctypes.c_double()
    for i in range(n):
        ch = tp.get_text_range(i, 1)
        gen = bool(raw.FPDFText_IsGenerated(tp, i))
        if not ch or (gen and ch != " "):
            continue  # keep PDFium's inserted spaces, drop its inserted newlines/hyphens
        l, b, r, t = tp.get_charbox(i)
        rect = raw.FS_RECTF()
        if raw.FPDFText_GetLooseCharBox(tp, i, ctypes.byref(rect)):
            l, r = rect.left, rect.right  # advance-based extent, as MuPDF uses
        raw.FPDFText_GetFontInfo(tp, i, buf, 256, ctypes.byref(flags))
        raw.FPDFText_GetMatrix(tp, i, ctypes.byref(mat))
        raw.FPDFText_GetCharOrigin(tp, i, ctypes.byref(ox), ctypes.byref(oy))
        unscaled = raw.FPDFText_GetFontSize(tp, i)
        # text-matrix scale: size = unscaled * sqrt(|det|)
        det = abs(mat.a * mat.d - mat.b * mat.c)
        scale = det ** 0.5 if det else 1.0  # uniform scale of the text matrix, also for rotated text
        font = buf.value.decode("latin-1")
        weight = raw.FPDFText_GetFontWeight(tp, i)
        asc = desc = None
        obj = raw.FPDFText_GetTextObject(tp, i)
        oidx = obj_index.get(ctypes.cast(obj, ctypes.c_void_p).value, last_obj) if obj else last_obj
        last_obj = oidx
        used.add(oidx)
        if obj:
            f = raw.FPDFTextObj_GetFont(obj)
            a, d = ctypes.c_float(), ctypes.c_float()
            raw.FPDFFont_GetAscent(f, 1.0, ctypes.byref(a)); raw.FPDFFont_GetDescent(f, 1.0, ctypes.byref(d))
            asc, desc = a.value, d.value
        (dl, dt), (dr, db), (dox, doy) = to_dev(l, t), to_dev(r, b), to_dev(ox.value, oy.value)
        out.append({
            "c": ch, "l": dl, "r": dr, "t": dt, "b": db,
            "ox": dox, "oy": doy,
            "size": unscaled * scale, "font": font,
            "italic": bool(flags.value & FLAG_ITALIC) or "italic" in font.lower() or "oblique" in font.lower(),
            "bold": bool(flags.value & FLAG_FORCEBOLD) or weight >= 600 or "bold" in font.lower(),
            "obj": oidx, "weight": weight, "gen": gen, "ang": raw.FPDFText_GetCharAngle(tp, i), "asc": asc, "desc": desc,
        })
    # text objects the text page dropped (typically a lone " " glyph after a line, or a blank line)
    for k, o in obj_ptrs.items():
        if k in used:
            continue
        m = raw.FS_MATRIX()
        raw.FPDFPageObj_GetMatrix(o, ctypes.byref(m))
        fs = ctypes.c_float()
        raw.FPDFTextObj_GetFontSize(o, ctypes.byref(fs))
        det = abs(m.a * m.d - m.b * m.c)
        size = fs.value * (det ** 0.5 if det else 1.0)
        f = raw.FPDFTextObj_GetFont(o)
        a, d = ctypes.c_float(), ctypes.c_float()
        raw.FPDFFont_GetAscent(f, 1.0, ctypes.byref(a)); raw.FPDFFont_GetDescent(f, 1.0, ctypes.byref(d))
        nb = ctypes.create_string_buffer(256)
        raw.FPDFFont_GetBaseFontName(f, nb, 256)
        fname = nb.value.decode("latin-1")
        flags = raw.FPDFFont_GetFlags(f)
        dox, doy = to_dev(m.e, m.f)
        out.append({
            "c": " ", "l": dox, "r": dox + 0.25 * size, "t": doy - a.value * size, "b": doy - d.value * size,
            "ox": dox, "oy": doy, "size": size, "font": fname,
            "italic": bool(flags & FLAG_ITALIC) or "italic" in fname.lower() or "oblique" in fname.lower(),
            "bold": "bold" in fname.lower(), "weight": 0, "obj": k, "gen": False, "ang": 0.0,
            "asc": a.value, "desc": d.value, "empty_obj": True,
        })
    out.sort(key=lambda c: c["obj"])  # stable: keeps text-page order inside an object
    return {"w": w, "h": h, "chars": out}


if __name__ == "__main__":
    pdf, outdir = Path(sys.argv[1]), Path(sys.argv[2])
    doc = pdfium.PdfDocument(str(pdf))
    pages = [page_chars(doc[i]) for i in range(len(doc))]
    (outdir / f"{pdf.stem}.chars.json").write_text(json.dumps({"pages": pages}))
