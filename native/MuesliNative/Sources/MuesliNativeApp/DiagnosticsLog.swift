import Foundation

enum DiagnosticsLog {
    static let defaultMaxBytes: UInt64 = 2 * 1024 * 1024

    private static let lock = NSLock()

    static var defaultURL: URL {
        if let rawURL = ProcessInfo.processInfo.environment["MUESLI_DIAGNOSTICS_LOG_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty {
            return URL(fileURLWithPath: rawURL)
        }
        return AppIdentity.supportDirectoryURL.appendingPathComponent("diagnostics.log")
    }

    static func write(_ message: @autoclosure () -> String) {
        let line = normalized(message())
        fputs("\(line)\n", stderr)
        append(line, to: defaultURL)
    }

    static func append(
        _ message: String,
        to fileURL: URL,
        maxBytes: UInt64 = defaultMaxBytes,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try appendLocked(
                normalized(message),
                to: fileURL,
                maxBytes: maxBytes,
                date: date,
                fileManager: fileManager
            )
        } catch {
            fputs("[diagnostics-log] failed to append diagnostics log: \(error)\n", stderr)
        }
    }

    private static func appendLocked(
        _ message: String,
        to fileURL: URL,
        maxBytes: UInt64,
        date: Date,
        fileManager: FileManager
    ) throws {
        let data = Data("\(timestamp(date)) \(message)\n".utf8)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try rotateIfNeeded(
            fileURL,
            incomingByteCount: UInt64(data.count),
            maxBytes: maxBytes,
            fileManager: fileManager
        )

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try handle.write(contentsOf: data)
        } else {
            let didCreate = fileManager.createFile(
                atPath: fileURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
            if !didCreate {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        }
        try securePermissions(at: fileURL, fileManager: fileManager)
    }

    private static func rotateIfNeeded(
        _ fileURL: URL,
        incomingByteCount: UInt64,
        maxBytes: UInt64,
        fileManager: FileManager
    ) throws {
        guard maxBytes > 0,
              fileManager.fileExists(atPath: fileURL.path),
              currentSize(of: fileURL, fileManager: fileManager) + incomingByteCount > maxBytes else {
            return
        }

        let oldURL = fileURL.appendingPathExtension("old")
        if fileManager.fileExists(atPath: oldURL.path) {
            try fileManager.removeItem(at: oldURL)
        }
        try fileManager.moveItem(at: fileURL, to: oldURL)
        try securePermissions(at: oldURL, fileManager: fileManager)
    }

    private static func securePermissions(at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func currentSize(of url: URL, fileManager: FileManager) -> UInt64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func normalized(_ message: String) -> String {
        message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
