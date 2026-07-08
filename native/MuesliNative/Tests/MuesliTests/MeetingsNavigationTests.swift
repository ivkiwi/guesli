import Testing
import AppKit
import AVFoundation
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meetings navigation", .muesliHermeticSupport)
struct MeetingsNavigationTests {

    private func makeController() -> MuesliController {
        MuesliController(
            runtime: makeRuntimePaths(),
            configStore: makeConfigStore()
        )
    }

    private func makeController(dictationStore: DictationStore) -> MuesliController {
        MuesliController(
            runtime: makeRuntimePaths(),
            configStore: makeConfigStore(),
            dictationStore: dictationStore
        )
    }

    private func makeController(
        configStore: ConfigStore,
        dictationStore: DictationStore
    ) -> MuesliController {
        MuesliController(
            runtime: makeRuntimePaths(),
            configStore: configStore,
            dictationStore: dictationStore
        )
    }

    private func makeRuntimePaths() -> RuntimePaths {
        RuntimePaths(
            repoRoot: FileManager.default.temporaryDirectory,
            menuIcon: nil,
            appIcon: nil,
            bundlePath: nil
        )
    }

    private func makeConfigStore() -> ConfigStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-nav-config-\(UUID().uuidString)", isDirectory: true)
        return ConfigStore(
            supportURL: root.appendingPathComponent("Guesli", isDirectory: true),
            legacySupportURL: root.appendingPathComponent("Muesli", isDirectory: true)
        )
    }

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-nav-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeRetainedRecordingURL() throws -> URL {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem([1_200, -800, 400, -200])
        return try #require(writer.stop())
    }

    private func audioDuration(from url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    @Test("app state defaults meetings to browser mode")
    func meetingsDefaultToBrowser() {
        let appState = AppState()

        #expect(appState.meetingsNavigationState == .browser)
        #expect(appState.selectedMeeting == nil)
    }

    @Test("discard confirmation maps checkbox selections to meeting discard resolutions")
    func discardConfirmationResolutionMapping() {
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: nil
            ) == .discardRecording
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: false
            ) == .keepManualNotes
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: true
            ) == .deleteDraft
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertSecondButtonReturn,
                deleteManualNotes: false
            ) == nil
        )
    }

    @Test("selectedMeeting resolves the selected row only")
    func selectedMeetingUsesExplicitSelection() {
        let appState = AppState()
        let first = makeMeeting(id: 101, title: "First")
        let second = makeMeeting(id: 202, title: "Second")
        appState.meetingRows = [first, second]

        #expect(appState.selectedMeeting == nil)

        appState.selectedMeetingID = 202
        #expect(appState.selectedMeeting?.id == 202)
        #expect(appState.selectedMeeting?.title == "Second")
    }

    @Test("selectedMeeting falls back to the stored document record outside the browser slice")
    func selectedMeetingUsesStoredRecordWhenNotInRows() {
        let appState = AppState()
        let visible = makeMeeting(id: 101, title: "Visible")
        let selected = makeMeeting(id: 202, title: "Selected Outside Slice")
        appState.meetingRows = [visible]
        appState.selectedMeetingID = 202
        appState.selectedMeetingRecord = selected

        #expect(appState.selectedMeeting?.id == 202)
        #expect(appState.selectedMeeting?.title == "Selected Outside Slice")
    }

    @Test("showMeetingDocument enters meetings document route and records selection")
    func showMeetingDocumentRoutesToDocument() {
        let controller = makeController()

        controller.appState.selectedTab = .dictations
        controller.appState.selectedFolderID = 55

        controller.showMeetingDocument(id: 202)

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.selectedMeetingID == 202)
        #expect(controller.appState.meetingsNavigationState == .document(202))
        #expect(controller.appState.selectedFolderID == 55)
    }

    @Test("showMeetingsHome returns to browser and preserves prior meeting selection")
    func showMeetingsHomeReturnsToBrowser() {
        let controller = makeController()

        controller.appState.selectedMeetingID = 303
        controller.appState.meetingsNavigationState = .document(303)

        controller.showMeetingsHome(folderID: 99)

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.selectedFolderID == 99)
        #expect(controller.appState.meetingsNavigationState == .browser)
        #expect(controller.appState.selectedMeetingID == 303)
    }

    @Test("showMeetingsHome with nil folder resets browser to all meetings")
    func showMeetingsHomeResetsFolderFilter() {
        let controller = makeController()

        controller.appState.selectedFolderID = 11
        controller.appState.meetingsNavigationState = .document(404)

        controller.showMeetingsHome(folderID: nil)

        #expect(controller.appState.selectedFolderID == nil)
        #expect(controller.appState.meetingsNavigationState == .browser)
    }

    @Test("deleteMeeting clears selected detail state and removes saved recording")
    func deleteMeetingClearsSelection() throws {
        let store = try makeStore()
        let configStore = makeConfigStore()
        let savedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-\(UUID().uuidString).wav")
        try Data("test".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: configStore.supportDirectory()
        )
        try Data("cache".utf8).write(to: cacheURL)

        let now = Date()
        try store.insertMeeting(
            title: "Delete Target",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )

        let controller = makeController(configStore: configStore, dictationStore: store)
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        controller.appState.selectedMeetingID = meetingID
        controller.appState.selectedMeetingRecord = try store.meeting(id: meetingID)
        controller.appState.meetingsNavigationState = .document(meetingID)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(controller.appState.selectedMeetingID == nil)
        #expect(controller.appState.selectedMeetingRecord == nil)
        #expect(controller.appState.meetingsNavigationState == .browser)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
    }

    @Test("deleteMeeting removes saved recording when waveform cache removal fails")
    func deleteMeetingRemovesSavedRecordingWhenWaveformCacheRemovalFails() throws {
        let store = try makeStore()
        let configStore = makeConfigStore()
        let supportRoot = configStore.supportDirectory().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let recordingsDirectory = MeetingRecordingStorage.directory(
            config: AppConfig(),
            supportDirectory: configStore.supportDirectory()
        )
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.wav")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: configStore.supportDirectory()
        )
        try Data("cache".utf8).write(to: cacheURL)
        let cacheDirectory = cacheURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path) }

        let now = Date()
        try store.insertMeeting(
            title: "Delete Cache Failure Target",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )
        let controller = makeController(configStore: configStore, dictationStore: store)
        let meetingID = try store.recentMeetings(limit: 1).first!.id

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("clearMeetingHistory removes saved recordings and waveform cache")
    func clearMeetingHistoryRemovesSavedRecordingsAndWaveformCache() throws {
        let store = try makeStore()
        let configStore = makeConfigStore()
        let recordingsDirectory = MeetingRecordingStorage.directory(
            config: AppConfig(),
            supportDirectory: configStore.supportDirectory()
        )
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: configStore.supportDirectory()
        )
        try Data("cache".utf8).write(to: cacheURL)
        let strandedCacheURL = RecordingWaveformCacheFiles
            .cacheDirectory(supportDirectory: configStore.supportDirectory())
            .appendingPathComponent("stranded.mwf")
        try Data("old-cache".utf8).write(to: strandedCacheURL)

        let now = Date()
        try store.insertMeeting(
            title: "Clear Target",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )
        let controller = makeController(configStore: configStore, dictationStore: store)

        controller.clearMeetingHistory()

        #expect(try store.recentMeetings(limit: 10).isEmpty)
        #expect(FileManager.default.fileExists(atPath: recordingsDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: strandedCacheURL.path) == false)
    }

    @Test("clearMeetingHistory keeps unrelated files in custom recording folder")
    func clearMeetingHistoryKeepsUnrelatedFilesInCustomRecordingFolder() throws {
        let store = try makeStore()
        let configStore = makeConfigStore()
        let recordingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-custom-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingsDirectory) }

        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.m4a")
        let unrelatedURL = recordingsDirectory.appendingPathComponent("family-video.mov")
        try Data("recording".utf8).write(to: savedRecordingURL)
        try Data("unrelated".utf8).write(to: unrelatedURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: configStore.supportDirectory()
        )
        try Data("cache".utf8).write(to: cacheURL)

        let now = Date()
        try store.insertMeeting(
            title: "Custom Clear Target",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )
        let controller = makeController(configStore: configStore, dictationStore: store)
        controller.updateConfig { $0.meetingRecordingFolderPath = recordingsDirectory.path }

        controller.clearMeetingHistory()

        #expect(try store.recentMeetings(limit: 10).isEmpty)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    @Test("deleteMeeting keeps a shared saved recording for remaining meetings")
    func deleteMeetingKeepsSharedRecording() throws {
        let store = try makeStore()
        let savedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-meeting-recording-\(UUID().uuidString).wav")
        try Data("shared".utf8).write(to: savedRecordingURL)

        let now = Date()
        let firstID = try store.insertMeeting(
            title: "First",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "First",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )
        let secondID = try store.insertMeeting(
            title: "Second",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180),
            rawTranscript: "Second",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )
        let controller = makeController(dictationStore: store)

        controller.deleteMeeting(id: firstID)

        #expect(try store.meeting(id: firstID) == nil)
        #expect(try store.meeting(id: secondID)?.savedRecordingPath == savedRecordingURL.path)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
    }

    @Test("deleteMeeting refuses live meeting rows")
    func deleteMeetingRefusesLiveRows() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = makeController(dictationStore: store)

        let liveMeeting = try #require(try store.meeting(id: meetingID))
        #expect(controller.canDeleteMeeting(liveMeeting) == false)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) != nil)
    }

    @Test("retranscribe missing recording preserves completed meeting status")
    func retranscribeMissingRecordingPreservesCompletedStatus() async throws {
        let store = try makeStore()
        let missingRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-meeting-recording-\(UUID().uuidString).wav")
        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Recovered Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Existing transcript",
            formattedNotes: "## Existing notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: missingRecordingURL.path
        )
        let controller = makeController(dictationStore: store)
        let meeting = try #require(try store.meeting(id: meetingID))

        let result = await withCheckedContinuation { continuation in
            controller.retranscribe(meeting: meeting) { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success:
            Issue.record("Expected re-transcription to fail when the retained recording is missing")
        case .failure(let error):
            #expect(error is MeetingRetranscriptionError)
        }

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.status == .completed)
        #expect(updated.rawTranscript == "Existing transcript")
        #expect(updated.formattedNotes == "## Existing notes")
    }

    @Test("retranscribe empty transcript restores original meeting status")
    func retranscribeEmptyTranscriptRestoresOriginalMeetingStatus() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.emptyTranscript
        ) == .completed)
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .failed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.emptyTranscript
        ) == .failed)
    }

    @Test("retranscribe status is unchanged before processing starts")
    func retranscribeStatusIsUnchangedBeforeProcessingStarts() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: false,
            error: MeetingRetranscriptionError.recordingUnavailable
        ) == nil)
    }

    @Test("retranscribe save failures restore original meeting status")
    func retranscribeSaveFailuresRestoreOriginalMeetingStatus() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.failedToSave(underlying: CocoaError(.fileWriteUnknown))
        ) == .completed)
    }

    @Test("retranscribe processing failures mark meeting failed")
    func retranscribeProcessingFailuresMarkMeetingFailed() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: CocoaError(.fileReadUnknown)
        ) == .failed)
    }

    @Test("retranscribe action remains visible for failed empty transcript with retained recording")
    func retranscribeActionVisibleForFailedEmptyTranscriptWithRecording() {
        let meeting = makeMeeting(
            id: 901,
            title: "Traffic Daily",
            rawTranscript: "",
            wordCount: 0,
            savedRecordingPath: "/tmp/traffic-daily.m4a",
            status: .failed
        )

        #expect(MeetingDetailView.showsRetranscribeAction(for: meeting))
    }

    @Test("retranscribe action remains visible for failed post-mode source tracks")
    func retranscribeActionVisibleForFailedPostModeSourceTracks() {
        let meeting = makeMeeting(
            id: 904,
            title: "Traffic Daily",
            rawTranscript: "",
            wordCount: 0,
            micAudioPath: "/tmp/traffic-daily-mic.wav",
            savedRecordingPath: nil,
            status: .failed
        )

        #expect(MeetingDetailView.showsRetranscribeAction(for: meeting))
    }

    @Test("retranscribe action stays hidden without retained recording path")
    func retranscribeActionHiddenWithoutRecordingPath() {
        let failedMeeting = makeMeeting(
            id: 902,
            title: "Traffic Daily",
            rawTranscript: "",
            wordCount: 0,
            savedRecordingPath: nil,
            status: .failed
        )
        let whitespacePathMeeting = makeMeeting(
            id: 903,
            title: "Traffic Daily",
            savedRecordingPath: "   "
        )

        #expect(MeetingDetailView.showsRetranscribeAction(for: failedMeeting) == false)
        #expect(MeetingDetailView.showsRetranscribeAction(for: whitespacePathMeeting) == false)
    }

    @Test("cached manual notes are persisted before debounce")
    func cachedManualNotesPersistImmediately() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = makeController(dictationStore: store)

        controller.cacheMeetingManualNotes(id: meetingID, notes: "Decision before crash")

        let persisted = try #require(try store.meeting(id: meetingID))
        #expect(persisted.manualNotes == "Decision before crash")
    }

    @Test("failed manual note persistence retries on later flush")
    func failedManualNotePersistenceRetriesOnFlush() throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)

        controller.cacheMeetingManualNotes(id: 1, notes: "Draft survives retry")
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        #expect(meetingID == 1)

        controller.flushCachedMeetingManualNotes(id: meetingID, sync: false)

        let stored = try #require(try store.meeting(id: meetingID))
        #expect(stored.manualNotes == "Draft survives retry")
    }

    @Test("manual note cache coalesces repeated writes until flush")
    func cachedManualNotesCoalesceRepeatedWrites() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = makeController(dictationStore: store)

        controller.cacheMeetingManualNotes(id: meetingID, notes: "First durable note")
        #expect(controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "First durable note"))
        controller.cacheMeetingManualNotes(id: meetingID, notes: "Second cached note")
        #expect(!controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "Second cached note"))

        let beforeFlush = try #require(try store.meeting(id: meetingID))
        #expect(beforeFlush.manualNotes == "First durable note")

        controller.flushCachedMeetingManualNotes(id: meetingID, sync: false)
        #expect(controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "Second cached note"))

        let afterFlush = try #require(try store.meeting(id: meetingID))
        #expect(afterFlush.manualNotes == "Second cached note")
    }

    @Test("persistCompletedMeetingResult keeps transcript when recording save fails")
    func persistCompletedMeetingResultPreservesMeetingOnRecordingFailure() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        controller.updateConfig { $0.meetingRecordingSavePolicy = .always }

        let invalidRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let result = MeetingSessionResult(
            title: "Customer Review",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(90),
            durationSeconds: 90,
            rawTranscript: "Discussed roadmap and blockers.",
            formattedNotes: "## Summary\nRoadmap reviewed.",
            retainedRecordingURL: invalidRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        #expect(persistenceResult.recordingSaveError != nil)
        let storedMeeting = try store.meeting(id: persistenceResult.meetingID)
        #expect(storedMeeting?.title == "Customer Review")
        #expect(storedMeeting?.rawTranscript == "Discussed roadmap and blockers.")
        #expect(storedMeeting?.savedRecordingPath == nil)
    }

    @Test("persistCompletedMeetingResult honors prompt recording save decision")
    func persistCompletedMeetingResultHonorsPromptRecordingSaveDecision() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let retainedRecordingURL = try makeRetainedRecordingURL()

        let result = MeetingSessionResult(
            title: "Prompt Decision",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Prompt decision transcript.",
            formattedNotes: "## Summary\nPrompt decision notes.",
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: false
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try store.meeting(id: persistenceResult.meetingID)
        #expect(storedMeeting?.rawTranscript == "Prompt decision transcript.")
        #expect(storedMeeting?.savedRecordingPath == nil)
        #expect(FileManager.default.fileExists(atPath: retainedRecordingURL.path) == false)
    }

    @Test("persistCompletedMeetingResult honors explicit recording save decision after policy drift")
    func persistCompletedMeetingResultHonorsExplicitRecordingSaveDecisionAfterPolicyDrift() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        controller.updateConfig {
            $0.meetingRecordingSavePolicy = .never
            $0.meetingRecordingFileFormat = MeetingRecordingFileFormat.wav.rawValue
        }

        let retainedRecordingURL = try makeRetainedRecordingURL()

        let result = MeetingSessionResult(
            title: "Policy Drift",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Policy drift transcript.",
            formattedNotes: "## Summary\nPolicy drift notes.",
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: true
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        let savedRecordingPath = try #require(storedMeeting.savedRecordingPath)
        #expect(FileManager.default.fileExists(atPath: savedRecordingPath))
        #expect(URL(fileURLWithPath: savedRecordingPath).pathExtension == "wav")
        #expect(FileManager.default.fileExists(atPath: retainedRecordingURL.path) == false)
    }

    @Test("persistCompletedMeetingResult saves retained recording in configured folder")
    func persistCompletedMeetingResultSavesRecordingInConfiguredFolder() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        let recordingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recordings-custom-\(UUID().uuidString)", isDirectory: true)
        controller.updateConfig {
            $0.meetingRecordingSavePolicy = .always
            $0.meetingRecordingFolderPath = recordingFolder.path
        }

        let retainedRecordingURL = try makeRetainedRecordingURL()
        let result = MeetingSessionResult(
            title: "Custom Folder",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Custom folder transcript.",
            formattedNotes: "## Summary\nCustom folder notes.",
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        let savedRecordingPath = try #require(storedMeeting.savedRecordingPath)
        let savedURL = URL(fileURLWithPath: savedRecordingPath)
        #expect(savedURL.deletingLastPathComponent().standardizedFileURL == recordingFolder.standardizedFileURL)
        #expect(savedURL.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
        #expect(FileManager.default.fileExists(atPath: retainedRecordingURL.path) == false)
    }

    @Test("persistCompletedMeetingResult keeps early saved recording path")
    func persistCompletedMeetingResultKeepsEarlySavedRecordingPath() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        controller.updateConfig { $0.meetingRecordingSavePolicy = .always }
        let savedRecordingURL = try makeRetainedRecordingURL()
        defer { try? FileManager.default.removeItem(at: savedRecordingURL) }

        let result = MeetingSessionResult(
            title: "Early Saved",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Early saved transcript.",
            formattedNotes: "## Summary\nEarly saved notes.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            retainedRecordingSavedURL: savedRecordingURL,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == savedRecordingURL.path)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
    }

    @Test("persistCompletedMeetingResult leaves recovery marker when DB persistence fails after recording save")
    func persistCompletedMeetingResultLeavesRecoveryMarkerAfterDBFailure() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        let savedRecordingURL = try makeRetainedRecordingURL()
        defer { try? FileManager.default.removeItem(at: savedRecordingURL) }
        defer { try? FileManager.default.removeItem(at: savedRecordingURL.appendingPathExtension("recovery")) }
        let missingLiveMeetingID: Int64 = 999_999
        let result = MeetingSessionResult(
            title: "Missing Live Row",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Transcript survived.",
            formattedNotes: "## Summary\nNotes survived.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            retainedRecordingSavedURL: savedRecordingURL,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        #expect(throws: Error.self) {
            _ = try controller.persistCompletedMeetingResult(
                result,
                existingMeetingID: missingLiveMeetingID,
                preparedRecordingSave: PreparedMeetingRecordingSave(path: savedRecordingURL.path, error: nil)
            )
        }

        let markerURL = savedRecordingURL.appendingPathExtension("recovery")
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        let marker = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(marker.contains("meeting_id=\(missingLiveMeetingID)"))
        #expect(marker.contains("saved_recording_path=\(savedRecordingURL.path)"))
    }

    @Test("persistCompletedMeetingResult discards retained recording when policy is never")
    func persistCompletedMeetingResultDiscardsRetainedRecordingWhenPolicyIsNever() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        controller.updateConfig { $0.meetingRecordingSavePolicy = .never }
        let retainedRecordingURL = try makeRetainedRecordingURL()

        let result = MeetingSessionResult(
            title: "Discard Source",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Discard transcript.",
            formattedNotes: "## Summary\nDiscard notes.",
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == nil)
        #expect(FileManager.default.fileExists(atPath: retainedRecordingURL.path) == false)
    }

    @Test("persistCompletedMeetingResult surfaces prompt policy retained recording failures without decision")
    func persistCompletedMeetingResultSurfacesPromptPolicyRetainedRecordingFailuresWithoutDecision() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let result = MeetingSessionResult(
            title: "Failed Retention",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Retention failure transcript.",
            formattedNotes: "## Summary\nRetention failure notes.",
            retainedRecordingURL: nil,
            retainedRecordingError: CocoaError(.fileWriteUnknown),
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == nil)
        #expect(persistenceResult.recordingSaveError != nil)
    }

    @Test("persistCompletedMeetingResult surfaces retained recording failures after explicit save decision")
    func persistCompletedMeetingResultSurfacesRetainedRecordingFailuresAfterExplicitSaveDecision() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let result = MeetingSessionResult(
            title: "Explicit Save Failed Retention",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Explicit save retention failure transcript.",
            formattedNotes: "## Summary\nExplicit save retention failure notes.",
            retainedRecordingURL: nil,
            retainedRecordingError: CocoaError(.fileWriteUnknown),
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: true
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == nil)
        #expect(persistenceResult.recordingSaveError != nil)
    }

    @Test("persistCompletedMeetingResult preserves user-edited live meeting title")
    func persistCompletedMeetingResultPreservesEditedLiveTitle() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        try store.updateMeetingTitle(id: liveID, title: "Investor Follow-up")

        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed fundraising updates.",
            formattedNotes: "## Summary\nFundraising updates discussed.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.title == "Investor Follow-up")
        #expect(storedMeeting.formattedNotes == "## Summary\nFundraising updates discussed.")
    }

    @Test("persistCompletedMeetingResult preserves cached live title before debounce")
    func persistCompletedMeetingResultPreservesCachedLiveTitle() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        controller.cacheMeetingTitle(id: liveID, title: "Status Bar Stop Title")

        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed follow-up items.",
            formattedNotes: "## Summary\nFollow-up items discussed.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.title == "Status Bar Stop Title")
        #expect(storedMeeting.formattedNotes == "## Summary\nFollow-up items discussed.")
    }

    @Test("resummary context strips appended written notes section")
    func resummaryContextStripsWrittenNotesSection() {
        let meeting = makeMeeting(
            id: 909,
            title: "Resummarize",
            formattedNotes: "## Summary\n- Decision captured\n\n### Written notes\n\n- User typed this",
            status: .completed,
            manualNotes: "- User typed this"
        )

        let context = MuesliController.notesContextForResummary(meeting)

        #expect(context == "## Summary\n- Decision captured")
    }

    @Test("startup recovery preserves stale live meetings with notes")
    func startupRecoveryPreservesStaleLiveMeetingWithNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Crashed Draft", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Important draft")
        let controller = makeController(dictationStore: store)

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
        #expect(meeting.manualNotes == "Important draft")
    }

    @Test("startup recovery marks empty stale live drafts as failed")
    func startupRecoveryMarksEmptyStaleLiveDraftsFailed() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Empty Draft", calendarEventID: nil, startTime: Date())
        let controller = makeController(dictationStore: store)

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
    }

    @Test("startup recovery uses live transcript checkpoints before failing stale meetings")
    func startupRecoveryUsesLiveTranscriptCheckpoints() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Checkpoint Draft", calendarEventID: nil, startTime: Date())
        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "11:45:02", speaker: "Others", startSeconds: 2, endSeconds: 3, text: "The fallback transcript survived.")
        ])
        let controller = makeController(dictationStore: store)

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.notesState == .rawTranscriptFallback)
        #expect(meeting.rawTranscript == "[11:45:02] Others: The fallback transcript survived.")
        #expect(try store.liveTranscriptCheckpointText(meetingID: id) == nil)
    }

    @Test("startup recovery adopts retained recording partial before failing stale meeting")
    func startupRecoveryAdoptsRetainedRecordingPartial() throws {
        let store = try makeStore()
        let configStore = makeConfigStore()
        let id = try store.createLiveMeeting(title: "Crashed Audio", calendarEventID: nil, startTime: Date())
        let writer = try MeetingRecordingWriter(meetingID: id)
        writer.appendSystem(Array(repeating: 1_200, count: 16_100))
        writer.markPauseBoundary()
        let partialURL = try #require(writer.partialURLForTesting())
        writer.closeWithoutFinalizingForTesting()
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let controller = makeController(configStore: configStore, dictationStore: store)
        controller.updateConfig { $0.meetingRecordingFileFormat = MeetingRecordingFileFormat.m4a.rawValue }

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        let savedRecordingPath = try #require(meeting.savedRecordingPath)
        let savedURL = URL(fileURLWithPath: savedRecordingPath)
        defer { try? FileManager.default.removeItem(at: savedURL) }
        #expect(meeting.status == .failed)
        #expect(savedURL.pathExtension == "wav")
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
        #expect(FileManager.default.fileExists(atPath: partialURL.path) == false)
        #expect(try audioDuration(from: savedURL) > 1)
    }

    @Test("startup recovery keeps linked saved recording when final persistence failed")
    func startupRecoveryKeepsLinkedSavedRecordingWhenFinalPersistenceFailed() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Linked Audio", calendarEventID: nil, startTime: Date())
        let savedRecordingURL = try makeRetainedRecordingURL()
        defer { try? FileManager.default.removeItem(at: savedRecordingURL) }
        try store.updateMeetingSavedRecordingPath(id: id, path: savedRecordingURL.path)
        let controller = makeController(dictationStore: store)

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
        #expect(meeting.savedRecordingPath == savedRecordingURL.path)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
    }

    @Test("showMeetingTemplatesManager preserves current meetings context and presents manager")
    func showMeetingTemplatesManagerPresentsManager() {
        let controller = makeController()

        controller.appState.selectedTab = .settings
        controller.appState.meetingsNavigationState = .document(404)
        controller.appState.isMeetingTemplatesManagerPresented = false

        controller.showMeetingTemplatesManager()

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.meetingsNavigationState == .document(404))
        #expect(controller.appState.isMeetingTemplatesManagerPresented == true)
    }

    @Test("deleteCustomMeetingTemplate resets default template when deleting the active default")
    func deletingDefaultCustomTemplateResetsDefaultToAuto() {
        let controller = makeController()
        let customTemplate = CustomMeetingTemplate(
            id: "tmpl_customer_followup",
            name: "Customer Follow-Up",
            prompt: "## Summary",
            icon: "person.2.fill"
        )

        controller.updateConfig {
            $0.customMeetingTemplates = [customTemplate]
            $0.defaultMeetingTemplateID = customTemplate.id
        }

        controller.deleteCustomMeetingTemplate(id: customTemplate.id)

        #expect(controller.config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(controller.appState.config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(controller.config.customMeetingTemplates.isEmpty)
    }

    @Test("meeting transcription backend selection is independent from dictation backend")
    func meetingTranscriptionBackendSelectionIsIndependent() {
        let controller = makeController()

        controller.selectBackend(.parakeetEnglish)
        controller.selectMeetingTranscriptionBackend(.whisperLargeTurbo, requireDownloaded: false)

        #expect(controller.appState.selectedBackend == .parakeetEnglish)
        #expect(controller.appState.selectedMeetingTranscriptionBackend == .whisperLargeTurbo)
        #expect(controller.appState.config.sttModel == BackendOption.parakeetEnglish.model)
        #expect(controller.appState.config.meetingTranscriptionModel == BackendOption.whisperLargeTurbo.model)
    }

    private func makeMeeting(
        id: Int64,
        title: String,
        rawTranscript: String = "Transcript",
        formattedNotes: String = "## Summary",
        wordCount: Int = 42,
        micAudioPath: String? = nil,
        systemAudioPath: String? = nil,
        savedRecordingPath: String? = nil,
        status: MeetingStatus = .completed,
        manualNotes: String = ""
    ) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            startTime: "2026-03-24 10:00",
            durationSeconds: 1800,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            wordCount: wordCount,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: micAudioPath,
            systemAudioPath: systemAudioPath,
            savedRecordingPath: savedRecordingPath,
            status: status,
            manualNotes: manualNotes,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )
    }
}

