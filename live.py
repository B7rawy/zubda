#!/usr/bin/env python3
"""Transcribe a meeting while it is being recorded.

Usage: live.py <meeting folder> <track,track,...>
Prints JSON lines: {"track", "text", "start"} for each new sentence, and {"busy": true/false}
around each Whisper pass so the notch can show it is working.
The app streams audio on stdin as frames: 1 byte track index, 4 bytes little-endian sample
count, then that many 16 kHz mono int16 samples. Every CHUNK seconds of new audio is
transcribed with the same Whisper settings as transcribe.py. The last TAIL seconds of each
chunk are held back and redone with the next one, so words cut at a chunk edge are not lost.
Each new line is printed as JSON for the notch. When stdin closes, the rest is transcribed
and transcript.md is written, so the report can start right away.
"""
import json
import struct
import sys
import threading
from pathlib import Path

import numpy as np

import insights
import transcribe

RATE = 16000
CHUNK = 10.0
TAIL = 2.5
# A chunk this long without a finished sentence is committed anyway, so memory can't grow forever.
STALL = 60.0


# Word-by-word mode: re-read the unconfirmed audio this often, and confirm a word once two
# passes in a row agree on it (the "local agreement" approach used by streaming Whisper).
WORD_STEP = 0.8
WORD_WINDOW = 20.0
PAUSE = 0.8
SENTENCE_END = (".", "?", "!", "؟")


class Track:
    def __init__(self, name):
        self.name = name
        self.pcm = bytearray()
        self.base = 0.0  # seconds already dropped from the front of pcm
        self.done = 0.0  # everything before this is transcribed and committed
        self.segments = []
        self.hypothesis = []  # last pass: [(text, start, end)] in absolute seconds
        self.confirmed = []   # agreed words not yet closed into a line
        self.last_pass = 0.0


def read_frames(tracks, lock, finished):
    stream = sys.stdin.buffer
    while True:
        head = stream.read(5)
        if len(head) < 5:
            break
        index, count = struct.unpack("<BI", head)
        data = stream.read(count * 2)
        if len(data) < count * 2:
            break
        with lock:
            tracks[index].pcm.extend(data)
    finished.set()


def step(track, lock, final):
    with lock:
        audio = np.frombuffer(bytes(track.pcm), dtype=np.int16).astype(np.float32) / 32768
        base = track.base
    total = base + len(audio) / RATE
    if not final and total - track.done < CHUNK:
        return

    start = track.done
    clip = audio[int((start - base) * RATE):]
    length = len(clip) / RATE
    if length < 0.5:
        if final:
            track.done = total
        return

    print(json.dumps({"busy": True}), flush=True)
    segments = transcribe.transcribe_audio(clip, track.name, prompt=meeting_prompt())
    print(json.dumps({"busy": False}), flush=True)
    if final or length >= STALL:
        keep = segments
        done = start + length
    else:
        keep = [s for s in segments if s["end"] <= length - TAIL]
        if keep:
            done = start + keep[-1]["end"]
        elif not segments:
            done = start + max(0.0, length - TAIL)  # silence: move on
        else:
            done = start  # a sentence is still going; wait for the next chunk

    for segment in keep:
        segment["start"] = round(segment["start"] + start, 2)
        segment["end"] = round(segment["end"] + start, 2)
        track.segments.append(segment)
        # Read by the Claude connector, so Claude can follow a meeting while it is happening.
        with LIVE_FILE.open("a", encoding="utf-8") as live:
            live.write(json.dumps({"t": segment["start"], "speaker": segment["speaker"], "text": segment["text"]},
                                  ensure_ascii=False) + "\n")
        print(json.dumps({"track": track.name, "text": segment["text"], "start": segment["start"]}, ensure_ascii=False), flush=True)
        flag(segment["text"], segment["start"])

    track.done = done
    with lock:
        cut = int((done - track.base) * RATE) * 2
        if cut > 0:
            del track.pcm[:cut]
            track.base += cut / 2 / RATE


LIVE_FILE = None
_prompt = None


def flag(text, start):
    """Ask the notch to mark a line that names a price, a date or a promise."""
    if transcribe.SETTINGS.get("auto_marks", True):
        kinds = insights.moment(text)
        if kinds:
            print(json.dumps({"auto_mark": kinds, "t": round(start, 2), "text": text}, ensure_ascii=False), flush=True)


def meeting_prompt():
    """Read once the app has written session.json, which happens as recording starts."""
    global _prompt
    if _prompt is None:
        try:
            _prompt = transcribe.prompt_for(json.loads((LIVE_FILE.parent / "session.json").read_text(encoding="utf-8")))
        except (OSError, ValueError):
            return None
    return _prompt


