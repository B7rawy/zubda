"""Shared settings for the Python side, read from the user's own config file.

macOS/Linux: ~/.config/meeting-recorder/config.json
Windows:     %APPDATA%\\meeting-recorder\\config.json
Every key is optional; anything missing falls back to the defaults below.
"""
import json
import os
import shutil
from pathlib import Path

DEFAULTS = {
    # Folder where every meeting gets its own subfolder.
    "meetings_folder": str(Path.home() / "Downloads" / "Meetings"),
    # Whisper language code, or "auto" to detect it.
    "language": "ar",
    # A sentence in the meeting's language that tells Whisper what to expect.
    "prompt": "اجتماع عمل، وممكن يكون فيه مصطلحات إنجليزية.",
    "model": "mlx-community/whisper-large-v3-turbo",
    # Language Claude writes reports and answers in.
    "report_language": "Arabic",
    # How reports refer to the person whose mic is recorded.
    "user_name": "the user",
    # Path to the claude CLI; found on PATH when empty.
    "claude": "",
}


def config_path():
    if os.name == "nt":
        return Path(os.environ.get("APPDATA", Path.home())) / "meeting-recorder" / "config.json"
    return Path.home() / ".config" / "meeting-recorder" / "config.json"


def load():
    settings = dict(DEFAULTS)
    try:
        settings.update(json.loads(config_path().read_text(encoding="utf-8")))
    except (OSError, ValueError):
        pass
    return settings


SETTINGS = load()
MEETINGS = Path(SETTINGS["meetings_folder"]).expanduser()


def claude_path():
    candidates = [SETTINGS["claude"], shutil.which("claude"), str(Path.home() / ".local" / "bin" / "claude")]
    return next((c for c in candidates if c and Path(c).exists()), None)
