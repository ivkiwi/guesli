import Foundation
import AVFoundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("MeetingRecordingWriter", .muesliHermeticSupport)
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

    @Test("persistTemporaryRecording encodes the temp wav into the meeting recordings directory with a slugged m4a name")
    func persistTemporaryRecordingMovesFile() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem([1200, -800, 400])
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try MeetingRecordingWriter.persistTemporaryRecording(
            from: tempURL,
            meetingTitle: "Weekly Product Sync! With Very Long Title Extra Words",
            startedAt: startedAt,
            supportDirectory: supportDirectory
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync-with-very-long.m4a"))
        #expect(try audioDuration(from: savedURL) > 0)
    }

    @Test("persistTemporaryRecording keeps WAV when selected")
    func persistTemporaryRecordingKeepsWAVWhenSelected() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem([1200, -800, 400])
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try MeetingRecordingWriter.persistTemporaryRecording(
            from: tempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.pathExtension == "wav")
        #expect(try readMonoPCM16WAVSamples(from: savedURL) == [1200, -800, 400])
    }

    @Test("persistTemporaryRecording keeps existing recordings on filename collision")
    func persistTemporaryRecordingKeepsExistingRecordingOnCollision() throws {
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let firstWriter = try MeetingRecordingWriter()
        firstWriter.appendSystem([1200, -800, 400])
        let firstTempURL = try #require(firstWriter.stop())
        let firstSavedURL = try MeetingRecordingWriter.persistTemporaryRecording(
            from: firstTempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory
        )

        let secondWriter = try MeetingRecordingWriter()
        secondWriter.appendSystem([300, 600, 900])
        let secondTempURL = try #require(secondWriter.stop())
        let secondSavedURL = try MeetingRecordingWriter.persistTemporaryRecording(
            from: secondTempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory
        )

        #expect(firstSavedURL != secondSavedURL)
        #expect(FileManager.default.fileExists(atPath: firstSavedURL.path))
        #expect(FileManager.default.fileExists(atPath: secondSavedURL.path))
    }

    @Test("persistTemporaryRecording serializes concurrent destination names")
    func persistTemporaryRecordingSerializesConcurrentDestinationNames() async throws {
        let recordingsDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)
        let firstTempURL = try makeTempWAV(samples: [100, 200, 300])
        let secondTempURL = try makeTempWAV(samples: [400, 500, 600])

        async let firstSavedURL = MeetingRecordingStorage.persistTemporaryRecording(
            from: firstTempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            destinationDirectory: recordingsDirectory,
            fileFormat: .wav
        )
        async let secondSavedURL = MeetingRecordingStorage.persistTemporaryRecording(
            from: secondTempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            destinationDirectory: recordingsDirectory,
            fileFormat: .wav
        )
        let savedURLs = try await [firstSavedURL, secondSavedURL]

        #expect(savedURLs[0] != savedURLs[1])
        #expect(Set(savedURLs.map(\.lastPathComponent)).count == 2)
        #expect(savedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("saved m4a decodes to temporary wav for retranscription")
    func savedM4ADecodesToTemporaryWAVForRetranscription() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: 1200, count: 16_000))
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let savedURL = try MeetingRecordingWriter.persistTemporaryRecording(
            from: tempURL,
            meetingTitle: "Retranscribe",
            startedAt: Date(timeIntervalSince1970: 1_711_000_000),
            supportDirectory: supportDirectory
        )

        let wavURL = try await MeetingRecordingStorage.temporaryWAVForTranscription(from: savedURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        #expect(wavURL.pathExtension == "wav")
        #expect(FileManager.default.fileExists(atPath: wavURL.path))
        #expect(try readMonoPCM16WAVSamples(from: wavURL).isEmpty == false)
    }

    @Test("saved m4a preserves start middle and end audio for retranscription")
    func savedM4APreservesStartMiddleAndEndAudioForRetranscription() async throws {
        let sampleRate = 16_000
        var samples = [Int16](repeating: 0, count: sampleRate * 8)
        addTone(to: &samples, startSecond: 0.5, frequency: 440)
        addTone(to: &samples, startSecond: 3.5, frequency: 660)
        addTone(to: &samples, startSecond: 6.5, frequency: 880)

        let tempURL = try makeTempWAV(samples: samples)
        let supportDirectory = makeTemporaryDirectory()
        let savedURL = try MeetingRecordingWriter.persistTemporaryRecording(
            from: tempURL,
            meetingTitle: "Retranscribe regions",
            startedAt: Date(timeIntervalSince1970: 1_711_000_000),
            supportDirectory: supportDirectory
        )
        let wavURL = try await MeetingRecordingStorage.temporaryWAVForTranscription(from: savedURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let decoded = try WavReader.readFloatMonoWAV(from: wavURL)

        #expect(decoded.sampleRate == sampleRate)
        #expect(decoded.samples.count > sampleRate * 7)
        #expect(rms(decoded.samples, startSecond: 0.4, endSecond: 1.6) > 0.05)
        #expect(rms(decoded.samples, startSecond: 3.4, endSecond: 4.6) > 0.05)
        #expect(rms(decoded.samples, startSecond: 6.4, endSecond: 7.6) > 0.05)
    }

    @Test("legacy wav migration encodes referenced recordings and removes orphan stubs")
    func legacyWAVMigrationEncodesAndDeletesOrphanStubs() throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let legacyWAVURL = recordingsDirectory.appendingPathComponent("legacy.wav")
        let orphanStubURL = recordingsDirectory.appendingPathComponent("orphan.wav")
        let referencedStubURL = recordingsDirectory.appendingPathComponent("referenced-stub.wav")
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: 1200, count: 16_000))
        let tempWAVURL = try #require(writer.stop())
        try FileManager.default.moveItem(at: tempWAVURL, to: legacyWAVURL)
        try Data([0]).write(to: orphanStubURL)
        try Data([1]).write(to: referencedStubURL)

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

        let summary = try MeetingRecordingStorage.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory
        )

        let migrated = try #require(try store.meeting(id: migratedID))
        let migratedPath = try #require(migrated.savedRecordingPath)
        #expect(summary.migrated == 1)
        #expect(summary.deletedOrphanStubs == 1)
        #expect(migratedPath.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: migratedPath))
        #expect(FileManager.default.fileExists(atPath: legacyWAVURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: orphanStubURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: referencedStubURL.path))

        let secondSummary = try MeetingRecordingStorage.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory
        )
        #expect(secondSummary.migrated == 0)
        #expect(secondSummary.deletedOrphanStubs == 0)
        #expect(try store.meeting(id: migratedID)?.savedRecordingPath == migratedPath)
    }

    @Test("legacy wav migration returns after orphan directory listing failure")
    func legacyWAVMigrationReturnsAfterOrphanDirectoryListingFailure() throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let legacyWAVURL = recordingsDirectory.appendingPathComponent("legacy.wav")
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: 1200, count: 16_000))
        let tempWAVURL = try #require(writer.stop())
        try FileManager.default.moveItem(at: tempWAVURL, to: legacyWAVURL)

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
        let fileManager = OrphanListingFailureFileManager(failingURL: recordingsDirectory)

        let summary = try MeetingRecordingStorage.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            fileManager: fileManager
        )

        let meeting = try #require(try store.meeting(id: meetingID))
        let migratedPath = try #require(meeting.savedRecordingPath)
        #expect(summary.migrated == 1)
        #expect(summary.deletedOrphanStubs == 0)
        #expect(fileManager.failedListingAttempts == 1)
        #expect(migratedPath.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: migratedPath))
        #expect(FileManager.default.fileExists(atPath: legacyWAVURL.path) == false)
    }

    @Test("legacy wav migration continues after attributes failure")
    func legacyWAVMigrationContinuesAfterAttributesFailure() throws {
        let store = try makeStore()
        let recordingsDirectory = makeTemporaryDirectory()
        let failedWAVURL = recordingsDirectory.appendingPathComponent("failed.wav")
        let migratedWAVURL = recordingsDirectory.appendingPathComponent("migrated.wav")
        try Data(repeating: 1, count: 2_048).write(to: failedWAVURL)

        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: 1200, count: 16_000))
        let tempWAVURL = try #require(writer.stop())
        try FileManager.default.moveItem(at: tempWAVURL, to: migratedWAVURL)

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

        let summary = try MeetingRecordingStorage.migrateLegacyWAVRecordings(
            store: store,
            recordingsDirectory: recordingsDirectory,
            fileManager: fileManager
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
        #expect(try audioDuration(from: URL(fileURLWithPath: migratedPath)) > 0)
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

    private func makeTempWAV(samples: [Int16]) throws -> URL {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(samples)
        return try #require(writer.stop())
    }

    private func addTone(to samples: inout [Int16], startSecond: Double, frequency: Double) {
        let sampleRate = 16_000
        let start = Int(startSecond * Double(sampleRate))
        let end = min(samples.count, start + sampleRate)
        guard start < end else { return }
        for index in start..<end {
            let phase = 2.0 * Double.pi * frequency * Double(index - start) / Double(sampleRate)
            samples[index] = Int16(sin(phase) * 12_000)
        }
    }

    private func rms(_ samples: [Float], startSecond: Double, endSecond: Double) -> Float {
        let sampleRate = 16_000
        let start = max(0, Int(startSecond * Double(sampleRate)))
        let end = min(samples.count, Int(endSecond * Double(sampleRate)))
        guard start < end else { return 0 }
        let sum = samples[start..<end].reduce(Float(0)) { partial, sample in
            partial + sample * sample
        }
        return sqrt(sum / Float(end - start))
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

    private func audioDuration(from url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
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

private final class OrphanListingFailureFileManager: FileManager {
    private let failingPath: String
    private(set) var failedListingAttempts = 0

    init(failingURL: URL) {
        self.failingPath = failingURL.standardizedFileURL.path
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        guard url.standardizedFileURL.path != failingPath else {
            failedListingAttempts += 1
            throw NSError(domain: "MeetingRecordingWriterTests", code: 4)
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}
