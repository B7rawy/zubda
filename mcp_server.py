#!/usr/bin/env python3
"""Connects Claude (Claude Desktop, Claude Code) to the user's recorded meetings over MCP.

A tiny stdio JSON-RPC server with no dependencies beyond the standard library. Everything is
read from the meetings folder on this computer; nothing is sent anywhere except the answers
Claude asks for. Tools:
  list_meetings      recent meetings, newest first, optionally for one client
  get_meeting        a meeting's report and/or full transcript
  search_meetings    lines that contain the words, across every meeting, with timestamps
  live_meeting       the meeting being recorded right now, as far as it has been written
  list_open_items    tasks and open points from recent reports
"""
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from config import MEETINGS  # noqa: E402

PROTOCOL = "2025-06-18"

TOOLS = [
    {
        "name": "list_meetings",
        "description": "List the user's recorded meetings, newest first, with client, title, date, length and a one-line summary. Use the returned `meeting` id with the other tools.",
        "inputSchema": {"type": "object", "properties": {
            "client": {"type": "string", "description": "Only meetings for this client/project."},
            "limit": {"type": "integer", "description": "How many to return (default 20)."},
        }},
    },
    {
        "name": "get_meeting",
        "description": "Get one meeting's report and/or its full timestamped transcript. In transcripts «أنا» is the user, «الآخرون» everyone else on a call, «الحاضرين»/«متكلم N» people in the room, «★ علامة» moments the user marked.",
        "inputSchema": {"type": "object", "required": ["meeting"], "properties": {
            "meeting": {"type": "string", "description": "Meeting id from list_meetings, or 'latest'."},
            "part": {"type": "string", "enum": ["report", "transcript", "both"], "description": "Default: both."},
        }},
    },
    {
        "name": "search_meetings",
        "description": "Find transcript lines containing all the given words across every meeting (Arabic spelling variants match). Returns meeting, timestamp, speaker and line.",
        "inputSchema": {"type": "object", "required": ["query"], "properties": {
            "query": {"type": "string"},
            "client": {"type": "string"},
            "limit": {"type": "integer", "description": "Max lines (default 40)."},
        }},
    },
    {
        "name": "live_meeting",
        "description": "The meeting being recorded right now: client, title, elapsed time, marks, and the transcript written so far (it runs about 10 seconds behind the speech). Use it to catch the user up or answer questions during a meeting.",
        "inputSchema": {"type": "object", "properties": {
            "last_minutes": {"type": "number", "description": "Only the last N minutes of transcript."},
        }},
    },
    {
        "name": "list_open_items",
        "description": "Tasks and open points from the reports of recent meetings, newest first.",
        "inputSchema": {"type": "object", "properties": {
            "client": {"type": "string"},
            "limit": {"type": "integer", "description": "How many meetings to look at (default 5)."},
        }},
    },
]


def norm(text):
    text = text.lower()
    for a, b in (("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ة", "ه"), ("ى", "ي"), ("ـ", "")):
        text = text.replace(a, b)
    return re.sub(r"[ً-ْ]", "", text)


