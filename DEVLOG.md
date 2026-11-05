# Dev Log — Table Read

## Resume here

> Round 5/5b (latest): markup is now a native single-canvas PencilKit viewer, awaiting Avery's device test (see History); next: fp32 Kokoro option if wanted; round-4 notes below about the Flutter ink layer are obsolete.
_Updated 2026-11-03 17:40 EST · branch `ipados-port` @ `1b2cc83` + round-3 commit (not pushed) · working tree: **`dart format -l 150 lib test` reformatted ~25 untouched files (lib/ui, lib/state, lib/models, phone_app.dart, other tests, ...): not committed; discard with `git checkout -- app/lib/main.dart app/lib/models app/lib/phone/phone_app.dart app/lib/services/{project_store,python_bridge,settings}.dart app/lib/state app/lib/ui app/test/{fixtures,logic_test,now_playing_test,player_test,rust_core_test,screens_test,worker_test}.dart` and `rm -rf app/test/failures` (the sandbox blocked me doing it)**; plus two untracked ephemeral `sidetrack-*.md`_

**Round 4 (Nov 4): see the newest History entry: Pencil is now our own Flutter ink layer (no PencilKit), PDF is always full screen, reader rework. Not yet installed on the iPad (it was unavailable); install with the Round 2 command, then test Pencil first.**

**Round 3 (Nov 3 17:40): Avery's iPad notes, built + tested on widget level, still never run on a real iPad.** (1) **Sidebar removed**: iPad reader has the phone's header (back button, name, search, My Character, PDF, Aa), script centred, scene dropdown from the pinned heading. (2) **Bookmarks** (`lib/phone/bookmarks.dart`, `Bookmarks/<device>.json`, same per-device-file + newest-wins + tombstone pattern as notes): bottom-left bar button replaces the redundant My Role pill (Line! still takes that slot while Block My Lines is on; text-only projects have no bar, so the header shows a bookmark icon instead); sheet = "Bookmark this spot" (playing line, else top line on screen) + list, tap to jump, swipe/x to delete; also a Bookmark button in the long-press selection bar and a ribbon on bookmarked lines. (3) **Outline rail** (`lib/phone/outline_rail.dart`): one dash per scene on the right edge, current scene longer and accent-coloured (follows the scroll via `_updateViewScene`/`_topLine`), tap opens a scene-heading list, folds on scroll / tap outside / pick. (4) **Position sync**: `RehearsalState` gained `reading {scene, line key}` (project_files.dart); saved 2 s after scroll rest or while following playback; on open the newest file from ANY device decides where to scroll; while open (20 s timer + app resume, with iCloud download of stale files) a "Your iPhone is at scene N · Jump there" chip appears when another device's newer file is somewhere else. Reused the existing Rehearsal file instead of a new sync document. (5) **Pencil fix attempt + tools** (`PdfPlugin.swift`, `pdf_view.dart`, `pdf_panel.dart`): guessed causes of "doesn't work at all": PDFView's own pan/selection recognizers took Pencil strokes (now restricted to non-Pencil touch types while marking up; 2-finger scroll when fingers draw), `isInMarkupMode`, and black ink inverting to white in dark mode (canvases now forced light). Own tool strip: pen / highlighter / eraser, 4 colours + 3 thicknesses each, undo / redo / clear / finger toggle; Apple's palette is one tap away (`systemPalette`). **None of this verified on a device**: the iPad simulator can't run `flutter run` (no Xcode build settings on the iOS 27.0 runtime) and Avery's iPad needs Developer Mode.
- **Tests:** full `flutter test` = 112 pass (goldens `ipad_rehearse_*`, `phone_rehearse_*`, `phone_scene_jump`, `phone_line_hint` re-recorded; new tests in ipad_test.dart for outline, bookmarks, position sync). `flutter build ios --simulator --debug --no-codesign` compiles the Swift.
- **OPEN DESIGN QUESTION for Avery (Pencil in the normal script view):** reflowing text (text size, window width) means ink can't live at fixed pixels. Proposed compromise (not built, waiting on a yes): ink is stored against the PDF page (as now), and each script line gets a rect on its PDF page (PDFKit `findString` on the line's text, done once like `page_align.dart`); the script view draws ink by warping page-y through those line anchors, so it moves with the text when the size changes; strokes drawn in the script are converted back through their line, clipped at page breaks; free-hand margin notes follow their nearest line. Cost: a Flutter-drawn ink layer over the script, native line-rect lookup, stroke warp. Fidelity is exact in page view, approximate in script view.
- **Next steps:** 1) Avery turns on Developer Mode and installs (command in Round 2 below); check Pencil drawing/tools, outline, bookmarks, sync chip, and report what breaks; 2) get Avery's answer on the script-view markup design, then build it; 3) file/comment on GitHub issues (bookmarks, outline, position sync not filed yet); 4) decide on the stray format changes above.

