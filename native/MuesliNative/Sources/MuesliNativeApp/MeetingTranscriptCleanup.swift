import Foundation

protocol MeetingTranscriptCleaning: Sendable {
    func cleanupMeetingTranscript(_ transcript: String, config: AppConfig) async throws -> String
}

struct ChatGPTMeetingTranscriptCleaner: MeetingTranscriptCleaning {
    func cleanupMeetingTranscript(_ transcript: String, config: AppConfig) async throws -> String {
        try await MeetingSummaryClient.cleanupMeetingTranscriptWithChatGPT(
            transcript: transcript,
            config: config
        )
    }
}

struct MeetingTranscriptCleanupResult: Equatable, Sendable {
    let transcript: String
    let originalTranscript: String?
}

enum MeetingTranscriptCleanupPipeline {
    static func cleanIfNeeded(
        transcript: String,
        config: AppConfig,
        isChatGPTAuthenticated: Bool,
        cleaner: MeetingTranscriptCleaning
    ) async -> MeetingTranscriptCleanupResult {
        let rawTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else {
            return MeetingTranscriptCleanupResult(transcript: transcript, originalTranscript: nil)
        }
        guard config.enableMeetingTranscriptCleanup else {
            return MeetingTranscriptCleanupResult(transcript: transcript, originalTranscript: nil)
        }
        guard config.resolvedMeetingTranscriptCleanupProvider == .chatGPT else {
            DiagnosticsLog.write("[meeting-cleanup] unsupported provider \(config.meetingTranscriptCleanupProvider); keeping raw transcript")
            return MeetingTranscriptCleanupResult(transcript: transcript, originalTranscript: nil)
        }
        guard isChatGPTAuthenticated else {
            DiagnosticsLog.write("[meeting-cleanup] ChatGPT not authenticated; keeping raw transcript")
            return MeetingTranscriptCleanupResult(transcript: transcript, originalTranscript: nil)
        }

        do {
            let cleaned = try await cleaner.cleanupMeetingTranscript(rawTranscript, config: config)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                DiagnosticsLog.write("[meeting-cleanup] empty cleanup response; keeping raw transcript")
                return MeetingTranscriptCleanupResult(transcript: transcript, originalTranscript: nil)
            }
            guard cleaned != rawTranscript else {
                return MeetingTranscriptCleanupResult(transcript: transcript, originalTranscript: nil)
            }
            DiagnosticsLog.write("[meeting-cleanup] cleaned transcript chars raw=\(rawTranscript.count) cleaned=\(cleaned.count)")
            return MeetingTranscriptCleanupResult(transcript: cleaned, originalTranscript: transcript)
        } catch {
            DiagnosticsLog.write("[meeting-cleanup] cleanup failed, keeping raw transcript: \(error.localizedDescription)")
            return MeetingTranscriptCleanupResult(transcript: transcript, originalTranscript: nil)
        }
    }
}
