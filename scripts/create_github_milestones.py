#!/usr/bin/env python3
"""
Table Read — GitHub Milestones & Issues Setup
Usage: GITHUB_TOKEN=ghp_xxx python3 scripts/create_github_milestones.py
"""

import json
import os
import sys
import urllib.request
import urllib.error

REPO   = "averywhitted/script-to-audio-app"
BASE   = "https://api.github.com"
TOKEN  = os.environ.get("GITHUB_TOKEN", "")

if not TOKEN:
    sys.exit("Set GITHUB_TOKEN before running.")

def api(method, path, body=None):
    url  = f"{BASE}{path}"
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type":  "application/json",
        "Accept":        "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        resp = json.loads(e.read())
        # 422 = already exists — treat as non-fatal for labels
        if e.code == 422:
            return resp
        print(f"  ERROR {e.code} on {method} {path}: {resp.get('message', resp)}", file=sys.stderr)
        return resp

def create_milestone(title, description):
    print(f"\n  Creating milestone: {title}")
    r = api("POST", f"/repos/{REPO}/milestones", {
        "title": title,
        "description": description,
        "state": "open",
    })
    num = r.get("number")
    if num:
        print(f"  → Milestone #{num}: {title}")
    else:
        print(f"  → Failed: {r.get('message', r)}", file=sys.stderr)
    return num

def create_issue(title, body, milestone_number, labels=None):
    payload = {
        "title":     title,
        "body":      body,
        "milestone": milestone_number,
        "labels":    labels or [],
    }
    r = api("POST", f"/repos/{REPO}/issues", payload)
    num = r.get("number")
    if num:
        print(f"    #{num}: {title}")
    else:
        print(f"    FAILED: {title} — {r.get('message', r)}", file=sys.stderr)

def ensure_labels():
    print("=== Ensuring labels exist ===")
    for name, color in [
        ("enhancement", "0075ca"),
        ("infra",       "e4e669"),
        ("design",      "f9d0c4"),
        ("polish",      "bfd4f2"),
        ("distribution","d93f0b"),
    ]:
        r = api("POST", f"/repos/{REPO}/labels", {"name": name, "color": color})
        if r.get("name"):
            print(f"  label: {name}")


# ─────────────────────────────────────────────────────────────────────────────
# MILESTONE 1 — Voice Engines
# ─────────────────────────────────────────────────────────────────────────────

VOICE_ISSUES = [
    (
        "Kokoro local TTS integration",
        """\
Implement the Kokoro voice engine end-to-end.

- [ ] Download Apache-licensed model weights on demand
- [ ] Wire up `backend/tts_engines.py` KokoroEngine class
- [ ] Flip `isSupported = true` in `EngineKind`
- [ ] Streaming progress works the same as macOS engine
- [ ] Voice list returned with gender hints

Kokoro produces near-neural quality offline; highest-value addition after macOS voices.""",
        ["enhancement"],
    ),
    (
        "Piper local TTS integration",
        """\
Implement the Piper ONNX voice engine.

- [ ] Bundle or download ONNX voice files on demand
- [ ] Wire up `backend/tts_engines.py` PiperEngine class
- [ ] Flip `isSupported = true` in `EngineKind`
- [ ] Voice listing with locale info

Piper is fast and small — good for previews and lower-spec machines.""",
        ["enhancement"],
    ),
    (
        "OpenAI TTS: preflight check and partial resume",
        """\
Before committing to a full render, offer a preflight pass that validates the key and RPM headroom, then allows resuming from the last successful scene if the job is interrupted.

- [ ] Preflight endpoint call (validate key, check quota)
- [ ] Persist completed scene files and skip them on re-run
- [ ] Clearer rate-limit error messages with estimated retry time""",
        ["enhancement"],
    ),
    (
        "Voice preview: listen before committing",
        """\
Add a 'Preview' button per character row in the Cast step that renders one line with the assigned voice before the user starts full generation.

- [ ] Short sample text rendered via the chosen engine
- [ ] Plays inline in the app (AVPlayer or `NSSound`)
- [ ] Disabled while a full generation is running""",
        ["enhancement"],
    ),
    (
        "Engine download manager UI",
        """\
Replace the plain alert with a proper download sheet that shows real progress for Kokoro and Piper model files.

- [ ] Download progress bar per model file
- [ ] Cancel in-flight download
- [ ] Disk space pre-check""",
        ["enhancement", "infra"],
    ),
]

