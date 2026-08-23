import AVFoundation
import Foundation
import FluidAudio
import os

enum HeadlessAudioLoadingStrategy: Equatable {
    case directSamples
    case streamedChunks
    case backendFile
}

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

    var audioLoadingStrategy: HeadlessAudioLoadingStrategy {
        switch self {
        case .gigaAMONNX: .directSamples
        case .parakeetEOU320ms: .streamedChunks
        default: .backendFile
        }
    }

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
    /// Offline backends ultimately materialize the complete 16 kHz waveform.
    /// Four hours is about 922 MB as Float32 and keeps accidental day-long files bounded.
    static let maximumBufferedAudioDurationSeconds: TimeInterval = 4 * 60 * 60

    private let coordinator = TranscriptionCoordinator()

    public init() {}

    public func transcribe(
        wavURL: URL,
        model: HeadlessTranscriptionModel,
        progress: (@Sendable (Double, String?) -> Void)? = nil,
        onPartial: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> HeadlessTranscriptionResult {
        let duration = try HeadlessWAVChunkReader.duration(at: wavURL)
        let result: SpeechTranscriptionResult

        switch model.audioLoadingStrategy {
        case .streamedChunks:
            result = try await coordinator.transcribeParakeetEOU(
                wavURL: wavURL,
                duration: duration,
                progress: progress,
                onPartial: onPartial
            )
        case .directSamples:
            try Self.validateBufferedDuration(duration, model: model)
            let samples = try AudioConverter().resampleAudioFile(wavURL)
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
        case .backendFile:
            try Self.validateBufferedDuration(duration, model: model)
            try await coordinator.preloadRequired(
                backend: model.backendOption,
                includeMeetingHelpers: false,
                progress: progress
            )
            result = try await coordinator.transcribeMeeting(
                at: wavURL,
                backend: model.backendOption
            )
        }

        return HeadlessTranscriptionResult(text: result.text, durationSeconds: duration)
    }

    public func shutdown() async {
        await coordinator.shutdown()
    }

    static func validateBufferedDuration(_ duration: TimeInterval, model: HeadlessTranscriptionModel) throws {
        guard duration <= maximumBufferedAudioDurationSeconds else {
            throw NSError(
                domain: "HeadlessTranscriptionRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(model.rawValue) supports audio up to 4 hours per CLI run."]
            )
        }
    }
}

enum HeadlessWAVChunkReader {
    static let sampleRate = 16_000.0

    static func duration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else {
            throw NSError(
                domain: "HeadlessWAVChunkReader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio file has an invalid sample rate."]
            )
        }
        return Double(file.length) / rate
    }

    @discardableResult
    static func forEachChunk(
        at url: URL,
        targetChunkSamples: Int,
        body: ([Float], TimeInterval) async throws -> Void
    ) async throws -> TimeInterval {
        precondition(targetChunkSamples > 0)
        let file = try AVAudioFile(forReading: url)
        let sourceRate = file.processingFormat.sampleRate
        guard sourceRate == sampleRate, file.processingFormat.channelCount == 1 else {
            throw NSError(
                domain: "HeadlessWAVChunkReader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Streaming input must be the prepared 16 kHz mono WAV."]
            )
        }
        let inputFramesPerChunk = AVAudioFrameCount(targetChunkSamples)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: inputFramesPerChunk
        ) else {
            throw NSError(
                domain: "HeadlessWAVChunkReader",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio streaming buffer."]
            )
        }

        let converter = AudioConverter(sampleRate: sampleRate)
        var emittedSamples = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let remaining = AVAudioFrameCount(min(
                AVAudioFramePosition(inputFramesPerChunk),
                file.length - file.framePosition
            ))
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }
            let samples = try converter.resampleBuffer(buffer)
            guard !samples.isEmpty else { continue }
            emittedSamples += samples.count
            try await body(samples, Double(emittedSamples) / sampleRate)
        }
        return Double(emittedSamples) / sampleRate
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
        wavURL: URL,
        duration: TimeInterval,
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
            try await HeadlessWAVChunkReader.forEachChunk(
                at: wavURL,
                targetChunkSamples: chunkSize
            ) { samples, seconds in
                var samples = samples
                if samples.count < chunkSize {
                    samples.append(contentsOf: repeatElement(0, count: chunkSize - samples.count))
                }
                state.setSeconds(seconds)
                try await engine.process(samples: samples)
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
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: duration, text: text)]
        )
    }
}
