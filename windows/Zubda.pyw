# Double-click (or the Start menu shortcut) runs Zubda without a console window.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from zubda.app import main  # noqa: E402

main()
