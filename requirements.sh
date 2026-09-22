#!/usr/bin/env bash
# Set up everything transcribe.py needs: the .venv, its Python dependencies,
# and the system tools (ffmpeg, gpg). Safe to re-run.

set -euo pipefail

cd "$(dirname "$0")"
VENV=".venv"
PYTHON="${PYTHON:-/opt/homebrew/bin/python3.13}"

say() { printf '\n== %s\n' "$1"; }
warn() { printf '!! %s\n' "$1" >&2; }

# --- system tools ------------------------------------------------------------

say "Checking system tools"

if ! command -v brew >/dev/null; then
    warn "Homebrew not found — install ffmpeg and gpg yourself."
else
    for pkg in ffmpeg gnupg; do
        if brew list --formula "$pkg" >/dev/null 2>&1; then
            echo "  $pkg: already installed"
        else
            echo "  $pkg: installing"
            brew install "$pkg"
        fi
    done
fi

for tool in ffmpeg gpg; do
    command -v "$tool" >/dev/null || warn "$tool is still not on PATH"
done

# --- virtualenv --------------------------------------------------------------

if [[ ! -x "$PYTHON" ]]; then
    warn "$PYTHON not found; falling back to python3 on PATH"
    PYTHON="$(command -v python3)"
fi

say "Creating $VENV with $PYTHON ($("$PYTHON" --version))"

if [[ -d "$VENV" ]]; then
    echo "  $VENV already exists — reusing it"
else
    "$PYTHON" -m venv "$VENV"
fi

say "Installing Python dependencies"
# whisperx pins torch 2.8; let pip resolve it rather than forcing a version.
"$VENV/bin/pip" install --upgrade pip
"$VENV/bin/pip" install -r requirements.txt

# --- HuggingFace token -------------------------------------------------------

say "Checking HuggingFace token in ~/.authinfo.gpg"

if [[ ! -f "$HOME/.authinfo.gpg" ]]; then
    warn "~/.authinfo.gpg not found. Add a line:"
    warn "    machine huggingface.co login <user> password <token>"
else
    # Capture the decrypted text rather than piping it: grep exiting early
    # truncates gpg's output and the match gets missed.
    authinfo="$(gpg --decrypt "$HOME/.authinfo.gpg" 2>/dev/null || true)"
    if [[ -z "$authinfo" ]]; then
        warn "could not decrypt ~/.authinfo.gpg (gpg-agent locked?) — skipping token check"
    elif grep -q "huggingface.co" <<<"$authinfo"; then
        echo "  token entry found"
    else
        warn "no 'machine huggingface.co' entry in ~/.authinfo.gpg. Add:"
        warn "    machine huggingface.co login <user> password <token>"
    fi
    unset authinfo
fi

# --- verify ------------------------------------------------------------------

say "Verifying imports"
"$VENV/bin/python3" - <<'PY'
import torch, whisperx
from whisperx.diarize import DiarizationPipeline
print(f"  torch      {torch.__version__}")
print(f"  whisperx   {whisperx.__version__ if hasattr(whisperx, '__version__') else 'ok'}")
print("  DiarizationPipeline importable")
PY

cat <<'EOF'

Setup complete.

Remaining manual step — accept these HuggingFace model agreements with the
account that owns the token in ~/.authinfo.gpg:

  https://huggingface.co/pyannote/speaker-diarization-3.1
  https://huggingface.co/pyannote/segmentation-3.0
  https://huggingface.co/pyannote/speaker-diarization-community-1

Then run:  ./transcribe.py <audio-file>
EOF
