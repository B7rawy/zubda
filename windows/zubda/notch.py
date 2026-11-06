"""The bar at the top centre of the screen: Windows' stand-in for the Mac notch.

Closed it is a small black pill hanging from the top edge (status, timer while recording, and a
line of live captions under it). Moving the pointer onto it opens it: start buttons, or while
recording the live conversation, notes, Mark, Pause, Discard and Stop & Save. It also asks
"Record this call?" when a call app takes the microphone, and opens by itself when someone
says your name.
"""
import time
import webbrowser

from PySide6.QtCore import QPoint, QRect, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QGuiApplication, QPainter, QPainterPath
from PySide6.QtWidgets import (QComboBox, QHBoxLayout, QLabel, QLineEdit, QPushButton, QSizePolicy,
                               QVBoxLayout, QWidget)

from . import paths, theme

CLOSED = (230, 34)
OPEN_WIDTH = 470


def clock(seconds):
    s = int(seconds)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def voice_label(track, speaker):
    if track == "me":
        return "Me", theme.MINT
    if track == "mark":
        return "★ Mark", "#FFD60A"
    if track == "notice":
        return "⏱ Time", theme.MUTED
    if speaker:
        n = int(speaker) if str(speaker).isdigit() else 1
        return (f"Guest {speaker}" if track == "others" else f"Speaker {speaker}"), theme.VOICES[(n - 1) % len(theme.VOICES)]
    return ("Others", theme.CYAN) if track == "others" else ("Room", "#CCCCCC")


def is_arabic(text):
    return any("؀" <= c <= "ۿ" for c in text)


