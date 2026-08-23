import Foundation
import MuesliCore
import SQLite3
import Testing
@testable import MuesliNativeApp

@Suite("Meeting resume and follow-up", .serialized, .muesliHermeticSupport)
struct MeetingResumeAndFollowUpTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-resume-follow-up-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func insertCompleted(
        _ store: DictationStore,
        title: String,
        start: Date,
        transcript: String = "Original transcript",
        notes: String = "## Summary\nOriginal notes"
    ) throws -> Int64 {
        try store.insertMeeting(
            title: title,
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: transcript,
            formattedNotes: notes,
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    @Test("resume policy only accepts completed meetings")
    func resumePolicyGate() {
        #expect(MeetingResumePolicy.canResume(status: .completed))
        #expect(!MeetingResumePolicy.canResume(status: .recording))
        #expect(!MeetingResumePolicy.canResume(status: .processing))
        #expect(!MeetingResumePolicy.canResume(status: .failed))
    }

    @Test("resume transcript merge is stable for empty additions")
    func resumeTranscriptMerge() {
        #expect(MeetingResumePolicy.combinedResumeTranscript(prior: "old", new: "") == "old")
        #expect(MeetingResumePolicy.combinedResumeTranscript(prior: "", new: "new") == "new")
        #expect(MeetingResumePolicy.combinedResumeTranscript(prior: "old", new: "new") == "old\n\n— Resumed —\n\nnew")
    }

    @Test("failed resume restores the exact completed meeting")
    func resumeRollback() throws {
        let store = try makeStore()
        let id = try insertCompleted(store, title: "Daily", start: Date(timeIntervalSince1970: 1_000))

        #expect(try store.prepareMeetingForResume(id: id) == "Original transcript")
        let recording = try store.meeting(id: id)
        #expect(try #require(recording).status == .recording)
        #expect(try store.restoreResumedMeetingIfNeeded(id: id))

        let restoredRecord = try store.meeting(id: id)
        let restored = try #require(restoredRecord)
        #expect(restored.status == .completed)
        #expect(restored.rawTranscript == "Original transcript")
        #expect(restored.formattedNotes == "## Summary\nOriginal notes")
        #expect(restored.durationSeconds == 60)
    }

    @Test("resume crash recovery appends checkpoints locally")
    func resumeCrashRecovery() throws {
        let store = try makeStore()
        let id = try insertCompleted(store, title: "Daily", start: Date(timeIntervalSince1970: 2_000))
        _ = try store.prepareMeetingForResume(id: id)
        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(
                timestampLabel: "[00:00]",
                speaker: "You",
                startSeconds: 0,
                endSeconds: 4,
                text: "New discussion"
            )
        ])

        #expect(try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id))
        let recoveredRecord = try store.meeting(id: id)
        let recovered = try #require(recoveredRecord)
        #expect(recovered.status == .completed)
        #expect(recovered.rawTranscript.contains("Original transcript"))
        #expect(recovered.rawTranscript.contains("— Resumed —"))
        #expect(recovered.rawTranscript.contains("New discussion"))
    }

    @Test("follow-up policy normalizes titles and carries only structured notes")
    func followUpPolicy() {
        #expect(MeetingFollowUpPolicy.followUpTitle(from: "Follow-up: Follow-up: Daily") == "Follow-up: Daily")
        #expect(MeetingFollowUpPolicy.followUpTitle(from: "  ") == "Follow-up meeting")
        #expect(MeetingFollowUpPolicy.canStartFollowUp(status: .completed))
        #expect(!MeetingFollowUpPolicy.canStartFollowUp(status: .recording))
        #expect(
            MeetingFollowUpPolicy.locallyCombinedNotes(previous: "Prior action", current: "New result")
                .contains("## Previous meeting context\n\nPrior action")
        )
    }

    @Test("older meeting JSON decodes without a follow-up link")
    func legacyMeetingJSON() throws {
        let json = #"{"id":1,"title":"Legacy","startTime":"2026-01-01T00:00:00Z","durationSeconds":1,"rawTranscript":"","formattedNotes":"","wordCount":0,"folderID":null}"#
        let record = try JSONDecoder().decode(MeetingRecord.self, from: Data(json.utf8))
        #expect(record.followUpToID == nil)
    }

    @Test("thread navigation supports multiple local follow-ups")
    func multipleFollowUps() throws {
        let store = try makeStore()
        let root = try insertCompleted(store, title: "Root", start: Date(timeIntervalSince1970: 3_000))
        let first = try store.createLiveMeeting(
            title: "First",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 3_100),
            followUpToID: root
        )
        let second = try store.createLiveMeeting(
            title: "Second",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 3_200),
            followUpToID: root
        )

        #expect(try store.meetingThreadIDs(containing: second) == [root, first, second])
        let resolvedNavigation = try store.meetingThreadNavigation(containing: root)
        let navigation = try #require(resolvedNavigation)
        #expect(navigation.predecessorID == nil)
        #expect(navigation.successorIDs == [first, second])
        #expect(navigation.count == 3)
    }

    @Test("deleting a predecessor detaches live local follow-ups")
    func deletingPredecessorDetachesChildren() throws {
        let store = try makeStore()
        let root = try insertCompleted(store, title: "Root", start: Date(timeIntervalSince1970: 4_000))
        let child = try store.createLiveMeeting(
            title: "Child",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 4_100),
            followUpToID: root
        )

        try store.deleteMeeting(id: root)
        let detachedChild = try store.meeting(id: child)
        #expect(try #require(detachedChild).followUpToID == nil)
    }

    @Test("follow-up migration stays local-only")
    func localOnlyMigration() throws {
        let store = try makeStore()
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA table_info(meetings)", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(String(cString: sqlite3_column_text(statement, 1)))
        }
        #expect(columns.contains("follow_up_to_id"))
        #expect(!columns.contains("follow_up_to_record_name"))
    }

    @Test("legacy meeting schema migrates before the follow-up index is created")
    func legacyMigration() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-follow-up-legacy-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let legacySQL = """
        CREATE TABLE meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'meeting',
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        #expect(sqlite3_exec(db, legacySQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        let root = try insertCompleted(store, title: "Root", start: Date(timeIntervalSince1970: 5_000))
        let child = try store.createLiveMeeting(
            title: "Child",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 5_100),
            followUpToID: root
        )
        let migratedChild = try store.meeting(id: child)
        #expect(try #require(migratedChild).followUpToID == root)
    }
}
