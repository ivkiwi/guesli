import FluidAudio
import Foundation
import MuesliCore

enum Qwen3AsrModelStore {
    static let cacheDirectoryNames = ["qwen3-asr-0.6b", "qwen3-asr-0.6b-coreml"]
    private static let requiredArtifacts = [
        "qwen3_asr_audio_encoder_v2.mlmodelc",
        "qwen3_asr_decoder_stateful.mlmodelc",
        "qwen3_asr_embeddings.bin",
        "vocab.json",
    ]

    static func modelsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        isModelDownloaded(in: modelsRoot(fileManager: fileManager), fileManager: fileManager)
    }

    static func isModelDownloaded(in modelsRoot: URL, fileManager: FileManager = .default) -> Bool {
        cacheDirectoryNames.contains { name in
            ["int8", "f32"].contains { variant in
                let directory = modelsRoot
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent(variant, isDirectory: true)
                return requiredArtifacts.allSatisfy {
                    fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
                }
            }
        }
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
    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if manager != nil { return }

        fputs("[qwen3-asr] downloading/loading models...\n", stderr)
        let modelDir = try await MuesliQwen3AsrModels.download(variant: .int8) { fraction in
            DispatchQueue.main.async {
                progress?(fraction, "Downloading Qwen3 ASR...")
            }
        }
        let mgr = MuesliQwen3AsrManager()
        try await mgr.loadModels(from: modelDir)
        self.manager = mgr
        fputs("[qwen3-asr] models loaded, running warmup inference...\n", stderr)

        // Warmup: run a tiny dummy audio through the pipeline to trigger CoreML compilation.
        // This moves the ~30s compilation cost from first dictation to preload time.
        let warmupSamples = [Float](repeating: 0, count: 16000) // 1 second of silence
        _ = try? await mgr.transcribe(audioSamples: warmupSamples)
        fputs("[qwen3-asr] warmup complete, ready\n", stderr)
    }

    /// Transcribe a WAV file URL.
    /// Returns the transcribed text (no token-level timings available).
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        return try await transcribe(audioSamples: samples)
    }

    func transcribe(audioSamples: [Float]) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let text = try await manager.transcribe(audioSamples: audioSamples)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        manager = nil
    }
}
