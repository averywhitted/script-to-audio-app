"""Compare the Rust char dump with the Python prototype's. Usage: compare_chars.py rust.json python.json"""
import json, sys, difflib
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
bad = tot = pages_off = 0; maxd = 0.0
for n, (pa, pb) in enumerate(zip(a["pages"], b["pages"])):
    ca, cb = pa["chars"], pb["chars"]
    if len(ca) != len(cb):
        pages_off += 1
        if pages_off <= 2:
            sa, sb = "".join(c["c"] for c in ca), "".join(c["c"] for c in cb)
            for op in difflib.SequenceMatcher(None, sa, sb, autojunk=False).get_opcodes():
                if op[0] != "equal": print("page", n, op, repr(sa[op[1]:op[2]]), repr(sb[op[3]:op[4]]))
        continue
    for x, y in zip(ca, cb):
        tot += 1
        if x["c"] != y["c"] or x["font"] != y["font"] or x["italic"] != y["italic"] or x["bold"] != y["bold"] or x["gen"] != y["gen"]:
            bad += 1; continue
        for k in ("l", "r", "t", "b", "ox", "oy", "size", "asc", "desc"):
            if y[k] is not None: maxd = max(maxd, abs(x[k] - y[k]))
print(f"pages {len(a['pages'])}, pages with different char count {pages_off}, chars compared {tot}, mismatched {bad}, max numeric diff {maxd:.3f}")
