# 0003 — Sync between Mac and iPhone

Status: accepted (2026-10-21, Avery)

## Decision
- Transport: files in the iCloud Drive project folder (works with a free Apple account), behind a
  small sync interface so CloudKit can replace it later.
- Direction: parses and corrections/cast sync both ways; rehearsal state is per device; the Mac sends
  rendered audio, cues, status and progress; the phone sends render requests.
- Parses: `script.json` carries the parser version; the newer parser wins; corrections live in
  `project.json` and apply on top, so a re-parse never loses them. The Mac offers to re-parse a
  phone parse from an older parser.
- Merging: corrections and cast merge per entry with timestamps (newest wins, loser kept in a short
  history). Per-device state files stay newest-wins. `script.json` is replaced whole.
- Every shared file has a `schemaVersion`; devices ignore unknown fields and never rewrite a file
  whose version is newer than they understand.
- Live updates: each app watches the project folder and applies the other device's changes when idle.
- Each app writes a small status file (timestamp, app version, current render, last error). The UI
  shows a chip for the other device: Online (written in the last couple of minutes), Offline with
  "last seen", Error with the message, and an Update pending badge when the other device reports a
  newer app or file version. iOS cannot write in the background, so the Mac's iPhone chip is mostly
  "last seen".
- The Mac can start a phone's render request by itself as an opt-in setting (default off). Live
  Activity progress on the lock screen needs push and is a later milestone.

## Consequences
- iCloud Drive is not a live channel (~30 s lag measured in #88). Progress shows when the phone app
  is open.
- Closes the #93 gaps (neither side reloaded, Mac did not restore position/loop).
