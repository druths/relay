This document provides some directional details around the API allowing communication between the **Front End (Web/iOS)** and the **API Gateway**, as well as the internal handoff between the **Conversation Manager** and **Agent Manager**.

Crucially, these are directional guides, so the final API may look quite different than this as implementation decisions are made.

Given the real-time nature of voice, we will utilize a **WebSocket** connection for the primary conversation and **REST** for configuration and session history.

---

## 1. Real-Time Conversation (WebSocket)

**Endpoint:** `wss://api.relay.ai/v1/conversation/{session_id}`

The WebSocket handles a multiplexed stream of audio, text, and control signals.

### 1.1 Client-to-Server (Upstream)

Sent by the Front End when the user is speaking.

* **Audio Chunk:** Binary data (PCM/Opus) for STT processing.
* **Control Event:**
```json
{
  "type": "interrupt",
  "timestamp": "2026-02-12T09:05:00Z",
  "payload": { "reason": "user_started_speaking" }
}

```



### 1.2 Server-to-Client (Downstream)

Sent by the API Gateway/Conversation Manager.

* **Audio Chunk:** Binary audio data (TTS output).
* **State Change Event:**
```json
{
  "type": "state_update",
  "payload": {
    "active_speaker": "operator", // or "vanto", "gemini"
    "status": "processing",
    "session_id": "abc-123"
  }
}

```


* **Handoff Event:**
```json
{
  "type": "handoff",
  "payload": {
    "from": "operator",
    "to": "vanto",
    "play_earcon": true
  }
}

```



---

## 2. Agent Management (REST)

Used by the Front End to configure the "Voice Styles" and personality parameters.

### 2.1 Update Agent Voice Configuration

**Endpoint:** `PATCH /v1/agents/{agent_id}/config`

```json
{
  "voice_settings": {
    "provider_id": "eleven_labs",
    "voice_identity": "antoni_premium",
    "parameters": {
      "stability": 0.75,
      "similarity_boost": 0.5,
      "style": 0.2
    }
  },
  "persona_prompt": "You are Vanto, a helpful and witty strategist."
}

```

---

## 3. Internal Service Contracts (gRPC or Internal REST)

### 3.1 Conversation Manager  Agent Manager

When the CM needs a text response from a specific agent.
**Endpoint:** `POST /internal/agent/process`

```json
{
  "agent_id": "vanto",
  "session_id": "abc-123",
  "text_input": "What is our current project status?",
  "context_window": [ ...previous messages... ]
}

```

**Response:**

```json
{
  "text_response": "We are currently finalizing the API contract.",
  "metadata": { "usage_tokens": 45 }
}

```

### 3.2 Conversation Manager  TTS Service

The CM triggers this immediately after receiving the text above.
**Endpoint:** `POST /internal/tts/synthesize`

```json
{
  "text": "We are currently finalizing the API contract.",
  "voice_profile": {
    "provider": "eleven_labs",
    "voice_id": "antoni_premium"
  },
  "stream": true
}

```

---

## 4. Session History & Operator Logic

**Endpoint:** `GET /v1/sessions`
Returns a list of recent contexts the Operator can "resume."

**Endpoint:** `POST /v1/sessions/resume`

```json
{
  "session_id": "abc-123",
  "intent_hint": "Continue conversation with Vanto"
}

```

---

## 5. Error Handling & Latency Marks

To ensure "performance" as requested, every response includes a latency object:

```json
"latency_metrics": {
  "stt_ms": 120,
  "llm_ms": 450,
  "tts_first_byte_ms": 80,
  "total_e2e_ms": 650
}

```

> **Note:** For the web-first version, we'll use standard **Web Audio API** on the front end to handle the binary stream and ensure smooth playback between the Operator's voice and the Agent's voice.

