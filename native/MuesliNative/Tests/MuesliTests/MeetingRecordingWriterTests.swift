import AVFoundation
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("MeetingRecordingWriter")
struct MeetingRecordingWriterTests {

    @Test("streaming writer merges mic and system samples incrementally")
    func writerMergesIncrementally() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 2000, 3000, 4000])
        writer.appendSystem([3000, -2000])
        writer.appendSystem([500, 1500])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [2000, 0, 1750, 2750])
    }

    @Test("streaming writer flushes single-track tail on stop")
    func writerFlushesSingleTrackTail() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1200, -800, 400])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1200, -800, 400])
    }

    @Test("pause boundary prevents unmatched samples from mixing across pause")
    func pauseBoundaryFlushesPendingSamples() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 3000])
        writer.markPauseBoundary()
        writer.appendSystem([5000, 7000])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1000, 3000, 5000, 7000])
    }

    @Test("persistTemporaryRecording moves the temp wav when WAV is selected")
    func persistTemporaryRecordingMovesWAVFile() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem([1200, -800, 400])
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync! With Very Long Title Extra Words",
            startedAt: startedAt,
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync-with-very-long.wav"))
        #expect(try readMonoPCM16WAVSamples(from: savedURL) == [1200, -800, 400])
    }

    @Test("persistTemporaryRecording transcodes to M4A by default")
    func persistTemporaryRecordingTranscodesToM4AByDefault() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: Int16(1200), count: 16_000))
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.pathExtension == "m4a")
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync.m4a"))

        let file = try AVAudioFile(forReading: savedURL)
        #expect(file.length > 0)
    }

    @Test("legacy wav migration updates referenced recordings and removes orphan stubs")
    func legacyWAVMigrationUpdatesRecordingsAndDeletesOrphanStubs() async throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let legacyWAVURL = recordingsDirectory.appendingPathComponent("legacy.wav")
        let orphanStubURL = recordingsDirectory.appendingPathComponent("orphan.wav")
        let referencedStubURL = recordingsDirectory.appendingPathComponent("referenced-stub.wav")
        let strandedWAVURL = recordingsDirectory.appendingPathComponent("stranded.wav")
        let strandedM4AURL = recordingsDirectory.appendingPathComponent("stranded.m4a")
        let unrelatedWAVURL = recordingsDirectory.appendingPathComponent("unrelated.wav")
        try Data(repeating: 1, count: 2_048).write(to: legacyWAVURL)
        try Data([0]).write(to: orphanStubURL)
        try Data([1]).write(to: referencedStubURL)
        try Data(repeating: 2, count: 2_048).write(to: strandedWAVURL)
        try Data("m4a".utf8).write(to: strandedM4AURL)
        try Data(repeating: 3, count: 2_048).write(to: unrelatedWAVURL)

        let now = Date(timeIntervalSince1970: 1_711_000_000)
        let migratedID = try store.insertMeeting(
            title: "Legacy",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "legacy",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: legacyWAVURL.path
        )
        try store.insertMeeting(
            title: "Referenced Stub",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180),
            rawTranscript: "stub",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: referencedStubURL.path
        )

        let summary = try await MeetingRecordingWriter.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            encode: { sourceURL, destinationURL in
                #expect(sourceURL == legacyWAVURL.standardizedFileURL)
                #expect(destinationURL.pathExtension == "m4a")
                #expect(destinationURL.lastPathComponent.contains(".migrating"))
                try Data("m4a".utf8).write(to: destinationURL)
            }
        )

        let migrated = try #require(try store.meeting(id: migratedID))
        let migratedPath = try #require(migrated.savedRecordingPath)
        #expect(summary.migrated == 1)
        #expect(summary.deletedOrphanStubs == 2)
        #expect(migratedPath.hasSuffix(".m4a"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: migratedPath)) == Data("m4a".utf8))
        #expect(FileManager.default.fileExists(atPath: legacyWAVURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: orphanStubURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: referencedStubURL.path))
        #expect(FileManager.default.fileExists(atPath: strandedWAVURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: strandedM4AURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedWAVURL.path))

        let secondSummary = try await MeetingRecordingWriter.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            encode: { _, _ in
                Issue.record("Migration should be idempotent")
            }
        )
        #expect(secondSummary.migrated == 0)
        #expect(secondSummary.deletedOrphanStubs == 0)
        #expect(try store.meeting(id: migratedID)?.savedRecordingPath == migratedPath)
    }

    @Test("legacy wav orphan cleanup continues after one delete failure")
    func legacyWAVMigrationContinuesAfterOrphanDeleteFailure() async throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let legacyWAVURL = recordingsDirectory.appendingPathComponent("legacy.wav")
        let failedStubURL = recordingsDirectory.appendingPathComponent("failing-stub.wav")
        let smallStubURL = recordingsDirectory.appendingPathComponent("small-stub.wav")
        let migratedStubURL = recordingsDirectory.appendingPathComponent("migrated-stub.wav")
        let migratedSiblingURL = recordingsDirectory.appendingPathComponent("migrated-stub.m4a")
        try Data(repeating: 1, count: 2_048).write(to: legacyWAVURL)
        try Data([0]).write(to: failedStubURL)
        try Data([1]).write(to: smallStubURL)
        try Data(repeating: 2, count: 2_048).write(to: migratedStubURL)
        try Data("m4a".utf8).write(to: migratedSiblingURL)

        let now = Date(timeIntervalSince1970: 1_711_000_000)
        let meetingID = try store.insertMeeting(
            title: "Legacy",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "legacy",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: legacyWAVURL.path
        )
        let fileManager = StubDeleteFailureFileManager(failingURL: failedStubURL)

        let summary = try await MeetingRecordingWriter.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            fileManager: fileManager,
            encode: { _, destinationURL in
                try Data("m4a".utf8).write(to: destinationURL)
            }
        )

        let meeting = try #require(try store.meeting(id: meetingID))
        let migratedPath = try #require(meeting.savedRecordingPath)
        #expect(summary.migrated == 1)
        #expect(summary.deletedOrphanStubs == 2)
        #expect(migratedPath.hasSuffix(".m4a"))
        #expect(fileManager.failedRemoveAttempts == 1)
        #expect(FileManager.default.fileExists(atPath: legacyWAVURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: failedStubURL.path))
        #expect(FileManager.default.fileExists(atPath: smallStubURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: migratedStubURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: migratedSiblingURL.path))
    }

    @Test("legacy wav migration continues after one attributes failure")
    func legacyWAVMigrationContinuesAfterAttributesFailure() async throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let failedWAVURL = recordingsDirectory.appendingPathComponent("failed.wav")
        let migratedWAVURL = recordingsDirectory.appendingPathComponent("migrated.wav")
        try Data(repeating: 1, count: 2_048).write(to: failedWAVURL)
        try Data(repeating: 2, count: 2_048).write(to: migratedWAVURL)

        let now = Date(timeIntervalSince1970: 1_711_000_000)
        let failedID = try store.insertMeeting(
            title: "Failed",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "failed",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: failedWAVURL.path
        )
        let migratedID = try store.insertMeeting(
            title: "Migrated",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180),
            rawTranscript: "migrated",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: migratedWAVURL.path
        )
        let fileManager = StubAttributesFailureFileManager(failingURL: failedWAVURL)

        let summary = try await MeetingRecordingWriter.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            fileManager: fileManager,
            encode: { sourceURL, destinationURL in
                #expect(sourceURL == migratedWAVURL.standardizedFileURL)
                try Data("m4a".utf8).write(to: destinationURL)
            }
        )

        let failedMeeting = try #require(try store.meeting(id: failedID))
        let migratedMeeting = try #require(try store.meeting(id: migratedID))
        let migratedPath = try #require(migratedMeeting.savedRecordingPath)
        #expect(summary.migrated == 1)
        #expect(summary.deletedOrphanStubs == 0)
        #expect(fileManager.failedAttributesAttempts == 1)
        #expect(failedMeeting.savedRecordingPath == failedWAVURL.path)
        #expect(migratedPath.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: failedWAVURL.path))
        #expect(FileManager.default.fileExists(atPath: migratedWAVURL.path) == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: migratedPath)) == Data("m4a".utf8))
    }

    @Test("legacy wav migration deletes shared wav only after last reference migrates")
    func legacyWAVMigrationDeletesSharedWAVAfterLastReferenceMigrates() async throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let legacyWAVURL = recordingsDirectory.appendingPathComponent("shared.wav")
        try Data(repeating: 1, count: 2_048).write(to: legacyWAVURL)

        let now = Date(timeIntervalSince1970: 1_711_000_000)
        let firstID = try store.insertMeeting(
            title: "First",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "first",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: legacyWAVURL.path
        )
        let secondID = try store.insertMeeting(
            title: "Second",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180),
            rawTranscript: "second",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: legacyWAVURL.path
        )

        let summary = try await MeetingRecordingWriter.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            encode: { _, destinationURL in
                try Data("m4a".utf8).write(to: destinationURL)
            }
        )

        let firstPath = try #require(try store.meeting(id: firstID)?.savedRecordingPath)
        let secondPath = try #require(try store.meeting(id: secondID)?.savedRecordingPath)
        #expect(summary.migrated == 2)
        #expect(firstPath == secondPath)
        #expect(firstPath.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: firstPath))
        #expect(FileManager.default.fileExists(atPath: legacyWAVURL.path) == false)
    }

    @Test("legacy wav migration keeps raw-path shared wav until sibling migrates")
    func legacyWAVMigrationKeepsRawPathSharedWAVUntilSiblingMigrates() async throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let legacyWAVURL = recordingsDirectory.appendingPathComponent("shared.wav")
        let rawLegacyPath = recordingsDirectory.path + "/nested/../shared.wav"
        try Data(repeating: 1, count: 2_048).write(to: legacyWAVURL)

        #expect(rawLegacyPath != legacyWAVURL.path)
        #expect(URL(fileURLWithPath: rawLegacyPath).standardizedFileURL == legacyWAVURL.standardizedFileURL)

        let now = Date(timeIntervalSince1970: 1_711_000_000)
        let firstID = try store.insertMeeting(
            title: "First",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "first",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: rawLegacyPath
        )
        let secondID = try store.insertMeeting(
            title: "Second",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180),
            rawTranscript: "second",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: rawLegacyPath
        )

        let summary = try await MeetingRecordingWriter.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            encode: { sourceURL, destinationURL in
                #expect(sourceURL == legacyWAVURL.standardizedFileURL)
                try Data("m4a".utf8).write(to: destinationURL)
            }
        )

        let firstPath = try #require(try store.meeting(id: firstID)?.savedRecordingPath)
        let secondPath = try #require(try store.meeting(id: secondID)?.savedRecordingPath)
        #expect(summary.migrated == 2)
        #expect(firstPath == secondPath)
        #expect(firstPath.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: firstPath))
        #expect(FileManager.default.fileExists(atPath: legacyWAVURL.path) == false)
    }

    @Test("legacy wav migration keeps wav and database path when encode fails")
    func legacyWAVMigrationKeepsWAVWhenEncodeFails() async throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let legacyWAVURL = recordingsDirectory.appendingPathComponent("legacy.wav")
        try Data(repeating: 1, count: 2_048).write(to: legacyWAVURL)

        let now = Date(timeIntervalSince1970: 1_711_000_000)
        let meetingID = try store.insertMeeting(
            title: "Legacy",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "legacy",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: legacyWAVURL.path
        )

        let summary = try await MeetingRecordingWriter.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            encode: { _, _ in
                throw NSError(domain: "MeetingRecordingWriterTests", code: 1)
            }
        )

        let meeting = try #require(try store.meeting(id: meetingID))
        #expect(summary.migrated == 0)
        #expect(summary.deletedOrphanStubs == 0)
        #expect(meeting.savedRecordingPath == legacyWAVURL.path)
        #expect(FileManager.default.fileExists(atPath: legacyWAVURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(!leftovers.contains { $0.lastPathComponent.contains(".migrating") })
    }

    @Test("legacy wav migration rethrows cancellation and removes temp file")
    func legacyWAVMigrationRethrowsCancellationAndRemovesTempFile() async throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let legacyWAVURL = recordingsDirectory.appendingPathComponent("legacy.wav")
        try Data(repeating: 1, count: 2_048).write(to: legacyWAVURL)

        let now = Date(timeIntervalSince1970: 1_711_000_000)
        let meetingID = try store.insertMeeting(
            title: "Legacy",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "legacy",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: legacyWAVURL.path
        )

        await #expect(throws: CancellationError.self) {
            try await MeetingRecordingWriter.migrateLegacyWAVRecordings(
                store: store,
                recordingsDirectory: recordingsDirectory,
                encode: { _, destinationURL in
                    try Data("partial".utf8).write(to: destinationURL)
                    throw CancellationError()
                }
            )
        }

        let meeting = try #require(try store.meeting(id: meetingID))
        #expect(meeting.savedRecordingPath == legacyWAVURL.path)
        #expect(FileManager.default.fileExists(atPath: legacyWAVURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(!leftovers.contains { $0.lastPathComponent.contains(".migrating") })
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-migration-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let sampleBytes = data.subdata(in: 44..<data.count)
        let count = sampleBytes.count / MemoryLayout<Int16>.size
        return sampleBytes.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(buffer.prefix(count)).map(Int16.init(littleEndian:))
        }
    }
}

private final class StubDeleteFailureFileManager: FileManager {
    private let failingPath: String
    private(set) var failedRemoveAttempts = 0

    init(failingURL: URL) {
        self.failingPath = failingURL.standardizedFileURL.path
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
            .sorted { lhs, rhs in
                if lhs.standardizedFileURL.path == failingPath { return true }
                if rhs.standardizedFileURL.path == failingPath { return false }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
    }

    override func removeItem(at URL: URL) throws {
        guard URL.standardizedFileURL.path != failingPath else {
            failedRemoveAttempts += 1
            throw NSError(domain: "MeetingRecordingWriterTests", code: 2)
        }
        try super.removeItem(at: URL)
    }
}

private final class StubAttributesFailureFileManager: FileManager {
    private let failingPath: String
    private(set) var failedAttributesAttempts = 0

    init(failingURL: URL) {
        self.failingPath = failingURL.standardizedFileURL.path
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        guard URL(fileURLWithPath: path).standardizedFileURL.path != failingPath else {
            failedAttributesAttempts += 1
            throw NSError(domain: "MeetingRecordingWriterTests", code: 3)
        }
        return try super.attributesOfItem(atPath: path)
    }
}
