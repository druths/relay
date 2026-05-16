"""Google Cloud Text-to-Speech provider.

Targets the Chirp 3 HD voice line by default — Google's newest conversational
TTS, designed for low first-byte latency and natural turn-taking. Falls back
to whatever voice id the caller passes (so other tiers like Neural2 work too
if a user picks one).

Auth: API key only (passed as `key=` query parameter). Service-account JSON
isn't supported in this v1 — self-hosted deployments overwhelmingly choose
the API-key path, and it's a single env var to set.
"""

from __future__ import annotations

import base64
import logging

import httpx

from app.config import settings
from app.services.tts.base import TTSProvider

logger = logging.getLogger(__name__)

_clients: dict[str, httpx.AsyncClient] = {}

GOOGLE_BASE_URL = "https://texttospeech.googleapis.com/v1"


def _get_client(api_key: str | None = None) -> httpx.AsyncClient | None:
    effective_key = api_key or getattr(settings, "google_tts_api_key", "")
    if not effective_key:
        return None
    if effective_key not in _clients:
        _clients[effective_key] = httpx.AsyncClient(
            base_url=GOOGLE_BASE_URL,
            timeout=60.0,
        )
    return _clients[effective_key]


def _key_for(api_key: str | None) -> str | None:
    return api_key or getattr(settings, "google_tts_api_key", "") or None


def _language_code_from_voice(voice_id: str) -> str:
    """Voice ids look like `en-US-Chirp3-HD-Charon` — the languageCode field
    that Google's synthesize endpoint requires is the leading `en-US`."""
    parts = voice_id.split("-")
    if len(parts) >= 2:
        return f"{parts[0]}-{parts[1]}"
    return "en-US"


class GoogleTTSProvider(TTSProvider):
    """Default voice tier exposed in the picker. Other tiers (Neural2, etc.)
    can be selected via the voice list — the synthesize endpoint accepts
    any voice id."""
    DEFAULT_VOICE = "en-US-Chirp3-HD-Charon"

    def __init__(self, api_key: str | None = None):
        self._api_key = api_key

    @classmethod
    def available_voices(cls) -> list[dict]:
        # Voices are dynamic — use fetch_voices() with an API key.
        return []

    @classmethod
    async def fetch_voices(cls, api_key: str) -> list[dict]:
        """Fetch the full voice catalogue and prefer Chirp 3 HD voices first.
        Other tiers (Neural2, Studio, Journey, WaveNet, Standard) follow,
        sorted alphabetically inside each group so the picker stays stable."""
        key = _key_for(api_key)
        if key is None:
            return []
        client = _get_client(api_key)
        if client is None:
            return []
        try:
            resp = await client.get("/voices", params={"key": key})
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            logger.warning("Google fetch_voices failed: %s", exc)
            return []

        def tier_rank(name: str) -> int:
            # Lower rank = listed first
            if "Chirp3-HD" in name: return 0
            if "Journey" in name:   return 1
            if "Neural2" in name:   return 2
            if "Wavenet" in name:   return 3
            if "Studio" in name:    return 4
            if "Standard" in name:  return 5
            return 6

        def tier_label(name: str) -> str:
            if "Chirp3-HD" in name: return "Chirp 3 HD"
            if "Journey" in name:   return "Journey"
            if "Neural2" in name:   return "Neural2"
            if "Wavenet" in name:   return "WaveNet"
            if "Studio" in name:    return "Studio"
            if "Standard" in name:  return "Standard"
            return "Other"

        out: list[dict] = []
        for v in data.get("voices", []):
            name = v.get("name") or ""
            if not name:
                continue
            langs = v.get("languageCodes", [])
            lang = langs[0] if langs else ""
            gender = v.get("ssmlGender", "").lower()
            tier = tier_label(name)
            # Display name: drop the language prefix so the dropdown is readable
            display = name.split("-", 2)[-1].replace("Chirp3-HD-", "").replace("Neural2-", "")
            description = " · ".join(
                p for p in [tier, lang, gender if gender and gender != "ssml_voice_gender_unspecified" else None]
                if p
            )
            out.append({
                "id": name,
                "name": display,
                "description": description,
                "_rank": tier_rank(name),
            })
        out.sort(key=lambda v: (v["_rank"], v["id"]))
        for v in out:
            v.pop("_rank", None)
        return out

    async def synthesize(self, text: str, voice_id: str, voice_settings: dict) -> bytes:
        key = _key_for(self._api_key)
        if key is None:
            raise RuntimeError("Google TTS API key not configured")
        client = _get_client(self._api_key)
        assert client is not None

        # Voice id can be left blank in the agent config; fall back to default.
        chosen_voice = voice_id or self.DEFAULT_VOICE
        language_code = voice_settings.get("language_code") or _language_code_from_voice(chosen_voice)
        # Speed range per Google: 0.25–4.0. Default 1.0.
        speed = float(voice_settings.get("speed", 1.0))
        pitch = float(voice_settings.get("pitch", 0.0))

        payload = {
            "input": {"text": text},
            "voice": {"languageCode": language_code, "name": chosen_voice},
            "audioConfig": {
                "audioEncoding": "MP3",
                "speakingRate": speed,
                "pitch": pitch,
            },
        }

        logger.info(
            "Google TTS: voice=%s, lang=%s, speed=%.2f, %d chars",
            chosen_voice, language_code, speed, len(text),
        )

        resp = await client.post("/text:synthesize", params={"key": key}, json=payload)
        if resp.status_code != 200:
            body = resp.text[:500]
            logger.error(
                "Google TTS error: status=%d, voice=%s, chars=%d, body=%s",
                resp.status_code, chosen_voice, len(text), body,
            )
            resp.raise_for_status()
        data = resp.json()
        audio_b64 = data.get("audioContent")
        if not audio_b64:
            raise RuntimeError(f"Google TTS response missing audioContent: {data}")
        audio = base64.b64decode(audio_b64)
        logger.info("Google TTS: decoded %d bytes for %d chars", len(audio), len(text))
        return audio
