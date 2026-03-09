# Relay Project Context

## Overview

Relay is a voice/chat AI client platform. It consists of:
- **Backend**: Python FastAPI service running in Docker
- **iOS Client**: SwiftUI app ("Relay") with a WidgetKit extension
- **Web/Other Clients**: Exist but not detailed here

The backend acts as a relay (hence the name) between clients and AI agents. It supports both text chat and live voice mode via WebSocket.

---

## Architecture

### Backend (`backend/`)

- **Framework**: FastAPI (Python), running in Docker container `hub-backend-1`
- **WebSocket**: Clients connect via WebSocket for real-time events
- **Agents**: Configurable AI agents, each with an LLM provider, prompt, tools, etc.
- **Operator**: A special built-in agent (the "lobby" agent) that greets users and routes them to other agents
- **STT**: Speech-to-text, supports ElevenLabs Scribe (`backend/app/services/stt/elevenlabs.py`)
  - `tag_audio_events` set to `"false"` to suppress annotations like "(mysterious music)"
- **TTS**: Text-to-speech via ElevenLabs
- **Sessions**: Users can enter/leave agent sessions. The operator handles the lobby.
- **Restart**: `docker restart hub-backend-1` to apply backend changes

### iOS Client (`ios-client/`)

- **Build system**: XcodeGen — edit `project.yml`, then run `xcodegen generate` to regenerate `.xcodeproj`
- **Targets**:
  - `Relay` — main app, bundle ID `io.titanforge.relay`
  - `RelayWidgetExtension` — WidgetKit extension, bundle ID `io.titanforge.relay.widget`
- **Swift version**: 6.0
- **Deployment target**: iOS 17.0
- **URL scheme**: `relay://` registered in main app Info.plist
- **ATS**: `NSAllowsArbitraryLoads: true` (needed for non-localhost HTTP to backend)
- **Background modes**: `audio`
- **Live Activities**: `NSSupportsLiveActivities: true`

---

## Key iOS Files

### App Entry Point
**`Relay/RelayApp.swift`**
- Configures AVAudioSession on init (`.playback` mode)
- Handles deep links via `.onOpenURL`:
  - `relay://toggle-mute` → posts `.relayToggleMute` notification
  - `relay://exit-live` → posts `.relayExitLive` notification
  - `relay://live` → posts `.relayEnterLive` notification (enters live mode)

### View Model
**`Relay/ViewModels/RelayViewModel.swift`**
- `@Observable` class — the central state for the app
- Key state: `connected`, `isLiveMode`, `agents`, `activeSessionId`, `activeAgentName`, `lobbyMessages`, `sessionMessages`, `sessions`, `status`, `activeSpeaker`
- `connect()` / `disconnect()` — WebSocket lifecycle
- `enterLiveMode()` / `exitLiveMode()` — live voice mode
- `toggleMute()` — microphone mute
- `sendMessage()` — sends text over WebSocket
- `leaveSession()` — returns to lobby
- `resumeSession()` — resumes a past session
- `fetchSessions()` — loads session history
- `refreshAgents()` — reloads agent list
- Live Activity management: `startLiveActivity()`, `updateLiveActivity()`, `endLiveActivity()`
- **Session handoff**: In live mode, `sessionEntered` event waits for operator audio to finish (`await audio.player.waitUntilFinished()`) before swapping session UI, preventing audio clipping

### Main View
**`Relay/Views/RelayView.swift`**
- `VStack`: header → AgentSelector (lobby only) → ConversationLog → InputBar
- Header shows `relay.activeAgentName ?? "Operator"` with a StatusOrb
- AgentSelector shown only when `connected && activeSessionId == nil` (lobby)
- Separator line (`relayBorder`) below AgentSelector
- `scenePhase` observation: reconnects WebSocket on foreground return
- Notification receivers: `.relayToggleMute`, `.relayExitLive`, `.relayEnterLive`
- `.relayEnterLive`: connects if needed, then calls `relay.enterLiveMode()`

