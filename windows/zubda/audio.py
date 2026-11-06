"""Recording the call and the mic on Windows, through WASAPI (PyAudioWPatch).

Two sources, each written to its own 16 kHz mono track like the Mac app:
- "others": what the computer plays (WASAPI loopback of the default speakers), i.e. everyone
  on a Zoom, Meet, Teams or WhatsApp call;
- "me" / "room": the microphone.

WASAPI loopback delivers nothing while the computer is silent, so a track is kept in step with
the wall clock: when a source falls behind by more than a moment, silence is written in its place.
That keeps the two tracks aligned for the transcript and the player.
"""
import threading
import time
import wave

import numpy as np

RATE = 16000
TICK = 0.1  # seconds of audio per chunk handed on


def _to_mono_16k(raw, channels, rate):
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    if rate != RATE and len(samples):
        count = int(round(len(samples) * RATE / rate))
        samples = np.interp(np.linspace(0, len(samples) - 1, count), np.arange(len(samples)), samples)
    return np.clip(samples, -32768, 32767).astype(np.int16)


class Track:
    """One source → <folder>/<name>.wav, with a level for the meter and samples for live text."""

    def __init__(self, name, path, on_samples=None):
        self.name = name
        self.path = path
        self.on_samples = on_samples
        self.level = 0.0
        self.written = 0  # samples at 16 kHz
        self._pending = []
        self._lock = threading.Lock()
        self._wav = wave.open(str(path), "wb")
        self._wav.setnchannels(1)
        self._wav.setsampwidth(2)
        self._wav.setframerate(RATE)
        self.paused = False

    def feed(self, samples):
        with self._lock:
            self._pending.append(samples)

    def flush(self, target, pad_after):
        """Write what arrived; pad with silence if the source went quiet (loopback)."""
        with self._lock:
            chunks, self._pending = self._pending, []
        data = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.int16)
        if self.paused:
            data = np.zeros(len(data), dtype=np.int16)
        missing = target - (self.written + len(data))
        if not chunks and missing > pad_after:
            data = np.zeros(missing, dtype=np.int16)
        if len(data):
            self._wav.writeframes(data.tobytes())
            self.written += len(data)
            self.level = float(np.sqrt(np.mean((data.astype(np.float32) / 32768) ** 2))) if len(data) else 0.0
            if self.on_samples:
                self.on_samples(self.name, data)
        else:
            self.level *= 0.6

    def close(self):
        self._wav.close()


class Capture:
    """Opens the devices, runs one reader per source and a clock that writes every TICK."""

    def __init__(self, tracks, mic_name=None):
        import pyaudiowpatch as pyaudio

        self.pa = pyaudio.PyAudio()
        self.pyaudio = pyaudio
        self.tracks = tracks  # dict: "loopback"/"mic" -> Track
        self.mic_name = mic_name
        self.streams = []
        self.started = None
        self._stop = threading.Event()

    def _device(self, kind):
        pa = self.pa
        if kind == "loopback":
            wasapi = pa.get_host_api_info_by_type(self.pyaudio.paWASAPI)
            speakers = pa.get_device_info_by_index(wasapi["defaultOutputDevice"])
            if not speakers.get("isLoopbackDevice"):
                for loop in pa.get_loopback_device_info_generator():
                    if speakers["name"] in loop["name"]:
                        return loop
            return pa.get_default_wasapi_loopback()
        if self.mic_name:
            for i in range(pa.get_device_count()):
                info = pa.get_device_info_by_index(i)
                if info["name"] == self.mic_name and info["maxInputChannels"] > 0 and not info.get("isLoopbackDevice"):
                    return info
        return pa.get_default_input_device_info()

    def start(self):
        for kind, track in self.tracks.items():
            device = self._device(kind)
            channels = max(1, min(2, int(device["maxInputChannels"])))
            rate = int(device["defaultSampleRate"])

            def callback(data, frames, info, status, track=track, channels=channels, rate=rate):
                track.feed(_to_mono_16k(data, channels, rate))
                return (None, self.pyaudio.paContinue)

            stream = self.pa.open(format=self.pyaudio.paInt16, channels=channels, rate=rate, input=True,
                                  input_device_index=device["index"], frames_per_buffer=int(rate * TICK),
                                  stream_callback=callback)
            stream.start_stream()
            self.streams.append(stream)
        self.started = time.monotonic()
        threading.Thread(target=self._clock, daemon=True).start()

    def _clock(self):
        while not self._stop.wait(TICK):
            target = int((time.monotonic() - self.started) * RATE)
            for kind, track in self.tracks.items():
                # The mic always delivers; only the loopback needs silence filled in.
                track.flush(target, pad_after=int(RATE * 0.3) if kind == "loopback" else 10 ** 9)

    def stop(self):
        self._stop.set()
        for stream in self.streams:
            try:
                stream.stop_stream()
                stream.close()
            except Exception:
                pass
        target = int((time.monotonic() - self.started) * RATE) if self.started else 0
        for track in self.tracks.values():
            track.flush(target, pad_after=int(RATE * 0.3))
            track.close()
        self.pa.terminate()


def microphones():
    """Names of the input devices, for Settings."""
    try:
        import pyaudiowpatch as pyaudio
    except ImportError:
        return []
    pa = pyaudio.PyAudio()
    try:
        wasapi = pa.get_host_api_info_by_type(pyaudio.paWASAPI)["index"]
        names = []
        for i in range(pa.get_device_count()):
            info = pa.get_device_info_by_index(i)
            if info["hostApi"] == wasapi and info["maxInputChannels"] > 0 and not info.get("isLoopbackDevice"):
                names.append(info["name"])
        return names
    finally:
        pa.terminate()
