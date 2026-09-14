import Foundation

/// Progress-aware, cancellable upload primitive. Wraps
/// `URLSessionUploadTask` + a task delegate so callers get live
/// `bytesSent / totalBytesExpectedToSend` events plus a `cancel()`
/// handle. Used by both attachment paths (chat FormData POST and
/// file-browser raw PUT) so a single upload registry can drive
/// progress UI regardless of origin.
///
/// Kept out of `APIClient` because that's an `actor` and the delegate
/// callbacks arrive on URLSession's own delegate queue — a per-task
/// NSObject delegate is a cleaner fit than routing through the actor.
final class ProgressiveUpload: NSObject, URLSessionTaskDelegate,
                               URLSessionDataDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var responseData = Data()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionUploadTask?
    private var session: URLSession?

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    /// Kick off the upload and await the response. Body is either the
    /// multipart bytes (chat POST) or the raw file bytes (browser PUT).
    /// `contentType` should be set for raw-body uploads; multipart
    /// callers set it in the request themselves so the delegate
    /// doesn't have to know the difference.
    func upload(
        request: URLRequest, from body: Data,
    ) async throws -> (Data, HTTPURLResponse) {
        // Fresh session per upload so `invalidateAndCancel` in cancel()
        // doesn't take out other in-flight uploads that happen to share
        // a shared session's delegate queue.
        let cfg = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let task = session.uploadTask(with: request, from: body)
            self.task = task
            task.resume()
        }
    }

    /// Cancel the in-flight upload. Rejects the pending
    /// `withCheckedThrowingContinuation` with `CancellationError`.
    func cancel() {
        task?.cancel()
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64,
    ) {
        // `-1` means "unknown" (streamed body). Skip so we don't feed
        // the UI with a nonsense total.
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: Error?,
    ) {
        defer {
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            continuation?.resume(throwing: URLError(.badServerResponse))
            continuation = nil
            return
        }
        continuation?.resume(returning: (responseData, http))
        continuation = nil
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data,
    ) {
        responseData.append(data)
    }
}
