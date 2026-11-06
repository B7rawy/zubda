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


# Windows pipes default to the local code page, which can't carry Arabic; every script imports
# this module, so its JSON lines and logs come out as UTF-8 everywhere.
for _stream in (__import__("sys").stdout, __import__("sys").stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

SETTINGS = load()
MEETINGS = Path(SETTINGS["meetings_folder"]).expanduser()


def data_dir():
    """Where the Python environment and models live: ~/.local/share/meeting-recorder on every OS."""
    return Path.home() / ".local" / "share" / "meeting-recorder"


def claude_path():
    # On Windows the native installer puts claude.exe in ~/.local/bin; prefer an .exe over npm's
    # claude.cmd, which can't take a long multi-line prompt as an argument.
    home_bin = Path.home() / ".local" / "bin"
    candidates = [SETTINGS["claude"], str(home_bin / "claude.exe"), shutil.which("claude.exe") if os.name == "nt" else None,
                  shutil.which("claude"), str(home_bin / "claude")]
    return next((c for c in candidates if c and Path(c).exists()), None)
