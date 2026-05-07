FROM python:3.11-slim

# Stable system deps — kept on its own line so editing it doesn't bust the
# (very expensive) pip-install layer cache below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        build-essential \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
# Pre-install llama-cpp-python from a pre-built CPU wheel to avoid
# compiling from source (which requires 8GB+ RAM and many minutes).
RUN pip install --no-cache-dir \
    --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu \
    "llama-cpp-python==0.3.19" && \
    pip install --no-cache-dir -r requirements.txt

# espeak-ng is required by the `phonemizer` package neutts uses for
# grapheme→phoneme conversion. Installed separately to avoid invalidating
# the pip layer when this set of packages changes.
RUN apt-get update && apt-get install -y --no-install-recommends \
        espeak-ng \
    && rm -rf /var/lib/apt/lists/*

# Pre-download the Nano GGUF backbone + full PyTorch codec so first-request
# latency isn't dominated by a HuggingFace download. The full codec (not the
# -onnx-decoder variant) is required because we encode reference audio at
# startup, which the decoder-only ONNX build doesn't support.
RUN python -c "from huggingface_hub import snapshot_download; \
    snapshot_download('neuphonic/neutts-nano-q8-gguf'); \
    snapshot_download('neuphonic/neucodec')"

COPY server.py .
COPY voices ./voices

ENV NEUTTS_BACKBONE=neuphonic/neutts-nano-q8-gguf
ENV NEUTTS_CODEC=neuphonic/neucodec
ENV NEUTTS_VOICES_DIR=/app/voices
ENV NEUTTS_CACHE_DIR=/app/cache
ENV PORT=8000

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost:8000/health || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]
