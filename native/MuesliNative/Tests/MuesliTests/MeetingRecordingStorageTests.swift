import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingRecordingStorage")
struct MeetingRecordingStorageTests {
    @Test("default directory uses support meeting-recordings folder")
    func defaultDirectoryUsesSupportFolder() {
        let supportDirectory = temporaryDirectory()

        let directory = MeetingRecordingStorage.directory(
            config: AppConfig(),
            supportDirectory: supportDirectory
        )

        #expect(directory.path == supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true).path)
    }

    @Test("custom directory uses configured absolute path")
    func customDirectoryUsesConfiguredPath() {
        let supportDirectory = temporaryDirectory()
        let customDirectory = temporaryDirectory()
        var config = AppConfig()
        config.meetingRecordingFolderPath = customDirectory.path

        let directory = MeetingRecordingStorage.directory(
            config: config,
            supportDirectory: supportDirectory
        )

        #expect(directory.path == customDirectory.standardizedFileURL.path)
    }

    @Test("relative custom directory falls back to default")
    func relativeCustomDirectoryFallsBackToDefault() {
        let supportDirectory = temporaryDirectory()
        var config = AppConfig()
        config.meetingRecordingFolderPath = "relative-recordings"

        let directory = MeetingRecordingStorage.directory(
            config: config,
            supportDirectory: supportDirectory
        )

        #expect(directory.path == MeetingRecordingStorage.defaultDirectory(supportDirectory: supportDirectory).path)
    }

    @Test("resolver keeps existing stored absolute path when custom folder is configured")
    func resolverKeepsExistingStoredPath() throws {
        let supportDirectory = temporaryDirectory()
        let customDirectory = temporaryDirectory()
        let oldDirectory = MeetingRecordingStorage.defaultDirectory(supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldRecording = oldDirectory.appendingPathComponent("meeting.wav")
        try Data("old".utf8).write(to: oldRecording)
        var config = AppConfig()
        config.meetingRecordingFolderPath = customDirectory.path

        let resolved = MeetingRecordingStorage.resolvedFileURL(
            forStoredPath: oldRecording.path,
            config: config,
            supportDirectory: supportDirectory
        )

        #expect(resolved?.path == oldRecording.standardizedFileURL.path)
    }

    @Test("resolver falls back to configured folder by filename when stored path is missing")
    func resolverFallsBackToConfiguredFolderByFilename() throws {
        let supportDirectory = temporaryDirectory()
        let customDirectory = temporaryDirectory()
        let storedPath = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
            .appendingPathComponent("meeting.wav")
            .path
        let movedRecording = customDirectory.appendingPathComponent("meeting.wav")
        try Data("moved".utf8).write(to: movedRecording)
        var config = AppConfig()
        config.meetingRecordingFolderPath = customDirectory.path

        let resolved = MeetingRecordingStorage.resolvedFileURL(
            forStoredPath: storedPath,
            config: config,
            supportDirectory: supportDirectory
        )

        #expect(resolved?.path == movedRecording.standardizedFileURL.path)
    }

    @Test("validateWritableDirectory accepts writable directories and cleans probe")
    func validateWritableDirectoryAcceptsWritableDirectory() throws {
        let directory = temporaryDirectory()
        let probeFileName = ".probe-\(UUID().uuidString)"

        try MeetingRecordingStorage.validateWritableDirectory(directory, probeFileName: probeFileName)

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(probeFileName).path) == false)
    }

    @Test("validateWritableDirectory rejects missing paths and files")
    func validateWritableDirectoryRejectsMissingPathsAndFiles() throws {
        let directory = temporaryDirectory()
        let missingDirectory = directory.appendingPathComponent("missing", isDirectory: true)
        let fileURL = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: fileURL)

        #expect(validationErrorCode(for: missingDirectory) == 1)
        #expect(validationErrorCode(for: fileURL) == 1)
    }

    @Test("validateWritableDirectory rejects unwritable directories and probe failures")
    func validateWritableDirectoryRejectsWriteFailures() throws {
        let unwritableDirectory = temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unwritableDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritableDirectory.path)
        }
        #expect(validationErrorCode(for: unwritableDirectory) == 2)

        let probeConflictDirectory = temporaryDirectory()
        let probeFileName = ".probe-\(UUID().uuidString)"
        try Data("exists".utf8).write(to: probeConflictDirectory.appendingPathComponent(probeFileName))

        #expect(validationErrorCode(for: probeConflictDirectory, probeFileName: probeFileName) == 3)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func validationErrorCode(for url: URL, probeFileName: String? = nil) -> Int? {
        do {
            if let probeFileName {
                try MeetingRecordingStorage.validateWritableDirectory(url, probeFileName: probeFileName)
            } else {
                try MeetingRecordingStorage.validateWritableDirectory(url)
            }
            return nil
        } catch {
            return (error as NSError).code
        }
    }
}
