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

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
