import AVFoundation
import FluidAudio
import Foundation
import MuesliCore

enum SenseVoiceFileChunking {
    static let sampleRate = SenseVoiceConfig.sampleRate
    static let passthroughThresholdSeconds: TimeInterval = 15
    static let windowSeconds: TimeInterval = 15
    static let overlapSeconds: TimeInterval = 2

    static func windows(sampleCount: Int, sampleRate: Int = sampleRate) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        guard shouldChunk(sampleCount: sampleCount, sampleRate: sampleRate) else {
            return [0..<sampleCount]
        }

        let windowSamples = max(1, Int((windowSeconds * Double(sampleRate)).rounded()))
        let overlapSamples = min(Int((overlapSeconds * Double(sampleRate)).rounded()), windowSamples - 1)
        let stepSamples = windowSamples - overlapSamples
        var result: [Range<Int>] = []
        var start = 0

        while start < sampleCount {
            let end = min(start + windowSamples, sampleCount)
            result.append(start..<end)
            if end == sampleCount { break }
            start += stepSamples
        }

        return result
    }

    static func shouldChunk(sampleCount: Int, sampleRate: Int = sampleRate) -> Bool {
        Double(sampleCount) / Double(sampleRate) > passthroughThresholdSeconds
    }

    static func mergeTranscripts(_ transcripts: [String]) -> String {
        TranscriptOverlapMerger.merge(
            transcripts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

/// Native Swift transcription backend for FunASR's SenseVoiceSmall via FluidAudio.
actor SenseVoiceTranscriber {
    private var manager: SenseVoiceManager?
    private var isLoading = false
    private var hasCompletedWarmup = false
    private var loadGeneration: UInt64 = 0
    private static let precision: SenseVoiceEncoderPrecision = .int8

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "SenseVoice models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models if needed and initializes the SenseVoice manager.
    func loadModels(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        // Actor isolation makes this check-and-set race-free. Waiters retry after
        // a failed load so a transient download error does not poison the actor.
        while isLoading {
            try await Task.sleep(nanoseconds: 50_000_000)
            if manager != nil { return }
        }
        if manager != nil { return }
        let generation = loadGeneration

        isLoading = true
        defer { isLoading = false }

        fputs("[sensevoice] downloading/loading models...\n", stderr)
        let plan = ManagedASRModelPlans.senseVoice()
        let loadedManager = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(modelID: plan.modelID, message: "Loading SenseVoice into Core ML...")
            progressSnapshot?(preparing)
            progress?(0.95, preparing.message)
            let models = try SenseVoiceModels.load(from: modelDirectory, precision: Self.precision)
            return SenseVoiceManager(models: models)
        }
        let preparing = ModelDownloadProgress.preparing(modelID: plan.modelID, message: "Loading SenseVoice into Core ML...")
        guard generation == loadGeneration else { throw CancellationError() }
        self.manager = loadedManager
        await warmupIfNeeded(progress: progress)
        progress?(1.0, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[sensevoice] models ready\n", stderr)
    }

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let duration = try Self.audioDuration(url: wavURL)
        if duration <= SenseVoiceFileChunking.passthroughThresholdSeconds {
            let text = try await manager.transcribe(audioURL: wavURL)
            return (text, CFAbsoluteTimeGetCurrent() - start)
        }

        let samples = try AudioConverter(sampleRate: Double(SenseVoiceFileChunking.sampleRate))
            .resampleAudioFile(wavURL)
        let windows = SenseVoiceFileChunking.windows(sampleCount: samples.count)
        guard !windows.isEmpty else {
            return ("", CFAbsoluteTimeGetCurrent() - start)
        }

        fputs("[sensevoice] chunked transcription: \(windows.count) windows, \(String(format: "%.1f", duration))s\n", stderr)
        var transcripts: [String] = []
        transcripts.reserveCapacity(windows.count)
        for window in windows {
            try Task.checkCancellation()
            let text = try await manager.transcribe(audio: Array(samples[window]))
            transcripts.append(text)
        }

        let text = SenseVoiceFileChunking.mergeTranscripts(transcripts)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func transcribe(samples: [Float]) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let windows = SenseVoiceFileChunking.windows(sampleCount: samples.count)
        guard !windows.isEmpty else {
            return ("", CFAbsoluteTimeGetCurrent() - start)
        }

        fputs("[sensevoice] chunked transcription: \(windows.count) windows, \(String(format: "%.1f", Double(samples.count) / Double(SenseVoiceFileChunking.sampleRate)))s\n", stderr)
        var transcripts: [String] = []
        transcripts.reserveCapacity(windows.count)
        for window in windows {
            try Task.checkCancellation()
            let text = try await manager.transcribe(audio: Array(samples[window]))
            transcripts.append(text)
        }

        let text = SenseVoiceFileChunking.mergeTranscripts(transcripts)
        return (text, CFAbsoluteTimeGetCurrent() - start)
    }

    func shutdown() {
        manager = nil
        hasCompletedWarmup = false
        loadGeneration &+= 1
    }

    static let cacheRelativePath = "Library/Application Support/FluidAudio/Models/sensevoice-small-coreml"
    static let downloadedModelSizeLabel = "~240 MB"

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        ManagedASRModelPlans.senseVoice(
            modelsRoot: ManagedASRModelPlans.fluidAudioModelsRoot(fileManager: fileManager)
        ).cacheDirectory
    }

    static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        ManagedASRModelPlans.senseVoice(
            modelsRoot: ManagedASRModelPlans.fluidAudioModelsRoot(fileManager: fileManager)
        ).isAvailableLocally(fileManager: fileManager)
    }

    static func deleteModelFiles(fileManager: FileManager = .default) {
        try? ManagedASRModelPlans.senseVoice(
            modelsRoot: ManagedASRModelPlans.fluidAudioModelsRoot(fileManager: fileManager)
        ).delete(fileManager: fileManager)
    }

    private nonisolated static func audioDuration(url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    private func warmupIfNeeded(progress: ((Double, String?) -> Void)?) async {
        guard !hasCompletedWarmup, let manager else { return }

        progress?(0.98, "Warming up SenseVoice...")
        fputs("[sensevoice] warmup: running silent audio for CoreML compilation...\n", stderr)
        do {
            let silence = [Float](repeating: 0, count: 16_000)
            _ = try await manager.transcribe(audio: silence)
            hasCompletedWarmup = true
            fputs("[sensevoice] warmup complete\n", stderr)
        } catch {
            fputs("[sensevoice] warmup failed: \(error)\n", stderr)
        }
    }
}
