"""The report and transcript pages inside the app, and their ⤴ "share this moment" links."""
import json
import os
import subprocess

from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineSettings
from PySide6.QtWidgets import QApplication, QMessageBox

from . import paths


class MeetingPage(QWebEnginePage):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.folder = None
        settings = self.settings()
        settings.setAttribute(QWebEngineSettings.LocalContentCanAccessFileUrls, True)
        settings.setAttribute(QWebEngineSettings.PlaybackRequiresUserGesture, True)

    def acceptNavigationRequest(self, url, nav_type, is_main_frame):
        if url.scheme() == "mrclip":
            self._share(url.toString()[len("mrclip:"):])
            return False
        # Our own pages only; nothing in a meeting page should leave the app.
        return url.isLocalFile() or url.scheme() in ("data", "about")

    def _share(self, seconds):
        if not self.folder or not seconds.isdigit():
            return
        result = subprocess.run([str(paths.PYTHON), str(paths.script("clip.py")), str(self.folder), seconds],
                                capture_output=True, env=paths.child_env(), creationflags=paths.CREATE_NO_WINDOW)
        try:
            data = json.loads(result.stdout.decode("utf-8"))
        except ValueError:
            QMessageBox.warning(None, "Zubda", "Couldn't cut this moment (the meeting has no audio).")
            return
        QApplication.clipboard().setText(data.get("text", ""))
        if os.name == "nt":
            subprocess.run(["explorer", "/select,", data["path"]])
        QMessageBox.information(None, "Zubda", "The clip is selected in File Explorer, and its words are copied.\n"
                                               "Drag the file into WhatsApp and paste the words with Ctrl+V.")
