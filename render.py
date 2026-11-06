#!/usr/bin/env python3
"""Turn a meeting's report.md / transcript.md into a readable right-to-left HTML page.

Usage: render.py path/to/file.md   (writes file.html next to it)
Only the Markdown the reports use: headings, lists, bold, code, quotes, tables, timestamps.
"""
import html
import json
import re
import sys
from pathlib import Path

CSS = """
:root { --bg:#f7f7f5; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e5e5e7; --accent:#e5483d; --mark:#fff4d6; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#141414; --card:#1e1e1e; --text:#ececec; --muted:#9a9a9f; --line:#2e2e30; --accent:#ff6b5f; --mark:#3a3218; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:16px/1.85 -apple-system, "SF Arabic", "Geeza Pro", sans-serif; }
main { max-width:860px; margin:0 auto; padding:40px 20px 80px; }
h1 { font-size:26px; margin:0 0 6px; line-height:1.4; }
h2 { font-size:19px; margin:34px 0 10px; padding-bottom:6px; border-bottom:1px solid var(--line); }
h3 { font-size:16px; margin:22px 0 6px; }
p { margin:8px 0; }
ul, ol { margin:6px 0; padding-inline-start:22px; }
li { margin:4px 0; }
strong { font-weight:650; }
code, .ts { font:13px ui-monospace, Menlo, monospace; direction:ltr; unicode-bidi:isolate; }
code { background:var(--line); padding:1px 5px; border-radius:5px; }
.ts { color:var(--accent); }
blockquote { margin:12px 0; padding:8px 14px; border-inline-start:3px solid var(--accent); background:var(--card); border-radius:6px; color:var(--muted); }
table { border-collapse:collapse; width:100%; margin:12px 0; background:var(--card); }
th, td { border:1px solid var(--line); padding:7px 10px; text-align:start; vertical-align:top; }
th { background:var(--bg); }
.line { margin:3px 0; }
.line.star { background:var(--mark); border-radius:6px; padding:2px 8px; }
.who { color:var(--muted); font-weight:600; }
.player { position:sticky; top:0; z-index:5; background:var(--bg); padding:10px 0 12px; margin-bottom:8px; border-bottom:1px solid var(--line); }
.player audio { width:100%; }
.player small { color:var(--muted); }
.controls { display:flex; gap:6px; align-items:center; margin-top:6px; flex-wrap:wrap; }
.controls button { font:12px -apple-system, sans-serif; border:1px solid var(--line); background:var(--card); color:inherit; border-radius:6px; padding:3px 9px; cursor:pointer; }
.controls button.on { background:var(--accent); border-color:var(--accent); color:#fff; }
.controls .sep { flex:1; }
.ts.play { cursor:pointer; border-radius:4px; }
.ts.play:hover { background:var(--mark); }
.line.now { outline:2px solid var(--accent); border-radius:6px; }
.clip { border:0; background:none; color:var(--muted); cursor:pointer; font-size:13px; padding:0 4px; opacity:0; border-radius:4px; }
.line:hover .clip, li:hover .clip, .clip:focus { opacity:1; }
.clip:hover { background:var(--mark); color:var(--accent); }
"""

# Clicking a timestamp plays the recording from just before that moment.
PLAYER_JS = """
const audio = document.querySelector('audio');
const seconds = t => t.split(':').reduce((a, b) => a * 60 + +b, 0);
document.querySelectorAll('.ts').forEach(el => {
  el.classList.add('play');
  el.title = 'Play from here';
  el.onclick = () => {
    audio.currentTime = Math.max(0, seconds(el.textContent.replace(/[\\[\\]]/g, '')) - 1);
    audio.play();
    document.querySelectorAll('.line.now').forEach(l => l.classList.remove('now'));
    el.closest('.line')?.classList.add('now');
  };
});
// Share a moment: the app cuts 30 seconds of audio around it, with the words said.
document.querySelectorAll('.ts').forEach(el => {
  const button = document.createElement('button');
  button.className = 'clip';
  button.textContent = '⤴';
  button.title = 'Share this moment as a clip';
  button.onclick = event => {
    event.stopPropagation();
    location.href = 'mrclip:' + seconds(el.textContent.replace(/[\\[\\]]/g, ''));
  };
  el.after(button);
});
const jump = location.hash.match(/t=(\\d+)/);
if (jump) {
  audio.currentTime = +jump[1];
  // Opened from Spotlight or a link: show the line that was said then.
  const lines = [...document.querySelectorAll('.line')];
  const at = lines.find(l => { const ts = l.querySelector('.ts'); return ts && seconds(ts.textContent.replace(/[\\[\\]]/g, '')) >= +jump[1]; });
  if (at) { at.classList.add('now'); at.scrollIntoView({block: 'center'}); }
}
"""

# Playback speed and skipping silence, remembered between pages.
SPEED_JS = """
const store = (k, v) => { try { v === undefined ? null : localStorage.setItem(k, v); return localStorage.getItem(k); } catch (e) { return null; } };
const rateButtons = document.querySelectorAll('.controls [data-rate]');
const setRate = r => { audio.playbackRate = r; rateButtons.forEach(b => b.classList.toggle('on', +b.dataset.rate === r)); store('rate', r); };
rateButtons.forEach(b => b.onclick = () => setRate(+b.dataset.rate));
setRate(+(store('rate') || 1));
const skip = document.getElementById('skip');
let skipping = store('skip') === '1';
skip.classList.toggle('on', skipping);
skip.onclick = () => { skipping = !skipping; skip.classList.toggle('on', skipping); store('skip', skipping ? '1' : '0'); };
audio.addEventListener('timeupdate', () => {
  if (!skipping || !SPEECH.length || audio.paused) return;
  const t = audio.currentTime;
  if (SPEECH.some(([s, e]) => t >= s - 0.3 && t <= e + 0.6)) return;
  const next = SPEECH.find(([s]) => s > t);
  if (next) { audio.currentTime = next[0] - 0.3; } else { audio.pause(); }
});
"""


