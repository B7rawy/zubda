"""One recording at a time: the meeting folder, session.json, the audio tracks and the live text.

Mirrors the Mac app's Recorder so the Python scripts, the reports and Claude's connector see the
same files on both systems:
  <Meetings>/<yyyy-mm-dd_HH-MM-SS>_<client>_<online|in-person>/
      session.json   others.wav + me.wav (online) or room.wav (in person)   live.jsonl
"""
import json
import re
import struct
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path

from PySide6.QtCore import QObject, QTimer, Signal

from . import paths
from .audio import Capture, Track

TRACK_INDEX = {"others": 0, "me": 1, "room": 0}


def iso(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class LiveText(QObject):
    """live.py running beside the recording: audio in on stdin, JSON lines out."""

    line = Signal(dict)

    def __init__(self, folder, tracks):
        super().__init__()
        self.tracks = tracks
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            [str(paths.PYTHON), str(paths.script("live.py")), str(folder), ",".join(tracks)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=paths.child_env(), creationflags=paths.CREATE_NO_WINDOW,
        )
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for raw in self.proc.stdout:
            try:
                self.line.emit(json.loads(raw.decode("utf-8")))
            except ValueError:
                continue

    def send(self, track, samples):
        if track not in self.tracks or self.proc.poll() is not None:
            return
        header = struct.pack("<BI", self.tracks.index(track), len(samples))
        with self.lock:
            try:
                self.proc.stdin.write(header + samples.tobytes())
                self.proc.stdin.flush()
            except (BrokenPipeError, OSError, ValueError):
                pass

    def finish(self, timeout=600):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def cancel(self):
        self.proc.kill()


class Recorder(QObject):
    changed = Signal()            # phase, timer or anything shown changed
    live_line = Signal(dict)      # {"track","text","start","speaker","translation"} or draft/auto_mark
    saved = Signal(str, str)      # folder, title — goes to the processing queue
    failed = Signal(str)

    def __init__(self):
        super().__init__()
        self.phase = "idle"  # idle | recording | saving
        self.mode = None     # "online" | "room"
        self.project = paths.settings().get("last_project", "General")
        self.folder = None
        self.meta = {}
        self.started = None
        self.capture = None
        self.live = None
        self.tracks = {}
        self.lines = []      # finished live lines, newest last
        self.draft = None
        self._tick = QTimer(self)
        self._tick.timeout.connect(self.changed.emit)

    # Projects (clients) are kept in config.json so the Mac and Windows settings look alike.
    def projects(self):
        found = paths.settings().get("projects") or []
        return ["General"] + [p for p in found if p != "General"]

    def add_project(self, name):
        name = name.strip()
        if name and name not in self.projects():
            paths.save_settings({"projects": [p for p in self.projects() if p != "General"] + [name]})

    def set_project(self, name):
        self.project = name
        paths.save_settings({"last_project": name})
        self.changed.emit()

    @property
    def elapsed(self):
        return (datetime.now() - self.started).total_seconds() if self.started else 0

    def levels(self):
        return {name: track.level for name, track in self.tracks.items()}

    def start(self, mode, title=None):
        if self.phase != "idle":
            return
        settings = paths.settings()
        now = datetime.now()
        slug = re.sub(r"[^0-9a-zA-Z؀-ۿ]+", "-", self.project.lower()).strip("-") or "general"
        folder = paths.meetings_folder() / f"{now:%Y-%m-%d_%H-%M-%S}_{slug}_{'online' if mode == 'online' else 'in-person'}"
        try:
            folder.mkdir(parents=True, exist_ok=False)
        except OSError as error:
            self.failed.emit(f"Couldn't create the meeting folder: {error}")
            return
        names = ["others", "me"] if mode == "online" else ["room"]
        self.meta = {
            "app": "meeting-recorder-windows", "mode": mode, "project": self.project, "marks": [],
            "title": title or ("Online meeting" if mode == "online" else "In-person meeting"),
            "attendees": [], "meetingCode": "online" if mode == "online" else "in-person",
            "tracks": names, "startedAt": iso(now), "status": "recording",
        }
        self.folder = folder
        self._write_meta()
        self.lines, self.draft = [], None
        self.live = None
        if settings.get("live_transcript", True):
            try:
                self.live = LiveText(folder, names)
                self.live.line.connect(self._on_live)
            except OSError:
                self.live = None
        send = self.live.send if self.live else None
        try:
            if mode == "online":
                self.tracks = {"others": Track("others", folder / "others.wav", send), "me": Track("me", folder / "me.wav", send)}
                sources = {"loopback": self.tracks["others"], "mic": self.tracks["me"]}
            else:
                self.tracks = {"room": Track("room", folder / "room.wav", send)}
                sources = {"mic": self.tracks["room"]}
            self.capture = Capture(sources, mic_name=settings.get("mic_name") or None)
            self.capture.start()
        except Exception as error:  # no device, device busy, driver error
            if self.live:
                self.live.cancel()
            for track in self.tracks.values():
                try:
                    track.close()
                except Exception:
                    pass
            self.tracks = {}
            self.meta["status"] = "interrupted"
            self._write_meta()
            self.failed.emit(f"Couldn't start recording: {error}")
            return
        self.mode, self.started, self.phase = mode, now, "recording"
        self._tick.start(500)
        self.changed.emit()

    def pause(self, paused):
        for track in self.tracks.values():
            track.paused = paused
        self.meta["paused"] = paused
        self.changed.emit()

    def mark(self, note=None, at=None, auto=False):
        if self.phase != "recording":
            return
        entry = {"t": int(at if at is not None else self.elapsed)}
        if note:
            entry["note"] = note
        if auto:
            entry["auto"] = True
        self.meta["marks"].append(entry)
        self._write_meta()
        self.lines.append({"track": "mark", "text": note or "Marked this moment", "start": entry["t"]})
        self.changed.emit()

    def stop(self, keep=True):
        """Stop and save (keep=True) or throw the recording away (keep=False, folder to the Recycle Bin)."""
        if self.phase != "recording":
            return
        self.phase = "saving"
        self._tick.stop()
        self.changed.emit()
        folder, live, capture = self.folder, self.live, self.capture

        def finish():
            try:
                capture.stop()
            except Exception:
                pass
            if keep:
                self.meta["endedAt"] = iso(datetime.now())
                self.meta["status"] = "done"
                self._write_meta()
                if live:
                    live.finish()
            else:
                if live:
                    live.cancel()
                _to_recycle_bin(folder)
            self._reset()
            if keep:
                self.saved.emit(str(folder), self.meta.get("title", folder.name))

        threading.Thread(target=finish, daemon=True).start()

    def _reset(self):
        self.phase, self.mode, self.started = "idle", None, None
        self.capture, self.live, self.tracks = None, None, {}
        self.draft = None
        self.changed.emit()

    def _on_live(self, message):
        if "auto_mark" in message:
            kinds = {"سعر": "Price", "موعد": "Date", "وعد": "Promise"}
            label = " · ".join(kinds.get(k, k) for k in message["auto_mark"])
            self.mark(note=f"تلقائي ({'، '.join(message['auto_mark'])}): {message.get('text', '')[:120]}",
                      at=message.get("t", self.elapsed), auto=True)
            self.lines[-1]["text"] = f"{label}: {message.get('text', '')[:70]}"
        elif "draft" in message:
            has_text = message.get("fixed") or message.get("tentative")
            self.draft = message if has_text else None
        elif "track" in message and "text" in message:
            self.lines.append(message)
            self.lines = self.lines[-40:]
        self.live_line.emit(message)
        self.changed.emit()

    def _write_meta(self):
        if self.folder:
            (self.folder / "session.json").write_text(
                json.dumps(self.meta, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


def _to_recycle_bin(folder):
    """Recoverable delete, like the Mac app's move to Trash."""
    try:
        from send2trash import send2trash

        send2trash(str(folder))
    except Exception:
        import shutil

        trash = Path(folder).parent / ".discarded"
        trash.mkdir(exist_ok=True)
        shutil.move(str(folder), str(trash / Path(folder).name))
