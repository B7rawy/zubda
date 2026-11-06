#!/usr/bin/env python3
"""Things worked out from a transcript without asking a model.

- talk_stats: who talked how long, and who cut in on whom.
- moment: whether a live line mentions a price, a date or a promise, for automatic marks.
- rename: swap voice labels («متحدث 1») for names, in the transcript, report and stats.

Usage: insights.py rename <folder> '{"متحدث 1": "كريم"}'
"""
import json
import re
import sys
from pathlib import Path

# Overlaps shorter than this are people agreeing («آه»، «تمام»), not cutting in.
INTERRUPT_MIN = 0.4


def talk_stats(segments):
    talk = {}
    for seg in segments:
        talk[seg["speaker"]] = talk.get(seg["speaker"], 0.0) + max(0.0, seg["end"] - seg["start"])
    total = sum(talk.values()) or 1.0
    interruptions = {}
    ordered = sorted(segments, key=lambda s: s["start"])
    for before, after in zip(ordered, ordered[1:]):
        if after["speaker"] != before["speaker"] and before["end"] - after["start"] >= INTERRUPT_MIN:
            key = f"{after['speaker']} → {before['speaker']}"
            interruptions[key] = interruptions.get(key, 0) + 1
    return {
        "talk": [{"speaker": s, "seconds": round(t), "percent": round(100 * t / total)}
                 for s, t in sorted(talk.items(), key=lambda kv: -kv[1])],
        "interruptions": [{"who": k, "count": n} for k, n in sorted(interruptions.items(), key=lambda kv: -kv[1])],
    }


def stats_text(stats):
    talk = "، ".join(f"{t['speaker']} {t['percent']}٪" for t in stats["talk"])
    cuts = "، ".join(f"{i['who']} ({i['count']})" for i in stats["interruptions"]) or "مفيش"
    return f"نسبة الكلام: {talk}. المقاطعات (مين قاطع مين): {cuts}."


