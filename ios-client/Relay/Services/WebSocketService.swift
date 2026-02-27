import Foundation

actor WebSocketService {
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<WebSocketEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var isConnected = false

    /// Stream of decoded server events. Consumers iterate with `for await`.
    var events: AsyncStream<WebSocketEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func connect(token: String) {
        disconnect()

        let urlString = "\(AppConfig.wsBase)/v1/lobby?token=\(token)"
        guard let url = URL(string: urlString) else {
            print("[WS] Invalid URL: \(urlString)")
            return
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()
        task = wsTask
        isConnected = true
        print("[WS] Connecting to \(AppConfig.wsBase)/v1/lobby")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() {
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
        print("[WS] Disconnected")
    }

    func send(_ event: ClientEvent) async throws {
        guard let task, isConnected else {
            throw WebSocketError.notConnected
        }
        guard let json = event.toJSON() else {
            throw WebSocketError.encodingFailed
        }
        try await task.send(.string(json))
    }

    // MARK: - Private

    private func receiveLoop() async {
        guard let task else { return }

        while !Task.isCancelled && isConnected {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    if let event = WebSocketEvent.decode(from: text) {
                        continuation?.yield(event)
                    }
                case .data(let data):
                    if let event = WebSocketEvent.decode(from: data) {
                        continuation?.yield(event)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    print("[WS] Receive error: \(error)")
                    isConnected = false
                    continuation?.finish()
                }
                break
            }
        }
    }

    enum WebSocketError: Error {
        case notConnected
        case encodingFailed
    }
}
