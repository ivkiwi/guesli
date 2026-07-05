import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("SpeechSegment")
struct SpeechSegmentTests {

    @Test("stores start, end, text")
    func basicConstruction() {
        let segment = SpeechSegment(start: 1.5, end: 3.0, text: "Hello world")
        #expect(segment.start == 1.5)
        #expect(segment.end == 3.0)
        #expect(segment.text == "Hello world")
    }
}

@Suite("SpeechTranscriptionResult")
struct SpeechTranscriptionResultTests {

    @Test("stores text and segments")
    func basicConstruction() {
        let result = SpeechTranscriptionResult(
            text: "Full text",
            segments: [
                SpeechSegment(start: 0, end: 1, text: "Full"),
                SpeechSegment(start: 1, end: 2, text: "text"),
            ]
        )
        #expect(result.text == "Full text")
        #expect(result.segments.count == 2)
    }

    @Test("empty result")
    func emptyResult() {
        let result = SpeechTranscriptionResult(text: "", segments: [])
        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
    }
}

@Suite("Qwen3 inference gate")
struct Qwen3InferenceGateTests {

    @Test("cancelled waiter is removed before next slot")
    func cancelledWaiterDoesNotConsumeSlot() async throws {
        let gate = Qwen3InferenceGate()
        try await gate.acquire()

        let cancelled = Task {
            try await gate.acquire()
            await gate.release()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))
        #expect(await gate.queuedWaiterCount() == 1)

        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await gate.queuedWaiterCount() == 0)

        let next = Task {
            try await gate.acquire()
            await gate.release()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))
        await gate.release()
        #expect(try await next.value)

        do {
            _ = try await cancelled.value
            Issue.record("Cancelled waiter unexpectedly acquired the inference slot")
        } catch is CancellationError {
            // Expected path.
        } catch {
            Issue.record("Cancelled waiter failed with unexpected error: \(error)")
        }
    }
}

@Suite("TranscriptionCoordinator routing")
struct TranscriptionCoordinatorTests {

    @Test("coordinator initializes without crash")
    func initDoesNotCrash() {
        let _ = TranscriptionCoordinator()
    }

    @Test("backend routing covers all known backends")
    func allBackendsCovered() {
        let backends = Set(BackendOption.all.map(\.backend))
        #expect(backends == TranscriptionCoordinator.explicitlyRoutedBackendIdentifiers.union(["fluidaudio"]))
    }

    @Test("routes ChatGPT dictation cleanup through external client")
    func routesChatGPTDictationCleanupThroughExternalClient() async throws {
        let recorder = TranscriptCleanupCallRecorder()
        let coordinator = TranscriptionCoordinator(externalTranscriptCleanup: { text, appContext, settings in
            await recorder.record(text: text, appContext: appContext, settings: settings)
            return "Ship the release."
        })
        var config = AppConfig()
        config.transcriptCleanupProvider = TranscriptCleanupProviderOption.chatGPT.rawValue
        config.postProcessorSystemPrompt = "Clean dictation"
        config.chatGPTModel = "gpt-summary"
        config.chatGPTDictationCleanupModel = "gpt-dictation"
        await coordinator.setTranscriptCleanupSettings(TranscriptCleanupSettings(config: config))

        let result = await coordinator.postProcessDictationIfNeeded(
            SpeechTranscriptionResult(text: "um ship the release", segments: [
                SpeechSegment(start: 0, end: 1, text: "um ship the release"),
            ]),
            backend: .whisper,
            enabled: true,
            appContext: "Release notes"
        )

        let call = await recorder.recordedCall()
        #expect(result?.text == "Ship the release.")
        #expect(result?.segments.isEmpty == true)
        #expect(call?.text == "um ship the release")
        #expect(call?.appContext == "Release notes")
        #expect(call?.settings.provider == .chatGPT)
        #expect(call?.settings.systemPrompt == "Clean dictation")
        #expect(call?.settings.chatGPTModel == "gpt-dictation")
    }