### Conversation Log
**`Relay/Views/Components/ConversationLog.swift`**
- Uses `VStack` (NOT `LazyVStack`) — critical, see Bug History below
- NO `.defaultScrollAnchor(.bottom)` — also critical
- `ScrollViewReader` with `.scrollTo(last.id, anchor: .bottom)` on `messages.count` change

### Message Bubble
**`Relay/Views/Components/MessageBubble.swift`**
- No role labels ("You" / "Operator" / "Agent" removed — considered obvious)
- Uses `MarkdownText` for rendering
- Streaming cursor: blinking green `Rectangle` (2×14pt) when `message.isStreaming`

### Markdown Renderer
**`Relay/Views/Components/MarkdownText.swift`**
- Custom UIViewRepresentable wrapping UITextView for range-based text selection
- Per-block rendering: each paragraph/header/code block is its own `SelectableText` view
- `MarkdownParser.parseBlocks()` splits text into `.paragraph`, `.header(level)`, `.codeBlock`
- Paragraphs split on blank lines
- Code blocks styled with background + corner radius in SwiftUI
- `SelectableText` Coordinator caches `lastSource`, `lastStyle`, `cachedSize`, `cachedWidth` to prevent re-layout loops

### Agent Selector
**`Relay/Views/Components/AgentSelector.swift`**
- Horizontal scroll of agent chips (excludes the Operator agent)
- Shows agent name + LLM provider + status dot (healthy/error/unknown)
- 4pt vertical padding top and bottom for breathing room
- Tapping an agent sends "connect me to {agent.name}" message to the operator

### Audio
**`Relay/Services/AudioPlayerService.swift`**
- Actor-based, sequence-ordered MP3 chunk queue
- `waitUntilFinished()`: polls `isDraining || pendingReset` every 50ms — used for session handoff

