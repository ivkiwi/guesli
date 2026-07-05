import Foundation

struct AuthTokenFileStore {
    let primaryURL: URL
    let logPrefix: String
    var fileManager: FileManager = .default
    var logger: (String) -> Void = { DiagnosticsLog.write($0) }

    var backupURL: URL { Self.backupURL(for: primaryURL) }
    var signedOutURL: URL { Self.signedOutURL(for: primaryURL) }

    func save(_ tokens: [String: String], reason: String) throws {
        let data = try JSONSerialization.data(withJSONObject: tokens, options: .prettyPrinted)
        try save(data, reason: reason)
    }

    func save(_ data: Data, reason: String) throws {
        let dir = primaryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(data, to: primaryURL, reason: reason)
        try write(data, to: backupURL, reason: reason)
        removeIfExists(signedOutURL, reason: reason)
    }

    func load() -> [String: String]? {
        restorePrimaryFromBackupIfNeeded()
        try? Self.secureFilePermissions(at: primaryURL, fileManager: fileManager)
        guard let data = try? Data(contentsOf: primaryURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict
    }

    func signOut() {
        removeIfExists(signedOutURL, reason: "sign-out")
        if fileManager.fileExists(atPath: primaryURL.path) {
            move(primaryURL, to: signedOutURL, reason: "sign-out")
        } else if fileManager.fileExists(atPath: backupURL.path) {
            move(backupURL, to: signedOutURL, reason: "sign-out")
        }
        removeIfExists(backupURL, reason: "sign-out")
    }

    static func backupURL(for primaryURL: URL) -> URL {
        siblingURL(for: primaryURL, suffix: ".backup")
    }

    static func signedOutURL(for primaryURL: URL) -> URL {
        siblingURL(for: primaryURL, suffix: ".signed-out")
    }

    static func hasRecoverableTokenFile(primaryURL: URL, fileManager: FileManager = .default) -> Bool {
        isValidTokenFile(at: primaryURL) || isValidTokenFile(at: backupURL(for: primaryURL))
    }

    static func secureFilePermissions(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions != 0o600 else { return }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func write(_ data: Data, to url: URL, reason: String) throws {
        try data.write(to: url, options: .atomic)
        try Self.secureFilePermissions(at: url, fileManager: fileManager)
        try excludeFromBackup(url)
        log("wrote \(url.lastPathComponent) reason=\(reason)")
    }

    private func restorePrimaryFromBackupIfNeeded() {
        guard !fileManager.fileExists(atPath: primaryURL.path),
              fileManager.fileExists(atPath: backupURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: backupURL)
            try write(data, to: primaryURL, reason: "restore")
            log("restored tokens from backup reason=restore")
        } catch {
            log("failed to restore tokens from backup reason=restore error=\(error)")
        }
    }

    private func move(_ sourceURL: URL, to destinationURL: URL, reason: String) {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            try Self.secureFilePermissions(at: destinationURL, fileManager: fileManager)
            try excludeFromBackup(destinationURL)
            log("renamed \(sourceURL.lastPathComponent) to \(destinationURL.lastPathComponent) reason=\(reason)")
        } catch {
            log("failed to rename \(sourceURL.lastPathComponent) to \(destinationURL.lastPathComponent) reason=\(reason) error=\(error)")
        }
    }

    private func removeIfExists(_ url: URL, reason: String) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
            log("deleted \(url.lastPathComponent) reason=\(reason)")
        } catch {
            log("failed to delete \(url.lastPathComponent) reason=\(reason) error=\(error)")
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var fileURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try fileURL.setResourceValues(resourceValues)
    }

    private func log(_ message: String) {
        logger("[\(logPrefix)] \(message)")
    }

    private static func isValidTokenFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let accessToken = dict["access_token"],
              !accessToken.isEmpty else {
            return false
        }
        return true
    }

    private static func siblingURL(for url: URL, suffix: String) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        let fileName = pathExtension.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(pathExtension)"
        return url.deletingLastPathComponent().appendingPathComponent(fileName)
    }
}
