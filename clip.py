#!/usr/bin/env python3
"""Cut a short clip around a moment of a meeting, for sharing.

Usage: clip.py <meeting folder> <seconds>
Writes <folder>/clips/<hh-mm-ss>.m4a (10 s before to 20 s after) and prints JSON:
{"path": ..., "text": the lines said in that window, with who said them}.
"""
import json
import subprocess
import sys
from pathlib import Path

import imageio_ffmpeg

import render
from transcribe import clock

BEFORE, AFTER = 10, 20


def main():
    folder = Path(sys.argv[1]).expanduser()
    moment = float(sys.argv[2])
    start = max(0.0, moment - BEFORE)
    audio = render.mixed_audio(folder)
    if not audio or not Path(audio).exists():
        sys.exit("This meeting has no audio to cut.")
    out_dir = folder / "clips"
    out_dir.mkdir(exist_ok=True)
    target = out_dir / f"{clock(moment).replace(':', '-')}.m4a"
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error", "-ss", str(start), "-t", str(BEFORE + AFTER),
                    "-i", str(audio), "-c:a", "aac", "-b:a", "96k", str(target)], check=True)

    lines = []
    try:
        data = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
        title = data["meeting"].get("title") or folder.name
        for seg in data["segments"]:
            if seg["end"] >= start and seg["start"] <= moment + AFTER:
                lines.append(f"{seg['speaker']}: {seg['text']}")
    except (OSError, ValueError, KeyError):
        title = folder.name
    text = f"{title} · {clock(moment)}\n" + "\n".join(lines)
    print(json.dumps({"path": str(target), "text": text}, ensure_ascii=False))


if __name__ == "__main__":
    main()
