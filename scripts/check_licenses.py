#!/usr/bin/env python3
"""check_licenses.py — enforce docs/adr/0001-license-policy.md on the Rust workspace.

Every workspace crate marked `[package.metadata] license-tier = "permissive"` (shared core + iPhone) and everything it
depends on (normal and build dependencies, all platforms) must be under permissive licenses only: MIT, BSD, ISC,
Apache-2.0, MPL-2.0, Zlib, Unicode, CC0 and the like. GPL/AGPL/LGPL never. A crate marked "gpl" (desktop-only
rendering) is exempt. `A OR B` passes if either side is allowed; `A AND B` needs both.

Usage: python3 scripts/check_licenses.py [--list]   (set MIRROR=<dir> to read crates from the local registry mirror,
see scripts/local_crate_mirror.py)
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUST = ROOT / "rust"

ALLOWED = {
    "MIT", "MIT-0", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib", "MPL-2.0", "0BSD", "Unlicense",
    "CC0-1.0", "BSL-1.0", "Unicode-3.0", "Unicode-DFS-2016", "BlueOak-1.0.0", "CDLA-Permissive-2.0",
}

# Crates whose metadata cannot be read automatically. Each needs a reason. (Keep this empty if you can.)
EXCEPTIONS: dict[str, str] = {}


def metadata() -> dict:
    mirror = os.environ.get("MIRROR")
    cmd = ([str(RUST / "cargo-offline.sh")] if mirror else [str(Path.home() / ".cargo/bin/cargo")]) + [
        "metadata", "--format-version", "1"]
    if not Path(cmd[0]).exists():
        cmd[0] = "cargo"
    return json.loads(subprocess.run(cmd, cwd=RUST, capture_output=True, text=True, check=True).stdout)


def tokens(expr: str) -> list[str]:
    expr = expr.replace("/", " OR ")
    return re.findall(r"\(|\)|[A-Za-z0-9.+-]+", expr)


def allowed(expr: str) -> bool:
    toks = tokens(expr)
    pos = 0

    def parse_or() -> bool:
        nonlocal pos
        val = parse_and()
        while pos < len(toks) and toks[pos].upper() == "OR":
            pos += 1
            rhs = parse_and()
            val = val or rhs
        return val

    def parse_and() -> bool:
        nonlocal pos
        val = parse_atom()
        while pos < len(toks) and toks[pos].upper() == "AND":
            pos += 1
            rhs = parse_atom()
            val = val and rhs
        return val

    def parse_atom() -> bool:
        nonlocal pos
        if toks[pos] == "(":
            pos += 1
            val = parse_or()
            pos += 1  # ")"
            return val
        ident = toks[pos].rstrip("+")
        pos += 1
        if pos < len(toks) and toks[pos].upper() == "WITH":  # license exception: judged by the base license
            pos += 2
        return ident in ALLOWED

    return bool(toks) and parse_or()


def main() -> int:
    meta = metadata()
    pkgs = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    members = [pkgs[i] for i in meta["workspace_members"]]
    checked: dict[str, dict] = {}
    for m in members:
        tier = (m.get("metadata") or {}).get("license-tier")
        if tier != "permissive":
            print(f"skip {m['name']}: license-tier = {tier!r}")
            continue
        stack, seen = [m["id"]], set()
        while stack:
            pid = stack.pop()
            if pid in seen:
                continue
            seen.add(pid)
            for d in nodes[pid]["deps"]:
                if any(k["kind"] in (None, "build") for k in d["dep_kinds"]):
                    stack.append(d["pkg"])
        for pid in seen:
            if pid not in meta["workspace_members"]:
                checked[pid] = pkgs[pid]
    bad = []
    for p in sorted(checked.values(), key=lambda p: p["name"]):
        lic = p.get("license")
        name = f"{p['name']} {p['version']}"
        if "--list" in sys.argv:
            print(f"{name}: {lic}")
        if p["name"] in EXCEPTIONS:
            continue
        if not lic:
            bad.append(f"{name}: no license field")
        elif not allowed(lic):
            bad.append(f"{name}: {lic}")
    print(f"checked {len(checked)} dependencies of permissive-tier crates")
    if bad:
        print("\n✗ not permissive (docs/adr/0001-license-policy.md):")
        for b in bad:
            print("   ", b)
        return 1
    print("✓ all permissive")
    return 0


if __name__ == "__main__":
    sys.exit(main())
