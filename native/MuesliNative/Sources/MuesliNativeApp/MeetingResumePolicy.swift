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

    /// The start origin a resumed meeting should be re-armed with.
    ///
    /// Resume reopens the *same* meeting row, so it should keep behaving like the
    /// meeting it is. Hardcoding `.manual` here silently discarded auto-stop:
    /// a recording armed from a detection prompt or a calendar event became
    /// unstoppable the moment the user resumed it, and ran until stopped by hand.
    ///
    /// `recordedOrigin` is nil when the original start is not known — the meeting
    /// was started in an earlier app session, so nothing in memory records how it
    /// began. Falling back to `.manual` there preserves the previous behaviour for
    /// exactly the case where inheriting is not possible, and never re-arms a
    /// recording against a meeting this process never observed starting.
    static func resumedStartOrigin(
        recordedOrigin: MeetingRecordingStartOrigin?
    ) -> MeetingRecordingStartOrigin {
        recordedOrigin ?? .manual
    }
}
