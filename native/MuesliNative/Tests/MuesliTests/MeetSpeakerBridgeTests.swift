import CoreAudio
import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meet speaker bridge")
struct MeetSpeakerBridgeTests {
    @Test("parses extension speaker observation JSON")
    func parsesObservationJSON() throws {
        let data = """
        {"meetingURL":"https://meet.google.com/abc-defg-hij","speakerName":"Alice Owner","participants":[{"name":"Alice Owner"},{"name":"Me","isSelf":true}],"source":"google-meet-extension"}
        """.data(using: .utf8)!

        let observation = try #require(MeetSpeakerBridgeServer.parseObservation(data))

        #expect(observation.meetingURL == "https://meet.google.com/abc-defg-hij")
        #expect(observation.speakerName == "Alice Owner")
        #expect(observation.participants.map(\.name) == ["Alice Owner", "Me"])
        #expect(observation.participants[1].isSelf)
        #expect(observation.source == "google-meet-extension")
    }

    @Test("parses participants-only extension update")
    func parsesParticipantsOnlyUpdate() throws {
        let data = """
        {"meetingURL":"https://meet.google.com/abc-defg-hij","participants":["Alice Owner",{"name":"Bob Reviewer"}],"source":"google-meet-extension"}
        """.data(using: .utf8)!

        let observation = try #require(MeetSpeakerBridgeServer.parseObservation(data))

        #expect(observation.speakerName == nil)
        #expect(observation.participants.map(\.name) == ["Alice Owner", "Bob Reviewer"])
    }

    @Test("parses client observation timestamp")
    func parsesClientObservationTimestamp() throws {
        let data = """
        {"speakerName":"Alice Owner","observedAtMs":1710000000123,"source":"google-meet-extension"}
        """.data(using: .utf8)!

        let observation = try #require(MeetSpeakerBridgeServer.parseObservation(data))

        #expect(abs(observation.observedAt.timeIntervalSince1970 - 1_710_000_000.123) < 0.001)
    }

    @Test("parses backup batch and inherits root metadata")
    func parsesBackupBatch() {
        let data = """
        {"meetingURL":"https://meet.google.com/abc-defg-hij","source":"google-meet-extension-backup","observations":[{"speakerName":"Alice Owner","observedAtMs":1710000000123},{"participants":[{"name":"Bob Reviewer"}],"observedAtMs":1710000002123}]}
        """.data(using: .utf8)!

        let observations = MeetSpeakerBridgeServer.parseObservations(data)

        #expect(observations.count == 2)
        #expect(observations[0].speakerName == "Alice Owner")
        #expect(observations[0].meetingURL == "https://meet.google.com/abc-defg-hij")
        #expect(observations[0].source == "google-meet-extension-backup")
        #expect(observations[1].participants.map(\.name) == ["Bob Reviewer"])
        #expect(abs(observations[1].observedAt.timeIntervalSince1970 - 1_710_000_002.123) < 0.001)
    }

    @Test("maps observed Meet speaker names to diarization clusters")
    func mapsSpeakerNamesToDiarizationClusters() {
        let start = Date(timeIntervalSince1970: 1000)
        let diarization = [
            makeDiarSeg(speakerId: "spk_0", start: 0.0, end: 5.0),
            makeDiarSeg(speakerId: "spk_1", start: 6.0, end: 12.0),
        ]
        let observations = [
            MeetSpeakerObservation(meetingURL: nil, speakerName: "Alice Owner", participants: [], observedAt: start.addingTimeInterval(1.0), source: "test"),
            MeetSpeakerObservation(meetingURL: nil, speakerName: "Alice Owner", participants: [], observedAt: start.addingTimeInterval(3.0), source: "test"),
            MeetSpeakerObservation(meetingURL: nil, speakerName: "Bob Reviewer", participants: [], observedAt: start.addingTimeInterval(8.0), source: "test"),
        ]

        let map = MeetingSession.speakerNameMap(
            diarizationSegments: diarization,
            observations: observations,
            meetingStart: start
        )

        #expect(map["spk_0"] == "Alice Owner")
        #expect(map["spk_1"] == "Bob Reviewer")
    }

    @Test("merges calendar and observed Meet participants")
    func mergesCalendarAndObservedMeetParticipants() {
        let calendar = [
            MeetingParticipant(name: "Alice Owner", email: "alice@example.com", isOrganizer: true, isSelf: false),
        ]
        let observations = [
            MeetSpeakerObservation(
                meetingURL: nil,
                speakerName: nil,
                participants: [
                    MeetingParticipant(name: "Alice Owner", email: nil, isOrganizer: false, isSelf: false),
                    MeetingParticipant(name: "Bob Reviewer", email: nil, isOrganizer: false, isSelf: false),
                ],
                observedAt: Date(),
                source: "test"
            ),
        ]

        let merged = MeetingSession.mergedParticipants(
            calendar,
            MeetingSession.observedParticipants(from: observations)
        )

        #expect(merged.map(\.summaryLabel) == ["Alice Owner <alice@example.com>", "Bob Reviewer"])
    }

