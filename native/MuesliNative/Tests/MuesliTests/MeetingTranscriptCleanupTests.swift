import Foundation
import Testing
@testable import MuesliNativeApp

private struct StaticMeetingTranscriptCleaner: MeetingTranscriptCleaning {
    let output: String

    func cleanupMeetingTranscript(_ transcript: String, config: AppConfig) async throws -> String {
        output
    }
}

private struct ThrowingMeetingTranscriptCleaner: MeetingTranscriptCleaning {
    func cleanupMeetingTranscript(_ transcript: String, config: AppConfig) async throws -> String {
        throw NSError(domain: "MeetingTranscriptCleanupTests", code: 1)
    }
}

private struct MeetingChatGPTCleanupRequestCall: Sendable {
    let model: String
    let timeout: TimeInterval
}

private actor MeetingChatGPTCleanupRequestRecorder {
    private var call: MeetingChatGPTCleanupRequestCall?

    func record(model: String, timeout: TimeInterval) {
        call = MeetingChatGPTCleanupRequestCall(model: model, timeout: timeout)
    }

    func recordedCall() -> MeetingChatGPTCleanupRequestCall? {
        call
    }
}

private actor MeetingCleanupConcurrencyProbe {
    private var active = 0
    private var maximumActive = 0

    func begin() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }

    func maximum() -> Int {
        maximumActive
    }
}

@Suite("Meeting transcript cleanup pipeline", .muesliHermeticSupport)
struct MeetingTranscriptCleanupTests {
    @Test("successful cleanup preserves original transcript")
    func successfulCleanupPreservesOriginalTranscript() async {
        var config = AppConfig()
        config.enableMeetingTranscriptCleanup = true
        config.meetingTranscriptCleanupProvider = MeetingTranscriptCleanupProviderOption.chatGPT.rawValue

        let result = await MeetingTranscriptCleanupPipeline.cleanIfNeeded(
            transcript: "[00:00:01] Speaker 1: um hello hello",
            config: config,
            isChatGPTAuthenticated: true,
            cleaner: StaticMeetingTranscriptCleaner(output: "[00:00:01] Speaker 1: Hello.")
        )

        #expect(result.transcript == "[00:00:01] Speaker 1: Hello.")
        #expect(result.originalTranscript == "[00:00:01] Speaker 1: um hello hello")
    }

    @Test("cleanup error falls back to raw transcript")
    func cleanupErrorFallsBackToRawTranscript() async {
        var config = AppConfig()
        config.enableMeetingTranscriptCleanup = true
        config.meetingTranscriptCleanupProvider = MeetingTranscriptCleanupProviderOption.chatGPT.rawValue

        let result = await MeetingTranscriptCleanupPipeline.cleanIfNeeded(
            transcript: "[00:00:01] Speaker 1: raw words",
            config: config,
            isChatGPTAuthenticated: true,
            cleaner: ThrowingMeetingTranscriptCleaner()
        )

        #expect(result.transcript == "[00:00:01] Speaker 1: raw words")
        #expect(result.originalTranscript == nil)
    }

    @Test("unauthenticated cleanup keeps raw transcript")
    func unauthenticatedCleanupKeepsRawTranscript() async {
        var config = AppConfig()
        config.enableMeetingTranscriptCleanup = true
        config.meetingTranscriptCleanupProvider = MeetingTranscriptCleanupProviderOption.chatGPT.rawValue

        let result = await MeetingTranscriptCleanupPipeline.cleanIfNeeded(
            transcript: "[00:00:01] Speaker 1: raw words",
            config: config,
            isChatGPTAuthenticated: false,
            cleaner: StaticMeetingTranscriptCleaner(output: "cleaned")
        )

        #expect(result.transcript == "[00:00:01] Speaker 1: raw words")
        #expect(result.originalTranscript == nil)
    }

    @Test("ChatGPT meeting cleanup uses meeting cleanup model")
    func chatGPTMeetingCleanupUsesMeetingCleanupModel() async throws {
        let recorder = MeetingChatGPTCleanupRequestRecorder()
        var config = AppConfig()
        config.chatGPTModel = "gpt-summary"
        config.chatGPTMeetingCleanupModel = "gpt-meeting-cleanup"

        let cleaned = try await MeetingSummaryClient.cleanupMeetingTranscriptWithChatGPT(
            transcript: "[00:00:01] Speaker 1: um hello",
            config: config,
            chatGPTRequest: { _, _, model, timeout in
                await recorder.record(model: model, timeout: timeout)
                return "[00:00:01] Speaker 1: Hello."
            }
        )

        let call = await recorder.recordedCall()
        #expect(cleaned == "[00:00:01] Speaker 1: Hello.")
        #expect(call?.model == "gpt-meeting-cleanup")
        #expect(call?.timeout == 120)
    }

    @Test("ChatGPT meeting cleanup defaults to fast model")
    func chatGPTMeetingCleanupDefaultsToFastModel() async throws {
        let recorder = MeetingChatGPTCleanupRequestRecorder()

        _ = try await MeetingSummaryClient.cleanupMeetingTranscriptWithChatGPT(
            transcript: "[00:00:01] Speaker 1: hello",
            config: AppConfig(),
            chatGPTRequest: { _, _, model, timeout in
                await recorder.record(model: model, timeout: timeout)
                return "[00:00:01] Speaker 1: Hello."
            }
        )

        let call = await recorder.recordedCall()
        #expect(AppConfig.defaultChatGPTMeetingCleanupModel == "gpt-5.6-terra")
        #expect(call?.model == AppConfig.defaultChatGPTMeetingCleanupModel)
        #expect(call?.timeout == 120)
    }

    @Test("ChatGPT cleanup runs long chunks concurrently and preserves order")
    func chatGPTCleanupRunsChunksConcurrentlyInOrder() async throws {
        let probe = MeetingCleanupConcurrencyProbe()
        let transcript = (1...3)
            .map { "[00:00:0\($0)] Speaker \($0): " + String(repeating: "word ", count: 2_300) }
            .joined(separator: "\n")

        let cleaned = try await MeetingSummaryClient.cleanupMeetingTranscriptWithChatGPT(
            transcript: transcript,
            config: AppConfig(),
            chatGPTRequest: { _, prompt, _, _ in
                let index = [1, 2, 3].first { prompt.contains("Transcript chunk \($0) of 3") } ?? 0
                await probe.begin()
                try await Task.sleep(for: .milliseconds(index == 1 ? 40 : 10))
                await probe.end()
                return "cleaned-\(index)"
            }
        )

        #expect(cleaned == "cleaned-1\ncleaned-2\ncleaned-3")
        #expect(await probe.maximum() == 3)
    }
}
