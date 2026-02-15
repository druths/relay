This functional specification outlines **Relay**, a unified AI orchestrator designed to manage multiple specialized agents (like OpenClaw agents, Gemini, or Claude) through a seamless, voice-first interface. The core of the experience centers on a centralized "Operator" that manages routing and navigating session by agent, intent, and context.

---

## 1. Executive Summary

**Relay** is a conversational platform that acts as a single point of entry for a user’s ecosystem of AI agents. It eliminates the friction of switching between different AI interfaces by providing a central "Operator" capable of understanding intent, managing long-term session context, and handing off interactions to specific agents with high-fidelity audio feedback.

---

## 2. Core User Experience (UX) Principles

* **Voice-First, Hands-Free:** Designed for high-performance audio interactions where text is a secondary modality for conversation and review.
* **The "Concierge" Pattern:** Users never talk to "the system"; they talk to a personified **Operator** or a specific **Agent**.
* **Seamless Continuity:** Sessions aren't just logs; they are live contexts the Operator can recall and resume instantly.
* **Low Latency & High Feedback:** Use of audio cues (earcons) to signify state changes (e.g., agent handoffs) to maintain user confidence without verbose speech.

---

## 3. Key User Workflows

### 3.1 The "Front Door" (Initial Entry)

* **Trigger:** User opens the Relay interface or activates the audio stream.
* **Operator Greeting:** The Relay Operator initiates the conversation: *"Hello, Operator here. How can I help you today?"*
* **User Intent:** The user provides a "hint" regarding who they want to talk to or what they want to achieve.
* *Direct Command:* "Connect me to Vanto."
* *Contextual Resume:* "I'd like to continue that conversation I had with Vanto earlier."
* *Discovery:* "Who can help me with my schedule?"



### 3.2 Dynamic Agent Handoff

* **Identification:** The Operator identifies the target agent and the relevant past session (if applicable).
* **Confirmation:** The Operator confirms the routing: *"I've found your last session with Vanto. Connecting you now."*
* **The Handoff Cue:** A distinct, non-verbal **audio tone** plays. This signal is crucial—it tells the user the Operator has stepped back and the Agent (e.g., Vanto) is now listening.
* **Agent Entry:** The selected Agent joins the stream with its specific configured voice and personality: *"Hi again, I'm ready. We were just discussing..."*

### 3.3 Context Switching & Session Management

* **Interruption:** While talking to Agent A, the user can ask to switch: "Relay, hold on, I need to check something with Gemini."
* **State Preservation:** The Conversation Manager pauses Agent A’s session, preserving the state, and brings the Operator back to facilitate the move to Agent B.
* **Memory Retrieval:** Users can ask the Operator for a summary of active sessions: "What was I working on with Vanto this morning?"

---

## 4. Functional Capabilities

| Feature | Description |
| --- | --- |
| **Operator Routing** | A dedicated logic layer within the Conversation Manager that interprets initial user input to select the correct Agent. |
| **Session Persistence** | Ability to "pause" a conversation and resume it days later with full context of the previous exchange. |
| **Multi-Agent Personalities** | Support for distinct voices, tones, and "styles" (via TTS microservice) for each individual agent. |
| **Audio Signalling** | Implementation of "Earcons" (functional sounds) to communicate system status (Listening, Processing, Handoff) without interrupting the flow of speech. |
| **Pluggable Audio** | Custom microservice wrappers for STT and TTS allow the back end to swap providers (Google, OpenAI, ElevenLabs) without changing the core business logic. |

---

## 5. User Interface (Agnostic)

### 5.1 The "Lean" Interface (Initial Web/Mobile)

* **Status Indicator:** A central visual element (e.g., an orb or waveform) that changes color or animation style based on who is speaking (Operator vs. Agent).
* **Conversation Log:** A scannable text transcript of the current or past sessions for visual confirmation.
* **Text conversation interface:** A text mode whereby the user can enter a session and conduct a text session with the agent.
* **Agent Selector:** A manual override to switch agents if voice routing is not preferred.
* **Voice Settings:** A configuration panel to adjust the "Voice Style" and "Speed" for each individual agent.

