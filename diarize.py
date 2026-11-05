"""Tell voices apart on one track, entirely on this computer (sherpa-onnx, no account, no upload).

Used for the tracks that mix several people: "others" in an online call and "room" in person.
Each transcript line is given the speaker whose voice covers most of it, numbered in the order
people first speak. It only knows voices, not names; the report infers names from context.
"""
from pathlib import Path

MODELS = Path.home() / ".local" / "share" / "meeting-recorder" / "models"
SEGMENTATION = MODELS / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx"
EMBEDDING = MODELS / "embedding.onnx"
# Lower splits one person into two more often; higher merges different people more often.
# 0.8 kept a 3-voice test exact; 0.5 split the same voices into five.
THRESHOLD = 0.8
# Voices with less than this share of the talking are treated as a split of a bigger voice.
MINOR_SHARE = 0.08

_engine = None


def available():
    try:
        import sherpa_onnx  # noqa: F401
    except ImportError:
        return False
    return SEGMENTATION.exists() and EMBEDDING.exists()


def _diarizer():
    global _engine
    if _engine is None:
        import sherpa_onnx

        config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
            segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(SEGMENTATION))
            ),
            embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(EMBEDDING)),
            clustering=sherpa_onnx.FastClusteringConfig(num_clusters=-1, threshold=THRESHOLD),
            min_duration_on=0.3,
            min_duration_off=0.5,
        )
        _engine = sherpa_onnx.OfflineSpeakerDiarization(config)
    return _engine


def _merge_minor_voices(segments):
    """Give lines of a rarely heard voice to the nearest line of a main voice."""
    talk = {}
    for s in segments:
        if "voice" in s:
            talk[s["voice"]] = talk.get(s["voice"], 0) + s["end"] - s["start"]
    total = sum(talk.values()) or 1
    major = {v for v, t in talk.items() if t / total >= MINOR_SHARE}
    if not major:
        return
    voiced = [s for s in segments if "voice" in s]
    for i, s in enumerate(voiced):
        if s["voice"] in major:
            continue
        nearest = min(
            (o for o in voiced if o["voice"] in major),
            key=lambda o: abs(o["start"] - s["start"]),
        )
        s["voice"] = nearest["voice"]


def label(segments, audio, base_label):
    """Rewrite each segment's speaker as «<base_label> 1», «… 2»… when more than one voice is heard."""
    if not segments or not available() or len(audio) < 16000 * 2:
        return segments
    turns = [(t.start, t.end, t.speaker) for t in _diarizer().process(audio).sort_by_start_time()]
    if len({speaker for *_, speaker in turns}) < 2:
        return segments

    order = {}
    for segment in segments:
        overlap = {}
        for start, end, speaker in turns:
            shared = min(segment["end"], end) - max(segment["start"], start)
            if shared > 0:
                overlap[speaker] = overlap.get(speaker, 0) + shared
        if overlap:
            speaker = max(overlap, key=overlap.get)
            order.setdefault(speaker, len(order) + 1)
            segment["voice"] = order[speaker]

    _merge_minor_voices(segments)
    order = {}
    for segment in segments:
        if "voice" in segment:
            segment["voice"] = order.setdefault(segment["voice"], len(order) + 1)
    if len(order) < 2:
        return segments
    for segment in segments:
        if "voice" in segment:
            segment["speaker"] = f"{base_label} {segment['voice']}"
    return segments
