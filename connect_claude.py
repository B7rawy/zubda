#!/usr/bin/env python3
"""Register the meetings connector with Claude Desktop and Claude Code.

Usage: connect_claude.py   (run with the Python that should start the connector)
Adds one "zubda" entry (and drops the old "meeting-recorder" one) and leaves every other setting as it was; a backup of the
Claude Desktop config is kept next to it. Restart Claude Desktop afterwards.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from config import claude_path  # noqa: E402

NAME = "zubda"
OLD_NAMES = ("meeting-recorder",)
SERVER = str(Path(__file__).resolve().parent / "mcp_server.py")


def desktop_config():
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
    if os.name == "nt":
        return Path(os.environ.get("APPDATA", Path.home())) / "Claude" / "claude_desktop_config.json"
    return Path.home() / ".config" / "Claude" / "claude_desktop_config.json"


def connect_desktop():
    path = desktop_config()
    if not path.parent.exists():
        return "Claude Desktop isn't installed; skipped."
    config = {}
    if path.exists():
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            return f"{path} isn't valid JSON; left it alone."
        shutil.copy2(path, path.with_suffix(".json.bak"))
    entry = {"command": sys.executable, "args": [SERVER]}
    servers = config.setdefault("mcpServers", {})
    renamed = any(servers.pop(old, None) for old in OLD_NAMES)
    if servers.get(NAME) == entry and not renamed:
        return "Claude Desktop: already connected."
    servers[NAME] = entry
    path.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
    return "Claude Desktop: connected. Quit and reopen Claude Desktop once."


def connect_code():
    claude = claude_path()
    if not claude:
        return "Claude Code isn't installed; skipped."
    run = lambda *args: subprocess.run([claude, *args], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    for old in (NAME, *OLD_NAMES):
        run("mcp", "remove", "--scope", "user", old)
    result = run("mcp", "add", "--scope", "user", NAME, "--", sys.executable, SERVER)
    return "Claude Code: connected." if result.returncode == 0 else f"Claude Code: {result.stderr.strip() or result.stdout.strip()}"


if __name__ == "__main__":
    print(connect_desktop())
    print(connect_code())
