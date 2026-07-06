import AVFoundation
import FluidAudio
import Foundation

enum SenseVoiceFileChunking {
    static let sampleRate = SenseVoiceConfig.sampleRate
    static let passthroughThresholdSeconds: TimeInterval = 15
    static let windowSeconds: TimeInterval = 15
    static let overlapSeconds: TimeInterval = 2

    static func shouldChunk(duration: TimeInterval) -> Bool {
        duration > passthroughThresholdSeconds
    }

    static func shouldChunk(sampleCount: Int, sampleRate: Int = sampleRate) -> Bool {
        guard sampleCount > 0, sampleRate > 0 else { return false }
        return shouldChunk(duration: Double(sampleCount) / Double(sampleRate))
    }

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

    static func mergeTranscripts(_ transcripts: [String]) -> String {
        SenseVoiceTranscriptMerger.merge(transcripts)
    }
}

private enum SenseVoiceTranscriptMerger {
    private static let maxOverlapWords = 40

    static func merge(_ transcripts: [String]) -> String {
        var words: [String] = []
        for transcript in transcripts {
            let next = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !next.isEmpty else { continue }
            let overlap = suffixPrefixOverlap(words, next)
            words.append(contentsOf: next.dropFirst(overlap))
        }
        return words.joined(separator: " ")
    }

    private static func suffixPrefixOverlap(_ left: [String], _ right: [String]) -> Int {
        let limit = min(maxOverlapWords, left.count, right.count)
        guard limit >= 2 else { return 0 }

        let normalizedLeft = left.map(normalize)
        let normalizedRight = right.map(normalize)
        for count in stride(from: limit, through: 2, by: -1) {
            let suffix = normalizedLeft.suffix(count)
            if !suffix.contains(""), Array(suffix) == Array(normalizedRight.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Native Swift transcription backend for FunASR's SenseVoiceSmall via FluidAudio.
actor SenseVoiceTranscriber {
    private var manager: SenseVoiceManager?
    private var isLoading = false
    private var hasCompletedWarmup = false
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
    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        // Actor isolation makes this check-and-set race-free. Waiters retry after
        // a failed load so a transient download error does not poison the actor.
        while isLoading {
            try await Task.sleep(nanoseconds: 50_000_000)
            if manager != nil { return }
        }
        if manager != nil { return }

        isLoading = true
        defer { isLoading = false }

        fputs("[sensevoice] downloading/loading models...\n", stderr)
        let modelDirectory = try await Self.downloadRequiredModels(progress: progress)
        progress?(0.95, "Loading SenseVoice...")
        let models = try SenseVoiceModels.load(from: modelDirectory, precision: Self.precision)
        self.manager = SenseVoiceManager(models: models)
        await warmupIfNeeded(progress: progress)
        progress?(1.0, nil)
        fputs("[sensevoice] models ready\n", stderr)
    }

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let duration = try Self.audioDuration(url: wavURL)
        if !SenseVoiceFileChunking.shouldChunk(duration: duration) {
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

    func shutdown() {
        manager = nil
        hasCompletedWarmup = false
    }

    static let cacheRelativePath = "Library/Application Support/FluidAudio/Models/sensevoice-small-coreml"
    static let downloadedModelSizeLabel = "~240 MB"

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(cacheRelativePath)
    }

    static func isModelDownloaded() -> Bool {
        requiredModelsExist(at: cacheDirectory())
    }

    static func deleteModelFiles(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: cacheDirectory(fileManager: fileManager))
    }

    private static func downloadRequiredModels(progress: ((Double, String?) -> Void)?) async throws -> URL {
        let directory = cacheDirectory()
        if requiredModelsExist(at: directory) {
            return directory
        }

        // FluidAudio 0.15.x downloads every SenseVoice encoder precision via SenseVoiceManager.load.
        // Muesli only needs the INT8 ANE encoder, so fetch that subset and then use FluidAudio's loader.
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        try await downloadSubdirectory(
            ModelNames.SenseVoice.preprocessorFile,
            to: directory,
            progressRange: 0.0...0.2,
            message: "Downloading SenseVoice preprocessor...",
            progress: progress
        )
        try await downloadSubdirectory(
            ModelNames.SenseVoice.encoderInt8File,
            to: directory,
            progressRange: 0.2...0.9,
            message: "Downloading SenseVoice INT8 encoder...",
            progress: progress
        )
        try await downloadVocabulary(to: directory, progress: progress)

        return directory
    }

    private static func downloadSubdirectory(
        _ subdirectory: String,
        to directory: URL,
        progressRange: ClosedRange<Double>,
        message: String,
        progress: ((Double, String?) -> Void)?
    ) async throws {
        try await DownloadUtils.downloadSubdirectory(
            .senseVoiceSmall,
            subdirectory: subdirectory,
            to: directory,
            progressHandler: { downloadProgress in
                let span = progressRange.upperBound - progressRange.lowerBound
                let fraction = progressRange.lowerBound + span * downloadProgress.fractionCompleted
                progress?(min(max(fraction, 0.0), 1.0), message)
            }
        )
    }

    private static func downloadVocabulary(to directory: URL, progress: ((Double, String?) -> Void)?) async throws {
        let vocabularyURL = directory.appendingPathComponent(ModelNames.SenseVoice.vocabularyFile)
        if FileManager.default.fileExists(atPath: vocabularyURL.path) {
            progress?(0.95, "SenseVoice vocabulary ready...")
            return
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress?(0.9, "Downloading SenseVoice vocabulary...")
        let remoteURL = try ModelRegistry.resolveModel(
            Repo.senseVoiceSmall.remotePath,
            ModelNames.SenseVoice.vocabularyFile
        )
        let data = try await DownloadUtils.fetchHuggingFaceFile(
            from: remoteURL,
            description: "SenseVoice vocabulary"
        )
        try data.write(to: vocabularyURL, options: .atomic)
        progress?(0.95, "SenseVoice vocabulary ready...")
    }

    private static func requiredModelsExist(at directory: URL, fileManager: FileManager = .default) -> Bool {
        let vocabularyURL = directory.appendingPathComponent(ModelNames.SenseVoice.vocabularyFile)
        return SenseVoiceModels.modelsExist(at: directory, precision: precision)
            && fileManager.fileExists(atPath: vocabularyURL.path)
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
