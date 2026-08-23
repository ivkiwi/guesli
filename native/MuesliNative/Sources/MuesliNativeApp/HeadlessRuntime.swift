import Foundation
import FluidAudio
import os

public enum HeadlessTranscriptionModel: String, CaseIterable, Sendable {
    case gigaAMONNX = "gigaam-onnx"
    case parakeetV3 = "parakeet-v3"
    case parakeetV2 = "parakeet-v2"
    case parakeetUnified = "parakeet-unified"
    case parakeetEOU320ms = "parakeet-eou-320ms"
    case senseVoice = "sensevoice"
    case qwen3ASR = "qwen3-asr"
    case nemotron35 = "nemotron35"
    case cohere = "cohere"
    case whisperTinyEnglish = "whisper-tiny-english"
    case whisperSmallEnglish = "whisper-small-english"
    case whisperMediumEnglish = "whisper-medium-english"
    case whisperLargeTurbo = "whisper-large-turbo"

    fileprivate var backendOption: BackendOption {
        switch self {
        case .gigaAMONNX: .gigaAMV3Russian
        case .parakeetV3: .parakeetMultilingual
        case .parakeetV2: .parakeetEnglish
        case .parakeetUnified: .parakeetUnified
        case .parakeetEOU320ms:
            BackendOption(
                backend: "parakeet-eou-320ms",
                model: "FluidInference/parakeet-realtime-eou-120m-coreml/320ms",
                label: "Parakeet Realtime EOU",
                sizeLabel: MeetingParakeetLiveCaptionModelStore.sizeLabel,
                description: "Streaming English ASR with cumulative partials.",
                recommended: false
            )
        case .senseVoice: .senseVoiceSmall
        case .qwen3ASR: .qwen3Asr
        case .nemotron35: .nemotron35Multilingual
        case .cohere: .cohereTranscribe
        case .whisperTinyEnglish: .whisperTinyEnglish
        case .whisperSmallEnglish: .whisperSmall
        case .whisperMediumEnglish: .whisperMedium
        case .whisperLargeTurbo: .whisperLargeTurbo
        }
    }
}

public struct HeadlessTranscriptionResult: Sendable {
    public let text: String
    public let durationSeconds: Double
}

public actor HeadlessTranscriptionRuntime {
    private let coordinator = TranscriptionCoordinator()

    public init() {}

    public func transcribe(
        wavURL: URL,
        model: HeadlessTranscriptionModel,
        progress: (@Sendable (Double, String?) -> Void)? = nil,
        onPartial: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> HeadlessTranscriptionResult {
        let samples = try AudioConverter().resampleAudioFile(wavURL)
        let duration = Double(samples.count) / 16_000
        let result: SpeechTranscriptionResult

        if model == .parakeetEOU320ms {
            result = try await coordinator.transcribeParakeetEOU(
                samples: samples,
                progress: progress,
                onPartial: onPartial
            )
        } else {
            try await coordinator.preloadRequired(
                backend: model.backendOption,
                includeMeetingHelpers: false,
                progress: progress
            )
            result = try await coordinator.transcribeMeeting(
                at: wavURL,
                samples: samples,
                backend: model.backendOption
            )
        }

        return HeadlessTranscriptionResult(text: result.text, durationSeconds: duration)
    }

    public func shutdown() async {
        await coordinator.shutdown()
    }
}

public enum HeadlessMeetingSummaryRuntime {
    public static func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String {
        let configURL = supportDirectory.appendingPathComponent("config.json")
        let config: AppConfig
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            config = AppConfig()
        }
        return try await MeetingSummaryClient.summarize(
            transcript: transcript,
            meetingTitle: title,
            config: config
        )
    }
}

private final class HeadlessPartialState: @unchecked Sendable {
    private struct State {
        var seconds = 0.0
        var text = ""
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setSeconds(_ seconds: Double) {
        state.withLock { $0.seconds = seconds }
    }

    func receive(_ text: String, onPartial: (@Sendable (Double, String) -> Void)?) {
        let seconds = state.withLock { value -> Double in
            value.text = text
            return value.seconds
        }
        onPartial?(seconds, text)
    }

    var text: String { state.withLock { $0.text } }
}

extension TranscriptionCoordinator {
    func transcribeParakeetEOU(
        samples: [Float],
        progress: (@Sendable (Double, String?) -> Void)?,
        onPartial: (@Sendable (Double, String) -> Void)?
    ) async throws -> SpeechTranscriptionResult {
        progress?(0, "Loading Parakeet Realtime EOU...")
        try await MeetingParakeetLiveCaptionModelStore.download { fraction in
            progress?(fraction, "Downloading Parakeet Realtime EOU...")
        }
        let engine = try await MeetingParakeetLiveCaptionModelStore.makeEngine(label: "CLI")
        let state = HeadlessPartialState()
        await engine.setPartialHandler { text in
            state.receive(text, onPartial: onPartial)
        }

        do {
            let chunkSize = MeetingStreamingPartialSession.feedSamples
            var offset = 0
            while offset < samples.count {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, samples.count)
                var chunk = Array(samples[offset..<end])
                if chunk.count < chunkSize {
                    chunk.append(contentsOf: repeatElement(0, count: chunkSize - chunk.count))
                }
                state.setSeconds(Double(end) / 16_000)
                try await engine.process(samples: chunk)
                offset = end
            }
            try await engine.finish()
            await engine.shutdown()
        } catch {
            await engine.shutdown()
            throw error
        }

        let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        progress?(1, "Transcription complete")
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: Double(samples.count) / 16_000, text: text)]
        )
    }
}
