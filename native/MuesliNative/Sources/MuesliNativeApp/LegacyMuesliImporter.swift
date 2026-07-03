import Foundation
import MuesliCore

struct LegacyMuesliImportSummary: Equatable {
    let didImport: Bool
    let dictationsImported: Int
    let meetingsImported: Int

    static let skipped = LegacyMuesliImportSummary(
        didImport: false,
        dictationsImported: 0,
        meetingsImported: 0
    )

    var totalImported: Int {
        dictationsImported + meetingsImported
    }
}

final class LegacyMuesliImporter {
    private struct Marker: Codable {
        let sourceDatabasePath: String
        let importedAt: String
        let dictationsImported: Int
        let meetingsImported: Int
    }

    private let fileManager: FileManager
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
    }

    func importIfNeeded(
        legacyDatabaseURL: URL = MuesliPaths.defaultDatabaseURL(appName: "Muesli"),
        legacySupportDirectory: URL = MuesliPaths.defaultSupportDirectoryURL(appName: "Muesli"),
        targetStore: DictationStore,
        targetSupportDirectory: URL = AppIdentity.supportDirectoryURL
    ) throws -> LegacyMuesliImportSummary {
        let legacyDatabaseURL = legacyDatabaseURL.standardizedFileURL
        let targetDatabaseURL = targetStore.databasePath().standardizedFileURL
        guard legacyDatabaseURL != targetDatabaseURL else { return .skipped }
        guard fileManager.fileExists(atPath: legacyDatabaseURL.path) else { return .skipped }
        guard !fileManager.fileExists(atPath: markerURL(targetSupportDirectory: targetSupportDirectory).path) else {
            return .skipped
        }

        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(AppTemporaryDirectories.legacyImportDirectoryName(), isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let tempDatabaseURL = try copySQLiteDatabase(from: legacyDatabaseURL, toDirectory: tempDirectory)
        let sourceStore = DictationStore(databaseURL: tempDatabaseURL)
        try sourceStore.migrateIfNeeded()

        let dictations = try sourceStore.recentDictations(limit: 100_000)
        let meetings = try sourceStore.recentMeetings(limit: nil)
        var dictationCount = 0
        var meetingCount = 0

        for dictation in dictations.reversed() {
            let endedAt = parseDate(dictation.timestamp) ?? now()
            let startedAt = endedAt.addingTimeInterval(-max(dictation.durationSeconds, 0))
            try targetStore.insertDictation(
                text: dictation.rawText,
                durationSeconds: dictation.durationSeconds,
                appContext: dictation.appContext,
                source: dictation.source,
                startedAt: startedAt,
                endedAt: endedAt
            )
            dictationCount += 1
        }

        for meeting in meetings.reversed() {
            if let eventID = meeting.calendarEventID,
               try targetStore.meetingByCalendarEventID(eventID) != nil {
                continue
            }

            let startTime = parseDate(meeting.startTime) ?? now()
            let endTime = startTime.addingTimeInterval(max(meeting.durationSeconds, 0))
            let micAudioPath = copiedLegacyAudioPath(
                meeting.micAudioPath,
                legacySupportDirectory: legacySupportDirectory,
                targetSupportDirectory: targetSupportDirectory
            )
            let systemAudioPath = copiedLegacyAudioPath(
                meeting.systemAudioPath,
                legacySupportDirectory: legacySupportDirectory,
                targetSupportDirectory: targetSupportDirectory
            )
            let savedRecordingPath = copiedLegacyAudioPath(
                meeting.savedRecordingPath,
                legacySupportDirectory: legacySupportDirectory,
                targetSupportDirectory: targetSupportDirectory
            )
            let importedMeetingID = try targetStore.insertMeeting(
                title: meeting.title,
                calendarEventID: meeting.calendarEventID,
                startTime: startTime,
                endTime: endTime,
                rawTranscript: meeting.rawTranscript,
                formattedNotes: meeting.formattedNotes,
                micAudioPath: micAudioPath,
                systemAudioPath: systemAudioPath,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: meeting.selectedTemplateID,
                selectedTemplateName: meeting.selectedTemplateName,
                selectedTemplateKind: meeting.selectedTemplateKind,
                selectedTemplatePrompt: meeting.selectedTemplatePrompt,
                source: normalizedMeetingSource(meeting.source)
            )
            if !meeting.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try targetStore.updateMeetingManualNotes(id: importedMeetingID, manualNotes: meeting.manualNotes)
            }
            let importedStatus = normalizedMeetingStatus(meeting.status)
            if importedStatus != .completed {
                try targetStore.updateMeetingStatus(id: importedMeetingID, status: importedStatus)
            }
            meetingCount += 1
        }

        let summary = LegacyMuesliImportSummary(
            didImport: true,
            dictationsImported: dictationCount,
            meetingsImported: meetingCount
        )
        try writeMarker(
            summary: summary,
            sourceDatabaseURL: legacyDatabaseURL,
            targetSupportDirectory: targetSupportDirectory
        )
        return summary
    }

    private func copySQLiteDatabase(from sourceURL: URL, toDirectory tempDirectory: URL) throws -> URL {
        let destinationURL = tempDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        for suffix in ["-wal", "-shm"] {
            let sidecarSource = URL(fileURLWithPath: sourceURL.path + suffix)
            guard fileManager.fileExists(atPath: sidecarSource.path) else { continue }
            try fileManager.copyItem(
                at: sidecarSource,
                to: URL(fileURLWithPath: destinationURL.path + suffix)
            )
        }
        return destinationURL
    }

    private func copiedLegacyAudioPath(
        _ path: String?,
        legacySupportDirectory: URL,
        targetSupportDirectory: URL
    ) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let sourceURL = resolvedLegacyFileURL(path, legacySupportDirectory: legacySupportDirectory)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return path
        }

        let destinationDirectory = targetSupportDirectory
            .appendingPathComponent("legacy-recordings", isDirectory: true)
        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destinationURL = uniqueDestinationURL(for: sourceURL, in: destinationDirectory)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL.path
        } catch {
            return path
        }
    }

    private func resolvedLegacyFileURL(_ path: String, legacySupportDirectory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return legacySupportDirectory
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private func uniqueDestinationURL(for sourceURL: URL, in destinationDirectory: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        var candidate = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let suffix = pathExtension.isEmpty ? "-\(index)" : "-\(index).\(pathExtension)"
            candidate = destinationDirectory.appendingPathComponent("\(baseName)\(suffix)")
            index += 1
        }
        return candidate
    }

    private func markerURL(targetSupportDirectory: URL) -> URL {
        targetSupportDirectory.appendingPathComponent("legacy-muesli-import.json")
    }

    private func writeMarker(
        summary: LegacyMuesliImportSummary,
        sourceDatabaseURL: URL,
        targetSupportDirectory: URL
    ) throws {
        try fileManager.createDirectory(at: targetSupportDirectory, withIntermediateDirectories: true)
        let marker = Marker(
            sourceDatabasePath: sourceDatabaseURL.path,
            importedAt: ISO8601DateFormatter().string(from: now()),
            dictationsImported: summary.dictationsImported,
            meetingsImported: summary.meetingsImported
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(
            to: markerURL(targetSupportDirectory: targetSupportDirectory),
            options: .atomic
        )
    }

    private func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func normalizedMeetingSource(_ source: MeetingSource) -> MeetingSource {
        source == .iOS ? .meeting : source
    }

    private func normalizedMeetingStatus(_ status: MeetingStatus) -> MeetingStatus {
        switch status {
        case .noteOnly, .failed:
            return status
        case .recording, .processing, .completed:
            return .completed
        }
    }
}
