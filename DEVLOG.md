# Dev Log — Table Read

## Resume here
_Updated 2026-10-14 00:33 EDT · branch `flutter-mac-app` @ `a752904` · working tree: clean except two kept sidetrack notes (`sidetrack-personality-relay.md`, `sidetrack-ui-notes-3.md`)_

**Project:** Table Read turns screenplay PDFs into per-scene `.m4a` audio dramas with TTS. The shipped app is SwiftUI (`Sources/TableRead/`) with a Python backend (`backend/`) over a stdin/stdout JSON bridge. It is being rebuilt as a Flutter app (`app/`) that drives the same Python worker.
**Current goal:** Flutter macOS preview app with the Claude Design "1a v2" redesign, refined in rounds of UI notes from Avery. This is step one of the approved plan: Flutter UI plus a Rust engine for all 5 platforms (see memory `platform_strategy.md`).

**Where things stand:**
- Flutter preview builds and is signed: `app/build/macos/Build/Products/Release/Table Read Preview.app` (bundle id `com.averywhitted.tableread.preview`). It runs the repo's backend live, so it always has the current parser.
- Done on this branch: workspace redesign with no side panel, three rounds of UI notes, playback/highlight sync by stable line ids, text size, Export Audio, personality pass. Avery hasn't given notes on the personality pass yet.
- Bug-report relay (`relay/src/worker.js`, Cloudflare Worker) is committed but **not deployed**: Avery has to create the Cloudflare account and GitHub token. Issue #77.
- Full test suite passes as of `a752904` (Python, Swift, Flutter 40/40).
- Parser work (PRs #69–#74) is merged to `main`. Baselines: generated 99.4%, real sample 98.5%. The held-out exam sample is drawn but not labelled.

**Next steps:**
1. Run the planning session Avery asked for (`/grilling`): decide where to go next. Candidates: PR `flutter-mac-app` → `main`; Dart port of the updater; first-launch importer for the Swift app's settings and Keychain item; deploy the relay (#77); #76; labelling the exam sample.
2. When Avery's notes on the personality pass come in: before shipping each round, re-check earlier fixes in the goldens (memory `feedback_ui_regressions.md`). Delete `sidetrack-ui-notes-3.md` and `sidetrack-personality-relay.md` once Avery confirms those rounds.

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