# ─────────────────────────────────────────────────────────────────────────────
# MILESTONE 2 — Packaging & Distribution
# ─────────────────────────────────────────────────────────────────────────────

PACKAGING_ISSUES = [
    (
        "Bundle Python runtime and virtualenv into the app bundle",
        """\
The app currently requires Python 3 and a virtualenv on the host machine. For a distributable build the entire runtime must be embedded.

- [ ] Evaluate options: python-build-standalone embedded CPython, PyInstaller frozen bundle, or Briefcase
- [ ] Settle on approach and document in CLAUDE.md
- [ ] `PythonBridge.swift` `findRepositoryRoot()` already checks `Bundle.main.url(forResource:)` — wire this up
- [ ] Verify all backend imports resolve inside the bundle (pdfminer, openai, etc.)""",
        ["infra"],
    ),
    (
        "Xcode project / proper .app bundle",
        """\
Replace the SPM-only build with a proper Xcode project so we can set bundle ID, version, entitlements, and build a real .app.

- [ ] Create `TableRead.xcodeproj` alongside `Package.swift`
- [ ] Set bundle ID `com.tableread`
- [ ] Configure entitlements: network (for OpenAI), file access
- [ ] Add Info.plist with `CFBundleDocumentTypes` for .pdf drag-and-drop
- [ ] Keep SPM package working for `swift run` dev workflow""",
        ["infra"],
    ),
    (
        "Code signing and notarization",
        """\
Unsigned apps require Gatekeeper override on every user's machine. Table Read should be signed and notarized for a frictionless install.

- [ ] Apple Developer account / certificates
- [ ] Automated notarization via `notarytool` in CI
- [ ] Hardened runtime entitlements audit""",
        ["infra", "distribution"],
    ),
    (
        "DMG installer",
        """\
Package the signed .app as a drag-to-install DMG with a background image and Applications symlink.

- [ ] `create-dmg` or `hdiutil` script
- [ ] Background image with Table Read branding
- [ ] Version number embedded in filename (e.g. `TableRead-1.0.dmg`)""",
        ["distribution", "design"],
    ),
    (
        "GitHub Releases CI pipeline",
        """\
Automate the build → sign → notarize → DMG → release workflow on every version tag.

- [ ] GitHub Actions workflow triggered on `v*` tags
- [ ] Secrets for signing cert + notarization credentials
- [ ] Attach DMG to GitHub Release automatically
- [ ] Update release notes from CHANGELOG""",
        ["infra", "distribution"],
    ),
    (
        "Decide distribution channel: direct vs Mac App Store",
        """\
Evaluate pros and cons of Mac App Store vs direct DMG distribution.

Considerations: sandbox restrictions on subprocess spawning (Python bridge may not be App Store compatible), review timeline, 30% cut vs direct, auto-update (Sparkle vs App Store), discoverability.

- [ ] Prototype App Store sandbox with a test entitlement set
- [ ] Document the decision here with rationale""",
        ["distribution"],
    ),
]

# ─────────────────────────────────────────────────────────────────────────────
# MILESTONE 3 — Visual Identity & Quality of Life
# ─────────────────────────────────────────────────────────────────────────────

