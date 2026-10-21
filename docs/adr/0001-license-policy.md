# 0001 — License policy: two tiers

Status: accepted (2026-10-21, Avery)

## Context
Table Read is moving to one shared Rust core used by the Flutter desktop app and the iPhone
companion. The Python backend leans on PyMuPDF (AGPL) and espeak-ng (GPL). Both apps are free.
The desktop app can be open source; the iPhone app must be App Store eligible eventually.
GPL obligations apply to distribution through any channel, and Apple's terms do not fit GPL.

## Decision
1. **Tier 1: shared core + iPhone app** (parser, cues, sync, UI shared with iOS). Third-party
   dependencies must be permissive: MIT, BSD, ISC, Apache-2.0, MPL-2.0, CC BY, CC0, public domain.
   No GPL, AGPL, LGPL. Credits for everything used appear on a generated Licenses screen.
2. **Tier 2: desktop-only rendering crate.** May link GPL code (espeak-ng, Piper's engine). The
   desktop app is open source under GPL-3.0. GPL code never enters a Tier 1 crate or the iPhone build.
3. Avery is the sole copyright holder of the project's own code and ships it under GPL-3.0 on desktop
   and a permissive license on iPhone. Outside code is not merged without a CLA (issues and bug
   reports only for now).
4. Both apps are free. Non-commercial-licensed voices are only usable while that stays true; they
   must be removed before any change. CC BY-NC-SA voices (Piper `ryan`) are excluded regardless.
5. `scripts/check_licenses.py` enforces tier 1 (runs in `bash scripts/test.sh rust`; crates opt in with `[package.metadata] license-tier = "permissive"`). It reads `cargo metadata`, evaluates each crate's SPDX expression (`A OR B` needs one allowed side, `A AND B` both) and fails on anything else. We wrote it instead of using `cargo-deny` because Rust binaries cannot be installed or fetch crates on the sandboxed dev Mac; swap to `cargo-deny` later if wanted.
6. PDF extraction is PDFium (`pdfium-render`, BSD/Apache + MIT/Apache), not PyMuPDF.

## Consequences
- `LICENSE` (personal-use, no redistribution) is replaced when this ships (#109).
- Piper stays on desktop only; Piper voice licenses must be verified per voice (lessac unverified).
- A lawyer should read the Tier 2 setup before anything is distributed widely.
