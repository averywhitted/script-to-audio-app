#!/usr/bin/env bash
# =============================================================================
# Table Read — Ship a new release
# =============================================================================
# Usage:
#   bash scripts/ship.sh 0.2.0
#
# What it does:
#   1. Updates the version in Info.plist
#   2. Builds the DMG
#   3. Commits the version bump
#   4. Tags and pushes
#   5. Creates the GitHub Release and uploads the DMG
#
# The download page always uses the /latest/download/ URL, so nothing
# on the website needs to change between releases.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "\n${CYAN}▶ $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
fail() { echo -e "${RED}✗ $*${NC}"; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
PLIST="$REPO_ROOT/Sources/TableRead/Info.plist"

# ── Version arg ───────────────────────────────────────────────────────────────
[[ -n "$VERSION" ]] || fail "Usage: bash scripts/ship.sh <version>  e.g.  bash scripts/ship.sh 0.2.0"

echo -e "\n${CYAN}Shipping Table Read $VERSION${NC}"

# ── Bump version in Info.plist ────────────────────────────────────────────────
step "Bumping version to $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
ok "CFBundleShortVersionString → $VERSION"

# Bump build number (increment by 1)
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "0")
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
ok "CFBundleVersion → $NEW_BUILD"

# ── Build DMG ────────────────────────────────────────────────────────────────
step "Building DMG"
bash "$REPO_ROOT/scripts/build_release.sh"

# ── Commit version bump ───────────────────────────────────────────────────────
step "Committing version bump"
cd "$REPO_ROOT"
git add "$PLIST"
git commit -m "Bump version to $VERSION (build $NEW_BUILD)"

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging v$VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
ok "Tag v$VERSION pushed"

# ── GitHub Release ────────────────────────────────────────────────────────────
step "Creating GitHub Release v$VERSION"
gh release create "v$VERSION" \
    "$REPO_ROOT/build/TableRead.dmg#TableRead.dmg" \
    "$REPO_ROOT/build/TableRead.zip#TableRead.zip" \
    "$REPO_ROOT/build/TableRead.sha256#TableRead.sha256" \
    --title "Table Read Beta v$VERSION" \
    --generate-notes \
    --latest

echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Table Read $VERSION shipped!${NC}"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""
echo "  Download page: serves the new DMG automatically — no site changes needed."
echo "  In-app updater: users on older versions will be prompted on next launch."
echo ""
