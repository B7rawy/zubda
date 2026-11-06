# Zubda · زُبدة

**A 90-minute meeting? Just give me the gist.**

Zubda is a free, open-source meeting recorder that lives in your Mac's notch. It records your meetings, online or in the room, writes down every word on your own computer, and gives you a report with the decisions, tasks, promises and open points. Your own Claude can read all your meetings and answer questions about them.

Built for Arabic dialects (Egyptian, Gulf…) and English. *Zubda* is Arabic for "the gist" (literally, "the cream").

---

## What it does

### Recording
- **From the notch:** move the mouse to the notch and it opens. One button for online meetings (Zoom, Meet, Teams, WhatsApp) and one for meetings in the room.
- **New Meet:** opens a new Google Meet and starts recording right away.
- **Join & Record:** if a calendar meeting has a link, the notch asks you before it starts, and one button joins and records.
- **Knows when a call starts:** as soon as a calling app turns on the mic, it asks whether to record. When the call ends it asks again, and saves on its own if you don't answer.
- **Do Not Disturb:** notifications go quiet while you record and come back when you finish. Needs two shortcuts added once from Settings.
- **5 minutes left:** before a calendar meeting's end time, the notch tells you quietly.

### During the meeting
- **Live captions, word by word** in the notch, and under it like movie subtitles when it's closed.
- **Who's speaking:** "Speaker 1, Speaker 2" in the room, "Guest 1, Guest 2" online.
- **Live translation** to Arabic or English.
- **Someone said your name?** The notch opens with a sound and shows the sentence and what came before it, so you can answer right away. You can add other words too.
- **Automatic marks ★:** any price, date or promise ("I'll send it tomorrow") is marked on its own. Mark a moment yourself with `⌃⌥M`.
- **"What did I miss?":** drifted off? One button summarises the last 5 minutes.

### After the meeting
- **Full report:** summary, the story from start to end, decisions, tasks, open points, and a comparison with your last meeting with the same client.
- **Real names:** Claude works out who "Speaker 1" is from the conversation, or you type names with the Name speakers button.
- **Who talked how much:** talk shares, and who interrupted whom.
- **Promises:** who promised what and by when, with a Mac reminder before the due date.
- **Replay any moment:** click any timestamp to hear it. 1.5× and 2× speed, and skip silence.
- **Share a moment:** the ⤴ button next to any line cuts 30 seconds of audio with the text, ready for WhatsApp or AirDrop.
- **Spotlight:** `⌘ Space`, type any word said in any meeting, in Arabic or English, and it opens that moment.

### Claude
- **Claude Desktop and Claude Code can see your meetings**, including the one happening now. Ask "what did the client say about payment?" without uploading a file.
- **Ask from the notch** and get the answer with timestamps.
- **Claude card on the Home page:** shows whether Claude Desktop and Claude Code are connected, a button that opens Claude Desktop on your meetings, and ready-made questions you can send with one click.

### Also
- **WhatsApp voice notes:** the notch offers to transcribe and summarise them.
- **Spoken notes:** press `⌃⌥N` and talk; the notch writes it down and saves it.
- **Morning brief** of today's meetings, and a **countdown** to the next one.

---

## Free or paid?

| | Free, on your computer | Faster with Soniox (optional) |
|---|---|---|
| Live transcription | Whisper on the Mac's chip | Soniox, under a second |
| Live speaker labels | No | Yes |
| Translation | Apple, on device | Soniox |
| Cost | Free | About $0.12 an hour, on your own account |
| Does audio leave the Mac? | No | Yes, to Soniox only, while recording |

Choose in **Settings → Recording** and paste your Soniox key there. If the key stops working or the internet drops, Zubda falls back to on-device transcription by itself.

Reports are written by **Claude on your own account**. There is no server of ours in between.

---

## Requirements

- A **Mac** with Apple silicon (M1 or later), or **Windows 10/11** (beta).
- [Claude Code](https://claude.com/claude-code): it installs Zubda, writes the reports and answers your questions.

## Install

Give this repo's link to Claude Code and say:

> Install this for me

It does everything and asks for your name and the language of your meetings. You only need to:
1. Allow the Mac permissions when they appear: Microphone, Screen & System Audio Recording (for online meetings), Calendars and Notifications.
2. If `claude` isn't logged in: open Terminal, type `claude`, then `/login`.

Or install it yourself:

```bash
./setup.sh
```

**On Windows**, from the repo folder in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

The Windows version has a black bar at the top centre of the screen that works like the notch, a main window, and a tray icon. It records everything the PC plays plus the mic, so it works with Zoom, Teams, Meet and WhatsApp. Not there yet: search from the Start menu, Do Not Disturb, calendar, and WhatsApp voice notes.

The transcription model (about 1.6 GB) downloads with your first meeting. To get it now: `./setup.sh --download-model`

## Privacy

- Recordings and transcripts stay on your computer, in `Downloads/Meetings`.
- No server, no account, no subscription.
- **Tell people before you record.** In many countries recording without consent is against the law.

## Made by

[Kareem Elbhrawy](https://kareemelbhrawy.com). I built it for my client meetings in Egyptian and Gulf Arabic, then made it free for everyone.

## License

MIT: use it, change it and share it for free.
