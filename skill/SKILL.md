---
name: meeting
description: Understand a meeting recorded with Zubda (the Mac notch app, formerly Meeting Recorder) - transcribe it locally if needed and produce a full report. Use when the user says "شوف آخر ميتنج", "لخص الميتنج", "ايه اللي حصل في الميتنج", "review my last meeting", or asks anything about a meeting they recorded.
---

# Meeting

Each meeting is a folder in the meetings folder (default `~/Downloads/Meetings`, set by `meetings_folder` in `~/.config/meeting-recorder/config.json`):

- `others.caf` + `me.caf` for an online meeting (folder ends `_online`): what the Mac played, and the user's mic.
- `room.caf` for an in-person meeting (folder ends `_in-person`): every voice in the room, the user's included.
- `session.json`: `project` (the client), `title`, `attendees` (from the calendar), `startedAt`, `endedAt`, `marks`.
- `transcript.md`, `report.md` and their `.html` pages, when the app already processed it.

Lines in `transcript.md` are labelled `أنا` (the user), `الآخرون` (everyone else on the call) or `الحاضرين` (the room). When more than one voice is found on a shared track, labels are numbered instead (`الطرف التاني 1`, `متكلم 2`): voices were told apart on this computer, which can be wrong and gives no names. `★ علامة` lines are moments the user marked during the meeting, often with a note; treat them as the most important parts.

## Steps

1. If `transcript.md` is missing, transcribe. It runs locally and can take minutes, so run it in the background for long meetings:
   `{{PYTHON}} {{REPO}}/transcribe.py latest`
   Pass a folder path instead of `latest` for an older meeting; `--force` redoes it.
2. If `report.md` exists, the app wrote it already: read it and the transcript, and don't rewrite it unless asked. Otherwise read all of `transcript.md` (not a sample) and write `report.md` in the language set as `report_language` in the config, with:
   - Short summary
   - Full context: how the discussion started and developed, with timestamps
   - The marked moments
   - Comparison with the previous meeting of the same `project`, if there is one with a report
   - Decisions
   - Tasks: who owns what, and when
   - Open points
   - Lines to check in the recording, with timestamps
   Then run `{{PYTHON}} {{REPO}}/render.py <folder>/report.md` so it opens as a page.
3. Give the user the summary and the report link, then answer follow-up questions from the transcript.

## Accuracy rules

- Numbered speakers come from voice matching and can be wrong. Name someone only when the context shows who it is, and say when you are inferring it.
- Lines marked `(غير واضح)` may be wrong. Never base a decision, number, price or date on one without flagging it.
- Whisper invents short phrases over silence or music; ignore them.
- Nothing is reported that isn't in the transcript. If a section is empty, say so.
