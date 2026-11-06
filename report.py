#!/usr/bin/env python3
"""Write report.md for a transcribed meeting using Claude Code.

Usage: report.py path/to/meeting-folder
Compares with the previous meeting of the same project when one has a report.
"""
import json
import signal
import subprocess
import sys
from pathlib import Path

from config import MEETINGS, SETTINGS, claude_path

PROMPT = """Read the whole meeting transcript at {folder}/transcript.md (every line, not a sample) and write {folder}/report.md.

Context: project «{project}», recorded {mode}. In the transcript «أنا» is {user} (their mic), «الآخرون» is everyone on the other side of an online call, «الحاضرين» is everyone in the room of an in-person meeting ({user} included). When several people share a track the labels are numbered («متحدث 1», «ضيف 2», or the older «الطرف التاني 1», «متكلم 2») by telling voices apart; that numbering can be wrong and carries no names, so infer who is who from the context and say when you do. Lines starting with «★ علامة» are moments {user} marked during the meeting, sometimes with their note.
{previous}
Measured from the transcript timings (not your guess): {stats}

Write the report in {report_language}, short sentences, with these sections:
- ملخص قصير
- مين اتكلم أد إيه: the talk shares and interruptions above in one or two lines, with names where you know them, and one short observation (e.g. who led, who barely spoke)
- السياق الكامل: الموضوع بدأ إزاي واتطور إزاي، بالترتيب وبالتوقيتات
- اللحظات اللي علّمتها: كل علامة بتوقيتها وملاحظتك والكلام اللي اتقال حواليها (لو مفيش علامات قول كده)
{compare_section}- القرارات
- المهام: مين مسؤول عن إيه والموعد
- النقط المفتوحة
- جمل محتاجة مراجعة في التسجيل، بالتوقيت

Accuracy rules: the voice numbering is not names, so only name someone when the context shows who it is and say when you infer it. Lines marked (غير واضح) may be wrong; never base a decision, number, price or date on one without flagging it. Report nothing that is not in the transcript. Whisper invents phrases in silence (مرحبا، اشتركوا في القناة، شكرا، موسيقى); ignore them.

Also write three small JSON files:
1. {folder}/speakers.json: an object mapping numbered voice labels from the transcript («متحدث 1», «ضيف 2»…) to real first names, only when the conversation makes it clear (someone is addressed or introduces themselves, e.g. «يا باشمهندس كريم»; on an in-person meeting one voice is {user}). Leave out any label you are not sure of. Write {{}} if there are none or the transcript has no numbered labels. In the report itself use these names instead of the numbers.
2. {folder}/promises.json: a list of commitments made in the meeting, each {{"who": name or label, "what": short text in the report language, "due": "YYYY-MM-DDTHH:MM" local time or "YYYY-MM-DD" or null, "said_at": "hh:mm:ss" from the transcript}}. The meeting was on {date} ({weekday}); turn «بكرة», «الخميس», «الأسبوع الجاي» into real dates from that. Only real commitments («هبعتلك العرض بكرة»), not wishes. Write [] if there are none.

3. {folder}/keywords.json: proper names and key terms from the transcript (people, companies, products, apps, payment gateways, places) mapped to the other spellings someone might search for: Latin for Arabic words, Arabic for English ones, e.g. {{"ثواني": ["Thawani"], "Paymob": ["باي موب"]}}. Keys exactly as written in the transcript. At most 40.

Only write {folder}/report.md, {folder}/speakers.json, {folder}/promises.json and {folder}/keywords.json. Do not change any other file."""


def previous_meeting(folder, project):
    candidates = []
    for meta_path in MEETINGS.glob("*/session.json"):
        other = meta_path.parent
        if other == folder or other.name > folder.name or not (other / "report.md").exists():
            continue
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except ValueError:
            continue
        if meta.get("project") == project:
            candidates.append(other)
    return max(candidates, key=lambda p: p.name, default=None)


def main():
    folder = Path(sys.argv[1]).expanduser().resolve()
    if not (folder / "transcript.md").exists():
        sys.exit(f"{folder} has no transcript.md")
    meta = json.loads((folder / "session.json").read_text(encoding="utf-8"))
    project = meta.get("project") or "General"
    previous = previous_meeting(folder, project) if project != "General" else None

    sys.path.insert(0, str(Path(__file__).parent))
    import insights
    from datetime import datetime

    try:
        stats = insights.stats_text(insights.write_stats(folder))
    except (OSError, ValueError, KeyError):
        stats = "not available"
    try:
        started = datetime.fromisoformat(meta["startedAt"].replace("Z", "+00:00")).astimezone()
    except (KeyError, ValueError):
        started = datetime.now()
    prompt = PROMPT.format(
        stats=stats,
        date=started.strftime("%Y-%m-%d %H:%M"),
        weekday=started.strftime("%A"),
        folder=folder,
        project=project,
        user=SETTINGS["user_name"],
        report_language=SETTINGS["report_language"],
        mode="in person" if meta.get("mode") == "room" else "online",
        previous=(f"\nThe previous «{project}» meeting's report is {previous}/report.md. Read it too.\n" if previous else ""),
        compare_section=("- مقارنة بالميتنج اللي فات: إيه اللي اتنفذ، إيه اللي اتغير، وإيه اللي لسه مفتوح من المرة اللي فاتت\n" if previous else ""),
    )
    claude = claude_path()
    if not claude:
        sys.exit("The claude CLI isn't installed, so no report; the transcript is ready.")
    log = (folder / "report.log").open("w")
    child = subprocess.Popen(
        [claude, "-p", prompt,
         "--permission-mode", "acceptEdits",
         # The report needs no connectors; skipping them keeps their login errors out of the log.
         "--strict-mcp-config",
         "--allowedTools", "Read", "Write", "Glob",
         "--add-dir", str(MEETINGS)],
        cwd=folder, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
    )
    # The app cancels a queued meeting by terminating this script; take Claude down with it.
    try:
        signal.signal(signal.SIGTERM, lambda *_: (child.terminate(), sys.exit(1)))
    except (ValueError, OSError):  # not available in every context on Windows
        pass
    child.wait()
    if child.returncode != 0 or not (folder / "report.md").exists():
        sys.exit(f"Report failed, see {folder}/report.log")
    names_file = folder / "speakers.json"
    try:
        names = json.loads(names_file.read_text(encoding="utf-8")) if names_file.exists() else {}
    except ValueError:
        names = {}
    if isinstance(names, dict) and names:
        insights.rename(folder, names)  # transcript, stats and session get the names too
    import render
    render.render(folder / "report.md")
    import archive
    archive.build()
    print(folder / "report.md")


if __name__ == "__main__":
    main()
