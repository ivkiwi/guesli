import Foundation
import MuesliCore

enum MeetingResumePolicy {
    static func canResume(status: MeetingStatus) -> Bool {
        status == .completed
    }

    static let resumeSeparator = "\n\n— Resumed —\n\n"

    static func combinedResumeTranscript(prior: String, new: String) -> String {
        let trimmedPrior = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return prior }
        guard !trimmedPrior.isEmpty else { return new }
        return prior + resumeSeparator + new
    }

    static func hasNewTranscriptContent(prior: String, new: String) -> Bool {
        combinedResumeTranscript(prior: prior, new: new) != prior
    }
}
