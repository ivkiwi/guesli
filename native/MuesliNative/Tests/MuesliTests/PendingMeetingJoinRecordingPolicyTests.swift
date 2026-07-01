import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Pending meeting join recording policy")
struct PendingMeetingJoinRecordingPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(
        _ rawValue: String = "https://meet.google.com/aaa-bbbb-ccc"
    ) throws -> PendingMeetingJoinRecordingPolicy.Request {
        let url = try #require(URL(string: rawValue))
        return try #require(PendingMeetingJoinRecordingPolicy.Request(meetingURL: url))
    }

    private func candidate(
        id: String = "googleMeet:meet.google.com/aaa-bbbb-ccc",
        platform: MeetingCandidate.Platform = .googleMeet,
        url: String? = nil,
        evidence: Set<MeetingCandidate.Evidence> = [.micActive]
    ) -> MeetingCandidate {
        MeetingCandidate(
            id: id,
            platform: platform,
            appName: "Chrome",
            url: url,
            evidence: evidence,
            startedAt: now,
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 1234
        )
    }

    @Test("starts when candidate ID matches request")
    func startsWhenCandidateIDMatchesRequest() throws {
        #expect(PendingMeetingJoinRecordingPolicy.shouldStartRecording(
            request: try request(),
            candidate: candidate()
        ))
    }

    @Test("starts when candidate URL matches request")
    func startsWhenCandidateURLMatchesRequest() throws {
        #expect(PendingMeetingJoinRecordingPolicy.shouldStartRecording(
            request: try request(),
            candidate: candidate(
                id: "browser:com.google.Chrome:session:1",
                url: "https://meet.google.com/aaa-bbbb-ccc?authuser=0",
                evidence: [.audioInputProcess]
            )
        ))
    }

    @Test("starts when unknown candidate URL matches request platform")
    func startsWhenUnknownCandidateURLMatchesRequestPlatform() throws {
        #expect(PendingMeetingJoinRecordingPolicy.shouldStartRecording(
            request: try request(),
            candidate: candidate(
                id: "browser:com.google.Chrome:session:1",
                platform: .unknown,
                url: "https://meet.google.com/aaa-bbbb-ccc?authuser=0",
                evidence: [.audioInputProcess]
            )
        ))
    }

    @Test("ignores URL from another platform")
    func ignoresURLFromAnotherPlatform() throws {
        #expect(!PendingMeetingJoinRecordingPolicy.shouldStartRecording(
            request: try request("https://zoom.us/j/123456789"),
            candidate: candidate(
                id: "browser:com.google.Chrome:session:1",
                platform: .unknown,
                url: "https://meet.google.com/aaa-bbbb-ccc",
                evidence: [.audioInputProcess]
            )
        ))
    }

    @Test("ignores non-matching candidate ID")
    func ignoresNonMatchingCandidateID() throws {
        #expect(!PendingMeetingJoinRecordingPolicy.shouldStartRecording(
            request: try request(),
            candidate: candidate(id: "googleMeet:meet.google.com/ddd-eeee-fff")
        ))
    }

    @Test("ignores matching candidate without evidence")
    func ignoresMatchingCandidateWithoutEvidence() throws {
        let request = try request()
        let candidate = candidate(evidence: [])

        #expect(PendingMeetingJoinRecordingPolicy.matches(request: request, candidate: candidate))
        #expect(!PendingMeetingJoinRecordingPolicy.shouldStartRecording(
            request: request,
            candidate: candidate
        ))
    }

    @Test("unidentified request does not match arbitrary Google Meet")
    func unidentifiedRequestDoesNotMatchArbitraryGoogleMeet() throws {
        let url = try #require(URL(string: "https://meet.google.com/not-a-room"))
        let request = PendingMeetingJoinRecordingPolicy.Request(meetingURL: url)

        #expect(request == nil)
        #expect(!PendingMeetingJoinRecordingPolicy.shouldStartRecording(
            request: request,
            candidate: candidate()
        ))
    }
}
