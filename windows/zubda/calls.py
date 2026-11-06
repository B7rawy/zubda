"""Which apps are using the microphone right now, from Windows' own privacy records.

Windows notes every app that opens the mic under
HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone
(store apps by package name, desktop apps under NonPackaged by path). While an app holds the mic,
its LastUsedTimeStop is 0. This is what the mic icon in the taskbar uses too.
"""
import os
import sys

ROOT = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"

# Friendly names for the usual call apps; anything else shows its file name.
NAMES = {
    "zoom": "Zoom", "teams": "Microsoft Teams", "ms-teams": "Microsoft Teams", "whatsapp": "WhatsApp",
    "chrome": "Google Chrome", "msedge": "Microsoft Edge", "firefox": "Firefox", "slack": "Slack",
    "discord": "Discord", "skype": "Skype", "webex": "Webex", "telegram": "Telegram", "brave": "Brave",
}


def _friendly(key):
    base = key.replace("#", "\\").split("\\")[-1].lower()
    base = base.removesuffix(".exe")
    for hint, name in NAMES.items():
        if hint in base or hint in key.lower():
            return name
    return base.split("_")[0] or key


def using_mic():
    """{key: friendly name} for every app holding the mic, except Zubda's own Python."""
    if os.name != "nt":
        return {}
    import winreg

    own = os.path.basename(sys.executable).lower()
    found = {}

    def scan(path):
        try:
            parent = winreg.OpenKey(winreg.HKEY_CURRENT_USER, path)
        except OSError:
            return
        i = 0
        while True:
            try:
                name = winreg.EnumKey(parent, i)
            except OSError:
                break
            i += 1
            if name == "NonPackaged":
                scan(path + "\\NonPackaged")
                continue
            try:
                key = winreg.OpenKey(parent, name)
                stop, _ = winreg.QueryValueEx(key, "LastUsedTimeStop")
                start, _ = winreg.QueryValueEx(key, "LastUsedTimeStart")
            except OSError:
                continue
            if stop == 0 and start > 0 and own not in name.lower() and "python" not in name.lower():
                found[name] = _friendly(name)

    scan(ROOT)
    return found
