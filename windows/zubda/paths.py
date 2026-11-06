"""Where things are, shared by every part of the Windows app."""
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

import config  # noqa: E402  (the same settings file the Python scripts read)

ASSETS = Path(__file__).resolve().parent / "assets"
PYTHON = Path(sys.executable)
# pythonw.exe has no console window; scripts are started with it so nothing flashes on screen.
PYTHONW = PYTHON.with_name("pythonw.exe") if PYTHON.with_name("pythonw.exe").exists() else PYTHON
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


def script(name):
    return REPO / name


def settings():
    """Fresh settings from config.json (it changes from the Settings page while the app runs)."""
    return config.load()


def meetings_folder():
    return Path(settings()["meetings_folder"]).expanduser()


def save_settings(changes):
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raw = {}
    raw.update(changes)
    path.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")


def soniox_key_file():
    return config.config_path().parent / "soniox.key"


def child_env():
    """Environment for the Python scripts the app starts: UTF-8 everywhere."""
    env = dict(os.environ)
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    return env
