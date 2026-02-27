import Speech

actor SpeechRecognitionService {
    private var isAuthorized = false

    func transcribe(url: URL) async throws -> String {
        if !isAuthorized {
            try await requestAuthorization()
        }

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SpeechError.unavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    private func requestAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch status {
        case .authorized:
            isAuthorized = true
        case .denied:
            throw SpeechError.denied
        case .restricted:
            throw SpeechError.restricted
        case .notDetermined:
            throw SpeechError.denied
        @unknown default:
            throw SpeechError.denied
        }
    }

    enum SpeechError: LocalizedError {
        case unavailable, denied, restricted

        var errorDescription: String? {
            switch self {
            case .unavailable: "Speech recognition is not available on this device."
            case .denied: "Speech recognition permission was denied."
            case .restricted: "Speech recognition is restricted on this device."
            }
        }
    }
}