**`Relay/ViewModels/AudioViewModel.swift`**
- `handleSessionChange()` restarts recorder only (doesn't touch player)
- `stopAudio()` calls `player.stop()`

### Models
**`Relay/Models/RelayActivityAttributes.swift`**
```swift
struct RelayActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isMuted: Bool
        var agentName: String
        var status: String
    }
}
```

**`Relay/Models/LiveActivityIntents.swift`**
- Notification names: `.relayToggleMute`, `.relayExitLive`, `.relayEnterLive`
- `ToggleMuteIntent`, `ExitLiveIntent`: `LiveActivityIntent` implementations for Live Activity buttons

**`Relay/Models/Message.swift`**
- `id: UUID` generated on init
- `role`: `.user`, `.operator`, `.agent`
- `textContent`: stored property
- `isStreaming`: stored property, defaults to `false` for history messages

**`Relay/Models/WebSocketEvent.swift`**
- Cases: `stateUpdate`, `text`, `handoff`, `sessionEntered`, `sessionLeft`, `sessionHistory`, `sessionNamed`, `textStart`, `textDelta`, `textDone`, `audioStart`, `audioChunk`, `audioDone`, `transcription`, `error`

---

## Widget Extension (`RelayWidgetExtension/`)

### Files
- `RelayLiveActivity.swift` — Live Activity widget + `@main` WidgetBundle
- `RelayQuickLaunchWidget.swift` — Lock screen shortcut widget
- `Assets.xcassets/WidgetIcon.imageset/` — Widget icon asset (speech bubble image)

### Live Activity Widget (`RelayLiveActivity`)
- Lock screen view: agent name, status text, mute button, exit button
- Dynamic Island: compact (blue dot), expanded (agent name + buttons)
- Buttons use `ToggleMuteIntent` / `ExitLiveIntent` (AppIntents)

### Lock Screen Shortcut Widget (`RelayQuickLaunchWidget`)
- Family: `accessoryCircular` only
- Static configuration (no dynamic data)
- Shows `ellipsis.bubble` SF Symbol with `AccessoryWidgetBackground()`
- `widgetURL`: `relay://live` → opens app and enters live mode
- Must use `.containerBackground(.fill.tertiary, for: .widget)` for iOS 17+

---

## Color Palette
Defined as `Color` extensions (likely in `Relay/Extensions/` or `Relay/Theme/`):
- `relaySurface` — main background
- `relayElevated` — elevated surface (user bubble background)
- `relayBorder` — separator lines
- `relayTextPrimary`, `relayTextSecondary`, `relayTextTertiary`, `relayTextQuaternary`
- `relaySuccess`, `relaySuccessLight` — green tones
- `relayError` — red
- `relayWarning` — orange/yellow (used for "Back to Lobby" button)
- `relayBlue` / relay blue: `rgb(37, 99, 235)`
- `relayOperatorBubble`, `relayAgentBubble` — bubble backgrounds
- `relayAgentActive` — active agent chip background

---

## WebSocket Event Flow

1. Client connects → receives `stateUpdate` with agents list, sessions, status
2. Lobby: operator sends `text` events (streamed via `textStart`/`textDelta`/`textDone`)
3. User enters live mode → audio chunks flow via `audioChunk` events
4. Operator routes user to agent → `sessionEntered` event with `sessionId` + `agentName`
5. In session: agent messages arrive as `text`/streaming events
6. `sessionLeft` → back to lobby
7. `sessionHistory` → sent on session resume, contains prior messages

---

## Bug History / Critical Decisions

### App Freeze (LazyVStack + defaultScrollAnchor)
**Symptom**: App becomes unresponsive to touch after loading a session with messages. Main thread is NOT blocked (heartbeat timer kept firing).
**Root cause**: `LazyVStack` combined with `.defaultScrollAnchor(.bottom)` causes SwiftUI's ScrollView touch handling to lock up.
**Fix**: Switch to `VStack`, remove `.defaultScrollAnchor(.bottom)`. Use `ScrollViewReader` + `.scrollTo()` for auto-scroll instead.
**Why VStack**: Session message lists are short enough (chat history) that LazyVStack's deferred rendering provides no meaningful benefit.

### iOS Background Disconnect
**Symptom**: WebSocket disconnects when app is backgrounded on a real device (not simulator).
**Fix**: `@Environment(\.scenePhase)` in `RelayView` — reconnect when transitioning to `.active` and `!relay.connected`.

### Audio Clipping on Session Handoff
**Symptom**: Operator's handoff audio (e.g., "Let me connect you to...") gets cut off mid-sentence when session swaps.
**Fix**: In live mode, `sessionEntered` handler awaits `audio.player.waitUntilFinished()` before swapping `activeSessionId`. `waitUntilFinished()` polls `isDraining || pendingReset` every 50ms.

### ElevenLabs Audio Annotations
**Symptom**: ElevenLabs STT adds "(mysterious music)" and similar annotations to transcriptions.
**Fix**: `tag_audio_events: "false"` in the multipart form data of the STT request (`backend/app/services/stt/elevenlabs.py`).

### Lock Screen Widget URL
**Symptom**: Tapping widget opens Apple documentation URL instead of `relay://live`.
**Fix**: Must use `.containerBackground(.fill.tertiary, for: .widget)` on the widget view (required for iOS 17+ accessory widgets). Without it, WidgetKit ignores `widgetURL`.

### Widget Icon Appearing Blank
**Symptom**: Custom PNG image appears blank on lock screen widget.
**Root cause**: Lock screen widgets use the image's alpha channel for rendering. A PNG with a solid white background (fully opaque everywhere) renders as a blank rectangle.
**Fix**: Use SF Symbols (`ellipsis.bubble`) which are designed for all widget rendering modes.

---

## XcodeGen Notes
- Edit `ios-client/project.yml` to add files/targets/settings
- Run `xcodegen generate` from `ios-client/` to regenerate `.xcodeproj`
- New source files in `RelayWidgetExtension/` are auto-included by the directory source rule
- New asset catalogs need to be in the correct target's source directory

## Docker
- Backend: `docker restart hub-backend-1`
- Frontend: `hub-frontend-1`

## Simulator vs Device Differences
- AirPods / audio input: doesn't work in iOS Simulator, only on real device
- Background/foreground lifecycle: Simulator doesn't kill WebSocket on background, real device does