    @Test("falls back when external dictation cleanup fails")
    func fallsBackWhenExternalDictationCleanupFails() async {
        let coordinator = TranscriptionCoordinator(externalTranscriptCleanup: { _, _, _ in
            throw TranscriptCleanupError.emptyResponse("ChatGPT (subscription)")
        })
        await coordinator.setTranscriptCleanupSettings(TranscriptCleanupSettings(provider: .chatGPT))

        let result = await coordinator.postProcessDictationIfNeeded(
            SpeechTranscriptionResult(text: "raw dictation", segments: []),
            backend: .whisper,
            enabled: true
        )

        #expect(result == nil)
    }

    @Test("falls back when ChatGPT dictation cleanup times out")
    func fallsBackWhenChatGPTDictationCleanupTimesOut() async {
        let coordinator = TranscriptionCoordinator(externalTranscriptCleanup: { _, _, _ in
            throw URLError(.timedOut)
        })
        await coordinator.setTranscriptCleanupSettings(TranscriptCleanupSettings(provider: .chatGPT))

        let result = await coordinator.postProcessDictationIfNeeded(
            SpeechTranscriptionResult(text: "raw dictation", segments: []),
            backend: .whisper,
            enabled: true
        )

        #expect(result == nil)
    }
}

private struct TranscriptCleanupCall: Sendable {
    let text: String
    let appContext: String?
    let settings: TranscriptCleanupSettings
}

private actor TranscriptCleanupCallRecorder {
    private var call: TranscriptCleanupCall?

    func record(text: String, appContext: String?, settings: TranscriptCleanupSettings) {
        call = TranscriptCleanupCall(text: text, appContext: appContext, settings: settings)
    }

    func recordedCall() -> TranscriptCleanupCall? {
        call
    }
}

@Suite("CohereTranscribeLanguage")
struct CohereTranscribeLanguageTests {

    @Test("english prompt ids match the current default prompt")
    func englishPromptIds() {
        #expect(
            CohereTranscribeLanguage.english.promptIds == [13764, 7, 4, 16, 62, 62, 5, 9, 11, 13]
        )
    }

    @Test("german prompt ids swap in the german language token")
    func germanPromptIds() {
        #expect(
            CohereTranscribeLanguage.german.promptIds == [13764, 7, 4, 16, 76, 76, 5, 9, 11, 13]
        )
    }

    @Test("unset and unsupported codes fall back to english")
    func resolvedFallbacks() {
        #expect(CohereTranscribeLanguage.resolved(nil) == .english)
        #expect(CohereTranscribeLanguage.resolved("xx") == .english)
    }
}

@Suite("CohereTranscribeUtils")
struct CohereTranscribeUtilsTests {

    @Test("single transcript returns unchanged")
    func singleTranscript() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts(["Hello world"])
        #expect(result == "Hello world")
    }

    @Test("empty list returns empty string")
    func emptyList() {
        #expect(CohereTranscribeUtils.mergeOverlappingTranscripts([]) == "")
    }

    @Test("no overlap joins with space")
    func noOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The quick brown fox",
            "jumped over the lazy dog",
        ])
        #expect(result == "The quick brown fox jumped over the lazy dog")
    }

    @Test("exact trigram overlap deduplicates")
    func exactOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "I went to the store and bought some milk",
            "and bought some milk then came home",
        ])
        #expect(result == "I went to the store and bought some milk then came home")
    }

    @Test("case-insensitive trigram matching")
    func caseInsensitive() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The Model Works well",
            "the model works well on device",
        ])
        #expect(result == "The Model Works well on device")
    }

    @Test("shared overlap merger returns only unique suffix")
    func sharedOverlapMergerUniqueSuffix() {
        let result = TranscriptOverlapMerger.uniqueAddition(
            previous: "Speaker one explains the migration plan in detail",
            next: "the migration plan in detail then assigns owners"
        )
        #expect(result == "then assigns owners")
    }

    @Test("cleanTranscript strips endoftext token")
    func stripsEndOfText() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello world<|endoftext|>garbage after")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript strips special tokens")
    func stripsSpecialTokens() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello<|nospeech|> world<|pnc|>")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript trims repeated suffix")
    func trimsRepeatedSuffix() {
        // Split on ". " produces: ["First", "Second", "Third", "Fourth", "Second", "more"]
        // Position 4 "Second" matches position 1 "Second", i-j=3 ≤ 3 → truncate at position 4
        let result = CohereTranscribeUtils.cleanTranscript(
            "First. Second. Third. Fourth. Second. more text"
        )
        #expect(result == "First. Second. Third. Fourth.")
    }

    @Test("cleanTranscript passes normal text unchanged")
    func normalTextUnchanged() {
        #expect(CohereTranscribeUtils.cleanTranscript("Normal transcription text.") == "Normal transcription text.")
    }
}

