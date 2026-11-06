"""Zubda for Windows: the bar at the top of the screen, the main window, the tray icon.

Run with: pythonw windows\\Zubda.pyw   (setup.ps1 makes a Start menu shortcut for it)
ZUBDA_SMOKE=<folder> opens every page, saves screenshots there and quits (used by the tests).
"""
import os
import sys
import time

from PySide6.QtCore import QTimer
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from . import calls, paths, theme
from .main_window import MainWindow
from .notch import Notch
from .processing import Queue
from .recorder import Recorder


def main():
    if os.name == "nt":
        # Our own taskbar icon and name instead of Python's.
        import ctypes

        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Zubda.MeetingRecorder")

    app = QApplication(sys.argv)
    app.setApplicationName("Zubda")
    app.setQuitOnLastWindowClosed(False)
    app.setStyleSheet(theme.STYLE)
    icon = QIcon(str(paths.ASSETS / "icon.png"))
    app.setWindowIcon(icon)

    recorder = Recorder()
    queue = Queue()
    recorder.saved.connect(queue.add)
    window = MainWindow(recorder, queue)
    notch = Notch(recorder, queue)
    notch.open_main.connect(lambda: (window.show(), window.raise_(), window.activateWindow()))
    recorder.failed.connect(lambda message: QMessageBox.warning(window, "Zubda", message))

    tray = QSystemTrayIcon(icon)
    menu = QMenu()
    for text, handler in (("Open Zubda", lambda: (window.show(), window.raise_())),
                          ("Record online meeting", lambda: recorder.start("online")),
                          ("Record in-person meeting", lambda: recorder.start("room")),
                          ("Stop and save", lambda: recorder.stop(True))):
        action = QAction(text, menu)
        action.triggered.connect(handler)
        menu.addAction(action)
    menu.addSeparator()
    quit_action = QAction("Quit Zubda", menu)
    quit_action.triggered.connect(lambda: _quit(app, recorder))
    menu.addAction(quit_action)
    tray.setContextMenu(menu)
    tray.setToolTip("Zubda")
    tray.activated.connect(lambda reason: window.show() if reason == QSystemTrayIcon.Trigger else None)
    tray.show()
    queue.finished.connect(lambda folder: tray.showMessage("Zubda", "The meeting report is ready.", icon, 5000))

    # Ask to record when a call app takes the microphone.
    seen = set()

    def watch_calls():
        if recorder.phase != "idle" or not paths.settings().get("detect_calls", True):
            seen.clear()
            return
        users = calls.using_mic()
        for key, name in users.items():
            if key not in seen:
                notch.ask_to_record(name)
        seen.intersection_update(users)
        seen.update(users)
        if not users and notch.prompt_app:
            notch.prompt_app = None
            notch.refresh()

    watcher = QTimer()
    watcher.timeout.connect(watch_calls)
    watcher.start(2000)

    queue.resume_unprocessed()

    smoke = os.environ.get("ZUBDA_SMOKE")
    if smoke:
        QTimer.singleShot(1500, lambda: _smoke(app, window, notch, recorder, smoke))
    else:
        window.show()
    sys.exit(app.exec())


def _quit(app, recorder):
    if recorder.phase == "recording":
        recorder.stop(True)
        QTimer.singleShot(3000, app.quit)
    else:
        app.quit()


def _smoke(app, window, notch, recorder, folder):
    """Screenshots of every page and both bar states, for the automated Windows test."""
    os.makedirs(folder, exist_ok=True)
    window.show()
    shots = []
    for name in ("Home", "Meetings", "Settings", "About"):
        window.go(name)
        app.processEvents()
        time.sleep(0.4)
        app.processEvents()
        window.grab().save(os.path.join(folder, f"page-{name.lower()}.png"))
        shots.append(name)
    notch.grab().save(os.path.join(folder, "bar-closed.png"))
    notch.expanded = True
    notch.refresh()
    app.processEvents()
    notch.grab().save(os.path.join(folder, "bar-open.png"))
    notch.prompt_app = "Zoom"
    notch.refresh()
    app.processEvents()
    notch.grab().save(os.path.join(folder, "bar-call.png"))
    with open(os.path.join(folder, "smoke.txt"), "w", encoding="utf-8") as f:
        f.write("ok " + " ".join(shots))
    app.quit()
