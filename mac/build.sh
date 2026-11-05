#!/bin/zsh
# Builds the notch app and installs it to ~/Applications.
# The repo, Python and claude paths are written into Info.plist so the app finds them on any Mac.
# Signs with an Apple Development identity when one exists, so macOS keeps the mic and
# screen-recording permissions across rebuilds; otherwise signs ad hoc (permissions are asked again).
set -euo pipefail
cd "$(dirname "$0")"

REPO="$(cd .. && pwd)"
PYTHON="${MR_PYTHON:-$HOME/.local/share/meeting-recorder/venv/bin/python}"
CLAUDE="${MR_CLAUDE:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
# The identity is remembered after the first build: macOS ties the permissions to it, so a
# different certificate (the keychain's order can change) would look like a new app.
SAVED="$HOME/.config/meeting-recorder/sign_identity"
AVAILABLE="$(security find-identity -v -p codesigning 2>/dev/null)"
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f "$SAVED" ]] && grep -qF "\"$(cat "$SAVED")\"" <<< "$AVAILABLE"; then
  IDENTITY="$(cat "$SAVED")"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(awk -F'"' '/Apple Development/ {print $2; exit}' <<< "$AVAILABLE")"
fi
IDENTITY="${IDENTITY:--}"
if [[ "$IDENTITY" != "-" ]]; then
  mkdir -p "$(dirname "$SAVED")"
  print -r -- "$IDENTITY" > "$SAVED"
fi
APP="build/Zubda.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingRecorder "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :MRRepo string $REPO" -c "Add :MRPython string $PYTHON" \
  -c "Add :MRClaude string $CLAUDE" "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements MeetingRecorder.entitlements --sign "$IDENTITY" "$APP"

if [[ -n "${MR_NO_INSTALL:-}" ]]; then
  echo "Built $APP (not installed: MR_NO_INSTALL is set)"
  exit 0
fi
mkdir -p ~/Applications
# Never kill the app mid-meeting: audio files are written every few seconds while recording.
MEETINGS="$(/usr/bin/python3 -c 'import json,os
p = os.path.expanduser("~/.config/meeting-recorder/config.json")
folder = json.load(open(p)).get("meetings_folder") if os.path.exists(p) else None
print(os.path.expanduser(folder or "~/Downloads/Meetings"))')"
if pgrep -x MeetingRecorder >/dev/null && [ -n "$(find "$MEETINGS" -name '*.caf' -mtime -20s 2>/dev/null)" ]; then
  echo "A recording is in progress; stop it from the notch, then run this again." >&2
  exit 1
fi
pkill -x MeetingRecorder 2>/dev/null || true
rm -rf ~/Applications/"Zubda.app"
# Installs from before the rename: the old name goes to the Trash (same app, same permissions).
if [ -d ~/Applications/"Meeting Recorder.app" ]; then
  mv ~/Applications/"Meeting Recorder.app" ~/.Trash/"Meeting Recorder $(date +%s).app"
fi
cp -R "$APP" ~/Applications/
echo ~/Applications/"Zubda.app"
open ~/Applications/"Zubda.app"