def meta_of(folder):
    try:
        return json.loads((folder / "session.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def meetings(client=None):
    found = []
    for folder in MEETINGS.iterdir() if MEETINGS.exists() else []:
        if not folder.is_dir() or not (folder / "session.json").exists():
            continue
        meta = meta_of(folder)
        if meta.get("status") in ("interrupted",):
            continue
        if client and norm(client) not in norm(meta.get("project") or ""):
            continue
        found.append((folder, meta))
    return sorted(found, key=lambda pair: pair[0].name, reverse=True)


def when(meta, folder):
    started = meta.get("startedAt")
    try:
        return datetime.fromisoformat(started.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M")
    except (AttributeError, ValueError):
        return folder.name[:16]


def summary(folder):
    report = folder / "report.md"
    if not report.exists():
        return ""
    lines = report.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        if line.startswith("## ") and "ملخص" in line:
            body = [l.strip(" -*") for l in lines[i + 1:i + 6] if l.strip() and not l.startswith("## ")]
            return " ".join(body)[:300]
    return ""


def resolve(name):
    if name == "latest":
        done = [f for f, m in meetings() if (f / "transcript.md").exists()]
        return done[0] if done else None
    folder = MEETINGS / name
    return folder if folder.is_dir() else None


def list_meetings(client=None, limit=20):
    rows = []
    for folder, meta in meetings(client)[:limit]:
        rows.append({
            "meeting": folder.name,
            "client": meta.get("project") or "",
            "title": meta.get("title") or "",
            "when": when(meta, folder),
            "mode": "in person" if meta.get("mode") == "room" else "online",
            "status": "recording now" if meta.get("status") == "recording" else (
                "report ready" if (folder / "report.md").exists() else
                "transcript ready" if (folder / "transcript.md").exists() else "not transcribed yet"),
            "summary": summary(folder),
        })
    return rows or "No meetings found."


def get_meeting(meeting, part="both"):
    folder = resolve(meeting)
    if not folder:
        return f"No meeting called {meeting!r}. Use list_meetings."
    out = []
    if part in ("report", "both") and (folder / "report.md").exists():
        out.append((folder / "report.md").read_text(encoding="utf-8"))
    if part in ("transcript", "both") and (folder / "transcript.md").exists():
        out.append((folder / "transcript.md").read_text(encoding="utf-8"))
    if not out and (folder / "live.jsonl").exists():
        return live_meeting()
    return "\n\n---\n\n".join(out) or "This meeting has no transcript yet."


def search_meetings(query, client=None, limit=40):
    words = [w for w in norm(query).split() if w]
    hits = []
    for folder, meta in meetings(client):
        transcript = folder / "transcript.md"
        if not transcript.exists():
            continue
        for line in transcript.read_text(encoding="utf-8").splitlines():
            if line.startswith("[") and all(w in norm(line) for w in words):
                hits.append(f"{folder.name} ({meta.get('project') or '-'}, {when(meta, folder)}): {line}")
                if len(hits) >= limit:
                    return "\n".join(hits)
    return "\n".join(hits) or "Nothing found."


def live_meeting(last_minutes=None):
    current = [(f, m) for f, m in meetings() if m.get("status") == "recording"]
    if not current:
        return "No meeting is being recorded right now."
    folder, meta = current[0]
    lines = []
    if (folder / "live.jsonl").exists():
        for raw in (folder / "live.jsonl").read_text(encoding="utf-8").splitlines():
            try:
                lines.append(json.loads(raw))
            except ValueError:
                pass
    for mark in meta.get("marks", []):
        lines.append({"t": mark.get("t", 0), "speaker": "★ علامة", "text": mark.get("note", "")})
    lines.sort(key=lambda l: l["t"])
    try:
        started = datetime.fromisoformat(meta["startedAt"].replace("Z", "+00:00")).timestamp()
        elapsed = time.time() - started
    except (KeyError, ValueError):
        elapsed = lines[-1]["t"] if lines else 0
    if last_minutes:
        lines = [l for l in lines if l["t"] >= elapsed - float(last_minutes) * 60]
    clock = lambda t: f"{int(t) // 3600:02d}:{int(t) % 3600 // 60:02d}:{int(t) % 60:02d}"
    head = (f"Recording now: {meta.get('title') or 'meeting'} · client {meta.get('project') or '-'} · "
            f"{int(elapsed // 60)} min in. The transcript runs about 10 seconds behind.")
    body = "\n".join(f"[{clock(l['t'])}] {l['speaker']}: {l['text']}" for l in lines)
    return head + "\n\n" + (body or "Nothing transcribed yet.")


def list_open_items(client=None, limit=5):
    out = []
    for folder, meta in meetings(client):
        report = folder / "report.md"
        if not report.exists():
            continue
        text = report.read_text(encoding="utf-8")
        sections = re.findall(r"^## (?:.*(?:المهام|النقط المفتوحة|Tasks|Open points).*)\n(?:(?!^## ).*\n?)*", text, re.M)
        if sections:
            out.append(f"# {folder.name} ({meta.get('project') or '-'}, {when(meta, folder)})\n" + "\n".join(s.strip() for s in sections))
        if len(out) >= limit:
            break
    return "\n\n".join(out) or "No reports with tasks yet."


HANDLERS = {
    "list_meetings": list_meetings,
    "get_meeting": get_meeting,
    "search_meetings": search_meetings,
    "live_meeting": live_meeting,
    "list_open_items": list_open_items,
}


def reply(message_id, result=None, error=None):
    message = {"jsonrpc": "2.0", "id": message_id}
    message["error" if error else "result"] = error or result
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for raw in sys.stdin:
        try:
            request = json.loads(raw)
        except ValueError:
            continue
        method, message_id = request.get("method"), request.get("id")
        if message_id is None:
            continue  # notifications need no answer
        if method == "initialize":
            reply(message_id, {
                "protocolVersion": request.get("params", {}).get("protocolVersion", PROTOCOL),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "zubda", "version": "1.0"},
                "instructions": "The user's meetings, recorded and transcribed on their own computer. "
                                "Use these tools whenever they ask about a meeting, a client, what was said or agreed, "
                                "their tasks, or the meeting happening right now. "
                                "How to answer: make it visual and easy to scan. If you have a tool that renders a visual, "
                                "widget, chart or artifact (for example show_widget or an Artifact), use it: meeting cards "
                                "with client, date, length and a one-line gist; promises and tasks as a checklist with who and "
                                "when; talk shares as bars; decisions vs open points side by side. Otherwise use clear Markdown: "
                                "a short headline, then tables or grouped bullets, bold the names, dates and numbers, and put "
                                "transcript timestamps as [hh:mm:ss]. Reply in the user's language and dialect; Arabic reads right to left.",
            })
        elif method == "tools/list":
            reply(message_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = request.get("params", {})
            handler = HANDLERS.get(params.get("name"))
            if not handler:
                reply(message_id, error={"code": -32602, "message": f"Unknown tool {params.get('name')}"})
                continue
            try:
                result = handler(**(params.get("arguments") or {}))
                text = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, indent=1)
                reply(message_id, {"content": [{"type": "text", "text": text}]})
            except Exception as error:  # report tool errors to Claude instead of dying
                reply(message_id, {"content": [{"type": "text", "text": f"Error: {error}"}], "isError": True})
        elif method == "ping":
            reply(message_id, {})
        else:
            reply(message_id, error={"code": -32601, "message": f"Unknown method {method}"})


if __name__ == "__main__":
    main()
