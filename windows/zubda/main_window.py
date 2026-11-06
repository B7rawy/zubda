"""The main window: Home, Meetings (report and transcript inside the app), Settings, About."""
import json
import os
import re
import subprocess
import sys
import threading
import webbrowser
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

from PySide6.QtCore import QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QIcon, QPixmap
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QFileDialog, QFrame, QGridLayout, QHBoxLayout,
                               QInputDialog, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow, QMessageBox,
                               QPushButton, QScrollArea, QSizePolicy, QStackedWidget, QVBoxLayout, QWidget)

from . import audio, library, paths, theme

TEST_PROMPT = "استخدم Zubda واعرضلي بشكل مرئي (كروت أو ويدجت): شايف كام ميتنج، وآخر ميتنج كان مع مين وإمتى وكان عن إيه."
VISUAL_HINT = " اعرض الرد بشكل مرئي ومنظم: ويدجت أو كروت أو جدول، مش فقرات طويلة."
PROMPTS = ["لخصلي آخر ميتنج", "إيه الوعود اللي عليّا الأسبوع ده؟", "العميل طلب إيه في آخر ٣ ميتنجات؟"]
REPO_URL = "https://github.com/B7rawy/zubda"


def card():
    frame = QFrame()
    frame.setObjectName("card")
    return frame


def label(text, size=13, color=None, bold=False, wrap=False):
    l = QLabel(text)
    style = f"font-size:{size}px;"
    if color:
        style += f"color:{color};"
    if bold:
        style += "font-weight:600;"
    l.setStyleSheet(style + "background:transparent;")
    l.setWordWrap(wrap)
    return l


def scroll(widget):
    area = QScrollArea()
    area.setWidgetResizable(True)
    area.setFrameShape(QFrame.NoFrame)
    area.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)  # pages fit the window's width
    area.setWidget(widget)
    return area


def open_in_claude(prompt):
    """A Claude Code session in Claude Desktop with the question written; the user presses Enter."""
    folder = str(paths.meetings_folder())
    url = f"claude://code/new?q={quote(prompt)}&folder={quote(folder)}"
    if os.name == "nt":
        os.startfile(url)
    else:
        webbrowser.open(url)


def claude_status():
    """(Claude Desktop connected, Claude Code connected)."""
    sys.path.insert(0, str(paths.REPO))
    import connect_claude

    desktop = False
    try:
        if connect_claude.desktop_extension_installed():
            desktop = True
        else:
            data = json.loads(connect_claude.desktop_config().read_text(encoding="utf-8"))
            desktop = "zubda" in (data.get("mcpServers") or {})
    except (OSError, ValueError):
        pass
    code = False
    try:
        data = json.loads((Path.home() / ".claude.json").read_text(encoding="utf-8"))
        code = "zubda" in (data.get("mcpServers") or {})
    except (OSError, ValueError):
        pass
    return desktop, code


# ---------------------------------------------------------------- Home

