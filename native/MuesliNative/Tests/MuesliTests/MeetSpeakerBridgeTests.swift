import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meet speaker bridge", .muesliHermeticSupport)
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

    private func makeDiarSeg(speakerId: String, start: Float, end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }
}
