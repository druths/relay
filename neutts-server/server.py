"""Lightweight HTTP wrapper around NeuTTS Nano for self-hosted TTS in Relay.

Voices are supplied as (wav, txt) pairs in NEUTTS_VOICES_DIR. The transcript
file is required by NeuTTS — the model conditions on both the reference audio
and its transcript when cloning a voice.

At startup we encode every reference voice once and cache the embedding tensor
on disk so per-request latency reduces to the LM forward pass + codec decode.
"""

from __future__ import annotations

import io
import logging
import os
from pathlib import Path

import numpy as np
import soundfile as sf
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel
from pydub import AudioSegment

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("neutts-server")

VOICES_DIR = Path(os.environ.get("NEUTTS_VOICES_DIR", "/app/voices"))
CACHE_DIR = Path(os.environ.get("NEUTTS_CACHE_DIR", "/app/cache"))
BACKBONE = os.environ.get("NEUTTS_BACKBONE", "neuphonic/neutts-nano-q8-gguf")
CODEC = os.environ.get("NEUTTS_CODEC", "neuphonic/neucodec-onnx-decoder")

CACHE_DIR.mkdir(parents=True, exist_ok=True)


class Voice:
    """A reference voice: audio + transcript + pre-encoded embedding."""

    def __init__(self, voice_id: str, wav_path: Path, txt_path: Path):
        self.id = voice_id
        self.wav_path = wav_path
        self.txt_path = txt_path
        self.transcript = txt_path.read_text(encoding="utf-8").strip()
        self.embedding = None  # populated by encode()

    def encode(self, model) -> None:
        cache_path = CACHE_DIR / f"{self.id}.npy"
        if cache_path.exists():
            self.embedding = np.load(cache_path)
            logger.info("Voice %s: loaded cached embedding", self.id)
            return
        logger.info("Voice %s: encoding reference (%s)", self.id, self.wav_path.name)
        codes = model.encode_reference(str(self.wav_path))
        # `codes` is a torch tensor or ndarray depending on backend; store as ndarray.
        arr = codes.detach().cpu().numpy() if hasattr(codes, "detach") else np.asarray(codes)
        np.save(cache_path, arr)
        self.embedding = arr


_model = None
_voices: dict[str, Voice] = {}


def _load_voices() -> dict[str, Voice]:
    """Discover (wav, txt) pairs in VOICES_DIR. Each pair becomes a voice
    whose id is the filename stem."""
    voices: dict[str, Voice] = {}
    if not VOICES_DIR.exists():
        logger.warning("Voices dir %s does not exist — server will start empty", VOICES_DIR)
        return voices
    for wav in VOICES_DIR.glob("*.wav"):
        txt = wav.with_suffix(".txt")
        if not txt.exists():
            logger.warning("Voice %s: missing transcript %s — skipping", wav.stem, txt.name)
            continue
        voices[wav.stem] = Voice(wav.stem, wav, txt)
    return voices


def _load_model():
    """Import the neutts package lazily — keeps startup logs cleaner if the
    package is missing in dev."""
    from neutts import NeuTTS
    return NeuTTS(backbone_repo=BACKBONE, codec_repo=CODEC)


app = FastAPI(title="NeuTTS Server", version="0.1.0")


@app.on_event("startup")
async def startup() -> None:
    global _model, _voices
    logger.info("Loading model: backbone=%s codec=%s", BACKBONE, CODEC)
    _model = _load_model()
    logger.info("Discovering voices in %s", VOICES_DIR)
    _voices = _load_voices()
    for voice in _voices.values():
        voice.encode(_model)
    logger.info("Ready: %d voices loaded", len(_voices))


class SynthesizeRequest(BaseModel):
    text: str
    voice_id: str
    speed: float | None = 1.0
    format: str | None = "mp3"  # mp3 or wav


@app.get("/health")
async def health() -> dict:
    return {
        "status": "ok" if _model is not None else "loading",
        "voices": list(_voices.keys()),
    }


@app.get("/voices")
async def list_voices() -> list[dict]:
    out = []
    for v in _voices.values():
        try:
            info = sf.info(str(v.wav_path))
            duration = info.frames / info.samplerate
        except Exception:
            duration = 0.0
        out.append({
            "id": v.id,
            "name": v.id.replace("_", " ").title(),
            "description": v.transcript[:80] + ("…" if len(v.transcript) > 80 else ""),
            "duration_s": round(duration, 2),
        })
    return out


@app.post("/synthesize")
async def synthesize(req: SynthesizeRequest) -> Response:
    if _model is None:
        raise HTTPException(status_code=503, detail="Model still loading")
    voice = _voices.get(req.voice_id)
    if voice is None:
        raise HTTPException(status_code=404, detail=f"Unknown voice: {req.voice_id}")
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="Empty text")

    try:
        audio = _model.infer(
            text=req.text,
            ref_codes=voice.embedding,
            ref_text=voice.transcript,
        )
    except Exception as e:
        logger.exception("Inference failed")
        raise HTTPException(status_code=500, detail=f"Inference failed: {e}")

    # `audio` is a 1-D float32 array at 24 kHz from NeuTTS' codec.
    audio_np = audio.detach().cpu().numpy() if hasattr(audio, "detach") else np.asarray(audio)
    audio_np = np.clip(audio_np, -1.0, 1.0)
    sample_rate = 24000

    # Encode to bytes. WAV is essentially free; MP3 needs ffmpeg via pydub.
    if (req.format or "mp3").lower() == "wav":
        buf = io.BytesIO()
        sf.write(buf, audio_np, sample_rate, format="WAV")
        return Response(content=buf.getvalue(), media_type="audio/wav")

    pcm16 = (audio_np * 32767.0).astype(np.int16).tobytes()
    seg = AudioSegment(
        data=pcm16, sample_width=2, frame_rate=sample_rate, channels=1
    )
    out_buf = io.BytesIO()
    seg.export(out_buf, format="mp3", bitrate="64k")
    return Response(content=out_buf.getvalue(), media_type="audio/mpeg")