    @Test("summary context includes participant candidates with anti-guessing guard")
    func summaryContextIncludesParticipantCandidates() {
        let context = MeetingSession.summaryContext(
            participants: [
                MeetingParticipant(name: "Alice Owner", email: "alice@example.com", isOrganizer: true, isSelf: false),
                MeetingParticipant(name: "Me", email: "me@example.com", isOrganizer: false, isSelf: true),
            ],
            visualContext: "Slide title: Roadmap"
        )

        #expect(context.contains("Meeting participant candidates:"))
        #expect(context.contains("- Alice Owner <alice@example.com>"))
        #expect(!context.contains("- Me <me@example.com>"))
        #expect(context.contains("Do not assign a Speaker N label"))
        #expect(context.contains("Slide title: Roadmap"))
    }

#if DEBUG
    @Test("bridge ingest attaches observation to active meeting session")
    func bridgeIngestAttachesObservationToActiveMeetingSession() throws {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let data = """
        {"meetingURL":"https://meet.google.com/abc-defg-hij","speakerName":"Alice Owner","participants":[{"name":"Alice Owner"},{"name":"Bob Reviewer"}],"observedAtMs":1710000001000,"source":"google-meet-extension"}
        """.data(using: .utf8)!
        let observation = try #require(MeetSpeakerBridgeServer.parseObservations(data).first)
        let session = makeSession()
        session.setRecordingForTesting(true)

        let route = MeetSpeakerObservationRouting.route(
            matchesActiveSource: true,
            hasActiveRecordingSession: session.isRecording,
            canBufferForPendingMeeting: false
        )
        #expect(route == .recordToActiveMeeting)
        if route == .recordToActiveMeeting {
            session.recordSpeakerObservation(observation)
        }

        let stored = session.speakerObservationsForTesting()
        #expect(stored.count == 1)
        #expect(session.speakerObservationStats() == MeetSpeakerObservationStats(
            observationsReceived: 1,
            speakerEvents: 1,
            participantSnapshots: 1
        ))

        let speakerMap = MeetingSession.speakerNameMap(
            diarizationSegments: [makeDiarSeg(speakerId: "spk_0", start: 0.0, end: 3.0)],
            observations: stored,
            meetingStart: start
        )
        #expect(speakerMap["spk_0"] == "Alice Owner")
        #expect(MeetingSession.observedParticipants(from: stored).map(\.name) == ["Alice Owner", "Bob Reviewer"])
    }
#endif

    @Test("bridge routing drops observations when no meeting is active")
    func bridgeRoutingDropsObservationsWhenNoMeetingIsActive() throws {
        let data = """
        {"meetingURL":"https://meet.google.com/abc-defg-hij","speakerName":"Alice Owner","source":"google-meet-extension"}
        """.data(using: .utf8)!
        let observation = try #require(MeetSpeakerBridgeServer.parseObservation(data))
        let route = MeetSpeakerObservationRouting.route(
            matchesActiveSource: true,
            hasActiveRecordingSession: false,
            canBufferForPendingMeeting: false
        )
        var stats = MeetSpeakerBridgeRoutingStats()

        stats.recordReceived(observation)
        if route == .dropNoActiveMeeting {
            stats.droppedNoActiveMeeting += 1
        }

        #expect(route == .dropNoActiveMeeting)
        #expect(stats.received.observationsReceived == 1)
        #expect(stats.received.speakerEvents == 1)
        #expect(stats.droppedNoActiveMeeting == 1)
        #expect(stats.matchedToMeeting == 0)
    }

    private func makeDiarSeg(speakerId: String, start: Float, end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }

#if DEBUG
    private func makeSession() -> MeetingSession {
        MeetingSession(
            title: "Bridge test",
            calendarEventID: nil,
            backend: .whisper,
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            config: AppConfig(),
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: MeetSpeakerBridgeFakeMeetingMicRecorder()
        )
    }
#endif
}

#if DEBUG
private final class MeetSpeakerBridgeFakeMeetingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?

    func prepare() throws {}
    func start() throws {}
    func pause() {}
    func resume() {}
    func stop() -> URL? { nil }
    func cancel() {}
    func currentPower() -> Float { -80 }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: .systemDefaultStreaming,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }
}
#endif
