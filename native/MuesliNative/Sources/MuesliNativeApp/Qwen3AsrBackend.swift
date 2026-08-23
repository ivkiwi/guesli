import FluidAudio
import Foundation
import MuesliCore

enum Qwen3AsrModelStore {
    static let cacheDirectoryNames = ["qwen3-asr-0.6b", "qwen3-asr-0.6b-coreml"]
    static func modelsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        isModelDownloaded(in: modelsRoot(fileManager: fileManager), fileManager: fileManager)
    }

    static func isModelDownloaded(in modelsRoot: URL, fileManager: FileManager = .default) -> Bool {
        ManagedASRModelPlans.qwen3ASRInt8(modelsRoot: modelsRoot)
            .isAvailableLocally(fileManager: fileManager)
    }

    static func deleteModelFiles(fileManager: FileManager = .default) throws {
        try deleteModelFiles(from: modelsRoot(fileManager: fileManager), fileManager: fileManager)
    }

    static func deleteModelFiles(from modelsRoot: URL, fileManager: FileManager = .default) throws {
        for name in cacheDirectoryNames {
            let directory = modelsRoot.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            try fileManager.removeItem(at: directory)
        }
    }
}

enum Qwen3AsrWarmupReadiness {
    static func validate(isCancelled: Bool = Task.isCancelled, isCurrent: Bool) throws {
        guard !isCancelled, isCurrent else { throw CancellationError() }
    }
}

/// Native Swift transcription backend using the vendored Qwen3 ASR model
/// running on Apple's Neural Engine (ANE) via CoreML.
/// Requires macOS 15+ due to CoreML stateful decoder support.
@available(macOS 15, *)
actor Qwen3AsrTranscriber {
    private var manager: MuesliQwen3AsrManager?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Qwen3 ASR models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models (if needed) and initializes the Qwen3 ASR manager.
    func loadModels(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if manager != nil { return }

        fputs("[qwen3-asr] downloading/loading models...\n", stderr)
        let plan = ManagedASRModelPlans.qwen3ASRInt8()
        let mgr = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDir in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading Qwen3 ASR into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)
            let candidate = MuesliQwen3AsrManager()
            try await candidate.loadModels(from: modelDir)
            self.manager = candidate
            fputs("[qwen3-asr] models loaded, running warmup inference...\n", stderr)
            do {
                _ = try await candidate.transcribe(audioSamples: [Float](repeating: 0, count: 16000))
                try Qwen3AsrWarmupReadiness.validate(isCurrent: manager === candidate)
                return candidate
            } catch {
                if manager === candidate { manager = nil }
                throw error
            }
        }
        self.manager = mgr
        let preparing = ModelDownloadProgress.preparing(modelID: plan.modelID, message: "Loading Qwen3 ASR into Core ML...")
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[qwen3-asr] warmup complete, ready\n", stderr)
    }

    /// Transcribe a WAV file URL.
    /// Returns the transcribed text (no token-level timings available).
    func transcribe(wavURL: URL, language: String? = nil) async throws -> (text: String, processingTime: Double) {
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        return try await transcribe(audioSamples: samples, language: language)
    }

    func transcribe(audioSamples: [Float], language: String? = nil) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let text = try await manager.transcribe(audioSamples: audioSamples, language: language)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        manager = nil
    }
}