@Suite("GigaAMV3FileChunking")
struct GigaAMV3FileChunkingTests {

    @Test("short files use one passthrough window")
    func shortFilesUseOnePassthroughWindow() {
        let sampleCount = 25 * GigaAMV3FileChunking.sampleRate
        #expect(GigaAMV3FileChunking.windows(sampleCount: sampleCount) == [0..<sampleCount])
        #expect(!GigaAMV3FileChunking.shouldChunk(sampleCount: sampleCount))
    }

    @Test("long files use 20 second windows with 2 second overlap")
    func longFilesUseOverlappingWindows() {
        let sampleRate = GigaAMV3FileChunking.sampleRate
        let sampleCount = 61 * sampleRate
        let windows = GigaAMV3FileChunking.windows(sampleCount: sampleCount)

        #expect(windows == [
            0..<(20 * sampleRate),
            (18 * sampleRate)..<(38 * sampleRate),
            (36 * sampleRate)..<(56 * sampleRate),
            (54 * sampleRate)..<(61 * sampleRate),
        ])
    }

    @Test("empty audio produces no windows")
    func emptyAudioProducesNoWindows() {
        #expect(GigaAMV3FileChunking.windows(sampleCount: 0).isEmpty)
    }

    @Test("merge deduplicates overlap")
    func mergeDeduplicatesOverlap() {
        let result = GigaAMV3FileChunking.mergeTranscripts([
            "alpha beta gamma delta epsilon",
            "gamma delta epsilon zeta eta",
            "zeta eta theta iota",
        ])

        #expect(result == "alpha beta gamma delta epsilon zeta eta theta iota")
    }
}

@Suite("SenseVoiceFileChunking")
struct SenseVoiceFileChunkingTests {

    @Test("short files use one passthrough window")
    func shortFilesUseOnePassthroughWindow() {
        let sampleCount = 15 * SenseVoiceFileChunking.sampleRate
        #expect(SenseVoiceFileChunking.windows(sampleCount: sampleCount) == [0..<sampleCount])
        #expect(!SenseVoiceFileChunking.shouldChunk(sampleCount: sampleCount))
    }

    @Test("long files use 15 second windows with 2 second overlap")
    func longFilesUseOverlappingWindows() {
        let sampleRate = SenseVoiceFileChunking.sampleRate
        let sampleCount = 46 * sampleRate
        let windows = SenseVoiceFileChunking.windows(sampleCount: sampleCount)

        #expect(windows == [
            0..<(15 * sampleRate),
            (13 * sampleRate)..<(28 * sampleRate),
            (26 * sampleRate)..<(41 * sampleRate),
            (39 * sampleRate)..<(46 * sampleRate),
        ])
    }

    @Test("empty audio produces no windows")
    func emptyAudioProducesNoWindows() {
        #expect(SenseVoiceFileChunking.windows(sampleCount: 0).isEmpty)
    }

    @Test("merge deduplicates overlap")
    func mergeDeduplicatesOverlap() {
        let result = SenseVoiceFileChunking.mergeTranscripts([
            "alpha beta gamma delta epsilon",
            "gamma delta epsilon zeta eta",
            "epsilon zeta eta theta iota",
        ])

        #expect(result == "alpha beta gamma delta epsilon zeta eta theta iota")
    }
}

