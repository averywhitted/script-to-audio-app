# GitHub Issues — iOS Version of Table Read

Paste each block below into a new GitHub issue. Suggested labels are noted at the top of each one.

---

## Issue 1 — [Epic] iOS Platform Support

**Labels:** `epic`, `ios`, `enhancement`

### Summary
Track all work required to bring Table Read to iPhone and iPad as a native iOS app.

### Motivation
Table Read currently runs only on macOS. An iOS version would let users review and play back audio renders on the go — especially useful during rehearsals and on set.

### Scope
This epic covers everything needed to ship a v1 iOS app:

- [ ] #2 — Multi-platform Xcode target + shared Swift package
- [ ] #3 — Replace Python TTS backend with on-device AVSpeechSynthesizer
- [ ] #4 — iOS file import via document picker
- [ ] #5 — Adapt SwiftUI views for touch (no hover)
- [ ] #6 — Scene overview touch interactions
- [ ] #7 — iOS audio session & background playback
- [ ] #8 — iOS notifications
- [ ] #9 — In-app settings UI (replace macOS Settings scene)
- [ ] #10 — iCloud sync for corrections and preferences
- [ ] #11 — App Store submission pipeline

### Out of scope for v1
- iPad-specific split-view layout
- Handoff / Continuity between Mac and iOS
- Remote/cloud TTS engines (may revisit post-v1 for higher-quality voices)

---

## Issue 2 — Multi-platform Xcode target + shared Swift package

**Labels:** `ios`, `infrastructure`

### Summary
Add an iOS app target to `TableRead.xcodeproj` and extract shared models into a local Swift package so both the macOS and iOS targets can consume them without duplication.

### Tasks
- Add an `iOS` target (`TableRead-iOS`) to the existing Xcode project
- Create a `TableReadCore` local Swift package containing:
  - `Models.swift` (`ParserCorrection`, `UserAddedElement`, `MergedSceneElement`, `AnonymousCorrection`, etc.)
  - `AppState.swift` (with platform-conditional sections where needed)
- Keep macOS-only code (`PythonBridge.swift`, `SettingsView.swift`) in the macOS target
- Confirm both targets build clean in Xcode

### Notes
Use `#if os(iOS)` / `#if os(macOS)` for any divergent code rather than duplicating files.

---

## Issue 3 — Replace Python TTS backend with on-device AVSpeechSynthesizer

**Labels:** `ios`, `audio`, `core`

### Summary
The macOS app shells out to a Python process for TTS via `PythonBridge`. iOS cannot run arbitrary Python processes. For the iOS version, synthesis must happen on-device using `AVSpeechSynthesizer`, or optionally via a remote API.

### Approach (v1 — on-device)
- Implement `IOSSpeechBridge` using `AVSpeechSynthesizer` and `AVSpeechUtterance`
- Map each scene element's `kind`/`speaker` to a voice identifier (`AVSpeechSynthesisVoice`)
- Queue utterances per scene and export to an `AVAudioFile` for playback and export
- Wire progress callbacks to mirror the existing `GenerationEvent` enum so `AppState` and the UI need minimal changes

### Voice assignment
- Reuse the existing `VoiceAssignment` model
- On iOS, enumerate available voices with `AVSpeechSynthesisVoice.speechVoices()` and present them in the voice picker

### Future option
Add an optional remote TTS path (ElevenLabs, OpenAI, etc.) behind a toggle for users who want higher-quality voices and are okay with an internet connection.

### Acceptance criteria
- A scene can be rendered to an audio file on an iOS simulator and device
- Progress events fire in the same order as the macOS Python backend

---

## Issue 4 — iOS file import via document picker

**Labels:** `ios`, `ui`

### Summary
On macOS, the app uses `NSOpenPanel` to let users pick a PDF. On iOS, file access goes through `UIDocumentPickerViewController` (or the SwiftUI `.fileImporter` modifier).

### Tasks
- Replace `NSOpenPanel` usage with `.fileImporter(isPresented:allowedContentTypes:onCompletion:)` in the iOS target
- Handle security-scoped bookmarks so the app can re-open recently used PDFs without prompting again
- Display recently opened files in the home screen (reuse the existing `recentFiles` model if present)

---

## Issue 5 — Adapt SwiftUI views for touch (no hover)

**Labels:** `ios`, `ui`

### Summary
Several macOS UI patterns don't translate to iOS:
- Hover states (`.onHover`) are not available on iOS
- `NavigationSplitView` sidebar layout needs an iOS-appropriate navigation stack
- Toolbar items and window chrome differ

### Tasks
- Audit all `.onHover` usages and replace with tap-to-reveal or swipe actions on iOS (use `#if os(macOS)` guards)
- Replace `NavigationSplitView` with `NavigationStack` + `List` on iOS
- Adapt the main `ContentView` layout to a single-column, scrollable structure on iPhone; consider a two-column layout on iPad
- Ensure all touch targets are at least 44×44 pt

