import ActivityKit
import Foundation

@Observable
@MainActor
final class RelayViewModel {
    // MARK: - Published state

    var connected = false
    var activeSessionId: String?
    var activeAgentName: String?
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

    var useLocalStt: Bool {
        UserDefaults.standard.string(forKey: "stt_local_provider") == "apple"
    }

    init(authService: AuthService) {
        self.authService = authService
        self.apiClient = APIClient(authService: authService)

        // Wire audio recording completion → send audio or transcribe locally
        audio.setup { [weak self] base64, format, fileURL in
            await self?.handleRecordingComplete(base64: base64, format: format, fileURL: fileURL)
        }
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
        lobbyMessages = []
        sessionMessages = []
        sessions = []
        status = "idle"
        activeSpeaker = "operator"
    }

    // MARK: - Actions

    func sendMessage(_ text: String) async {
        ChimeGenerator.play()

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

                await MainActor.run {
                    ChimeGenerator.play()
                    HapticService.impact(.light)
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
        audio.startListening()
        startLiveActivity()
    }

    func exitLiveMode() {
        isLiveMode = false
        audio.stopListening()
        audio.stopAudio()
        endLiveActivity()
        Task { await SilentKeepAlive.shared.stop() }
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

    private func fetchPlatformSettings() async {
        do {
            let settings: PlatformSettings = try await apiClient.request("GET", path: "/v1/platform/settings")
            sttSettings = settings

            // Apply STT settings to recorder
            audio.updateSettings(
                silenceThresholdDb: Float(settings.sttSilenceThresholdDb),
                silenceTimeoutMs: settings.sttSilenceTimeoutMs,
                minDurationMs: settings.sttMinDurationMs
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

        case .text(let payload):
            let role: Message.MessageRole = payload.speaker == "operator" ? .operator : .agent
            let msg = Message(role: role, textContent: payload.text)
            if activeSessionId != nil {
                sessionMessages.append(msg)
            } else {
                lobbyMessages.append(msg)
            }

        case .handoff(let payload):
            if payload.playEarcon {
                HapticService.notification(.success)
            }

        case .sessionEntered(let payload):
            if isLiveMode {
                // Let the operator's audio finish before swapping to the session
                Task {
                    await audio.player.waitUntilFinished()
                    activeSessionId = payload.sessionId
                    activeAgentName = payload.agentName
                    sessionMessages = []
                    audio.handleSessionChange(newSessionId: payload.sessionId)
                    updateLiveActivity()
                    await fetchSessions()
                }
            } else {
                activeSessionId = payload.sessionId
                activeAgentName = payload.agentName
                sessionMessages = []
                audio.handleSessionChange(newSessionId: payload.sessionId)
                Task { await fetchSessions() }
            }

        case .sessionLeft:
            audio.stopAudio()
            let oldSessionId = activeSessionId
            activeSessionId = nil
            activeAgentName = nil
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

        case .textStart(let payload):
            guard activeSessionId != nil else { break }
            let role: Message.MessageRole = payload.speaker == "operator" ? .operator : .agent
            sessionMessages.append(Message(role: role, textContent: "", isStreaming: true))

        case .textDelta(let payload):
            guard activeSessionId != nil, !sessionMessages.isEmpty else { break }
            let lastIdx = sessionMessages.count - 1
            if sessionMessages[lastIdx].isStreaming {
                sessionMessages[lastIdx].textContent += payload.delta
            }

        case .textDone(let payload):
            guard activeSessionId != nil, !sessionMessages.isEmpty else { break }
            let lastIdx = sessionMessages.count - 1
            if sessionMessages[lastIdx].isStreaming {
                sessionMessages[lastIdx].textContent = payload.text
                sessionMessages[lastIdx].isStreaming = false
            }

        case .audioStart(let payload):
            guard isLiveMode else { break }
            print("[TTS][relay] audio_start from \(payload.speaker)")
            Task { await audio.player.start() }

        case .audioChunk(let payload):
            guard isLiveMode else { break }
            print("[TTS][relay] audio_chunk seq=\(payload.sequence) (\(payload.data.count) b64 chars)")
            Task { await audio.player.enqueue(data: payload.data, sequence: payload.sequence) }

        case .audioDone(let payload):
            guard isLiveMode else { break }
            print("[TTS][relay] audio_done from \(payload.speaker)")
            Task { await audio.player.done() }

        case .transcription(let payload):
            print("[STT] transcription received: \"\(payload.text)\"")
            ChimeGenerator.play()
            HapticService.impact(.light)
            let msg = Message(role: .user, textContent: payload.text)
            if activeSessionId != nil {
                sessionMessages.append(msg)
            } else {
                lobbyMessages.append(msg)
            }

        case .error(let payload):
            print("[Relay] Server error: \(payload.message)")
        }
    }
}
