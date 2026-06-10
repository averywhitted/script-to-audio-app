#!/usr/bin/env bash
# =============================================================================
# Table Read — Ship a new release
# =============================================================================
# Usage:
#   bash scripts/ship.sh <version> [channel]
#
#   channel: "beta" (default) or "stable"
#
# Examples:
#   bash scripts/ship.sh 0.2.0           # beta prerelease (default)
#   bash scripts/ship.sh 0.2.0 beta      # same
#   bash scripts/ship.sh 1.0.0 stable    # production release, marks as --latest
#
# Channels:
#   beta   — marked as GitHub prerelease; visible to users on the Beta update
#            channel (hits /releases?per_page=1).  Does NOT become "latest".
#   stable — non-prerelease; marked --latest so users on the Stable channel
#            see it via /releases/latest.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'
step() { echo -e "\n${CYAN}▶ $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
fail() { echo -e "${RED}✗ $*${NC}"; exit 1; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
CHANNEL="${2:-beta}"
PLIST="$REPO_ROOT/Sources/TableRead/Info.plist"

# ── Args ──────────────────────────────────────────────────────────────────────
[[ -n "$VERSION" ]] || fail "Usage: bash scripts/ship.sh <version> [beta|stable]  e.g.  bash scripts/ship.sh 0.2.0"
[[ "$CHANNEL" == "beta" || "$CHANNEL" == "stable" ]] || fail "Channel must be 'beta' or 'stable', got: $CHANNEL"

if [[ "$CHANNEL" == "stable" ]]; then
    RELEASE_TITLE="Table Read v$VERSION"
    GH_FLAGS="--latest"
else
    RELEASE_TITLE="Table Read Beta v$VERSION"
    GH_FLAGS="--prerelease"
fi

echo -e "\n${CYAN}Shipping Table Read $VERSION (${CHANNEL})${NC}"

# ── Bump version in Info.plist ────────────────────────────────────────────────
step "Bumping version to $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
ok "CFBundleShortVersionString → $VERSION"

CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "0")
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
ok "CFBundleVersion → $NEW_BUILD"

# ── Build ─────────────────────────────────────────────────────────────────────
step "Building release"
bash "$REPO_ROOT/scripts/build_release.sh"

# ── Commit & tag ──────────────────────────────────────────────────────────────
step "Committing version bump"
cd "$REPO_ROOT"
git add "$PLIST"
git commit -m "Bump version to $VERSION (build $NEW_BUILD)"

step "Tagging v$VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
ok "Tag v$VERSION pushed"

# ── GitHub Release ────────────────────────────────────────────────────────────
step "Creating GitHub Release v$VERSION ($CHANNEL)"
# shellcheck disable=SC2086
gh release create "v$VERSION" \
    "$REPO_ROOT/build/TableRead.dmg#TableRead.dmg" \
    "$REPO_ROOT/build/TableRead.zip#TableRead.zip" \
    "$REPO_ROOT/build/TableRead.sha256#TableRead.sha256" \
    --title "$RELEASE_TITLE" \
    --generate-notes \
    $GH_FLAGS

echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Table Read $VERSION ($CHANNEL) shipped!${NC}"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""
if [[ "$CHANNEL" == "stable" ]]; then
    echo "  Stable channel users will be prompted on next launch."
    echo "  Beta channel users will also see this (it's the most recent release)."
else
    echo "  Beta channel users will be prompted on next launch."
    echo "  Stable channel users will NOT see this prerelease."
fi
echo ""