class HomePage(QWidget):
    open_meeting = Signal(str)

    def __init__(self, recorder):
        super().__init__()
        self.setObjectName("page")
        self.recorder = recorder
        self.layout_ = QVBoxLayout(self)
        self.layout_.setContentsMargins(36, 30, 36, 30)
        self.layout_.setSpacing(20)
        self.refresh()

    def refresh(self):
        while self.layout_.count():
            item = self.layout_.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        settings = paths.settings()
        hour = datetime.now().hour
        part = "morning" if hour < 12 else "afternoon" if hour < 18 else "evening"
        name = settings.get("user_name", "")
        greet = f"Good {part}" + (f", {name}" if name and name != "the user" else "")
        self.layout_.addWidget(label(greet, 24, bold=True))
        self.layout_.addWidget(label(datetime.now().strftime("%A, %d %B"), 13, theme.MUTED))

        meetings = library.meetings()
        top = QHBoxLayout()
        hero = card()
        hero.setStyleSheet(f"QFrame#card {{ background: qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #0d0d0d, stop:0.6 #3a1530, stop:1 {theme.BRAND}); border:none; border-radius:8px; }}")
        h = QVBoxLayout(hero)
        h.setContentsMargins(26, 22, 26, 22)
        h.addWidget(label("Start a recording", 22, bold=True))
        engine = "Soniox (live)" if settings.get("live_engine") == "soniox" else "this computer"
        h.addWidget(label(f"Transcribed on {engine}, then summarised by your Claude.", 13, "#DDDDDD"))
        h.addStretch()
        buttons = QHBoxLayout()
        online = QPushButton("●  Record online")
        online.setObjectName("primary")
        online.clicked.connect(lambda: self.recorder.start("online"))
        room = QPushButton("In person")
        room.clicked.connect(lambda: self.recorder.start("room"))
        buttons.addWidget(online)
        buttons.addWidget(room)
        buttons.addStretch()
        h.addLayout(buttons)
        hero.setMinimumHeight(190)
        top.addWidget(hero, 3)

        stats = QGridLayout()
        minutes = sum(m.minutes for m in meetings)
        values = [(str(len(meetings)), "Meetings"), (f"{minutes // 60}h {minutes % 60}m", "Recorded"),
                  (str(sum(m.marks for m in meetings)), "Marked moments"),
                  (str(len({m.client for m in meetings} - {"General"})), "Clients")]
        for i, (value, name) in enumerate(values):
            box = card()
            v = QVBoxLayout(box)
            v.addWidget(label(value, 22, bold=True))
            v.addWidget(label(name, 12, theme.MUTED))
            stats.addWidget(box, i // 2, i % 2)
        holder = QWidget()
        holder.setLayout(stats)
        holder.setMinimumWidth(0)
        top.addWidget(holder, 2)
        self.layout_.addLayout(top)

        self.layout_.addWidget(self._claude_card())

        self.layout_.addWidget(label("Recent meetings", 15, bold=True))
        if not meetings:
            empty = card()
            QVBoxLayout(empty).addWidget(label("Nothing here yet. Move the pointer onto the bar at the top of the screen, or press Record.", 13, theme.MUTED))
            self.layout_.addWidget(empty)
        for meeting in meetings[:8]:
            self.layout_.addWidget(self._meeting_row(meeting))
        self.layout_.addStretch()

    def _meeting_row(self, meeting):
        row = QPushButton()
        row.setStyleSheet(f"QPushButton {{ background:{theme.CARD}; border:1px solid {theme.LINE}; border-radius:8px; text-align:left; padding:12px 14px; }} QPushButton:hover {{ background:#2E2E2E; }}")
        when = meeting.started.strftime("%d %b, %H:%M") if meeting.started else ""
        badge = "Report" if meeting.has_report else "Transcript" if meeting.has_transcript else "Processing…"
        text = f"{meeting.label}   ·   {badge}\n{when} · {meeting.minutes} min" + (f" · {meeting.marks}★" if meeting.marks else "")
        if meeting.summary:
            text += f"\n{meeting.summary[:120]}"
        row.setText(text)
        row.clicked.connect(lambda: self.open_meeting.emit(str(meeting.folder)))
        return row

    def _claude_card(self):
        box = card()
        v = QVBoxLayout(box)
        v.setContentsMargins(18, 16, 18, 16)
        head = QHBoxLayout()
        head.addWidget(label("✦", 18, theme.ORANGE))
        titles = QVBoxLayout()
        titles.addWidget(label("Claude", 15, bold=True))
        titles.addWidget(label("Claude reads your meetings, even one that's still going.", 12, theme.MUTED))
        head.addLayout(titles, 1)
        test = QPushButton("Test in Claude Desktop")
        test.setToolTip("Opens a Claude Code session with a question about your meetings; press Enter there")
        test.clicked.connect(lambda: open_in_claude(TEST_PROMPT))
        head.addWidget(test)
        v.addLayout(head)
        # Connection on its own line, so the card never pushes the page wider than the window.
        status = QHBoxLayout()
        desktop, code = claude_status()
        for name, on in (("Claude Desktop", desktop), ("Claude Code", code)):
            pill = label(f"● {name}  {'connected' if on else 'not connected'}", 12, theme.GREEN if on else theme.ORANGE)
            pill.setToolTip(f"{name} can read your meetings" if on else f"{name} isn't connected yet")
            status.addWidget(pill)
            status.addSpacing(14)
        if not (desktop and code):
            connect = QPushButton("Connect")
            connect.clicked.connect(self._connect)
            status.addWidget(connect)
        status.addStretch()
        v.addLayout(status)
        v.addWidget(label("ASK CLAUDE CODE", 11, theme.MUTED, bold=True))
        chips = QHBoxLayout()
        chips.setSpacing(8)
        prompts = list(PROMPTS)
        if self.recorder.phase == "recording":
            prompts.insert(0, "تابع الميتنج اللي شغال دلوقتي وقولّي أهم حاجة اتقالت")
        for prompt in prompts:
            chip = QPushButton("↗ " + prompt)
            chip.setObjectName("chip")
            chip.setLayoutDirection(Qt.RightToLeft)
            chip.setSizePolicy(QSizePolicy.Maximum, QSizePolicy.Fixed)
            chip.clicked.connect(lambda _=False, p=prompt: open_in_claude(p + VISUAL_HINT))
            chips.addWidget(chip)
        chips.addStretch()
        v.addLayout(chips)
        v.addWidget(label("Opens a new Claude Code session in Claude Desktop with the question written; press Enter to send.", 11.5, theme.MUTED))
        return box

    def _connect(self):
        subprocess.Popen([str(paths.PYTHON), str(paths.script("connect_claude.py"))], env=paths.child_env(),
                         creationflags=paths.CREATE_NO_WINDOW)
        QTimer.singleShot(4000, self.refresh)


# ---------------------------------------------------------------- Meetings

class MeetingsPage(QWidget):
    def __init__(self):
        super().__init__()
        self.setObjectName("page")
        self.stack = QStackedWidget()
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(self.stack)

        self.list_page = QWidget()
        lv = QVBoxLayout(self.list_page)
        lv.setContentsMargins(36, 30, 36, 30)
        head = QHBoxLayout()
        head.addWidget(label("Meetings", 24, bold=True))
        head.addStretch()
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search titles and clients")
        self.search.textChanged.connect(self.refresh)
        self.search.setFixedWidth(260)
        head.addWidget(self.search)
        folder = QPushButton("Open folder")
        folder.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(paths.meetings_folder()))))
        head.addWidget(folder)
        lv.addLayout(head)
        self.items = QListWidget()
        self.items.itemClicked.connect(lambda item: self.show_meeting(item.data(Qt.UserRole)))
        lv.addWidget(self.items)
        self.stack.addWidget(self.list_page)

        self.detail = QWidget()
        dv = QVBoxLayout(self.detail)
        dv.setContentsMargins(24, 18, 24, 18)
        bar = QHBoxLayout()
        back = QPushButton("‹ Meetings")
        back.clicked.connect(lambda: self.stack.setCurrentWidget(self.list_page))
        bar.addWidget(back)
        self.title = label("", 17, bold=True)
        bar.addWidget(self.title, 1)
        self.tabs = QButtonGroup(self)
        for i, name in enumerate(("Report", "Transcript")):
            b = QPushButton(name)
            b.setCheckable(True)
            b.setChecked(i == 0)
            self.tabs.addButton(b, i)
            bar.addWidget(b)
        self.tabs.idClicked.connect(lambda _: self._load())
        names = QPushButton("Name speakers")
        names.clicked.connect(self._name_speakers)
        bar.addWidget(names)
        files = QPushButton("Files")
        files.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.folder))))
        bar.addWidget(files)
        dv.addLayout(bar)
        from PySide6.QtWebEngineWidgets import QWebEngineView

        from .web import MeetingPage

        self.view = QWebEngineView()
        self.page = MeetingPage(self.view)
        self.view.setPage(self.page)
        dv.addWidget(self.view, 1)
        self.stack.addWidget(self.detail)
        self.folder = None
        self.refresh()

    def refresh(self):
        self.items.clear()
        query = self.search.text().strip().lower()
        for m in library.meetings():
            if query and query not in m.label.lower():
                continue
            when = m.started.strftime("%a %d %b %Y, %H:%M") if m.started else ""
            badge = "Report" if m.has_report else "Transcript" if m.has_transcript else "Processing…"
            item = QListWidgetItem(f"{m.label}    [{badge}]\n{when} · {m.minutes} min · {'In person' if m.in_person else 'Online'}")
            item.setData(Qt.UserRole, str(m.folder))
            self.items.addItem(item)

    def show_meeting(self, folder, moment=None):
        self.folder = Path(folder)
        try:
            meta = json.loads((self.folder / "session.json").read_text(encoding="utf-8"))
            self.title.setText(library.Meeting(self.folder, meta).label)
        except (OSError, ValueError):
            self.title.setText(self.folder.name)
        self.page.folder = self.folder
        self.tabs.button(1 if moment is not None else 0).setChecked(True)
        self._load(moment)
        self.stack.setCurrentWidget(self.detail)

    def _load(self, moment=None):
        name = "report.html" if self.tabs.checkedId() == 0 else "transcript.html"
        page = self.folder / name
        if not page.exists():
            self.view.setHtml(f"<body style='background:{theme.BG};color:{theme.MUTED};font-family:Segoe UI;text-align:center;padding-top:80px'>"
                              f"{'The report' if name == 'report.html' else 'The transcript'} isn't ready yet.</body>")
            return
        url = QUrl.fromLocalFile(str(page))
        if moment is not None:
            url.setFragment(f"t={int(moment)}")
        self.view.load(url)

    def _name_speakers(self):
        try:
            data = json.loads((self.folder / "transcript.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return
        voices = []
        for seg in data.get("segments", []):
            if re.fullmatch(r"(متحدث|ضيف|الطرف التاني|متكلم) \d+", seg.get("speaker", "")) and seg["speaker"] not in voices:
                voices.append(seg["speaker"])
        if not voices:
            QMessageBox.information(self, "Name speakers", "This meeting has no numbered voices to name.")
            return
        names = {}
        for voice in voices:
            name, ok = QInputDialog.getText(self, "Who is who?", f"Name for «{voice}» (leave empty to keep the number):")
            if ok and name.strip():
                names[voice] = name.strip()
        if names:
            subprocess.run([str(paths.PYTHON), str(paths.script("insights.py")), "rename", str(self.folder),
                            json.dumps(names, ensure_ascii=False)], env=paths.child_env(), creationflags=paths.CREATE_NO_WINDOW)
            self._load()


# ---------------------------------------------------------------- Settings

class SettingsPage(QWidget):
    def __init__(self):
        super().__init__()
        self.setObjectName("page")
        s = paths.settings()
        v = QVBoxLayout(self)
        v.setContentsMargins(36, 30, 36, 30)
        v.setSpacing(14)
        v.addWidget(label("Settings", 24, bold=True))

        def section(title):
            v.addSpacing(6)
            v.addWidget(label(title.upper(), 11, theme.MUTED, bold=True))

        def row(name, widget, hint=None):
            line = QHBoxLayout()
            line.setSpacing(12)
            name_label = label(name, 13)
            name_label.setFixedWidth(220)
            line.addWidget(name_label)
            line.addWidget(widget, 1)
            v.addLayout(line)
            if hint:
                h = label(hint, 11.5, theme.MUTED, wrap=True)
                h.setContentsMargins(220 + 12 + 1, 0, 0, 0)
                v.addWidget(h)

        section("You")
        self.name = QLineEdit(s.get("user_name", "") if s.get("user_name") != "the user" else "")
        self.name.setPlaceholderText("Used in reports, e.g. Kareem")
        row("Your name", self.name)
        self.language = QComboBox()
        for code, name in (("ar", "Arabic"), ("en", "English"), ("auto", "Detect automatically")):
            self.language.addItem(name, code)
        self.language.setCurrentIndex(max(0, self.language.findData(s.get("language", "ar"))))
        row("Meetings are in", self.language)
        self.report_language = QLineEdit(s.get("report_language", "Arabic"))
        row("Write reports in", self.report_language, "e.g. Egyptian Arabic, Gulf Arabic, English")
        self.prompt = QLineEdit(s.get("prompt", ""))
        row("Describe your meetings", self.prompt, "One sentence in the meeting language: the dialect, the topic.")
        folder_row = QHBoxLayout()
        self.folder = QLineEdit(s.get("meetings_folder", ""))
        pick = QPushButton("Choose…")
        pick.clicked.connect(self._pick_folder)
        folder_row.addWidget(self.folder, 1)
        folder_row.addWidget(pick)
        holder = QWidget()
        holder.setLayout(folder_row)
        row("Meetings folder", holder)

        section("Recording")
        self.mic = QComboBox()
        self.mic.addItem("System default", "")
        for name in audio.microphones():
            self.mic.addItem(name, name)
        self.mic.setCurrentIndex(max(0, self.mic.findData(s.get("mic_name", ""))))
        row("Microphone", self.mic)
        self.detect = QCheckBox("Ask to record when a call app starts using the mic")
        self.detect.setChecked(s.get("detect_calls", True))
        v.addWidget(self.detect)
        self.live = QCheckBox("Write the transcript live while recording")
        self.live.setChecked(s.get("live_transcript", True))
        v.addWidget(self.live)
        self.engine = QComboBox()
        self.engine.addItem("This computer (free, private)", "local")
        self.engine.addItem("Soniox (faster, uses your API key)", "soniox")
        self.engine.setCurrentIndex(max(0, self.engine.findData(s.get("live_engine", "local"))))
        row("Live transcript runs on", self.engine)
        key_row = QHBoxLayout()
        self.key = QLineEdit()
        self.key.setEchoMode(QLineEdit.Password)
        self.key.setPlaceholderText("snx_…")
        try:
            self.key.setText(paths.soniox_key_file().read_text(encoding="utf-8").strip())
        except OSError:
            pass
        paste = QPushButton("Paste")
        paste.clicked.connect(self._paste_key)
        key_row.addWidget(self.key, 1)
        key_row.addWidget(paste)
        holder = QWidget()
        holder.setLayout(key_row)
        row("Soniox API key", holder, "About $0.12 an hour per voice track, billed to your own Soniox account. "
                                      "If the key fails or you're offline, this computer takes over by itself.")
        self.auto_marks = QCheckBox("Mark prices, dates and promises by itself")
        self.auto_marks.setChecked(s.get("auto_marks", True))
        v.addWidget(self.auto_marks)
        self.mention = QCheckBox("Get my attention when someone says my name")
        self.mention.setChecked(s.get("mention_alert", True))
        v.addWidget(self.mention)
        self.words = QLineEdit(s.get("alert_words", ""))
        self.words.setPlaceholderText("e.g. باشمهندس, your project name")
        row("Also for these words", self.words)
        self.captions = QCheckBox("Live captions under the closed bar")
        self.captions.setChecked(s.get("closed_captions", True))
        v.addWidget(self.captions)
        self.startup = QCheckBox("Start Zubda when Windows starts")
        self.startup.setChecked(_startup_enabled())
        v.addWidget(self.startup)

        save = QPushButton("Save")
        save.setObjectName("primary")
        save.clicked.connect(self.save)
        self.saved = label("", 12, theme.GREEN)
        bottom = QHBoxLayout()
        bottom.addWidget(save)
        bottom.addWidget(self.saved)
        bottom.addStretch()
        v.addLayout(bottom)
        v.addStretch()

    def _pick_folder(self):
        chosen = QFileDialog.getExistingDirectory(self, "Meetings folder", self.folder.text())
        if chosen:
            self.folder.setText(chosen)

    def _paste_key(self):
        from PySide6.QtWidgets import QApplication

        self.key.setText(QApplication.clipboard().text().strip())

    def save(self):
        paths.save_settings({
            "user_name": self.name.text().strip() or "the user",
            "language": self.language.currentData(),
            "report_language": self.report_language.text().strip() or "Arabic",
            "prompt": self.prompt.text().strip(),
            "meetings_folder": self.folder.text().strip() or str(Path.home() / "Downloads" / "Meetings"),
            "mic_name": self.mic.currentData(),
            "detect_calls": self.detect.isChecked(),
            "live_transcript": self.live.isChecked(),
            "live_engine": self.engine.currentData(),
            "auto_marks": self.auto_marks.isChecked(),
            "mention_alert": self.mention.isChecked(),
            "alert_words": self.words.text().strip(),
            "closed_captions": self.captions.isChecked(),
        })
        key_file = paths.soniox_key_file()
        key = self.key.text().strip()
        if key:
            key_file.parent.mkdir(parents=True, exist_ok=True)
            key_file.write_text(key, encoding="utf-8")
        elif key_file.exists():
            key_file.unlink()
        _set_startup(self.startup.isChecked())
        self.saved.setText("Saved ✓")
        QTimer.singleShot(2500, lambda: self.saved.setText(""))


RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def _startup_enabled():
    if os.name != "nt":
        return False
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, "Zubda")
            return True
    except OSError:
        return False


def _set_startup(on):
    if os.name != "nt":
        return
    import winreg

    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if on:
            command = f'"{paths.PYTHONW}" "{paths.REPO / "windows" / "Zubda.pyw"}"'
            winreg.SetValueEx(key, "Zubda", 0, winreg.REG_SZ, command)
        else:
            try:
                winreg.DeleteValue(key, "Zubda")
            except OSError:
                pass


# ---------------------------------------------------------------- About

class AboutPage(QWidget):
    def __init__(self):
        super().__init__()
        self.setObjectName("page")
        v = QVBoxLayout(self)
        v.setContentsMargins(36, 30, 36, 30)
        v.setSpacing(16)
        hero = card()
        h = QHBoxLayout(hero)
        h.setContentsMargins(22, 20, 22, 20)
        icon = QLabel()
        icon.setPixmap(QPixmap(str(paths.ASSETS / "icon.png")).scaled(72, 72, Qt.KeepAspectRatio, Qt.SmoothTransformation))
        h.addWidget(icon)
        text = QVBoxLayout()
        text.addWidget(label("Zubda", 26, bold=True))
        text.addWidget(label("The bottom line of every meeting. Records it, writes down every word, and lets Claude "
                             "understand it. Free and open source.", 13, theme.MUTED, wrap=True))
        text.addWidget(label("Version 1.0 · Windows (beta) · MIT licence", 12, theme.MUTED))
        h.addLayout(text, 1)
        source = QPushButton("Source code")
        source.setObjectName("primary")
        source.clicked.connect(lambda: webbrowser.open(REPO_URL))
        issue = QPushButton("Report a problem")
        issue.clicked.connect(lambda: webbrowser.open(REPO_URL + "/issues"))
        buttons = QVBoxLayout()
        buttons.addWidget(source)
        buttons.addWidget(issue)
        h.addLayout(buttons)
        v.addWidget(hero)

        maker = card()
        m = QHBoxLayout(maker)
        m.setContentsMargins(20, 18, 20, 18)
        photo = QLabel()
        picture = QPixmap(str(paths.REPO / "assets" / "maker.jpg"))
        if not picture.isNull():
            photo.setPixmap(picture.scaled(64, 64, Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation))
            photo.setFixedSize(64, 64)
            photo.setStyleSheet("border-radius:32px;")
        m.addWidget(photo)
        who = QVBoxLayout()
        who.addWidget(label("Made by Kareem Elbhrawy", 16, bold=True))
        who.addWidget(label("Full-stack & AI developer · Cairo", 12, theme.MUTED))
        who.addWidget(label("I built this for my own client meetings in Egyptian and Gulf Arabic, then made it free for everyone.", 12.5, theme.MUTED, wrap=True))
        m.addLayout(who, 1)
        for title, url in (("kareemelbhrawy.com", "https://kareemelbhrawy.com"), ("GitHub", "https://github.com/B7rawy"),
                           ("LinkedIn", "https://linkedin.com/in/b7rawy")):
            b = QPushButton(title + " ↗")
            b.clicked.connect(lambda _=False, u=url: webbrowser.open(u))
            m.addWidget(b)
        v.addWidget(maker)

        privacy = card()
        p = QVBoxLayout(privacy)
        p.setContentsMargins(20, 18, 20, 18)
        p.addWidget(label("WHERE YOUR MEETINGS GO", 11, theme.MUTED, bold=True))
        p.addWidget(label("• Audio stays in your meetings folder. There is no Zubda server.", 13))
        p.addWidget(label("• Transcribed on this computer, unless you choose Soniox for live text (your own key).", 13))
        p.addWidget(label("• Reports are written by your own Claude account.", 13))
        p.addWidget(label("• Tell people before you record. In many countries recording without consent is illegal.", 13, theme.ORANGE))
        v.addWidget(privacy)
        v.addStretch()


# ---------------------------------------------------------------- Window

class MainWindow(QMainWindow):
    def __init__(self, recorder, queue):
        super().__init__()
        self.setWindowTitle("Zubda")
        self.setWindowIcon(QIcon(str(paths.ASSETS / "icon.png")))
        self.resize(1180, 760)
        self.recorder = recorder

        root = QWidget()
        layout = QHBoxLayout(root)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        side = QWidget()
        side.setObjectName("sidebar")
        side.setFixedWidth(220)
        s = QVBoxLayout(side)
        s.setContentsMargins(12, 20, 12, 16)
        brand = QHBoxLayout()
        logo = QLabel()
        logo.setPixmap(QPixmap(str(paths.ASSETS / "icon.png")).scaled(30, 30, Qt.KeepAspectRatio, Qt.SmoothTransformation))
        brand.addWidget(logo)
        names = QVBoxLayout()
        names.addWidget(label("Zubda", 14, bold=True))
        self.status = label("Ready", 11.5, theme.MUTED)
        names.addWidget(self.status)
        brand.addLayout(names)
        brand.addStretch()
        s.addLayout(brand)
        s.addSpacing(18)

        self.pages = QStackedWidget()
        self.home = HomePage(recorder)
        self.meetings = MeetingsPage()
        self.settings = SettingsPage()
        self.about = AboutPage()
        self.nav = {}
        for name, page in (("Home", self.home), ("Meetings", self.meetings), ("Settings", self.settings), ("About", self.about)):
            self.pages.addWidget(scroll(page) if page is not self.meetings else page)
            b = QPushButton(name)
            b.setObjectName("nav")
            b.clicked.connect(lambda _=False, n=name: self.go(n))
            self.nav[name] = b
            if name == "Settings":
                s.addStretch()
            s.addWidget(b)
        layout.addWidget(side)
        layout.addWidget(self.pages, 1)
        self.setCentralWidget(root)

        self.home.open_meeting.connect(self.open_meeting)
        recorder.changed.connect(self._status)
        queue.changed.connect(self._status)
        queue.finished.connect(lambda _: (self.home.refresh(), self.meetings.refresh()))
        recorder.saved.connect(lambda *_: (self.home.refresh(), self.meetings.refresh()))
        self.queue = queue
        self.go("Home")

    def go(self, name):
        index = list(self.nav).index(name)
        self.pages.setCurrentIndex(index)
        for n, b in self.nav.items():
            b.setProperty("active", n == name)
            b.style().unpolish(b)
            b.style().polish(b)
        if name == "Home":
            self.home.refresh()
        elif name == "Meetings":
            self.meetings.refresh()
            self.meetings.stack.setCurrentWidget(self.meetings.list_page)

    def open_meeting(self, folder, moment=None):
        self.go("Meetings")
        self.meetings.show_meeting(folder, moment)
        self.show()
        self.raise_()
        self.activateWindow()

    def _status(self):
        rec = self.recorder
        job = self.queue.active
        if rec.phase == "recording":
            self.status.setText("Recording…")
        elif job:
            self.status.setText("Writing the report…" if job.stage == "reporting" else "Transcribing…")
        else:
            self.status.setText("Ready")
