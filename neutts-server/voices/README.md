# Voices

Drop reference voices in here as `(name.wav, name.txt)` pairs.

- `name.wav` — mono WAV, 16–44 kHz, 3–15 seconds, clean audio, minimal background noise.
- `name.txt` — verbatim transcript of `name.wav` in the language being spoken.

The filename stem becomes the voice id (e.g. `alice.wav` → voice id `alice`).
The server will pre-encode every voice on startup and cache the embedding under
`/app/cache`, so the upfront cost is paid once.

The server starts with no voices if this directory is empty — `/voices` will
return `[]` and `/synthesize` will 404 until you add at least one pair.
