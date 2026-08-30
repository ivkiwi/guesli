import Foundation
import MuesliCore

struct MeetingThreadContext {
    let predecessor: MeetingRecord?
    let successors: [MeetingRecord]
    let position: Int
    let count: Int
}

enum MeetingFollowUpPolicy {
    static let titlePrefix = "Follow-up: "
    static let maxCarriedNotesLength = 6000

    static func canStartFollowUp(status: MeetingStatus) -> Bool {
        status == .completed
    }

    static func followUpTitle(from predecessorTitle: String) -> String {
        let barePrefix = titlePrefix.trimmingCharacters(in: .whitespaces)
        var base = predecessorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(barePrefix) {
            base = String(base.dropFirst(barePrefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return base.isEmpty ? "Follow-up meeting" : titlePrefix + base
    }

    static func carriedContext(from predecessor: MeetingRecord) -> String? {
        guard predecessor.notesState == .structuredNotes else { return nil }
        return carriedContext(fromPredecessorNotes: predecessor.formattedNotes)
    }

    static func carriedContext(fromPredecessorNotes notes: String) -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxCarriedNotesLength else { return trimmed }
        return String(trimmed.prefix(maxCarriedNotesLength)) + "\n[…previous notes truncated]"
    }

    static func locallyCombinedNotes(previous: String?, current: String) -> String {
        let prior = previous?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prior.isEmpty else { return current }
        guard !latest.isEmpty else { return prior }
        return "## Previous meeting context\n\n\(prior)\n\n---\n\n## Follow-up notes\n\n\(latest)"
    }
}