@Suite("TranscriptionEngineArtifactsFilter")
struct TranscriptionEngineArtifactsFilterTests {

    @Test("returns empty string for known artifact")
    func blankAudioArtifact() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[blank_audio]") == "")
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[BLANK_AUDIO]") == "")
    }

    @Test("trims surrounding whitespace before matching")
    func trailingWhitespace() {
        #expect(TranscriptionEngineArtifactsFilter.apply("  [blank_audio]  \n") == "")
    }

    @Test("passes through normal transcription unchanged")
    func normalTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("Hello world") == "Hello world")
    }

    @Test("passes through empty string unchanged")
    func emptyTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("") == "")
    }

    @Test("does not strip artifact when it appears mid-sentence")
    func midSentenceNotStripped() {
        let text = "Hello [blank_audio] world"
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == text)
    }

    @Test("strips leaked canary prompt suffix from transcript")
    func stripsCanaryPromptSuffix() {
        let text = """
        I'm actually now using the canary qwen model for dictation. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "I'm actually now using the canary qwen model for dictation."
        )
    }

    @Test("strips leaked canary prompt prefix from transcript")
    func stripsCanaryPromptPrefix() {
        let text = "Transcribe the spoken audio accurately. Testing whether this works or not."
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "Testing whether this works or not."
        )
    }

    @Test("removes pure prompt leakage entirely")
    func removesPurePromptLeakage() {
        let text = """
        Transcribe the spoken audio accurately. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == "")
    }
}

@Suite("Qwen3 post-processing output cleanup")
struct Qwen3PostProcessingOutputCleanerTests {

    @Test("removes think tags")
    func stripsThinkTags() {
        let raw = "<think>reasoning</think>Clean transcript"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "Clean transcript")
    }

    @Test("removes chat markup")
    func stripsChatMarkup() {
        let raw = "<|im_start|>assistant Hello world <|im_end|>"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "assistant Hello world")
    }

    @Test("removes leaked list-formatting instruction")
    func stripsLeakedPromptInstruction() {
        let raw = """
        If the speaker is dictating a list, such as saying "first point", "second point", or "bullet point", format each item on its own line.
        First point is ship it
        """
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "First point is ship it")
    }

    @Test("adds sentence-final period after terminal letters and digits")
    func addsSentenceFinalPeriodAfterLettersAndDigits() {
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("что в итоге получается") == "что в итоге получается.")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("не который MLX") == "не который MLX.")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("Release 42") == "Release 42.")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("single") == "single.")
    }

    @Test("preserves punctuation emoji and empty strings")
    func preservesTerminalPunctuationEmojiAndEmptyStrings() {
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("") == "")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done.") == "done.")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done?") == "done?")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done!") == "done!")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done…") == "done…")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done,") == "done,")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done:") == "done:")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done;") == "done;")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done-") == "done-")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done🙂") == "done🙂")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done 1️⃣") == "done 1️⃣")
    }

    @Test("handles trailing whitespace and closing quotes")
    func handlesTrailingWhitespaceAndClosingQuotes() {
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("done   ") == "done.   ")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("«так.»") == "«так.»")
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("\"so.\"") == "\"so.\"")
        // Closing quote after a word gets an outside period; moving it inside would rewrite dictated text.
        #expect(Qwen3PostProcessorOutputCleaner.appendSentenceFinalPeriodIfNeeded("\"so\"") == "\"so\".")
    }

    @Test("rejects assistant-style analysis output")
    func rejectsAssistantStyleAnalysisOutput() {
        let cleaned = """
        The user is asking about the system prompt.

        Analysis:
        This is a question.

        Action Plan:
        1. Answer the question.
        """
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects runaway output")
    func rejectsRunawayOutput() {
        let cleaned = String(repeating: "Remove the filler word like. ", count: 40)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects oversized cleanup output")
    func rejectsOversizedCleanupOutput() {
        let input = String(repeating: "Please ship this note. ", count: 10)
        let cleaned = String(repeating: "Please ship this note with unrelated additions. ", count: 12)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: input
        ))
    }

    @Test("rejects short-input hallucination expansion")
    func rejectsShortInputHallucinationExpansion() {
        let cleaned = String(repeating: "This unrelated response should not replace a short dictation. ", count: 3)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "um yeah"
        ))
    }
}

