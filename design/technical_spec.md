This **Technical Architecture Specification** details the back-end infrastructure for **Relay**. It focuses on a microservices-oriented approach where responsibilities are decoupled to ensure the "Operator" logic is distinct yet integrated, and audio processing is flexible.

---

## 1. System Architecture Overview

The system is composed of five primary functional blocks. A key architectural decision is that the **Conversation Manager** acts as the "brain" for the user's session, while the **Agent Manager** acts as the "bridge" to specific LLM implementations.

### Component Map

* **API Gateway:** The entry point for the Front End (Web/iOS). Handles authentication and initial routing.
* **Conversation Manager (CM):** The orchestrator. It manages session state, runs the **Operator** logic, and handles the "Handoff" state.
* **Agent Manager (AM):** The interface for AI agents. It handles the text-based communication with various LLMs and **holds the configuration for agent personalities/voices.**
* **Audio Microservices (STT/TTS):** Pluggable wrappers around speech-to-text and text-to-speech providers.
* **Context Store:** A shared database (Redis/PostgreSQL) for session history and active routing states.

---

## 2. Component Responsibilities

### 2.1 API Gateway

* **Protocol:** Manages WebSockets for real-time audio streaming.
* **STT Integration:** Calls the Speech-to-Text microservice to convert incoming user audio into text packets before passing them to the Conversation Manager.
* **Routing:** Directs the text payload to the CM.

### 2.2 Conversation Manager (The Orchestrator)

* **Operator Logic:** Contains the "System Agent" (Operator) that processes initial intent.
* **Session State:** Tracks which agent is currently "active" in the room.
* **Handoff Execution:** When the Operator triggers a handoff, the CM emits a "Handoff Event" to the front end (to play the sound) and updates the routing table for that Session ID.
* **TTS Orchestration (Return Path):** Once an agent responds with text, the CM calls the TTS service using the specific **Voice Profile** provided by the Agent Manager.

### 2.3 Agent Manager

* **Agent Registry:** Stores configuration for Vanto, Gemini, etc.
* **Voice Profiles:** Maps agents to specific TTS settings (e.g., `Agent: Vanto -> Provider: ElevenLabs, VoiceID: 'Antoni', Stability: 0.5`).
* **LLM Wrapper:** Translates the Relay internal text format to the specific API of the target agent (OpenAI, Google, etc.).

---

## 3. The Data Flow (The "Handoff" Sequence)

1. **User Audio:** "Connect me to Vanto."
2. **API Gateway:** Converts audio to text via **STT Service**. Sends text to **Conversation Manager**.
3. **Conversation Manager:**
* Consults **Operator Logic**.
* Recognizes intent: `ACTION_CONNECT`, `TARGET: Vanto`.
* Fetches Vanto’s metadata from **Agent Manager**.
* Updates Session State: `active_agent = 'vanto'`.


4. **Response Path:**
* CM sends confirmation text: "Connecting you to Vanto."
* CM calls **TTS Service** with **Operator's Voice Profile**.
* CM sends Audio + `HANDOFF_SIGNAL` to **API Gateway**.


5. **Front End:** Plays Operator audio  Plays "Handoff" sound  Switches UI mode to "Vanto."

---

## 4. API & Microservice Interface Designs

### 4.1 Pluggable Audio Wrappers

To avoid vendor lock-in, we use a standardized internal API for audio services:

> **TTS Request Schema:**
> ```json
> {
>   "text": "Hello, I am Vanto.",
>   "voice_config": {
>     "provider": "eleven_labs",
>     "voice_id": "v3_standard_01",
>     "style_parameters": { "pitch": 1.0, "stability": 0.5 }
>   }
> }
> 
> ```
> 
> 

### 4.2 Operator vs. Agent Logic

Within the **Conversation Manager**, the routing logic functions as a state machine:

| State | Input Handler | Output Source |
| --- | --- | --- |
| **INITIAL** | Operator | Operator Voice |
| **ROUTING** | Operator | Operator Voice + Earcon |
| **ACTIVE_SESSION** | Selected Agent | Agent-Specific Voice |

---

## 5. Technical Considerations for Development

* **Concurrency:** Use an asynchronous framework (like FastAPI or Go) for the Conversation Manager to handle multiple simultaneous audio streams without blocking.
* **Latency:** The TTS conversion should be "streamed." The CM should begin sending audio chunks to the Front End as they are generated, rather than waiting for the full sentence to finish.
* **Persistence:** Session context (the transcript and agent states) must be persisted in a document store to allow the "Continue our conversation" functionality.

