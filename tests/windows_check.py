"""End-to-end checks for the Windows build, run by .github/workflows/windows.yml.

Uses a short public English clip (JFK, from the faster-whisper test data) and the tiny model so it
runs in minutes on a GitHub Windows machine. Covers: Whisper through whisper_engine, the live
transcriber over its stdin protocol, the full transcribe.py pipeline on a meeting folder, the
HTML pages, the Claude connector, and reading which apps hold the microphone.
Exit code 0 only if every check passed; each result is printed.
"""
import json
import os
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
CLIP_URL = "https://github.com/SYSTRAN/faster-whisper/raw/master/tests/data/jfk.flac"
WORK = Path(os.environ.get("ZUBDA_TEST_DIR", REPO / "test-output"))
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}", flush=True)


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    clip = WORK / "jfk.flac"
    if not clip.exists():
        urllib.request.urlretrieve(CLIP_URL, clip)

    import config
    import transcribe
    import whisper_engine

    check("config points at the test folder", str(config.MEETINGS).startswith(str(WORK)), str(config.MEETINGS))
    check("faster-whisper is the engine on Windows", whisper_engine.backend() == "faster-whisper", whisper_engine.backend())

    audio = transcribe.load_audio(clip)
    check("audio decodes with the bundled ffmpeg", len(audio) > 16000 * 5, f"{len(audio) / 16000:.1f}s")

    started = time.time()
    segments = transcribe.transcribe_audio(audio, "room")
    text = " ".join(s["text"] for s in segments).lower()
    check("Whisper transcribes the clip", "country" in text, f"{time.time() - started:.1f}s: {text[:90]}")

    # Live transcriber: stream the clip in 0.1 s frames, like the app does.
    meeting = config.MEETINGS / "2026-01-01_10-00-00_test_in-person"
    meeting.mkdir(parents=True, exist_ok=True)
    (meeting / "session.json").write_text(json.dumps({
        "app": "meeting-recorder-windows", "mode": "room", "project": "Test", "marks": [], "title": "Test meeting",
        "attendees": [], "tracks": ["room"], "startedAt": "2026-01-01T08:00:00Z", "status": "recording"}), encoding="utf-8")
    live = subprocess.Popen([sys.executable, str(REPO / "live.py"), str(meeting), "room"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env={**os.environ, "PYTHONUTF8": "1"})
    pcm = (audio * 32767).clip(-32768, 32767).astype("int16")
    for i in range(0, len(pcm), 1600):
        chunk = pcm[i:i + 1600]
        live.stdin.write(struct.pack("<BI", 0, len(chunk)) + chunk.tobytes())
    live.stdin.close()
    out, err = live.communicate(timeout=900)
    lines = [json.loads(l) for l in out.decode("utf-8").splitlines() if l.strip()]
    spoken = [l for l in lines if "track" in l]
    check("live transcriber writes lines", bool(spoken) and any(l.get("done") for l in lines),
          (spoken[0]["text"][:80] if spoken else err.decode("utf-8", "replace")[-300:]))
    check("live.jsonl for Claude's connector", (meeting / "live.jsonl").exists())

    # Full pipeline on a finished meeting folder.
    import wave

    with wave.open(str(meeting / "room.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm.tobytes())
    meta = json.loads((meeting / "session.json").read_text(encoding="utf-8"))
    meta.update({"status": "done", "endedAt": "2026-01-01T08:00:11Z"})
    (meeting / "session.json").write_text(json.dumps(meta), encoding="utf-8")
    run = subprocess.run([sys.executable, str(REPO / "transcribe.py"), str(meeting)], capture_output=True,
                         env={**os.environ, "PYTHONUTF8": "1"}, timeout=900)
    check("transcribe.py writes the transcript", (meeting / "transcript.md").exists() and (meeting / "transcript.html").exists(),
          run.stderr.decode("utf-8", "replace")[-300:] if run.returncode else "")
    check("the page has the player and the mixed audio", (meeting / "audio.m4a").exists()
          and "<audio" in (meeting / "transcript.html").read_text(encoding="utf-8"))

    clip_run = subprocess.run([sys.executable, str(REPO / "clip.py"), str(meeting), "5"], capture_output=True, timeout=120)
    check("share-a-moment clip", clip_run.returncode == 0 and b".m4a" in clip_run.stdout, clip_run.stderr.decode("utf-8", "replace")[-200:])

    stats = subprocess.run([sys.executable, str(REPO / "insights.py"), "stats", str(meeting)], capture_output=True, timeout=60)
    check("talk shares", stats.returncode == 0, stats.stdout.decode("utf-8", "replace")[:120])

    archive = subprocess.run([sys.executable, str(REPO / "archive.py")], capture_output=True, timeout=120)
    check("archive page", archive.returncode == 0 and (config.MEETINGS / "index.html").exists())

    # Claude's connector speaks MCP over stdin/stdout.
    requests = "\n".join(json.dumps(r) for r in [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_meetings", "arguments": {}}},
    ]) + "\n"
    mcp = subprocess.run([sys.executable, str(REPO / "mcp_server.py")], input=requests.encode("utf-8"),
                         capture_output=True, timeout=60)
    replies = [json.loads(l) for l in mcp.stdout.decode("utf-8").splitlines() if l.strip()]
    listed = json.dumps(replies[-1]) if replies else ""
    check("Claude connector lists the meeting", "zubda" in json.dumps(replies[:1]) and "Test" in listed, listed[:160])

    sys.path.insert(0, str(REPO / "windows"))
    from zubda import audio as zaudio, calls

    check("reads which apps use the mic", isinstance(calls.using_mic(), dict))
    check("lists microphones without crashing", isinstance(zaudio.microphones(), list), str(zaudio.microphones())[:120])

    passed = sum(results)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
