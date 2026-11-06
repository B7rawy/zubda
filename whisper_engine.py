"""One Whisper call for every platform.

Macs with Apple silicon use mlx-whisper (fast on the Mac's GPU). Everything else, Windows
included, uses faster-whisper: on an NVIDIA card when there is one, otherwise on the CPU with
int8 weights. Both give back the same shape, so transcribe.py and live.py don't care which ran:

    {"segments": [{"start", "end", "text", "no_speech_prob", "avg_logprob",
                   "compression_ratio", "words": [{"word", "start", "end"}]}]}
"""
import platform
import sys

APPLE_SILICON = sys.platform == "darwin" and platform.machine() == "arm64"

# faster-whisper's name for the same model the Mac uses (large-v3-turbo, about 1.6 GB).
PORTABLE_MODEL = "large-v3-turbo"

_model = None  # faster-whisper keeps the model in memory between calls (live.py calls often)


def backend():
    return "mlx" if APPLE_SILICON else "faster-whisper"


def _portable_name(model):
    """The Mac setting names an MLX repo; elsewhere use the faster-whisper build of it."""
    if not model or model.startswith("mlx-community/"):
        return PORTABLE_MODEL
    return model


def _load(model):
    global _model
    if _model is None:
        from faster_whisper import WhisperModel

        device, compute = "cpu", "int8"
        try:
            import ctranslate2

            if ctranslate2.get_cuda_device_count() > 0:
                device, compute = "cuda", "float16"
        except Exception:
            pass
        _model = WhisperModel(_portable_name(model), device=device, compute_type=compute)
    return _model


def transcribe(audio, model, language=None, prompt=None, word_timestamps=True):
    """audio: 16 kHz mono float32 numpy array."""
    if APPLE_SILICON:
        import mlx_whisper

        return mlx_whisper.transcribe(
            audio, path_or_hf_repo=model, language=language, condition_on_previous_text=False,
            initial_prompt=prompt, word_timestamps=word_timestamps,
        )

    segments, _info = _load(model).transcribe(
        audio, language=language, condition_on_previous_text=False, initial_prompt=prompt,
        word_timestamps=word_timestamps, vad_filter=False, beam_size=5,
    )
    out = []
    for seg in segments:
        out.append({
            "start": seg.start,
            "end": seg.end,
            "text": seg.text,
            "no_speech_prob": seg.no_speech_prob,
            "avg_logprob": seg.avg_logprob,
            "compression_ratio": seg.compression_ratio,
            "words": [{"word": w.word, "start": w.start, "end": w.end} for w in (seg.words or [])],
        })
    return {"segments": out}
