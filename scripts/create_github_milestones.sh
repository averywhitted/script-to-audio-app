#!/usr/bin/env bash
# =============================================================================
# Table Read — GitHub Milestones & Issues Setup
# =============================================================================
# Usage:
#   1. Create a GitHub personal access token at https://github.com/settings/tokens
#      (needs repo scope, or a fine-grained token with Issues read/write)
#   2. Run: GITHUB_TOKEN=ghp_xxx bash scripts/create_github_milestones.sh
# =============================================================================

set -euo pipefail

REPO="averywhitted/script-to-audio-app"
API="https://api.github.com"
AUTH="Authorization: Bearer ${GITHUB_TOKEN:?Set GITHUB_TOKEN before running}"
CT="Content-Type: application/json"

create_milestone() {
  local title="$1" desc="$2" due="$3"
  local body="{\"title\":$(echo "$title"|python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))'),\"description\":$(echo "$desc"|python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}"
  if [ -n "$due" ]; then
    body=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); d['due_on']='${due}T07:00:00Z'; print(json.dumps(d))")
  fi
  curl -sS -X POST "$API/repos/$REPO/milestones" -H "$AUTH" -H "$CT" -d "$body" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['number'])"
}

create_issue() {
  local title="$1" body="$2" milestone="$3"
  shift 3
  local labels_json="[]"
  if [ $# -gt 0 ]; then
    labels_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "$@")
  fi
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
  'title': sys.argv[1],
  'body':  sys.argv[2],
  'milestone': int(sys.argv[3]),
  'labels': json.loads(sys.argv[4]),
}))
" "$title" "$body" "$milestone" "$labels_json")
  curl -sS -X POST "$API/repos/$REPO/issues" -H "$AUTH" -H "$CT" -d "$payload" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('#'+str(d['number'])+' '+d['title'])"
}

# ---------------------------------------------------------------------------
echo "=== Creating labels (skips if already exist) ==="
for label_spec in \
  "enhancement:0075ca" \
  "infra:e4e669" \
  "design:f9d0c4" \
  "polish:bfd4f2" \
  "distribution:d93f0b"
do
  name="${label_spec%%:*}"
  color="${label_spec##*:}"
  curl -sS -X POST "$API/repos/$REPO/labels" -H "$AUTH" -H "$CT" \
    -d "{\"name\":\"$name\",\"color\":\"$color\"}" > /dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Milestone 1: Voice Engines ==="
M1=$(create_milestone \
  "Voice Engines" \
  "Support local high-quality voices (Kokoro, Piper) and polish the OpenAI TTS route. Goal: every engine card is fully functional." \
  "")
echo "  Created milestone #$M1"

create_issue "Kokoro local TTS integration" \
"Implement the Kokoro voice engine end-to-end.