def speech_ranges(folder):
    """When someone is talking, merged, from transcript.json: gaps longer than 2 s are silence."""
    try:
        segments = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))["segments"]
    except (OSError, ValueError, KeyError):
        return []
    ranges = []
    for s in sorted(segments, key=lambda s: s["start"]):
        if ranges and s["start"] - ranges[-1][1] < 2:
            ranges[-1][1] = max(ranges[-1][1], s["end"])
        else:
            ranges.append([round(s["start"], 1), round(s["end"], 1)])
    return ranges


TRACKS = ("others", "me", "room")


def mixed_audio(folder):
    """One playable file for the page: the call's tracks mixed together, as AAC in .m4a."""
    target = folder / "audio.m4a"
    if target.exists():
        return target
    sources = [folder / f"{t}{ext}" for t in TRACKS for ext in (".caf", ".webm", ".flac", ".wav") if (folder / f"{t}{ext}").exists()]
    if not sources:
        return None
    import subprocess
    import imageio_ffmpeg

    command = [imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-loglevel", "error", "-y"]
    for source in sources:
        command += ["-i", str(source)]
    if len(sources) > 1:
        command += ["-filter_complex", f"amix=inputs={len(sources)}:duration=longest:normalize=0"]
    command += ["-ac", "1", "-c:a", "aac", "-b:a", "64k", str(target)]
    try:
        subprocess.run(command, check=True, capture_output=True)
    except (subprocess.CalledProcessError, OSError):
        return None
    return target

# [00:12:03], 00:12:03 or 12:03 (reports write offsets in all three forms).
TIMESTAMP = re.compile(r"\[?(?<![\d:])(\d{2}:\d{2}(?::\d{2})?)(?![\d:])\]?")


def inline(text):
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    return TIMESTAMP.sub(r'<span class="ts">\1</span>', text)


def transcript_line(line):
    star = "★" in line
    match = re.match(r"\[(\d{2}:\d{2}:\d{2})\]\s*([^:]+):\s*(.*)", line)
    if match and not star:
        stamp, who, said = match.groups()
        body = f'<span class="ts">[{stamp}]</span> <span class="who">{html.escape(who)}:</span> {inline(said)}'
    else:
        body = inline(line)
    return f'<p class="line{" star" if star else ""}">{body}</p>'


def convert(markdown, is_transcript):
    out, list_tag, table = [], None, []

    def close_list():
        nonlocal list_tag
        if list_tag:
            out.append(f"</{list_tag}>")
            list_tag = None

    def flush_table():
        if not table:
            return
        rows = [r for r in table if not re.fullmatch(r"\|?[\s:\-|]+\|?", r)]
        cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
        out.append("<table>")
        for i, row in enumerate(cells):
            tag = "th" if i == 0 else "td"
            out.append("<tr>" + "".join(f"<{tag}>{inline(c)}</{tag}>" for c in row) + "</tr>")
        out.append("</table>")
        table.clear()

    for raw in markdown.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if stripped.startswith("|"):
            close_list()
            table.append(stripped)
            continue
        flush_table()
        if not stripped:
            close_list()
            continue
        heading = re.match(r"(#{1,3})\s+(.*)", stripped)
        bullet = re.match(r"[-*]\s+(.*)", stripped)
        numbered = re.match(r"\d+[.)]\s+(.*)", stripped)
        if heading:
            close_list()
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
        elif bullet or numbered:
            tag = "ul" if bullet else "ol"
            if list_tag != tag:
                close_list()
                out.append(f"<{tag}>")
                list_tag = tag
            out.append(f"<li>{inline((bullet or numbered).group(1))}</li>")
        elif stripped.startswith(">"):
            close_list()
            out.append(f"<blockquote>{inline(stripped.lstrip('> '))}</blockquote>")
        elif is_transcript and stripped.startswith("["):
            close_list()
            out.append(transcript_line(stripped))
        else:
            close_list()
            out.append(f"<p>{inline(stripped)}</p>")
    flush_table()
    close_list()
    return "\n".join(out)


def render(path):
    path = Path(path)
    text = path.read_text(encoding="utf-8")
    try:
        audio = mixed_audio(path.parent)
    except ImportError:  # imageio_ffmpeg missing: the page still works, just without playback
        audio = None
    player = (f'<div class="player"><audio controls preload="metadata" src="{audio.name}"></audio>'
              '<div class="controls"><button data-rate="1" class="on">1×</button><button data-rate="1.5">1.5×</button>'
              '<button data-rate="2">2×</button><button id="skip" title="Jump over the gaps where nobody talks">Skip silence</button>'
              '<span class="sep"></span><small>Click any timestamp to hear that moment.</small></div></div>') if audio else ""
    speech = speech_ranges(path.parent) if audio else []
    script = (f"<script>const SPEECH = {json.dumps(speech)};\n{PLAYER_JS}\n{SPEED_JS}</script>") if audio else ""
    title = next((l.lstrip("# ").strip() for l in text.splitlines() if l.startswith("#")), path.stem)
    page = (
        '<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        f"<title>{html.escape(title)}</title><style>{CSS}</style></head>"
        f"<body><main>{player}{convert(text, path.stem.startswith('transcript'))}</main>{script}</body></html>"
    )
    target = path.with_suffix(".html")
    target.write_text(page, encoding="utf-8")
    return target


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        print(render(arg))
