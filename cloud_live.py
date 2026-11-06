"""Live transcript through Soniox: words appear in well under a second.

Optional, and off unless the user picks it and saves their own API key in
~/.config/meeting-recorder/soniox.key. Audio leaves the Mac only in this mode; the final
transcript after the meeting is still made locally by Whisper.

Prints the same JSON lines as live.py's word mode: {"draft", "fixed", "tentative"} while a
sentence is being said, then {"track", "text", "start"} once it is finished.
"""
import json
import struct
import sys
import threading
from pathlib import Path

URL = "wss://stt-rt.soniox.com/transcribe-websocket"
MODEL = "stt-rt-v6"
from config import config_path

# Next to config.json: ~/.config/meeting-recorder on a Mac, %APPDATA%\meeting-recorder on Windows.
KEY_FILE = config_path().parent / "soniox.key"
SENTENCE_END = (".", "?", "!", "؟")


def api_key():
    try:
        return KEY_FILE.read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


class Stream:
    """One Soniox connection per track (me, others, room).

    With diarization on, a change of speaker closes the line, so each line is one person.
    With translation on, Soniox sends each piece's translation right after the piece itself,
    so a finished sentence waits for the next piece (or an end of speech) before closing,
    and takes its translation with it."""

    def __init__(self, name, key, config, out):
        from websockets.sync.client import connect

        self.name = name
        self.out = out
        self.finals = []  # final tokens of the line being said: (text, start_ms)
        self.translation = []
        self.speaker = None
        self.closing = False  # the sentence ended; close once its translation is in
        self.end_ms = 0
        self.failed = False
        self.ws = connect(URL, additional_headers={"Authorization": f"Bearer {key}"},
                          max_size=None, ping_interval=None)
        self.ws.send(json.dumps(config))
        self.thread = threading.Thread(target=self.receive, daemon=True)
        self.thread.start()

    def send(self, pcm):
        try:
            self.ws.send(pcm)
        except Exception:
            pass

    def finish(self):
        try:
            self.ws.send("")
        except Exception:
            pass
        self.thread.join(timeout=15)

    def close_line(self):
        text = "".join(t for t, _ in self.finals).strip()
        if text:
            self.out.line(self.name, text, self.finals[0][1] / 1000, self.speaker,
                          "".join(self.translation).strip() or None, self.end_ms / 1000)
        self.finals = []
        self.translation = []
        self.closing = False

    def receive(self):
        try:
            for message in self.ws:
                data = json.loads(message)
                if data.get("error_code"):
                    self.out.error(f"Soniox: {data.get('error_message')}")
                    self.failed = True
                    return
                pending, pending_speaker = [], None
                for token in data.get("tokens", []):
                    text = token.get("text", "")
                    final = token.get("is_final")
                    if token.get("translation_status") == "translation":
                        if final:
                            self.translation.append(text)
                        continue
                    if text == "<end>":
                        if final:
                            self.close_line()
                        continue
                    speaker = token.get("speaker")
                    if not final:
                        pending.append(text)
                        pending_speaker = pending_speaker or speaker
                        continue
                    changed = speaker is not None and self.speaker is not None and speaker != self.speaker
                    if self.finals and (self.closing or changed):
                        self.close_line()
                    if speaker is not None:
                        self.speaker = speaker
                    self.finals.append((text, token.get("start_ms", 0)))
                    self.end_ms = token.get("end_ms", self.end_ms)
                    if text.strip().endswith(SENTENCE_END) and len(self.finals) > 3:
                        self.closing = True
                fixed = "".join(t for t, _ in self.finals).strip()
                self.out.draft(self.name, fixed, "".join(pending).strip(),
                               self.speaker if fixed else pending_speaker or self.speaker)
                if data.get("finished"):
                    break
        except Exception as error:
            self.out.error(f"Soniox: {error}")
            self.failed = True
        self.close_line()
        self.out.draft(self.name, "", "", None)


def run(folder, names, settings, prompt, out):
    """Stream stdin frames (same format as live.py) to Soniox until stdin closes.
    Returns False if it could not connect or Soniox refused, so live.py falls back to local Whisper."""
    key = api_key()
    if not key:
        return False
    language = settings.get("language", "ar")
    hints = ["ar", "en"] if language in ("ar", "auto") else [language, "en"]
    config = {
        "model": MODEL,
        "audio_format": "pcm_s16le",
        "sample_rate": 16000,
        "num_channels": 1,
        "language_hints": hints,
        "enable_endpoint_detection": True,
        "max_endpoint_delay_ms": 1000,
    }
    if prompt:
        config["context"] = {"text": prompt}
    target = settings.get("translate_to", "off")
    if target and target != "off":
        config["translation"] = {"type": "one_way", "target_language": target}
    try:
        streams = []
        for name in names:
            options = dict(config)
            # Your own mic is one person; the call and the room can be several.
            if name in ("others", "room"):
                options["enable_speaker_diarization"] = True
            streams.append(Stream(name, key, options, out))
    except Exception as error:
        out.error(f"Soniox: {error}")
        return False

    out.engine("soniox")
    stream = sys.stdin.buffer
    while True:
        head = stream.read(5)
        if len(head) < 5:
            break
        index, count = struct.unpack("<BI", head)
        data = stream.read(count * 2)
        if len(data) < count * 2:
            break
        streams[index].send(data)
        if all(s.failed for s in streams):
            # No credit, a bad key or no internet: let local Whisper carry on from here.
            out.engine("local")
            return False
    for s in streams:
        s.finish()
    # Only a stream that never dropped is a whole transcript; otherwise Whisper redoes it.
    out.complete = not any(s.failed for s in streams)
    return True
