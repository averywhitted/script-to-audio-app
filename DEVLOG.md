# Dev Log — Table Read

## Resume here
_Updated 2026-10-20 01:20 EDT · branch `ios-rehearsal` @ `aa1127c` (not pushed) · working tree: uncommitted label kit (Oct 17: `scripts/label_kit.py`, `scripts/side_by_side.py`, `label_sample.py`, `.gitignore`, `CLAUDE.md`, `.claude/launch.json`; not part of the iOS work, don't commit it with it) + two kept sidetrack notes_

**Project:** Table Read turns screenplay PDFs into per-scene `.m4a` audio dramas with TTS. Shipped app is SwiftUI (`Sources/TableRead/`) + Python backend (`backend/`); it is being rebuilt as a Flutter app (`app/`, beta v0.3.0, PR #78 still open) that drives the same Python worker.
**Current goal:** milestone **iOS rehearsal** (GitHub milestone 4, issues #88–#94): an iPhone version of the Flutter app for rehearsing and learning lines. Planned with `/grilling` on Oct 19; Avery said go.

**The plan (TLDR for Avery):** render on the Mac; projects live in an iCloud Drive folder both apps read and write; the phone is the Mac's rehearsal player on a touchscreen, plus lock-screen playback and AirPods controls; role/toggles/speed/loops/where-you-stopped sync both ways. Free Apple account, just Avery, reinstall from the Mac every 7 days.
- Steps (one issue each): #88 iCloud folder test (go/no-go) → #89 Mac changes (save full parsed `script.json` per project; rehearsal settings move from prefs `view.<id>` into a file in the project folder; "Move projects to iCloud Drive" button, archives too; handle not-downloaded files) → #90 iPhone basics (iOS target in `app/`, name "Table Read", same icon, own bundle id, project list, one-time folder pick, offline download) → #91 rehearsal screen (mockup first, then iterate) → #92 lock screen + AirPods (AirPods tap = "I said it, carry on" in Stop Before My Lines) → #93 sync (synced: role, mute/block/stop, speed, loops, position; per device: text size, highlights) → #94 on Avery's iPhone, rounds of notes.
- Facts it rests on: a rendered project is self-sufficient for rehearsal (`Scene_NN_*.cues.json` has every line's text, speaker, kind, start/end time, `ref`); the phone needs no parser or Python. `just_audio` already supports iOS.
- Out of scope: iPad layout, voice detection, $99 membership/TestFlight for castmates, full parity (import/parse/render on the phone = the Rust engine milestone). Avery: "the goal is to have complete parity with the desktop app eventually."

**Where things stand:**
- #88 spike app: `spikes/icloud_folder/` (Flutter, bundle id `com.averywhitted.icloudFolderTest`, team TX98CU7F96). Native code in `ios/Runner/AppDelegate.swift` (`FolderAccessPlugin`, channel `tableread/folder`: pick/status/list/read/write; bookmark in UserDefaults; coordinated reads that ask iCloud to download).
- **#88 PASSED and closed (Oct 19)** on Avery's iPhone 15 Pro Max (UDID 00008130-000475601803401C), free team: folder kept across relaunch, 2.3 MB scene read, phone→Mac and Mac→phone (~30 s) both work. No iCloud entitlement needed. **The iCloud Drive approach is a go.**
- Mac-side test folder `~/Library/Mobile Documents/com~apple~CloudDocs/Table Read Sync Test/` kept for #90 testing; delete when the real app reads real projects.
- **#91 built (`aa1127c`), open for Avery's notes**: `lib/phone/rehearsal_screen.dart` (script follows playback, tap to play, long-press-drag → Loop, dark bar with `SceneTimeline` (made public from `playback_bar.dart`), Rehearse panel, your-line card + Line!, Aa sheet: text size + character colors per device) and `lib/phone/rehearsal_session.dart` (rendered scenes from cue maps, text-only from script.json with corrections; saves `Rehearsal/<deviceId>.json` via native coordinated write, restores newest incl. position). `RehearsalPlayer.loadItems`. `audio_session` direct dep, spoken-audio session. Loaded both real projects through it fine. Goldens `phone_rehearse_*`, `phone_panel_*`.
- **`scripts/install_iphone.sh`**: build + sign + install on the connected iPhone (rerun weekly: free-team apps expire after 7 days).
- **#90 done (`692b6f1`)**: iOS target `app/ios` (bundle `com.averywhitted.tableread.ios`, "Table Read", Mac icon, background-audio mode), `ProjectsFolderPlugin` in `app/ios/Runner/AppDelegate.swift` (pick/folder/forget/list/download/write; Simulator-only fallback to the app's own Documents/Table Read), `lib/phone/` (welcome, cover grid, download on open, stand-in scene list), `test/phone_test.dart` + `goldens/phone_*`. `main.dart` sends iOS to `PhoneApp`. Verified in the Simulator with copies of Diana of Dobsons + TLRAD (list renders through the native code). NOT verified on the iPhone (signing blocked).
- **#89 code done (`a3ee5ca`), issue left open until Avery runs the real move.** Installed in `/Applications/Table Read Preview.app`. New `app/lib/services/project_files.dart`: `script.json` (worker parse; edits stay in project.json and are applied on top), `Rehearsal/<deviceId>.json` (one file per device, newest `updatedAt` wins, falls back to prefs `view.<id>`; also saves loop + position for #93, not restored yet), `rebaseEdits` (edits keyed by absolute PDF path get re-pointed on open). `ProjectStore.moveProjectsTo` + Settings → Projects → iPhone section. `NativePlatform.downloadFolder` on open. Re-render fingerprint no longer includes the PDF path; fingerprints are now actually saved (they never were).
- Parser-quality milestone is paused, not dropped: it resumes when Avery's exam labels come in (Avery's call, Oct 19).

**Next steps:**
1. Avery: open Table Read Preview → Settings → Projects → Move to iCloud Drive… (close any open project first). Then check: projects open, corrections still applied, nothing newly marked for re-render, `script.json` + `Rehearsal/` appear in a project folder after opening it. Then close #89.
2. Once Xcode is signed in again: `bash scripts/install_iphone.sh`, then Avery tries #90/#91 on the phone (pick iCloud Drive › Table Read after the Mac move). Real audio, scroll-follow and touch are untested on a device.
3. #92 lock screen + AirPods: background playback is already allowed (`UIBackgroundModes` audio, spoken-audio session); needs lock-screen Now Playing + remote commands (play/pause/next) mapped to the player, AirPods tap = carry on in Stop Before. Probably `audio_service` or a small native MPRemoteCommandCenter channel.
4. #93 sync: the Mac doesn't restore position/loop yet, and neither side reloads when the other device's file changes while open.

**Waiting on the user / open questions:**
- Labelling the exams (offline kit `Test PDFs/label-kit/Label lines.html`) for the parser milestone.
- Merge PR #78 (`flutter-mac-app` → `main`).
- Run the move to iCloud Drive (#89 step above).
- **Renew Xcode's Apple ID sign-in** (Xcode → Settings → Accounts; it says "No Accounts" to xcodebuild again: `IDE.Identifiers.Prod` is empty). Needed to install on the iPhone.
- Notes on the rehearsal mockup.

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

**Key files:** `app/lib/state/player_state.dart` (RehearsalPlayer, to be shared with iOS), `app/lib/ui/playback_bar.dart` (rehearsal controls), `app/lib/services/project_store.dart` (projects folder, `projectsBaseURL`), `app/lib/state/app_state.dart` (`loadView`/`saveView`: rehearsal settings in prefs today), `spikes/icloud_folder/` (#88)
**Run / test:** `bash scripts/test.sh flutter`, `bash scripts/test.sh` (full). Spike: `cd spikes/icloud_folder && flutter analyze && flutter build ios --simulator --debug`.

## History
<!-- newest first -->

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
