#!/usr/bin/env python3
"""Ask Claude, through the Zubda connector, what it can see, to prove the link works.

Usage: check_claude.py
Prints one JSON line: {"ok": true, "answer": "..."} or {"ok": false, "error": "..."}.
Uses the user's own `claude` CLI with only the Zubda connector loaded, read-only tools.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from config import SETTINGS, claude_path

REPO = Path(__file__).resolve().parent

PROMPT = (
    "Use the zubda tools (list_meetings) to look at my recorded meetings. In {language}, in at most two short "
    "sentences, say how many meetings you can see and what the most recent one was (client, when, one-line gist). "
    "Start with ✓. Do not add anything else."
)


def main():
    claude = claude_path()
    if not claude:
        print(json.dumps({"ok": False, "error": "The claude CLI isn't installed."}))
        return
    config = {"mcpServers": {"zubda": {"command": sys.executable, "args": [str(REPO / "mcp_server.py")]}}}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(config, f)
    language = SETTINGS.get("report_language") or "English"
    try:
        result = subprocess.run(
            [claude, "-p", PROMPT.format(language=language), "--mcp-config", f.name, "--strict-mcp-config",
             "--allowedTools", "mcp__zubda__list_meetings", "mcp__zubda__get_meeting", "--model", "haiku"],
            capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=180,
        )
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "Claude took too long to answer."}))
        return
    finally:
        Path(f.name).unlink(missing_ok=True)
    answer = result.stdout.strip()
    if result.returncode != 0 or not answer:
        error = (result.stderr or result.stdout).strip().splitlines()[-1:] or ["No answer."]
        if "login" in error[0].lower() or "auth" in error[0].lower():
            error = ["Claude isn't logged in. Run `claude` in Terminal, then /login."]
        print(json.dumps({"ok": False, "error": error[0]}, ensure_ascii=False))
        return
    print(json.dumps({"ok": True, "answer": answer}, ensure_ascii=False))


if __name__ == "__main__":
    main()
