import AVFoundation
import Foundation
import MuesliCore

enum MeetingRecordingFileFormat: String, CaseIterable, Sendable {
    case m4a
    case wav

    var displayName: String {
        switch self {
        case .m4a:
            return "M4A (AAC, smaller)"
        case .wav:
            return "WAV (lossless)"
        }
    }

    var fileExtension: String {
        switch self {
        case .m4a:
            return "m4a"
        case .wav:
            return "wav"
        }
    }

    static func resolved(_ rawValue: String?) -> MeetingRecordingFileFormat {
        guard let rawValue, let format = MeetingRecordingFileFormat(rawValue: rawValue) else {
            return .m4a
        }
        return format
    }
}

enum MeetingRecordingStorage {
    private static let defaultDirectoryName = "meeting-recordings"

    static func defaultDirectory(supportDirectory: URL = AppIdentity.supportDirectoryURL) -> URL {
        supportDirectory.appendingPathComponent(defaultDirectoryName, isDirectory: true)
    }

    static func directory(
        config: AppConfig,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) -> URL {
        let configuredPath = config.meetingRecordingFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredPath.isEmpty else {
            return defaultDirectory(supportDirectory: supportDirectory)
        }
        return URL(fileURLWithPath: configuredPath, isDirectory: true).standardizedFileURL
    }

    static func persistTemporaryRecording(
        from tempWAVURL: URL,
        meetingTitle: String,
        startedAt: Date,
        config: AppConfig,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) throws -> URL {
        try persistTemporaryRecording(
            from: tempWAVURL,
            meetingTitle: meetingTitle,
            startedAt: startedAt,
            destinationDirectory: directory(config: config, supportDirectory: supportDirectory),
            fileFormat: config.resolvedMeetingRecordingFileFormat
        )
    }

    static func persistTemporaryRecording(
        from tempWAVURL: URL,
        meetingTitle: String,
        startedAt: Date,
        destinationDirectory: URL,
        fileFormat: MeetingRecordingFileFormat = .m4a
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = destinationDirectory.appendingPathComponent(
            "\(fileNamePrefix(for: startedAt, title: meetingTitle)).\(fileFormat.fileExtension)"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        if fileFormat == .wav {
            try FileManager.default.moveItem(at: tempWAVURL, to: destinationURL)
            return destinationURL
        }

        do {
            try encodeWAVToM4A(sourceURL: tempWAVURL, destinationURL: destinationURL)
            try? FileManager.default.removeItem(at: tempWAVURL)
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    static func persistTemporaryRecordingAsync(
        from tempWAVURL: URL,
        meetingTitle: String,
        startedAt: Date,
        config: AppConfig,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) async throws -> URL {
        try await persistTemporaryRecordingAsync(
            from: tempWAVURL,
            meetingTitle: meetingTitle,
            startedAt: startedAt,
            destinationDirectory: directory(config: config, supportDirectory: supportDirectory),
            fileFormat: config.resolvedMeetingRecordingFileFormat
        )
    }

    static func persistTemporaryRecordingAsync(
        from tempWAVURL: URL,
        meetingTitle: String,
        startedAt: Date,
        destinationDirectory: URL,
        fileFormat: MeetingRecordingFileFormat = .m4a
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try persistTemporaryRecording(
                from: tempWAVURL,
                meetingTitle: meetingTitle,
                startedAt: startedAt,
                destinationDirectory: destinationDirectory,
                fileFormat: fileFormat
            )
        }.value
    }

    static func temporaryWAVForTranscription(from savedRecordingURL: URL) async throws -> URL {
        let (wavURL, _) = try await AudioFileImportController.convertToWAV(sourceURL: savedRecordingURL)
        return wavURL
    }

    @discardableResult
    static func migrateLegacyWAVRecordings(
        store: DictationStore,
        recordingsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> (migrated: Int, deletedOrphanStubs: Int) {
        var migrated = 0
        for candidate in try store.legacyWAVMeetingRecordingPaths() {
            if Task.isCancelled { break }
            let sourceURL = URL(fileURLWithPath: candidate.path).standardizedFileURL
            guard sourceURL.pathExtension.lowercased() == "wav",
                  fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard fileSize >= 1024 else { continue }

            let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")
            let temporaryURL = sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).migrating")
            do {
                try? fileManager.removeItem(at: temporaryURL)
                try encodeWAVToM4A(sourceURL: sourceURL, destinationURL: temporaryURL)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                try store.updateMeetingSavedRecordingPath(id: candidate.id, path: destinationURL.path)
                try fileManager.removeItem(at: sourceURL)
                migrated += 1
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                fputs("[meeting-recording-storage] failed to migrate legacy wav \(sourceURL.path): \(error)\n", stderr)
            }
        }

        let deletedOrphanStubs = try deleteOrphanedWAVStubs(
            in: recordingsDirectory,
            store: store,
            fileManager: fileManager
        )
        return (migrated, deletedOrphanStubs)
    }

    private static func encodeWAVToM4A(sourceURL: URL, destinationURL: URL) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let outputFile = try AVAudioFile(forWriting: destinationURL, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16_384) else {
            throw NSError(
                domain: "MeetingRecordingStorage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio conversion buffer."]
            )
        }

        while inputFile.framePosition < inputFile.length {
            let remainingFrames = AVAudioFrameCount(inputFile.length - inputFile.framePosition)
            let framesToRead = min(buffer.frameCapacity, remainingFrames)
            try inputFile.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
        }
    }

    private static func deleteOrphanedWAVStubs(
        in recordingsDirectory: URL,
        store: DictationStore,
        fileManager: FileManager
    ) throws -> Int {
        guard fileManager.fileExists(atPath: recordingsDirectory.path) else { return 0 }
        let files = try fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var deleted = 0
        for file in files where file.pathExtension.lowercased() == "wav" {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) < 1024,
                  try store.savedRecordingReferenceCount(path: file.path) == 0 else { continue }
            try fileManager.removeItem(at: file)
            deleted += 1
        }
        return deleted
    }

    private static func fileNamePrefix(for date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let normalized = title.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let slug = normalized
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .joined(separator: "-")
            .lowercased()

        return slug.isEmpty ? timestamp : "\(timestamp)-\(slug)"
    }
}
