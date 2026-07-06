import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Legacy Muesli importer", .serialized, .muesliHermeticSupport)
struct LegacyMuesliImporterTests {
    @Test("imports legacy dictations, meetings, notes, and recordings once")
    func importsLegacyHistoryOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-muesli-import-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacySupport = root.appendingPathComponent("Muesli", isDirectory: true)
        let targetSupport = root.appendingPathComponent("Guesli", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetSupport, withIntermediateDirectories: true)

        let legacyStore = DictationStore(
            databaseURL: legacySupport.appendingPathComponent("muesli.db")
        )
        try legacyStore.migrateIfNeeded()

        let start = try #require(ISO8601DateFormatter().date(from: "2026-07-02T09:00:00Z"))
        _ = try legacyStore.insertDictation(
            text: "legacy dictation text",
            durationSeconds: 4,
            appContext: "Legacy App",
            source: "dictation",
            startedAt: start,
            endedAt: start.addingTimeInterval(4)
        )

        let legacyRecording = legacySupport
            .appendingPathComponent("meeting-recordings", isDirectory: true)
            .appendingPathComponent("legacy.wav")
        try FileManager.default.createDirectory(
            at: legacyRecording.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy audio".utf8).write(to: legacyRecording)

        let meetingID = try legacyStore.insertMeeting(
            title: "Legacy Meeting",
            calendarEventID: "legacy-event",
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "legacy transcript",
            formattedNotes: "legacy summary",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "meeting-recordings/legacy.wav",
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto Detailed Notes",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "legacy prompt",
            source: .meeting
        )
        try legacyStore.updateMeetingManualNotes(id: meetingID, manualNotes: "legacy manual notes")

        let targetStore = DictationStore(
            databaseURL: targetSupport.appendingPathComponent("muesli.db")
        )
        try targetStore.migrateIfNeeded()

        let importer = LegacyMuesliImporter(now: { start.addingTimeInterval(120) })
        let summary = try importer.importIfNeeded(
            legacyDatabaseURL: legacyStore.databasePath(),
            legacySupportDirectory: legacySupport,
            targetStore: targetStore,
            targetSupportDirectory: targetSupport
        )

        #expect(summary.didImport)
        #expect(summary.dictationsImported == 1)
        #expect(summary.meetingsImported == 1)

        let importedDictations = try targetStore.recentDictations(limit: 10)
        #expect(importedDictations.map(\.rawText) == ["legacy dictation text"])
        #expect(importedDictations.first?.appContext == "Legacy App")

        let importedMeetings = try targetStore.recentMeetings(limit: nil)
        let importedMeeting = try #require(importedMeetings.first)
        #expect(importedMeeting.title == "Legacy Meeting")
        #expect(importedMeeting.rawTranscript == "legacy transcript")
        #expect(importedMeeting.formattedNotes == "legacy summary")
        #expect(importedMeeting.manualNotes == "legacy manual notes")
        #expect(importedMeeting.selectedTemplateID == "auto")
        let copiedRecordingPath = try #require(importedMeeting.savedRecordingPath)
        #expect(copiedRecordingPath.contains("/legacy-recordings/"))
        #expect(FileManager.default.fileExists(atPath: copiedRecordingPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: copiedRecordingPath)) == Data("legacy audio".utf8))

        let secondSummary = try importer.importIfNeeded(
            legacyDatabaseURL: legacyStore.databasePath(),
            legacySupportDirectory: legacySupport,
            targetStore: targetStore,
            targetSupportDirectory: targetSupport
        )
        #expect(secondSummary == .skipped)
        #expect(try targetStore.recentDictations(limit: 10).count == 1)
        #expect(try targetStore.recentMeetings(limit: nil).count == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: targetSupport.appendingPathComponent("legacy-muesli-import.json").path
            )
        )
    }
}
