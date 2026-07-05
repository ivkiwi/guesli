import Foundation

enum MeetingRecordingStorage {
    private static let directoryName = "meeting-recordings"

    static func defaultDirectory(supportDirectory: URL = AppIdentity.supportDirectoryURL) -> URL {
        supportDirectory.appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    static func directory(
        config: AppConfig,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) -> URL {
        let path = config.meetingRecordingFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return defaultDirectory(supportDirectory: supportDirectory)
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func resolvedFileURL(
        forStoredPath storedPath: String,
        config: AppConfig,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmedPath = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let storedURL = URL(fileURLWithPath: trimmedPath).standardizedFileURL
        if fileManager.fileExists(atPath: storedURL.path) {
            return storedURL
        }

        let configuredURL = directory(config: config, supportDirectory: supportDirectory)
            .appendingPathComponent(storedURL.lastPathComponent)
            .standardizedFileURL
        if configuredURL.path != storedURL.path,
           fileManager.fileExists(atPath: configuredURL.path) {
            return configuredURL
        }

        return nil
    }

    static func validateWritableDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        let directoryURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: "MeetingRecordingStorage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose an existing folder."]
            )
        }
        guard fileManager.isWritableFile(atPath: directoryURL.path) else {
            throw NSError(
                domain: "MeetingRecordingStorage",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Muesli cannot write to this folder."]
            )
        }

        let probeURL = directoryURL.appendingPathComponent(".muesli-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probeURL, options: .withoutOverwriting)
            try? fileManager.removeItem(at: probeURL)
        } catch {
            try? fileManager.removeItem(at: probeURL)
            throw NSError(
                domain: "MeetingRecordingStorage",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Muesli cannot write to this folder. \(error.localizedDescription)"]
            )
        }
    }
}
