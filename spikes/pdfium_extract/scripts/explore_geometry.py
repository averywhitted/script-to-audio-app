import json, sys, collections, statistics as st
from pathlib import Path
out = Path("out")
for stem in sys.argv[1:]:
    ref = json.load(open(out/f"{stem}.pymupdf.json")); ch = json.load(open(out/f"{stem}.chars.json"))
    asc = collections.defaultdict(list); desc = collections.defaultdict(list); sizeerr=[]; fontmis=collections.Counter(); itmis=0; n=0
    for pi, (rp, cp) in enumerate(zip(ref["pages"], ch["pages"])):
        chars = cp["chars"]
        for b in rp["blocks"]:
            for ln in b["lines"]:
                x0,y0,x1,y1 = ln["bbox"]
                inside = [c for c in chars if x0-0.5 <= (c["l"]+c["r"])/2 <= x1+0.5 and y0-0.5 <= (c["t"]+c["b"])/2 <= y1+0.5 and c["c"].strip()]
                if not inside or not ln["spans"]: continue
                sp = ln["spans"][0]
                c = inside[0]
                asc[sp["font"]].append((c["oy"]-y0)/sp["size"]); desc[sp["font"]].append((y1-c["oy"])/sp["size"])
                sizeerr.append(c["size"]-sp["size"]); n+=1
                if c["italic"]!=sp["italic"]: itmis+=1
    print(stem, "lines", n, "size err mean %.3f max %.3f"%(st.mean(sizeerr), max(map(abs,sizeerr))), "italic mismatches", itmis)
    for f in list(asc)[:6]:
        print("  ", f, "asc %.3f±%.3f desc %.3f±%.3f (n=%d)"%(st.mean(asc[f]), st.pstdev(asc[f]), st.mean(desc[f]), st.pstdev(desc[f]), len(asc[f])))
