#!/usr/bin/env python3
"""Transcribe one voice note or quick spoken note, on this computer.

Usage: voice.py <audio file> [--min SECONDS] [--save notes|voice]
Prints JSON: {"seconds": 42.1, "text": "..."}.
--min skips (exit code 3, text empty) audio shorter than that, for automatic transcription.
--save appends the text to "Notes/notes.md" or "Voice notes/<date>.md" in the meetings folder,
so the archive, Claude and the notch can find it later.
"""
import json
import sys
from datetime import datetime

import transcribe
from config import MEETINGS

RATE = 16000


def main():
    args = sys.argv[1:]
    path = args[0]
    minimum = float(args[args.index("--min") + 1]) if "--min" in args else 0
    save = args[args.index("--save") + 1] if "--save" in args else None

    audio = transcribe.load_audio(path)
    seconds = round(len(audio) / RATE, 1)
    if seconds < minimum:
        print(json.dumps({"seconds": seconds, "text": ""}))
        sys.exit(3)

    lines = [s["text"] for s in transcribe.transcribe_audio(audio, "room")] if len(audio) else []
    text = " ".join(lines).strip()

    if save and text:
        now = datetime.now()
        if save == "notes":
            target = MEETINGS / "Notes" / "notes.md"
            entry = f"- {now:%Y-%m-%d %H:%M} — {text}\n"
        else:
            target = MEETINGS / "Voice notes" / f"{now:%Y-%m-%d}.md"
            entry = f"## {now:%H:%M} · {int(seconds // 60)}:{int(seconds % 60):02d}\n\n{text}\n\n"
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as out:
            out.write(entry)

    print(json.dumps({"seconds": seconds, "text": text}, ensure_ascii=False))


if __name__ == "__main__":
    main()
