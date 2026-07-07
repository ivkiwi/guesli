import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("AppTemporaryDirectories", .muesliHermeticSupport)
struct AppTemporaryDirectoriesTests {
    @Test("launch sweep covers app temp dirs and skips dead retranscription dir")
    func launchSweepDirectoryListCoversAppTempDirs() {
        let names = Set(AppTemporaryDirectories.launchSweepDirectoryNames)
        let requiredNames: Set<String> = [
            "muesli-system-audio",
            "muesli-meeting-recordings",
            "muesli-native",
            "muesli-import",
            "muesli-wav-temp",
            "muesli-meeting-mic",
            "muesli-meeting-mic-audioqueue",
            "muesli-meeting-mic-app-scoped-fallback",
            "muesli-meeting-mic-chunks",
            "muesli-meeting-system-chunks",
            "muesli-meeting-mic-repair",
            "muesli-native-dictation",
            "muesli-native-dictation-streaming",
        ]

        #expect(requiredNames.isSubset(of: names))
        #expect(!names.contains("guesli-retranscription"))
    }

    @Test("launch sweep removes only app temp entries older than the grace period")
    func launchSweepRemovesOnlyOldAppTempEntries() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("muesli-temp-sweep-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 10_000)
        let oldDate = now.addingTimeInterval(-7_200)
        let freshDate = now.addingTimeInterval(-60)
        var oldURLs: [URL] = []
        var protectedOldMeetingRecordingURLs: [URL] = []
        var freshURLs: [URL] = []

        for directoryName in AppTemporaryDirectories.launchSweepDirectoryNames {
            let directory = AppTemporaryDirectories.url(named: directoryName, temporaryDirectory: root)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let oldURL = directory.appendingPathComponent("old.wav")
            let freshURL = directory.appendingPathComponent("fresh.wav")
            try Data([1]).write(to: oldURL)
            try Data([2]).write(to: freshURL)
            try setModificationDate(oldDate, for: oldURL)
            try setModificationDate(freshDate, for: freshURL)
            if directoryName == AppTemporaryDirectories.meetingRecordings {
                protectedOldMeetingRecordingURLs.append(oldURL)
            } else {
                oldURLs.append(oldURL)
            }
            freshURLs.append(freshURL)
        }

        let oldLegacyDirectory = root.appendingPathComponent(
            AppTemporaryDirectories.legacyImportDirectoryName(),
            isDirectory: true
        )
        let freshLegacyDirectory = root.appendingPathComponent(
            AppTemporaryDirectories.legacyImportDirectoryName(),
            isDirectory: true
        )
        try fileManager.createDirectory(at: oldLegacyDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: freshLegacyDirectory, withIntermediateDirectories: true)
        try setModificationDate(oldDate, for: oldLegacyDirectory)
        try setModificationDate(freshDate, for: freshLegacyDirectory)

        let unownedDirectory = root.appendingPathComponent("muesli-unowned", isDirectory: true)
        try fileManager.createDirectory(at: unownedDirectory, withIntermediateDirectories: true)
        let unownedOldURL = unownedDirectory.appendingPathComponent("old.wav")
        try Data([3]).write(to: unownedOldURL)
        try setModificationDate(oldDate, for: unownedOldURL)

        let result = AppTemporaryDirectories.sweepAtLaunch(
            fileManager: fileManager,
            temporaryDirectory: root,
            now: now,
            logger: nil
        )

        #expect(result.removedEntryCount == oldURLs.count + 1)
        for oldURL in oldURLs {
            #expect(!fileManager.fileExists(atPath: oldURL.path))
        }
        for protectedURL in protectedOldMeetingRecordingURLs {
            #expect(fileManager.fileExists(atPath: protectedURL.path))
        }
        for freshURL in freshURLs {
            #expect(fileManager.fileExists(atPath: freshURL.path))
        }
        #expect(!fileManager.fileExists(atPath: oldLegacyDirectory.path))
        #expect(fileManager.fileExists(atPath: freshLegacyDirectory.path))
        #expect(fileManager.fileExists(atPath: unownedOldURL.path))
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

@Suite("RecordingWaveformCacheFiles", .muesliHermeticSupport)
struct RecordingWaveformCacheFilesTests {
    @Test("stale sweep removes old waveform files only")
    func staleSweepRemovesOldWaveformFilesOnly() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("muesli-waveform-cache-tests-\(UUID().uuidString)", isDirectory: true)
        let supportDirectory = root.appendingPathComponent("Guesli", isDirectory: true)
        let cacheDirectory = RecordingWaveformCacheFiles.cacheDirectory(supportDirectory: supportDirectory)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 20_000)
        let oldDate = now.addingTimeInterval(-7_200)
        let freshDate = now.addingTimeInterval(-60)
        let oldWaveform = cacheDirectory.appendingPathComponent("old.mwf")
        let freshWaveform = cacheDirectory.appendingPathComponent("fresh.mwf")
        let oldNonCache = cacheDirectory.appendingPathComponent("old.txt")
        try Data([1]).write(to: oldWaveform)
        try Data([2]).write(to: freshWaveform)
        try Data([3]).write(to: oldNonCache)
        try setModificationDate(oldDate, for: oldWaveform)
        try setModificationDate(freshDate, for: freshWaveform)
        try setModificationDate(oldDate, for: oldNonCache)

        let removed = RecordingWaveformCacheFiles.sweepStaleCachedWaveforms(
            supportDirectory: supportDirectory,
            now: now,
            maximumAge: 3_600,
            logger: nil
        )

        #expect(removed == 1)
        #expect(!fileManager.fileExists(atPath: oldWaveform.path))
        #expect(fileManager.fileExists(atPath: freshWaveform.path))
        #expect(fileManager.fileExists(atPath: oldNonCache.path))
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
