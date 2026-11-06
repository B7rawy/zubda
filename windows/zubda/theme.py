"""Colours and the one stylesheet, matching the Mac app: dark, brand red, 8 px corners."""

BRAND = "#FF453B"
BG = "#161616"
PANEL = "#1E1E1E"
CARD = "#262626"
LINE = "#333333"
TEXT = "#F2F2F2"
MUTED = "#9A9A9A"
GREEN = "#32D74B"
ORANGE = "#FF9F0A"
CYAN = "#64D2FF"
MINT = "#66D4CF"

# Colours for numbered voices (Speaker 1, Guest 2…), same order as the Mac app.
VOICES = [CYAN, ORANGE, "#FF6482", "#BF5AF2", "#FFD60A", GREEN, "#5E5CE6"]

FONT = "Segoe UI Variable, Segoe UI, Arial"

STYLE = f"""
* {{ font-family: {FONT}; color: {TEXT}; }}
QMainWindow, QWidget#page, QScrollArea, QScrollArea > QWidget > QWidget {{ background: {BG}; }}
QWidget#sidebar {{ background: {PANEL}; }}
QLabel#muted, QLabel[muted="true"] {{ color: {MUTED}; }}
QLabel#title {{ font-size: 24px; font-weight: 600; }}
QLabel#section {{ font-size: 11px; font-weight: 600; color: {MUTED}; letter-spacing: 1px; }}
QFrame#card {{ background: {CARD}; border: 1px solid {LINE}; border-radius: 8px; }}
QPushButton {{ background: #2C2C2C; border: 1px solid {LINE}; border-radius: 8px; padding: 7px 14px; }}
QPushButton:hover {{ background: #363636; }}
QPushButton:disabled {{ color: #666; }}
QPushButton#primary {{ background: {BRAND}; border: none; font-weight: 600; }}
QPushButton#primary:hover {{ background: #ff5c53; }}
QPushButton#nav {{ background: transparent; border: none; text-align: left; padding: 9px 12px; font-size: 14px; }}
QPushButton#nav:hover {{ background: #2A2A2A; }}
QPushButton#nav[active="true"] {{ background: #2E2E2E; font-weight: 600; }}
QPushButton#chip {{ border-radius: 14px; padding: 5px 12px; background: #2C2C2C; }}
QLineEdit, QComboBox, QPlainTextEdit {{ background: #202020; border: 1px solid {LINE}; border-radius: 8px; padding: 6px 8px; }}
QComboBox QAbstractItemView {{ background: #202020; selection-background-color: #3A3A3A; }}
QCheckBox::indicator {{ width: 16px; height: 16px; }}
QListWidget {{ background: transparent; border: none; }}
QListWidget::item {{ background: {CARD}; border: 1px solid {LINE}; border-radius: 8px; margin: 3px 0; padding: 10px; }}
QListWidget::item:selected {{ background: #303030; }}
QScrollBar:vertical {{ background: transparent; width: 10px; }}
QScrollBar::handle:vertical {{ background: #3A3A3A; border-radius: 5px; min-height: 30px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
QToolTip {{ background: #2C2C2C; color: {TEXT}; border: 1px solid {LINE}; }}
"""