def whisper_words(clip, offset):
    """Words with absolute times for one pass, dropping what Whisper hears in silence."""
    import whisper_engine

    result = whisper_engine.transcribe(
        clip, transcribe.DEFAULT_MODEL,
        language=None if transcribe.SETTINGS["language"] == "auto" else transcribe.SETTINGS["language"],
        prompt=meeting_prompt(), word_timestamps=True,
    )
    words = []
    for seg in result["segments"]:
        if seg["no_speech_prob"] > transcribe.NO_SPEECH and seg["avg_logprob"] < transcribe.SILENT_LOGPROB:
            continue
        if seg["compression_ratio"] > transcribe.MAX_COMPRESSION:
            continue
        said = seg["text"].strip()
        # Lines Whisper learnt from film subtitles; it says them over silence and noise.
        if any(p in said for p in transcribe.HALLUCINATIONS) or said.strip(" .،") in ("موسيقى", "مرحبا", "شكرا"):
            continue
        for w in seg.get("words", []):
            text = w["word"].strip()
            if text:
                words.append((text, round(w["start"] + offset, 2), round(w["end"] + offset, 2)))
    return words


def plain(word):
    return transcribe.normalize_word(word) if hasattr(transcribe, "normalize_word") else word.strip(".,،؟?!").lower()


def emit_line(track, words):
    text = " ".join(w[0] for w in words).strip()
    if not text or any(p in text for p in transcribe.HALLUCINATIONS) or text.strip(" .،") in ("موسيقى", "مرحبا", "شكرا"):
        return
    segment = {"start": words[0][1], "end": words[-1][2], "track": track.name,
               "speaker": transcribe.SPEAKERS[track.name], "text": text, "unclear": False}
    track.segments.append(segment)
    print(json.dumps({"track": track.name, "text": text, "start": segment["start"]}, ensure_ascii=False), flush=True)
    flag(text, segment["start"])
    with LIVE_FILE.open("a", encoding="utf-8") as live:
        live.write(json.dumps({"t": segment["start"], "speaker": segment["speaker"], "text": text}, ensure_ascii=False) + "\n")


def word_step(track, lock, final):
    """Word-by-word: confirm words two passes agree on, show the rest as a draft."""
    with lock:
        audio = np.frombuffer(bytes(track.pcm), dtype=np.int16).astype(np.float32) / 32768
        base = track.base
    total = base + len(audio) / RATE
    start = track.done
    clip = audio[int((start - base) * RATE):]
    length = len(clip) / RATE

    if final:
        if length >= 0.5:
            words = whisper_words(clip, start)
            if words:
                emit_line(track, words)
        print(json.dumps({"draft": track.name, "fixed": "", "tentative": ""}), flush=True)
        track.done = total
        return
    if length < 1.0 or total - track.last_pass < WORD_STEP:
        return
    track.last_pass = total

    print(json.dumps({"busy": True}), flush=True)
    words = whisper_words(clip, start)
    print(json.dumps({"busy": False}), flush=True)

    # Words both this pass and the last one agree on, from the start, are confirmed.
    agreed = 0
    for new, old in zip(words, track.hypothesis):
        if plain(new[0]) != plain(old[0]):
            break
        agreed += 1
    track.confirmed = words[:agreed] if agreed > len(track.confirmed) else track.confirmed
    track.hypothesis = words

    # Close a line at the end of a sentence, at a pause, or when it gets long.
    cut = None
    for i, word in enumerate(track.confirmed):
        next_start = track.confirmed[i + 1][1] if i + 1 < len(track.confirmed) else None
        if word[0].endswith(SENTENCE_END) or (next_start and next_start - word[2] > PAUSE) or i >= 24:
            cut = i + 1
            break
    if cut is None and length > WORD_WINDOW and track.confirmed:
        cut = len(track.confirmed)
    if cut:
        emit_line(track, track.confirmed[:cut])
        done = track.confirmed[cut - 1][2]
        track.done = done
        track.hypothesis = []
        track.confirmed = []
        with lock:
            drop = int((done - track.base) * RATE) * 2
            if drop > 0:
                del track.pcm[:drop]
                track.base += drop / 2 / RATE
    elif not words and length > 4:
        track.done = total - 1.0  # silence: move on
        track.hypothesis = []

    fixed = " ".join(w[0] for w in track.confirmed)
    tentative = " ".join(w[0] for w in track.hypothesis[len(track.confirmed):])
    print(json.dumps({"draft": track.name, "fixed": fixed, "tentative": tentative}, ensure_ascii=False), flush=True)


