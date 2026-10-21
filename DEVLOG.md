# Dev Log — Table Read

## Resume here
_Updated 2026-10-21 15:40 EDT · branch `ios-rehearsal` @ `342c1e9` (not pushed) · working tree: ADRs and the spike committed (see git log); uncommitted: Oct 17 label-kit files and two sidetrack notes that are not part of this work (don't commit them with it)_

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

**Where things stand (#99 PDFium spike, `spikes/pdfium_extract/`; README there lists what the builder has to do):**
- **The Python prototype passes the Q7 gate**: `.venv/bin/python3 spikes/pdfium_extract/scripts/pdfium_answer_key.py --check` (38 s) patches `parser._extract_blocks` with a PDFium-based builder (pypdfium2 = same PDFium, existing `libpdfium.dylib` in `.venv`, nothing downloaded) and reports "Nothing got worse": generated scripts 99.4% (= baseline, 0 broken), real sample 98.5% (= baseline, 0 broken). Progression: naive 91.4% / 81.4% -> fixes below -> 99.4% / 98.5%. Never `--save` from the wrapper.
- What fixed it, in order of effect: MuPDF-style block boundaries (new block when a line is indented over 0.25 em more than the previous, jumps up, or drops over 1.45 em: reproduces 19349 of 19357 boundaries); splitting lines at large forward gaps (inline `NAME:` + hanging dialogue); ignoring PDFium's synthetic spaces for line decisions and adding spaces by gap (0.1 em); PageToDevice coordinates; text-matrix scale for size; near-vertical text; content-stream order plus text objects the text page drops (lone " " after a line = MuPDF's trailing space, blank lines).
- Line text agrees with PyMuPDF on 99.4% of 50k lines across the 13 corpus PDFs. Known gaps (not gate-relevant yet): trailing-space width (0.25 em assumed, Courier is 0.6 em) so some right edges are one space off; non-standard non-embedded fonts get slightly different line heights; page rotation untested; EMMA 4960 lines vs 4746.
- 14 standard-font line metrics measured from PyMuPDF are in `spikes/pdfium_extract/base14_metrics.json`.
- **The Rust crate is NOT started: Homebrew cargo cannot reach `index.crates.io`** ("Couldn't resolve host" although `curl` works, the same DNS issue that makes `gh` need `GODEBUG=netdns=go`). A local CONNECT-proxy workaround was refused by the sandbox classifier, so don't try workarounds. Likely fix, needs Avery's OK: install rustup (also needed for iOS targets, #98) and use its cargo.

**Next steps:**
1. Ask Avery to approve installing rustup (official installer from rustup.rs), then port the builder to Rust with `pdfium-render` (#99), checking it against the same reference dumps (`out/*.pymupdf.json`, regenerate with `scripts/dump_pymupdf.py`) and then the real gate. Use `libpdfium.dylib` from `.venv/lib/python3.14/site-packages/pypdfium2_raw/` locally; iOS needs a static PDFium build. In Rust, check that `pdfium-render` exposes what the Python prototype used (text objects in stream order incl. empty ones, FPDFText_GetLooseCharBox, FPDF_PageToDevice equivalents, font ascent/descent).
2. Close the known gaps above (trailing-space width, rotated pages) and test on more PDFs than the corpus (exam sample, other producers).
3. Then #100 (parser port).
4. Still waiting from the iPhone milestone: Avery runs the Mac "Move to iCloud Drive" (#89), tries round 2 on the phone incl. lock screen + AirPods (#92), renews Xcode's Apple ID sign-in to reinstall (`bash scripts/install_iphone.sh`, weekly).

**Waiting on the user / open questions:**
- OK to install rustup (see step 2).
- Labelling the exams (offline kit `Test PDFs/label-kit/Label lines.html`); parser quality work is paused until after the Rust parser cutover (Python parser frozen).
- Merge PR #78 (`flutter-mac-app` -> `main`). Run the move to iCloud Drive (#89). Notes on the rehearsal mockup / round 2.
- Verify before relying on them: the research agent's sherpa-onnx news (espeak removal, Oct 20 2026), Piper `lessac` voice license, `flutter_rust_bridge` static linking on iOS/macOS 2026 (Xcode symbol stripping), `ort` is still a release candidate.

**Watch out for:**
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
