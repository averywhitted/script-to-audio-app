#!/usr/bin/env python3
"""Build a cargo `local-registry` from crates.io using only Python's HTTP client.

Why: on the sandboxed dev Mac, Rust-built binaries (cargo, rustup) cannot resolve DNS while Python and curl can,
so `cargo` cannot reach crates.io. This fetches the index entries and .crate files for the dependency closure of
the named crates into a directory that cargo can use offline:

    python3 scripts/local_crate_mirror.py <mirror-dir> pdfium-render serde "serde_json=1" [--features pkg:feat,feat]
    cargo build --offline \\
      --config 'source.crates-io.replace-with="local-mirror"' \\
      --config 'source.local-mirror.local-registry="<mirror-dir>"'

Each argument is `name` or `name=<semver requirement>`. Optional dependencies are followed only when a default
(or --features) feature enables them. Cargo picks among the versions mirrored (the highest matching each requirement).
"""
import hashlib
import json
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

INDEX = "https://index.crates.io"
CRATES = "https://static.crates.io/crates"


def index_path(name):
    n = name.lower()
    if len(n) == 1:
        return f"1/{n}"
    if len(n) == 2:
        return f"2/{n}"
    if len(n) == 3:
        return f"3/{n[0]}/{n}"
    return f"{n[:2]}/{n[2:4]}/{n}"


def get(url):
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read()
        except Exception as e:  # retry transient errors
            err = e
    raise RuntimeError(f"{url}: {err}")


def ver(s):
    m = re.match(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?", s)
    return (int(m[1]), int(m[2]), int(m[3])), m[4]


def key(s):
    v, pre = ver(s)
    return (v, pre is None, pre or "")


def matches(version, req):
    v, pre = ver(version)
    if pre and not re.search(r"-\w", req):
        return False
    for part in [p.strip() for p in req.split(",") if p.strip()]:
        if part == "*":
            continue
        m = re.match(r"(\^|~|=|>=|<=|>|<)?\s*(\d+)(?:\.(\d+|\*))?(?:\.(\d+|\*))?", part)
        op = m[1] or "^"
        nums = [int(x) if x and x != "*" else None for x in (m[2], m[3], m[4])]
        lo = tuple(x or 0 for x in nums)
        if op == "=":
            if not all(n is None or n == c for n, c in zip(nums, v)):
                return False
        elif op == ">=":
            if v < lo:
                return False
        elif op == ">":
            if v <= lo:
                return False
        elif op == "<=":
            if v > tuple(x if x is not None else 10**9 for x in nums):
                return False
        elif op == "<":
            if v >= lo:
                return False
        elif op == "~":
            if v < lo or v[0] != lo[0] or (nums[1] is not None and v[1] != lo[1]):
                return False
        else:  # caret
            if v < lo:
                return False
            if nums[0]:
                if v[0] != lo[0]:
                    return False
            elif nums[1] is not None and nums[1]:
                if v[0] != 0 or v[1] != lo[1]:
                    return False
            elif nums[2] is not None:
                if v[:2] != lo[:2] or v[2] != lo[2]:
                    return False
            elif nums[1] is None:
                if v[0] != 0:
                    return False
            else:
                if v[:2] != (0, 0):
                    return False
    return True


def enabled_optionals(entry, extra):
    feats = entry.get("features2", {}) | entry.get("features", {})
    on, todo = set(), ["default"] + list(extra)
    seen = set()
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        for item in feats.get(f, []):
            name = item.removeprefix("dep:").split("/")[0].rstrip("?")
            if "/" in item and not item.startswith("dep:"):
                on.add(name)
            if item.startswith("dep:") or name not in feats:
                on.add(name)
            else:
                todo.append(name)
    return on


def main():
    args = sys.argv[1:]
    extra = {}
    if "--features" in args:
        i = args.index("--features")
        for spec in args[i + 1].split(";"):
            pkg, _, fs = spec.partition(":")
            extra[pkg] = fs.split(",")
        del args[i:i + 2]
    root = Path(args[0]).resolve()
    (root / "index").mkdir(parents=True, exist_ok=True)
    want = [(a.partition("=")[0], a.partition("=")[2] or "*") for a in args[1:]]
    cache, chosen, queue = {}, {}, list(want)
    while queue:
        name, req = queue.pop()
        if name not in cache:
            cache[name] = [json.loads(l) for l in get(f"{INDEX}/{index_path(name)}").decode().splitlines() if l.strip()]
        # An exact pin (`name==1.2.3`, from Cargo.lock) may be yanked: cargo still builds a locked yanked version.
        cands = [e for e in cache[name] if (req.startswith("=") or not e["yanked"]) and matches(e["vers"], req)]
        if not cands:
            print(f"warn: no version of {name} matches {req}", file=sys.stderr)
            continue
        best = max(cands, key=lambda e: key(e["vers"]))
        if best["vers"] in chosen.setdefault(name, {}):
            continue
        chosen[name][best["vers"]] = best
        optional_on = enabled_optionals(best, extra.get(name, []))
        for d in best["deps"]:
            if d["kind"] == "dev" or (d["optional"] and d["name"] not in optional_on and d.get("package", d["name"]) not in optional_on):
                continue
            queue.append((d.get("package") or d["name"], d["req"]))
    jobs = []
    for name, vs in chosen.items():
        p = root / "index" / index_path(name)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("\n".join(json.dumps(e, separators=(",", ":")) for e in vs.values()) + "\n")
        for v, e in vs.items():
            jobs.append((name, v, e["cksum"]))

    def fetch(job):
        name, v, ck = job
        f = root / f"{name}-{v}.crate"
        if f.exists() and hashlib.sha256(f.read_bytes()).hexdigest() == ck:
            return
        data = get(f"{CRATES}/{name}/{name}-{v}.crate")
        if hashlib.sha256(data).hexdigest() != ck:
            raise RuntimeError(f"checksum mismatch for {name} {v}")
        f.write_bytes(data)

    with ThreadPoolExecutor(8) as ex:
        list(ex.map(fetch, jobs))
    print(f"mirrored {len(jobs)} crate versions ({len(chosen)} crates) into {root}")


if __name__ == "__main__":
    main()
