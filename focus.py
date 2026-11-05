#!/usr/bin/env python3
"""Do Not Disturb while recording, through two Shortcuts the user adds once.

macOS has no API for apps to turn Focus on, so the app runs the shortcuts
"Zubda Focus On" and "Zubda Focus Off".

Usage: focus.py setup   builds and signs both shortcuts and opens them, so Shortcuts asks to add them
       focus.py check   exit 0 if both are installed
"""
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

NAMES = {True: "Zubda Focus On", False: "Zubda Focus Off"}


def workflow(on):
    parameters = {"Enabled": 1 if on else 0,
                  "FocusModes": {"Identifier": "com.apple.donotdisturb.mode.default", "DisplayString": "Do Not Disturb"}}
    if on:
        parameters["AssertionType"] = "Turned Off"  # until the app turns it off
    return {
        "WFWorkflowActions": [{"WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                               "WFWorkflowActionParameters": parameters}],
        "WFWorkflowClientVersion": "2607.0.2", "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [], "WFWorkflowInputContentItemClasses": [], "WFWorkflowTypes": [],
        "WFWorkflowHasShortcutInputVariables": False, "WFQuickActionSurfaces": [],
    }


def installed():
    names = subprocess.run(["shortcuts", "list"], capture_output=True, text=True).stdout.splitlines()
    return all(n in names for n in NAMES.values())


def setup():
    folder = Path(tempfile.mkdtemp(prefix="mr-focus-"))
    for on, name in NAMES.items():
        raw = folder / f"{name}.unsigned.shortcut"
        signed = folder / f"{name}.shortcut"
        with raw.open("wb") as f:
            plistlib.dump(workflow(on), f, fmt=plistlib.FMT_BINARY)
        subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(raw), "--output", str(signed)],
                       check=True, capture_output=True)
        subprocess.run(["open", str(signed)], check=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["setup"]:
        setup()
    elif sys.argv[1:] == ["check"]:
        sys.exit(0 if installed() else 1)
