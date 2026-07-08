import ActivityKit
import Foundation

@Observable
@MainActor
final class RelayViewModel {
    // MARK: - Published state

    var connected = false
    var activeSessionId: String?
    var activeAgentName: String?
    var activeSessionLabels: [String] = []
    var activeSpeaker = "operator"
    var status = "idle"
    var lobbyMessages: [Message] = []
    var sessionMessages: [Message] = []
    var agents: [Agent] = []
    var sessions: [Session] = []
    var allLabels: [String] = []
    /// ark projects, aggregated across every configured ark backend by the
    /// Relay aggregator. Each entry carries `serverId` so the UI can route
    /// single-project ops back to the right ark.
    var projects: [Project] = []
    /// Ring-buffered file-change events (project + workspace). Feeds the
    /// "Recent changes" view in the file browser.
    var fileChanges: [FileChangeEvent] = []
    private static let fileChangeBufferCap = 200

    /// Per-scope file-tree expansion state, keyed by `"<kind>:<targetId>"`.
    /// Survives sheet dismissals so reopening the file browser puts the
    /// user back in the same tree state — important on iPad where the
    /// browser is a sheet and gets dismissed every time a file is opened
    /// into a central tab. Ephemeral: cleared on disconnect alongside
    /// the rest of session state.
    var fileTreeExpanded: [String: [String: DirListing]] = [:]

    /// True while the central-pane file editor's underlying UITextView is
    /// first responder. The iPad layout uses this to silence its
    /// single-letter keyboard shortcuts ("/" and "m") while the user is
    /// typing — otherwise those keys never reach the editor.
    var editorFocused: Bool = false
    /// Counter that the editor wrapper observes; bumping it tells the
    /// active editor to `resignFirstResponder` (used by Escape from the
    /// iPad layout).
    var resignEditorFocusTrigger: Int = 0
    /// True while the message-input UITextView is first responder. Same
    /// purpose as `editorFocused` — UIKit-backed first-responder state
    /// is invisible to SwiftUI's `@FocusState`, so the iPad shortcut
    /// gate (`/`, `m`, Escape) reads this instead.
    var messageInputFocused: Bool = false
    /// Client-side system markers keyed by sessionId — appended to sessionMessages
    /// on resume so the user can see when a session ended within the app's lifetime.
    private var sessionMarkers: [String: [Message]] = [:]
    var sttAvailable = false
    var sttSettings: PlatformSettings?
    var outputMode: OutputMode = .speaker
    var isLiveMode = false

    enum OutputMode: String {
        case speaker, earpiece
    }

    // MARK: - Services

    private let authService: AuthService
    let apiClient: APIClient
    private let webSocketService = WebSocketService()
    private let speechService = SpeechRecognitionService()
    let audio = AudioViewModel()

    private var eventTask: Task<Void, Never>?
    private var currentActivity: Activity<RelayActivityAttributes>?

    // Pending session — set immediately on sessionEntered so events route correctly
    // before the live-mode audio wait completes and the UI swaps.
    private var pendingSessionId: String?
    private var pendingAgentName: String?

    // Agent audio that arrives while waiting for operator audio to finish.
    // Flushed to the player only after the UI has swapped to the session view.
    private var pendingAudioHasStart = false
    private var pendingAudioChunks: [(data: String, sequence: Int)] = []
    private var pendingAudioHasDone = false

    // Suppress the operator greeting sent on every fresh WebSocket connection.
    private var suppressNextGreeting = false

    // Gap detection: fires the thinking tone if no audio_chunk arrives within 300 ms.
    private var audioGapTask: Task<Void, Never>?
    /// Whether the operator/agent is currently "thinking" from a status
    /// perspective. The thinking tone may still be paused while TTS audio is
    /// playing — see `syncThinkingTone`.
    private var wantThinkingTone = false

    private var isInSession: Bool {
        activeSessionId != nil || pendingSessionId != nil
    }