@Suite("External transcript cleanup client")
struct ExternalTranscriptCleanupClientTests {

    @Test("normalizes OpenAI-compatible endpoints")
    func normalizesOpenAICompatibleEndpoints() {
        #expect(
            ExternalTranscriptCleanupClient.resolveOpenAICompatibleURL("https://models.example.com")?.absoluteString ==
                "https://models.example.com/v1/chat/completions"
        )
        #expect(
            ExternalTranscriptCleanupClient.resolveOpenAICompatibleURL("https://models.example.com/v1")?.absoluteString ==
                "https://models.example.com/v1/chat/completions"
        )
        #expect(
            ExternalTranscriptCleanupClient.resolveOpenAICompatibleURL("https://models.example.com/openai/v1/chat/completions")?.absoluteString ==
                "https://models.example.com/openai/v1/chat/completions"
        )
    }

    @Test("extracts chat completions content")
    func extractsChatCompletionsContent() {
        let payload: [String: Any] = [
            "choices": [
                [
                    "message": [
                        "content": "Clean transcript",
                    ],
                ],
            ],
        ]
        #expect(ExternalTranscriptCleanupClient.extractChatCompletionsText(from: payload) == "Clean transcript")
    }

    @Test("validates external cleanup output with Qwen safeguards")
    func validatesExternalCleanupOutput() throws {
        let raw = "<think>nope</think>Ship the release."
        #expect(
            try ExternalTranscriptCleanupClient.validateOutput(
                raw,
                input: "um ship the release",
                provider: "OpenAI"
            ) == "Ship the release."
        )
    }

    @Test("cleans ChatGPT cleanup output through WHAM request")
    func cleansChatGPTCleanupOutputThroughWHAMRequest() async throws {
        let recorder = ChatGPTCleanupRequestRecorder(response: "<think>skip</think>Ship it.")
        let cleaned = try await ExternalTranscriptCleanupClient.cleanup(
            "um ship it",
            appContext: "Release notes",
            settings: TranscriptCleanupSettings(
                provider: .chatGPT,
                systemPrompt: "Clean dictation",
                chatGPTModel: "gpt-test"
            ),
            chatGPTRequest: { systemPrompt, userPrompt, model, timeout in
                await recorder.record(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: model,
                    timeout: timeout
                )
                return recorder.response
            }
        )

        let call = await recorder.recordedCall()
        #expect(cleaned == "Ship it.")
        #expect(call?.systemPrompt == "Clean dictation")
        #expect(call?.userPrompt.contains("App context:\nRelease notes") == true)
        #expect(call?.userPrompt.contains("Raw transcript:\num ship it") == true)
        #expect(call?.model == "gpt-test")
        #expect(call?.timeout == 10)
    }

    @Test("defaults ChatGPT dictation cleanup to nano model")
    func defaultsChatGPTDictationCleanupToNanoModel() async throws {
        let recorder = ChatGPTCleanupRequestRecorder(response: "Ship it.")
        _ = try await ExternalTranscriptCleanupClient.cleanup(
            "ship it",
            appContext: nil,
            settings: TranscriptCleanupSettings(provider: .chatGPT),
            chatGPTRequest: { systemPrompt, userPrompt, model, timeout in
                await recorder.record(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: model,
                    timeout: timeout
                )
                return recorder.response
            }
        )

        let call = await recorder.recordedCall()
        #expect(call?.model == AppConfig.defaultChatGPTDictationCleanupModel)
        #expect(call?.timeout == 10)
    }

    @Test("reports missing OpenAI cleanup credentials")
    func reportsMissingOpenAICleanupCredentials() throws {
        var config = AppConfig()
        config.transcriptCleanupProvider = TranscriptCleanupProviderOption.openAI.rawValue

        let status = try #require(TranscriptCleanupCredentialStatus.dictationCleanup(
            provider: .openAI,
            config: config,
            environment: [:]
        ))

        #expect(status.isWarning)
        #expect(status.message.contains("Meeting Summaries OpenAI credentials"))
        #expect(status.message.contains("key missing"))
    }

    @Test("reports configured OpenRouter cleanup credentials")
    func reportsConfiguredOpenRouterCleanupCredentials() throws {
        var config = AppConfig()
        config.openRouterAPIKey = "sk-or-test"

        let status = try #require(TranscriptCleanupCredentialStatus.dictationCleanup(
            provider: .openRouter,
            config: config,
            environment: [:]
        ))

        #expect(!status.isWarning)
        #expect(status.message.contains("Meeting Summaries OpenRouter credentials"))
        #expect(status.message.contains("key present"))
    }

    @Test("reports ChatGPT cleanup sign-in status")
    func reportsChatGPTCleanupSignInStatus() throws {
        let signedOut = try #require(TranscriptCleanupCredentialStatus.dictationCleanup(
            provider: .chatGPT,
            config: AppConfig(),
            isChatGPTAuthenticated: false,
            environment: [:]
        ))
        let signedIn = try #require(TranscriptCleanupCredentialStatus.dictationCleanup(
            provider: .chatGPT,
            config: AppConfig(),
            isChatGPTAuthenticated: true,
            environment: [:]
        ))

        #expect(signedOut.isWarning)
        #expect(signedOut.message.contains("Sign in with ChatGPT"))
        #expect(!signedIn.isWarning)
        #expect(signedIn.message.contains("Signed in with ChatGPT"))
    }

    @Test("warns when custom cleanup cannot use summary settings")
    func warnsWhenCustomCleanupCannotUseSummarySettings() throws {
        var config = AppConfig()
        config.customLLMFormat = CustomLLMFormat.anthropic.rawValue

        let status = try #require(TranscriptCleanupCredentialStatus.dictationCleanup(
            provider: .customLLM,
            config: config,
            environment: [:]
        ))

        #expect(status.isWarning)
        #expect(status.message.contains("OpenAI-compatible"))
    }

    @Test("formats external cleanup failure warning")
    func formatsExternalCleanupFailureWarning() {
        let warning = TranscriptCleanupFailureSurface.warning(
            provider: .openAI,
            error: TranscriptCleanupError.missingAPIKey("OpenAI")
        )

        #expect(warning.contains("OpenAI transcript cleanup failed; using raw transcript"))
        #expect(warning.contains("needs an API key"))
    }
}

private struct ChatGPTCleanupRequestCall: Sendable {
    let systemPrompt: String
    let userPrompt: String
    let model: String
    let timeout: TimeInterval
}

private actor ChatGPTCleanupRequestRecorder {
    let response: String
    private var call: ChatGPTCleanupRequestCall?

    init(response: String) {
        self.response = response
    }

    func record(systemPrompt: String, userPrompt: String, model: String, timeout: TimeInterval) {
        call = ChatGPTCleanupRequestCall(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            timeout: timeout
        )
    }

    func recordedCall() -> ChatGPTCleanupRequestCall? {
        call
    }
}
