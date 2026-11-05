#!/usr/bin/env python3
"""Turn a recorded meeting into a timestamped transcript.

Usage: transcribe.py [latest | path/to/meeting-folder] [--model HF_REPO] [--force]
Writes transcript.md and transcript.json into the meeting folder.
"""
import argparse
import json
import subprocess
import sys
from difflib import SequenceMatcher
from pathlib import Path

from config import MEETINGS, SETTINGS

# Recordings the Chrome extension saved under random names land in the parent folder.
DOWNLOADS = MEETINGS.parent
DEFAULT_MODEL = SETTINGS["model"]
# .webm from the Chrome extension, .caf from the Mac app, anything else from an import.
AUDIO_EXTENSIONS = (".webm", ".caf", ".m4a", ".mp3", ".wav", ".mp4", ".mov", ".ogg", ".opus", ".aac", ".flac")
SPEAKERS = {"me": "أنا", "others": "الآخرون", "room": "الحاضرين"}
PROMPT = SETTINGS["prompt"]

# Above these limits Whisper is usually repeating itself or inventing text over silence.
MAX_COMPRESSION = 2.4
NO_SPEECH = 0.6
SILENT_LOGPROB = -1.0
UNCLEAR_LOGPROB = -0.7
ECHO_SIMILARITY = 0.75
# Subtitle credits from Whisper's training data; it invents them over quiet Arabic audio.
HALLUCINATIONS = ("ترجمة نانسي قنقر", "نانسي قنقر", "Subtitles by", "Amara.org", "Thanks for watching", "اشتركوا في القناة", "اشترك في القناة", "شكرا للمشاهدة", "شكراً للمشاهدة")


def organize_downloads(downloads=DOWNLOADS):
    """Move recordings that Chrome saved under random names into their meeting folders."""
    for meta_path in downloads.glob("*.json"):
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        if not isinstance(meta, dict) or meta.get("app") != "meet-recorder":
            continue
        files = meta.get("files") or {}
        sources = {track: downloads / Path(path).name for track, path in files.items() if path}
        # An extension still running the old background worker writes no paths; leave those alone.
        if set(sources) != set(meta.get("tracks", [])) or not all(s.exists() for s in sources.values()):
            continue
        folder = downloads / meta["folder"]
        folder.mkdir(parents=True, exist_ok=True)
        for track, source in sources.items():
            source.rename(folder / f"{track}.webm")
        (folder / "session.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
        meta_path.unlink()


def find_meeting(target):
    if target != "latest":
        return Path(target).expanduser()
    # The Mac app writes session.json when it starts; skip one that is still recording.
    done = [p.parent for p in MEETINGS.glob("*/session.json")
            if json.loads(p.read_text(encoding="utf-8")).get("status") != "recording"]
    if not done:
        sys.exit(f"No finished meetings in {MEETINGS}")
    return max(done, key=lambda p: (p / "session.json").stat().st_mtime)


def load_audio(path):
    # Decoded here because mlx_whisper calls whatever ffmpeg is on PATH, and the one on this Mac
    # is an Intel build that won't run. imageio_ffmpeg ships a native binary.
    import imageio_ffmpeg
    import numpy as np

    decoded = subprocess.run(
        [imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-loglevel", "error", "-i", str(path),
         "-f", "f32le", "-ac", "1", "-ar", "16000", "-"],
        capture_output=True, check=True,
    )
    return np.frombuffer(decoded.stdout, dtype=np.float32)


def prompt_for(meta):
    """The meeting description plus the client's words to spell right (Settings → Clients)."""
    vocabulary = SETTINGS.get("vocabulary") or {}
    words = list(vocabulary.get(meta.get("project") or "", [])) + list(vocabulary.get("*", []))
    return (SETTINGS["prompt"] + (" " + "، ".join(words) + "." if words else ""))[:600]


def transcribe_track(path, track, model, prompt=None):
    audio = load_audio(path)
    return transcribe_audio(audio, track, model, prompt) if len(audio) else []


def transcribe_audio(audio, track, model=DEFAULT_MODEL, prompt=None):
    """Segments for 16 kHz mono float audio, with times relative to its start."""
    import mlx_whisper

    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=model,
        language=None if SETTINGS["language"] == "auto" else SETTINGS["language"],
        condition_on_previous_text=False,
        initial_prompt=prompt or PROMPT,
        # Without this a line after silence is stamped too early and the two tracks merge out of order.
        word_timestamps=True,
    )
    segments = []
    for seg in result["segments"]:
        text = seg["text"].strip()
        silent = seg["no_speech_prob"] > NO_SPEECH and seg["avg_logprob"] < SILENT_LOGPROB
        if not text or text in (PROMPT, prompt) or silent or seg["compression_ratio"] > MAX_COMPRESSION:
            continue
        if any(phrase in text for phrase in HALLUCINATIONS) or text.strip(" .،") in ("موسيقى", "مرحبا", "شكرا"):
            continue
        segments.append({
            "start": round(seg["start"], 2),
            "end": round(seg["end"], 2),
            "track": track,
            "speaker": SPEAKERS[track],
            "text": text,
            "unclear": seg["avg_logprob"] < UNCLEAR_LOGPROB,
        })
    return segments