@Suite("Meeting browser logic", .muesliHermeticSupport)
struct MeetingBrowserLogicTests {

    @Test("available filters expand with older meeting history")
    func availableFiltersExpandWithHistory() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 1, daysAgo: 40, title: "Oldest"),
            makeMeeting(id: 2, daysAgo: 1, title: "Recent")
        ]

        let filters = MeetingBrowserLogic.availableFilters(for: meetings, now: now, calendar: calendar)

        #expect(filters == [.all, .last2Days, .lastWeek, .last2Weeks, .lastMonth, .last3Months])
    }

    @Test("filtering excludes invalid dates and sorts newest first")
    func filteringNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 1, daysAgo: 10, title: "Too old"),
            makeMeeting(id: 2, daysAgo: 2, title: "Recent A"),
            makeMeeting(id: 3, daysAgo: 1, title: "Recent B"),
            makeMeeting(id: 4, rawDate: "not-a-date", title: "Invalid")
        ]

        let filtered = MeetingBrowserLogic.filteredMeetings(
            from: meetings,
            filter: .lastWeek,
            sort: .newestFirst,
            now: now,
            calendar: calendar
        )

        #expect(filtered.map(\.id) == [3, 2])
    }

    @Test("all filter keeps invalid dates and oldest-first pushes them to the front")
    func allFilterOldestFirst() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 10, daysAgo: 2, title: "Recent"),
            makeMeeting(id: 11, daysAgo: 8, title: "Older"),
            makeMeeting(id: 12, rawDate: "invalid-date", title: "Invalid")
        ]

        let filtered = MeetingBrowserLogic.filteredMeetings(
            from: meetings,
            filter: .all,
            sort: .oldestFirst,
            now: now,
            calendar: calendar
        )

        #expect(filtered.map(\.id) == [12, 11, 10])
    }

    @Test("formatStartTime converts UTC ISO timestamps to the requested timezone")
    func formatStartTimeConvertsUTC() {
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        guard let date = MeetingBrowserLogic.parseDate("2025-06-15T19:30:45Z") else {
            Issue.record("Expected ISO timestamp to parse")
            return
        }

        let formatted = MeetingBrowserLogic.formatStartTime(
            "2025-06-15T19:30:45Z",
            locale: Locale(identifier: "en_US"),
            timeZone: timeZone
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        #expect(components.year == 2025)
        #expect(components.month == 6)
        #expect(components.day == 15)
        #expect(components.hour == 12)
        #expect(components.minute == 30)
        #expect(formatted.contains("Jun 15, 2025"))
        #expect(formatted.contains("12:30"))
        #expect(formatted.localizedCaseInsensitiveContains("PM"))
    }

    private static func isoDate(daysAgo: Int, now: Date, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func makeMeeting(id: Int64, daysAgo: Int, title: String) -> MeetingRecord {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        return makeMeeting(id: id, rawDate: Self.isoDate(daysAgo: daysAgo, now: now, calendar: calendar), title: title)
    }

    private func makeMeeting(id: Int64, rawDate: String, title: String) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            startTime: rawDate,
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Summary",
            wordCount: 42,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )
    }
}