class CloudOutput:
    """What cloud_live prints for the notch and writes for the Claude connector."""

    def __init__(self):
        self.lock = threading.Lock()
        self.segments = []  # every finished line, for the final transcript
        self.complete = False

    def say(self, payload):
        with self.lock:
            print(json.dumps(payload, ensure_ascii=False), flush=True)

    def line(self, track, text, start, speaker, translation=None, end=None):
        if any(p in text for p in transcribe.HALLUCINATIONS):
            return
        with self.lock:
            who = transcribe.SPEAKERS[track] + (f" {speaker}" if speaker else "")
            if speaker:
                # Several voices on one track: name them the way the report and Claude will see them.
                who = f"متحدث {speaker}" if track == "room" else f"ضيف {speaker}"
            self.segments.append({"start": round(start, 2), "end": round(max(end or start, start), 2), "track": track,
                                  "speaker": who, "text": text, "unclear": False})
            print(json.dumps({"track": track, "text": text, "start": round(start, 2), "speaker": speaker,
                              "translation": translation}, ensure_ascii=False), flush=True)
            with LIVE_FILE.open("a", encoding="utf-8") as live:
                live.write(json.dumps({"t": round(start, 2), "speaker": who, "text": text}, ensure_ascii=False) + "\n")
            flag(text, start)

    def draft(self, track, fixed, tentative, speaker):
        self.say({"draft": track, "fixed": fixed, "tentative": tentative, "speaker": speaker})

    def engine(self, name):
        self.say({"engine": name})

    def error(self, message):
        self.say({"error": message})


def run_cloud(folder, names):
    """Soniox, when the user chose it and saved a key; False means use Whisper instead.

    When the whole meeting came through, Soniox's lines (with who said what) become the
    final transcript, so the queue goes straight to the report: no second pass, no extra cost."""
    import cloud_live

    out = CloudOutput()
    if not cloud_live.run(folder, names, transcribe.SETTINGS, meeting_prompt(), out):
        return False
    if out.complete and out.segments:
        try:
            meta = json.loads((folder / "session.json").read_text(encoding="utf-8"))
            meta["transcribed_by"] = "soniox"
            segments = sorted(out.segments, key=lambda s: s["start"])
            mine = transcribe.drop_echo([s for s in segments if s["track"] == "me"],
                                        [s for s in segments if s["track"] == "others"])
            rest = [s for s in segments if s["track"] != "me"]
            transcribe.write_outputs(folder, meta, sorted(mine + rest, key=lambda s: s["start"]))
        except Exception as error:  # the queue will transcribe it locally instead
            print(json.dumps({"error": f"Saving the Soniox transcript: {error}"}), flush=True)
    return True


def main():
    global LIVE_FILE
    folder = Path(sys.argv[1])
    LIVE_FILE = folder / "live.jsonl"
    tracks = [Track(name) for name in sys.argv[2].split(",")]
    if transcribe.SETTINGS.get("live_engine") == "soniox" and run_cloud(folder, [t.name for t in tracks]):
        print(json.dumps({"done": True}), flush=True)
        return
    lock = threading.Lock()
    finished = threading.Event()
    threading.Thread(target=read_frames, args=(tracks, lock, finished), daemon=True).start()

    word_mode = transcribe.SETTINGS.get("live_mode", "word") == "word"
    while True:
        final = finished.is_set()
        for track in tracks:
            (word_step if word_mode else step)(track, lock, final)
        if final:
            break
        finished.wait(0.25 if word_mode else 1.0)

    if word_mode:
        # The live words were for the screen; a fresh pass over the whole meeting is more
        # accurate, so the queue transcribes it again before the report.
        print(json.dumps({"done": True}), flush=True)
        return

    meta = json.loads((folder / "session.json").read_text(encoding="utf-8"))
    by_name = {}
    for track in tracks:
        # The app has closed the audio file by now, so voices are told apart over the whole meeting.
        audio = next((folder / f"{track.name}{ext}" for ext in (".caf", ".webm", ".flac", ".wav") if (folder / f"{track.name}{ext}").exists()), None)
        by_name[track.name] = transcribe.separate_voices(track.segments, audio, track.name) if audio else track.segments
    others = by_name.get("others", [])
    mine = transcribe.drop_echo(by_name.get("me", []), others)
    room = by_name.get("room", [])
    transcribe.write_outputs(folder, meta, sorted(mine + others + room, key=lambda s: s["start"]))
    print(json.dumps({"done": True}), flush=True)


if __name__ == "__main__":
    main()