- [ ] Download Apache-licensed model weights on demand
- [ ] Wire up \`backend/tts_engines.py\` KokoroEngine class
- [ ] Flip \`isSupported = true\` in \`EngineKind\`
- [ ] Streaming progress works the same as macOS engine
- [ ] Voice list returned with gender hints

Kokoro produces near-neural quality offline; this is the highest-value addition after macOS voices." \
"$M1" enhancement

create_issue "Piper local TTS integration" \
"Implement the Piper ONNX voice engine.

- [ ] Bundle or download ONNX voice files on demand
- [ ] Wire up \`backend/tts_engines.py\` PiperEngine class
- [ ] Flip \`isSupported = true\` in \`EngineKind\`
- [ ] Voice listing with locale info

Piper is fast and small — good for previews and lower-spec machines." \
"$M1" enhancement

create_issue "OpenAI TTS: preflight check and partial resume" \
"Before committing to a full OpenAI render, offer a preflight pass that verifies the key and RPM headroom, then allows resuming from the last successful scene if the job is interrupted.

- [ ] Preflight endpoint call (validate key, check quota)
- [ ] Persist completed scene files and skip them on re-run
- [ ] Clearer rate-limit error messages with estimated retry time" \
"$M1" enhancement

create_issue "Voice preview: listen before committing" \
"Add a 'Preview' button per character row in the Cast step that renders one line with the assigned voice before the user starts full generation.

- [ ] Short sample text rendered via the chosen engine
- [ ] Plays inline in the app (AVPlayer or \`NSSound\`)
- [ ] Disabled while a full generation is running" \
"$M1" enhancement

create_issue "Engine download manager UI" \
"Replace the plain alert with a proper download sheet that shows real progress for Kokoro and Piper model files.

- [ ] Download progress bar per model file
- [ ] Cancel in-flight download
- [ ] Disk space pre-check" \
"$M1" enhancement infra

# ---------------------------------------------------------------------------
echo ""
echo "=== Milestone 2: Packaging & Distribution ==="
M2=$(create_milestone \
  "Packaging & Distribution" \
  "Ship Table Read as a self-contained macOS app. No Python installation required. Target: signed DMG anyone can drag to /Applications." \
  "")
echo "  Created milestone #$M2"

create_issue "Bundle Python runtime and virtualenv into the app bundle" \
"The app currently requires Python 3 and a virtualenv on the host machine. For a distributable build the entire runtime must be embedded.

- [ ] Evaluate options: embedded CPython (python-build-standalone), pyinstaller frozen bundle, or Briefcase
- [ ] Settle on approach and document in CLAUDE.md
- [ ] \`PythonBridge.swift\` \`findRepositoryRoot()\` already checks \`Bundle.main.url(forResource:)\` — wire this up
- [ ] Verify all backend imports resolve inside the bundle (pdfminer, openai, etc.)" \
"$M2" infra

create_issue "Xcode project / proper .app bundle" \
"Replace the SPM-only build with a proper Xcode project so we can set bundle ID, version, entitlements, and build a real .app.

- [ ] Create \`TableRead.xcodeproj\` alongside \`Package.swift\`
- [ ] Set bundle ID \`com.tableread\`
- [ ] Configure entitlements: network (for OpenAI), file access
- [ ] Add Info.plist with \`CFBundleDocumentTypes\` for .pdf drag-and-drop
- [ ] Keep SPM package working for \`swift run\` dev workflow" \
"$M2" infra

create_issue "Code signing and notarization" \
"Unsigned apps require Gatekeeper override on every user's machine. Table Read should be signed and notarized for a frictionless install.

- [ ] Apple Developer account / certificates
- [ ] Automated notarization via \`notarytool\` in CI
- [ ] Hardened runtime entitlements audit" \
"$M2" infra distribution

create_issue "DMG installer" \
"Package the signed .app as a drag-to-install DMG with a background image and Applications symlink.

- [ ] \`create-dmg\` or \`hdiutil\` script
- [ ] Background image with Table Read branding
- [ ] Version number embedded in filename (e.g. \`TableRead-1.0.dmg\`)" \
"$M2" distribution design

create_issue "GitHub Releases CI pipeline" \
"Automate the build → sign → notarize → DMG → release workflow on every version tag.

- [ ] GitHub Actions workflow triggered on \`v*\` tags
- [ ] Secrets for signing cert + notarization credentials
- [ ] Attach DMG to GitHub Release automatically
- [ ] Update release notes from CHANGELOG" \
"$M2" infra distribution

create_issue "Decide distribution channel: direct vs Mac App Store" \
"Evaluate pros and cons of Mac App Store vs direct DMG distribution.

Considerations: sandbox restrictions on subprocess spawning (Python bridge may not be App Store compatible), review timeline, 30% cut vs direct, auto-update (Sparkle vs App Store), discoverability.

- [ ] Prototype App Store sandbox with a test entitlement set
- [ ] Document the decision here with rationale" \
"$M2" distribution

# ---------------------------------------------------------------------------
echo ""
echo "=== Milestone 3: Visual Identity, Branding & Quality of Life ==="
M3=$(create_milestone \
  "Visual Identity & Quality of Life" \
  "Give Table Read a distinct look, feel, and personality. Ship settings, bug reporting, and support options so real users can actually use it." \
  "")
echo "  Created milestone #$M3"

create_issue "App icon" \
"Design and integrate a proper app icon for Table Read.

- [ ] Concept: something that evokes a script/screenplay + audio/waveform — a table read is actors sitting around a table reading aloud
- [ ] All required macOS icon sizes (16–1024 @1x/@2x) in an .icns / .xcassets
- [ ] Works well in both light and dark Dock" \
"$M3" design

create_issue "Semantic color system and dark/light mode polish" \
"Audit every hardcoded color and replace with semantic tokens so the app looks intentional in both appearances.

- [ ] Define a small color palette in an \`AppColors\` file (primary accent, success, warning, error, surface)
- [ ] Replace remaining \`Color.orange\`, \`Color.green\` etc. with semantic references
- [ ] Test all four views in light + dark + increased contrast" \
"$M3" design polish

create_issue "Settings panel" \
"Add a Settings window (⌘,) with user-configurable preferences.

- [ ] Default output directory (currently per-PDF)
- [ ] Default voice engine
- [ ] Default narrator voice
- [ ] OpenAI API key (move from Cast step to Settings)
- [ ] Theme override (system / light / dark)" \
"$M3" enhancement polish

create_issue "In-app bug reporting" \
"Make it easy for users to file a bug without leaving the app.

- [ ] 'Report a Bug' menu item under Help
- [ ] Collects: app version, macOS version, last generation log
- [ ] Opens a pre-filled GitHub issue URL in the browser (no sending data without consent)
- [ ] Option to copy log to clipboard instead" \
"$M3" polish

create_issue "About panel and donation / support link" \
"Standard macOS About window plus a way to support development.

- [ ] About panel: app name, version, credits, GitHub link
- [ ] 'Support Table Read' button linking to Ko-fi / GitHub Sponsors / similar
- [ ] Keep it tasteful — one link, not a paywall" \
"$M3" polish

create_issue "Onboarding experience for first launch" \
"New users land on the Import step with no context. Add a lightweight first-launch guide.

- [ ] Welcome sheet on first launch explaining the four steps
- [ ] 'Don't show again' checkbox
- [ ] Maybe a sample PDF to try the app immediately" \
"$M3" enhancement polish

create_issue "Menu bar: File > Open and recent files" \
"Implement the macOS-standard File menu so the app feels native.

- [ ] File > Open (⌘O) — same as the Import step button
- [ ] File > Open Recent (using \`NSDocumentController\` or manual recent list)
- [ ] File > Show in Finder for the current output directory" \
"$M3" polish

echo ""
echo "=== Done ==="
echo "Milestones: #$M1 Voice Engines  |  #$M2 Packaging & Distribution  |  #$M3 Visual Identity & QoL"
echo "Visit: https://github.com/$REPO/milestones"