    var useLocalStt: Bool {
        UserDefaults.standard.string(forKey: "stt_local_provider") == "apple"
    }

    init(authService: AuthService) {
        self.authService = authService
        self.apiClient = APIClient(authService: authService)

        // Wire audio recording completion → send audio or transcribe locally
        audio.setup(
            onRecordingComplete: { [weak self] base64, format, fileURL in
                await self?.handleRecordingComplete(base64: base64, format: format, fileURL: fileURL)
            },
            onSpeechStarted: { [weak self] in
                guard let self else { return }
                guard await self.isLiveMode else { return }
                // Cancel gap timer and mark any in-progress streaming message as interrupted
                await MainActor.run {
                    self.audioGapTask?.cancel()
                    self.audioGapTask = nil
                    if let idx = self.sessionMessages.indices.last,
                       self.sessionMessages[idx].isStreaming {
                        self.sessionMessages[idx].isStreaming = false
                        self.sessionMessages[idx].isInterrupted = true
                    }
                    self.wantThinkingTone = false
                    self.syncThinkingTone()
                }
                // Signal backend to cancel the current agent turn
                print("[Relay] speech detected — sending interrupt")
                try? await self.webSocketService.send(.interrupt)
            }
        )
    }

    // MARK: - Connection

    func connect() async {
        guard let token = authService.token else {
            print("[Relay] No token, cannot connect")
            return
        }

        await webSocketService.connect(token: token)
        connected = true

        // Start consuming events
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await webSocketService.events
            for await event in stream {
                await self.handleEvent(event)
            }
            // Stream ended → disconnected
            await MainActor.run {
                self.connected = false
                self.status = "disconnected"
            }
        }

