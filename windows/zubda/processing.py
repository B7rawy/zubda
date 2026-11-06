"""After a recording: transcribe, then the report, one meeting at a time, in the background.

The same two scripts the Mac app runs (transcribe.py then report.py). A new recording can start
while an older one is still being processed.
"""
import json
import subprocess
import threading
import time
from pathlib import Path

from PySide6.QtCore import QObject, Signal

from . import paths


class Job:
    def __init__(self, folder, title):
        self.folder = Path(folder)
        self.title = title
        self.stage = "waiting"  # waiting | transcribing | reporting | ready | failed
        self.message = ""
        self.since = time.time()


class Queue(QObject):
    changed = Signal()
    finished = Signal(str)  # folder, when its report is ready

    def __init__(self):
        super().__init__()
        self.jobs = []
        self._running = False
        self._current = None

    def add(self, folder, title):
        self.jobs.append(Job(folder, title))
        self.jobs = self.jobs[-8:]
        self.changed.emit()
        self._pump()

    def resume_unprocessed(self):
        """Recordings saved but never transcribed (the app was closed mid-way)."""
        root = paths.meetings_folder()
        if not root.exists():
            return
        for meta in sorted(root.glob("*/session.json")):
            folder = meta.parent
            try:
                status = json.loads(meta.read_text(encoding="utf-8")).get("status")
            except (OSError, ValueError):
                continue
            if status == "done" and not (folder / "transcript.md").exists():
                self.add(str(folder), folder.name)

    @property
    def active(self):
        return next((j for j in self.jobs if j.stage in ("transcribing", "reporting")), None)

    def _run(self, script, folder):
        self._current = subprocess.Popen(
            [str(paths.PYTHON), str(paths.script(script)), str(folder)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            env=paths.child_env(), creationflags=paths.CREATE_NO_WINDOW,
        )
        _, err = self._current.communicate()
        ok = self._current.returncode == 0
        self._current = None
        return ok, (err or b"").decode("utf-8", "replace").strip().splitlines()[-1:] or [""]

    def _pump(self):
        if self._running:
            return
        job = next((j for j in self.jobs if j.stage == "waiting"), None)
        if not job:
            return
        self._running = True

        def work():
            job.stage, job.since = "transcribing", time.time()
            self.changed.emit()
            ok, err = self._run("transcribe.py", job.folder)
            if not ok:
                job.stage, job.message = "failed", err[0] or "Transcription failed"
            else:
                job.stage, job.since = "reporting", time.time()
                self.changed.emit()
                ok, err = self._run("report.py", job.folder)
                # No report (Claude not logged in) still leaves a full transcript.
                job.stage = "ready"
                job.message = "" if ok else (err[0] or "No report; the transcript is ready")
                self.finished.emit(str(job.folder))
            self._running = False
            self.changed.emit()
            self._pump()

        threading.Thread(target=work, daemon=True).start()

    def discard(self, job):
        if job.stage in ("transcribing", "reporting") and self._current:
            self._current.terminate()
        if job in self.jobs:
            self.jobs.remove(job)
        self.changed.emit()