POLISH_ISSUES = [
    (
        "App icon",
        """\
Design and integrate a proper app icon for Table Read.

- [ ] Concept: evokes a script/screenplay + audio/waveform — a table read is actors sitting around a table reading aloud
- [ ] All required macOS icon sizes (16–1024 @1x/@2x) in an .icns / .xcassets
- [ ] Works well in both light and dark Dock""",
        ["design"],
    ),
    (
        "Semantic color system and dark/light mode polish",
        """\
Audit every hardcoded color and replace with semantic tokens so the app looks intentional in both appearances.

- [ ] Define a small color palette in an `AppColors` file (primary accent, success, warning, error, surface)
- [ ] Replace remaining `Color.orange`, `Color.green` etc. with semantic references
- [ ] Test all four views in light + dark + increased contrast""",
        ["design", "polish"],
    ),
    (
        "Settings panel (⌘,)",
        """\
Add a Settings window with user-configurable preferences.

- [ ] Default output directory (currently per-PDF)
- [ ] Default voice engine
- [ ] Default narrator voice
- [ ] OpenAI API key (move from Cast step to Settings)
- [ ] Theme override (system / light / dark)""",
        ["enhancement", "polish"],
    ),
    (
        "In-app bug reporting",
        """\
Make it easy for users to file a bug without leaving the app.

- [ ] 'Report a Bug' menu item under Help
- [ ] Collects: app version, macOS version, last generation log
- [ ] Opens a pre-filled GitHub issue URL in the browser (no sending data without consent)
- [ ] Option to copy log to clipboard instead""",
        ["polish"],
    ),
    (
        "About panel and donation / support link",
        """\
Standard macOS About window plus a way to support development.

- [ ] About panel: app name, version, credits, GitHub link
- [ ] 'Support Table Read' button linking to Ko-fi / GitHub Sponsors / similar
- [ ] Keep it tasteful — one link, not a paywall""",
        ["polish"],
    ),
    (
        "Onboarding experience for first launch",
        """\
New users land on the Import step with no context. Add a lightweight first-launch guide.

- [ ] Welcome sheet on first launch explaining the four steps
- [ ] 'Don't show again' checkbox
- [ ] Sample PDF bundled so users can try the app immediately""",
        ["enhancement", "polish"],
    ),
    (
        "Menu bar: File > Open and recent files",
        """\
Implement the macOS-standard File menu so the app feels native.

- [ ] File > Open (⌘O) — same as the Import step button
- [ ] File > Open Recent (using `NSDocumentController` or manual recent list)
- [ ] File > Show in Finder for the current output directory""",
        ["polish"],
    ),
]


def main():
    ensure_labels()

    print("\n=== Milestone 1: Voice Engines ===")
    m1 = create_milestone(
        "Voice Engines",
        "Support local high-quality voices (Kokoro, Piper) and polish the OpenAI TTS route. Goal: every engine card is fully functional.",
    )
    if m1:
        for title, body, labels in VOICE_ISSUES:
            create_issue(title, body, m1, labels)

    print("\n=== Milestone 2: Packaging & Distribution ===")
    m2 = create_milestone(
        "Packaging & Distribution",
        "Ship Table Read as a self-contained macOS app. No Python installation required. Target: signed DMG anyone can drag to /Applications.",
    )
    if m2:
        for title, body, labels in PACKAGING_ISSUES:
            create_issue(title, body, m2, labels)

    print("\n=== Milestone 3: Visual Identity & Quality of Life ===")
    m3 = create_milestone(
        "Visual Identity & Quality of Life",
        "Give Table Read a distinct look, feel, and personality. Ship settings, bug reporting, and support options so real users can actually use it.",
    )
    if m3:
        for title, body, labels in POLISH_ISSUES:
            create_issue(title, body, m3, labels)

    print(f"\n=== Done ===")
    print(f"Milestones: #{m1} Voice Engines  |  #{m2} Packaging  |  #{m3} Visual Identity & QoL")
    print(f"https://github.com/{REPO}/milestones")


if __name__ == "__main__":
    main()