---

## Issue 6 — Scene overview touch interactions (add line, corrections)

**Labels:** `ios`, `ui`

### Summary
The macOS scene overview uses hover to reveal an "Add line" pill and edit controls on each element. On iOS these need to be exposed via tap or swipe gestures.

### Tasks
- Replace hover-triggered "Add line" pill with a contextual button revealed by long-press or a visible `+` row between elements
- Replace hover-triggered edit/delete on `AddedElementRow` with swipe-to-delete and a tap-to-edit popover
- Replace correction affordances (right-click or hover) with a long-press context menu (`contextMenu` modifier)
- Test on 390pt (iPhone 15 Pro) and 744pt (iPad mini) widths

---

## Issue 7 — iOS audio session & background playback

**Labels:** `ios`, `audio`

### Summary
iOS requires explicit `AVAudioSession` configuration for audio playback, and Background Modes must be enabled for audio to continue when the screen locks or the user switches apps.

### Tasks
- Configure `AVAudioSession.sharedInstance()` with `.playback` category at app launch
- Enable "Audio, AirPlay, and Picture in Picture" background mode in the iOS target's entitlements
- Handle audio session interruptions (phone calls, Siri) — pause render/playback and resume when appropriate
- Add a Now Playing info (`MPNowPlayingInfoCenter`) entry so the Lock Screen shows the current scene and play/pause works from Control Center

---

## Issue 8 — iOS notifications

**Labels:** `ios`, `notifications`

### Summary
The macOS app uses `UNUserNotificationCenter` for scene and render completion notifications. The same framework works on iOS, but foreground presentation and permission prompts behave differently.

### Tasks
- Reuse the existing `UNUserNotificationCenter` notification code (it's already cross-platform)
- Request notification permission at an appropriate moment (e.g., when the user first starts a render)
- Confirm `UNUserNotificationCenterDelegate` foreground presentation options work correctly on iOS
- Add notification settings toggles to the iOS in-app settings screen (see Issue #9)

---

## Issue 9 — In-app settings UI (replace macOS Settings scene)

**Labels:** `ios`, `ui`

### Summary
The macOS app uses `Settings { ... }` scene, which renders as a standard macOS Preferences window. iOS has no equivalent — settings must live inside the app as a sheet or a dedicated view.

### Tasks
- Build an `IOSSettingsView` with the same sections as the macOS `SettingsView`:
  - General (default export directory equivalent, recent files)
  - Voices (voice assignments per character kind)
  - Notifications (scene complete, render complete, render failed toggles)
  - Corrections (opt-in toggle, manual upload trigger)
  - About (app icon, version, GitHub link)
- Present it from a gear icon in the navigation bar
- Back all toggles with the same `@AppStorage` keys as macOS so any shared iCloud defaults sync correctly

---

## Issue 10 — iCloud sync for corrections and preferences

**Labels:** `ios`, `infrastructure`

### Summary
User preferences and parser corrections are currently stored in `UserDefaults` and a local JSON file. On iOS, these should optionally sync across the user's devices via iCloud.

### Tasks
- Move correction storage to `NSUbiquitousKeyValueStore` (for small payloads) or a `CloudKit` private database
- Use `NSUbiquitousKeyValueStore` for lightweight preferences (notification toggles, voice assignments) as a starting point
- Add a "Sync with iCloud" toggle in settings (default on) with a graceful fallback to local-only if iCloud is unavailable
- Ensure the auto-upload-to-Cloudflare corrections pipeline continues to work independently of iCloud sync status

---

## Issue 11 — App Store submission pipeline

**Labels:** `ios`, `infrastructure`, `distribution`

### Summary
Unlike the macOS version (distributed as an ad-hoc signed DMG), the iOS app must go through the App Store. This requires an Apple Developer account and submission infrastructure.

### Tasks
- Enroll in (or confirm existing) Apple Developer Program ($99/yr)
- Create an App ID and provisioning profile for `com.averywhitted.tableread-ios` (or reuse the existing bundle ID with an iOS platform slice)
- Add an App Store Connect record for Table Read iOS
- Configure `scripts/build_ios_archive.sh` to:
  - `xcodebuild archive` for the iOS scheme
  - `xcodebuild -exportArchive` with `method: app-store`
- Write `scripts/ExportOptions-iOS.plist` with `method = app-store`
- Set up App Store screenshots (6.9" iPhone, 13" iPad Pro at minimum)
- Write a short App Store description and privacy policy URL (required because the app can optionally upload anonymous correction data)

### Notes
- TestFlight is a good first step before public release — share the build via TestFlight while the review is pending
- The corrections upload feature means a privacy policy URL is required in App Store Connect

---