def write_stats(folder):
    data = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
    stats = talk_stats(data["segments"])
    (folder / "stats.json").write_text(json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")
    return stats


def smooth_speakers(segments):
    """Fix the usual mistake of live voice separation before the transcript is saved: a "voice"
    that only ever said a few words (one person split in two) is merged into the nearest real
    speaker. Short replies between two people («آه»، «بالظبط») are real turns and stay as they are;
    flickers inside one person's talk are already handled live (cloud_live SWITCH_*).
    Only numbered voices on shared tracks are touched ("متحدث 2", "ضيف 1"); «أنا» never changes."""
    numbered = re.compile(r"(متحدث|ضيف) \d+")
    by_track = {}
    for seg in segments:
        if numbered.fullmatch(seg.get("speaker", "")):
            by_track.setdefault(seg["track"], []).append(seg)

    def words(seg):
        return len(seg["text"].split())

    for lines in by_track.values():
        lines.sort(key=lambda s: s["start"])
        total = sum(words(s) for s in lines) or 1
        counts = {}
        for seg in lines:
            counts.setdefault(seg["speaker"], []).append(seg)
        real = [name for name, segs in counts.items() if sum(words(s) for s in segs) / total >= 0.04 or len(segs) > 3]
        if not real:
            continue
        for name, segs in counts.items():
            if name in real:
                continue
            for seg in segs:
                nearest = min((s for s in lines if s["speaker"] in real),
                              key=lambda s: abs(s["start"] - seg["start"]), default=None)
                if nearest:
                    seg["speaker"] = nearest["speaker"]
        # Renumber in order of first appearance, so the voices read 1, 2, 3 with no gaps.
        order = []
        for seg in lines:
            if seg["speaker"] not in order:
                order.append(seg["speaker"])
        prefix = lambda name: name.split(" ")[0]
        mapping = {name: f"{prefix(name)} {i + 1}" for i, name in enumerate(order)}
        for seg in lines:
            seg["speaker"] = mapping[seg["speaker"]]
    return segments


# Live automatic marks. Kept narrow on purpose: a mark should mean something.
NUMBER = r"(\d[\d,.]*|[٠-٩][٠-٩٬٫]*|ألف|الف|مية|ميه|مليون|عشرة|عشرين|خمسين|مئة)"
PATTERNS = {
    "سعر": re.compile(NUMBER + r"\s*(ريال|جنيه|دولار|درهم|دينار|يورو|ر\.?س|\$|EGP|SAR|USD|OMR)|"
                      r"(السعر|التكلفة|التكلفه|الميزانية|الميزانيه|الدفعة|الدفعه|المقدم|الخصم|price|budget)\s"),
    "موعد": re.compile(r"(بكرة|بكره|بعد بكرة|بعد بكره|غدًا|غدا|الأسبوع الجاي|الاسبوع الجاي|الأسبوع القادم|الشهر الجاي|"
                       r"يوم (السبت|الأحد|الاحد|الاثنين|الإثنين|التلات|الثلاثاء|الأربع|الاربعاء|الأربعاء|الخميس|الجمعة)|"
                       r"الساعة\s*" + NUMBER + r"|deadline|ديدلاين|آخر ميعاد|اخر ميعاد|قبل يوم)"),
    "وعد": re.compile(r"\b(هبعت|هبعتلك|هبعتهولك|هرسل|هسلم|هسلّم|هخلص|هخلّص|هجهز|هجهّز|هكلم|هكلّم|هتابع|"
                      r"هنبعت|هنسلم|هنخلص|هنجهز|"
                      r"حبعت|حرسل|حسلم|حخلص|"
                      r"بنرسل|راح أرسل|راح ارسل|بأرسل|بارسل|سأرسل|سأسلم|سنرسل|سنسلم|"
                      r"أوعدك|اوعدك|وعد مني|ألتزم|التزم)"),
}


def moment(text):
    """The kinds of thing worth marking in one live line, e.g. ["سعر", "موعد"]."""
    return [kind for kind, pattern in PATTERNS.items() if pattern.search(text)]


def rename(folder, names):
    """Replace voice labels with names everywhere the meeting is written down."""
    names = {k: v.strip() for k, v in names.items() if v and v.strip() and v.strip() != k}
    if not names:
        return
    sys.path.insert(0, str(Path(__file__).parent))
    import transcribe
    import render

    data = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
    for seg in data["segments"]:
        seg["speaker"] = names.get(seg["speaker"], seg["speaker"])
    meta = data["meeting"]
    meta["speaker_names"] = {**meta.get("speaker_names", {}), **names}
    transcribe.write_outputs(folder, meta, data["segments"])
    write_stats(folder)
    report = folder / "report.md"
    if report.exists():
        text = report.read_text(encoding="utf-8")
        # Longest first, so «متحدث 10» is not caught by «متحدث 1».
        for old in sorted(names, key=len, reverse=True):
            text = re.sub(re.escape(old) + r"(?!\d)", names[old], text)
        report.write_text(text, encoding="utf-8")
        render.render(report)
    try:
        session = folder / "session.json"
        saved = json.loads(session.read_text(encoding="utf-8"))
        saved["speaker_names"] = meta["speaker_names"]
        session.write_text(json.dumps(saved, ensure_ascii=False, indent=2), encoding="utf-8")
    except (OSError, ValueError):
        pass


def voices(folder):
    """Numbered voice labels in a transcript, for the rename sheet."""
    data = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
    seen = []
    for seg in data["segments"]:
        if re.fullmatch(r"(متحدث|ضيف|الطرف التاني|متكلم) \d+", seg["speaker"]) and seg["speaker"] not in seen:
            seen.append(seg["speaker"])
    return seen


if __name__ == "__main__":
    command, target = sys.argv[1], Path(sys.argv[2]).expanduser()
    if command == "rename":
        rename(target, json.loads(sys.argv[3]))
    elif command == "voices":
        print(json.dumps(voices(target), ensure_ascii=False))
    elif command == "stats":
        print(stats_text(write_stats(target)))
