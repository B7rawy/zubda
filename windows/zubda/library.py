"""Everything recorded so far, read from the meetings folder (same rules as the Mac app)."""
import json
from datetime import datetime
from pathlib import Path

from . import paths


class Meeting:
    def __init__(self, folder, meta):
        self.folder = Path(folder)
        self.client = meta.get("project") or "General"
        title = meta.get("title") or self.folder.name
        if title.startswith("Meet - ") or title == "test":
            title = "In-person meeting" if meta.get("mode") == "room" else "Online meeting"
        self.title = title
        self.started = _date(meta.get("startedAt"))
        ended = _date(meta.get("endedAt"))
        self.minutes = max(0, round((ended - self.started).total_seconds() / 60)) if self.started and ended else 0
        self.in_person = meta.get("mode") == "room"
        self.marks = len(meta.get("marks") or [])
        self.recording = meta.get("status") == "recording"
        self.has_report = (self.folder / "report.html").exists()
        self.has_transcript = (self.folder / "transcript.html").exists()
        self.summary = _summary(self.folder / "report.md")

    @property
    def label(self):
        return self.title if self.client == "General" else f"{self.client} · {self.title}"


def _date(text):
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def _summary(report):
    try:
        lines = report.read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    start = next((i for i, l in enumerate(lines) if l.startswith("## ") and "ملخص" in l), None)
    if start is None:
        return ""
    body = []
    for line in lines[start + 1:]:
        if line.startswith("## "):
            break
        line = line.strip().strip("-* ").replace("**", "")
        if line:
            body.append(line)
    return " ".join(body)[:240]


def meetings():
    root = paths.meetings_folder()
    found = []
    for meta_path in root.glob("*/session.json") if root.exists() else []:
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if meta.get("status") == "interrupted":
            continue
        found.append(Meeting(meta_path.parent, meta))
    return sorted(found, key=lambda m: m.started or datetime.min.astimezone(), reverse=True)
