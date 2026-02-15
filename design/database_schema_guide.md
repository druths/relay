To support the **Relay**, the database needs to handle three distinct areas: the identity and configuration of **Agents**, the ongoing state of **Conversations**, and the detailed **Logs** for context retrieval.

Since we want to prioritize performance and flexibility, a relational schema (PostgreSQL) is recommended for configuration, while the context history can be stored in a JSONB format to accommodate varying LLM response structures.

---

## 1. Agent Registry (`agents`)

This table defines who the agents are and how they sound.

| Column | Type | Description |
| --- | --- | --- |
| `agent_id` | UUID (PK) | Unique identifier (e.g., for Vanto, Gemini). |
| `name` | String | Display name. |
| `persona_prompt` | Text | The system instructions sent to the LLM. |
| `tts_provider` | String | e.g., "eleven_labs", "google_cloud". |
| `voice_id` | String | The specific voice model identifier. |
| `voice_settings` | JSONB | Stability, similarity boost, pitch, etc. |

---

## 2. Conversation Sessions (`sessions`)

This table manages the "Operator's" world—tracking who is currently talking to whom.

| Column | Type | Description |
| --- | --- | --- |
| `session_id` | UUID (PK) | The unique ID for a specific user interaction. |
| `user_id` | UUID | Reference to the user. |
| `active_agent_id` | UUID (FK) | References `agents.agent_id`. Null if talking to Operator. |
| `status` | Enum | `active`, `paused`, `archived`. |
| `created_at` | Timestamp | When the session started. |
| `last_active` | Timestamp | Used for the Operator to "resume" recent contexts. |

---

## 3. Conversation Context (`messages`)

This table stores the actual transcript. It is indexed by `session_id` for rapid retrieval.

| Column | Type | Description |
| --- | --- | --- |
| `message_id` | UUID (PK) | Unique ID for the message. |
| `session_id` | UUID (FK) | Links to the session. |
| `role` | Enum | `user`, `operator`, or `agent`. |
| `text_content` | Text | The raw text (from STT or LLM). |
| `audio_ref` | String | (Optional) URL to the stored audio file in S3/Blob storage. |
| `metadata` | JSONB | Token count, latency metrics, or tool calls. |

---

## 4. Logical Relationships

* **The Operator's View:** When you say "Connect me to Vanto," the **Conversation Manager** queries the `sessions` table filtered by `user_id` and sorted by `last_active`. It looks at the `messages` associated with those IDs to provide "hints" to the LLM about what was previously discussed.
* **Dynamic Configuration:** When the CM prepares the response, it joins `sessions` with `agents` to grab the `voice_id` and `tts_provider`. This ensures that if you change Vanto's voice via the UI, the very next response uses the new configuration.

---

## 5. Performance Note: The "Context Cache"

For high performance, all the messages of an active session should be mirrored in **Redis**.

* **Why?** When the User speaks, we don't want to wait for a full SQL join to get the context for the Agent Manager.
* **Flow:** CM hits Redis first  provides context to Agent  writes the new message to Postgres asynchronously.


