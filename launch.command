#!/usr/bin/env bash
# Double-click to run. Sets up a virtual environment in this folder and
# launches the app. Picks the most modern Python+Tk available so the GUI
# renders reliably on macOS (the system Tk is deprecated and quirky).

set -eo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

VENV_DIR="${HERE}/.venv"
PY="${VENV_DIR}/bin/python3"
REQ="${HERE}/requirements.txt"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

has_tkinter() {
  [[ -x "$1" ]] && "$1" -c "import tkinter" >/dev/null 2>&1
}

# Prefer (in order): user's python3 (Homebrew) > /Library/Frameworks (python.org)
# > /usr/bin/python3 (Xcode CLT, but uses deprecated Tk 8.5 - last resort).
pick_host_python_with_tkinter() {
  local cand
  for cand in "$(command -v python3 2>/dev/null || true)" \
              /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
              /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
              /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
              /Library/Frameworks/Python.framework/Versions/3.10/bin/python3 \
              /usr/bin/python3; do
    if has_tkinter "${cand}"; then
      echo "${cand}"
      return 0
    fi
  done
  return 1
}

current_python_version() {
  command -v python3 >/dev/null 2>&1 || { echo ""; return; }
  python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
}

ask_install_tk() {
  local pyver="$1"
  osascript -e "display dialog \"Your Python ${pyver} (Homebrew) does not include Tkinter, the GUI library.\n\nThe most reliable fix is to install python-tk@${pyver} via Homebrew. This avoids the deprecated system Tk and produces a much better-looking app.\n\nInstall it now? (Runs: brew install python-tk@${pyver})\" buttons {\"Skip\", \"Install\"} default button \"Install\"" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Determine which host Python to use for the venv
# ---------------------------------------------------------------------------

CURRENT_PY="$(command -v python3 || true)"
if [[ -z "${CURRENT_PY}" ]]; then
  osascript -e 'display dialog "Python 3 is required.\n\nInstall Python from https://www.python.org/downloads/ then try again." buttons {"OK"} default button 1 with icon stop'
  exit 1
fi

CURRENT_VER="$(current_python_version)"

# If the current python3 (typically Homebrew) lacks tkinter, try to install
# python-tk@VER via Homebrew. This gives us modern Tk and avoids the
# deprecated system Tk 8.5 path entirely.
if ! has_tkinter "${CURRENT_PY}" && command -v brew >/dev/null 2>&1; then
  ANSWER="$(ask_install_tk "${CURRENT_VER}" || echo "Skip")"
  if [[ "${ANSWER}" == *"Install"* ]]; then
    echo "Installing python-tk@${CURRENT_VER} via Homebrew..."
    if brew install "python-tk@${CURRENT_VER}"; then
      :
    else
      echo "Homebrew install failed; falling back to other Python installs."
    fi
  fi
fi

# Pick the host Python (preferring modern Tk)
HOST_PY=""
if HOST_PY="$(pick_host_python_with_tkinter)"; then
  echo "Host Python with tkinter: ${HOST_PY}"
else
  osascript -e "display dialog \"No Python with Tkinter is available on this Mac.\n\nFix options:\n  - brew install python-tk@${CURRENT_VER}\n  - Install Python from python.org (bundles Tkinter)\n\nThen run the launcher again.\" buttons {\"OK\"} default button \"OK\""
  exit 1
fi

# ---------------------------------------------------------------------------
# Create / refresh the venv
#
# If the venv exists but uses a different host Python (e.g., from a previous
# launch that fell back to /usr/bin/python3), recreate it so we get the
# modern Tk binding.
# ---------------------------------------------------------------------------

VENV_NEEDS_REBUILD=0
if [[ ! -x "${PY}" ]]; then
  VENV_NEEDS_REBUILD=1
elif ! has_tkinter "${PY}"; then
  VENV_NEEDS_REBUILD=1
else
  # Compare the venv's underlying Python to our chosen host. If they differ
  # in major.minor, rebuild.
  VENV_VER="$("${PY}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"
  HOST_VER="$("${HOST_PY}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"
  if [[ -n "${VENV_VER}" && -n "${HOST_VER}" && "${VENV_VER}" != "${HOST_VER}" ]]; then
    VENV_NEEDS_REBUILD=1
  fi
fi

if [[ "${VENV_NEEDS_REBUILD}" == "1" ]]; then
  echo "Setting up virtual environment using ${HOST_PY} ..."
  rm -rf "${VENV_DIR}"
  "${HOST_PY}" -m venv "${VENV_DIR}"
  echo "Installing dependencies ..."
  "${PY}" -m pip install --upgrade pip --quiet
  "${PY}" -m pip install -r "${REQ}" --quiet
  touch "${VENV_DIR}/.requirements.stamp"
else
  STAMP="${VENV_DIR}/.requirements.stamp"
  if [[ ! -f "${STAMP}" || "${REQ}" -nt "${STAMP}" ]]; then
    echo "Updating dependencies ..."
    "${PY}" -m pip install --upgrade pip --quiet
    "${PY}" -m pip install -r "${REQ}" --quiet
    touch "${STAMP}"
  fi
fi

# Final sanity check
if ! has_tkinter "${PY}"; then
  osascript -e "display dialog \"Tkinter still not available after setup. Try deleting the .venv folder in this app folder and re-running the launcher.\" buttons {\"OK\"} default button \"OK\""
  exit 1
fi

# Sanity check macOS-only tools we depend on
for tool in say afconvert; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    osascript -e "display dialog \"This app requires the '${tool}' command, which ships with macOS. Are you on macOS?\" buttons {\"OK\"} default button \"OK\" with icon stop"
    exit 1
  fi
done

echo "Tk/Tcl version: $("${PY}" -c 'import tkinter; print(tkinter.TkVersion)')"

# Clear Python bytecode cache so source edits always take effect on next run.
# Without this, switching between Python versions (e.g., 3.10 -> 3.14) can
# leave stale .pyc files that Python prefers over the updated source.
rm -rf "${HERE}/__pycache__" 2>/dev/null || true

echo "Launching app ..."
exec "${PY}" "${HERE}/audio_drama.py"
