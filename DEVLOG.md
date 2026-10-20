# Dev Log — Table Read

## Resume here
_Updated 2026-10-19 15:38 EDT · branch `flutter-mac-app` @ `e4f1f61` (pushed; tag `v0.3.0`; PR #78 open) · working tree: uncommitted label kit (Oct 17) + this file; two kept sidetrack notes (`sidetrack-personality-relay.md`, `sidetrack-ui-notes-3.md`)_

**Project:** Table Read turns screenplay PDFs into per-scene `.m4a` audio dramas with TTS. The shipped app is SwiftUI (`Sources/TableRead/`) with a Python backend (`backend/`) over a stdin/stdout JSON bridge. It is being rebuilt as a Flutter app (`app/`) that drives the same Python worker.
**Current goal:** Flutter macOS preview app with the Claude Design "1a v2" redesign, refined in rounds of UI notes from Avery. This is step one of the approved plan: Flutter UI plus a Rust engine for all 5 platforms (see memory `platform_strategy.md`).

**Where things stand:**
- Flutter preview builds and is signed: `app/build/macos/Build/Products/Release/Table Read Preview.app` (bundle id `com.averywhitted.tableread.preview`). That build runs the repo's backend live.
- **Installed copy:** `/Applications/Table Read Preview.app` is self-contained (backend + `vendor/python` bundled), made by `bash scripts/build_flutter_app.sh`. It does NOT follow the repo: rerun the script after backend/UI changes. The old Swift `/Applications/TableRead.app` is untouched.
- **Beta v0.3.0 (Oct 19) is the Flutter app**, a GitHub prerelease with `TableRead-Preview.{dmg,zip,sha256}` (`bash scripts/build_flutter_app.sh --package`). The asset names deliberately differ from `TableRead.zip`: Swift beta-channel users get a link to the release page, never an auto-install (Avery's choice). Apple Silicon only (bundled Python is arm64), Development-signed (Gatekeeper right-click → Open).
- Done on this branch: workspace redesign with no side panel, three rounds of UI notes, playback/highlight sync by stable line ids, text size, Export Audio, personality pass. Avery hasn't given notes on the personality pass yet.
- Bug-report relay (`relay/src/worker.js`, Cloudflare Worker) is committed but **not deployed**: Avery has to create the Cloudflare account and GitHub token. Issue #77.
- Full test suite passes as of `a752904` (Python, Swift, Flutter 40/40).
- Parser work (PRs #69–#74) is merged to `main`. Baselines: generated 99.4%, real sample 98.5%. The held-out exam (`Test PDFs/reference/real_sample.exam.json`) is 260/403 labelled; 143 left across 13 PDFs.
- **Plan decided (`/grilling`, Oct 14–16; awaiting Avery's final go-ahead).** Next milestone is **parser quality** (not shipping Flutter, not Rust). Avery labels the exam → score #69–#74 on it (pass = range overlaps 98.5% ± 2.5; if clearly lower, look at error categories, never exam lines). Exam scored once for this, then a normal judge. **No parser changes land until it's scored.** UI notes from Avery interrupt parser work when they arrive.
  - Then, in order: #68 (learn the script's own acts/scenes; else "Part N", current chunk size, never announced) → furniture bugs (INATH margin scene number read twice; Stereophonic author's note read by "D A V I D") → #75 split in three: column splitting at extraction → dual dialogue → room columns + reading order → side-by-side exam (~400 lines, Avery labels by hand once at the end, new "spoken at the same time as" field).
  - Side-by-side rule: **height on the page = time.** Lines next to each other are simultaneous (voices mixed, `overlap_voices`) until a real script proves otherwise; no exception rules built in advance. Action is read by the narrator in height order. EMMA's two-pages-per-sheet is already handled.
  - #75 is designed on new generated layout families (dual dialogue, room columns) in `synth_generate.py`, not on real lines. Survey of side-by-side kinds in the corpus: 37 dual-dialogue regions (~240 lines, 7 PDFs); Stereophonic room columns 10% right voice; #75's text is wrong that right-column names aren't recognised.
  - Out of scope: ML hybrid, #19, calibration wizard, #76, relay deploy (#77).

**Next steps:**
1. Avery merges PR #78 (`flutter-mac-app` → `main`); auto mode blocked Claude from merging without review. CI passed on the same commit's push run.
2. Run the prepared GitHub cleanup script (closes #21–26, #13, #52, #42, #75, PRs #54/#56; creates the "Parser quality" milestone and 9 issues; comments on #68). It was dry-run against a fake `gh`; its text is the source for those issues. `gh` needs `GODEBUG=netdns=go` on this Mac: the system resolver times out on api.github.com (Tailscale DNS); the script sets it.
3. Avery: label both exams in the offline kit (`Test PDFs/label-kit/Label lines.html`, double-click; 143 held-out + 400 side-by-side lines), Export, then Claude runs `python scripts/label_kit.py --import`. Score the held-out exam first; the side-by-side labels stay unread until steps 1–3 are done and review the latest preview build in depth. Delete `sidetrack-ui-notes-3.md` and `sidetrack-personality-relay.md` once Avery confirms those rounds.

**Waiting on the user / open questions:**
- Deploying the relay (#77): needs Avery's Cloudflare account and a fine-grained GitHub token. Claude can't create accounts or handle tokens.
- #76: ask about uncertain lines instead of showing a flagged-lines navigator? Proposed, not built.
- Open a PR from `flutter-mac-app` to `main`?

**Watch out for:**
- `sidetrack-*.md` notes are ephemeral: delete each once its task is confirmed done; never commit them.
- Avery catches UI regressions by eye. The options cluster must stay pinned far top-right, and playback must scroll to the playing line.
- Goldens: record with the whole file (`flutter test --update-goldens test/screens_test.dart`), never a single test. Earlier tests open a project, which changes the gallery's order. Use `clockNow()`, never `DateTime.now()`, for anything a golden shows.
- `app/test/failures/` is tracked in git by mistake (old diff images). Don't `rm -rf` it in a commit unless removing it on purpose.
- `ml/data/` is gitignored: `dataset.csv` names the corpus PDFs, like `real_sample*.json`.
- Parser edits must follow the answer-key protocol in `CLAUDE.md` (`python scripts/answer_key.py`; nothing right may go wrong).
- Builds are signed with Avery's Apple Development cert (team TX98CU7F96) so macOS doesn't re-prompt for Documents access.

**Key files:** `app/lib/` (Flutter UI), `design/table-read-ui-contract.json` (screens and labels the UI must match), `backend/audio_worker.py` (worker protocol), `relay/src/worker.js`
**Run / test:** `bash scripts/test.sh flutter` (analyze + logic/screen/worker tests), `bash scripts/test.sh` (full suite).

## History
<!-- newest first -->

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