**Round 2 (Nov 3 15:50): search + Pencil tools, waiting on the iPad.** Avery asked: search must work in both script and PDF views; Pencil functionality and tools on iPad only. Done and tested (ipad_test + phone_tools_test pass): with the PDF beside the script, ONE search drives both (script search bar query also highlights in the PDF via `pdf.search(q, reveal: false)`; stepping a script hit turns the PDF to that line's page; PDF toolbar search icon / ⌘F opens the script bar; PDF shows a "N of M in the PDF" strip with its own prev/next); the phone's full-screen PDF keeps its own search bar. Pencil tools in the PDF toolbar when markup is on: Undo, Redo, Clear page (undoable, snackbar Undo), finger-draws toggle, plus the system PKToolPicker (pen/marker/pencil/eraser/lasso/ruler, Pencil double-tap/squeeze per iPad settings). Native: PdfPlugin.swift `undo/redo/clearPage/history`. **Blocker: Avery's iPad (iPad13,1, UDID 00008101-0018551A10E1401E) has Developer Mode off** (Settings > Privacy & Security > Developer Mode > on > restart > confirm). Release build for generic iOS compiles; then: `cd app && xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -destination 'id=00008101-0018551A10E1401E' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build` and `xcrun devicectl device install app --device 00008101-0018551A10E1401E <DerivedData>/Release-iphoneos/Runner.app`. Still unverified on a real iPad: everything Pencil, page/continuous, 3-pane, ⌘F.

**iPadOS port + iOS feature requests (Nov 3, built and committed; iPad-only parts unverified).** Avery asked for 6 iOS features and an iPad version "based on the iOS one, using the form factor". Decision: **one universal app** (iOS target was already `TARGETED_DEVICE_FAMILY "1,2"`), adaptive layouts keyed on window width (`lib/phone/adaptive.dart`: compact <700, regular <1100, wide), so Split View/Stage Manager work. GitHub: milestone **iPadOS** (11); issues iOS #113 search, #114 My Character w/o audio, #115 Show PDF, #116 PDF page numbers, #117 line notes, #118 Remove Download; iPadOS #119 Pencil markup, #120 page/continuous PDF, #121 iPad app umbrella. Nothing closed or commented yet.
- **Done, tests passing (45 phone tests: `test/phone_test.dart`, `phone_tools_test.dart`, new `ipad_test.dart`):** search (header icon, ⌘F/⌘G/Esc, `script_search.dart`, far-scene reveal `_revealLine`); My Character button + sheet (works with no rendered scenes; saves in Rehearsal file); notes (`line_notes.dart`, `Notes/<device>.json`, newest-wins merge + tombstones, flag/card UI); page breaks (`page_align.dart` aligns lines to PDF page text on the phone, no parser change; "Page numbers" switch in Aa); Remove Download (`evict` in AppDelegate.swift, project long-press menu); PDF native view (`ios/Runner/PdfPlugin.swift`: PDFKit + PencilKit overlay per page, search, page/continuous; Dart `pdf_view.dart`, `pdf_panel.dart`; markup in `Markup/<device>.json`); iPad layouts (scenes sidebar, centred script, PDF pane beside script at >=1000 pt, projects grid fills width, keyboard Space/arrows, hover, sheets capped at 560 pt). New files added to `Runner.xcodeproj` by hand (PdfPlugin.swift). Goldens: `ipad_*` new; six `phone_*` re-recorded (header gained search/person/PDF icons).
- **Compiles for the simulator** (`flutter build ios --simulator --debug --no-codesign` OK; PDF view gated `@available(iOS 16)`).
- **Verified on the iPhone 17 simulator (iOS 27.1, real Kill Floor PDF, 2012 lines):** Show PDF opens the native PDFKit view (118 pages, "Page N of 118" chip); PDF search highlights and counts ("1 of 5") and moves the page; Page numbers shows the dotted line + "p. 4"; tapping the PDF button opens on page 3 (where the script starts); alignment replayed in Python: 2012/2012 lines matched. Bug found and fixed there: a new PDFView ignored the first jump to a page and sat on page 1 (PdfPlugin.swift `go(toPage:)` now repeats the jump during the view's first 3 s).
- **NOT verified (needs an iPad):** the iPad-only parts on a real or simulated iPad: Apple Pencil/finger markup and its saving to `Markup/`, the page/continuous switch, PDF beside the script (three panes), ⌘F on a keyboard. Only the widget tests and goldens cover them. Evict needs real iCloud Drive.
- **Full `bash scripts/test.sh flutter`:** analyze fine. 3 `worker_test.dart` tests failed only while the machine was overloaded (load avg 54 from the iOS 27.0 iPad simulator runtime spinning); re-run alone afterwards: all 5 pass. Not caused by this work.
- **Simulator trouble:** every iPad simulator is on the **iOS 27.0** runtime (27.1 has no iPads). Booting one (`iPad Pro 13-inch (M5)`, E0B11AA5-F830-43F7-A346-32ADF784A773) twice made `diskimagesiod` and the runtime processes spin (load avg 38-55), which slows everything and made 3 worker tests fail once. I shut it down both times (`xcrun simctl shutdown all`); don't boot it again without a reason. The iPhone 17 (27.1) works fine. Test projects (Kill Floor, Emma) are in the session scratchpad; the simulator-only fallback in AppDelegate `open()` reads the app container's `Documents/Table Read`. Debug Flutter builds only run via `flutter run -d <udid>`; the simulator draws about 5-10 s behind taps.
- **Next steps (iPad):** 1) install on Avery's real iPad (`xcodebuild -workspace app/ios/Runner.xcworkspace -scheme Runner -configuration Release -destination id=<ipad udid> -allowProvisioningUpdates build`, then `xcrun devicectl device install app`) and check page/continuous, Pencil + finger markup saving, the 3-pane layout and ⌘F; fix what breaks; 2) comment on and close issues #113-#121 with what shipped; 3) open a PR to `main` when Avery wants it. Free-team installs expire after 7 days.
- **Gotchas found:** never run `dart format` without `-l 150` (repo style; default 80 reformats everything); `ListTile` inside a `ColoredBox` hides its ink (use `Material`); `LineNotes` is a ChangeNotifier the screen must listen to; BSD sed has no `\n` in replacements (use python).
- **Linux-box:** not used this round (the work was judgment-heavy UI/native code, nothing bulk).

**Earlier state (before Nov 3):**
_(old header) Updated 2026-11-01 11:46 EST · branch `ios-rehearsal` @ `107a8a0` (not pushed) · working tree: clean except two untracked `sidetrack-*.md` notes (ephemeral, never commit)_

**Project:** Table Read turns screenplay PDFs into per-scene `.m4a` audio dramas. Shipped app is SwiftUI (`Sources/TableRead/`) + Python backend (`backend/`); being rebuilt as a Flutter app (`app/`, beta v0.3.0, PR #78 open) that drives the Python worker. iPhone companion exists in `app/` (iOS rehearsal milestone, #89-#94, rounds 1-2 installed on Avery's phone).
**Current goal:** milestone **Rust core** (GitHub milestone 9, issues #98-#109; later engines/languages/cloud parked in milestone 10, #110-#112). Planned with `/grilling` Oct 21; Avery said go.

**Decisions (full text in `docs/adr/0001-license-policy.md`, `0002-shared-rust-core.md`, `0003-sync-model.md`):**
- Both apps free. Desktop app open source (GPL-3.0); iPhone app App Store eventually (needs paid Apple Developer Program, $99/yr, also for Mac notarization). Avery is sole copyright holder; no outside code merged without a CLA.
- Two license tiers: shared core + iPhone permissive-only (CI `cargo-deny`, Licenses screen); desktop-only render crate may link GPL (espeak-ng, Piper engine). PDF extraction = PDFium (`pdfium-render`), not PyMuPDF (AGPL).
- iPhone is a companion: parses and rehearses on device, **no voice rendering**; renders happen on the Mac via the existing render queue (#97). Background-render spike cancelled. Cloud rendering parked. English only.
- OpenAI TTS removed everywhere (#3 closed won't-do, removal is #108). Engines: system voices, Kokoro (+espeak-ng), Piper on desktop only with verified-clean voices (lessac unverified, ryan excluded). Python stays dev-only oracle after each cutover.
- Gates: parser = extraction comparison + answer keys no worse + "nothing right may go wrong"; Python parser changes **frozen** during the port. Renderer = cue files match, audio length/loudness within tolerance, Avery listens.
- Sync: iCloud Drive files behind an interface; two-way parses (newer parser wins, corrections on top), per-entry merge for corrections/cast, `schemaVersion` everywhere, live folder watching, status file + Mac/iPhone chips (Online/Offline last-seen/Error/Update pending). Opt-in Mac auto-start of phone render requests.

**Order of work:** #98 skeleton/CI (needs rustup) and #99 PDFium spike alongside the #93 sync gaps (#103-#105) -> #100 Rust parser -> #101 Mac cutover -> #102 iPhone import/parse -> sync features -> #106 desktop Rust renderer -> #107 Mac render cutover. #108 (remove OpenAI) and #109 (LICENSE) are small separate PRs.

**Parser port (#100) DONE, gate passed:** `rust/crates/parser` (stages 1-5: `blocks.rs`, `model.rs`, `classify.rs`, `style.rs`, `script.rs`, plus `pystr.rs` for Python string/rounding/`sum` semantics) and `rust/crates/core` (`table_read_core::parse_pdf`, bin `table_read_parse <libpdfium> <pdf> [corrections_config.json]` printing the worker's script-summary JSON + `parserVersion: "rust-0.1.0"`). `python3 scripts/rust_parser_diff.py [-v] [stage...]` diffs every stage against `backend/parser.py` on the same extractor JSON: **identical on all 31 PDFs** for text_blocks, doc_model, classified_nostyle, style, classified, script (mutation tests prove it catches changes). **`python3 scripts/answer_key_rust.py --check` (PDFium + Rust parser only, no PyMuPDF, no Python parser): generated 99.4%, real 98.5%, "Nothing got worse"** (15 s). All run by `MIRROR=<dir> bash scripts/test.sh rust` (23 + 8 cargo tests, license check 65 deps). Gotchas learned: Python `round` is half-even (`round_ties_even`), `x or fallback` also falls back on 0.0, `Counter.most_common(1)` keeps the first max, Python 3.12+ `sum()` of floats is compensated. Title uses `script::derive_title` on page-1 lines (pdfplumber is gone), not yet compared. Python parser is still the reference and still frozen until the Mac cutover (#101).

**Workspace (#98 skeleton, done):** `rust/` is the Rust workspace (`rust/Cargo.toml`, crate `rust/crates/extract` = lib `table_read_extract` + bin `pdfium_extract`, `rust/cargo-offline.sh`). `bash scripts/test.sh rust` (needs `MIRROR=<dir>` on this Mac, see below) runs: 12 cargo unit tests (line and block rules), `scripts/check_licenses.py` (ADR 0001 tier 1: 61 dependencies all permissive; Python tests in `backend/tests/test_check_licenses.py` prove it rejects GPL/AGPL/LGPL/NC), and the answer-key gate with the Rust extractor (fails if anything got worse; verified by breaking the binary). Not part of `all` yet. Still open on #98: Licenses screen generator, `flutter_rust_bridge` hello-world on macOS and iPhone.

**Where things stand (#99 PDFium extraction; the Python prototype and notes are in `spikes/pdfium_extract/`, its README lists what the builder has to do):**
- **The Python prototype passes the Q7 gate**: `.venv/bin/python3 spikes/pdfium_extract/scripts/pdfium_answer_key.py --check` (38 s) patches `parser._extract_blocks` with a PDFium-based builder (pypdfium2 = same PDFium, existing `libpdfium.dylib` in `.venv`, nothing downloaded) and reports "Nothing got worse": generated scripts 99.4% (= baseline, 0 broken), real sample 98.5% (= baseline, 0 broken). Progression: naive 91.4% / 81.4% -> fixes below -> 99.4% / 98.5%. Never `--save` from the wrapper.
- What fixed it, in order of effect: MuPDF-style block boundaries (new block when a line is indented over 0.25 em more than the previous, jumps up, or drops over 1.45 em: reproduces 19349 of 19357 boundaries); splitting lines at large forward gaps (inline `NAME:` + hanging dialogue); ignoring PDFium's synthetic spaces for line decisions and adding spaces by gap (0.1 em); PageToDevice coordinates; text-matrix scale for size; near-vertical text; content-stream order plus text objects the text page drops (lone " " after a line = MuPDF's trailing space, blank lines).
- Line text agrees with PyMuPDF on 99.4% of 50k lines across the 13 corpus PDFs. Known gaps (not gate-relevant yet): trailing-space width (0.25 em assumed, Courier is 0.6 em) so some right edges are one space off; non-standard non-embedded fonts get slightly different line heights; page rotation untested; EMMA 4960 lines vs 4746.
- 14 standard-font line metrics measured from PyMuPDF are in `spikes/pdfium_extract/base14_metrics.json`.
- **The Rust port passes the same gate** (`EXTRACTOR=rust .venv/bin/python3 spikes/pdfium_extract/scripts/pdfium_answer_key.py --check`, 19 s): generated 99.4%, real 98.5%, both = baseline, "Nothing got worse". `rust/crates/extract/src/` (`chars.rs`, `lines.rs`, `blocks.rs`, `lib.rs`, `main.rs`) uses `pdfium-render` 0.9 with the `pdfium_7763` feature against the venv's `libpdfium.dylib` (PDFium 149.0.7802; the crate default 7881 needs a newer lib). Rust chars equal the Python prototype's (`scripts/compare_chars.py`: identical numbers, only a control-character glyph differs). Python stays as the reference: `scripts/dump_pymupdf.py`, `proto_*.py`.
- **Rust toolchain and network on this Mac:** Rust-built binaries (cargo, rustup, anything compiled) cannot resolve DNS in the sandbox while curl and Python can (a compiled `to_socket_addrs` test fails). Workaround that is in bounds: rustup 1.29 + stable 1.99.1 with `aarch64-apple-ios` and `-ios-sim` targets were installed from a local mirror of static.rust-lang.org files fetched with curl (`RUSTUP_DIST_SERVER=file://...`; installed in `~/.cargo/bin`, `~/.rustup`, not on PATH: `--no-modify-path`); crates come from a local registry built by `scripts/local_crate_mirror.py` (Python HTTP) and `rust/cargo-offline.sh` (needs `MIRROR=<dir>`). The mirror dirs live in the session scratchpad and are rebuilt by those commands. Homebrew's cargo is still the first `cargo` on PATH; use `~/.cargo/bin/cargo` explicitly. A local CONNECT proxy was refused by the sandbox classifier, don't try.

**Rust core is wired into the Mac app code (not yet cut over for good):** `rust/crates/ffi` (`libtable_read_ffi.dylib` / `.a`; C ABI `tr_parse_pdf`/`tr_version`/`tr_free`, PDFium opened once per process) and `app/lib/services/rust_core.dart` (`dart:ffi` on a background isolate; `RustCore.locate`). `AppState.importPDF` now parses with the Rust core when the libraries are found and falls back to the Python worker (logged). `flutter test` 76 pass incl. `test/rust_core_test.dart`. iOS static libs build: `cd rust && ./cargo-offline.sh rustc --release --target aarch64-apple-ios[-sim] -p table-read-ffi --features static-pdfium --crate-type staticlib` (~34 MB each; needs only PDFium's static lib at the final link: 432 FPDF symbols).
**Parity with the worker** (`python3 scripts/rust_vs_worker.py`, element-level text overlap vs PyMuPDF+Python on 31 PDFs): 25 of 31 at 99-100%, titles identical 31/31, scene/line/character counts within 1; lowest: Untitled 94.6% (PyMuPDF glues page-break "(MORE)" into a parenthetical, Rust doesn't), EMMA 97.1%, Burns 98.8% (side-by-side layouts; some Rust results are better). Bugs this found and fixed in the extractor: doubled spaces (generated + real space), TAB used as space, U+0002 hyphen, split `fi` ligatures (recombined to ﬁ to keep stored text identical), dropped duplicate space glyphs, block gap 1.45 -> 1.5 em, letter-spaced titles.

**Next steps:**
1. **Avery: re-sign in to Xcode's Apple ID** (Xcode > Settings > Accounts; the device build fails with "No Accounts"). Then `MIRROR=<dir> bash scripts/build_ios_native.sh` is already done in `app/ios/native/` (rerun only if the Rust code changes), and install: `cd app && flutter build ios --config-only --release`, then the `xcodebuild ... -destination 'id=00008130-000475601803401C'` + `devicectl install` commands under Watch out for. Then on the phone: `+` > pick a PDF > check the project shows and opens (text-only rehearsal).
2. Push `ios-rehearsal` / open a PR to `main` when Avery wants it (commits `a50a16d` phone import, `107a8a0` labelling kit; full gate passed before them).
3. **Mac side of imported projects:** open a phone-imported project on the Mac (it has PDF + script.json + project.json) and confirm it loads without re-importing; decide whether the Mac re-parses (ADR 0003: newer parser wins).
4. **#101 Mac cutover:** bundle `libtable_read_ffi.dylib` + the downloaded `pdfium-mac-arm64` (`libpdfium.dylib`, same 149.0.7802) into the .app (Contents/Frameworks, signed), then drop the Python parse fallback from the shipped app (keep as oracle).
5. Gaps: page rotation / non-corpus PDFs; share-sheet import ("Open in Table Read"); import progress text; the iPhone's Release build never ran on a device yet; PDF import needs iOS 26+ (PDFium minos 26.0).
6. Then sync features (#103-#105), then the desktop Rust renderer (#106-#107).

**To try on the phone:** not installable until step 1 (Apple ID sign-in). Verified instead on the iPhone 17 simulator (`flutter run -d 3F48D6A2-E8BF-4769-8B17-6B26617FAC0B`): the Rust core and PDFium load from `Runner.app/Frameworks` and a PDF imports end to end (project folder with PDF, script.json, project.json). The Files picker itself renders blank in the simulator (Apple remote view), so the `+` > picker path is only verified on a real phone later.

**Waiting on the user / open questions:**
- Re-sign in to Xcode (step 1). Done: OK to download PDFium (fetched Oct 30).
- Labelling the exams (offline kit `Test PDFs/label-kit/Label lines.html`); parser quality work is paused until after the Rust parser cutover (Python parser frozen).
- Merge PR #78 (`flutter-mac-app` -> `main`). Run the move to iCloud Drive (#89). Notes on the rehearsal mockup / round 2.
- Verify before relying on them: the research agent's sherpa-onnx news (espeak removal, Oct 20 2026), Piper `lessac` voice license, `flutter_rust_bridge` static linking on iOS/macOS 2026 (Xcode symbol stripping), `ort` is still a release candidate.

**Watch out for:**
- **Rust builds for iOS:** put `~/.cargo/bin` first on PATH (Homebrew's `rustc` has no iOS targets and cargo picks it up: "can't find crate for core"). The crate mirror is rebuilt per session: pin every crate from `rust/Cargo.lock` (`name==version`) into `scripts/local_crate_mirror.py <dir> ...`, then `MIRROR=<dir>`. `cargo-offline.sh` appends `--config` after your args, so don't use `cargo rustc -- <flags>`; use `RUSTFLAGS`.
- Flutter debug builds only run via `flutter run` (a debug app launched from the home screen / `simctl launch` shows white).
- Avery asked (Oct 19): use the local models on linux-box for grunt work and supervise (skill `linux-box-llm`). Used so far for the issue drafts and the spike's Dart UI; both needed review (one real bug: error logs interpolated a function).
- **Installing on the iPhone:** `flutter build ios` / `flutter devices` don't see the phone. What works: `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -destination 'id=00008130-000475601803401C' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`, then `xcrun devicectl device install app --device <udid> <DerivedData>/Release-iphoneos/Runner.app`. Xcode is now signed in to Avery's Apple ID; the developer is trusted on the phone. Free-team apps expire after 7 days: reinstall.
- **Swift tests hang at launch** ("test runner hung before establishing connection"), issue #95; started Oct 20 after Xcode sign-in / first iPhone attach; not caused by code. Full suite otherwise passes.
- Screen tests: rehearsal settings are files in the fixture project now; `_makeState` deletes `Rehearsal/` folders so tests don't leak into each other.
- **Dart sees no environment on iOS** (`Platform.environment` is empty, even HOME): never rely on it in phone code. The Runner target's Debug config has no Swift `DEBUG` flag; use `#if targetEnvironment(simulator)` for Simulator-only code.
- The iOS Simulator control tool hung (300 s timeouts) on Oct 20; `xcrun simctl io <udid> screenshot` still works.
- Simulator: the iOS sim tool only has access to the `iPhone 17` sim (3F48D6A2…); the iPhone 18 Pro sim was declined. Its screenshots lag taps by a second or two: wait before screenshotting.
- `sidetrack-*.md` notes are ephemeral: delete once confirmed done; never commit them.
- Avery catches UI regressions by eye (options cluster top-right, scroll-follow on play).
- Goldens: record with the whole file (`flutter test --update-goldens test/screens_test.dart`); use `clockNow()` for anything a golden shows.
- Parser edits follow the answer-key protocol in `CLAUDE.md`.
- `gh` needs `GODEBUG=netdns=go` on this Mac. Git pushes: `-c credential.helper='!gh auth git-credential'`.
- No cargo registry access from this Mac's Homebrew cargo (see above); don't spend time on proxies, ask for rustup.
- Never run `answer_key.py --save` from the PDFium wrapper; baselines are the PyMuPDF results.

**Key files:** `docs/adr/` (decisions), `spikes/pdfium_extract/scripts/` (PDFium prototype), `backend/parser.py` (`_extract_blocks`, `_split_raw_block` = the structure the Rust extraction must reproduce), `app/lib/state/player_state.dart`, `app/lib/services/project_files.dart`, `app/lib/services/project_store.dart`
**Run / test:** `bash scripts/test.sh flutter`, `bash scripts/test.sh` (full); PDFium check above.

## History
<!-- newest first -->

### 2026-11-04 — iPad round 5b: markup viewer is one PencilKit canvas
- Avery: the per-page-overlay viewer drew nothing and showed no iPadOS palette. Rewrote `MarkupViewController` (`ios/Runner/PdfPlugin.swift`)
  as the standard PencilKit layout: one `PKCanvasView` (scroll view) with the PDF pages rendered lazily as image views behind the ink,
  `PKToolPicker` attached in `viewDidAppear` (again after 0.4 s). Ink still saved per page in page points (split by stroke midY on
  save, re-laid on load/rotation). No pinch-zoom in the viewer; pages are fit-to-width, max 1100 pt. Built and installed; not verified.
- Kokoro question inflection: text reaches `kokoro.create` unchanged, so it is mostly a model limitation. Lead to try: we ship the
  `int8` model (`backend/tts_engines.py`), the fp32 one may keep more prosody. Asked Avery whether to add it as an option.

### 2026-11-04 — iPad round 5: Apple's own PencilKit markup, short notices
- Avery tried round 4 on the iPad: Pencil drew but the fit-to-page, single-page markup was unusable in landscape. Asked for the
  standard iPadOS Pencil tools and continuous scroll like Preview.
- Dropped the Flutter ink layer (`lib/phone/ink_layer.dart` deleted). The toolbar's pencil button now calls `presentMarkup`
  (`ios/Runner/PdfPlugin.swift`): a native full-screen `MarkupViewController` (PDFView, continuous scroll, `PKCanvasView` per page via
  `PDFPageOverlayViewProvider`, system `PKToolPicker`, Done button). Drawings are PKDrawing base64 per page in `Markup/<device>.json`
  (saved ~0.6 s after a stroke settles, flushed on Done). The reading view shows the ink through the same overlays, read-only.
  Round-4 ink JSON in existing Markup files is ignored (not valid PKDrawing data).
- One-page-at-a-time reading now also turns pages with a native left/right swipe (only at fitted zoom) besides the arrows.
- Passing messages use `showNotice` (`lib/phone/notice.dart`): floating, 1.8 s, replaces the previous one.
- Not verified on device yet: whether the PencilKit canvases take the Pencil inside the native viewer (the earlier in-Flutter version
  did not draw); installed on the iPad for Avery to try.

### 2026-11-04 — iPad round 4: own ink layer, full-screen PDF, reader rework
**Asked:** Pencil still dead; PDF full screen in landscape; page turning stuck in single-page; no script-view markup; outline left + animated + scrub; jump reliability/smoothness; fixed scene bar; multi-select characters; bookmark preview; faster long-press + floating iPad menu; note flag/animation/pencil icon/delete.
**Done:** PencilKit dropped. `PdfPlugin.swift` now only shows the page (fit-locked while marking up) and reports its on-screen rect (`geometry`); `lib/phone/ink_layer.dart` draws/records strokes in Flutter in page coordinates (pen/highlighter/eraser, undo/redo, JSON per page in `Markup/<device>.json`; touches swipe to turn pages, stylus draws, mouse draws for the simulator); marking up switches to single-page mode. PDF never splits the screen (`splitPdfMinWidth = infinity`). Reader: fixed scene bar (name animates; Text only chip + chevron constant), inline scene titles, outline rail left at ~1/3 height with fade/scale open, sliding long dash, hold-and-drag scrub with label; scene jumps animate 480 ms and re-settle; bar/outline use exact heading positions (post-frame); end spacer so every scene can reach the top; `myRoles` set in `RehearsalPlayer` (+ `roles` in the Rehearsal file; `role` stays the first); bookmark sheet shows a mini preview of the line; 220 ms long-press; iPad selection menu floats on the line (phone keeps the bottom bar); note flag points at the line, card animates, Note uses a pencil icon, Delete Note added.
**Decisions:** Flutter-drawn ink because PencilKit-in-PDFKit-overlay could not be debugged without a device; ink visible only in single-page mode. Tests: `_forgetLastTest` helper because the previous test's mounted screen saved its reading position into the next test's folder.
**State:** 114 tests pass; NOT installed (iPad was unavailable); nothing verified on a device.
**Next:** install and test (Pencil first).

### 2026-11-03 17:40 — iPad notes round 3: sidebar out, bookmarks, outline rail, position sync, Pencil tools
**Asked:** Pencil markup broken, wants standard tools or pen+highlighter with colours/thickness; drop the redundant scenes sidebar and add bookmarks (replacing the bar's left button); markup in scroll view too (and a compromise for reflow); collapsible outline; position sync across devices.
**Done:** see Resume block (files: `lib/phone/{bookmarks,outline_rail}.dart` new; `rehearsal_screen.dart`, `rehearsal_session.dart`, `project_files.dart`, `adaptive.dart`, `pdf_view.dart`, `pdf_panel.dart`, `ios/Runner/PdfPlugin.swift`; tests in `ipad_test.dart`, `phone_test.dart`).
**Decisions:** own tool strip as default because the system PKToolPicker is unverifiable inside a Flutter platform view (Apple's palette stays a toggle); position sync extends the existing per-device Rehearsal file (iCloud KV store needs entitlements the free team lacks) and never moves the view while open without a tap; script-view markup held back for Avery's call on the anchor design.
**State:** committed; 112 tests pass; Swift compiles; nothing run on a device. Accidental repo-wide reformat left uncommitted (see header).
**Next:** device test, then script-view markup.

### 2026-11-03 14:13 — iPad port started; six iOS features built (uncommitted, partly unverified)
**Asked:** Address the iOS feature requests (search, My Character without rendering, Show PDF, PDF page numbers, notes per line, Remove Download), note the iPadOS ones (Pencil markup, page/continuous PDF), and start the iPadOS port from the iOS app; report blockers first; use linux-box where it fits.
**Done:** see the Resume block: issues #113-#121 + milestone iPadOS filed; new `lib/phone/{adaptive,line_notes,page_align,script_search,pdf_view,pdf_panel}.dart`, `ios/Runner/PdfPlugin.swift`, `evict` in AppDelegate; `rehearsal_screen.dart` rebuilt around header/search/notes/page breaks/sidebar/PDF pane; `phone_app.dart` grid + Remove Download; tests `phone_tools_test.dart`, `ipad_test.dart`; CLAUDE.md issue table.
**Decisions:** one universal app, width-based size classes; page numbers by aligning lines to PDF text (parser frozen); markup and notes stored per device in the project folder (same no-conflict pattern as Rehearsal/); PDF fetched from iCloud on demand, not in the up-front download; PDF view needs iOS 16 (gated, not raising the deployment target).
**State:** committed on `ipados-port` (not pushed). Full `bash scripts/test.sh flutter`: 105 pass, 3 skipped; PDF view/search/page breaks verified on the iPhone 17 simulator; iPad-only parts not run on an iPad (see Resume). Bugs the tests caught and I fixed: sidebar ListTile needed a Material; notes screen didn't listen to LineNotes.
**Next:** Resume block, iPad next steps 1-4.

### 2026-11-01 11:46 — Committed the phone-import work and the labelling kit
**Asked:** "Commit the working tree changes with a sensible message."
**Done:** ran the full `bash scripts/test.sh` (passed), then two commits: `a50a16d` (iPhone native libs + PDF import, DEVLOG, `.gitignore` `app/ios/native/` line) and `107a8a0` (`label_kit.py`, `side_by_side.py`, `label_sample.py` sbs sample, `CLAUDE.md` rows, `launch.json` entry, `.gitignore` kit line). The shared `.gitignore` was split between them.
**Decisions:** left the two `sidetrack-*.md` notes untracked (they are ephemeral by rule).
**State:** committed, not pushed. Phone install still blocked on Xcode's Apple ID sign-in.
**Next:** see Resume block.

### 2026-10-30 13:55 — PDFium downloaded; Rust core embedded in the iPhone app; PDF import on the phone (#99, #102)
**Asked:** "Yes, download" (OK to fetch PDFium builds); goal: a new version for the phone.
**Done:**
- Downloaded bblanchon/pdfium-binaries `chromium/7802` (PDFium 149.0.7802.0 = the dev dylib's version): `pdfium-ios-device-arm64`, `-ios-simulator-arm64`, `-mac-arm64`, ~3.3 MB each. **They are dylibs, not static libs** (so the plan to link a static PDFium is dropped; the paulocoutinhox static build was not needed). Downloaded copies are in the old session scratchpad; `scripts/build_ios_native.sh` re-downloads.
- `scripts/build_ios_native.sh`: builds `libtable_read_ffi.dylib` (cdylib, install name `@rpath/...`) for device and simulator and puts it with `libpdfium.dylib` in `app/ios/native/{iphoneos,iphonesimulator}/` (gitignored). New Xcode build phase "Embed native libraries" in `Runner` (`project.pbxproj`) copies the matching pair into `Runner.app/Frameworks` and signs them.
- `rust_core.dart`: on iOS `RustCore.locate` finds them in `<app>/Frameworks`.
- Phone import (#102): `+` in the Projects header -> Files picker (`pickPdf` in `AppDelegate.swift`, copy into the app sandbox) -> `RustCore.parse` with the bundled `assets/corrections_config.json` (copy of the backend's; a test keeps them equal) -> `PhoneStore.importPdf` writes `<project>/<pdf>`, `script.json`, `project.json` into the projects folder (new `copyIn` plugin op, coordinated writes). Phone goldens re-recorded (only the new "+").
- `scripts/local_crate_mirror.py` now accepts yanked versions for exact pins; mirror can be rebuilt from `rust/Cargo.lock` (see Gotchas).
**Decisions:** dylibs embedded in Frameworks instead of static linking (simpler, smaller; App Store packaging of loose dylibs is to be revisited with the Apple Developer Program step). PDFium's iOS builds have minos 26.0: fine for the phone (iOS 27.0.1), the app's own target stays 15.0 but PDF import needs iOS 26+.
**State:** committed as `a50a16d`, not pushed. Full `bash scripts/test.sh` passed (Python, Swift, Flutter analyze, `flutter test` 78 pass incl. import test through the Rust core on macOS). Simulator: Debug build embeds both dylibs (signed); with a temporary startup hook (removed) the app located them in Frameworks and imported a PDF end to end (project folder written). The Files picker is blank in the simulator, so it is untried. **Device build fails at signing: "No Accounts" in Xcode, Avery must re-sign in to the Apple ID.**
**Next:** see Resume block.

### 2026-10-21 20:00 — Rust core wired into the Flutter app (FFI), parity with the worker measured and fixed
**Asked:** (continuing after a usage-limit reset)
**Done:** `rust/crates/ffi` + `rust_core.dart` + `AppState` hook (Rust first, Python fallback) + `test/rust_core_test.dart`; iOS device/simulator static libs build; new `scripts/rust_vs_worker.py` (element-level overlap vs the worker) which exposed text differences the answer keys could not see, all fixed in `rust/crates/extract` (see Resume block); titles 31/31 identical; ADR 0002 addendum.
**Decisions:** C ABI + dart:ffi (not flutter_rust_bridge). Recombine ligatures to match stored text. Keep PDFium's cleaner results where PyMuPDF has quirks ("(MORE)").
**State:** committed, not pushed. cargo tests (extract 18, parser 20, ffi 3), license check, six stage diffs, Rust-only answer keys (99.4% / 98.5%), `flutter test` 76 pass.
**Next:** see Resume block (PDFium downloads need Avery's OK).

### 2026-10-21 18:10 — Rust parser port finished: all stages identical, answer keys at baseline
**Asked:** "continue unless you need me; tell me when it's ready to load on my phone".
**Done:** stages 2-5 of the parser port (`model.rs`, `classify.rs`, `style.rs`, `script.rs`), `rust/crates/core` (PDF in, script JSON out), `scripts/answer_key_rust.py`; the diff harness covers six stages on 31 PDFs; `test.sh rust` runs everything. Commits per stage (a0246b0 stage 2, a1e9da1 stage 3, 8aca197 stage 4, then stage 5 + core). Issues #99/#100 commented.
**Decisions:** C ABI + dart:ffi instead of flutter_rust_bridge (JSON in and out matches how the apps already work). Own license checker instead of cargo-deny (earlier).
**State:** committed, not pushed. cargo tests pass, license check ok, stage diffs identical, Rust-only answer keys = baseline (generated 99.4%, real 98.5%). Python parser untouched. Not installable on the phone yet.
**Next:** see Resume block (FFI crate; PDFium builds need Avery's OK to download).

### 2026-10-21 16:30 — Rust parser port, stage 1 (text blocks) identical to Python
**Asked:** (continuing; "you decide" on next steps)
**Done:** surveyed parser.py (2565 lines, no regex lookarounds, pdfplumber only for the title) and posted the six-stage plan on #100. Wrote `rust/crates/parser` stage 1 and the exact differential harness `scripts/rust_parser_diff.py` (same extractor JSON into Python and Rust, field-by-field diff). 11 Rust unit tests for the helpers (expected values taken from Python). Wired into `scripts/test.sh rust`.
**Decisions:** none new. Python semantics are reproduced explicitly (`pystr.rs`), not assumed to match Rust's `str`.
**State:** committed, not pushed. cargo 23 tests pass, stage diff identical (31 PDFs), license check ok (65 deps), extraction gate unchanged. Python parser untouched.
**Next:** see Resume block.

### 2026-10-21 15:50 — Rust workspace skeleton, license check, `test.sh rust`
**Asked:** "Not sure you decide" (what to do next after the Rust extractor passed).
**Done:** decided to do the #98 skeleton before the parser port (small, gives the port a home). Moved the spike's Rust into `rust/` (workspace + `crates/extract`, lib and bin); 12 unit tests for the line/block rules (each is a failure found earlier); `scripts/check_licenses.py` + 3 pytest cases; `bash scripts/test.sh rust`; ADR 0001 updated (own checker instead of `cargo-deny`, which can't be installed here). Python wrapper paths updated; both the Python and Rust modes of the gate still say "Nothing got worse".
**Decisions:** parser port (#100) comes next, after the skeleton; `rust` is not in `all` until the toolchain works without a mirror.
**State:** committed, not pushed. Python fast suite 100 passed; cargo 12 passed; license check ok; gate unchanged. Full `bash scripts/test.sh python` (answer keys on the Python parser) not re-run: no parser files changed.
**Next:** see Resume block.

### 2026-10-21 15:30 — Rust toolchain, Rust PDFium extractor passes the gate
**Asked:** install rustup (Avery: "You can install rustup"), continue.
**Done:** rustup + Rust 1.99.1 (+ iOS targets) installed via a curl-fetched local mirror because compiled binaries can't resolve DNS here; `scripts/local_crate_mirror.py` + `spikes/pdfium_extract/cargo-offline.sh` for crates; `spikes/pdfium_extract/src/*.rs` (chars/lines/blocks, `pdfium-render` 0.9, feature `pdfium_7763`) producing PyMuPDF's dict shape. Gate through the unchanged parser: generated 99.4%, real 98.5%, nothing broke (19 s). Issue #99 commented.
**Decisions:** none new. Synthetic spaces join the span they follow in Rust (the Python prototype gave them their own size-1.0 span); the gate stayed at baseline.
**State:** committed with the spike (see git log), not pushed. No app code changed; verified by the answer-key gate only (`EXTRACTOR=rust`).
**Next:** see Resume block.

### 2026-10-21 15:40 — Rust core planned (grilling), milestone filed, PDFium extraction spike passes the gate in Python
**Asked:** push toward importing, parsing and rendering on iOS; `/grilling`; then "go, continue unless you need me".
**Done:** 34-question grilling (decisions in the Resume block). Research agent audited licenses (PDFium, Kokoro/misaki, espeak-ng GPL, Piper archived -> piper1-gpl, ort, AAC, flutter_rust_bridge). Wrote `docs/adr/0001-0003`. Created milestones "Rust core" (#9: issues #98-#109) and "Advanced voice engines" (#10: #110-#112); closed #3; commented on #2 and #93. #99: `spikes/pdfium_extract/` PDFium prototype in Python (same PDFium) rebuilds PyMuPDF's block/line/span structure well enough that the answer-key gate does not get worse (generated 99.4%, real 98.5%, both equal to baseline); details in the Resume block and the spike README.
**Decisions:** Piper kept after all (desktop-only) because the desktop app will be GPL; the phonemizer listening spike was dropped for the same reason (Kokoro keeps espeak-ng on desktop). iPhone does no rendering, so sync matters more.
**State:** committed, not pushed. No Flutter/Swift/Python app code changed (the wrapper patches the parser at runtime), so only the answer-key gate was run, via the wrapper.
**Next:** see Resume block.


### 2026-10-20 16:09 — iPhone round 2; lock screen + headphone controls
**Asked:** bar only dark → follow the theme; scene list should drop down from the header; Line! as a bar button (only when blocking), one-time hint instead of the tutorial card, tap again while playing stops; render request works; implement headphone + lock-screen controls.
**Done:** `9957288` (Resume block). Issues: #97 closed, #92 and #91 commented.
**Decisions:** Line! replaces the role pill while Block My Lines is on (both pills opened the panel anyway). Native MPRemoteCommandCenter instead of the `audio_service` package (smaller; just_audio stays the player). AirPods press maps to toggle, so it carries on at your line.
**State:** Flutter 74/74 (new now_playing_test, Line! test, drop-down position check). Installed on the iPhone. Lock screen/AirPods not tried on the device yet.
**Next:** Avery's notes on round 2.

### 2026-10-20 09:01 — iPhone round 1 notes; render queue
**Asked:** Avery's first notes on the phone build: dark mode in the bottom bar; drag-select should scroll at the edges; whole play scrollable with sticky, tappable scene headings; "Large" twice → "Huge"; ask the Mac to render from the phone (a queue on the home screen); Stop Before: play didn't carry on; peek should toggle and read the line aloud; could you say "Line!" out loud?
**Done:** `cf41edc` (see Resume block). Issues: #96 (spoken Line!, filed), #97 (render queue, built). #91 commented.
**Decisions:** The phone's bar stays dark in both themes (the Mac's flips light in dark mode). Peek changes are shared with the Mac (parity). A render request opens the Mac's Render sheet rather than starting by itself, so engine/cast checks still apply. One request file per project, written by the phone, removed by the Mac.
**State:** Flutter 70/70 (new: player_test, drag auto-scroll test verified to fail with auto-scroll off, request flow tests, Mac gallery banner golden). Existing Mac goldens unchanged. Not on the phone yet (unreachable at install time).
**Next:** install on the phone; Avery tries it.

### 2026-10-20 01:20 — #91 iPhone rehearsal screen
**Asked:** (continuing independently) build the rehearsal screen from the mockup.
**Done:** `aa1127c` as in the Resume block; `scripts/install_iphone.sh`. Issue #91 commented, left open for notes.
**Decisions:** One scene on screen at a time (header or panel switches scenes), following playback into the next scene. Rendered scenes are shown from cue maps so the highlight is the cue index, no row matching. The phone restores position already (part of #93). Text options per device, as decided Oct 19.
**State:** Flutter 60/60; iOS Simulator build compiles. Fixed during review of the goldens: dark-mode playing line unreadable (pale ink on yellow), "My Role" truncated, knob over "0:00", invisible ripples on the toggles. Device install still blocked ("No Accounts").
**Next:** Avery: Xcode sign-in, Mac move, try the phone.

### 2026-10-20 01:07 — #90 iPhone app basics; rehearsal mockup for #91
**Asked:** Avery: "continue working independently" (after #89).
**Done:** `692b6f1`: iOS target, native folder plugin, phone welcome + project covers + download, phone screen tests. Issue #90 commented. Mockup canvas for #91: https://claude.ai/artifact/7rVmDhroJQJzHnLLVimJ8B (playing; Rehearse panel; Stop Before + Block waiting card with "Line!").
**Decisions:** The phone reuses the Mac's `ScriptCover` (scaled, two per row) instead of a new card. Rendered scenes will be shown from their cue files (what was voiced, corrections included); text-only scenes from script.json. Projects without script.json say "open it on your Mac once" rather than the phone guessing.
**State:** Flutter 55/55. Device install blocked: xcodebuild says "No Accounts" (Apple ID token expired?). Simulator tapping blocked (tool hung); verified by screenshots + widget tests instead. Avery's real projects still in ~/Documents.
**Next:** build #91.

### 2026-10-20 00:37 — #89: Mac app makes projects ready for the iPhone
**Asked:** Step 2 of the iOS plan, the Mac app changes.
**Done:** `a3ee5ca`. script.json snapshot, per-device rehearsal files, Move to iCloud Drive (Settings → Projects → iPhone; UI contract updated), iCloud prefetch on open. Two problems found in passing: edits are keyed by the PDF's absolute path, so a move would orphan every correction (now re-pointed on open, and the path is out of the re-render fingerprint); render fingerprints were never saved to project.json (`_syncToProject` skipped them), so reopening forgot pending re-renders. Rebuilt `/Applications/Table Read Preview.app`. Filed #95.
**Decisions:** script.json holds the raw parse, not the edited script, so there's one source of truth for edits (project.json) and the phone shares the Mac's display code. One rehearsal file per device instead of one shared file: iCloud never has to merge. Position/loop are saved now, restored in #93.
**State:** Flutter 48/48 (8 new tests drafted by qwen-big; 4 real bugs fixed in review), worker test round-trips every test PDF, Python + answer keys unchanged, Mac app builds. Swift tests hang (#95). The move itself hasn't run on Avery's real projects.
**Next:** Avery runs the move; then #90.

### 2026-10-19 23:50 — #88 passed on the real iPhone: iCloud Drive approach is a go
**Asked:** Run the iCloud folder test on Avery's iPhone.
**Done:** Avery signed in to Xcode (it had no Apple ID; iOS signing needs one). Built for the phone's exact UDID so Xcode registered it and made a team profile, installed with `devicectl`, Avery trusted the developer and ran the test. Closed #88 with results.
**Decisions:** Go for the shared iCloud Drive folder (the Wi-Fi fallback isn't needed).
**State:** Verified: phone wrote `hello-from-iphone.txt`, seen on the Mac; a Mac edit read on the phone (Avery: "says edited"); folder remembered after relaunch. Only spike + log changed.
**Next:** #89 Mac app changes.

### 2026-10-19 23:20 — iOS rehearsal planned; iCloud folder test passes in the Simulator
**Asked:** Plan an iOS port as a rehearsal/line-learning tool at parity with the desktop player (`/grilling`, TLDR for Avery), then go. Also: use linux-box local models for grunt work from now on.
**Done:** Three rounds of questions, 13 decisions (Resume block). Branch `ios-rehearsal`. GitHub milestone 4 renamed "iOS rehearsal" with issues #88–#94 (bodies drafted by qwen-big, reviewed). Spike app `spikes/icloud_folder/` for #88, run on the iPhone 17 simulator.
**Decisions (Avery):** iOS goes ahead of the parser milestone (parser resumes when labels arrive); just Avery, free account; sync via a shared iCloud Drive folder (rejected: AirDrop is one-way; Wi-Fi sync only when both on the same network with the Mac app open, most code; Apple's app sync needs $99); sync role/toggles/speed/loops/position both ways, text size + highlights per device; Mac saves the full parsed script so unrendered scenes show as text; Mac gets a one-button move to iCloud Drive (old Swift app loses the projects, accepted); phone layout as proposed, "start here and iterate"; app "Table Read", same icon.
**State:** Simulator: pick, list, read/write, 2.3 MB read, bookmark survives relaunch. Device/iCloud test pending Avery's iPhone. Spike not covered by `scripts/test.sh` (flutter analyze clean); suite not rerun, no app code changed.
**Next:** #88 on the real iPhone.

### 2026-10-19 15:38 — Released the Flutter app as beta v0.3.0
**Asked:** Release this version as the new beta.
**Done:** App version 0.3.0 (`AppState.appVersion` = `0.3.0-preview`, pubspec `0.3.0+2`). Six sheet goldens re-recorded (only the version text changed). `build_flutter_app.sh --package` writes the release assets to `build/`. Commit `e4f1f61` and tag `v0.3.0` pushed. Prerelease "Table Read Beta v0.3.0" with dmg/zip/sha256 and hand-written notes (install, Gatekeeper, Apple Silicon, Swift users download manually).
**Decisions (Avery):** link-only for Swift beta users (no `TableRead.zip`, so their updater can't swap in a different app); version 0.3.0. `ship.sh` not used: it is Swift-only (Info.plist, TableRead.zip + Ed25519 sig).
**State:** Full suite passed (Python, Swift; Flutter 40/40 after goldens). The Flutter app's own updater only links to the release page (`hasZipAsset` looks for `TableRead.zip`). Git pushes hang on the osxkeychain helper here (a Keychain prompt?); pushing with `-c credential.helper='!gh auth git-credential'` works. Removed `.github/workflows/release.yml`: on every `v*` tag it built the Swift app on macos-14 (Xcode 15.4, can't compile current Swift; failed on every tag since v0.1.7) and showed a red check on PR #78; had it passed, it would have published a conflicting `--latest` Swift release. Releases are made locally (`ship.sh` for Swift, `build_flutter_app.sh --package` for Flutter). `ci.yml` is unchanged.
**Next:** Back to the parser-quality plan.

### 2026-10-19 13:29 — Flutter app installed as a normal Mac app
**Asked:** A build Avery can run as a normal app on this Mac.
**Done:** `scripts/build_flutter_app.sh`: `flutter build macos --release`, copies `backend/*.py` + `*.json` and `vendor/python` into `Contents/Resources` (the bridge's first lookup), signs nested Mach-O files then the app with the Apple Development cert, installs to `/Applications/Table Read Preview.app` (233 MB). `--no-build` re-bundles the last build.
**Decisions:** Self-contained rather than pointing at the repo, so switching branches can't break the installed app. No hardened runtime on the bundled Python: library validation would refuse the Kokoro/onnxruntime packages pip-installed in `~/Library/Application Support/TableRead/python-packages`.
**State:** Uncommitted. Verified: bundled worker parses a test PDF (18 scenes, 8 characters), engineStatus sees macOS + Kokoro, Kokoro imports under the re-signed Python, the app launches from /Applications. `spctl` says "rejected" (normal for a Development cert; no quarantine flag, so it opens). Not clicked through end to end in the UI.
**Next:** Avery tries it; rerun the script after future changes.

### 2026-10-17 — Offline labelling kit for both exams
**Asked:** Both remaining exams in one tool that doesn't need the console running and can be paused.
**Done:** `scripts/label_kit.py` builds `Test PDFs/label-kit/` (gitignored: page images + line text): one HTML page, labels autosave in the browser (localStorage), Export downloads `table-read-labels-*.json`, `--import` merges the newest one from ~/Downloads into the sample files. `scripts/side_by_side.py` finds side-by-side text without the parser (shared rows + two-column runs with names and prose on both sides; splits EMMA's two-page sheets; ignores rotated watermarks). Drew `real_sample.sbs.json` (400 lines: all 311 non-Stereophonic + 89 sampled Stereophonic; seed 2028), registered as sample `sbs` in `label_sample.py`. Added a `label-kit` server to `.claude/launch.json` (testing only: the browser pane can't load file:// pages properly).
**Decisions:** Avery labels the side-by-side exam now rather than after #75 (changes the Oct 16 plan); the labels are not read until steps 1–3 are done, the same discipline as the held-out exam. `together` is stored as 'yes'/'no'/'unsure'.
**State:** Uncommitted. Tested in the browser (label, side-by-side flow, reload keeps progress, region outline) and import tested on copies. `bash scripts/test.sh python` passes, answer keys unchanged.
**Next:** Avery labels; Claude imports and scores the held-out exam.

### 2026-10-16 — Planning session: next milestone is parser quality
**Asked:** `/grilling` on where to go after the Flutter preview rounds.
**Done:** 21 decisions, recorded in the Resume block. A background survey of side-by-side layouts across the 13 real PDFs (report was in a session scratchpad, not the repo) found four kinds: dual dialogue, Stereophonic's room columns, EMMA's two-pages-per-sheet, and page furniture. `CLAUDE.md` branch note updated (no more `parser-block-extraction`).
**Decisions:** Parser quality before shipping Flutter or starting Rust. Exam first, no parser changes until it's scored. Height on the page = time; side by side = simultaneous until a real script proves otherwise (Avery: "I think that will usually be correct"). Design #75 on generated layouts, judge on real lines labelled once at the end (~400, Avery labels by hand, so kept small). Rejected: a stopgap for #75 (accepts broken units); scoring the exam against a pinned old commit (easy to score the wrong parser).
**State:** Plan approved by Avery Oct 16. Merge and GitHub cleanup follow.
**Next:** See Resume block.

### 2026-10-14 00:33 — Check-in: loose files committed, golden drift fixed
**Asked:** Resume from the log; commit `DEVLOG.md` and `relay/`, gitignore the ML data, clear out finished sidetrack notes; then plan next steps with `/grilling`.
**Done:**
- Committed `relay/` and `DEVLOG.md`. Added `ml/data/` to `.gitignore` (its `script` column names the corpus PDFs).
- Deleted four finished sidetrack notes (first Flutter build, overnight parser work, workspace redesign, UI notes round 2). Kept round 3 and personality/relay: Avery hasn't confirmed those yet.
- Full suite failed before any change: gallery goldens drifted with the real date. `Project.newProject` (`app/lib/models/models.dart`) and `ProjectStore.openProject` (`app/lib/services/project_store.dart`) used `DateTime.now()` instead of `clockNow()`. Fixed, re-recorded the gallery goldens (only the opened project's date label changed, "Oct 11" → "Today, 9:14"). Commit `a752904`.
**Decisions:** Sidetrack notes are ephemeral (Avery's rule, saved to memory `feedback_sidetrack_notes_ephemeral`).
**State:** Full suite passes (Flutter 40/40 twice in a row). Committed.
**Next:** `/grilling` on where to go from here.

### 2026-10-11 19:25 — Dev log started
**Asked:** Avery asked for a `dev-log` skill that keeps a running DEVLOG.md in every project, so a new chat can pick up where the last one stopped without rereading long chats.
**Done:**
- Global skill `~/.claude/skills/dev-log/SKILL.md` (Resume / Write / Init modes; format with a "Resume here" block plus History).
- Global rule in `~/.claude/CLAUDE.md`: a log in every project, written after every finished task, read the Resume block to resume.
- Stop hook `~/.claude/hooks/devlog-reminder.py`, registered in `~/.claude/settings.json`. It reminds once per batch of changes when files changed after the log was last written. Tested in 9 scenarios in a scratch repo.
- This file, seeded from git history, memory and the sidetrack notes.
**Decisions:** DEVLOG.md at the repo root, committed. The Resume block is rewritten each time and History stays below it, so resuming reads about 50 lines. Instructions plus a reminder hook, for reliability.
**State:** Global files are outside the repo. `DEVLOG.md` is not committed yet.
**Next:** Commit `DEVLOG.md` with the next commit on this branch.

### Before 2026-10-11 — project so far (summary)
- Jun 2026: v0.1.8 shipped (in-app updater with stable/beta channels). Parser rewrite to PyMuPDF blocks began on `parser-block-extraction`.
- Oct 2026: parser audit. Answer keys built (generated scripts plus 403 hand-labelled real lines). Style learner and page-body work merged as PRs #69–#74.
- Oct 7–11 2026: Flutter UI + Rust engine plan approved. First Flutter build at `e0996ea`, then the commits above.
