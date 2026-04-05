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
    var sttAvailable = false
    var sttSettings: PlatformSettings?
    var outputMode: OutputMode = .speaker
    var isLiveMode = false

    enum OutputMode: String {
        case speaker, earpiece
    }

    // MARK: - Services

    private let authService: AuthService
    private let apiClient: APIClient
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
                }
                Task { await ThinkingToneService.shared.stop() }
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

    // MARK: - Actions

    func sendMessage(_ text: String) async {
        if isLiveMode { ChimeGenerator.play() }

        let message = Message(role: .user, textContent: text)
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

    func fetchSessions() async {
        do {
            let fetched: [Session] = try await apiClient.request("GET", path: "/v1/sessions")
            sessions = fetched
        } catch {
            print("[Relay] Failed to fetch sessions: \(error)")
        }
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

    func enterLiveMode() {
        isLiveMode = true
        ChimeGenerator.playLiveStart()
        audio.startListening()
        startLiveActivity()
        Task { try? await webSocketService.send(.setLiveMode(enabled: true)) }
    }

    func exitLiveMode() {
        isLiveMode = false
        ChimeGenerator.playLiveEnd()
        audioGapTask?.cancel()
        audioGapTask = nil
        audio.stopListening()
        audio.stopAudio()
        endLiveActivity()
        Task { await SilentKeepAlive.shared.stop() }
        Task { await ThinkingToneService.shared.stop() }
        Task { try? await webSocketService.send(.setLiveMode(enabled: false)) }
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
                if payload.status == "processing" {
                    print("[ThinkingTone] status=processing → start")
                    Task { await ThinkingToneService.shared.start() }
                } else {
                    Task { await ThinkingToneService.shared.stop() }
                }
            }

        case .text(let payload):
            if suppressNextGreeting && payload.speaker == "operator" {
                if !isLiveMode { suppressNextGreeting = false }
                break
            }
            let role: Message.MessageRole = payload.speaker == "operator" ? .operator : .agent
            let msg = Message(role: role, textContent: payload.text)
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

        case .sessionLeft:
            audio.stopAudio()
            audioGapTask?.cancel()
            audioGapTask = nil
            let oldSessionId = activeSessionId
            pendingSessionId = nil
            pendingAgentName = nil
            pendingAudioHasStart = false
            pendingAudioChunks = []
            pendingAudioHasDone = false
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
            sessionMessages = payload.messages.map { $0.toMessage() }

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
            sessionMessages.append(Message(role: role, textContent: "", isStreaming: true))

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

        case .audioChunk(let payload):
            guard isLiveMode else { break }
            if suppressNextGreeting { break }
            // Cancel any pending gap timer and stop thinking tone — real audio is arriving.
            audioGapTask?.cancel()
            audioGapTask = nil
            Task { await ThinkingToneService.shared.stop() }
            if pendingSessionId != nil {
                pendingAudioChunks.append((data: payload.data, sequence: payload.sequence))
                break
            }
            print("[TTS][relay] audio_chunk seq=\(payload.sequence) (\(payload.data.count) b64 chars)")
            Task { await audio.player.enqueue(data: payload.data, sequence: payload.sequence) }
            // Start gap timer: if no chunk arrives within 300 ms, re-arm the thinking tone.
            audioGapTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                audioGapTask = nil
                Task { await ThinkingToneService.shared.start() }
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
            }

        case .transcription(let payload):
            print("[STT] transcription received: \"\(payload.text)\"")
            if isLiveMode {
                ChimeGenerator.play()
                HapticService.impact(.light)
            }
            let msg = Message(role: .user, textContent: payload.text)
            if isInSession {
                sessionMessages.append(msg)
            } else {
                lobbyMessages.append(msg)
            }

        case .error(let payload):
            print("[Relay] Server error: \(payload.message)")
        }
    }
}
