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


def build_extension():
    """A Claude Desktop extension (.mcpb) for this Mac. Desktop rewrites its config file while it runs,
    which can drop a server added there; an installed extension stays. Returns the bundle path."""
    import zipfile

    repo = Path(__file__).resolve().parent
    out = repo / "dist" / "zubda.mcpb"
    out.parent.mkdir(exist_ok=True)
    manifest = {
        "manifest_version": "0.2",
        "dxt_version": "0.2",
        "name": "zubda",
        "display_name": "Zubda",
        "version": "1.0.0",
        "description": "Your recorded meetings (Zubda, the Mac notch app): list, read, search, follow live, open items.",
        "author": {"name": "Kareem Elbhrawy", "url": "https://github.com/B7rawy/zubda"},
        "homepage": "https://github.com/B7rawy/zubda",
        "icon": "icon.png",
        "server": {
            "type": "python",
            "entry_point": "server/main.py",
            # This Mac's own Python and repo, so the extension uses the same files as the app.
            "mcp_config": {"command": sys.executable, "args": [SERVER]},
        },
        "tools": [
            {"name": "list_meetings", "description": "Recorded meetings, newest first."},
            {"name": "get_meeting", "description": "A meeting's report and full transcript."},
            {"name": "search_meetings", "description": "Search every word said in every meeting."},
            {"name": "live_meeting", "description": "What is being said in the meeting recording right now."},
            {"name": "list_open_items", "description": "Open points and tasks across meetings."},
        ],
    }
    launcher = f"import os, sys\nos.execv({sys.executable!r}, [{sys.executable!r}, {SERVER!r}, *sys.argv[1:]])\n"
    icon = None
    icns = repo / "mac" / "Resources" / "AppIcon.icns"
    if icns.exists():
        icon = out.parent / "icon.png"
        subprocess.run(["sips", "-s", "format", "png", "-Z", "256", str(icns), "--out", str(icon)], capture_output=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
        z.writestr("server/main.py", launcher)
        if icon and icon.exists():
            z.write(icon, "icon.png")
    return out


def desktop_extension_installed():
    folder = desktop_config().parent / "Claude Extensions"
    return folder.exists() and any("zubda" in p.name for p in folder.iterdir())


def install_extension():
    if sys.platform != "darwin" or not desktop_config().parent.exists():
        return "Claude Desktop isn't installed; skipped the extension."
    if desktop_extension_installed():
        return "Claude Desktop extension: already installed."
    bundle = build_extension()
    subprocess.run(["open", "-a", "Claude", str(bundle)])
    return "Claude Desktop extension: click Install in Claude Desktop."


if __name__ == "__main__":
    if "--extension" in sys.argv:
        print(install_extension())
        sys.exit(0)
    print(connect_desktop())
    print(connect_code())
    print(install_extension())
