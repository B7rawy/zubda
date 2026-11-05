#!/usr/bin/env python3
"""Build ~/Downloads/Meetings/index.html: every meeting, grouped by client, with search.

Usage: archive.py   (prints the page path)
Search runs in the page itself over titles, report summaries and every transcript line.
"""
import json
import re
from datetime import datetime
from pathlib import Path

from config import MEETINGS

CSS = """
:root { --bg:#f5f5f3; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e4e4e6; --accent:#e5483d; --chip:#ececee; --hit:#fff1c2; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#121212; --card:#1d1d1f; --text:#ececec; --muted:#9a9a9f; --line:#2c2c2e; --accent:#ff6b5f; --chip:#2a2a2c; --hit:#4a3d12; }
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.7 -apple-system, "SF Arabic", "Geeza Pro", sans-serif; }
main { max-width:980px; margin:0 auto; padding:36px 20px 80px; }
header h1 { font-size:26px; margin:0; }
header p { color:var(--muted); margin:4px 0 20px; }
#q { width:100%; font:inherit; font-size:17px; padding:13px 16px; border-radius:12px; border:1px solid var(--line); background:var(--card); color:var(--text); outline:none; }
#q:focus { border-color:var(--accent); }
.chips { display:flex; flex-wrap:wrap; gap:8px; margin:14px 0 6px; }
.chip { border:0; font:inherit; font-size:13px; padding:5px 12px; border-radius:99px; background:var(--chip); color:var(--text); cursor:pointer; }
.chip.on { background:var(--accent); color:#fff; }
h2 { font-size:18px; margin:30px 0 10px; display:flex; gap:8px; align-items:baseline; }
h2 small { color:var(--muted); font-weight:500; font-size:13px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:14px 16px; margin:10px 0; }
.top { display:flex; justify-content:space-between; gap:12px; flex-wrap:wrap; }
.title { font-weight:650; font-size:16px; }
.meta { color:var(--muted); font-size:13px; }
.summary { margin:6px 0 0; }
.links { display:flex; gap:8px; margin-top:10px; }
.links a { font-size:13px; text-decoration:none; color:var(--accent); border:1px solid var(--line); padding:3px 10px; border-radius:8px; }
.hits { margin-top:10px; border-top:1px dashed var(--line); padding-top:8px; }
.hit { font-size:14px; margin:3px 0; }
.hit a { color:var(--accent); text-decoration:none; font:12.5px ui-monospace, Menlo, monospace; direction:ltr; unicode-bidi:isolate; margin-inline-end:6px; }
mark { background:var(--hit); color:inherit; border-radius:3px; }
.empty { color:var(--muted); text-align:center; margin:50px 0; }
"""

SCRIPT = r"""
const data = JSON.parse(document.getElementById('data').textContent);
const q = document.getElementById('q'), list = document.getElementById('list'), chips = document.getElementById('chips');
let client = 'all';
const norm = s => (s || '').toLowerCase().replace(/[أإآ]/g, 'ا').replace(/ة/g, 'ه').replace(/ى/g, 'ي').replace(/[ً-ْـ]/g, '');
const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function mark(text, words) {
  let out = esc(text);
  for (const w of words) if (w) out = out.replace(new RegExp(w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), m => `<mark>${m}</mark>`);
  return out;
}
const clients = [...new Set(data.map(m => m.client))];
chips.innerHTML = ['all', ...clients].map(c => `<button class="chip${c === client ? ' on' : ''}" data-c="${esc(c)}">${c === 'all' ? 'الكل' : esc(c)} </button>`).join('');
chips.onclick = e => { const c = e.target.dataset.c; if (!c) return; client = c; [...chips.children].forEach(b => b.classList.toggle('on', b.dataset.c === c)); draw(); };
function draw() {
  const words = norm(q.value).split(/\s+/).filter(Boolean);
  const groups = {};
  for (const m of data) {
    if (client !== 'all' && m.client !== client) continue;
    let hits = [];
    if (words.length) {
      const head = norm(m.title + ' ' + m.summary + ' ' + m.client + ' ' + m.people);
      hits = m.lines.filter(l => words.every(w => norm(l.text).includes(w))).slice(0, 6);
      if (!hits.length && !words.every(w => head.includes(w))) continue;
    }
    (groups[m.client] = groups[m.client] || []).push({m, hits});
  }
  const names = Object.keys(groups);
  if (!names.length) { list.innerHTML = '<p class="empty">مفيش ميتنجات بالكلام ده.</p>'; return; }
  list.innerHTML = names.map(c => `<h2>${esc(c)} <small>${groups[c].length} ميتنج</small></h2>` + groups[c].map(({m, hits}) => `
    <div class="card">
      <div class="top"><div class="title">${mark(m.title, words)}</div><div class="meta">${esc(m.when)} · ${esc(m.kind)}${m.length ? ' · ' + esc(m.length) : ''}</div></div>
      ${m.people ? `<div class="meta">${esc(m.people)}</div>` : ''}
      ${m.summary ? `<p class="summary">${mark(m.summary, words)}</p>` : ''}
      ${hits.length ? `<div class="hits">${hits.map(h => `<div class="hit"><a href="${m.transcript}">[${h.t}]</a>${mark(h.text, words)}</div>`).join('')}</div>` : ''}
      <div class="links">${m.report ? `<a href="${m.report}">التقرير</a>` : ''}${m.transcript ? `<a href="${m.transcript}">النص الكامل</a>` : ''}</div>
    </div>`).join('')).join('');
}
q.oninput = draw;
draw();
q.focus();
"""


