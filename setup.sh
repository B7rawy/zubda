#!/bin/zsh
# One-command install on a Mac with Apple silicon. Safe to run again to update.
#   1. Python environment with Whisper (MLX) in ~/.local/share/meeting-recorder/venv
#   2. Settings file ~/.config/meeting-recorder/config.json (kept if it exists)
#   3. The notch app, built and installed to ~/Applications
#   4. The "meeting" skill for Claude Code in ~/.claude/skills/meeting
#   5. Optional: downloads the Whisper model now (~1.6 GB) instead of on the first meeting
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
VENV="$HOME/.local/share/meeting-recorder/venv"
CONFIG="$HOME/.config/meeting-recorder/config.json"

step() { print -P "\n%F{208}==>%f $1"; }

[[ "$(uname -s)" == Darwin ]] || { echo "This setup is for macOS. Windows support is not ready yet."; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "Needs a Mac with Apple silicon (M1 or newer); Whisper here runs on MLX."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Install the Xcode command line tools first: xcode-select --install"; exit 1; }

PY="$(command -v python3.12 || command -v python3.13 || command -v python3.11 || command -v python3 || true)"
[[ -n "$PY" ]] || { echo "Python 3.10+ is needed: brew install python"; exit 1; }
"$PY" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "Python 3.10+ is needed, found $("$PY" --version)"; exit 1; }

step "Python environment"
[[ -x "$VENV/bin/python" ]] || "$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet mlx-whisper imageio-ffmpeg numpy sherpa-onnx websockets

step "Voice separation models (about 45 MB, runs on this Mac)"
MODELS="$HOME/.local/share/meeting-recorder/models"
mkdir -p "$MODELS"
RELEASES="https://github.com/k2-fsa/sherpa-onnx/releases/download"
if [[ ! -f "$MODELS/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" ]]; then
  curl -fsSL "$RELEASES/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" | tar xj -C "$MODELS"
fi
if [[ ! -f "$MODELS/embedding.onnx" ]]; then
  curl -fsSL -o "$MODELS/embedding.onnx" "$RELEASES/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
fi
echo "Models in $MODELS"

step "Settings"
mkdir -p "${CONFIG:h}"
if [[ ! -f "$CONFIG" ]]; then
  cp "$REPO/config.example.json" "$CONFIG"
  echo "Created $CONFIG; edit language, prompt and your name there."
else
  echo "Keeping $CONFIG"
fi

step "Notch app"
MR_PYTHON="$VENV/bin/python" "$REPO/mac/build.sh"

step "Connect Claude to your meetings"
"$VENV/bin/python" "$REPO/connect_claude.py"

step "Claude Code skill"
mkdir -p "$HOME/.claude/skills/meeting"
sed -e "s|{{REPO}}|$REPO|g" -e "s|{{PYTHON}}|$VENV/bin/python|g" "$REPO/skill/SKILL.md" > "$HOME/.claude/skills/meeting/SKILL.md"
echo "Installed ~/.claude/skills/meeting"

if [[ "${1:-}" == "--download-model" ]]; then
  step "Whisper model (one time, about 1.6 GB)"
  "$VENV/bin/python" -c "
import json, os, numpy as np, mlx_whisper
cfg = os.path.expanduser('~/.config/meeting-recorder/config.json')
model = json.load(open(cfg)).get('model', 'mlx-community/whisper-large-v3-turbo')
mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=model)
print('Model ready')"
fi

step "Checks"
"$VENV/bin/python" -c "import mlx_whisper, imageio_ffmpeg; print('Whisper and ffmpeg: OK')"
"$VENV/bin/python" -c "import sys; sys.path.insert(0, '$REPO'); import diarize; print('Voice separation: OK' if diarize.available() else 'Voice separation: missing')"
if command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; then
  echo "claude CLI found: reports and questions will work once it's logged in (run: claude, then /login)."
else
  echo "claude CLI not found: recordings and transcripts work; reports and questions need Claude Code."
fi
echo "\nDone. Hover over the notch to start. Quit and reopen Claude Desktop once so it sees your meetings."