class Notch(QWidget):
    open_main = Signal()

    def __init__(self, recorder, queue):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.recorder = recorder
        self.queue = queue
        self.expanded = False
        self.hold_until = 0.0
        self.prompt_app = None       # name of the call app asking to record
        self.dismissed = set()
        self.mention = None          # text of the line where your name was said

        self.body = QVBoxLayout(self)
        self.body.setContentsMargins(16, 8, 16, 14)
        self.body.setSpacing(8)

        self._leave = QTimer(self, singleShot=True, interval=350, timeout=self.collapse)
        recorder.changed.connect(self.refresh)
        recorder.live_line.connect(self._on_live)
        queue.changed.connect(self.refresh)
        self.refresh()
        self.show()

    # ---------- geometry and painting ----------

    def _place(self, width, height):
        screen = QGuiApplication.primaryScreen().geometry()
        self.setGeometry(QRect(screen.center().x() - width // 2, screen.top(), width, height))

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect())
        path = QPainterPath()
        radius = 18 if self.expanded else 14
        # Square top (it hangs from the screen edge), round bottom, like the notch.
        path.moveTo(r.left(), r.top())
        path.lineTo(r.right(), r.top())
        path.lineTo(r.right(), r.bottom() - radius)
        path.quadTo(r.right(), r.bottom(), r.right() - radius, r.bottom())
        path.lineTo(r.left() + radius, r.bottom())
        path.quadTo(r.left(), r.bottom(), r.left(), r.bottom() - radius)
        path.closeSubpath()
        p.fillPath(path, QColor(0, 0, 0, 245))

    def enterEvent(self, _):
        self._leave.stop()
        if not self.expanded:
            self.expanded = True
            self.refresh()

    def leaveEvent(self, _):
        self._leave.start()

    def collapse(self):
        if time.time() < self.hold_until or self.prompt_app:
            self._leave.start(1000)
            return
        if self.expanded and not self.underMouse():
            self.expanded = False
            self.refresh()

    # ---------- content ----------

    def _clear(self):
        while self.body.count():
            item = self.body.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
            elif item.layout():
                self._clear_layout(item.layout())

    def _clear_layout(self, layout):
        while layout.count():
            item = layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
            elif item.layout():
                self._clear_layout(item.layout())

    def _key(self):
        """What decides the layout; while it stays the same only the moving parts are updated,
        so typing a note isn't interrupted twice a second."""
        rec = self.recorder
        job = self.queue.active
        ready = any(j.stage == "ready" and time.time() - j.since < 600 for j in self.queue.jobs)
        return (bool(self.prompt_app and rec.phase == "idle"), self.expanded, rec.phase, rec.mode,
                bool(rec.meta.get("paused")), job.stage if job else None, ready, self.mention)

    def refresh(self):
        key = self._key()
        if key == getattr(self, "_shown", None) and self.recorder.phase == "recording":
            self._update_moving()
            return
        self._shown = key
        self._timer = self._feed = self._caption = self._meter_label = None
        self._clear()
        if self.prompt_app and self.recorder.phase == "idle":
            self._prompt()
        elif not self.expanded:
            self._closed()
        elif self.recorder.phase == "recording":
            self._recording()
        else:
            self._idle()
        self.adjustSize()
        width = OPEN_WIDTH if (self.expanded or self.prompt_app) else CLOSED[0]
        height = max(CLOSED[1], self.sizeHint().height())
        if not self.expanded and not self.prompt_app:
            height = CLOSED[1] + (40 if self.recorder.phase == "recording" and self._captions() else 0)
        self._place(width, height)
        self.update()

    def _label(self, text, size=12, color=theme.TEXT, bold=False):
        label = QLabel(text)
        label.setStyleSheet(f"color:{color}; font-size:{size}px; {'font-weight:600;' if bold else ''} background:transparent;")
        return label

    def _closed(self):
        self.body.setContentsMargins(14, 6, 14, 6)
        row = QHBoxLayout()
        rec = self.recorder
        if rec.phase == "recording":
            row.addWidget(self._label("●", 12, theme.BRAND))
            self._timer = self._label(clock(rec.elapsed), 12, theme.TEXT, True)
            row.addWidget(self._timer)
            row.addStretch()
            self._meter_label = self._meter(max(rec.levels().values() or [0]))
            row.addWidget(self._meter_label)
        elif rec.phase == "saving":
            row.addWidget(self._label("Saving…", 12, theme.MUTED))
        elif self.queue.active:
            row.addWidget(self._label("Writing the report…" if self.queue.active.stage == "reporting" else "Transcribing…", 12, theme.ORANGE))
        else:
            row.addWidget(self._label("Zubda", 12, theme.MUTED, True))
            row.addStretch()
            ready = any(j.stage == "ready" and time.time() - j.since < 600 for j in self.queue.jobs)
            row.addWidget(self._label("Ready ✓" if ready else "", 12, theme.GREEN))
        self.body.addLayout(row)
        if rec.phase == "recording":
            self._caption = self._label(self._captions(), 12.5, "#EDEDED")
            self._caption.setAlignment(Qt.AlignCenter)
            self._caption.setWordWrap(False)
            self.body.addWidget(self._caption)

    def _captions(self):
        """The newest words, for the line under the closed bar."""
        if not paths.settings().get("closed_captions", True):
            return ""
        draft = self.recorder.draft
        if draft:
            text = f"{draft.get('fixed', '')} {draft.get('tentative', '')}".strip()
        else:
            spoken = [l for l in self.recorder.lines if l.get("track") not in ("mark", "notice")]
            text = spoken[-1]["text"] if spoken else ""
        return text[-70:]

    def _meter(self, level):
        bars = QLabel("▮" * max(1, min(5, int(level * 40) + 1)))
        bars.setStyleSheet(f"color:{theme.GREEN}; font-size:9px; background:transparent;")
        return bars

    def _idle(self):
        self.body.setContentsMargins(16, 10, 16, 14)
        top = QHBoxLayout()
        top.addWidget(self._project_menu())
        top.addStretch()
        new_meet = QPushButton("＋ New Meet")
        new_meet.setToolTip("Start a new Google Meet and record it")
        new_meet.clicked.connect(self._new_meet)
        top.addWidget(new_meet)
        more = QPushButton("⋯")
        more.setToolTip("Open Zubda")
        more.clicked.connect(self.open_main.emit)
        top.addWidget(more)
        self.body.addLayout(top)

        tiles = QHBoxLayout()
        for title, subtitle, mode in (("Online meeting", "Zoom, Meet, Teams, WhatsApp", "online"),
                                      ("In-person meeting", "Laptop mic, whole room", "room")):
            tile = QPushButton(f"{title}\n{subtitle}")
            tile.setMinimumHeight(64)
            tile.setStyleSheet("text-align:left; padding:10px 12px; font-size:13px;")
            tile.clicked.connect(lambda _=False, m=mode: self.recorder.start(m))
            tiles.addWidget(tile)
        self.body.addLayout(tiles)

        job = self.queue.active
        status = (f"{job.title}: {'writing the report' if job.stage == 'reporting' else 'transcribing'}…" if job
                  else "Recordings stay on this computer")
        self.body.addWidget(self._label(status, 11.5, theme.MUTED))

    def _recording(self):
        rec = self.recorder
        self.body.setContentsMargins(16, 10, 16, 14)
        head = QHBoxLayout()
        head.addWidget(self._label("●", 12, theme.BRAND))
        head.addWidget(self._label("Online" if rec.mode == "online" else "In person", 13, theme.TEXT, True))
        head.addWidget(self._label("· " + rec.project, 12, theme.MUTED))
        head.addStretch()
        self._timer = self._label(clock(rec.elapsed), 20, theme.TEXT, True)
        head.addWidget(self._timer)
        self.body.addLayout(head)

        self._feed = QVBoxLayout()
        self._feed.setSpacing(4)
        self._fill_feed()
        self.body.addLayout(self._feed)

        note = QLineEdit()
        note.setPlaceholderText("Add a note and press Enter")
        note.returnPressed.connect(lambda: (rec.mark(note.text().strip() or None), note.clear()))
        self.body.addWidget(note)

        buttons = QHBoxLayout()
        discard = QPushButton("🗑")
        discard.setToolTip("Throw this recording away (it goes to the Recycle Bin)")
        discard.clicked.connect(lambda: rec.stop(keep=False))
        mark = QPushButton("★ Mark")
        mark.clicked.connect(lambda: rec.mark())
        paused = rec.meta.get("paused")
        pause = QPushButton("▶ Resume" if paused else "⏸ Pause")
        pause.clicked.connect(lambda: rec.pause(not paused))
        stop = QPushButton("■ Stop & Save")
        stop.setObjectName("primary")
        stop.clicked.connect(lambda: rec.stop(keep=True))
        for b in (discard, mark, pause):
            buttons.addWidget(b)
        buttons.addWidget(stop, 2)
        self.body.addLayout(buttons)

    def _fill_feed(self):
        rec = self.recorder
        self._clear_layout(self._feed)
        lines = rec.lines[-5:]
        if not lines and not rec.draft:
            self._feed.addWidget(self._label("Words show up here as people talk.", 11.5, theme.MUTED))
        for line in lines:
            self._feed.addWidget(self._row(line))
        if rec.draft:
            self._feed.addWidget(self._row({"track": rec.draft.get("draft"), "speaker": rec.draft.get("speaker"),
                                            "text": rec.draft.get("fixed", ""), "tentative": rec.draft.get("tentative", "")}))

    def _update_moving(self):
        rec = self.recorder
        if self._timer:
            self._timer.setText(clock(rec.elapsed))
        if self._meter_label:
            self._meter_label.setText("▮" * max(1, min(5, int(max(rec.levels().values() or [0]) * 40) + 1)))
        if self._caption is not None:
            self._caption.setText(self._captions())
        if self._feed is not None:
            signature = (len(rec.lines), str(rec.draft))
            if signature != getattr(self, "_feed_signature", None):
                self._feed_signature = signature
                self._fill_feed()
        self.adjustSize()
        width = OPEN_WIDTH if self.expanded else CLOSED[0]
        height = max(CLOSED[1], self.sizeHint().height()) if self.expanded else CLOSED[1] + (40 if self._captions() else 0)
        self._place(width, height)

    def _row(self, line):
        name, color = voice_label(line.get("track"), line.get("speaker"))
        row = QWidget()
        mentioned = self.mention and line.get("text") == self.mention
        row.setStyleSheet(f"background:{'rgba(255,159,10,0.18)' if mentioned else 'rgba(255,255,255,0.05)'};"
                          f"border-radius:8px; {'border:1px solid #FF9F0A;' if mentioned else ''}")
        layout = QHBoxLayout(row)
        layout.setContentsMargins(8, 4, 8, 4)
        who = self._label(name, 10.5, color, True)
        who.setFixedWidth(62)
        layout.addWidget(who)
        text = line.get("text", "")
        tentative = line.get("tentative")
        html = f"<span style='color:#EDEDED'>{text}</span>"
        if tentative:
            html += f" <span style='color:#777'>{tentative}</span>"
        if line.get("translation"):
            html += f"<br><span style='color:{theme.BRAND}'>{line['translation']}</span>"
        body = QLabel(html)
        body.setWordWrap(True)
        body.setStyleSheet("background:transparent; font-size:12px;")
        body.setLayoutDirection(Qt.RightToLeft if is_arabic(text + (tentative or "")) else Qt.LeftToRight)
        body.setAlignment(Qt.AlignRight if is_arabic(text) else Qt.AlignLeft)
        body.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
        layout.addWidget(body, 1)
        return row

    def _prompt(self):
        self.body.setContentsMargins(16, 12, 16, 14)
        self.body.addWidget(self._label(f"{self.prompt_app} is using your mic", 14, theme.TEXT, True))
        self.body.addWidget(self._label("Record this meeting? Pick the client first.", 12, theme.MUTED))
        row = QHBoxLayout()
        row.addWidget(self._project_menu())
        row.addStretch()
        later = QPushButton("Not now")
        later.clicked.connect(self.dismiss_prompt)
        record = QPushButton("● Record")
        record.setObjectName("primary")
        record.clicked.connect(self.accept_prompt)
        row.addWidget(later)
        row.addWidget(record)
        self.body.addLayout(row)

    def _project_menu(self):
        box = QComboBox()
        box.addItems(self.recorder.projects())
        box.setCurrentText(self.recorder.project)
        box.currentTextChanged.connect(self.recorder.set_project)
        box.setMinimumWidth(130)
        return box

    # ---------- actions ----------

    def _new_meet(self):
        webbrowser.open("https://meet.new")
        self.recorder.start("online", title="Google Meet")

    def ask_to_record(self, app):
        if self.recorder.phase != "idle" or app in self.dismissed:
            return
        self.prompt_app = app
        self.refresh()

    def dismiss_prompt(self):
        if self.prompt_app:
            self.dismissed.add(self.prompt_app)
        self.prompt_app = None
        self.refresh()

    def accept_prompt(self):
        self.prompt_app = None
        self.recorder.start("online", title=None)

    def _on_live(self, message):
        """Someone else said your name (or an alert word): open, highlight and ring."""
        text = message.get("text") or message.get("fixed") or ""
        track = message.get("track") or message.get("draft")
        settings = paths.settings()
        if not text or track in ("me", "mark") or not settings.get("mention_alert", True):
            return
        words = [settings.get("user_name", "")] + str(settings.get("alert_words", "")).replace("،", ",").split(",")
        folded = text.lower().replace("أ", "ا").replace("إ", "ا").replace("آ", "ا").replace("ة", "ه")
        hit = any(w.strip() and len(w.strip()) > 1 and w.strip().lower().replace("أ", "ا").replace("إ", "ا") in folded
                  for w in words if w.strip() != "the user")
        if hit and time.time() - getattr(self, "_last_mention", 0) > 20:
            self._last_mention = time.time()
            self.mention = text
            self.hold_until = time.time() + 12
            self.expanded = True
            self.refresh()
            try:
                import winsound

                winsound.MessageBeep(winsound.MB_ICONASTERISK)
            except Exception:
                pass