def parse_time(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def summary_of(report):
    """First paragraph under the report's summary heading."""
    lines = report.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("## ") and "ملخص" in line:
            body = []
            for nxt in lines[i + 1:]:
                if nxt.startswith("## "):
                    break
                if nxt.strip():
                    body.append(re.sub(r"[*`#>]", "", nxt).strip(" -"))
                elif body:
                    break
            return " ".join(body)[:420]
    return ""


def meeting(folder):
    try:
        meta = json.loads((folder / "session.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if meta.get("status") in ("recording", "interrupted"):
        return None
    transcript = folder / "transcript.md"
    if not transcript.exists():
        return None
    started, ended = parse_time(meta.get("startedAt")), parse_time(meta.get("endedAt"))
    length = ""
    if started and ended:
        minutes = round((ended - started).total_seconds() / 60)
        length = f"{minutes} دقيقة" if minutes else "أقل من دقيقة"
    lines = []
    for line in transcript.read_text(encoding="utf-8").splitlines():
        found = re.match(r"\[(\d{2}:\d{2}:\d{2})\]\s*(.*)", line)
        if found:
            lines.append({"t": found.group(1), "text": found.group(2)})
    report = folder / "report.md"
    page = lambda name: f"{folder.name}/{name}" if (folder / name).exists() else ""
    title = meta.get("title") or folder.name
    if title in ("Online meeting", "In-person meeting") or title.startswith("Meet - "):
        title = f"{'ميتنج حضوري' if meta.get('mode') == 'room' else 'ميتنج أونلاين'}"
    return {
        "client": meta.get("project") or "بدون عميل",
        "title": title,
        "when": started.strftime("%Y-%m-%d · %I:%M %p") if started else folder.name[:10],
        "sort": folder.name,
        "kind": "حضوري" if meta.get("mode") == "room" else "أونلاين",
        "length": length,
        "people": "، ".join(meta.get("attendees") or []),
        "summary": summary_of(report.read_text(encoding="utf-8")) if report.exists() else "",
        "report": page("report.html") or page("report.md"),
        "transcript": page("transcript.html") or page("transcript.md"),
        "lines": lines,
    }


def build():
    meetings = [m for f in MEETINGS.iterdir() if f.is_dir() and (m := meeting(f))]
    meetings.sort(key=lambda m: m["sort"], reverse=True)
    payload = json.dumps(meetings, ensure_ascii=False).replace("</", "<\\/")
    page = (
        '<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1"><title>أرشيف الميتنجات</title>'
        f"<style>{CSS}</style></head><body><main>"
        f"<header><h1>أرشيف الميتنجات</h1><p>{len(meetings)} ميتنج · ابحث في العناوين والملخصات وكل كلمة اتقالت</p></header>"
        '<input id="q" type="search" placeholder="ابحث… مثلًا: بوابة الدفع، ثواني، التقسيط" autocomplete="off">'
        '<div class="chips" id="chips"></div><div id="list"></div></main>'
        f'<script type="application/json" id="data">{payload}</script><script>{SCRIPT}</script></body></html>'
    )
    target = MEETINGS / "index.html"
    target.write_text(page, encoding="utf-8")
    return target


if __name__ == "__main__":
    print(build())
