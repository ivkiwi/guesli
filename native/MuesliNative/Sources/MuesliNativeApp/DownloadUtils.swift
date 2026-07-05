import Foundation

enum DownloadError: Error, LocalizedError {
    case httpError(Int, String)
    case retriesExhausted(String, Error)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let path):
            return "HTTP \(code) downloading \(path)"
        case .retriesExhausted(let path, let underlying):
            return "Failed to download \(path) after retries: \(underlying.localizedDescription)"
        }
    }
}

/// Download a file with HTTP status validation, retry with exponential backoff,
/// and cleanup of partial files on failure.
func downloadWithRetry(
    from url: URL,
    to destination: URL,
    maxRetries: Int = 3,
    session: URLSession = .shared,
    progressHandler: ((Double) -> Void)? = nil
) async throws {
    var lastError: Error?
    for attempt in 0..<maxRetries {
        if attempt > 0 {
            let delay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            fputs("[download] retry \(attempt)/\(maxRetries) for \(url.lastPathComponent)\n", stderr)
        }
        do {
            try Task.checkCancellation()
            let (tempURL, response) = try await downloadTemporaryFile(
                from: url,
                session: session,
                progressHandler: progressHandler
            )
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                try? FileManager.default.removeItem(at: tempURL)
                throw DownloadError.httpError(code, url.lastPathComponent)
            }
            try moveDownloadedTemporaryFile(tempURL, to: destination)
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }
    }
    let underlying = lastError ?? NSError(domain: "DownloadError", code: 0, userInfo: [
        NSLocalizedDescriptionKey: "No download attempts were made",
    ])
    throw DownloadError.retriesExhausted(url.lastPathComponent, underlying)
}

func moveDownloadedTemporaryFile(_ tempURL: URL, to destination: URL) throws {
    var movedToDestination = false
    defer {
        if !movedToDestination {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: tempURL, to: destination)
    movedToDestination = true
}

private func downloadTemporaryFile(
    from url: URL,
    session: URLSession,
    progressHandler: ((Double) -> Void)?
) async throws -> (URL, URLResponse) {
    guard let progressHandler else {
        return try await session.download(from: url)
    }

    let delegate = ProgressDownloadDelegate(onProgress: progressHandler)
    let progressSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
    let invalidator = DownloadSessionInvalidator()
    do {
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                delegate.setContinuation(continuation)
                progressSession.downloadTask(with: url).resume()
            }
        } onCancel: {
            invalidator.cancel(progressSession)
        }
        invalidator.finish(progressSession)
        return result
    } catch {
        if error is CancellationError {
            invalidator.cancel(progressSession)
        } else {
            invalidator.finish(progressSession)
        }
        throw error
    }
}

private final class DownloadSessionInvalidator: @unchecked Sendable {
    private let lock = NSLock()
    private var didInvalidate = false

    func finish(_ session: URLSession) {
        invalidate(session, action: { $0.finishTasksAndInvalidate() })
    }

    func cancel(_ session: URLSession) {
        invalidate(session, action: { $0.invalidateAndCancel() })
    }

    private func invalidate(_ session: URLSession, action: (URLSession) -> Void) {
        lock.lock()
        guard !didInvalidate else {
            lock.unlock()
            return
        }
        didInvalidate = true
        lock.unlock()
        action(session)
    }
}

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func setContinuation(_ c: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock()
        defer { lock.unlock() }
        continuation = c
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        var movedURL: URL?
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + downloadTask.originalRequestURLLastPathComponent)
            try FileManager.default.moveItem(at: location, to: destination)
            movedURL = destination
            guard let response = downloadTask.response else {
                throw URLError(.badServerResponse)
            }
            resumeOnce(.success((destination, response)))
        } catch {
            if let movedURL { try? FileManager.default.removeItem(at: movedURL) }
            resumeOnce(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        resumeOnce(.failure(error))
    }

    private func resumeOnce(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private extension URLSessionDownloadTask {
    var originalRequestURLLastPathComponent: String {
        originalRequest?.url?.lastPathComponent.nonEmpty ?? "download.tmp"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
