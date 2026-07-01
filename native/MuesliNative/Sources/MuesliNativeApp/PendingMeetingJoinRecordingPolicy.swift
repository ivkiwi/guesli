import Foundation

struct PendingMeetingJoinRecordingPolicy {
    struct Request: Equatable {
        let normalizedID: String
        let platform: MeetingCandidate.Platform

        init?(meetingURL: URL) {
            guard let normalized = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
                return nil
            }
            normalizedID = normalized.id
            platform = normalized.platform
        }
    }

    static func shouldStartRecording(request: Request?, candidate: MeetingCandidate?) -> Bool {
        guard let request, let candidate else { return false }
        return matches(request: request, candidate: candidate)
            && hasJoinedMeetingEvidence(candidate)
    }

    static func matches(request: Request, candidate: MeetingCandidate) -> Bool {
        guard candidate.platform == request.platform || candidate.platform == .unknown else {
            return false
        }
        if candidate.id == request.normalizedID || candidate.id.hasSuffix(":\(request.normalizedID)") {
            return true
        }
        if let url = candidate.url,
           let normalized = MeetingURLNormalizer.normalize(url),
           normalized.platform == request.platform,
           normalized.id == request.normalizedID {
            return true
        }
        return false
    }

    static func hasJoinedMeetingEvidence(_ candidate: MeetingCandidate) -> Bool {
        candidate.evidence.contains(.micActive)
            || candidate.evidence.contains(.cameraActive)
            || candidate.evidence.contains(.audioInputProcess)
    }
}
