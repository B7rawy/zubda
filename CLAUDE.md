# Zubda (Meeting Recorder) — notes for Claude

The user cloned this repo and wants it working. You install it, check it, and explain the few
steps only they can do.

## Install (macOS, Apple silicon)

1. Check: `uname -m` is `arm64`, `xcode-select -p` works, Python 3.10+ exists (`brew install python` if not).
2. Run `./setup.sh` from the repo root. It creates `~/.local/share/meeting-recorder/venv`, writes
   `~/.config/meeting-recorder/config.json` from `config.example.json` if missing, builds the app into
   `~/Applications/Zubda.app`, and installs the `meeting` skill into `~/.claude/skills/meeting`.
   Add `--download-model` to fetch the Whisper model now (~1.6 GB) instead of on the first meeting;
   ask the user first, it is a large download.
3. Ask the user for their name, the language they speak in meetings, and the language they want
   reports in, then edit `config.json` (`user_name`, `language`, `prompt`, `report_language`).
   `prompt` is one sentence in the meeting language describing the meeting, e.g. the dialect.
4. Reports and the notch's question box use the `claude` CLI. If `claude auth status` says
   `loggedIn: false`, tell the user to run `claude` in Terminal and then `/login` themselves.
   You can't log in for them.

## What only the user can do

- Allow Microphone, Screen & System Audio Recording (online meetings), Calendars and Notifications
  when macOS asks. Screen recording needs the app reopened after allowing it.
- Optional: add their Google account in System Settings → Internet Accounts so calendar
  meetings show up.

## Install (Windows 10/11, beta)

1. Python 3.11 or 3.12 must exist (`py -3.12 --version`). If not, ask the user, then
   `winget install -e --id Python.Python.3.12`.
2. From the repo folder: `powershell -ExecutionPolicy Bypass -File .\setup.ps1`. It creates the venv in
   `%USERPROFILE%\.local\share\meeting-recorder\venv` (about 600 MB of libraries: PySide6, faster-whisper,
   PyAudioWPatch…), the settings in `%APPDATA%\meeting-recorder\config.json`, connects Claude, installs the
   skill, adds "Zubda" to the Start menu and opens it. `-DownloadModel` fetches the Whisper model now
   (about 1.6 GB); ask first.
3. Same step 3 and 4 as the Mac (name, languages, `claude` logged in). The user's name and languages can
   also be set in Zubda > Settings.
4. Prefer Claude Code's native installer on Windows (`claude.exe`); `config.py` uses it over npm's
   `claude.cmd`, which can't take the report prompt as an argument.

The Windows app is Python (`windows/zubda/`, PySide6): a bar at the top centre of the screen that acts
like the Mac notch, a main window (Home with the Claude card, Meetings with report/transcript pages,
Settings, About) and a tray icon. Audio: WASAPI loopback (everything the PC plays) + the mic, via
PyAudioWPatch, written as `others.wav`/`me.wav` or `room.wav`. Call detection reads Windows' own
microphone-in-use records. Not on Windows yet: Spotlight-style search, Do Not Disturb, calendar,
WhatsApp voice notes. `tests/windows_check.py` + `.github/workflows/windows.yml` test it on a GitHub
Windows machine on every push.

## Layout

- `mac/` — the Swift notch app (records, asks before/after calls, queue, archive, questions).
- `whisper_engine.py` — one Whisper call for both systems: mlx-whisper on Apple silicon, faster-whisper
  (CUDA if present, else CPU int8) everywhere else.
- `transcribe.py` — local Whisper; `report.py` — report via `claude -p`; `render.py` —
  Markdown to RTL HTML; `archive.py` — searchable index of all meetings; `config.py` — settings.
- `skill/SKILL.md` — template for the `meeting` skill; `setup.sh` fills in the paths.
- `mcp_server.py` — MCP connector (stdlib only) giving Claude list/get/search/live/open-items tools;
  `connect_claude.py` registers it with Claude Desktop (backup kept) and Claude Code. Tell the user to
  quit and reopen Claude Desktop once.
- `live.py` — live transcript while recording: word by word (default, `live_mode: "word"`) or every ~10 s (`"sentence"`); writes `live.jsonl` for the connector. Optional `live_engine: "soniox"` streams to Soniox instead (`cloud_live.py`, key in `~/.config/meeting-recorder/soniox.key`, chosen in Settings → Recording) and falls back to local Whisper if refused. With Soniox the room and call tracks get live speaker labels (Speaker 1/2, Guest 1/2) and captions are translated by Soniox in the same stream.
- `insights.py` — talk shares and interruptions (stats.json), live auto-mark patterns (price/date/promise), and `rename` to put names on numbered voices. `report.py` also asks Claude for `speakers.json` (names it can infer) and `promises.json` (commitments with due dates; the app schedules reminders).
- `clip.py` — cuts 30 s around a moment (share button ⤴ next to every timestamp in the pages). The app indexes transcripts in Spotlight (`Spotlight.swift`, with other spellings from `keywords.json`, written by report.py or backfilled by `keywords.py`) and opens a result at that moment. Saying the user's name or an `alert_words` word in a meeting opens the notch with a sound.
- `focus.py` — builds and signs two Shortcuts (Do Not Disturb on/off) the user adds once; the app runs them while recording if enabled. Calendar events with a Meet/Zoom/Teams link get Join & Record; the notch has New Meet (meet.new); 5 min before a calendar meeting ends a ⏱ line appears. Pages have 1×/1.5×/2× and Skip silence (from transcript.json).
- Home's Claude card opens a Claude Code session in Claude Desktop with the question prefilled and the meetings folder as working folder (`claude://code/new?q=…&folder=…`); the user presses Return. `connect_claude.py` also builds `dist/zubda.mcpb`, a Claude Desktop extension, and opens it for the user to click Install, because Claude Desktop rewrites `claude_desktop_config.json` while running and drops servers added there.
- `voice.py` — WhatsApp voice notes and spoken notes (`⌃⌥N`); saves to `Voice notes/` and `Notes/notes.md`.
- `legacy/chrome-extension/` — the first version, a Chrome extension; not installed by setup.

## Gotchas

- The app is called Zubda; internal paths keep the old name on purpose (`~/.config/meeting-recorder`, `~/.local/share/meeting-recorder`, bundle id `net.in-general.meeting-recorder`), because macOS ties permissions to the bundle id. The connector is registered as `zubda`.

- Decode audio with `imageio_ffmpeg`, not a system ffmpeg: Homebrew on old Intel installs can be the wrong architecture.
- Pass stdin=/dev/null when running `claude -p` from scripts, or it waits three seconds for input.
- `mac/build.sh` refuses to reinstall while a recording is running, so it can't cut a meeting short.