        // Fetch initial data
        await refreshAgents()
        await fetchSessions()
        await fetchLabels()
        await fetchProjects()
        await checkSttStatus()
        await fetchPlatformSettings()
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        await webSocketService.disconnect()
        if isLiveMode { exitLiveMode() }
        audio.stopAudio()
        connected = false
        activeSessionId = nil
        activeAgentName = nil
        activeSessionLabels = []
        lobbyMessages = []
        sessionMessages = []
        sessions = []
        fileTreeExpanded = [:]
        status = "idle"
        activeSpeaker = "operator"
    }

    func reconnect() async {
        suppressNextGreeting = true
        let previousSessionId = activeSessionId  // capture before connect() runs
        await connect()
        // Re-enter the session we were in before the disconnect.
        // The backend will respond with sessionHistory (and possibly sessionEntered)
        // to re-establish the session context. If the session no longer exists,
        // the backend sends sessionLeft, which clears activeSessionId normally.
        if let sessionId = previousSessionId, connected {
            await resumeSession(sessionId)
        }
    }

    /// Resync state after returning from background. The connection may appear alive
    /// but the client could have missed messages (especially agent responses that
    /// completed in the background). Re-fetch session list and resume the active
    /// session if there is one to pull down the latest history.
    func resync() async {
        await fetchSessions()
        if let sessionId = activeSessionId {
            suppressNextGreeting = true
            await resumeSession(sessionId)
        }
    }

    // MARK: - Actions

    func sendMessage(_ text: String) async {
        if isLiveMode { ChimeGenerator.play() }

        // A follow-up user message implicitly interrupts any in-flight
        // agent turn. Close its streaming bubble locally right now so
        // the "thinking" dots go away immediately — the backend will
        // cancel the old task on its side, but that's a round-trip.
        if activeSessionId != nil {
            for i in sessionMessages.indices where sessionMessages[i].isStreaming {
                sessionMessages[i].isStreaming = false
                sessionMessages[i].isInterrupted = true
            }
        }

        let message = Message(role: .user, textContent: text, createdAt: Date())
        if activeSessionId != nil {
            sessionMessages.append(message)
        } else {
            lobbyMessages.append(message)
        }

        do {
            try await webSocketService.send(.textInput(text: text))
        } catch {
            print("[Relay] Failed to send message: \(error)")
        }
    }

    /// Upload a file for the active session. The bytes are POSTed to
    /// `/v1/files`; if the session is ark-backed, the backend forwards them
    /// to ark on our behalf and the upload itself becomes the agent-visible
    /// "user attached a file" event. Appends a user message with the resulting
    /// attachment to the conversation log.
    @discardableResult
    func uploadAttachment(data: Data, filename: String, mimeType: String) async -> FileAttachment? {
        struct UploadResponse: Decodable {
            let file_id: String
            let filename: String
            let mime_type: String
            let size_bytes: Int
            let url: String
        }
        var path = "/v1/files"
        if let sid = activeSessionId,
           let encoded = sid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?session_id=\(encoded)"
        }
        do {
            let resp: UploadResponse = try await apiClient.uploadMultipart(
                "POST", path: path,
                field: "file", filename: filename, mimeType: mimeType, data: data,
            )
            let att = FileAttachment(
                fileId: resp.file_id,
                filename: resp.filename,
                mimeType: resp.mime_type,
                sizeBytes: resp.size_bytes,
                url: resp.url,
            )
            let msg = Message(role: .user, textContent: "", createdAt: Date(), attachments: [att])
            if activeSessionId != nil {
                sessionMessages.append(msg)
            } else {
                lobbyMessages.append(msg)
            }
            return att
        } catch {
            print("[Relay] Upload failed: \(error)")
            return nil
        }
    }

    func sendAudio(_ base64: String, format: String) async {
        print("[STT] sending audio_input: \(base64.count) base64 chars, format=\(format)")
        do {
            try await webSocketService.send(.audioInput(data: base64, format: format))
        } catch {
            print("[STT] Failed to send audio: \(error)")
        }
    }

    private func handleRecordingComplete(base64: String, format: String, fileURL: URL) async {
        if useLocalStt {
            do {
                let text = try await speechService.transcribe(url: fileURL)
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    print("[STT][local] empty transcription, discarding")
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                print("[STT][local] transcribed: \"\(text)\"")
                try? FileManager.default.removeItem(at: fileURL)

                if await self.isLiveMode {
                    await MainActor.run {
                        ChimeGenerator.play()
                        HapticService.impact(.light)
                    }
                }
                await sendMessage(text)
            } catch {
                print("[STT][local] transcription failed: \(error)")
                try? FileManager.default.removeItem(at: fileURL)
            }
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            await sendAudio(base64, format: format)
        }
    }

    func leaveSession() async {
        do {
            try await webSocketService.send(.leaveSession)
        } catch {
            print("[Relay] Failed to leave session: \(error)")
        }
    }

    func resumeSession(_ sessionId: String) async {
        do {
            try await webSocketService.send(.resumeSession(sessionId: sessionId))
        } catch {
            print("[Relay] Failed to resume session: \(error)")
        }
    }

    func renameSession(_ sessionId: String, name: String) async {
        do {
            try await webSocketService.send(.renameSession(sessionId: sessionId, name: name))
        } catch {
            print("[Relay] Failed to rename session: \(error)")
        }
    }

    func updateSessionLabels(_ sessionId: String, labels: [String]) async {
        do {
            try await webSocketService.send(.updateSessionLabels(sessionId: sessionId, labels: labels))
        } catch {
            print("[Relay] Failed to update session labels: \(error)")
        }
    }

    func deleteSession(_ sessionId: String) async {
        do {
            try await apiClient.delete(path: "/v1/sessions/\(sessionId)")
            sessions.removeAll { $0.sessionId == sessionId }
            if activeSessionId == sessionId {
                activeSessionId = nil
                activeAgentName = nil
                activeSessionLabels = []
                sessionMessages = []
                activeSpeaker = "operator"
                status = "ready"
                audio.handleSessionChange(newSessionId: nil)
            }
        } catch {
            print("[Relay] Failed to delete session: \(error)")
        }
    }

    func refreshAgents() async {
        do {
            let fetched: [Agent] = try await apiClient.request("GET", path: "/v1/agents?include_operator=true")
            agents = fetched
        } catch {
            print("[Relay] Failed to fetch agents: \(error)")
        }
    }

    func fetchLabels() async {
        struct LabelDTO: Decodable { let label_id: String; let name: String }
        do {
            let fetched: [LabelDTO] = try await apiClient.request("GET", path: "/v1/labels")
            allLabels = fetched.map(\.name).sorted()
        } catch {
            print("[Relay] Failed to fetch labels: \(error)")
        }
    }

    func fetchSessions(search: String? = nil, label: String? = nil) async {
        do {
            var path = "/v1/sessions"
            var params: [String] = []
            if let s = search, !s.isEmpty,
               let encoded = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                params.append("search=\(encoded)")
            }
            if let l = label, !l.isEmpty,
               let encoded = l.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                params.append("label=\(encoded)")
            }
            if !params.isEmpty { path += "?" + params.joined(separator: "&") }
            let fetched: [Session] = try await apiClient.request("GET", path: path)
            sessions = fetched
        } catch {
            print("[Relay] Failed to fetch sessions: \(error)")
        }
    }

    func fetchProjects() async {
        do {
            let fetched = try await apiClient.listProjects()
            projects = fetched
        } catch {
            // Non-ark setups will fail or return empty — keep quiet.
            print("[Relay] Failed to fetch projects: \(error)")
        }
    }

    /// Append to the ring-buffered file-change log, dropping the oldest
    /// entry when we cross the cap.
    func appendFileChange(_ ev: FileChangeEvent) {
        var next = fileChanges
        next.append(ev)
        if next.count > Self.fileChangeBufferCap {
            next.removeFirst(next.count - Self.fileChangeBufferCap)
        }
        fileChanges = next
    }

    func setOutputMode(_ mode: OutputMode) {
        outputMode = mode
        audio.setEarpieceMode(mode == .earpiece)

        do {
            if mode == .earpiece {
                try AudioSessionManager.configure(.earpiece)
            } else {
                try AudioSessionManager.configure(.playback)
            }
        } catch {
            print("[Relay] Failed to set output mode: \(error)")
        }
    }

    func toggleMute() {
        audio.isMuted.toggle()
        if isLiveMode { updateLiveActivity() }
    }

    func enterLiveMode(trigger: String = "user") {
        isLiveMode = true
        ChimeGenerator.playLiveStart()
        audio.startListening()
        startLiveActivity()
        Task { try? await webSocketService.send(.setLiveMode(enabled: true)) }
        ActivityLog.shared.add("live_mode_entered", context: [
            "trigger": trigger,
            "active_session_id": activeSessionId as Any,
            "active_agent": activeAgentName as Any,
        ])
    }

    /// Re-evaluate whether the thinking tone should be playing right now.
    /// The tone is gated on `wantThinkingTone` (status-driven) AND the
    /// absence of active TTS playback (so it never overlaps the agent's
    /// voice). Safe to call from any context; the work happens in a Task.
    private func syncThinkingTone() {
        let want = wantThinkingTone && isLiveMode
        Task {
            if want {
                let playing = await audio.player.isPlaying()
                if !playing {
                    await ThinkingToneService.shared.start()
                    return
                }
            }
            await ThinkingToneService.shared.stop()
        }
    }

    func exitLiveMode(trigger: String = "user") {
        isLiveMode = false
        audioGapTask?.cancel()
        audioGapTask = nil
        audio.stopListening()
        audio.stopAudio()
        endLiveActivity()
        Task { await SilentKeepAlive.shared.stop() }
        wantThinkingTone = false
        Task { await ThinkingToneService.shared.stop() }
        Task { try? await webSocketService.send(.setLiveMode(enabled: false)) }
        ActivityLog.shared.add("live_mode_exited", context: [
            "trigger": trigger,
            "active_session_id": activeSessionId as Any,
        ])
    }

    func stopAudio() {
        audio.stopAudio()
    }

    // MARK: - Live Activity

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] Activities not enabled")
            return
        }

        let initialState = RelayActivityAttributes.ContentState(
            isMuted: audio.isMuted,
            agentName: activeAgentName ?? "Relay",
            status: status
        )

        do {
            let activity = try Activity.request(
                attributes: RelayActivityAttributes(),
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            print("[LiveActivity] Started: \(activity.id)")
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    private func updateLiveActivity() {
        guard let activity = currentActivity else { return }

        let updatedState = RelayActivityAttributes.ContentState(
            isMuted: audio.isMuted,
            agentName: activeAgentName ?? "Relay",
            status: status
        )

        Task {
            await activity.update(
                ActivityContent(state: updatedState, staleDate: nil)
            )
        }
    }

    private func endLiveActivity() {
        guard let activity = currentActivity else { return }

        let finalState = RelayActivityAttributes.ContentState(
            isMuted: false,
            agentName: activeAgentName ?? "Relay",
            status: "ended"
        )

        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            print("[LiveActivity] Ended: \(activity.id)")
        }

        currentActivity = nil
    }

    // MARK: - Private

    private func checkSttStatus() async {
        do {
            struct SttStatus: Codable { let available: Bool }
            let result: SttStatus = try await apiClient.request("GET", path: "/v1/agents/stt/status")
            sttAvailable = result.available
        } catch {
            sttAvailable = false
        }
    }

    func fetchPlatformSettings() async {
        do {
            let settings: PlatformSettings = try await apiClient.request("GET", path: "/v1/platform/settings")
            sttSettings = settings

            // Apply STT settings to recorder
            audio.updateSettings(
                silenceThresholdDb: Float(settings.sttSilenceThresholdDb),
                silenceTimeoutMs: settings.sttSilenceTimeoutMs,
                minDurationMs: settings.sttMinDurationMs,
                attackDebounceMs: settings.sttAttackDebounceMs
            )
        } catch {
            print("[Relay] Failed to fetch platform settings: \(error)")
        }
    }

    private func handleEvent(_ event: WebSocketEvent) {
        switch event {
        case .stateUpdate(let payload):
            activeSpeaker = payload.activeSpeaker
            status = payload.status
            if isLiveMode { updateLiveActivity() }
            if isLiveMode {
                let nowThinking = payload.status == "processing"
                if nowThinking != wantThinkingTone {
                    print("[ThinkingTone] status=\(payload.status) → want=\(nowThinking)")
                }
                wantThinkingTone = nowThinking
                syncThinkingTone()
            }
            // Restore the streaming placeholder (three-dot indicator) when resuming
            // a session whose agent is still working in the background. The placeholder
            // was lost when session_history overwrote sessionMessages.
            if isInSession, payload.status == "processing",
               sessionMessages.last?.isStreaming != true {
                sessionMessages.append(Message(role: .agent, textContent: "", createdAt: Date(), isStreaming: true))
            }

        case .text(let payload):
            if suppressNextGreeting && payload.speaker == "operator" {
                if !isLiveMode { suppressNextGreeting = false }
                break
            }
            // If the event is targeted at a specific session and that
            // session isn't the one we're viewing, skip the live append —
            // the server has already persisted, the unread badge will
            // signal, and history-on-resume will replay it when the user
            // navigates over.
            if let targetSid = payload.sessionId, targetSid != activeSessionId {
                break
            }
            let role: Message.MessageRole = payload.speaker == "operator" ? .operator : .agent
            let msg = Message(role: role, textContent: payload.text, createdAt: Date())
            if isInSession {
                sessionMessages.append(msg)
            } else {
                lobbyMessages.append(msg)
            }

        case .handoff(let payload):
            if payload.playEarcon && isLiveMode {
                HapticService.notification(.success)
            }

        case .sessionEntered(let payload):
            ActivityLog.shared.add("session_entered", context: [
                "session_id": payload.sessionId,
                "agent_name": payload.agentName,
                "labels": payload.labels,
                "in_live_mode": isLiveMode,
            ])
            if isLiveMode {
                // Stage the session immediately so incoming events route to sessionMessages.
                // The UI swap (activeSessionId) waits for operator audio to finish.
                pendingSessionId = payload.sessionId
                pendingAgentName = payload.agentName
                activeSessionLabels = payload.labels
                sessionMessages = []
                Task {
                    await audio.player.waitUntilFinished()
                    guard pendingSessionId != nil else { return }  // session was cancelled
                    ChimeGenerator.play()
                    activeSessionId = pendingSessionId
                    activeAgentName = pendingAgentName
                    pendingSessionId = nil
                    pendingAgentName = nil
                    audio.handleSessionChange(newSessionId: payload.sessionId)
                    updateLiveActivity()
                    // Flush any agent audio that arrived during the operator audio wait
                    if pendingAudioHasStart {
                        await audio.player.start()
                        pendingAudioHasStart = false
                    }
                    for chunk in pendingAudioChunks {
                        await audio.player.enqueue(data: chunk.data, sequence: chunk.sequence)
                    }
                    pendingAudioChunks = []
                    if pendingAudioHasDone {
                        await audio.player.done()
                        pendingAudioHasDone = false
                    }
                    await fetchSessions()
                }
            } else {
                activeSessionId = payload.sessionId
                activeAgentName = payload.agentName
                activeSessionLabels = payload.labels
                sessionMessages = []
                audio.handleSessionChange(newSessionId: payload.sessionId)
                Task { await fetchSessions() }
            }

        case .sessionLeft(let payload):
            audio.stopAudio()
            audioGapTask?.cancel()
            audioGapTask = nil
            let oldSessionId = activeSessionId
            let oldAgentName = activeAgentName
            pendingSessionId = nil
            pendingAgentName = nil
            pendingAudioHasStart = false
            pendingAudioChunks = []
            pendingAudioHasDone = false

            // Build a system marker capturing what just happened so the user
            // can see (in both the now-cleared session log on resume, and in
            // the lobby) that they were dumped out.
            if let sid = oldSessionId {
                let now = Date()
                let sessionMarker = Message(role: .system, textContent: "Left session", createdAt: now)
                let lobbyLabel = oldAgentName.map { "Left session with \($0)" } ?? "Left session"
                let lobbyMarker = Message(role: .system, textContent: lobbyLabel, createdAt: now)
                sessionMarkers[sid, default: []].append(sessionMarker)
                lobbyMessages.append(lobbyMarker)
                if isLiveMode { ChimeGenerator.playSessionLeave() }
            }
            var ctx: [String: Any] = [
                "previous_session_id": oldSessionId as Any,
                "previous_agent": oldAgentName as Any,
                "in_live_mode": isLiveMode,
                "reason": payload.reason as Any,
            ]
            // Server-reported session_id is the one the server just left us
            // out of — useful when it differs from what the client thought
            // was active (e.g. resume-of-missing-session edge case).
            if let serverSid = payload.sessionId {
                ctx["server_session_id"] = serverSid
            }
            // Spread `detail` keys into the context so the JSON dump shows
            // the matched text, target agent, etc. on individual lines
            // rather than as a nested blob.
            if let detail = payload.detail {
                for (k, v) in detail { ctx[k] = v.anyValue }
            }
            ActivityLog.shared.add("session_left", context: ctx)

            activeSessionId = nil
            activeAgentName = nil
            activeSessionLabels = []
            sessionMessages = []
            audio.handleSessionChange(newSessionId: nil)
            if isLiveMode { updateLiveActivity() }
            if oldSessionId != nil {
                Task { await fetchSessions() }
            }

        case .sessionHistory(let payload):
            var messages = payload.messages.map { $0.toMessage() }
            if let sid = activeSessionId ?? pendingSessionId,
               let markers = sessionMarkers[sid], !markers.isEmpty {
                messages.append(contentsOf: markers)
            }
            sessionMessages = messages

        case .sessionNamed(let payload):
            if let idx = sessions.firstIndex(where: { $0.sessionId == payload.sessionId }) {
                sessions[idx].name = payload.name
            }

        case .sessionRenamed(let payload):
            if let idx = sessions.firstIndex(where: { $0.sessionId == payload.sessionId }) {
                sessions[idx].name = payload.name
            }

        case .sessionLabelsUpdated(let payload):
            if let idx = sessions.firstIndex(where: { $0.sessionId == payload.sessionId }) {
                sessions[idx].labels = payload.labels
            }
            if activeSessionId == payload.sessionId {
                activeSessionLabels = payload.labels
            }
            Task { await fetchLabels() }

        case .sessionStatus(let payload):
            if let idx = sessions.firstIndex(where: { $0.sessionId == payload.sessionId }) {
                sessions[idx].status = payload.status
            }
            // If the active session transitioned from processing → paused, a
            // background-completed response just finished. Re-resume to pull fresh history
            // and clear the thinking indicator.
            if payload.sessionId == activeSessionId && payload.status == "paused" {
                Task { await resumeSession(payload.sessionId) }
            }

        case .sessionUnread(let payload):
            if let idx = sessions.firstIndex(where: { $0.sessionId == payload.sessionId }) {
                sessions[idx].hasUnread = payload.hasUnread
            }

        case .sessionDeleted(let payload):
            audio.stopAudio()
            audioGapTask?.cancel()
            audioGapTask = nil
            sessions.removeAll { $0.sessionId == payload.sessionId }
            if activeSessionId == payload.sessionId {
                activeSessionId = nil
                activeAgentName = nil
                activeSessionLabels = []
                sessionMessages = []
                audio.handleSessionChange(newSessionId: nil)
            }

        case .textStart(let payload):
            if suppressNextGreeting && payload.speaker == "operator" { break }
            guard isInSession else { break }
            let role: Message.MessageRole = payload.speaker == "operator" ? .operator : .agent
            // Defensive: any prior bubble still marked streaming was
            // orphaned (a cancelled turn that never emitted its text_done).
            // Close it so its thinking dots go away instead of lingering
            // behind the new turn's bubble.
            for i in sessionMessages.indices where sessionMessages[i].isStreaming
                && !(sessionMessages[i].textContent.isEmpty && i == sessionMessages.count - 1
                     && sessionMessages[i].role == role) {
                sessionMessages[i].isStreaming = false
                sessionMessages[i].isInterrupted = true
            }
            // Reuse the placeholder added by the processing state_update if present.
            if let last = sessionMessages.last, last.isStreaming, last.textContent.isEmpty, last.role == role {
                break
            }
            sessionMessages.append(Message(role: role, textContent: "", createdAt: Date(), isStreaming: true))

        case .textDelta(let payload):
            guard isInSession, !sessionMessages.isEmpty else { break }
            let lastIdx = sessionMessages.count - 1
            if sessionMessages[lastIdx].isStreaming {
                sessionMessages[lastIdx].textContent += payload.delta
            }

        case .textDone(let payload):
            guard isInSession, !sessionMessages.isEmpty else { break }
            let lastIdx = sessionMessages.count - 1
            if sessionMessages[lastIdx].isStreaming {
                sessionMessages[lastIdx].textContent = payload.text
                sessionMessages[lastIdx].isStreaming = false
                if let meta = payload.metadata {
                    sessionMessages[lastIdx].metadata = meta
                }
                if sessionMessages[lastIdx].createdAt == nil {
                    sessionMessages[lastIdx].createdAt = Date()
                }
            }

        case .audioStart(let payload):
            guard isLiveMode else { break }
            if suppressNextGreeting { break }
            if pendingSessionId != nil {
                pendingAudioHasStart = true
                break
            }
            print("[TTS][relay] audio_start from \(payload.speaker)")
            Task { await audio.player.start() }
            // TTS playback is starting — sync so the thinking tone steps aside.
            syncThinkingTone()

        case .audioChunk(let payload):
            guard isLiveMode else { break }
            if suppressNextGreeting { break }
            // Cancel any pending gap timer; real audio is arriving and the
            // sync() below will suppress the thinking tone.
            audioGapTask?.cancel()
            audioGapTask = nil
            if pendingSessionId != nil {
                pendingAudioChunks.append((data: payload.data, sequence: payload.sequence))
                break
            }
            print("[TTS][relay] audio_chunk seq=\(payload.sequence) (\(payload.data.count) b64 chars)")
            Task { await audio.player.enqueue(data: payload.data, sequence: payload.sequence) }
            syncThinkingTone()
            // Gap timer: if no chunk arrives within 300 ms, the player will
            // have drained and sync will restore the thinking tone (only if
            // we still want it and nothing is actually playing).
            audioGapTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.audioGapTask = nil
                    self.syncThinkingTone()
                }
            }

        case .audioDone(let payload):
            guard isLiveMode else { break }
            if suppressNextGreeting {
                suppressNextGreeting = false
                break
            }
            if pendingSessionId != nil {
                pendingAudioHasDone = true
                break
            }
            // Turn is fully done — cancel gap timer so thinking tone doesn't re-arm.
            audioGapTask?.cancel()
            audioGapTask = nil
            print("[TTS][relay] audio_done from \(payload.speaker)")
            Task {
                await audio.player.done()
                await audio.player.waitUntilFinished()
                // Playback fully complete — if status is still "processing"
                // (mid-turn tool call, etc.), the thinking tone should resume.
                await MainActor.run { self.syncThinkingTone() }
            }

        case .transcription(let payload):
            print("[STT] transcription received: \"\(payload.text)\"")
            if isLiveMode {
                ChimeGenerator.play()
                HapticService.impact(.light)
            }
            let msg = Message(role: .user, textContent: payload.text, createdAt: Date())
            if isInSession {
                sessionMessages.append(msg)
            } else {
                lobbyMessages.append(msg)
            }

        case .agentFile(let payload):
            // Agent pushed a workspace file via ark's share_with_client tool.
            // Render as an agent message with a single attachment whose URL
            // routes through Relay's ark passthrough.
            guard isInSession, payload.sessionId == activeSessionId else { break }
            let filename = (payload.path.split(separator: "/").last).map(String.init) ?? payload.path
            let encodedAgent = payload.agentName
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? payload.agentName
            let encodedPath = payload.path
                .split(separator: "/")
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            let attachment = FileAttachment(
                fileId: nil,
                filename: filename,
                mimeType: "application/octet-stream",
                sizeBytes: payload.size ?? 0,
                url: "/v1/files/ark/\(encodedAgent)/\(encodedPath)"
            )
            sessionMessages.append(Message(
                role: .agent,
                textContent: payload.description ?? "",
                attachments: [attachment]
            ))

        case .projectFileChanged(let payload):
            appendFileChange(.init(
                ts: Date(),
                kind: .project,
                scope: payload.projectId,
                path: payload.path,
                change: FileChangeEvent.Change(rawValue: payload.change) ?? .modified,
            ))

        case .workspaceFileChanged(let payload):
            appendFileChange(.init(
                ts: Date(),
                kind: .workspace,
                scope: payload.agentName,
                path: payload.path,
                change: FileChangeEvent.Change(rawValue: payload.change) ?? .modified,
            ))

        case .error(let payload):
            print("[Relay] Server error: \(payload.message)")
        }
    }
}
