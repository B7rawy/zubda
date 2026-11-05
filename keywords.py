#!/usr/bin/env python3
"""Names and terms of a meeting in both scripts, so Spotlight finds «ثواني» when you type Thawani.

Usage: keywords.py <meeting folder>   (report.py writes keywords.json itself; this backfills old meetings)
Writes keywords.json: {"ثواني": ["Thawani"], "Wave": ["ويف"], ...}
"""
import subprocess
import sys
from pathlib import Path

from config import claude_path

PROMPT = """Read {folder}/transcript.md. List the proper names and key terms in it (people, companies, products, payment gateways, apps, places, technical terms people would search for). For each, give the other spellings someone might type: the English/Latin spelling for Arabic words and the Arabic spelling for English ones, e.g. «ثواني» -> ["Thawani"], «Paymob» -> ["باي موب", "بايموب"]. Use the exact form as it appears in the transcript as the key. At most 40 entries. Write only {folder}/keywords.json as a JSON object, nothing else."""


def main():
    folder = Path(sys.argv[1]).expanduser().resolve()
    claude = claude_path()
    if not claude or not (folder / "transcript.md").exists():
        sys.exit(1)
    subprocess.run([claude, "-p", PROMPT.format(folder=folder), "--permission-mode", "acceptEdits",
                    "--strict-mcp-config", "--allowedTools", "Read", "Write", "--model", "haiku"],
                   cwd=folder, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)


if __name__ == "__main__":
    main()