def separate_voices(segments, path, track):
    """Number the people in an in-person recording.

    Only the room track: on a call's compressed audio the voice matching split one client
    into 11-26 "voices" in a real meeting, so online tracks keep a single label.
    """
    if track != "room" or not segments or not SETTINGS.get("separate_voices", True):
        return segments
    import diarize

    if not diarize.available():
        return segments
    print(f"Separating voices in {path.name}...", file=sys.stderr)
    return diarize.label(segments, load_audio(path), "متكلم")


def drop_echo(mine, others):
    """On laptop speakers the mic also hears the others; keep their line, not the echo."""
    def is_echo(seg):
        return any(
            o["start"] <= seg["end"] and seg["start"] <= o["end"]
            and SequenceMatcher(None, seg["text"], o["text"]).ratio() >= ECHO_SIMILARITY
            for o in others
        )
    return [seg for seg in mine if not is_echo(seg)]


def clock(seconds):
    s = int(seconds)
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def write_outputs(folder, meta, segments):
    (folder / "transcript.json").write_text(
        json.dumps({"meeting": meta, "segments": segments}, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    lines = [f"# {meta.get('title') or folder.name}", ""]
    if meta.get("recovered"):
        lines += ["> التسجيل ده اترجّع بعد توقف مفاجئ، وممكن آخره يكون ناقص.", ""]
    entries = [(seg["start"], 1, f"[{clock(seg['start'])}] {seg['speaker']}: {seg['text']}"
                + (" (غير واضح)" if seg["unclear"] else "")) for seg in segments]
    # Moments the user marked from the notch, placed in time order among the lines.
    for mark in meta.get("marks", []):
        note = f": {mark['note']}" if mark.get("note") else ""
        entries.append((mark["t"], 0, f"[{clock(mark['t'])}] ★ علامة{note}"))
    lines += [line for _, _, line in sorted(entries)]
    (folder / "transcript.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    import render
    render.render(folder / "transcript.md")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", default="latest")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    organize_downloads()
    folder = find_meeting(args.target)
    meta_path = folder / "session.json"
    if not meta_path.exists():
        sys.exit(f"{folder} has no session.json; the recording did not finish saving")

    output = folder / "transcript.md"
    if output.exists() and not args.force:
        print(output)
        return

    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    by_track = {}
    for track in SPEAKERS:
        # .webm from the Chrome extension, .caf from the Mac app.
        audio = next((folder / f"{track}{ext}" for ext in AUDIO_EXTENSIONS if (folder / f"{track}{ext}").exists()), None)
        if audio:
            print(f"Transcribing {audio.name}...", file=sys.stderr)
            by_track[track] = separate_voices(transcribe_track(audio, track, args.model, prompt_for(meta)), audio, track)

    others = by_track.get("others", [])
    mine = drop_echo(by_track.get("me", []), others)
    write_outputs(folder, meta, sorted(mine + others + by_track.get("room", []), key=lambda seg: seg["start"]))
    print(output)


if __name__ == "__main__":
    main()
